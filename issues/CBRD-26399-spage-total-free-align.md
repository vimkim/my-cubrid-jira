# [SPAGE] slotted page 정렬 회계 결함 주장 재검증과 종료 요청

**한 줄 요약**: 2025-11에 이 이슈가 제기한 "slotted page가 정렬을 무시해 여유 공간을 크게 보고하고 레코드가 slot 영역을 침범할 수 있다"는 주장을 현재 develop에서 다시 검증한 결과 결함이 없었으므로, 근거를 남기고 코드 수정 없이 종료하자는 이슈다.

## Issue Triage

**이슈 수행 목적**: slotted page의 여유 공간 계산이 정렬 때문에 실제보다 크게 보고되는 결함이 있는지 판정하고, 그 근거를 이슈에 남긴다.

**이슈 수행 이유**: 원래 설명은 `spage_initialize()` 의 `total_free` 올림과 `spage_max_record_size()` 의 정렬 미반영 때문에 경계 길이 레코드가 slot 배열과 겹칠 수 있다고 보고, 두 함수의 식 변경과 assertion 추가를 제안했다. 2026-10-01 코멘트는 debug 빌드 실측으로 이를 반박하고 Close를 요청했다. 두 주장이 충돌한 채 열려 있어 현재 develop에서 소스 추적과 경계 실험으로 다시 검증했다.

**영향**: 검증 결과 사용자 데이터와 페이지 무결성에 미치는 영향은 없다. 반대로 옛 설명의 제안을 그대로 적용하면 heap의 최대 slotted 레코드 길이가 이유 없이 4바이트 줄고, 제안한 정렬 assertion은 catalog 같은 정렬 8 페이지의 정상 상태를 오류로 판정한다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 배경

slotted page는 페이지 앞쪽에 32바이트 `SPAGE_HEADER` 를 두고, 레코드를 그 뒤에 정렬된 offset으로 쌓는다. 페이지 끝에서는 4바이트 `SPAGE_SLOT` 배열이 앞으로 자란다. 정렬 단위는 페이지마다 고정이다. heap, B+tree, extendible hash 페이지는 4바이트, catalog 페이지는 8바이트다. 레코드 하나는 `길이 + 정렬 낭비` 를 차지하고, 새 slot이 필요하면 4바이트를 더 쓴다.

slotted page가 실제로 쓰는 크기는 IO 페이지에서 예약 영역 40바이트를 뺀 `DB_PAGESIZE` 다. 4K/8K/16K 페이지에서 각각 4056/8152/16344바이트이고 모두 8의 배수다.

### 원래 주장과 반박

- 설명 (2025-11-24) 은 두 가지를 주장했다. 하나는 `spage_initialize()` 가 `total_free = DB_ALIGN (SPAGE_DB_PAGESIZE - sizeof (SPAGE_HEADER), alignment)` 로 올림하므로 가용량을 부풀린다는 것이다. 다른 하나는 `spage_max_record_size()` 가 정렬을 무시하므로 그 길이의 레코드를 넣으면 정렬 낭비가 slot 배열과 겹친다는 것이다. 예시 계산은 페이지 크기를 16384로 두었다.
- 2026-07-29 보고자 코멘트는 16K에서는 발생하지 않고 8K, 4K에서 의심된다고 적었다.
- 2026-10-01 코멘트는 debug 빌드 실측으로 세 페이지 크기 모두에서 재현되지 않았다고 보고했다. `spage_max_record_size()` 는 사전 거절 기준이고 실제 판정은 `spage_find_empty_slot()` 이 정렬 낭비와 slot 크기를 더해 한다는 점, heap이 이 값을 정렬 4에서 쓴다는 점, 제안한 정렬 assertion이 성립하지 않는다는 점을 지적하고 Close를 요청했다.

### 검증 결과

| 주장 | 판정 | 근거 |
| --- | --- | --- |
| 초기화의 `DB_ALIGN` 올림이 `total_free` 를 부풀린다 | 반증 | 헤더 32와 `DB_PAGESIZE` 가 모두 8의 배수라 정렬 1/2/4/8 모두에서 `total_free == DB_PAGESIZE - 32` 이고 정확한 값과 같다 |
| 초기화 직후와 compact 직후의 `total_free` 가 달라진다 | 반증 | 두 식이 같은 값을 낸다. 72만 회 무작위 연산 동안 `total_free` 와 실제 레코드 배치가 매번 일치했다 |
| `spage_max_record_size()` 길이의 레코드가 slot 영역과 겹친다 | 반증 | 정렬 8에서 그 길이는 `SP_DOESNT_FIT` 으로 거절되고, 4바이트 짧은 길이가 최대다. 설명의 16384 가정에서도 slot 4바이트를 더하면 거절된다 |
| catalog, extendible hash가 과대 보고된 공간을 믿는다 | 반증 | 이들은 정렬을 반영하는 `spage_max_space_for_new_record()` 를 쓰고, 실험에서 그 길이는 항상 실제로 들어갔다. catalog에서 `spage_max_record_size()` 를 쓰는 유일한 변수 `catalog_Max_record_size` 는 대입 뒤 읽히지 않는다 |
| `total_free` 가 항상 정렬 배수라는 assertion을 추가한다 | 성립하지 않음 | slot이 4바이트씩 늘고 줄어 정렬 8 페이지에서 8의 배수가 아닌 상태가 75,162회 관측되었다 |
| `offset_to_free_area + cont_free + 4 * num_slots <= DB_PAGESIZE` assertion을 추가한다 | 이미 있음 | `spage_check()` 가 같은 조건을 검사한다 |
| 8K, 4K에서만 문제가 의심된다 | 반증 | 세 페이지 크기의 산술과 실험 결과가 같은 패턴이다 |

빈 페이지에서 계산하고 실험으로 확인한 값은 다음과 같다. 2026-10-01 코멘트의 실측과 같다.

| IO 페이지 | `DB_PAGESIZE` | 빈 페이지 `total_free` | `spage_max_record_size()` | 실제 최대 길이 (정렬 1/2/4) | 실제 최대 길이 (정렬 8) |
| --- | --- | --- | --- | --- | --- |
| 4K | 4056 | 4024 | 4020 | 4020 | 4016 |
| 8K | 8152 | 8120 | 8116 | 8116 | 8112 |
| 16K | 16344 | 16312 | 16308 | 16308 | 16304 |

`spage_max_record_size()` 는 정렬을 모르는 사전 상한이다. 삽입과 갱신은 이 값보다 긴 길이를 바로 거절한다. 그보다 짧은 길이는 `spage_find_empty_slot()`, `spage_find_empty_slot_at()`, `spage_check_updatable()`, `spage_put_helper()` 가 정렬 낭비와 필요한 slot 크기를 더해 `total_free` 와 다시 비교한다. 따라서 정렬 8 페이지에서 이 값이 4바이트 큰 것은 어떤 길이를 바로 거절할지에만 영향을 주고, 페이지 배치에는 영향을 주지 않는다.

헤더 크기가 8의 배수가 아니게 바뀌면 원래 설명의 첫 번째 우려는 실제가 된다. 예를 들어 헤더가 36바이트면 16K 정렬 8 페이지에서 `total_free` 가 8바이트 크게 잡힌다. 그러나 `SPAGE_HEADER` 는 모든 slotted page에 기록되는 디스크 포맷이고, 헤더 정의의 주석도 8바이트 정렬을 요구한다. 그런 변경은 볼륨 변환을 동반해야 하므로 현재 식을 고칠 근거가 되지 않는다.

## Test Build

- 소스는 CUBRID develop `e64a04a79a5842827a124b3f8313516d0da2594c` 이다. 2026-11-05의 develop `2362424f25bcebd1bd9733bddd59a993e2852ac5` 에서도 `slotted_page.c`, `slotted_page.h`, `memory_alloc.h`, `storage_common.c` 는 같다.
- 빌드는 GCC 11.5.0 Debug (`-O0`) 이고, 엔진 소스는 수정하지 않았다.

## Repro

검증 하네스는 수정하지 않은 `slotted_page.c` 의 SA 모드 객체에 링크해 공개 API (`spage_initialize`, `spage_insert`, `spage_update`, `spage_delete`, `spage_vacuum_slot`, `spage_max_space_for_new_record`, `spage_check`) 를 메모리 페이지에서 직접 호출한다. page buffer와 로그 함수는 최소 stub으로 바꾸었고, 저장 공간 예약은 끄고 실행했다. 하네스와 원본 결과는 [my-cubrid-docs cbrd-26399](https://github.com/vimkim/my-cubrid-docs/tree/main/cbrd-26399) 에 있다.

1. 빈 페이지 경계: IO 페이지 4K/8K/16K와 정렬 1/2/4/8의 각 조합에서 빈 페이지에 길이 `spage_max_record_size() - 24` 부터 `+ 8` 까지 삽입하고, 길이 1 레코드를 같은 길이로 갱신한다.
2. 무작위 작업 부하: 같은 조합과 anchor 종류 3개 (`ANCHORED`, `ANCHORED_DONT_REUSE_SLOTS`, `UNANCHORED_KEEP_SEQUENCE`) 마다 삽입, 삭제, 갱신, vacuum을 20,000회 실행한다. 매 연산 뒤 레코드와 slot 배열의 겹침, 레코드끼리의 겹침, 페이지 경계 밖 쓰기, `total_free` 와 실제 배치의 일치, `spage_check()` 결과를 검사한다.

아래는 프로젝트 `debug` 프리셋으로 같은 단계를 옮긴 명령이다. 이번 실행은 같은 소스에 GCC Debug 개인 프리셋을 써서 했고, 아래 명령 그대로는 실행하지 않았다.

```bash
# CUBRID 소스 루트에서 실행한다. g++, ninja, python3 가 필요하다.
git clone https://github.com/vimkim/my-cubrid-docs.git /tmp/my-cubrid-docs
cmake --preset debug
ninja -C build_preset_debug sa/CMakeFiles/cubridsa.dir/__/src/storage/slotted_page.c.o
/tmp/my-cubrid-docs/cbrd-26399/evidence/run-probe.sh build_preset_debug /tmp/cbrd-26399-probe 20000
```

## Expected Result

- 정렬 8 페이지에서 `spage_max_record_size()` 길이의 삽입과 갱신은 `SP_DOESNT_FIT` 으로 거절된다.
- 받아들여진 모든 레코드는 slot 배열과 겹치지 않고, `total_free` 는 실제 배치와 일치한다.

## Actual Result

- 기대와 같다. 정렬 1/2/4에서는 `spage_max_record_size()` 길이가 들어가고, 정렬 8에서는 거절되며 4바이트 짧은 길이가 최대다.
- 36개 조합 720,000회 연산에서 기하 검사 실패는 0회였다.
- `spage_max_space_for_new_record()` 가 돌려준 길이는 운영 코드가 쓰는 anchor 종류 (`ANCHORED_DONT_REUSE_SLOTS`, `UNANCHORED_KEEP_SEQUENCE`) 에서 한 번도 실패하지 않았다.

## Additional Information

- 이 검증에서 같은 종류의 산술 차이를 질의 정렬 모듈에서 하나 찾았다. `external_sort.c` 는 별도 slotted page 구현을 쓰고, `SORT_MAXREC_LENGTH` 가 정렬 낭비를 빼지 않아 실제 최대 길이보다 2바이트 크다. 두 길이 (`DB_PAGESIZE - 23`, `DB_PAGESIZE - 22`) 는 사전 검사를 통과한 뒤 빈 페이지 삽입에서 실패할 수 있다. 그러나 정렬 입력 레코드는 모두 `qfile_make_sort_key()` 가 만들고 길이가 항상 4의 배수이므로 현재 도달할 수 없다. B+tree 정렬 복사본은 이미 정렬 낭비를 반영한 `BTSORT_MAXREC_LENGTH` 를 쓴다. 이 이슈의 범위가 아니며, 정렬 레코드 길이 규칙이 바뀔 때 함께 보는 것이 적절하다.
- 옛 설명의 옵션 1 (`spage_max_record_size()` 를 `MAX_ALIGNMENT` 기준으로 내림) 은 정렬 4 heap 페이지에서 정확한 값을 4바이트 줄인다. 도달 가능한 실패를 고치지 않으므로 적용할 이유가 없다.

## Triage Request

- 코드 수정 없이 결함 아님으로 종료할지 결정해 달라.
- `SPAGE_HEADER` 크기의 정렬 요구를 컴파일 시점 검사로 바꾸는 하드닝을 원하면 별도 이슈로 다룰 수 있다. 이 변경은 동작을 바꾸지 않는다.
