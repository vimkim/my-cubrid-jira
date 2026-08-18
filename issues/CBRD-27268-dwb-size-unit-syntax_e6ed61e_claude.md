# [PGBUF] double_write_buffer_size에 크기 단위 문법을 지원한다

## Issue Triage

**이슈 수행 목적**: `double_write_buffer_size` 가 다른 크기 파라미터와 같은 문법(`0`, byte 정수, `512K`, `2M`)을 받아들이게 한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | `double_write_buffer_size` 는 바이트 값을 받는 크기 파라미터인데 `PRM_INTEGER` 이면서 `PRM_SIZE_UNIT` 플래그가 없다(`system_parameter.c:4340-4351`). 그래서 `2M` 같은 단위 표기가 파싱 단계에서 거부되고, CUBRID 의 conf 로더는 값 오류를 경고로 넘기지 않고 로드 전체를 실패시키므로 서버가 기동을 중단한다. 반면 byte 값을 받는 다른 크기 파라미터는 예외 없이 `PRM_BIGINT` + `PRM_SIZE_UNIT` 조합이라 같은 표기를 정상 처리한다 — `db_volume_size`, `log_volume_size`, `max_subquery_cache_size` 등. |
| **TO-BE (목표 상태 / 기대 동작)** | 아래 대비대로, 다른 크기 파라미터와 같은 입력 문법을 받는다. 값의 의미(0 = DWB 비활성, 상한 32 MiB, 2의 거듭제곱 반올림)는 그대로 둔다. |
| **영향** | 고객 장애 — 문법 오류가 경고가 아니라 서버 기동 실패로 나타난다. `cubrid server start` 는 실패 원인을 보여주지 않고 start timeout 으로만 끝나므로, 원인이 conf 한 줄의 단위 표기라는 사실을 찾는 데 시간이 든다. `data_buffer_size=16M` 이 동작하는 것을 본 사용자가 같은 문법을 DWB 에 쓰는 것은 자연스러운 오사용이다. |

AS-IS / TO-BE 입력 대비:

| conf 입력 | 현재 동작 | 목표 동작 |
|---|---|---|
| `double_write_buffer_size=2097152` | 2 MiB 로 해석 (정상) | 동일 |
| `double_write_buffer_size=2M` | 서버 기동 실패 | 2097152 바이트로 해석 |
| `double_write_buffer_size=512K` | 서버 기동 실패 | 524288 바이트로 해석 |
| `double_write_buffer_size=0` | DWB 비활성 (정상) | 동일 |

**이슈 수행 방안**:

- 파라미터 정의를 `PRM_BIGINT` + `PRM_SIZE_UNIT` 로 바꿔 다른 byte 단위 파라미터와 같은 패턴에 맞춘다. 상·하한(0 ~ 32 MiB)은 현행 유지한다.
- `PRM_INTEGER` 에 `PRM_SIZE_UNIT` 만 붙이는 방식은 쓸 수 없다 — `PRM_DIFFER_UNIT` 이 함께 없으면 `sysprm_generate_new_value` 가 `:8920-8923` 에서 무조건 `PRM_ERR_BAD_VALUE` 를 반환한다.
- 값 표시 형식이 바뀌는 부수 효과가 있으므로 Specification Changes 에 명시한다.

------------------------------------------------------------------------

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/base/system_parameter.c` 의 `PRM_ID_DWB_SIZE` 항목 하나와, 그 값을 읽는 유일한 소비자인 `src/storage/double_write_buffer.cpp:775`. 디스크 형식과 DWB 동작 자체는 바뀌지 않는다. 값 표시 경로(`SHOW PARAMETERS`, `cubrid paramdump`)의 출력 문자열이 `2097152` 에서 `2.0M` 형태로 바뀌므로 이 파라미터를 파싱하는 테스트와 운영 스크립트가 영향을 받는다.
- 부모 EPIC 은 CBRD-27193 이고, 이 이슈가 소유하는 결함은 D5(크기 단위 문법 거부와 그로 인한 기동 실패)다.

------------------------------------------------------------------------

## Description

DWB(Double Write Buffer — 데이터 page 를 원래 위치에 쓰기 전에 별도 파일에 사본을 먼저 기록해 torn write 로부터 보호하는 장치)의 크기는 `double_write_buffer_size` 로 바이트 단위로 지정한다. 기본값은 2 MiB 이고 상한은 32 MiB, 0 은 DWB 비활성을 뜻한다.

문제는 이 파라미터가 크기 파라미터인데도 크기 단위 문법을 지원하지 않는 것이고, 더 나쁜 것은 그 거부가 조용하지 않다는 점이다. CUBRID 의 conf 로더는 잘못된 값을 만나면 그 파라미터만 건너뛰지 않고 로드 전체를 실패시킨다.

### 재현 절차

```bash
# 1. conf 에 크기 단위 표기로 값을 지정
cat >> $CUBRID/conf/cubrid.conf <<'EOF'
double_write_buffer_size=2M
EOF

# 2. 서버 기동 시도
cubrid server start demodb
```

`cubrid server start` 는 실패 원인을 그대로 보여주지 않고 기동 대기 후 timeout 으로 끝난다. 실제 원인은 서버 프로세스의 stderr 와 에러 로그에 남는다.

```
The 'double_write_buffer_size' parameter at line <N> in file '<CUBRID>/conf/cubrid.conf' : Value type does not match parameter type.
ERROR CODE = -839  ... "double_write_buffer_size": Unknown system parameter or bad value.
ERROR CODE = -1076 ... Could not load system parameter.
```

같은 파일에서 `data_buffer_size=16M` 은 정상 처리된다. 두 파라미터의 문법이 다르다는 사실은 어디에도 표시되지 않는다.

기대 동작은 `2M` 이 2097152 바이트로 해석되어 서버가 정상 기동하는 것이다.

### 값이 거부되는 경로

```
prm_load_by_section ()                                    system_parameter.c:6536
  └ prm_set (prm, "2M", true)                                          :6740
       └ sysprm_generate_new_value ()                                  :8750
            case PRM_INTEGER:                                          :8888
              ├ if (PRM_HAS_SIZE_UNIT (prm))     → 플래그 없음 → 미진입 :8899
              ├ else if (PRM_HAS_TIME_UNIT (prm))→ 플래그 없음 → 미진입 :8925
              └ else                                                   :8953
                   parse_int (&val, "2M", 10)                          :8957
                   ★ 실패 → return PRM_ERR_BAD_VALUE                   :8959-8962
  ← error != NO_ERROR                                                  :6741
       prm_report_bad_entry () → stderr + ER_PRM_BAD_VALUE(-839)       :6743
       return error                                                    :6744
prm_read_and_parse_ini_file () → 그대로 반환                            :6776, :6810
sysprm_load_and_init_internal () → 그대로 반환                          :6298-6301
boot_restart_server ()                                        boot_sr.c:2029
  ★ ER_BO_CANT_LOAD_SYSPRM(-1076) → goto error, 기동 중단              :2031-2033
```

`PRM_INTEGER` 에 `PRM_SIZE_UNIT` 만 추가하는 것은 해결책이 되지 못한다. 그 조합은 `:8899` 로 들어간 뒤 `PRM_DIFFERENT_UNIT` 이 거짓이라 `:8920-8923` 의 `else` 로 빠져 무조건 `PRM_ERR_BAD_VALUE` 를 반환한다. `PRM_DIFFER_UNIT` 을 함께 붙이면 `PRM_ADJUST_FOR_SET_BIGINT_TO_INTEGER`(`:836-844`)가 `prm->set_dup` 함수 포인터를 호출하므로 변환 함수 한 쌍을 새로 만들어야 한다. 그런데 `double_write_buffer_size` 는 저장 단위가 이미 바이트라 변환할 것이 없다. `PRM_DIFFER_UNIT` 은 `data_buffer_size` 처럼 "입력은 바이트, 저장은 page 수" 인 파라미터를 위한 장치다(`:1211-1221`, `prm_size_to_io_pages` / `prm_io_pages_to_size`).

### 크기 파라미터 문법 현황

`PRM_SIZE_UNIT` 을 가진 파라미터를 전수 대조한 결과, 조합은 정확히 두 종류로 갈린다.

| 조합 | 저장 단위 | 예 | `2M` 입력 |
|---|---|---|---|
| `PRM_BIGINT` + `PRM_SIZE_UNIT` | 바이트 | `db_volume_size`(`:3288`), `log_volume_size`(`:3300`), `thread_stacksize`(`:1612`), `max_subquery_cache_size`(`:5029`), `max_agg_hash_size`(`:3506`), `max_hash_list_scan_size`(`:3553`), `group_concat_max_len`(`:2040`), `ib_task_memsize`(`:4497`), `backup_volume_max_size_bytes`(`:1658`) | 정상 |
| `PRM_INTEGER` + `PRM_SIZE_UNIT` + `PRM_DIFFER_UNIT` + 변환 함수 쌍 | 바이트가 아닌 단위(page 수 등) | `data_buffer_size`(`:1211`), `log_buffer_size`(`:1380`), `max_flush_size_per_second`(`:1887`) 등 | 정상 |
| `PRM_INTEGER`, 플래그 없음 | 바이트 | `double_write_buffer_size`(`:4340`) | **거부** |

즉 `double_write_buffer_size` 만 크기 파라미터인데 어느 패턴에도 속하지 않는다. 저장 단위가 바이트이므로 첫 번째 패턴이 정확한 짝이다.

> **요지**: 다른 바이트 단위 파라미터는 예외 없이 `PRM_BIGINT` + `PRM_SIZE_UNIT` 이다. 이 파라미터를 그 패턴으로 옮기면 새 파싱 코드나 변환 함수 없이 문법이 통일된다.

## Specification Changes

### 입력 문법

허용 단위는 `util_size_string_to_byte`(`util_common.c:1123`)와 `util_size_to_byte`(`:1005`)가 정하며, 대소문자를 구분하지 않는다.

| 입력 형태 | 해석 |
|---|---|
| 접미사 없는 수 | 바이트 |
| `B` | 바이트 |
| `K`, `KB` | KiB (x 1024) |
| `M`, `MB` | MiB (x 1024^2) |
| `G`, `GB` 및 그 이상 | 문법으로는 허용되나 상한 32 MiB 를 넘어 `PRM_ERR_BAD_RANGE` |

### 값 처리 규칙 (변경 없음, 명시만)

파싱을 통과한 값은 `dwb_load_buffer_size`(`double_write_buffer.cpp:769-785`)가 아래처럼 보정한다. 지금도 같은 규칙이지만 매뉴얼에 드러나 있지 않아 함께 문서화한다.

| 입력 값 | 최종 값 | 근거 |
|---|---|---|
| 0 | DWB 비활성 | `:776-780` |
| 0 초과 512 KiB 미만 | 512 KiB (`DWB_MIN_SIZE`) | `dwb_power2_ceil` `:737-740` |
| 512 KiB 이상 32 MiB 이하이면서 2의 거듭제곱이 아님 | 다음 2의 거듭제곱으로 올림 | `:745-755` |
| 32 MiB 초과 | 파라미터 상한 검사에서 `PRM_ERR_BAD_RANGE` (`DWB_MAX_SIZE` 도 32 MiB) | `system_parameter.c:4347`, `double_write_buffer.cpp:53` |

즉 `600K` 를 지정하면 실제로는 1 MiB 가 되고, 이 반올림은 경고 없이 일어난다. 매뉴얼에 반올림 규칙을 적는다.

### 출력 표시 변경

`PRM_SIZE_UNIT` 이 붙으면 값 출력이 `util_byte_to_size_string` 을 거친다(`system_parameter.c:7848-7852`). `SHOW PARAMETERS` 와 `cubrid paramdump` 의 표시가 `double_write_buffer_size=2097152` 에서 `double_write_buffer_size=2.0M` 형태로 바뀐다. 다른 크기 파라미터와 같은 표시 형식이 되므로 일관성은 개선되지만, 이 값을 정수로 파싱하는 기존 테스트와 스크립트는 갱신이 필요하다.

## Implementation

### 변경 지점

| 파일 / 라인 | 변경 |
|---|---|
| `system_parameter.c:4342` | `static_flag` 에 `PRM_SIZE_UNIT` 추가 → `(PRM_FOR_SERVER \| PRM_USER_CHANGE \| PRM_SIZE_UNIT)` |
| `system_parameter.c:4343` | `PRM_INTEGER` → `PRM_BIGINT` |
| `system_parameter.c:4345-4348` | 기본값·상한·하한의 공용체 멤버를 `.i` 에서 `.bi` 로 변경. 값 자체는 유지 (2 MiB / 2 MiB / 32 MiB / 0) |
| `double_write_buffer.cpp:775` | `prm_get_integer_value (PRM_ID_DWB_SIZE)` → `prm_get_bigint_value (PRM_ID_DWB_SIZE)`. 대상 변수가 `unsigned int *` 이므로 명시적 캐스팅을 붙인다. 상한이 32 MiB 라 `unsigned int` 범위를 넘지 않는다 |

`prm_get_bigint_value` 는 `system_parameter.h:831`, `:949` 에 이미 선언되어 있으므로 새 접근자를 만들 필요는 없다. `PRM_ID_DWB_SIZE` 를 참조하는 다른 지점은 없다 — 전체 소스에서 이 파라미터를 읽는 곳은 `double_write_buffer.cpp:775` 한 곳이다.

### 후보안 비교

| 순위 | 후보 | 권장 이유 / 고려사항 |
|---|---|---|
| 1 | `PRM_BIGINT` + `PRM_SIZE_UNIT` 로 전환 | 다른 바이트 단위 파라미터 전부와 동일한 패턴이라 파싱·표시·범위 검사가 모두 기존 코드로 처리된다. 변경량이 5줄 수준이다. 값 표시 형식이 바뀌는 것이 유일한 부수 효과다 |
| 2 | 문법은 그대로 두고 에러 메시지만 개선 | 기동 실패 자체는 남는다. 사용자가 원인을 빨리 찾을 수 있게 되는 것뿐이라 근본 해결이 아니다. 다른 크기 파라미터와의 비일관성도 남는다 |
| 3 | `PRM_INTEGER` + `PRM_SIZE_UNIT` + `PRM_DIFFER_UNIT` + 항등 변환 함수 쌍 | 저장 단위가 이미 바이트라 변환 함수가 아무 일도 하지 않는 껍데기가 된다. `PRM_DIFFER_UNIT` 의 설계 의도와 맞지 않는다 |

### 검증

```bash
# 단위 문법 수용
echo 'double_write_buffer_size=2M' >> $CUBRID/conf/cubrid.conf
cubrid server start demodb
csql -u dba -S demodb -c "SHOW PARAMETERS" | grep double_write_buffer_size

# 하한 미달 반올림 (512K 로 올라가야 한다)
# conf 값을 300K 로 바꾼 뒤 재기동하고 paramdump 로 확인
cubrid paramdump demodb | grep double_write_buffer_size

# 상한 초과 거부 (기동 실패 + BAD_RANGE)
# conf 값을 64M 로 바꾼 뒤 재기동 시도

# 비활성 값 유지
# conf 값을 0 으로 바꾼 뒤 재기동하고 DWB 파일이 생성되지 않음을 확인

# 기존 정수 표기 하위 호환
# conf 값을 2097152 로 바꾼 뒤 재기동하고 2M 지정과 동일하게 동작함을 확인
```

## Acceptance Criteria

- [ ] `double_write_buffer_size=2M`, `=512K`, `=2097152`, `=0` 네 표기가 모두 서버 기동을 막지 않는다.
- [ ] `2M` 과 `2097152` 가 동일한 DWB 크기로 동작한다.
- [ ] 32 MiB 초과 값은 `PRM_ERR_BAD_RANGE` 로 거부되고, 상한이 `DWB_MAX_SIZE` 와 일치한다.
- [ ] `0` 은 DWB 비활성으로 계속 동작한다.
- [ ] `SHOW PARAMETERS` 와 `cubrid paramdump` 의 표시 형식 변경이 문서와 관련 테스트에 반영된다.
- [ ] 512 KiB 미달 값과 2의 거듭제곱이 아닌 값의 반올림 규칙이 매뉴얼에 기술된다.

## Definition of done

- [ ] 위 Acceptance Criteria 충족
- [ ] QA 통과 (파라미터 표기를 검증하는 기존 shell 테스트 기대값 갱신 포함)
- [ ] 매뉴얼의 `double_write_buffer_size` 설명에 허용 단위와 반올림 규칙 반영

## 참고 코드

- `src/base/system_parameter.c:4340-4351` — `PRM_ID_DWB_SIZE` 파라미터 정의
- `src/base/system_parameter.c:8750`, `:8888-9028` — `sysprm_generate_new_value` 의 `PRM_INTEGER` / `PRM_BIGINT` 파싱 분기
- `src/base/system_parameter.c:6536-6749` — `prm_load_by_section`, 값 오류 시 로드 전체 실패
- `src/base/system_parameter.c:7848-7852` — `PRM_SIZE_UNIT` 값의 표시 경로
- `src/base/system_parameter.c:1211-1221` — `data_buffer_size` 의 `PRM_DIFFER_UNIT` 패턴 (대조용)
- `src/executables/util_common.c:1005-1163` — `util_size_to_byte`, `util_size_string_to_byte` 허용 단위
- `src/storage/double_write_buffer.cpp:732-785` — `dwb_power2_ceil`, `dwb_load_buffer_size`
- `src/storage/double_write_buffer.cpp:52-53` — `DWB_MIN_SIZE`(512 KiB), `DWB_MAX_SIZE`(32 MiB)
- `src/transaction/boot_sr.c:2029-2034` — 파라미터 로드 실패 시 기동 중단

## Remarks

- 부모 EPIC: CBRD-27193
- `double_write_buffer_blocks`(`system_parameter.c:4352-4363`)는 개수 파라미터라 크기 단위 문법 대상이 아니다. 다만 이쪽도 `dwb_power2_ceil` 로 2의 거듭제곱 반올림이 조용히 일어나므로(`double_write_buffer.cpp:808`) 반올림 규칙 문서화는 두 파라미터에 함께 적용하는 편이 낫다.
