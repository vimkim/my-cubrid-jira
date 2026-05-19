# [CTP] shell 테스트가 사용자 `$CUBRID` 를 무시하고 `$HOME/CUBRID` 만 쓰는 문제

## Issue Triage

**이슈 수행 목적**: CTP 가 shell 테스트를 돌릴 때, 사용자가 셸에 export 해 둔 `$CUBRID` 경로를 그대로 따르도록 고친다. 지금처럼 `$HOME/CUBRID` 로 덮이지 않게 한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: CTP 는 매 shell 테스트마다 자식 셸을 새로 띄우고, 그 자식 셸의 첫 줄에서 `~/.bash_profile` 을 source 한다. 그런데 사용자의 `~/.bashrc` (CUBRID 공식 설치 가이드대로 적혀 있음) 에는 `export CUBRID=$HOME/CUBRID` 가 들어 있다. 즉 매번 사용자가 설정한 `$CUBRID` 가 `$HOME/CUBRID` 로 덮인다. CTP 코드는 `CTP_HOME` 만 백업해 뒀다가 복원하는데, `CUBRID` 는 그렇게 하지 않는다 (`CTP/shell/src/com/navercorp/cubridqa/shell/common/ScriptInput.java:71`).
- **영향**: QA 실패. `$HOME/CUBRID` 가 아닌 곳에 CUBRID 를 설치하는 모든 경우 (worktree 여러 개, debug/release 빌드 병행 등) 에서 shell 회귀 테스트가 못 돌아간다. 예: `bigPageSize.sh` 가 CTP 로 돌리면 `time=0` 즉시 NOK 로 떨어진다 (직접 `bash bigPageSize.sh` 로 돌리면 약 8 분 동안 정상 수행). 이 때문에 OOS 회귀 (CBRD-26813/26814/26815) 검증을 CTP 로 못 했다.

**이슈 수행 방안**:

- CTP 자식 셸 래퍼에 `$CUBRID` 백업/복원 코드를 추가한다. `CTP_HOME` 과 똑같이 처리하면 된다.
- 수정 위치 (Java 소스):
    - `CTP/shell/src/com/navercorp/cubridqa/shell/common/ScriptInput.java:71` (shell 테스트 전용)
    - `CTP/common/src/com/navercorp/cubridqa/common/ShellInput.java:50` (sql/medium/HA-repl/CDC-repl/isolation 공용)
    - `CTP/sql/src/com/navercorp/cubridqa/cqt/common/ShellInput.java:51` (sql/cqt 의 같은 패턴)
- 같은 패턴으로 `CUBRID_DATABASES`, `PATH`, `LD_LIBRARY_PATH` 도 복원 (`~/.bashrc` 가 이 네 개를 같이 덮어쓰기 때문).
- 부모 셸에 `$CUBRID` 가 비어 있을 때만 `.bash_profile` 의 값을 그대로 받는다. 즉 기존 사용자 환경 (사용자 셸에 `CUBRID` 미 export) 은 동작이 그대로 유지된다.
- 검증: `bigPageSize.sh` 를 `ctp.sh shell -c shell_ci.conf` 로 돌렸을 때 `time=0` 즉시 NOK 가 아니라 실제 실행 시간 (분 단위) 이 기록되어야 한다.
- 범위 밖: jar 재빌드/배포 절차는 `TBD - 합의 미확인`.

---

## AI-Generated Context

> 아래는 AI 가 CTP 소스와 실패 로그를 대조해 작성한 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만 보면 되고, 아래는 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **문제**: CTP 가 자식 셸에서 `~/.bash_profile` 을 source 한 뒤, 부모로부터 받은 `$CUBRID` 를 복원하지 않는다.
- **원인**: 자식 셸 래퍼가 `CTP_HOME` 만 백업/복원하고 `CUBRID` 는 빠뜨렸다.
- **변경**: 같은 백업/복원 코드를 `CUBRID` (와 동반 변수 3 개) 에도 적용. Java 소스 3 곳 수정.
- **영향 범위**: CUBRID 를 비표준 위치에 설치하는 모든 개발자/QA 환경. 다중 worktree, 다중 빌드 모드 병행 시 특히.

### 신입을 위한 사전 설명 (용어 정리)

- **환경변수**: 셸이 기억하는 이름=값 쌍. `echo $CUBRID` 로 확인. 셸이 자식 프로세스를 띄울 때 자동 상속된다.
- **`$CUBRID`**: CUBRID 가 설치된 디렉터리. 예: `/home/foo/CUBRID` 또는 `/home/foo/.cub/install/branch-x/debug`. CUBRID 의 모든 conf 파일/실행 파일이 이 경로 아래에 있다.
- **`~/.bash_profile`, `~/.bashrc`**: 셸이 시작될 때 자동으로 실행되는 설정 파일. 보통 `.bash_profile` 이 `.bashrc` 를 source 하는 구조. 여기에 `export CUBRID=$HOME/CUBRID` 같은 줄이 들어 있다.
- **`. ~/.bash_profile`**: 현재 셸 안에서 `.bash_profile` 의 내용을 한 줄씩 실행. 그 안의 `export` 가 현재 셸의 환경을 바꾼다.
- **CTP**: CUBRID Test Program. Java 로 작성된 테스트 자동화 도구. `ctp.sh shell -c shell.conf` 로 부르면 shell 카테고리의 테스트를 일괄 실행한다.
- **자식 셸**: Java 프로세스가 `/bin/sh -c "..."` 로 새로 띄운 셸. CTP 가 테스트 한 건마다 자식 셸 하나를 띄워서 그 안에서 테스트 스크립트를 실행한다.
- **CTP 의 래퍼 스크립트**: CTP 가 자식 셸에 실제 테스트 명령을 던지기 전에 앞뒤에 붙이는 공통 코드. "환경 세팅 + 사용자 명령 + 정리" 의 샌드위치 구조. 본 이슈의 버그는 이 래퍼의 앞부분에 있다.

---

## Description

### 한 줄 요약

사용자가 셸에서 `export CUBRID=...` 해 놓아도, CTP 가 자식 셸을 띄울 때 `~/.bash_profile` 을 source 해서 그 값을 `$HOME/CUBRID` 로 덮어버린다. 그래서 자식 셸 안의 테스트는 항상 `$HOME/CUBRID` 만 본다.

### 전체 흐름 (그림으로)

```
[사용자 셸]                                     CUBRID=/home/foo/.cub/install/.../debug   <- 사용자가 설정
   |
   | $ ctp.sh shell -c shell_ci.conf
   v
[Java 프로세스 (CTP 본체)]                      CUBRID=/home/foo/.cub/install/.../debug   <- Java 가 부모 환경 상속 (OK)
   |
   | 테스트 한 건마다 자식 셸 spawn
   | (래퍼 스크립트로 감싸서 실행)
   v
[자식 셸 - 래퍼의 앞부분]
   1. pri_ctp_home=$CTP_HOME            <- CTP_HOME 만 백업
   2. . ~/.bash_profile                 <- .bashrc 가 source 됨
                                           안에 export CUBRID=$HOME/CUBRID 있음
                                           CUBRID 가 /home/foo/CUBRID 로 덮임 (BUG)
   3. export CTP_HOME=$pri_ctp_home     <- CTP_HOME 만 복원
                                           CUBRID 는 복원 안 함 (BUG)
   v
[자식 셸 - 실제 테스트 실행]                    CUBRID=/home/foo/CUBRID                   <- 잘못된 값!
   |
   | source init.sh (테스트 공통 초기화)
   |   ini.sh -s %BROKER1 $CUBRID/conf/cubrid_broker.conf SERVICE
   |   -> /home/foo/CUBRID/conf/cubrid_broker.conf 를 열려고 시도
   v
java.io.FileNotFoundException                  <- 그런 파일 없음 -> 테스트 즉시 NOK
```

### 발견 경위

`feat-oos-m2-manual` 브랜치의 OOS 회귀 (CBRD-26813 / 26814 / 26815) 를 패치한 뒤 `bigPageSize.sh` 가 통과하는지 보려고 했다. 두 가지 실행 방식의 결과:

| 실행 방식 | 결과 | 소요 시간 |
|---|---|---|
| `ctp.sh shell -c shell_ci.conf` (CTP 경유, bigPageSize 만 scenario 로 지정) | `[NOK]`, `load.log` 가 빈 파일 | `time=0` (즉시 종료) |
| `bash bigPageSize.sh` (CTP 우회, 사용자 셸 환경) | 끝까지 실행, `load.log` 정상 생성 | 약 8 분 |

CTP 쪽 `feedback.log` 에 다음 예외가 반복 출력되어 있었다:

```
++ ini.sh -s %BROKER1 /home/vimkim/CUBRID/conf/cubrid_broker.conf SERVICE
Exception in thread "main" java.io.FileNotFoundException:
  /home/vimkim/CUBRID/conf/cubrid_broker.conf (No such file or directory)
    at com.navercorp.cubridqa.common.IniData.init(Unknown Source)
    at com.navercorp.cubridqa.ctp.IniCommand.main(Unknown Source)
```

`$CUBRID` 가 사용자 셸에서는 `/home/vimkim/.cub/install/feat-oos-m2-manual/debug_clang` 였는데 자식 셸에서는 `/home/vimkim/CUBRID` (없는 경로) 였다. 사용자가 설정한 값이 자식 셸까지 안 전달된 것이다.

### 왜 이런 일이 일어나는가 (코드)

`CTP/shell/src/com/navercorp/cubridqa/shell/common/ScriptInput.java` 의 `getCommands()` 함수가 자식 셸의 래퍼 스크립트를 만든다. 67-74 줄의 핵심:

```java
public String getCommands() {
    if (isPureWindows) {
        return "echo " + START_FLAG_MOCK_WIN + ...;
    } else {
        return "pri_ctp_home=$CTP_HOME; if  [ -f ~/.bash_profile ]; then . ~/.bash_profile; fi; if [ \"$pri_ctp_home\" != \"\" ];then export CTP_HOME=${pri_ctp_home}; fi; " + LINE_SEPARATOR
                + "echo " + START_FLAG_MOCK + LINE_SEPARATOR + cmds.toString() + "echo " + COMP_FLAG_MOCK + LINE_SEPARATOR;
    }
}
```

위 한 줄을 풀어 보면:

```bash
pri_ctp_home=$CTP_HOME             # 부모로부터 받은 CTP_HOME 을 잠시 저장
. ~/.bash_profile                  # 사용자 .bash_profile (안에서 .bashrc) source
if [ "$pri_ctp_home" != "" ]; then
    export CTP_HOME=$pri_ctp_home  # CTP_HOME 만 다시 복원
fi
# ... 여기부터 실제 테스트 명령 실행 ...
```

CTP 개발자가 `~/.bash_profile` 안의 사용자 코드가 `CTP_HOME` 을 덮어쓸까 봐 백업/복원을 넣은 것은 좋다. 그런데 `$CUBRID` 도 똑같이 덮일 수 있다는 걸 잊었다.

사용자 `~/.bashrc` (CUBRID 공식 설치 안내의 표준 스니펫, 거의 모든 CUBRID 머신에 그대로 있음):

```bash
export CUBRID=$HOME/CUBRID
export CUBRID_DATABASES=$CUBRID/databases
export PATH=$CUBRID/bin:$PATH
export LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib:$LD_LIBRARY_PATH
```

이 네 줄이 매 shell 테스트 시작 시 실행되어 부모로부터 받은 값을 덮어쓴다.

### 이 의존성이 만드는 실제 문제

- **다중 worktree 빌드 불가**: 한 머신에 branch 여러 개의 빌드를 동시에 두고 빠르게 전환하려면 각 worktree 의 install 경로가 달라야 한다. CTP 가 `$HOME/CUBRID` 만 보면 그때마다 symlink 를 다시 걸어야 하고, 그동안 다른 worktree 의 테스트는 멎는다.
- **OOS 회귀 검증 차단**: `bigPageSize` 같은 OOS 시나리오는 검증에 5-10 분이 필요하다. CTP 가 1 초 안에 NOK 로 떨어지면 회귀가 풀렸는지 아닌지 알 수 없다 (이번 OOS sub-task 3 건의 검증을 직접 bash 실행으로 대체할 수밖에 없었다).
- **다른 빌드 모드 병행 불가**: release / debug / debug_clang 같은 빌드 모드 여러 개를 같은 머신에서 쓰려면 매번 `$HOME/CUBRID` symlink 를 다시 걸어야 한다. 자동화가 깨진다.

### 같은 안티 패턴이 있는 다른 파일

shell 모듈에서만 발견했지만, sql/medium 등 다른 카테고리 코드에도 같은 패턴이 있다. 본 이슈 PR 에 같이 묶어서 처리하는 것을 권장.

| 파일 | 누가 쓰는가 | 현재 상태 |
|---|---|---|
| `CTP/shell/src/com/navercorp/cubridqa/shell/common/ScriptInput.java:71` | shell 모듈 전부 | `CTP_HOME` 만 백업/복원. `CUBRID` 누락 |
| `CTP/common/src/com/navercorp/cubridqa/common/ShellInput.java:50` | sql/medium/HA-repl/CDC-repl/isolation 공용 | 백업/복원 자체가 없음. `. ~/.bash_profile` 만 |
| `CTP/sql/src/com/navercorp/cubridqa/cqt/common/ShellInput.java:51` | sql/cqt 의 별도 사본 | 위와 동일 |

## Test Build

- CTP: 현재 사용 중인 `~/CTP`. jar 버전 식별자 확인은 `TBD - 합의 미확인`.
- CUBRID 설치: `/home/vimkim/.cub/install/feat-oos-m2-manual/debug_clang` (`$CUBRID` 환경변수로 export 됨).
- OS: RHEL 9.6 (5.14.0-570.30.1.el9_6.x86_64).

## Repro

```bash
# 1. 셸 환경 — 비표준 위치에 CUBRID 설치, 그런데 ~/.bashrc 는 CUBRID=$HOME/CUBRID 로 고정
export CUBRID=/home/vimkim/.cub/install/feat-oos-m2-manual/debug_clang
export PATH=$CUBRID/bin:$PATH
grep '^export CUBRID=' ~/.bashrc      # export CUBRID=$HOME/CUBRID
ls /home/vimkim/CUBRID 2>&1           # No such file or directory

# 2. 직접 실행: 정상 (사용자 $CUBRID 를 그대로 따른다)
cd /home/vimkim/cubrid-testcases-private-ex/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize/cases
export init_path=/home/vimkim/CTP/shell/init_path
bash bigPageSize.sh                   # 약 8 분, 끝까지 실행

# 3. CTP 경유: 실패 (CTP 가 .bash_profile 소싱 후 $CUBRID 복원 안 함)
#    shell_ci.conf 의 scenario 를 위 bigPageSize 경로로 지정한 뒤
ctp.sh shell -c shell_ci.conf
# 결과: time=0 으로 즉시 NOK
cat /home/vimkim/CTP/result/shell/current_runtime_logs/feedback.log | grep FileNotFoundException
# Exception in thread "main" java.io.FileNotFoundException:
#   /home/vimkim/CUBRID/conf/cubrid_broker.conf (No such file or directory)
```

## Expected Result

```bash
$ CUBRID=/path/to/custom/install ctp.sh shell -c shell_ci.conf
# init.sh 의 ini.sh 가 /path/to/custom/install/conf/cubrid_broker.conf 를 정상 읽음.
# 테스트가 실제 실행 시간 (분 단위) 동안 동작하고 OK/NOK 가 진짜 결과를 반영함.
```

## Actual Result

CTP 가 매 shell exec 마다 `.bash_profile` 을 source 한 뒤 `$CUBRID` 를 복원하지 않아 자식 셸의 `$CUBRID` 가 `$HOME/CUBRID` 로 덮인다. `init.sh` 의 `ini.sh` 호출이 존재하지 않는 conf 파일을 열려다 `FileNotFoundException`. 테스트는 1 초 안에 NOK.

## Additional Information

### 관련 회귀 검증과의 연결

이 버그 때문에 OOS 회귀 3 건 (CBRD-26813, 26814, 26815) 의 fix 검증을 CTP 가 아닌 직접 `bash` 실행으로 대체해야 했다. CTP 결과만 보면 패치 적용 후에도 `[NOK]` 이라 패치가 효과 없는 것처럼 오해할 위험이 있다.

### 워크어라운드 (임시)

방법 1 — symlink:

```bash
ln -s /home/vimkim/.cub/install/feat-oos-m2-manual/debug_clang /home/vimkim/CUBRID
```

worktree 를 바꿀 때마다 symlink 를 다시 걸어야 하고, 두 worktree 를 동시에 쓰는 시나리오는 여전히 깨진다.

방법 2 — `.bashrc` 가드:

```bash
# 기존: export CUBRID=$HOME/CUBRID
# 변경: 사용자가 미리 설정 안 했을 때만 기본값 사용
[ -z "$CUBRID" ] && export CUBRID=$HOME/CUBRID
```

CUBRID 공식 설치 가이드와 다른 도구들이 `CUBRID=$HOME/CUBRID` 를 가정하는 경우가 많아 부수 효과가 있다.

두 방법 다 임시방편. 본 이슈로 정공법 수정 필요.

## Implementation

### 핵심 아이디어

CTP 가 이미 `CTP_HOME` 에 적용 중인 백업/복원 패턴을 그대로 `CUBRID` (와 동반 변수) 에 확장한다. 코드 변화는 작다.

### 1단계: `ScriptInput.java` 패치 (shell 모듈)

대상: `CTP/shell/src/com/navercorp/cubridqa/shell/common/ScriptInput.java:71`

수정 후 prefix 예시 (한 줄을 가독성 위해 여러 줄로 풀어 적음):

```java
return "pri_ctp_home=$CTP_HOME; "
     + "pri_cubrid=$CUBRID; "
     + "pri_cubrid_db=$CUBRID_DATABASES; "
     + "pri_path=$PATH; "
     + "pri_ld=$LD_LIBRARY_PATH; "
     + "if  [ -f ~/.bash_profile ]; then . ~/.bash_profile; fi; "
     + "if [ \"$pri_ctp_home\" != \"\" ]; then export CTP_HOME=${pri_ctp_home}; fi; "
     + "if [ \"$pri_cubrid\" != \"\" ]; then export CUBRID=${pri_cubrid}; fi; "
     + "if [ \"$pri_cubrid_db\" != \"\" ]; then export CUBRID_DATABASES=${pri_cubrid_db}; fi; "
     + "if [ \"$pri_path\" != \"\" ]; then export PATH=${pri_path}; fi; "
     + "if [ \"$pri_ld\" != \"\" ]; then export LD_LIBRARY_PATH=${pri_ld}; fi; "
     + LINE_SEPARATOR
     + "echo " + START_FLAG_MOCK + LINE_SEPARATOR + cmds.toString() + "echo " + COMP_FLAG_MOCK + LINE_SEPARATOR;
```

핵심: 부모 셸의 값이 비어 있으면 `.bash_profile` 에서 흘러나온 값을 그대로 받아 기존 동작 유지. 비어 있지 않으면 부모 값을 강제 복원.

### 2단계: sibling 위치 같이 수정

대상 1: `CTP/common/src/com/navercorp/cubridqa/common/ShellInput.java:50` (sql/medium/HA-repl/CDC-repl/isolation 공용)

현재:

```java
if (scriptToRun == null) {
    scriptToRun = ". ~/.bash_profile";
}
```

수정 후:

```java
if (scriptToRun == null) {
    scriptToRun = "pri_cubrid=$CUBRID; pri_cubrid_db=$CUBRID_DATABASES; "
                + "pri_path=$PATH; pri_ld=$LD_LIBRARY_PATH; "
                + ". ~/.bash_profile; "
                + "if [ \"$pri_cubrid\" != \"\" ]; then export CUBRID=${pri_cubrid}; fi; "
                + "if [ \"$pri_cubrid_db\" != \"\" ]; then export CUBRID_DATABASES=${pri_cubrid_db}; fi; "
                + "if [ \"$pri_path\" != \"\" ]; then export PATH=${pri_path}; fi; "
                + "if [ \"$pri_ld\" != \"\" ]; then export LD_LIBRARY_PATH=${pri_ld}; fi;";
}
```

대상 2: `CTP/sql/src/com/navercorp/cubridqa/cqt/common/ShellInput.java:51` — 위와 같은 내용으로 패치.

### 3단계: 빌드 / 배포

수정 대상은 Java 소스. jar 재빌드 필요:

- `CTP/common/lib/cubridqa-common.jar`
- `CTP/shell/lib/cubridqa-shell.jar`
- `CTP/sql/lib/cubridqa-cqt.jar`

빌드 절차 자체는 `TBD - 합의 미확인`.

### 4단계: 검증

```bash
# 비표준 경로에 CUBRID 를 export 한 상태에서
export CUBRID=/home/vimkim/.cub/install/feat-oos-m2-manual/debug_clang

# bigPageSize.sh 가 CTP 경유로 정상 실행되는지 확인
# (shell_ci.conf 의 scenario 를 bigPageSize 경로로 지정한 뒤)
ctp.sh shell -c shell_ci.conf
# 기대: time 이 5-10 분 사이, OK 또는 진짜 NOK (FileNotFoundException 아닌 실제 실패)

# feedback.log 에 FileNotFoundException 없는지 확인
grep FileNotFoundException /home/vimkim/CTP/result/shell/current_runtime_logs/feedback.log
# 기대: 아무 출력 없음
```

추가로 shell 카테고리의 다른 테스트 한두 개도 sanity check.

## Acceptance Criteria

- [ ] 사용자 셸에 `CUBRID` 가 비표준 경로로 export 된 상태에서 `ctp.sh shell` 이 그 경로를 따른다.
- [ ] `CUBRID` 가 export 되지 않은 환경에서는 `.bash_profile` 의 값이 그대로 사용된다 (기존 동작 유지).
- [ ] `bigPageSize.sh` 를 `ctp.sh shell -c shell_ci.conf` 로 실행하면 `time=0` 이 아닌 실제 실행 시간이 기록된다.
- [ ] `feedback.log` 에 `FileNotFoundException: /home/.../CUBRID/conf/...` 가 더 이상 나오지 않는다.
- [ ] OOS 회귀 sub-task 3 건 (CBRD-26813/26814/26815) 의 fix 를 CTP 로 검증해 OK 가 떨어진다.

## Definition of done

- [ ] 위 A/C 충족.
- [ ] `cubridqa-common.jar`, `cubridqa-shell.jar`, `cubridqa-cqt.jar` 재빌드 및 PR merge.
- [ ] sql/medium 카테고리에서도 같은 시나리오 (비표준 `$CUBRID`) 가 정상 동작하는지 sanity check.

## 참고 코드

| 파일:줄 | 역할 |
|---|---|
| `CTP/shell/src/com/navercorp/cubridqa/shell/common/ScriptInput.java:71` | **주 수정 대상**. shell 모듈의 모든 자식 셸 래퍼 prefix. `CTP_HOME` 만 백업/복원, `CUBRID` 누락. |
| `CTP/common/src/com/navercorp/cubridqa/common/ShellInput.java:50` | **부 수정 대상**. sql/medium/HA-repl/CDC-repl/isolation 공용. 백업/복원 자체가 없음. |
| `CTP/sql/src/com/navercorp/cubridqa/cqt/common/ShellInput.java:51` | **부 수정 대상**. sql/cqt 의 같은 패턴. |
| `CTP/shell/init_path/init.sh:79, 776, 778, 780` | `ini.sh -s ... $CUBRID/conf/...` 호출들. 표면 증상이 나타나는 지점. **이 파일은 수정하지 않는다.** |
| `CTP/bin/ini.sh` | `IniCommand` Java 래퍼. 받은 경로를 그대로 쓴다. 책임 없음. |
| `CTP/shell/src/com/navercorp/cubridqa/shell/common/GeneralScriptInput.java` | `ScriptInput` 의 자식 클래스. `CTP_HOME` 재계산은 여기서도 하지만 `CUBRID` 는 다루지 않음. 참고용. |

## Remarks

- 동반 관련 sub-task: CBRD-26813 / CBRD-26814 / CBRD-26815 (OOS 회귀 3 건). 본 이슈가 풀려야 그 fix 들을 CTP 로 정상 검증 가능.
- 본 패치의 부수 효과: `PATH`, `LD_LIBRARY_PATH` 도 부모 값으로 복원되므로, 사용자가 PATH 앞에 prepend 한 임의 디렉터리 (예: 도구 디렉터리) 가 유지된다. 기존 동작이 `.bash_profile` 의 PATH 를 강제로 쓰던 점에 의존하는 케이스가 있는지 확인 필요.
- 임시 워크어라운드 (`ln -s` symlink, `.bashrc` 가드) 는 단일 worktree 환경에서만 통한다.
