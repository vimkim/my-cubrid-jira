# [PGBUF] double_write_buffer_size에 크기 단위 문법을 지원한다

## Issue Triage

**이슈 수행 목적**: `double_write_buffer_size`에 `512K`, `2M`과 같은 크기 단위 입력을 지원하고, 기존 바이트 정수 입력과 `0`의 DWB 비활성 의미를 보존한다.

**이슈 수행 이유**: 현재 파라미터는 바이트 크기이지만 단위 없는 정수만 파싱한다. 다른 크기 파라미터처럼 `2M`을 설정하면 값 오류가 설정 로드 실패와 서버 기동 중단으로 전파되는 경로가 확인된다. 입력 문법의 차이를 줄이고 기존 설정의 호환 기준을 정할 필요가 있다.

**영향**: DWB 크기를 설정하는 운영자와 설정 자동화가 바이트 환산과 파라미터별 문법 확인을 해야 한다. 지원하지 않는 단위 표기를 넣으면 기동을 완료할 수 없는 경로가 있다. 이번 확인은 고정 소스 분석이며, 실제 고객 발생 여부·빈도·기동 대기 시간은 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

이 이슈는 [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)의 하위 과제로, DWB(Double Write Buffer) 크기 설정의 입력 문법을 개선한다. DWB는 데이터 페이지를 원래 볼륨에 쓰기 전에 별도 파일에 사본을 기록하는 보호 장치이며, 이 과제의 요구는 그 크기를 읽기 쉬운 단위로 지정하는 것이다. [DWB와 원래 위치의 쓰기 순서](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L2328-L2356)

분석 기준은 CUBRID `f6cac312310f39f46711693da157a08f0e725693`이다. 이 기준에서 `double_write_buffer_size`는 `PRM_INTEGER`이고 `PRM_SIZE_UNIT` 플래그가 없다. 기본값은 2097152바이트(2 MiB), 파라미터 허용 범위는 0~33554432바이트(32 MiB)이다. 반면 `db_volume_size`는 `PRM_BIGINT`와 `PRM_SIZE_UNIT`을 사용하고, `data_buffer_size`는 크기 단위를 페이지 수로 바꾸는 변환 함수를 사용한다. [DWB 정의](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L4352-L4364), [크기 단위 사용 예](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L3300-L3325), [페이지 수 변환 예](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L1223-L1233)

단위 플래그가 없는 정수 분기는 `parse_int(..., 10)`을 호출한다. 이 함수는 숫자를 읽은 뒤 남은 문자가 있으면 실패하므로 `2M`, `512K`가 `PRM_ERR_BAD_VALUE`로 거부된다. 설정 파일 로더는 이 오류를 보고하고 반환하며, 서버 초기화는 파라미터 로드 실패 시 `ER_BO_CANT_LOAD_SYSPRM`으로 기동을 중단한다. 이는 소스로 확인한 오류 전파이며 이번 작성에서 서버를 실행한 결과는 아니다. [정수 파싱](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L9119-L9148), [접미사 거부](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/porting.c#L2266-L2292), [설정 오류 반환](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L6907-L6912), [로드 실패 전파](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L6462-L6468), [서버 기동 중단](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/boot_sr.c#L2029-L2035)

| 설정 값 | 현재 소스의 처리 | 필요한 결과 |
|---|---|---|
| `2097152` | 2097152바이트로 수용한다. | 기존 의미를 보존한다. |
| `2M` | 정수 파싱에서 거부한다. | 2097152바이트로 수용한다. |
| `512K` | 정수 파싱에서 거부한다. | 524288바이트로 수용한다. |
| `0` | DWB를 비활성화한다. | 기존 의미를 보존한다. |

### 왜 문제인가

운영자는 같은 설정 파일에서 크기를 지정하면서 파라미터마다 단위 문법 지원 여부를 구별해야 한다. 예를 들어 2 MiB를 지정하려면 현재는 `2097152`로 환산해야 한다. 다른 크기 설정에서 사용하는 `2M`을 이 파라미터에도 적용하면 설정 검증 단계에서 실패하고 서버 시작 작업까지 영향을 받는다. 숫자 입력은 우회책이지만, 설정 템플릿을 작성하거나 크기를 검토할 때 환산과 문법 확인 부담이 남는다.

오류 원인을 숨기는지와 기동 대기 시간이 얼마나 늘어나는지는 실행 환경을 포함해 확인해야 한다. 소스에는 파라미터명·파일·행과 오류를 stderr에 출력하고 `ER_PRM_BAD_VALUE`를 설정하는 경로가 있다. 기존 보고에 적힌 `cubrid server start`의 timeout 증상은 실행 빌드와 원본 로그를 확보해 재확인한다. 고객 장애 발생이나 데이터 손상, 성능 저하의 크기를 이 자료만으로 판단하지 않는다. [오류 보고 경로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L10065-L10111), [기존 보고](https://github.com/vimkim/my-cubrid-jira/blob/da39b0f3ee0bc1c55d2063588c3969a808a95687/issues/CBRD-27268-dwb-size-unit-syntax_e6ed61e_claude.md)

### 왜 해결해야 하는가

요청된 단위 문법을 지원하면 운영자가 의도한 크기를 직접 쓰고 검토할 수 있으며, 지원 여부의 차이 때문에 유효한 크기 의도가 설정 오류가 되는 경우를 줄일 수 있다. 오류 메시지 개선만으로는 `512K`, `2M` 입력 요구를 충족하지 못한다. 착수 근거는 명확한 문법 차이와 서버 시작에 연결되는 오류 경로이며, 긴급도와 대상 릴리스는 triage에서 판단한다.

문법 확장은 기존 숫자 설정의 의미를 바꾸지 않아야 한다. 기본값·범위·DWB 크기 보정과 출력 호환성을 함께 확인해야 기존 설정 및 도구를 사용하는 작업을 보존할 수 있다. 구체적인 타입 변경이나 파서 수정은 ANALYSIS에서 결정한다.

## Evidence

### 확인 범위와 기존 자료

2026-10-21에 수집한 live 제목·본문은 크기 단위 지원을 요청하며 댓글은 0건이다. 기존 문서의 타입 전환 제안은 합의된 구현 결정으로 확인되지 않았다. 이후 triage 자료도 `PRM_BIGINT`와 `PRM_SIZE_UNIT` 조합을 후보로 다루고 출력·직렬화 호환성 검토를 요구한다. [기존 보고](https://github.com/vimkim/my-cubrid-jira/blob/da39b0f3ee0bc1c55d2063588c3969a808a95687/issues/CBRD-27268-dwb-size-unit-syntax_e6ed61e_claude.md), [기존 triage 자료](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/CBRD-27193/triage-2026-10-19.html#L160-L172)

현재 기준의 실행 빌드·OS·설정 파일 로드 로그는 수집하지 않았다. 따라서 영향받는 제품 릴리스와 플랫폼 범위, 명령의 실제 종료 메시지와 시간은 TBD이다. 기존 파일명의 `e6ed61e`를 현재 기준이나 이번 실행 빌드로 간주하지 않는다.

### 기존 수치 의미와 크기 보정

`dwb_load_buffer_size`는 설정값을 지역 변수로 읽고, 0이면 비활성을 반환한다. 양수이면 512 KiB~32 MiB 범위에서 2의 거듭제곱으로 올린다. 파라미터 범위 검사를 통과한 값에 대한 의미는 다음과 같다. [크기 상수](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L51-L55), [보정과 0 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L732-L785), [정수 범위 검사](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L8780-L8823)

| 바이트 입력 | DWB 크기 로드 결과 |
|---|---|
| `0` | DWB 비활성이다. |
| `1`~`524287` | 524288바이트(512 KiB)로 보정한다. |
| `524288`~`33554432` | 2의 거듭제곱이면 유지하고, 그 외에는 다음 2의 거듭제곱으로 올린다. 예: `614400`은 1048576바이트가 된다. |
| `33554433` | 파라미터 범위 검사에서 거부한다. |

현재 `600K`는 파싱되지 않는다. 위 `614400`의 보정은 단위 지원 후 `600K`에도 보존해야 할 수치 의미를 설명하는 예다. 파서가 처리할 수 없는 큰 정수는 타입 오류일 수도 있으므로, 모든 상한 초과 문자열의 오류 코드를 동일하다고 단정하지 않는다.

보정은 파라미터 저장값에 되쓰지 않는다. `paramdump`는 파라미터 값을 출력하므로 그 출력만으로 보정 후 DWB 크기를 검증할 수 없다. DWB 활성 여부도 파일 존재 여부 하나로 판정하지 않고 생성 경로와 실제 상태를 확인해야 한다. `double_write_buffer_blocks=0`도 DWB 비활성 조건이므로 크기를 비교할 때 블록 설정을 고정한다. [DWB 생성 경로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L1164-L1213), [블록 수와 비활성 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L795-L810), [파라미터 출력](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L6247-L6265)

### 공통 크기 파서와 출력 호환성

기존 공통 크기 파서는 `strtod`로 수를 읽고, 접미사가 없으면 바이트로 처리한다. `B`, `K`/`KB`, `M`/`MB`, `G`/`GB`, `T`/`TB`, `P`/`PB`를 대소문자 구분 없이 인식하며 배율은 1024의 거듭제곱이다. `UINT64` 범위 안의 유한한 비음수 입력에서 소수도 읽고, 단위를 곱한 뒤 `UINT64`로 변환하므로 소수 바이트 부분은 버린다. 예를 들어 `1.5M`은 1572864바이트이다. 접미사 앞 공백이나 `KiB`는 이 함수의 단위 비교와 일치하지 않는다. 큰 단위도 환산 결과로 범위를 판단해야 하므로 `G` 이상 접미사라는 이유만으로 항상 32 MiB를 넘는 것은 아니다. 이 설명은 공통 함수의 현재 동작이며 DWB의 현재 지원 문법은 위 표와 같다. [단위와 숫자 파싱](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/executables/util_common.c#L1053-L1089), [바이트 변환](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/executables/util_common.c#L1171-L1210), [배율 상수](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/porting.h#L64-L68)

현재 정수 파서에 `PRM_SIZE_UNIT`만 붙이면 충분하지 않다. 해당 분기는 `PRM_DIFFER_UNIT`에 따른 변환 함수를 요구하며, 없으면 오류를 반환한다. `PRM_BIGINT`와 `PRM_SIZE_UNIT` 분기는 공통 크기 파서를 호출하고 범위를 검사한다. 이 차이는 구현 후보를 검토할 근거이며 타입 전환의 확정 근거는 아니다. [정수 크기 분기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L9055-L9091), [BIGINT 분기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L9150-L9195)

공통 출력 경로를 그대로 쓰는 타입·플래그 변경이라면 `2097152`가 `2.0M`처럼 표시될 수 있다. `cubrid paramdump`는 이 경로를 사용한다. 출력 형식을 정수로 읽는 테스트·도구의 존재와 영향을 확인하고 출력 계약을 정해야 한다. 공통 직렬화도 `PRM_INTEGER`와 `PRM_BIGINT`를 각각 다른 폭으로 처리하므로 타입 변경 시 이 파라미터가 전달되는 경로의 호환성을 확인한다. 출력 변경만이 유일한 부수 효과라고 가정하지 않는다. [출력 분기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L7994-L8025), [표시 함수](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/executables/util_common.c#L1099-L1161), [paramdump 호출](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/executables/util_cs.c#L2437-L2451), [타입별 직렬화](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L11255-L11295)

## Specification Changes

- `double_write_buffer_size=512K`와 `=2M`을 각각 524288바이트와 2097152바이트로 수용한다. 기존 바이트 정수 입력과 `0`을 계속 수용한다.
- 기본값 2 MiB, 0의 비활성 의미, 32 MiB 상한과 양수의 최소 크기·2의 거듭제곱 올림 의미를 보존한다.
- 공통 크기 문법과 맞출 대소문자·추가 접미사·소수 입력의 범위와 잘못된 값·오버플로 처리, 출력 형식 및 호환 방침은 ANALYSIS에서 명세한다. 범위 검사는 환산한 바이트 값을 기준으로 한다.
- 블록 개수 파라미터인 `double_write_buffer_blocks`의 단위 문법 변경은 이 과제의 대상에서 제외한다. 검증에 영향을 주는 비활성·올림 조건은 함께 기록한다.

## Implementation

TBD - ANALYSIS 단계에서 결정한다. 기존 문서의 `PRM_BIGINT`와 `PRM_SIZE_UNIT` 조합은 공통 파서 재사용 후보이다. 선택 시 파라미터 저장 타입·기본값·한계값·접근자와 DWB 소비자의 변환, 출력과 직렬화 경로를 함께 검토한다. DWB의 직접 크기 소비자는 현재 `prm_get_integer_value(PRM_ID_DWB_SIZE)`를 사용한다. 변경 파일 수나 코드 줄 수만으로 구현 비용과 호환 범위를 확정하지 않는다.

## Acceptance Criteria

- [ ] `0`, `2097152`, `512K`, `2M`이 명세대로 수용되며, 이 문법 때문에 설정 로드나 정상 서버 시작이 실패하지 않는다.
- [ ] `2M`과 `2097152`의 파라미터 값과 DWB 적용 크기가 같고, 기본값·0의 비활성 의미가 보존된다.
- [ ] `1`, `524288`, `614400`, `33554432`의 적용 크기와 `33554433`의 거부를 검증한다. 단위 입력에도 같은 바이트 범위·올림 규칙이 적용된다.
- [ ] 잘못된 단위·음수·오버플로 등 거부 입력이 의도하지 않은 유효 크기나 비활성 값으로 적용되지 않는다. 허용 문법과 오류 계약은 ANALYSIS 명세와 일치한다.
- [ ] 기존 숫자 설정을 읽는 경로와 `paramdump` 등 출력 소비자의 호환성을 확인하고, 필요한 출력 변경·이행 방법과 테스트 기대값을 기록한다.
- [ ] 지원 입력 문법, 범위, 0과 올림의 의미 및 출력에서 확인할 수 있는 값을 문서화한다.

## Definition of done

- [ ] ANALYSIS에서 파서·타입·출력 계약과 대상 버전 범위를 결정하고 근거를 남긴다.
- [ ] 허용/거부 입력과 경계값을 검증하는 집중 테스트 및 설정 파일을 통한 서버 기동 검증을 완료한다. 각 실행의 전체 빌드·커밋·OS·설정과 결과를 남긴다.
- [ ] DWB 적용 크기 검증은 파라미터 출력과 구별된 관찰 근거를 사용하고, 블록 수 등 관련 설정을 기록한다.
- [ ] Acceptance Criteria를 충족하고 변경된 파서·소비자·도구에 필요한 회귀 검사와 문서 수정을 완료한다.

## Triage Request

크기 단위 문법 지원 필요성을 확인하고 작성자 측에 ANALYSIS를 배정할 것을 요청한다. 분석 범위는 기존 정수·0과 크기 보정을 보존하는 입력 확장, 지원 접미사·소수·오류 경계, 타입 선택에 따른 출력·전달 호환성, 현재 빌드의 설정 로드와 서버 시작 검증이다. 구체적인 구현과 우선순위·담당 배정은 triage 및 ANALYSIS에서 결정한다.
