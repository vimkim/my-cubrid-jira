# [CTP] shell 테스트가 사용자 `$CUBRID` 를 무시하는 문제 (`.bash_profile` 소싱 후 미복원)

## Issue Triage

**이슈 수행 목적**: CTP 가 shell 테스트를 spawn 할 때 부모 셸의 `$CUBRID` 를 보존하도록 바꾼다. 비표준 경로에 설치된 CUBRID 빌드도 `ctp.sh shell` 로 그대로 테스트할 수 있어야 한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `ctp.sh shell` 은 매 shell 명령마다 `ScriptInput.getCommands()` 가 만든 래퍼 스크립트로 감싼다 (`CTP/shell/src/com/navercorp/cubridqa/shell/common/ScriptInput.java:71`). 그 래퍼는 `pri_ctp_home=$CTP_HOME; . ~/.bash_profile; if [ "$pri_ctp_home" != "" ]; then export CTP_HOME=${pri_ctp_home}; fi;` 패턴으로 `CTP_HOME` 만 save/restore 하고 `CUBRID` 는 하지 않는다. 사용자 `~/.bashrc` 가 (CUBRID 공식 설치 안내에 따라) `export CUBRID=$HOME/CUBRID` 를 하면, `.bash_profile -> .bashrc` 체인이 매 shell exec 마다 부모로부터 상속된 `$CUBRID` 를 `$HOME/CUBRID` 로 덮어쓴다. 이후 `init.sh:79, 776, 778, 780` 의 `ini.sh -s ... $CUBRID/conf/cubrid_broker.conf ...` 가 존재하지 않는 `/home/USER/CUBRID/conf/cubrid_broker.conf` (USER 는 실제 사용자명) 를 열려다 `java.io.FileNotFoundException` 으로 죽는다.
- **영향**: QA 실패 — `$HOME/CUBRID` 가 아닌 곳에 설치하는 모든 워크플로 (다중 worktree, release/debug/debug_clang 병행, RPM 외 설치) 에서 shell 회귀가 못 돌아간다. 예: `bigPageSize.sh` 가 CTP 경유 시 `time=0` 으로 즉시 NOK 처리되어 (실제 직접 실행 시 약 8 분 소요) OOS 회귀 (CBRD-26813/26814/26815) 검증 자체가 CTP 로 불가능했다.

**이슈 수행 방안**:

- **수정 위치 1 (필수)**: `CTP/shell/src/com/navercorp/cubridqa/shell/common/ScriptInput.java:71` 의 래퍼 prefix 에 `CUBRID` 보존 코드를 추가한다. `pri_cubrid=$CUBRID` 로 사전 저장하고, `.bash_profile` 소싱 후 `if [ "$pri_cubrid" != "" ]; then export CUBRID=${pri_cubrid}; export CUBRID_DATABASES=${pri_cubrid}/databases; fi;` 로 복원한다. `PATH`, `LD_LIBRARY_PATH` 도 동일 패턴으로 보존 (`.bashrc` 가 `$CUBRID/bin`, `$CUBRID/lib` 를 PATH 앞에 prepend 하는데, 복원하지 않으면 stale 한 `$HOME/CUBRID/bin` 이 PATH 에 남는다).
- **수정 위치 2 (sibling, 같은 PR 에서 처리)**:
    - `CTP/common/src/com/navercorp/cubridqa/common/ShellInput.java:50` — SQL/medium/HA-repl/CDC-repl/isolation 오케스트레이터가 공유하는 entry. 현재 `scriptToRun = ". ~/.bash_profile";` 만 하고 save/restore 가 아예 없다.
    - `CTP/sql/src/com/navercorp/cubridqa/cqt/common/ShellInput.java:51` — SQL/CQT 의 동일 패턴.
- **fallback 정책**: 부모 `$CUBRID` 가 비어 있을 때만 `.bash_profile` 로부터 흘러나온 값을 받는다 (위 `if [ "$pri_cubrid" != "" ]` 가드가 이를 보장).
- **검증 기준**:
    - `CUBRID=/path/to/custom/install ctp.sh shell -c CONF` (CONF 는 임의 conf 파일) 가 사용자 지정 경로의 `conf/cubrid_broker.conf` 를 정상 읽는다.
    - `bigPageSize.sh` 를 `just shell-debug` 로 실행 시 `time=0` 이 아닌 실제 실행 시간 (분 단위) 동안 동작한다.
    - `feedback.log` 에 `FileNotFoundException` 이 더 이상 나오지 않는다.
- **범위 밖**: `cubridqa-common.jar` 의 build/release 절차는 `TBD - 합의 미확인` (소스 수정 후 jar 재빌드/배포 방법은 별도 확인). 분산 (multi-node) shell 테스트의 SSH 경유 case (`SSHConnect`) 도 동일 패턴이 있는지 별도 확인 필요.

---

## AI-Generated Context

> 아래 내용은 AI 가 CTP 소스를 직접 읽고 실패 로그와 대조해 작성한 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만 보면 충분하다.

### Summary

- **문제**: CTP shell-test 래퍼가 매 exec 마다 `~/.bash_profile` 을 source 하면서 부모 셸의 `$CUBRID` 를 보존하지 않아 `$HOME/CUBRID` 로 덮인다.
- **원인**: `ScriptInput.getCommands()` 가 `CTP_HOME` 만 `pri_ctp_home` 으로 save/restore 하고 `CUBRID`/`PATH`/`LD_LIBRARY_PATH` 는 빠뜨렸다 (`CTP/shell/src/com/navercorp/cubridqa/shell/common/ScriptInput.java:71`).
- **변경**: 같은 save/restore 패턴을 `CUBRID`, `CUBRID_DATABASES`, `PATH`, `LD_LIBRARY_PATH` 에도 적용. `ShellInput.java` 의 두 sibling 위치도 같이 수정.
- **영향 범위**: 비표준 위치에 CUBRID 를 설치하는 모든 개발/QA 워크플로. 다중 worktree, 다중 빌드 모드 병행, OOS 회귀 검증 등.

---

## Description

CTP 의 shell 테스트 래퍼가 매 exec 마다 `~/.bash_profile` 을 source 하지만, source 직후 부모 셸의 `$CUBRID` 를 복원하지 않는다. 그 결과 사용자 `~/.bashrc` 의 `export CUBRID=$HOME/CUBRID` 가 매번 부모의 `$CUBRID` 를 덮어쓰고, `init.sh` 의 `ini.sh` 호출이 존재하지 않는 conf 파일을 열려다 죽는다.

### 발견 경위

`feat-oos-m2-manual` 브랜치의 OOS 회귀 (CBRD-26813 / 26814 / 26815) 를 패치한 뒤 `bigPageSize.sh` 가 통과하는지 확인하려 했다. 두 가지 실행 방식의 결과:

| 실행 방식 | 결과 | 소요 시간 |
|---|---|---|
| `just shell-debug ...bigPageSize` (CTP 경유) | `[NOK]`, `load.log` 가 빈 파일 | `time=0` (즉시 종료) |
| `bash bigPageSize.sh` (CTP 우회, 사용자 셸 환경) | 끝까지 실행, `load.log` 정상 생성 | 약 8 분 |

CTP 경로의 `feedback.log` 에 다음 예외가 반복 출력되어 있었다:

```
++ ini.sh -s %BROKER1 /home/vimkim/CUBRID/conf/cubrid_broker.conf SERVICE
Exception in thread "main" java.io.FileNotFoundException:
  /home/vimkim/CUBRID/conf/cubrid_broker.conf (No such file or directory)
    at com.navercorp.cubridqa.common.IniData.init(Unknown Source)
    at com.navercorp.cubridqa.ctp.IniCommand.main(Unknown Source)
```

사용자 셸의 `$CUBRID` 는 `/home/vimkim/.cub/install/feat-oos-m2-manual/debug_clang` 였지만 CTP 가 띄운 child shell 의 `$CUBRID` 는 `/home/vimkim/CUBRID` (없는 경로) 였다.

### 근본 원인

`CTP/shell/src/com/navercorp/cubridqa/shell/common/ScriptInput.java:67-74`:

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

매 shell exec 마다 위 prefix 가 붙는다. `CTP_HOME` 은 `pri_ctp_home` 에 백업해 두고 `.bash_profile` 소싱 후 복원하지만, `CUBRID` 는 그런 처리가 없다.

사용자 `~/.bashrc` (실제 내용):

```bash
export CUBRID=$HOME/CUBRID
export CUBRID_DATABASES=$CUBRID/databases
export PATH=$CUBRID/bin:$PATH
export LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib:$LD_LIBRARY_PATH
```

이건 CUBRID 공식 설치 가이드의 standard snippet 으로, 거의 모든 CUBRID 개발자/QA 머신에 들어 있다.

체인:

1. 사용자 셸: `CUBRID=/home/vimkim/.cub/install/feat-oos-m2-manual/debug_clang` export.
2. `ctp.sh shell` -> `java com.navercorp.cubridqa.ctp.CTP shell`. Java 의 `Runtime.exec` 가 parent env 를 상속하므로 Java 프로세스도 올바른 `$CUBRID` 를 가진다.
3. Java 가 shell test 한 건마다 `ScriptInput.getCommands()` 로 래퍼 스크립트를 만들어 `LocalInvoker` 가 `/bin/sh -c` 로 실행.
4. 래퍼 prefix 가 `. ~/.bash_profile` 을 수행 -> `.bashrc` 가 sourced -> `CUBRID=/home/vimkim/CUBRID` 로 overwritten.
5. 래퍼 후미가 `CTP_HOME` 만 복원하고 `CUBRID` 는 안 한다. 이제 child shell 에서 `$CUBRID = /home/vimkim/CUBRID`.
6. 테스트 케이스가 `init.sh` 를 source 하면서 `ini.sh -s ... $CUBRID/conf/cubrid_broker.conf` 호출 -> 존재하지 않는 경로 -> `FileNotFoundException` -> 케이스 NOK.

### 이 의존성이 만드는 실제 문제

- **다중 worktree 빌드 불가**: 한 머신에 여러 branch 의 빌드를 동시에 두고 빠르게 전환하려면 각 worktree 의 install 경로를 분리해야 한다. CTP 가 `$HOME/CUBRID` 만 보면 그때마다 symlink 를 다시 걸어야 하고, 그동안 다른 worktree 의 테스트는 멎는다.
- **OOS 회귀 검증 차단**: `bigPageSize` 같은 OOS-heavy 시나리오는 검증에 5-10 분이 필요하다. CTP 가 첫 1 초 안에 NOK 로 떨어지면 실제 회귀가 풀렸는지 아닌지 구분이 안 된다 (이번 OOS sub-task 3 건의 검증을 직접 bash 실행으로 대체할 수밖에 없었다).
- **다른 빌드 모드 병행 불가**: release / debug / debug_clang 등 같은 branch 의 다른 빌드를 같은 머신에서 쓰려면 매번 `$HOME/CUBRID` symlink 재설정. 자동화 워크플로가 깨진다.

### 동일 패턴이 있는 sibling 위치

| 파일 | 역할 | 차이점 |
|---|---|---|
| `CTP/shell/src/com/navercorp/cubridqa/shell/common/ScriptInput.java:71` | shell 모듈의 모든 shell exec 래퍼 | `CTP_HOME` 은 save/restore 함, `CUBRID` 누락 |
| `CTP/common/src/com/navercorp/cubridqa/common/ShellInput.java:50` | SQL/medium/HA-repl/CDC-repl/isolation 공용 entry | save/restore 자체가 없음 (`. ~/.bash_profile` 만) |
| `CTP/sql/src/com/navercorp/cubridqa/cqt/common/ShellInput.java:51` | SQL/CQT 의 별도 사본 | 위와 동일 |

본 이슈의 표면 증상은 shell 카테고리에서 발견됐지만, sql/medium 도 비표준 `$CUBRID` 경로 사용 시 같은 식으로 깨질 가능성이 있다 (별도 확인 필요).

## Test Build

- CTP: 현재 사용 중인 `~/CTP` (정확한 버전은 `TBD - 합의 미확인` — `cubridqa-common.jar` 의 빌드 식별자 확인 필요).
- CUBRID 설치: `/home/vimkim/.cub/install/feat-oos-m2-manual/debug_clang` (`$CUBRID` 환경변수로 export 됨).
- OS: RHEL 9.6 (5.14.0-570.30.1.el9_6.x86_64).

## Repro

```bash
# 셸 환경 — 비표준 위치에 CUBRID 설치, 그러나 ~/.bashrc 는 CUBRID=$HOME/CUBRID 를 export 함
export CUBRID=/home/vimkim/.cub/install/feat-oos-m2-manual/debug_clang
export PATH=$CUBRID/bin:$PATH
grep '^export CUBRID=' ~/.bashrc    # export CUBRID=$HOME/CUBRID
ls /home/vimkim/CUBRID 2>&1         # No such file or directory

# 직접 실행: 정상 (사용자 $CUBRID 를 따른다)
cd /home/vimkim/cubrid-testcases-private-ex/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize/cases
export init_path=/home/vimkim/CTP/shell/init_path
bash bigPageSize.sh   # 약 8 분, 끝까지 실행

# CTP 경유: 실패 (CTP 의 래퍼가 .bash_profile 소싱 후 $CUBRID 미복원)
just shell-debug /home/vimkim/cubrid-testcases-private-ex/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize
# 결과: time=0 으로 즉시 NOK
cat /home/vimkim/CTP/result/shell/current_runtime_logs/feedback.log | grep FileNotFoundException
# Exception in thread "main" java.io.FileNotFoundException:
#   /home/vimkim/CUBRID/conf/cubrid_broker.conf (No such file or directory)
```

## Expected Result

```bash
$ CUBRID=/path/to/custom/install ctp.sh shell -c shell_ci.conf
# init.sh 내부의 ini.sh 가 /path/to/custom/install/conf/cubrid_broker.conf 를 정상 읽음.
# 테스트가 실제 시간 (분 단위) 동안 실행되고 결과가 OK/NOK 로 정확히 떨어짐.
```

## Actual Result

CTP 가 매 shell exec 마다 `.bash_profile` 을 source 하고 `$CUBRID` 를 복원하지 않아 child shell 의 `$CUBRID` 가 `$HOME/CUBRID` 로 덮인다. `init.sh` 의 `ini.sh` 호출이 존재하지 않는 conf 파일을 열려다 `FileNotFoundException`. 테스트는 1 초 이내에 NOK 처리.

## Additional Information

### 관련 회귀 검증과의 연결

본 의존성 때문에 OOS 회귀 3 건 (CBRD-26813, 26814, 26815) 의 fix 검증을 CTP 가 아닌 직접 bash 실행으로 대체해야 했다. CTP 결과만 보면 패치 적용 후에도 `[NOK]` 이라 패치가 효과 없는 것처럼 오해할 위험이 있다.

### 워크어라운드 (임시)

`ln -s /home/vimkim/.cub/install/feat-oos-m2-manual/debug_clang /home/vimkim/CUBRID` 로 symlink 를 걸면 즉시 통과한다. 그러나 worktree 를 바꿀 때마다 symlink 를 다시 걸어야 하고, 두 worktree 를 동시에 쓰는 시나리오는 여전히 깨진다. 본 이슈로 해결되어야 할 항목이다.

또 다른 워크어라운드: `~/.bashrc` 에서 `export CUBRID=$HOME/CUBRID` 라인을 제거 (또는 `[ -z "$CUBRID" ] && export CUBRID=$HOME/CUBRID` 로 가드). 그러나 CUBRID 공식 설치 가이드와 다른 도구가 이 라인을 가정하므로 사용자 환경 전반에 부수효과가 있다.

## Implementation

### 1단계: `ScriptInput.java` 패치

`CTP/shell/src/com/navercorp/cubridqa/shell/common/ScriptInput.java:71` 의 래퍼 prefix 를 아래처럼 확장:

```java
return "pri_ctp_home=$CTP_HOME; pri_cubrid=$CUBRID; pri_cubrid_db=$CUBRID_DATABASES; pri_path=$PATH; pri_ld=$LD_LIBRARY_PATH; "
        + "if  [ -f ~/.bash_profile ]; then . ~/.bash_profile; fi; "
        + "if [ \"$pri_ctp_home\" != \"\" ]; then export CTP_HOME=${pri_ctp_home}; fi; "
        + "if [ \"$pri_cubrid\" != \"\" ]; then export CUBRID=${pri_cubrid}; fi; "
        + "if [ \"$pri_cubrid_db\" != \"\" ]; then export CUBRID_DATABASES=${pri_cubrid_db}; fi; "
        + "if [ \"$pri_path\" != \"\" ]; then export PATH=${pri_path}; fi; "
        + "if [ \"$pri_ld\" != \"\" ]; then export LD_LIBRARY_PATH=${pri_ld}; fi; "
        + LINE_SEPARATOR
        + "echo " + START_FLAG_MOCK + LINE_SEPARATOR + cmds.toString() + "echo " + COMP_FLAG_MOCK + LINE_SEPARATOR;
```

핵심: 부모 셸에 변수가 비어 있으면 `.bash_profile` 에서 흘러나온 값을 그대로 받아 기존 동작 유지. 비어 있지 않으면 부모 값을 강제 복원.

### 2단계: sibling 위치 동일 처리

`CTP/common/src/com/navercorp/cubridqa/common/ShellInput.java:50` 과 `CTP/sql/src/com/navercorp/cubridqa/cqt/common/ShellInput.java:51` 은 현재 save/restore 가 아예 없다. 동일 패턴 추가:

```java
if (scriptToRun == null) {
    scriptToRun = "pri_cubrid=$CUBRID; pri_cubrid_db=$CUBRID_DATABASES; pri_path=$PATH; pri_ld=$LD_LIBRARY_PATH; "
                + ". ~/.bash_profile; "
                + "if [ \"$pri_cubrid\" != \"\" ]; then export CUBRID=${pri_cubrid}; fi; "
                + "if [ \"$pri_cubrid_db\" != \"\" ]; then export CUBRID_DATABASES=${pri_cubrid_db}; fi; "
                + "if [ \"$pri_path\" != \"\" ]; then export PATH=${pri_path}; fi; "
                + "if [ \"$pri_ld\" != \"\" ]; then export LD_LIBRARY_PATH=${pri_ld}; fi;";
}
```

### 3단계: 빌드 / 배포

수정 대상은 Java 소스. jar 재빌드 (`CTP/common/lib/cubridqa-common.jar`, `CTP/shell/lib/cubridqa-shell.jar`, `CTP/sql/lib/cubridqa-cqt.jar`) 후 머지. 빌드 절차는 `TBD - 합의 미확인`.

### 4단계: 검증

`bigPageSize.sh` 를 `CUBRID=CUSTOM_PATH` (CUSTOM_PATH 는 비표준 install 경로) 세팅 후 `just shell-debug` 로 실행해 정상 시간 (5-10 분) 동안 동작, OK/NOK 가 실제 결과를 반영하는지 확인. 다른 shell 테스트 한두 개도 sanity check.

## Acceptance Criteria

- [ ] 사용자 셸에 `CUBRID` 가 비표준 경로로 export 된 상태에서 `ctp.sh shell -c CONF` (CONF 는 임의 conf) 가 그 경로를 따른다.
- [ ] `CUBRID` 가 export 되지 않은 환경에서는 `.bash_profile` 의 값이 그대로 사용된다 (regression 방지).
- [ ] `bigPageSize.sh` 를 `just shell-debug` 로 실행하면 `time=0` 이 아닌 실제 실행 시간 (분 단위) 이 기록된다.
- [ ] `feedback.log` 에 `FileNotFoundException: /home/.../CUBRID/conf/...` 가 더 이상 나오지 않는다.
- [ ] OOS 회귀 sub-task 3 건 (CBRD-26813/26814/26815) 의 fix 를 CTP 로 검증해 OK 가 떨어진다.

## Definition of done

- [ ] 위 A/C 충족.
- [ ] `cubridqa-common.jar`, `cubridqa-shell.jar`, `cubridqa-cqt.jar` 재빌드 및 PR merge.
- [ ] sql/medium 카테고리에서도 동일 시나리오 (비표준 `$CUBRID`) 가 정상 동작하는지 sanity check.

## 참고 코드

| 파일:줄 | 역할 |
|---|---|
| `CTP/shell/src/com/navercorp/cubridqa/shell/common/ScriptInput.java:71` | **주 수정 대상**. shell 모듈의 모든 exec 래퍼 prefix. `CTP_HOME` 만 save/restore, `CUBRID` 누락. |
| `CTP/common/src/com/navercorp/cubridqa/common/ShellInput.java:50` | **부 수정 대상**. SQL/medium/HA-repl/CDC-repl/isolation 공용. save/restore 없이 `. ~/.bash_profile` 만 수행. |
| `CTP/sql/src/com/navercorp/cubridqa/cqt/common/ShellInput.java:51` | **부 수정 대상**. SQL/CQT 의 동일 패턴. |
| `CTP/shell/init_path/init.sh:79, 776, 778, 780` | `ini.sh -s ... $CUBRID/conf/...` 호출들. 본 이슈의 표면 증상이 나타나는 지점. 본 파일은 수정하지 않는다. |
| `CTP/bin/ini.sh` | `IniCommand` Java 래퍼. 받은 경로를 그대로 사용. 책임 없음. |
| `CTP/shell/src/com/navercorp/cubridqa/shell/common/GeneralScriptInput.java` | `ScriptInput` 의 자식 클래스. `CTP_HOME` 재계산은 여기서도 수행하나 `CUBRID` 는 다루지 않는다. 참고용. |

## Remarks

- 동반 관련 sub-task: CBRD-26813 / CBRD-26814 / CBRD-26815 (OOS 회귀 3 건). 본 이슈가 풀려야 그 fix 들을 CTP 로 정상 검증 가능.
- 임시 워크어라운드 (`ln -s CUSTOM_INSTALL $HOME/CUBRID`, CUSTOM_INSTALL 은 실제 비표준 install 경로) 는 단일 worktree 환경에서만 통한다.
- 본 패치의 부수 효과로 `PATH`/`LD_LIBRARY_PATH` 도 부모 값으로 복원되므로, 사용자가 PATH 앞에 prepend 한 임의 디렉터리도 유지된다. 기존 동작이 `.bash_profile` 의 PATH 를 강제로 쓰던 점에 의존하는 케이스가 있는지 확인 필요.
