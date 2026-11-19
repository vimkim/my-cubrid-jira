# [OOS] 페이지 batch 수집이 OOS 행의 MVCC 헤더 크기를 배열 범위 밖에서 읽는다

**한 줄 요약**: PR #7990(feature/oos-merge → develop) 병합 전 점검에서 확인한 결함이다. develop에서 들어온 페이지 batch 스캔의 행 수집 함수가 OOS 플래그를 지우지 않은 MVCC 플래그로 8칸짜리 헤더 크기 표를 인덱싱해, OOS 값을 가진 행마다 표 밖의 전역 메모리를 읽는다. 이를 병합 전에 바로잡는다.

## Issue Triage

**이슈 수행 목적**: OOS 값을 가진 행이 페이지 batch 스캔을 지나가도, 행 수집 함수가 `mvcc_header_size_lookup` 표의 범위 안에서만 헤더 크기를 읽는다.

**이슈 수행 이유**: `heap_page_collect_visible` (`src/storage/heap_file.c:8790`)는 `mvcc_header_size_lookup[MVCC_GET_FLAG (&mvcc_header)]` 로 행의 헤더 크기를 구한다. 이때 플래그 값에는 하위 3비트 MVCC 플래그뿐 아니라 OOS 플래그(`OR_RECORD_FLAG_HAS_OOS`, `0x08`)도 남아 있다. 표는 `int[8]` 이므로, OOS 행에서는 인덱스가 8\~15가 되어 표 밖을 읽는다. 같은 표를 쓰는 다른 곳은 모두 `OR_RECORD_MVCC_FLAG_MASK` 로 하위 3비트만 남긴 뒤 인덱싱한다. 이 줄은 develop의 페이지 batch 실행(CBRD-27361, PR #8196)이 추가했고, OOS 플래그를 쓰는 코드와는 feature/oos-merge의 develop 동기화에서 처음 만났다. 그래서 develop에는 아직 드러나지 않고, #7990이 develop에 병합되면 함께 들어간다.

**영향**: C/C++ 기준으로 정의되지 않은 동작(배열 범위 밖 읽기)이다. 소스로 따라가 보면 질의 결과에는 영향이 없다. 잘못 읽은 헤더 크기를 쓰는 곳은 batch 계획의 레코드 검사(`src/query/expr_batch.c:4216`)뿐이고, OOS 행은 그 직후 검사(`:4221`)에서 언제나 행 단위 경로로 넘어간다. 잘못된 값은 넘어가는 이유("다른 representation"과 "out-of-row 값") 중 어느 것이 붙는지만 바꾼다. 다만 AddressSanitizer 빌드에서 OOS 테이블을 스캔하는 시험은 이 읽기를 global-buffer-overflow로 보고할 수 있다. 그러면 개발자와 QA가 실제 결함과 이 잡음을 구분해야 한다. 실행 재현은 하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

소스 기준은 `origin/feature/oos-merge` `71993ddb63` 이다. 아래 내용은 모두 코드를 읽어 확인했고, 빌드나 실행으로 재현하지 않았다.

### 무엇이 어긋나는가

heap 레코드 헤더의 첫 4바이트에는 representation ID와 레코드 플래그가 함께 들어 있다. 플래그 중 하위 3비트(`OR_RECORD_MVCC_FLAG_MASK`, `0x07`)는 MVCC 필드가 있는지를 나타내고, 헤더 길이는 이 3비트로 정해진다. `0x08` 은 OOS가 추가한 "이 행에 out-of-row 값이 있다" 플래그로, 헤더 길이와는 상관없다.

``` c
/* src/object/object_representation.c:71 */
int mvcc_header_size_lookup[8] = { ... };

/* src/base/object_representation_constants.h:159-174 */
#define OR_RECORD_FLAG_MASK       0x1f
#define OR_RECORD_MVCC_FLAG_MASK  0x07
#define OR_RECORD_FLAG_HAS_OOS    0x08
```

페이지 batch 수집은 헤더를 직접 풀어 플래그 5비트를 모두 남긴다.

``` c
/* src/storage/heap_file.c:8569, heap_page_row_mvcc_header () */
header->mvcc_flag = (char) ((repid_and_flag_bits >> OR_RECORD_FLAG_SHIFT_BITS) & OR_RECORD_FLAG_MASK);

/* src/storage/heap_file.c:8790, heap_page_collect_visible () */
rows[n].hdr_size = mvcc_header_size_lookup[MVCC_GET_FLAG (&mvcc_header)];	/* OR_HEADER_SIZE (rec.data) */
```

`MVCC_GET_FLAG` 는 `mvcc_flag` 를 그대로 돌려준다(`src/transaction/mvcc.h:75`). 반면 같은 표를 쓰는 다른 곳은 모두 마스크를 적용한다. 예를 들어 `heap_file.c:23411`, `:24642`, `src/base/object_representation_sr.c:4382`, `src/query/vacuum.c:2445`(`OR_GET_MVCC_FLAGS`), `object_representation.c:5799` 가 그렇다.

### 잘못 읽은 값이 쓰이는 곳

`HEAP_PAGE_ROW.hdr_size` 를 읽는 곳은 `src/query/expr_batch.c` 의 representation 확인 루프뿐이다.

``` c
/* src/query/expr_batch.c:4216-4224 */
if (recdes->data == NULL || recdes->length < batch->rows[r].hdr_size)
  {
    return eb_fallback (plan, "a record of another representation");
  }
/* an out-of-row value's variable-area bytes are its OOS reference, not the value */
if (OR_RECORD_HAS_OOS (recdes->data))
  {
    return eb_fallback (plan, "a record with out-of-row values");
  }
```

OOS 행은 첫 검사를 통과하든 못 하든 행 단위 경로로 넘어간다. 그래서 `heap_rec_layout_init_repr_hdr` 가 잘못된 헤더 크기로 호출되지는 않는다. 영향은 표 밖 읽기 자체와 넘어가는 이유 문자열에 그친다. 이 판단은 현재 호출 구조에 기대고 있다. 앞으로 batch가 OOS 행을 직접 디코딩하게 되면, 같은 값이 잘못된 컬럼 위치로 이어진다.

### 재현 방법(제안, 실행하지 않음)

1. feature/oos-merge를 AddressSanitizer로 빌드한다(CMake `-DCMAKE_BUILD_TYPE=Debug`, `-fsanitize=address` 를 C/C++ 플래그에 추가).
2. OOS로 저장될 만큼 큰 `VARCHAR` 값과 정수 컬럼을 가진 테이블에 여러 행을 넣는다.
3. 정수 컬럼에 조건을 건 `SELECT` 를 실행해, 페이지 batch 스캔(`scan_batch_open_internal` 이 허용하는 일반 heap SELECT)을 타게 한다.
4. 기대 결과: ASan 보고가 없다. 실제 예상: `heap_page_collect_visible` 에서 `mvcc_header_size_lookup` 에 대한 global-buffer-overflow 보고. 일반 Debug·Release 빌드에서는 증상이 보이지 않을 가능성이 크다.

### ANALYSIS에서 확인할 것

- 위 재현 절차로 ASan 보고가 실제로 나오는지 확인한다.
- 수정 위치를 정한다. 이 호출 한 곳에 마스크를 적용할지, `heap_page_row_mvcc_header` 가 채우는 값과 다른 MVCC 헤더 해석 함수 사이의 계약을 맞출지 결정한다. 디버그 빌드의 일치 검사(`heap_file.c:8727-8732`, `or_mvcc_get_header` 와의 비교)는 `mvcc_flag` 를 5비트 그대로 비교하므로, 계약을 바꾸면 이 검사도 함께 봐야 한다.
- 같은 종류의 결함은 CBRD-26488에서 `or_header_size` 에 대해 한 번 고쳤다. 새 코드가 이 표를 직접 인덱싱하면 같은 실수가 다시 생길 수 있다. 마스크를 적용하는 접근 함수만 쓰도록 할지, 표 접근에 범위 assert를 둘지 검토한다.
- #7990 병합 전에 넣을지 결정한다. 수정은 작지만, 병합 직전에 head가 바뀌면 CI와 최종 리뷰를 다시 돌려야 한다.

### 관련 이슈

- CBRD-27361 (PR #8196): 이 줄을 추가한 develop 페이지 batch 실행
- CBRD-26357 (PR #7990): OOS를 develop에 병합하는 PR
- CBRD-26488 (Closed): `or_header_size` 가 같은 표를 마스크 없이 인덱싱하던 같은 종류의 결함과 그 수정
- CBRD-26978: OOS TODO epic(OOS 결함은 이 epic의 Sub-task로 등록한다는 2026-11-10 결정)
