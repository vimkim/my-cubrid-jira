# [System Parameter] 크기 단위 파라미터에 0.5, inf, 1e30을 주면 오류 없이 0이 되어, 0을 허용하는 파라미터는 기본 동작이나 기능 끄기로 바뀐다

**한 줄 요약**: PR #8632(CBRD-28062, `oos_trigger_threshold` 파라미터 추가) 리뷰에서 찾은 기존 결함이다. 크기 단위(`4K`, `1M` 등) 파라미터를 읽는 `util_size_string_to_byte ()` 가 `0.5`, `inf`, `1e30` 을 오류 없이 0바이트로 바꾼다. 0을 허용하는 파라미터는 운영자가 잘못된 값을 넣어도 경고 없이 0의 의미(자동값, 기능 끄기)로 동작한다. 이 이슈는 이런 입력을 오류로 거부하는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: 크기 단위 파라미터에 정수 바이트로 나타낼 수 없는 값(1바이트 미만의 소수, 무한대, 표현 범위를 넘는 수, NaN)을 주면, `cubrid.conf` 를 읽을 때나 `SET SYSTEM PARAMETERS` 를 실행할 때 오류로 거부한다.

**이슈 수행 이유**: `util_size_string_to_byte ()` 는 숫자 부분을 `strtod ()` 로 읽고 단위를 곱한 뒤 `(UINT64)` 로 바꾼다. 결과가 `UINT64` 범위 밖인지, 0이 되는지는 검사하지 않는다. 이 함수를 그대로 옮겨 x86-64 gcc 11.5로 실행하면 `0.5`, `inf`, `1e30` 은 모두 성공(반환 0)과 함께 0바이트가 된다. C에서 범위 밖 실수를 정수로 바꾸는 것은 정의되지 않은 동작이라, 다른 컴파일러나 플랫폼에서는 결과가 다를 수 있다. 하한이 0인 파라미터는 이 0이 범위 검사를 통과한다.

**영향**: 아래 파라미터는 잘못된 값이 경고 없이 0으로 설정된다. 운영자는 설정이 무시된 것을 알기 어렵다. `memoize_memory_limit` 과 `max_hash_list_scan_size` 는 0이면 해당 최적화를 쓰지 않는다. `oos_trigger_threshold`(PR #8632, `feature/oos-merge` 대상)는 0이면 자동 목표값을 쓴다. 나머지 크기 단위 파라미터는 0이 하한보다 작아 범위 오류로 거부된다(소스 판독). 이때 오류 메시지는 범위를 말하지만, 실제 원인은 운영자가 쓴 입력의 형식이다. 이런 값을 실제로 설정한 사례는 알려진 것이 없다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 파서 동작

develop `1ecb2e7f37` 기준이다. `feature/oos-merge` 와 PR #8632 head `44dab49185` 의 `util_common.c` 도 같다.

- `util_size_string_to_byte ()`, [util_common.c:1184](https://github.com/CUBRID/cubrid/blob/1ecb2e7f3753e4f9fb4b79b5a421d8dbcc769c08/src/executables/util_common.c#L1184): `val = strtod (size_str, &end);` 는 `inf`, `nan`, 지수 표기, 16진 표기를 모두 숫자로 읽는다. 음수만 거부한다.
- [util_common.c:1209](https://github.com/CUBRID/cubrid/blob/1ecb2e7f3753e4f9fb4b79b5a421d8dbcc769c08/src/executables/util_common.c#L1209): `*size_num = (UINT64) val;` 는 소수점 아래를 버리고, 범위 밖 값은 정의되지 않은 동작으로 바꾼다.
- `sysprm_generate_new_value ()` 는 이 결과로 `prm_check_range ()` 를 한 번 한다([system_parameter.c:9330](https://github.com/CUBRID/cubrid/blob/1ecb2e7f3753e4f9fb4b79b5a421d8dbcc769c08/src/base/system_parameter.c#L9330) 이하). `cubrid.conf` 를 읽는 `prm_set ()` 과 `SET SYSTEM PARAMETERS` 가 모두 이 함수를 거친다.

### 함수 동작 확인 (에뮬레이션)

`util_size_to_byte ()` 와 `util_size_string_to_byte ()` 를 PR #8632 head `44dab49185` 에서 그대로 복사해 작은 프로그램으로 실행했다(x86-64, gcc 11.5.0, `-O0` 과 `-O2` 결과 같음). CUBRID 프로세스로 실행한 결과는 아니다.

| 입력 | 반환 | 결과 바이트 |
|---|---|---|
| `0.5` | 성공 | 0 |
| `inf` | 성공 | 0 |
| `1e30` | 성공 | 0 |
| `nan` | 성공 | 9223372036854775808 (2^63) |
| `1.5` | 성공 | 1 |
| `0x10` | 성공 | 16 |
| `0.5K` | 성공 | 512 (정상) |
| `4K` | 성공 | 4096 (정상) |

### 0이 범위 검사를 통과하는 파라미터

파라미터 정의 표에서 `PRM_SIZE_UNIT` 이 있고 하한이 0인 것을 골랐다(develop `1ecb2e7f37`, 소스 판독).

| 파라미터 | 0의 의미 (사용처) |
|---|---|
| `memoize_memory_limit` | memoize를 쓰지 않는다([query_planner.c:7111](https://github.com/CUBRID/cubrid/blob/1ecb2e7f3753e4f9fb4b79b5a421d8dbcc769c08/src/optimizer/query_planner.c#L7111), `memoize.cpp:955`) |
| `max_hash_list_scan_size` | hash list scan 계획을 포기한다([query_planner.c:11706](https://github.com/CUBRID/cubrid/blob/1ecb2e7f3753e4f9fb4b79b5a421d8dbcc769c08/src/optimizer/query_planner.c#L11706)) |
| `max_subquery_cache_size` | 캐시 항목 수가 0으로 계산된다([subquery_cache.c:305](https://github.com/CUBRID/cubrid/blob/1ecb2e7f3753e4f9fb4b79b5a421d8dbcc769c08/src/query/subquery_cache.c#L305)). 이후 동작은 확인하지 않았다 |
| `max_connect_by_dfs_size` | spill 한도가 내부 최솟값이 된다([query_executor.c:26100](https://github.com/CUBRID/cubrid/blob/1ecb2e7f3753e4f9fb4b79b5a421d8dbcc769c08/src/query/query_executor.c#L26100)) |
| `db_volume_size` | 범위 검사는 통과한다. 사용처에서의 의미는 확인하지 않았다 |
| `index_scan_key_buffer_size` | 범위 검사는 통과한다. `src/` 에 이 값을 읽는 곳이 없다 |
| `generic_vol_prealloc_size` | 폐기된(obsoleted) 파라미터다 |
| `oos_trigger_threshold` | `feature/oos-merge` 대상 PR #8632에서 추가된다. 0이면 자동 목표값(한 페이지에 행 4개가 들어가는 크기)을 쓴다 |

- 이 밖의 크기 단위 파라미터는 하한이 0보다 커서 0이 범위 오류(`PRM_ERR_BAD_RANGE`)로 거부되는 것으로 본다(소스 판독).
- `nan` 은 2^63이 되어 상한이 있는 파라미터에서는 거부된다. 상한이 없는 `memoize_memory_limit` 은 이 값을 받아들이는 것으로 본다(소스 판독).
- `1.5` 처럼 1보다 큰 소수는 소수점 아래만 버려진다. 크기 단위 값으로 큰 영향은 없지만, 입력과 다른 값이 경고 없이 설정되는 것은 같다.

### 관련 이슈

- CBRD-28062: 이 결함을 찾은 PR #8632의 이슈다. 새 파라미터 `oos_trigger_threshold` 도 이 파서를 쓴다.

### ANALYSIS에서 확인할 것

- 거부할 입력의 범위: 1바이트 미만의 양수, 무한대, NaN, `UINT64` 를 넘는 수, 그리고 정수가 아닌 바이트 수를 모두 거부할지.
- 시간 단위 파서 `util_time_string_to_msec ()` 도 `strtod ()` 결과를 정수로 바꾸는지, 같은 문제가 있는지.
- CUBRID 프로세스에서 `SET SYSTEM PARAMETERS 'memoize_memory_limit=inf'` 를 실행한 뒤 `;get` 결과가 0인지 확인한다(아직 실행하지 않았다).
