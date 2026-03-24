# AI agent를 위한 csql echo on 모드 지원

## Description

`csql` 유틸리티에 `--echo` 커맨드라인 옵션을 추가하여, 시작 시 echo 모드를 활성화하고 각 SQL 문을 실행 전에 출력하도록 한다. 이를 통해 csql 출력이 자기 문서화(self-documenting)되어 자동화 테스트, AI 기반 디버깅, 로그 분석이 크게 개선된다.

`csql` 에는 내부적으로 `csql_Is_echo_on` 플래그가 있으며, `true` 일 때 각 SQL 문을 실행 전에 출력 스트림에 출력한다. 다음과 같은 상황에서 특히 유용하다:

- 배치 모드(`-i` 또는 `-c`)로 csql을 실행할 때 출력과 입력을 대조하는 경우
- AI 에이전트가 결과를 해당 SQL 원본과 매칭해야 하는 결과 파일을 생성하는 경우
- 사람이 원본 SQL 파일 없이 출력 로그를 검토하는 경우

### Current Behavior

`csql_Is_echo_on` 의 기본값은 `false` 이다. 이를 활성화하는 유일한 방법은 인터랙티브 세션 명령뿐이다:

```
;echo on
```

이는 다음을 의미한다:

- 셸에서 비대화식(non-interactively)으로 설정할 수 없음
- `-i`(입력 파일)나 `-c`(명령어)를 사용하는 자동화 스크립트에서는 SQL 입력 내에 `;echo on` 을 삽입하지 않으면 활성화할 수 없음
- 시작 시 활성화할 수 있는 지속적이고 운영자가 확인 가능한 방법이 없음

**근거**: `src/executables/csql.c` 의 세션 명령어 `S_CMD_ECHO` 가 유일한 메커니즘이다:

```c
case S_CMD_ECHO:
  if (!strcasecmp (argument, "on"))
    {
      csql_Is_echo_on = true;
    }
  else if (!strcasecmp (argument, "off"))
    {
      csql_Is_echo_on = false;
    }
  ...
  break;
```

이 플래그를 시작 시 설정하는 `csql_arg` 필드나 CLI 옵션이 존재하지 않는다.

### Problem

csql 기반 테스트 도구(예: `ctp.sh sql`) 또는 자동화 파이프라인 사용 시:

- 출력 파일에 쿼리 결과만 포함되고 쿼리 자체는 포함되지 않음
- 결과 행을 원본 SQL과 매칭하려면 입력 파일과 수동으로 교차 참조해야 함
- AI 에이전트가 출력을 분석할 때 어떤 SQL이 어떤 결과를 생성했는지 판단할 수 없음
- 결과 파일에 컨텍스트가 없어 장애 디버깅이 어려움

## Spec Change

`csql` 에 `--echo` CLI 플래그를 추가하여 시작 시 `csql_Is_echo_on = true` 로 설정한다.

### Usage

```bash
csql -udba testdb -S -i test.sql --echo
csql -udba testdb -S -c "SELECT 1; SELECT 2+2;" --echo
```

### Output Example (`--echo` 사용 시)

```
SELECT 1;

  1
======
  1

1 command(s) successfully processed.
SELECT 2+2;

  2+2
=====
  4

1 command(s) successfully processed.
```

`--echo` 없이 실행하면 SQL 문은 출력에 나타나지 않는다.

### Interaction with `;echo` Session Command

새로운 `--echo` CLI 옵션과 기존 `;echo on/off` 세션 명령어는 완전히 호환된다:

- `--echo` 는 시작 시 echo 모드를 설정함
- 사용자는 언제든지 `;echo on` 또는 `;echo off` 로 토글 가능
- `--echo` 없이 실행하면 기존 동작과 동일 (echo 기본 off)

## Implementation

### Changed Files

| 파일 | 변경 내용 |
|------|-----------|
| `src/executables/utility.h` | `CSQL_ECHO_S` (12022) 및 `CSQL_ECHO_L` ("echo") 옵션 상수 추가 |
| `src/executables/csql.h` | `CSQL_ARGUMENT` 구조체에 `bool echo_on` 필드 추가 |
| `src/executables/csql_launcher.c` | `csql_option[]` 배열에 옵션 등록; `CSQL_ECHO_S` 케이스 처리하여 `csql_arg.echo_on = true` 설정 |
| `src/executables/csql.c` | `csql()` 함수에서 `start_csql()` 호출 전에 `csql_arg->echo_on` 을 `csql_Is_echo_on` 에 적용; 하드코딩된 `true` 를 `false`(기본값)로 복원 |
| `msg/en_US.utf8/csql.msg` | 사용법 메시지에 `--echo` 추가 |
| `msg/ko_KR.utf8/csql.msg` | 사용법 메시지에 `--echo` 한국어 번역 추가 |

### Key Code Changes

**`utility.h`** — 새 옵션 상수:
```c
#define CSQL_ECHO_S  12022
#define CSQL_ECHO_L  "echo"
```

**`csql.h`** — `CSQL_ARGUMENT` 새 필드:
```c
bool echo_on;
```

**`csql_launcher.c`** — 옵션 등록 및 핸들러:
```c
{CSQL_ECHO_L, 0, 0, CSQL_ECHO_S},   // csql_option[] 내

case CSQL_ECHO_S:
  csql_arg.echo_on = true;
  break;
```

**`csql.c`** — 시작 시 적용 (`nopager` 처리 후, `lang_init_console_txt_conv()` 전):
```c
if (csql_arg->echo_on)
  {
    csql_Is_echo_on = true;
  }
```

## A/C (Acceptance Criteria)

- [ ] `csql --echo` 옵션이 `csql --help` 출력에 표시됨
- [ ] `csql -udba testdb -S -c "SELECT 1;" --echo` 실행 시 SQL 문이 결과 앞에 출력됨
- [ ] `csql -udba testdb -S -i test.sql --echo` 실행 시 각 SQL 문이 결과 앞에 출력됨
- [ ] `--echo` 없이 실행하면 기존 동작과 동일 (SQL 문 미출력)
- [ ] `--echo` 로 시작 후 `;echo off` 세션 명령으로 비활성화 가능
- [ ] 기존 `;echo on` / `;echo off` 세션 명령은 영향 없이 정상 동작

## DoD (Definition of Done)

- [ ] 코드 변경 완료 및 빌드 성공
- [ ] A/C 항목 전체 수동 검증 완료
- [ ] PR 코드 리뷰 통과
- [ ] 기존 csql 관련 테스트 regression 없음
