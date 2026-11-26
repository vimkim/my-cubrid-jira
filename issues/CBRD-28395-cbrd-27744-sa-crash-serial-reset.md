# [develop 회귀] CBRD-27562 (#8537) 이후 shell TC cbrd_27744_sa 의 SA 크래시 복구 serial 검사가 실패한다

**한 줄 요약**: 여러 PR 의 CI `test_shell` 에서 `cbrd_27744_sa` 가 반복 실패해 로컬에서 bisect 했고, 첫 bad commit 은 CBRD-27562 의 `e74826c46c` (#8537) 였다. 이 이슈는 그 변경 뒤 `csql -S` 강제 종료와 재시작 복구를 거친 serial 값이 TC 의 기대(CBRD-27744 의 수정 결과)와 달라지는 원인을 밝히고, 엔진과 TC 중 어디를 고칠지 정하는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: develop 에서 `cbrd_27744_sa` 가 다시 통과한다. 실패 원인이 엔진 동작(CBRD-27744 의 수정이 SA 크래시 복구에서 무력화됨)인지, TC 의 전제(크래시 전에 로그가 디스크에 닿음)가 깨진 것인지 밝히고 그에 맞게 고친다.

**이슈 수행 이유**: `shell/_06_issues/_26_2h/cbrd_27744_sa/cases/cbrd_27744_sa.sh` 의 13, 14번 검사가 실패한다. 로컬 bisect 에서 `e74826c46c` 의 부모 `9937d09` 는 통과하고 `e74826c46c` 부터 실패했다. 실패 PR 의 변경이 없는 develop `a5ab407` 에서도 같은 값으로 재현했다. #8537 과 CBRD-27744 의 엔진·TC 는 서로 다른 날 develop 에 들어와 함께 CI 를 거치지 않았다.

**영향**: develop 을 base 로 한 PR 의 `/run all` 에서 `test_shell` 이 이 TC 하나 때문에 실패한다. 2026-11-25 에 서로 다른 PR 5개의 CI 에서 같은 실패를 확인했다. 개발자는 PR 마다 이 실패가 자기 변경과 무관한지 따로 판단해야 하고, 실패가 남아 있는 동안 `test_shell` 이 green 이 되지 않는다. 엔진 쪽 원인이라면, SA 모드에서 DDL 트랜잭션이 크래시로 끝났을 때 이미 발급한 AUTO_INCREMENT 값이 복구 뒤 다시 발급될 수 있다(CBRD-27744 가 고친 동작). 어느 쪽인지는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

## Triage Request

- **분석 담당 제안**: #8537 작성자이자 CBRD-27562 담당자인 Joon Min(`hornetmj`)을 분석 담당으로 제안한다. 이것은 이 이슈 작성자(Daehyun Kim)의 제안이며, 배정과 우선순위는 triage 에서 정한다.

---

## AI-Generated Context

## Description

`cbrd_27744_sa` 는 CBRD-27744 의 수정을 SA 모드(`csql -S`)에서 확인하는 TC 다. `sa_crash` 시나리오는 다음 순서로 진행한다.

1. AUTO_INCREMENT `(1, 70000)` 인 테이블에 1 행을 넣는다. serial 의 `current_val` 은 1 이다.
2. 한 `csql -S` 트랜잭션(autocommit 끔)에서 `ALTER SERIAL ... MAXVALUE` 를 두 번 실행하고, 같은 트랜잭션에서 INSERT 두 번으로 70001, 140001 을 받는다.
3. 같은 트랜잭션에서 다른 테이블에 약 10MB 를 INSERT 한다(`INSERT ... SELECT REPEAT ('x', 2000) FROM db_class a, db_class b, db_class c LIMIT 5000`). TC 주석은 이것이 `log_buffer_size=4M` 보다 많은 로그를 만들어 DDL 과 INSERT 의 로그가 디스크에 닿게 하려는 것이라고 적는다.
4. `csql -S` 프로세스를 kill 한다. 다음 `csql -S` 가 복구하며 DDL 을 롤백한다.
5. 기대: serial 은 `140001 2147483647 1` 이다(이미 발급한 값을 롤백이 되돌리지 않음). 다음 INSERT 는 210001 을 받는다.

실제 결과는 serial `1 2147483647 1`, 다음 INSERT 70001 이다. 이 값은 DDL 트랜잭션이 남긴 변경이 복구 뒤 하나도 보이지 않는 상태와 같다. `max_val` 도 DDL 이전 값(2147483647)이므로 이 결과만으로는 아래 두 경우를 구분할 수 없다.

- (가) 크래시 복구의 DDL undo 가 CBRD-27744 이전처럼 `current_val` 까지 DDL 이전 값으로 되돌린다.
- (나) kill 시점에 DDL 트랜잭션의 로그와 serial 페이지가 디스크에 없어, 복구할 것이 없었다. 3번 단계의 INSERT ... SELECT 는 임시 파일을 쓸 수 있다(확인 안 함). 그렇다면 #8537 이 임시 sector 예약과 임시 볼륨 확장·추가에서 뺀 system operation 과 로그 flush 가 이 TC 에서 로그를 디스크로 보내던 경로였을 수 있다.

두 가설 모두 확인하지 않은 추론이다. (나)라면 커밋되지 않은 트랜잭션의 변경이 사라진 것이므로 엔진의 복구 결함이 아니라 TC 전제의 문제일 수 있다. (가)라면 엔진 결함이다.

## Test Build

| 엔진 (`CUBRID/cubrid`) | 결과 |
| --- | --- |
| `fb05460a1f` (develop `a5ab407` + PR #8736) | 13, 14 NOK (CI 와 같은 값) |
| `a5ab407ba0` (develop) | 13, 14 NOK (같은 값) |
| `510157f` | 13, 14 NOK |
| `47692d4`, `c0dee81` | 13 NOK |
| `e74826c46c` | 13 NOK |
| `9937d09e6b` (`e74826c46c` 의 부모) | 13 OK |

- first bad commit: [`e74826c46c55015c0b5e252dc03b057bea6afcdf`](https://github.com/CUBRID/cubrid/commit/e74826c46c55015c0b5e252dc03b057bea6afcdf) "[CBRD-27562] Do not start a system operation for temporary sector reservation or temporary volume growth ([#8537](https://github.com/CUBRID/cubrid/pull/8537))". 변경 파일은 `disk_manager.c`, `file_manager.c`, `boot_sr.c`, `btree_load.c`, `px_parallel.cpp` 다.
- bisect 는 13번 검사로 판정했다. `e74826c46c` 와 그 직후 커밋에서는 13번만 기록했고, 14번은 `510157f` 이후 커밋에서 함께 실패했다.
- 환경: 로컬 Linux debug 빌드, TC `cubrid-testcases-private-ex` `52eaedb2b`, CTP `cubrid-testtools` develop `db9b870`(TC 가 쓰는 `wait_until` 이 있는 버전).
- 병합 순서: #8537 의 마지막 `test_shell` 은 2026-11-21 에 통과했다. CBRD-27744 의 엔진 `44e9290f38` (#8460) 과 TC `fb02a1c72` (cubrid-testcases-private-ex #4809) 는 그 뒤 2026-11-24 에 들어왔다.

## Repro

로컬 bisect 에서 쓴 정확한 runner 명령은 기록하지 않았다. 아래는 같은 조건을 만드는 절차다.

1. `CUBRID/cubrid` 를 `9937d09e6b` 와 `e74826c46c` 에서 각각 debug 로 빌드·설치한다.
2. `cubrid-testtools` develop(`db9b870` 이후)의 CTP 로 shell TC `shell/_06_issues/_26_2h/cbrd_27744_sa/cases/cbrd_27744_sa.sh` 하나를 실행한다(TC 저장소 `cubrid-testcases-private-ex`, `fb02a1c72` 이후).
3. 결과 파일에서 13번(`sa_crash serial after recovery`)과 14번(`sa_crash ids`) 검사를 확인한다.

## Expected Result

- 13: `sa_crash serial after recovery` 가 `140001 2147483647 1` 이다.
- 14: `sa_crash ids` 가 `1 210001` 이다.

## Actual Result

- 13: `sa_crash serial after recovery: expected '140001 2147483647 1', got '1 2147483647 1'`
- 14: `sa_crash ids: expected '1 210001', got '1 70001'`
- 1-12번 검사(`sa_start`, `sa_own`, `sa_crash` 의 크래시 전 단계)는 통과한다.

## Additional Information

- **CI 에서 관찰한 실패** (모두 `test_shell`, 같은 13, 14번 값):

| PR | Run | Shard |
| --- | --- | --- |
| [#8753](https://github.com/CUBRID/cubrid/pull/8753) | [45615415274](https://github.com/CUBRID/cubrid/actions/runs/45615415274) | 16 |
| [#8754](https://github.com/CUBRID/cubrid/pull/8754) | [45617357842](https://github.com/CUBRID/cubrid/actions/runs/45617357842) | 16 |
| [#8686](https://github.com/CUBRID/cubrid/pull/8686) | [45637749074](https://github.com/CUBRID/cubrid/actions/runs/45637749074) | 00 |
| [#8693](https://github.com/CUBRID/cubrid/pull/8693) | [45624045146](https://github.com/CUBRID/cubrid/actions/runs/45624045146) | 16 |
| [#8736](https://github.com/CUBRID/cubrid/pull/8736) | [45603558494](https://github.com/CUBRID/cubrid/actions/runs/45603558494) | 35 |

- #8736 의 이전 run [45567167574](https://github.com/CUBRID/cubrid/actions/runs/45567167574)(엔진 `fd7d071`, base develop `bfb59bdd13`)에서는 이 TC 가 통과했다. `bfb59bdd13` 은 CBRD-27744 엔진 커밋 `44e9290f38` 을 포함하고 `e74826c46c` 는 포함하지 않는다.
- 다섯 run 은 서로 다른 PR 의 CI 다. 같은 시기의 다른 PR CI 중에는 이 TC 가 실패하지 않은 것도 있다. 그 차이가 각 PR 의 base 가 `e74826c46c` 와 CBRD-27744 를 모두 포함하는지에 따른 것인지는 확인하지 않았다.
- **ANALYSIS 확인 사항**:
  - 위 (가), (나) 중 어느 쪽인가. 예를 들어 kill 직전에 DDL 트랜잭션의 로그가 디스크에 있는지, 복구가 DDL undo(`RVHF_SERIAL_DDL_UPDATE_UNDO`)를 실행하는지 확인한다.
  - develop 에서 `e74826c46c` 만 revert 한 빌드가 13, 14번을 통과하는가. 통과하지 않으면 이 귀속은 틀린다.
  - (나)라면 TC 가 로그를 디스크로 보내는 방법을 임시 파일 경로에 기대지 않도록 바꿀지, 엔진이 이 경우에도 flush 해야 하는지 정한다.
- **중복 확인** (`cubrid-jira-dup candidate-find`, 2026-11-26): 이 증상을 다루는 이슈는 없다. 상위 후보 CBRD-28296, CBRD-28290, CBRD-28374, CBRD-28366 은 다른 shell TC 의 실패다. CBRD-28271, CBRD-28292, CBRD-28052 는 serial 행 저장과 로그 문제로, SA 크래시 복구 뒤 serial 값이 DDL 이전으로 돌아가는 이 증상과 다르다.
- **관련**: CBRD-27562(첫 bad commit 의 이슈), CBRD-27744(TC 가 확인하는 수정).
