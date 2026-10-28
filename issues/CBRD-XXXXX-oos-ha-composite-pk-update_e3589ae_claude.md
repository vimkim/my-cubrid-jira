# [OOS] 복합 기본 키 테이블에서 OOS 값이 있는 행을 UPDATE하면 HA slave의 applylogdb가 assertion으로 반복 종료한다

## Issue Triage

**이슈 수행 목적**: 기본 키가 여러 컬럼인 테이블에서도 OOS 값이 있는 행의 UPDATE가 HA slave에 반영되게 한다.

**이슈 수행 이유**: 기본 키가 두 컬럼인 테이블에서 OOS 값이 있는 행을 UPDATE하면, slave의 applylogdb는 그 UPDATE의 OOS 복제 항목을 반영하다가 `ws_add_to_repl_obj_list`의 기본 키 값 assertion(`src/object/work_space.c:5379`)으로 종료한다. heartbeat가 applylogdb를 다시 띄워도 같은 항목에서 다시 종료한다. OOS가 아닌 컬럼만 바꿔도 발생하고, 행 하나로 매번 재현된다. 같은 UPDATE라도 기본 키가 한 컬럼이거나 행에 OOS 값이 없으면 정상 반영된다.

**영향**: 그 UPDATE 뒤로 slave에는 어떤 변경도 반영되지 않는다. standby는 계속 뒤처지면서도 standby 상태를 유지한다. 파티션 테이블은 기본 키에 파티션 키를 포함해야 하므로 이 조건에 자주 해당한다. optdebug build에서 확인했고, assertion이 빠지는 release build의 결과는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

UPDATE된 행에 OOS 값이 있으면 master는 행 항목 앞에 OOS 값마다 `RVREPL_OOS_INSERT` 복제 항목을 남긴다(`src/transaction/locator_sr.c`의 `locator_update_force` 경로, `repl_log_insert`에 `new_key`를 넘긴다). 현재 엔진은 UPDATE에서 바뀌지 않은 OOS 값도 새 chain으로 다시 쓰므로, OOS가 아닌 컬럼만 바꾼 UPDATE도 이 항목을 남긴다. 항목에는 행을 찾기 위한 기본 키 값이 들어 있다.

기본 키가 두 컬럼인 테이블에서는 slave의 applylogdb가 이 항목을 반영할 때 다음 assertion으로 종료한다.

```
cub_admin: src/object/work_space.c:5379: int ws_repl::ws_add_to_repl_obj_list(OID*, char*, int, RECDES*, int, bool, char*, int):
Assertion `packed_pkey_value != NULL && 0 < packed_pkey_va...' failed.
```

호출 경로는 다음과 같다(applylogdb crash 파일).

```
ws_repl::ws_add_to_repl_obj_list   src/object/work_space.c:5379
la_repl_add_object                 src/transaction/log_applier.c:5835
la_apply_oos_insert_log            src/transaction/log_applier.c:6349
la_apply_repl_log                  src/transaction/log_applier.c:6915
la_apply_log_file                  src/transaction/log_applier.c:9708
```

필요한 동작은 기본 키의 컬럼 수와 관계없이 slave가 같은 UPDATE를 반영하는 것이다. 원인, 곧 복합 키 값이 OOS 항목에 비어서 기록되는지 applylogdb가 그 값을 읽지 못하는지는 분석하지 않았다.

확인 근거(모두 행 하나, 9,000 B OOS 값 하나):

| 실행 | 기본 키 | 행의 값 | UPDATE | slave 결과 |
| --- | --- | --- | --- | --- |
| m1 | `(id, k)` | OOS | OOS 컬럼 | applylogdb assertion, 반영 안 됨 |
| m2 | `(id, k)` | OOS | `tag`만 | applylogdb assertion, 반영 안 됨 |
| m3 | `id` | OOS | OOS 컬럼 | 1초 안에 반영 |
| m5 | `(id, k)` | inline 10 B | `tag`만 | 1초 안에 반영 |

INSERT는 복합 기본 키에서도 정상 반영된다. 비활성 TC의 INSERT 단계도 두 노드에서 통과한다.

### 왜 문제인가

HA를 쓰는 운영자는 master의 모든 변경이 standby에 반영되어, master가 멈추면 standby가 같은 데이터로 서비스를 이어 받는다고 기대한다. 기본 키가 여러 컬럼인 테이블은 흔하다. 특히 파티션 테이블은 기본 키에 파티션 키를 포함해야 하므로, OOS 값이 있는 파티션 테이블의 거의 모든 UPDATE가 이 조건에 해당한다.

현재는 그런 UPDATE 하나로 standby의 복제가 멈춘다. applylogdb는 같은 항목에서 계속 종료하므로 그 뒤의 어떤 transaction도 반영되지 않는다. standby는 standby 상태를 유지하므로 heartbeat 상태만 보는 운영자는 이를 놓치기 쉽다. optdebug build에서는 applylogdb가 약 3초마다 다시 시작해 종료하며 crash 파일을 남겼다(30초 동안 37회에서 47회로 증가).

확인하지 않은 영향은 다음과 같다.

- failover 때 standby의 서버는 모든 applier가 끝난 뒤에만 active가 된다(`css_check_ha_log_applier_done`, `src/connection/server_support.c:1702`). 반영할 수 없는 항목이 남으면 failover가 끝나지 않거나, 반영되지 않은 데이터로 승격될 수 있다.
- release build에서는 assertion이 없으므로 applylogdb가 잘못된 키로 진행하거나 다른 오류를 낼 수 있다.

### 왜 해결해야 하는가

방치하면 OOS 컬럼이 있는 복합 기본 키 테이블, 특히 OOS 컬럼이 있는 파티션 테이블은 HA에서 쓸 수 없다. 첫 UPDATE에서 standby 복제가 멈추고, 그 뒤의 다른 테이블 변경까지 함께 멈춘다.

우회책은 기본 키를 한 컬럼으로 바꾸거나 OOS를 쓰지 않는 것뿐이다. 둘 다 스키마나 저장 정책을 바꾸는 일이라 운영 중인 테이블에 적용하기 어렵다. standby를 다시 구성해도 다음 UPDATE에서 같은 일이 생긴다.

OOS는 PR #8128과 `feature/oos-merge`를 거쳐 develop 병합을 준비하고 있다. HA 복제는 그 기능 범위에 들어 있으므로 병합 전에 원인과 수정 범위를 정해야 한다. 행 하나로 결정적으로 재현되고, 재현 TC가 이미 있다.

## Triage Request

이슈를 확인하고 OOS HA 복제 담당 측에 ANALYSIS를 배정해 주기를 요청한다. ANALYSIS에서 다음을 확인한다.

1. 복합 기본 키 값이 OOS 복제 항목에 어떻게 기록되는지, 비어 있다면 master와 applylogdb 중 어디서 비는지.
2. DELETE, MERGE, 파티션 이동, FK action처럼 OOS 항목을 남기는 다른 경로에도 같은 문제가 있는지.
3. release build와 `ha_copy_sync_mode=async`에서의 결과.
4. 반영할 수 없는 항목이 남은 standby에서 failover가 어떻게 끝나는지.
5. 수정 뒤 아래 재현 TC를 다시 켤 수 있는지.

## Test Build

- Engine: `e3589ae42d42b04eb020e1ae43e165b01d31b12a`(PR #8128 head, base `feature/oos-merge`), `CUBRID 11.5.0 (11.5.0.2793-e3589ae) (64bit optdebug build for Linux)`. `cubridci/cubridci:build_rl8.10`에서 `/entrypoint.sh build -m optdebug`로 만들었다.
- 실행 환경: `cubridci/cubridci:test_rl8.10`(`sha256:54e1835de00fa38c2539d268023ab1d34e653f0558f32f5f450e8b6b2721a15d`), `podman run --privileged`.
- HA 구성: 한 host에서 노드마다 network, UTS, PID, IPC, mount namespace를 두고 veth로 연결한 두 노드다(`cubrid-testcases-private-ex`의 `shell/_40_guava/oos_common/oos_ha_pair.sh`). `ha_copy_sync_mode=sync:sync`다. 노드 시작을 빠르게 하려고 heartbeat 타이머(`ha_init_timer_in_msec` 등 5개)를 1000 ms로 줄였다.
- 같은 assertion을 `ha_copy_sync_mode=async:async`에서도 한 번 보았다(파티션 테이블 UPDATE). release build와 물리적으로 분리된 두 host는 확인하지 않았다.

## Repro

두 노드 HA에서 master에 다음 SQL을 실행한다.

```sql
CREATE TABLE t (id INT, k INT, tag VARCHAR(8), a BIT VARYING, PRIMARY KEY (id, k));
INSERT INTO t VALUES (1, 1, 'x', CAST(REPEAT('ab', 9000) AS BIT VARYING));
UPDATE t SET tag = 'y' WHERE id = 1;
```

slave에서 `SELECT tag FROM t WHERE id = 1;`의 결과와 slave의 `$CUBRID/log/*applylogdb*.err`, `$CUBRID/log/coredump`를 확인한다.

같은 문제는 `cubrid-testcases-private-ex`의 `tc/pr-8128`에 있는 비활성 TC로도 재현된다(커밋 `479035a45`, PR #4365에 반영 예정).

```sh
cd cubrid-testcases-private-ex
mkdir -p shell/_40_guava/cbrd_26659_ha_composite_key/cases
cp disabled/failing/shell/_40_guava/cbrd_26659_ha_composite_key/cases/cbrd_26659_ha_composite_key.sh.disabled \
   shell/_40_guava/cbrd_26659_ha_composite_key/cases/cbrd_26659_ha_composite_key.sh
podman run --rm --privileged \
  -v <CUBRID install>:/home/CUBRID \
  -v <cubrid-testtools at 7dc9f41>:/home/cubrid-testtools \
  -v "$PWD":/home/cubrid-testcases-private-ex \
  -e TEST_SCENARIO=/home/cubrid-testcases-private-ex/shell/_40_guava/cbrd_26659_ha_composite_key \
  docker.io/cubridci/cubridci:test_rl8.10 /entrypoint.sh test shell
```

## Expected Result

slave의 `tag`가 1초 안팎에 `y`가 되고, applylogdb가 계속 실행된다.

## Actual Result

- slave의 applylogdb가 위 assertion으로 종료하고 heartbeat가 다시 띄울 때마다 같은 항목에서 다시 종료한다. 이 UPDATE 뒤에 master에서 commit한 barrier 행도 slave에 반영되지 않는다.
- slave는 `standby` 상태와 서버 프로세스를 유지했다. `cubrid heartbeat list`에는 copylogdb와 서버만 남는다.
- TC 결과는 `key.update: the slave did not apply the phase marker within 30s`이다. 같은 TC의 INSERT 단계(`key.insert`)는 두 노드에서 통과한다.
- standby의 `cubrid heartbeat start`가 아직 끝나지 않은 10초 안에 이 UPDATE가 반영되면, 그 utility의 점검이 죽은 applylogdb를 보고 heartbeat를 비활성화해 standby 서버도 멈추었다. 테스트 시점에 따른 현상이며, 위 결과는 그 utility가 끝난 뒤 관찰한 것이다.

## Additional Information

- 같은 TC 묶음의 활성 TC(`cbrd_26659_ha_queue`, `cbrd_26659_ha_async`)는 파티션 테이블의 기본 키를 파티션 키 하나로 두어 이 조건을 피한다.
- 함께 찾은 별도 문제: applylogdb가 flush를 미룬 동안 record buffer를 재사용해, slave에 다른 행의 레코드를 OOS 값으로 저장한다. 원인과 조건이 달라 별도 이슈로 작성한다.
