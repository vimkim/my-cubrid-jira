# [OOS] [조사/설계] OOS 값 압축 위치 검토 — 데이터 타입 직렬화 계층(A안) vs OOS 경계(B안)

## Issue Triage

**이슈 수행 목적**: OOS(Out-of-row Overflow Storage — heap 의 큰 가변 컬럼을 별도 파일로 분리 저장하는 방식)로 빠지는 값을 압축할지, 한다면 어느 계층에서 할지 결정의 근거를 마련한다. 후보 두 가지 — **A안(데이터 타입 직렬화 계층)** / **B안(OOS 경계)** — 의 장단점·특징·수정 콜패스를 정리하고, 최종 선택은 ANALYSIS 단계로 넘긴다.

**이슈 수행 이유**:

지금(공식 머지본) 엔진의 값 압축 현황은 아래와 같다.

| 압축 위치 | 공식 상태 |
|-----------|-----------|
| 데이터 타입 직렬화 계층 | VARCHAR 만 LZ4 압축. `pr_do_db_value_string_compression` 이 `db_type != DB_TYPE_VARCHAR` 에서 즉시 반환하므로, VARNCHAR·VARBIT·JSON 등은 비압축으로 직렬화된다. |
| OOS 경계 | 공식 압축 없음. OOS 로 빠진 큰 가변 값(VARBIT·JSON 등)은 그대로 비압축 저장된다. |

**영향**: 현재 압축되는 가변 타입(Variable Type)은 VARCHAR 뿐이다. 압축 위치를 정하고 나면 JSON·VARBIT·SEQUENCE (그리고 추후 CHAR) 같은 다른 가변 타입도 압축 대상에 넣을 수 있다.

---

## 1. A안 vs B안 장단점 비교

- **A안 = 데이터 타입 직렬화 계층 압축** — `mr_data_writeval_*` 의 공식 압축 자리를 VARCHAR 너머로 확장
- **B안 = OOS 경계 압축** — `oos_payload_encode` 에서 OOS 로 빠지는 값만 압축 (임시 PR `cbrd-26756` 프로토타입)

기본 성격(장단점 아님):

- **적용 범위** — A안: heap·index·OOS 직렬화 일괄 / B안: OOS 로 빠진 값만.
- **진행 경로** — A안: develop 독립 이슈 / B안: OOS(feat/oos) 작업 내부.

### 장점 비교

| 비교 축 | A안: 타입 직렬화 계층 | B안: OOS 경계 |
|---------|----------------------|---------------|
| 장점 ① | 타입별 알고리즘 자유 선택 (VARBIT skip, JSON 자체압축 활용 등) | 영향 범위가 OOS 파일로 좁아 회귀 위험 작음 |
| 장점 ② | 이중압축이 **구조적으로 불가** (압축 자리가 한 곳) | 작은 가변값엔 비용 0 (OOS 임계치 넘은 값만 압축) |
| 장점 ③ | 길이 prefix 가 압축 여부를 기술 → **별도 헤더 불필요** | feat/oos 작업 내부에서 **자기완결**, 포맷 변경이 OOS 파일에 국한 |
| 장점 ④ | develop 이슈로 **독립 진행** 가능 | 임시 PR 로 **이미 동작 검증** 됨 (encode/decode/gain-gate 완성) |

### 단점 비교

| 비교 축 | A안: 타입 직렬화 계층 | B안: OOS 경계 |
|---------|----------------------|---------------|
| 단점 ① | 영향 범위 넓음 (heap+index+OOS 모두 회귀 검증) | 알고리즘이 LZ4 로 **고정** (`compressor.hpp` static_assert) |
| 단점 ② | 인덱스 키 압축 의미 검증 필요 (키비교·prefix·커버링 인덱스) | 저압축성 VARBIT 도 풀 O(n) 압축 강제 → **낭비 CPU** 가 read/write 에 직접 실림 |
| 단점 ③ | 타입마다 수정량 편차 큼 (string 류는 게이트만, JSON/SET 은 포맷 변경) | 별도 압축 헤더(`OOS_COMP_HEADER` 8B) 필요 |
| 단점 ④ | 인덱스만 제외하려면 공유 본체(`mr_writeval_string_internal`) 분기 필요 | VARCHAR 이중압축은 **"명시 제외"로만** 회피 (코드 강제 아님) |

---

## 2. A안 / B안 각각의 특징

### A안 — 데이터 타입 직렬화 계층 압축

- **무엇을 하는가**: DB_VALUE 를 디스크/`recdes`(heap 레코드 디스크립터) 이미지로 직렬화할 때(`mr_data_writeval_*`) 압축한다. 지금 VARCHAR 가 쓰는 압축 자리를 다른 타입으로 넓히는 방향.
- **압축이 박히는 곳**: 직렬화 포맷 자체. VARCHAR 는 `value->data.ch.medium.compressed_size` 라는 **포맷 내장 슬롯** 으로 압축 여부를 기술한다. VARNCHAR·VARBIT 는 같은 `ch.medium` 구조를 공유하므로 게이트만 풀면 되지만, JSON·SET 은 이 슬롯이 없어 새 포맷 설계가 필요하다.
- **적용 단위**: 타입. 한 번 타입에 압축을 켜면 그 타입은 heap·index·OOS 어디로 가든 동일하게 압축된다.
- **알고리즘 자유도**: 타입별 `writeval` 함수가 갈라져 있으니, 타입마다 다른 알고리즘/정책을 박을 수 있다(원리상). 단, 공통 `compressor.hpp` 가 LZ4 고정이라 다양화는 그 래퍼 확장이 선행되어야 한다.
- **본질적 결정 포인트**: "인덱스 키도 압축할 것인가". `mr_index_writeval_string` 이 `mr_data_writeval_string` 과 **같은 본체를 공유** 하므로, A안을 택하면 인덱스 키 압축 여부를 강제로 결정·구현해야 한다.

### B안 — OOS 경계 압축

- **무엇을 하는가**: 큰 가변 컬럼이 OOS 로 빠질 때(`oos_payload_encode`)만 압축한다. 직렬화는 그대로 두고, OOS 파일에 쓰기 직전에 layer-2 blob 으로 한 번 더 감싼다.
- **압축이 박히는 곳**: OOS blob 포맷. `[ OOS_COMP_HEADER(8B) | image-or-lz4-bytes ]` 구조로, 헤더의 `algo` 필드가 압축 방식을 기술한다(향후 알고리즘 다양화 여지는 포맷상 이미 확보).
- **적용 단위**: OOS 로 빠진 개별 값. OOS 임계치(레코드 > `DB_PAGESIZE/8`, 컬럼 > 512B)에 못 미쳐 heap 에 남는 작은 가변값은 손대지 않는다.
- **이득 게이트**: 압축 후 `comp_len + OOS_COMP_MIN_GAIN(8) > image_len` 이면 raw fallback. LZ4 는 풀 패스를 돌려야 실제 크기를 알 수 있어, 저압축성 타입은 이 풀 압축이 사실상 낭비 CPU 가 된다.
- **본질적 결정 포인트**: "저압축성 타입(VARBIT 등)에 풀 압축 패스를 그대로 태울 것인가". 그리고 알고리즘 LZ4 고정을 언제 풀 것인가.

---

## 3. A안 / B안 각각 — 수정해야 할 콜패스

**범례**: `[유지]` = 이미 있는 코드, `[게이트 완화]` = 분기 조건만 손봄, `[신규]` = 새로 작성, `[분기]` = 공유 본체를 갈라야 함.

### A안 수정 콜패스 — 타입 계층 (공식 코드 확장)

```
■ 쓰기 경로
mr_data_writeval_string()                          object_primitive.c:10832  [유지]
     │
     └─▶ mr_writeval_string_internal()             object_primitive.c:10929  [분기?]
              │                                      ⚠ 인덱스도 이 공통 본체 호출
              │   mr_index_writeval_string() ───────┘ object_primitive.c:10813
              │     → A안 택하면 인덱스 키도 압축됨. 인덱스 제외하려면
              │       align 인자 기준으로 본체를 [분기] 해야 함
              │
              └─▶ pr_do_db_value_string_compression()   object_primitive.c:14613
                       │
                       │  ★ if (db_type != DB_TYPE_VARCHAR) return;   ← [게이트 완화]
                       │     VARNCHAR/VARBIT 는 ch.medium 공유 → 게이트만 풀면 됨
                       │     JSON/SET 은 ch.medium 슬롯 없음 → 각 타입 writeval 에 [신규]
                       │  ★ OR_IS_STRING_LENGTH_COMPRESSABLE (255 미만 skip)
                       │
                       └─▶ cubcompress::compress<LZ4>()   compressor.hpp:135  [유지/확장]
                                ★ static_assert(T==LZ4)    ← 알고리즘 다양화 시 [확장]

■ 읽기 역경로 (반드시 대칭 수정)
mr_data_readval_string() / pr_do_db_value_string_decompression()              [대칭 수정]

■ 타입별 추가 작업 (JSON/SET 등 ch.medium 미공유 타입을 포함할 경우)
mr_data_writeval_json() / mr_data_writeval_set() 등 각 타입 writeval/readval    [신규 + 포맷 변경]
```

**A안 수정 요약**
- **string 계열(VARNCHAR·VARBIT)**: `pr_do_db_value_string_compression` 의 db_type 게이트 완화 + read 대칭 → 비교적 작음.
- **JSON·SET 등**: 압축 여부 기술 슬롯이 없어 각 타입 직렬화 포맷에 신규 설계 필요 → 큼.
- **인덱스 분리**: 인덱스 키를 압축에서 빼려면 `mr_writeval_string_internal` 공유 본체를 `align` 기준으로 분기.
- **알고리즘 다양화**: `compressor.hpp` 의 LZ4 `static_assert` 확장(CBRD-26890 연계).

### B안 수정 콜패스 — OOS 경계 (임시 PR 공식화)

```
■ 쓰기 경로
heap_file.c:12497   oos_payload_encode(thread_p, attr_type, ...)              [유지/공식화]
     │
     ├─▶ OOS_COMPRESSION_ENABLED && oos_should_compress(attr_type)
     │        oos_file.hpp:241,257   ← 타입 게이트(VARCHAR 제외=이중압축 회피)  [정책 확정]
     │
     ├─▶ bound = cubcompress::bound<LZ4>(len)        oos_file.hpp:308          [유지]
     │        ★ bound <= 0 (len > 0x7E000000)  → raw 저장
     │
     └─▶ cubcompress::compress<LZ4>()                oos_file.hpp:323          [유지]
              │   ⚠ 풀 O(n) 패스 — VARBIT 등 저압축성 타입엔 낭비 CPU
              │     → 타입별 skip/샘플링 둘지 [정책 결정]
              └─▶ ★ comp_len + OOS_COMP_MIN_GAIN(8) > len → raw fallback        [유지]

■ 읽기 역경로
heap_file.c:10621   oos_payload_decode()             oos_file.hpp:132          [유지]
                       ← OOS_COMP_HEADER(8B).algo 보고 해제

■ 알고리즘 다양화 시
compressor.hpp:123,135,164  static_assert(T==LZ4)                              [확장]
OOS_COMP_HEADER.algo (oos_file.hpp:45)  ← 포맷상 이미 여지 확보됨               [활용]
```

**B안 수정 요약**
- 핵심 함수(`oos_payload_encode` / `oos_payload_decode` / `oos_should_compress`)는 **임시 PR 에 이미 작성** 되어 있음 → 수정이 아니라 **공식화·정책 확정** 이 일.
- **정책 결정 항목**: ① `oos_should_compress` 의 타입 화이트리스트 확정, ② 저압축성 타입 풀 압축 skip 여부, ③ VARCHAR 이중압축 회피를 코드로 강제할지.
- **알고리즘 다양화**: `compressor.hpp` 확장 + 이미 있는 `OOS_COMP_HEADER.algo` 필드 활용(CBRD-26890 연계).

---

## AI-Generated Context

**참고**: 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료입니다. 빠른 triage 에는 위 1~3 절로 충분하며, 아래는 구현/리뷰 단계 참고용입니다. 근거 비교 보고서: `oos-compression-placement-analysis.md`(작업 트리 루트).

### Summary

- **문제 / 목적**: OOS 로 빠지는 값을 압축할지, 한다면 타입 직렬화 계층(A안)과 OOS 경계(B안) 중 어디서 할지 비교/조사.
- **원인 / 배경**: 공식 압축은 타입 계층의 VARCHAR 단일뿐이고 OOS 값은 비압축이다. 임시 PR `cbrd-26756` 이 OOS 경계 압축을 시도하면서 압축 위치를 정식으로 정할 필요가 생겼다.
- **제안 / 변경**: 본 이슈는 코드 변경 없음. 비교 문서화와 결정 항목 정리만.
- **영향 범위**: heap 직렬화, index 직렬화(`mr_index_writeval_*`), OOS read/write 경로, `compressor.hpp` 공통 래퍼. 조사 단계라 본 이슈 자체로 인한 디스크 포맷 변경은 없다.

### 데이터 타입별 압축 현황

`타입 계층` 열만 공식이다. `OOS 경계` 열의 `O` 는 임시 PR `cbrd-26756` 기준이며, 공식 머지본에서는 OOS 값이 모두 비압축이다.

| 가변 타입 | A안: 타입 계층 (공식) | B안: OOS 경계 (임시 PR 프로토타입) |
|-----------|------------------|-------------------------------|
| VARCHAR | O (LZ4) | X (이중압축 회피로 제외) |
| VARNCHAR (enum `DB_TYPE_VARNCHAR_DEPRECATED`) | X (db_type 분기로 미적용) | O (LZ4) |
| VARBIT | X | O (LZ4) |
| JSON | X | O (LZ4) |
| SET/MULTISET/SEQUENCE | X | O (LZ4) |
| BLOB/CLOB | X (external ES, locator 만 inline) | X |
| CHAR/NCHAR/BIT(고정) | X | X (OOS 대상 아님) |

OOS 임계치(레코드 > `DB_PAGESIZE/8`, 컬럼 > 512B)에 못 미쳐 heap 안에 그대로 남는 작은 가변 값은 어느 방식에서도 압축되지 않는다. 타입 계층은 VARCHAR 만, OOS 경계는 OOS 로 빠진 값만 다루기 때문이다.

### 압축 후 크기 예측 비용

삽입 성능과 직결되는 지점이라 따로 둔다.

- `LZ4_compressBound(isize)` = `isize + isize/255 + 16`, 한계 초과 시 0 (`lz4.h:171`). O(1) 매크로다.
- 단, 이는 **최악 팽창 상한**(입력보다 약간 큰 값)이라 실제 압축 크기가 아니다. 실제 크기는 `LZ4_compress_fast_extState` 풀 패스(O(n))를 돌려야만 알 수 있다.
- 따라서 "크기를 싸게 추정해 보고 이득 없으면 건너뛰기"는 LZ4 로는 불가능하다. 압축 대상이면 일단 풀 압축을 돌린 뒤에야 이득 여부를 판단한다. VARBIT 처럼 잘 안 줄어드는 타입은 이 풀 압축 패스가 사실상 낭비 CPU 가 된다.

### 인덱스 영향 (A안 한정)

`mr_index_writeval_string`(`object_primitive.c:10813`)은 별도 함수지만 `mr_writeval_string_internal`(`:10929`) 을 정렬값(`CHAR_ALIGNMENT` vs `INT_ALIGNMENT`)만 바꿔 호출하는 **공통 본체** 다. A안(타입 계층 압축)을 택하면 인덱스 키에도 영향이 가며, 인덱스만 빼려면 이 wrapper 를 본체에서 갈라야 해 수정량이 커진다. 인덱스 키 압축은 키 비교·prefix 인덱스·커버링 인덱스 의미에 영향을 줄 수 있어 별도 확인이 필요하다.

### 알고리즘 다양화 가능성 (A안·B안 공통)

`compressor.hpp` 의 `bound/compress/decompress` 는 모두 `static_assert(std::is_same_v<T, LZ4>)`(`compressor.hpp:123,135,164`)로 LZ4 만 허용한다. 어느 위치를 택하든 zstd 같은 알고리즘 추가는 이 공통 래퍼 확장이 선행되어야 하며, 이 부분은 CBRD-26890(internal LOB 압축 알고리즘 검토)과 겹친다. 단 B안은 `OOS_COMP_HEADER.algo`(`oos_file.hpp:45`) 필드로 디스크 포맷상 알고리즘 식별 여지를 이미 확보해 둔 상태다.

## Open Questions

- 인덱스 키를 압축 대상에 포함할지, 포함 시 키 비교·prefix·커버링 인덱스에 미치는 영향 범위. (A안)
- VARBIT 등 저압축성 타입에 풀 압축 패스를 그대로 태울지, 타입별 스킵이나 샘플링 추정을 둘지(삽입 성능 측정 필요). (A·B 공통)
- zstd 등 알고리즘 다양화를 어느 계층에서, `compressor.hpp` 의 LZ4 고정을 어떻게 풀며 도입할지(CBRD-26890 연계).
- JSON 처럼 라이브러리 자체 압축을 가진 타입을 별도 처리할지.
- 타입 계층(A안)과 OOS 경계(B안)를 동시에 쓸 경우, 이중압축 방지를 주석 약속이 아니라 코드로 강제하는 방법.

## 참고 사항

- 본 이슈는 설계 확정이 아닌 조사/검토 단계이며, 상세 정책과 구현은 후속 이슈에서 구체화한다.
- 임시 PR `cbrd-26756` 은 공식 머지본이 아니다. 그 OOS 경계 구현 세부(헤더 형식·타입 분기·gain gate)는 방향 검토용 프로토타입 참고일 뿐, 본 이슈가 디스크 포맷을 확정하지는 않는다.

## 참고 코드

- `src/object/object_primitive.c` (공식) — mr_data_writeval_string(:10832), mr_index_writeval_string(:10813), mr_writeval_string_internal(:10929), pr_do_db_value_string_compression(:14613)
- `src/base/object_representation.h:1411,1414` (공식) — OR_MINIMUM_STRING_LENGTH_FOR_COMPRESSION(255), 압축 조건 매크로
- `src/storage/oos_file.hpp` (임시 PR cbrd-26756 프로토타입) — OOS_COMP_HEADER(:53,70), algo 필드(:45), OOS_COMP_MIN_GAIN(:82), oos_payload_decode(:132), OOS_COMPRESSION_ENABLED(:241), oos_should_compress(:257), oos_payload_encode(:296), bound(:308), compress(:323), gain gate(:324)
- `src/storage/heap_file.c` (임시 PR) — :12497 oos_payload_encode 호출(attr_type 전달), :10621 oos_payload_decode 호출
- `src/base/compressor.hpp` (공식) — LZ4 단일 래퍼(public 템플릿 bound/compress/decompress static_assert :123,135,164; LZ4_compress_fast_extState :97)
- `win/3rdparty/lz4/include/lz4.h:170,171` — LZ4_MAX_INPUT_SIZE(0x7E000000), LZ4_COMPRESSBOUND 매크로
