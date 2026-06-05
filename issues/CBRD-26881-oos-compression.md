# [OOS] OOS 페이로드 압축 저장

## Issue Triage

**이슈 수행 목적**: OOS 로 빠지는 큰 컬럼 값 중 지금은 압축 없이 저장되는 타입(VARBIT/JSON/콜렉션 등)을 압축해서 저장한다. OOS 파일이 작아지고 읽기 디스크 I/O 가 줄어든다.

> 용어: OOS (Out-of-row Overflow Storage) 는 heap 레코드(한 행의 데이터) 안에 두기엔 너무 큰 가변 컬럼 값을, 별도의 OOS 파일로 빼서 저장하는 방식이다. 행에는 "값이 저기 있다" 는 16바이트짜리 포인터만 남는다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: CUBRID 에는 이미 문자열 자동 압축(LZ4) 이 있다. 그런데 이 압축은 `DB_TYPE_VARCHAR` 한 종류에만 걸린다 (`pr_do_db_value_string_compression` 이 VARCHAR 가 아니면 그냥 반환). 그래서 `DB_TYPE_VARBIT` / `DB_TYPE_JSON` / `DB_TYPE_SET` / `DB_TYPE_MULTISET` / `DB_TYPE_SEQUENCE` 값은 압축 없이 그대로 OOS 파일에 들어간다 (CBRD-26756 조사로 확인).
- **영향**: OOS 로 빠지는 값은 정의상 큰 값(`OR_OOS_INLINE_SIZE` = 16바이트 포인터로 바꿀 만큼 큰 값)인데, 그게 압축도 안 된 채 디스크에 쌓인다. 특히 JSON 은 텍스트 기반이라 압축률이 높은데도 통째로 저장돼, OOS 파일 용량과 읽기 I/O 가 불필요하게 커진다.

**이슈 수행 방안**:

- 값을 OOS 파일에 넣기 직전에 압축하고, 읽어올 때 풀어준다. 쓰기는 `heap_attrinfo_insert_to_oos`, 읽기는 `heap_attrvalue_read_oos_inline` 에서 처리한다.
- 타입 자체의 직렬화 코드(`data_writeval`) 안에 압축을 넣는 방식은 쓰지 않는다. 그렇게 하면 OOS 가 아닌 일반 행과 인덱스까지 디스크 포맷이 바뀌어 영향이 너무 커진다.
- 압축 대상: `DB_TYPE_VARBIT` / `DB_TYPE_JSON` / `DB_TYPE_SET` / `DB_TYPE_MULTISET` / `DB_TYPE_SEQUENCE` / `DB_TYPE_VARNCHAR`. VARNCHAR 도 포함한다 - 위 LZ4 가 VARCHAR 만 걸러내므로 VARNCHAR 는 압축 안 된 채 OOS 로 가기 때문이다. `DB_TYPE_VARCHAR`(이미 압축됨) 와 `DB_TYPE_BLOB` / `DB_TYPE_CLOB`(본문은 외부 저장소에 있고 행에는 위치 정보만 들어감) 는 제외한다.
- 압축한 값에는 8바이트짜리 표시를 앞에 붙인다 (압축했는지 여부 + 원래 크기). 이 표시를 읽고 푸는 코드는 한 군데(`oos_file.hpp` 공유 모듈) 에만 두고, OOS 값을 읽는 모든 경로가 그 한 곳을 쓰게 한다. OOS 값을 읽는 곳은 한 군데가 아니다 - 일반 조회, 복제(HA) 적용, 향후 CDC 가 있다.
- 복제(standby 서버로 데이터 복사) 는 압축을 푼 값이 아니라 압축된 상태 그대로 전송하고, standby 가 같은 코드로 풀어 쓴다. 전송량을 늘리지 않고, standby 도 일반 읽기와 같은 경로로 복원하게 하기 위해서다.
- LZ4 압축은 기존 `cubcompress::compress` / `decompress` (`src/base/compressor.hpp`) 를 재사용한다.
- 압축 on/off 설정을 정식 시스템 파라미터(`oos_enable_compression`) 로 뺄지 여부: `TBD - 합의 미확인`. 현재 구현은 코드 내부 상수이며, 시스템 파라미터로 빼는 방향을 검토 중이다.

---

## AI-Generated Context

> 아래는 AI 가 코드를 분석해 채운 상세 자료다. 빠른 triage 에는 위 Issue Triage 만 봐도 되고, 본문은 구현/리뷰 때 참고하면 된다.

### 개요

압축한 값은 앞에 8바이트 헤더를 붙여 저장한다. 헤더에는 압축 방식과 원래 크기가 들어간다. 따라서 OOS 값을 읽는 쪽은 항상 헤더를 먼저 해석한 뒤 압축을 풀어야 한다. 이 이슈의 핵심 위험은 OOS 값을 읽는 경로가 하나가 아니라는 점이다. 일반 조회, 복제 적용기, 향후 CDC 가 모두 OOS 값을 읽으며, 이 중 한 경로라도 헤더를 해석하지 않으면 깨진 값을 사용하게 된다. 그래서 헤더 해석/복원 코드를 공유 모듈 한 곳에 두고 모든 경로가 그것을 호출하도록 한다.

### Summary

- **문제 / 목적**: VARCHAR 를 뺀 OOS 대상 타입(VARBIT/JSON/콜렉션)이 비압축으로 저장돼 OOS 파일이 커진다. OOS 경계에서 압축한다.
- **원인 / 배경**: 자동 LZ4 압축이 VARCHAR(`tp_String`) 직렬화 경로에만 있다 (CBRD-26756).
- **제안 / 변경**: 쓰기(`heap_attrinfo_insert_to_oos`)/읽기(`heap_attrvalue_read_oos_inline`) 에 압축/복원을 넣고, 포맷과 코덱을 `oos_file` 공유 모듈로 둔다.
- **영향 범위**: `src/storage/heap_file.c`, `src/storage/oos_file.{hpp,cpp}`, `src/transaction/log_applier.c`(복제 reader). 디스크/전송 포맷 변경이라 OOS 미완 단계(feat/oos, M2)에서 처리한다. 기존 일반 행 포맷은 안 바뀐다.

---

## Description

OOS 로 빠진 값도 결국 일반 행과 똑같은 직렬화 함수(`data_writeval` - 값을 디스크 바이트로 바꾸는 콜백)를 거쳐 OOS 페이지에 기록된다. OOS 전용 직렬화 경로는 따로 없다. 즉 타입의 `data_writeval` 안에서 압축이 일어나야만 OOS 도 압축된 바이트를 받는데, 그 경로를 가진 타입은 `DB_TYPE_VARCHAR` 하나뿐이다.

CBRD-26756 조사 결과는 이렇다:

- 압축 진입점 `pr_do_db_value_string_compression` 은 타입이 VARCHAR 가 아니면 바로 빠져나온다.
- 이 함수를 부르는 곳은 `mr_lengthval_string_internal` 과 `mr_writeval_string_internal` 둘뿐이고, 둘 다 문자열(`tp_String`) 경로다.
- JSON/콜렉션/VARBIT 의 직렬화 함수(`mr_data_writeval_json`, `mr_data_writeval_set`, `mr_writeval_varbit_internal`)에는 압축 호출이 아예 없다.

그래서 이 이슈는 타입별 코드를 건드리는 대신, OOS 로 넣고 빼는 길목에 압축/복원을 한 겹 끼운다. 압축은 값의 의미를 바꾸지 않는다. 같은 값을 넣고 빼면 똑같은 `DB_VALUE`(CUBRID 내부 값 표현) 와 똑같은 `DISK_SIZE` 가 나와야 한다.

설계 분기 두 가지를 이렇게 정했다. (1) 압축은 타입별 직렬화가 아니라 OOS 경계에서 한다 - 일반 행/인덱스 포맷을 건드리지 않기 위해서다. (2) 복제는 압축을 푼 값이 아니라 압축된 바이트를 그대로 standby 로 보내고 standby 가 푼다 - 전송량을 늘리지 않고, standby 도 일반 읽기와 같은 코드로 풀게 하기 위해서다.

## Specification Changes

- OOS 파일에 저장되는 값 앞에 8바이트 헤더가 붙는다. 구성은 압축 방식 1바이트(없음 / LZ4) + 예약 3바이트 + 원래 크기 4바이트다. 예약 3바이트는 나중에 다른 압축 방식을 넣을 자리다.
- 행 안에 남는 16바이트 포인터(`OR_OOS_INLINE_SIZE`, OOS OID 8바이트 + 길이 8바이트) 와 가변 컬럼 오프셋 표(VOT) 의 플래그 비트는 바뀌지 않는다.
- 압축해도 안 줄어드는 값은 그냥 비압축으로 저장하되, 헤더 8바이트만큼은 커진다. OOS 대상은 원래 큰 값이라 이 8바이트는 무시할 수준이다.
- OOS 값의 저장/전송 포맷이 바뀌므로 기존 OOS 데이터와는 호환되지 않는다. feat/oos 는 아직 출시 전 개발 브랜치라 마이그레이션 대상이 없다.
- 사용자가 보는 SQL 동작이나 문법은 그대로다. 압축은 내부 저장 최적화일 뿐이다.
- sysprm 을 추가한다면 매뉴얼에 `oos_enable_compression` 항목이 필요하다: `TBD - 합의 미확인`.

## Implementation

쓰기 - `heap_attrinfo_insert_to_oos` (`src/storage/heap_file.c`):

```
값을 직렬화 -> image (크기 L_u)
  |
  +-> 압축 대상 타입이고, 압축 설정 ON 이고, L_u >= OOS_MIN_COMPRESS_LEN(255) 이면:
  |     LZ4 로 압축 -> 결과 크기 L_c
  |     이득 마진 충족 시 채택: L_c + OOS_COMP_MIN_GAIN(8) <= L_u
  |       (8바이트 헤더는 압축/비압축 양쪽에 똑같이 붙어 비교에서 빠진다.
  |        이 마진은 매 읽기마다 드는 압축 해제 CPU 를 정당화하는 최소 절감량)
  |
  +-> [8B 헤더 | 압축본 또는 원본] 을 oos_insert 로 저장
  +-> 행에 남기는 길이 = 8B + 실제 저장 바이트 (oos_insert 에 넘긴 크기와 같아야 함)
```

읽기 - `heap_attrvalue_read_oos_inline` (`src/storage/heap_file.c`):

```
oos_read 로 [8B 헤더 | 저장 바이트] 를 버퍼에 읽음
  |
  +-> 헤더가 "압축 없음": 헤더 8B 를 걷어내고(버퍼 앞으로 memmove) 원래 크기로 맞춤
  +-> 헤더가 "LZ4": 원래 크기만큼 새 버퍼 할당해서 압축 해제, 읽기 버퍼는 해제
```

조심해야 할 곳:

- **`oos_read` 의 길이 약속**: `oos_read` 는 "넘겨받은 버퍼 크기 == 저장된 바이트 수" 여야 한다고 단언(assert)한다. 그래서 행에 남기는 길이는 압축된 실제 크기와 같아야 하고, 원래 크기는 행이 아니라 8바이트 헤더 안에 적어야 한다.
- **읽기 버퍼 소유권**: `heap_attrvalue_read_oos_inline` 에서 `raw->data` 는 "데이터 위치" 이면서 동시에 "나중에 해제할 메모리 시작점" 이다 (호출자는 `raw->data != oos_scratch` 일 때 `recdes_free_data_area` 로 해제). 그래서 비압축일 때 포인터만 헤더 8바이트 뒤로 옮기면 안 된다(해제 시작점이 어긋난다). 데이터를 앞으로 당기는 `memmove` 를 써야 한다. 압축일 때는 새 메모리에 풀고, 읽기 버퍼를 해제한 뒤 `raw->data` 를 새 메모리 시작점으로 둔다. 같은 버퍼 안에서 푸는 것(in-place) 은 금지 - LZ4 는 입력과 출력이 겹치면 안 된다.
- **임시 버퍼 수명**: 쓰기 쪽 압축용 임시 버퍼는 성공이든 실패(`error_oos`) 든 모든 경로에서 `free_and_init` 으로 해제하고, `recdes.data` 와 같은 메모리로 묶지 않는다.
- **읽는 곳이 여러 군데 (CBRD-26756 조사 후 발견된 핵심 위험)**: 복제 적용기(applier) `la_resolve_oos_value_for_sql_log` (`src/transaction/log_applier.c`) 가 복제 스트림에서 받은 OOS 바이트(`entry->data`) 를 직접 `data_readval` 한다. 일반 조회 경로를 안 거친다. 이 경로가 8바이트 헤더를 안 읽고 안 풀면, 압축본은 깨진 값으로, 비압축본조차 헤더 8바이트가 값 앞에 섞여 깨진 값으로 standby 에 반영된다. 기존 길이 검사(`entry->length != oos_length`) 는 둘 다 같은 길이라 이걸 못 잡는다. 그래서 헤더 포맷과 푸는 코드를 `oos_file` 공유 모듈로 빼고, 이 경로도 같은 코드를 쓰게 고친다. 향후 CDC/flashback 의 OOS 복원 경로도 같은 코드를 거쳐야 하며, 아직 없는 지점에는 `// TODO(CBRD-26881):` 를 남긴다.
- **압축 실패 처리**: `cubcompress::compress` 가 0 이하를 반환하면 내부에서 `er_set` 으로 에러가 이미 찍혔을 수 있다. 비압축으로 넘어가기 전에 `er_clear` 로 그 잔여 에러를 지운다 (성공했지만 이득이 없어 비압축으로 가는 경우와는 구분).
- **복구(recovery) 무영향**: redo/undo 로그에는 압축이 끝난 바이트(헤더 포함) 가 그대로 기록되므로, 복구 때 같은 바이트가 재생돼 결과가 달라지지 않는다. 압축은 로깅보다 앞단에서 이미 끝나 있다.

## Acceptance Criteria

- [ ] VARBIT/JSON/SET/MULTISET/SEQUENCE/VARNCHAR OOS 컬럼이 압축 저장되고, 넣고 빼면 값과 `DISK_SIZE` 가 압축 전과 같다.
- [ ] VARCHAR/BLOB/CLOB 는 동작이 안 바뀐다.
- [ ] 압축해도 안 줄어드는 값은 비압축으로 저장되고(헤더 8바이트만 추가), 정상 복원된다.
- [ ] 한 OOS 페이지를 넘는 큰 값(다중 chunk)도 압축 후 chain 으로 정상 저장/복원된다.
- [ ] 복제 적용기(`la_resolve_oos_value_for_sql_log`) 가 헤더를 읽고 풀어, 압축/비압축 OOS 값을 standby 에 똑같이 복원한다.
- [ ] crash 후 복구해도 OOS 값이 정상 복원된다 (redo/undo 가 같은 바이트 재생).
- [ ] 헤더 읽기/쓰기가 공유 함수로 빠지고, 아직 없는 reader(CDC/flashback) 경로에 `TODO(CBRD-26881)` 가 남는다.

## Definition of done

- [ ] 위 Acceptance Criteria 충족
- [ ] QA 통과 (OOS 적재 검증은 debug 빌드의 `oos.log` 로 확인)
- [ ] 문서/매뉴얼 반영 (sysprm 추가 시)

## 참고 코드

| 구성 요소 | 파일 | 용도 |
|---|---|---|
| `heap_attrinfo_insert_to_oos` | `src/storage/heap_file.c` | OOS 저장 진입점 (압축 추가 지점) |
| `heap_attrinfo_dbvalue_to_recdes` | `src/storage/heap_file.c` | 값을 디스크 바이트로 직렬화 |
| `heap_attrvalue_read_oos_inline` | `src/storage/heap_file.c` | OOS 읽기 (복원 추가 지점) |
| `oos_should_compress` / OOS_COMP_HEADER put/get | `src/storage/heap_file.c` | 압축 대상 타입 판정, 8B 헤더 직렬화 |
| `oos_insert` / `oos_read` / `oos_record_header` | `src/storage/oos_file.cpp`, `oos_file.hpp` | OOS 파일 입출력, 청크 헤더, 공유 코덱 |
| `la_resolve_oos_value_for_sql_log` | `src/transaction/log_applier.c` | 복제 적용기의 OOS reader |
| `cubcompress::compress` / `decompress` | `src/base/compressor.hpp` | LZ4 코덱 |
| `pr_do_db_value_string_compression` | `src/object/object_primitive.c` | VARCHAR 전용 기존 LZ4 진입점 |
| `OR_OOS_INLINE_SIZE`, `OR_IS_OOS` | `src/base/object_representation.h` | 행에 남는 OOS 포인터 크기, VOT 플래그 |

## Remarks

- 부모: CBRD-26583. 선행 조사: CBRD-26756 (타입별 자동 압축 여부 정리).
- 구현 WIP 가 브랜치 `cbrd-26756-oos-compression` 에 있다 (`heap_file.c` 쓰기/읽기, `oos_file.hpp` 공유 코덱, `log_applier.c` 적용기 연동).
- 미결정: 압축 설정의 sysprm 화 여부 (`oos_enable_compression`).
