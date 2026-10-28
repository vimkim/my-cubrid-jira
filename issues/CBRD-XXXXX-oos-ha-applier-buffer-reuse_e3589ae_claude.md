# [OOS] [TODO] [bug] HA applylogdb가 flush를 미룬 동안 record buffer를 재사용해 slave에 다른 행의 레코드를 OOS 값으로 저장한다

## Issue Triage

**이슈 수행 목적**: 한 번에 많은 OOS 값을 복제해도 HA slave가 master와 같은 OOS 값을 저장하게 한다.

**이슈 수행 이유**: slave의 applylogdb는 반영할 항목마다 200개짜리 record buffer pool에서 버퍼를 차례로 꺼내 쓴다. OOS 값이 있는 행은 OOS 항목과 행 항목을 한 번에 보내려고, 버퍼가 200개 찬 뒤에도 행 항목이 올 때까지 flush를 미룬다. 그동안 새 항목이 아직 flush하지 않은 항목의 버퍼를 덮어쓰고, slave는 나중 행의 heap record를 앞선 행의 OOS 값으로 저장한다. OOS 값 두 개가 있는 행 67개를 INSERT ... SELECT 한 문장으로 넣으면 매번 재현된다.

**영향**: master에서 정상인 행을 slave에서 읽으면 `ER_HEAP_OOS_CORRUPTED_RECORD`로 실패한다. failover 뒤에는 새 master에서 그 행을 읽을 수 없다. `SHOW HEAP OOS`의 레코드 수는 같아서 행을 실제로 읽기 전에는 드러나지 않는다. optdebug build와 `ha_copy_sync_mode=sync`에서 확인했다. release build, async 모드, 행 항목의 버퍼가 덮이는 경우의 결과는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

OOS 값은 HA slave에 행보다 먼저 별도 항목으로 도착한다. master는 OOS 값마다 `RVREPL_OOS_INSERT` 복제 항목을 남기고, chunk chain이면 그 앞에 `RVREPL_DUMMY_OOS_RECORD`를 남긴다. 행 자체는 그 뒤의 `RVREPL_DATA_INSERT` 또는 `RVREPL_DATA_UPDATE` 항목이다. slave server는 같은 force area 안에서 OOS 항목을 먼저 저장하고, 새로 받은 OID를 행의 stub에 속성 순서대로 써 넣는다(`locator_fixup_oos_oids_in_recdes`, `src/transaction/locator_sr.c`).

applylogdb는 OOS 항목과 행 항목마다 `la_assign_recdes_from_pool`로 RECDES 하나를 받는다. 이 pool의 크기는 `LA_MAX_UNFLUSHED_REPL_ITEMS`, 곧 200이고(`src/transaction/log_applier.c:85`, `:9336`), 인덱스는 200에서 0으로 돌아간다. 원래는 flush하지 않은 항목이 200개가 되면 다음 항목 전에 flush하므로(`log_applier.c:5661`) 아직 쓰이는 버퍼가 재사용되지 않는다.

OOS 지원에서 추가된 `pending_oos_flush`는 마지막으로 쌓은 항목이 OOS 항목이면 flush를 하지 않는다(`log_applier.c:5656`). 행의 OOS 항목과 행 항목을 한 force area로 보내기 위해서다. 200번째 항목이 어떤 행의 OOS 항목이면 그 행의 남은 항목이 201번째, 202번째가 되고, 이 항목들은 pool 앞쪽의 버퍼를 받는다. 그 버퍼는 같은 묶음에서 아직 flush하지 않은 항목의 것이다. 확인한 결과, 앞선 행의 OOS 항목은 나중 행의 heap record를 OOS 값으로 slave에 저장했다.

필요한 동작은 항목 수나 flush 위치와 관계없이 slave의 모든 OOS 값이 master와 같은 것이다.

확인 근거:

- **최소 재현**: 단일 chunk OOS 값 두 개가 있는 행은 버퍼를 세 개(OOS 두 개, 행 하나) 쓴다. 66행(198개)은 slave에서 모두 정상이다. 67행이면 67번째 행의 두 번째 OOS 항목이 200번째가 되고, slave의 행 1을 읽을 수 없다.
- **큰 재현**: 행마다 OOS 값 0–4개와 chunk chain이 섞인 120행 INSERT ... SELECT(버퍼 440개)에서 slave의 행 1과 56만 읽을 수 없다. 위 모델로 계산하면 행 1과 56의 버퍼를 행 55와 110이 덮는다. 행 55와 110은 행 1과 56과 열 구성이 같다.
- **잘못 저장된 값은 heap record다**: slave에 저장된 잘못된 OOS 값 길이는 행의 heap record 크기를 따라 변한다. inline 값을 120 B에서 130 B로 늘리면 196 B에서 204 B로, varchar 값을 10자 늘리면 208 B로 바뀌었다.
- **바이트 합계**: 120행 재현에서 `SHOW HEAP OOS`의 `Oos_num_recs`는 두 노드 모두 480이지만 `Oos_recs_sumlen`은 master 4,110,080, slave 4,096,256이다. 차이 13,824 B는 (5,208 − 196) + (9,008 − 196)과 같다.
- **대조**: 같은 값의 행 하나만 넣으면 정상이다. `log_compress=no`에서도 같은 행이 같은 길이로 깨진다.

### 왜 문제인가

HA를 쓰는 운영자는 master가 멈추면 slave가 같은 데이터로 서비스를 이어 받고, 평소에는 slave에서 읽기 부하를 나눌 수 있다고 기대한다. OOS는 큰 값을 따로 저장하는 기능이므로, 큰 값을 여러 행에 한꺼번에 넣거나 고치는 일괄 적재와 일괄 수정이 대표적인 사용 형태다.

현재는 그런 transaction 하나로 slave의 일부 행이 손상된다. 손상된 행은 slave에서 읽으면 오류가 나고, failover 뒤에는 새 master에서도 읽을 수 없다. 그 OOS 값의 원본은 이전 master에만 있다. `SHOW HEAP OOS`의 레코드 수나 행 수는 두 노드에서 같으므로, 손상은 그 행을 읽을 때까지 보이지 않는다.

발생 조건은 결정적이다. flush하지 않은 항목이 200개에 이를 때 200번째가 OOS 항목이면 발생한다. 확인한 것은 transaction 하나가 200개를 넘는 경우다. 코드상 이 개수는 applylogdb가 자체 commit(`la_log_commit`)에서 flush할 때 0이 되므로, 짧은 시간에 commit된 작은 transaction 여러 개도 같은 조건이 될 수 있다. 이 경우는 확인하지 않았다.

아직 확인하지 않은 위험도 있다. 덮인 버퍼가 OOS 항목이 아니라 행 항목의 것이면, slave에 다른 행의 내용이 들어가거나 반영이 실패할 수 있다.

### 왜 해결해야 하는가

방치하면 OOS 컬럼이 있는 테이블은 HA에서 일괄 작업을 안전하게 할 수 없다. 손상이 조용히 남기 때문에 failover 시점에 드러날 수 있고, 그때는 이전 master 없이 값을 복구할 수 없다.

transaction을 작게 나누는 우회는 충분하지 않다. 경계는 applylogdb의 commit 간격 안에 쌓인 항목 수로 정해지므로 사용자가 통제할 수 없고, 행의 OOS 값 개수에 따라 안전한 크기도 달라진다. 손상을 찾으려면 slave의 모든 OOS 행을 읽어야 하고, 고치려면 slave를 다시 구성해야 한다.

OOS는 PR #8128과 `feature/oos-merge`를 거쳐 develop 병합을 준비하고 있다. HA 복제는 그 기능 범위에 들어 있으므로, 병합 전에 원인과 수정 범위를 정해야 한다. 재현 TC는 이미 있다.

## Triage Request

이슈를 확인하고 OOS HA 복제 담당 측에 ANALYSIS를 배정해 주기를 요청한다. ANALYSIS에서 다음을 확인한다.

1. 위 원인 설명(pool 재사용과 flush 연기의 충돌)이 맞는지, 다른 경로도 같은 버퍼를 공유하는지.
2. release build와 `ha_copy_sync_mode=async`에서도 같은 결과인지.
3. 덮인 버퍼가 행 항목일 때 slave에 어떤 결과가 남는지.
4. 작은 transaction 여러 개가 applylogdb commit 간격 안에 200개를 넘길 때도 발생하는지.
5. 수정 뒤 아래 재현 TC를 다시 켤 수 있는지.

## Test Build

- Engine: `e3589ae42d42b04eb020e1ae43e165b01d31b12a`(PR #8128 head, base `feature/oos-merge`), `CUBRID 11.5.0 (11.5.0.2793-e3589ae) (64bit optdebug build for Linux)`. `cubridci/cubridci:build_rl8.10`에서 `/entrypoint.sh build -m optdebug`로 만들었다.
- 실행 환경: `cubridci/cubridci:test_rl8.10`(`sha256:54e1835de00fa38c2539d268023ab1d34e653f0558f32f5f450e8b6b2721a15d`), `podman run --privileged`.
- HA 구성: 한 host에서 노드마다 network, UTS, PID, IPC, mount namespace를 두고 veth로 연결한 두 노드다(`cubrid-testcases-private-ex`의 `shell/_40_guava/oos_common/oos_ha_pair.sh`). `ha_copy_sync_mode=sync:sync`, `ha_apply_max_mem_size=300`이다. 노드 시작을 빠르게 하려고 heartbeat 타이머(`ha_init_timer_in_msec` 등 5개)를 1000 ms로 줄였다.
- 확인하지 않은 환경: release build, async 모드, 물리적으로 분리된 두 host.

## Repro

두 노드 HA에서 master에 다음 SQL을 실행한다.

```sql
CREATE TABLE t2 (id INT PRIMARY KEY, a BIT VARYING, b BIT VARYING);
INSERT INTO t2
  SELECT LEVEL,
         CAST(CONCAT(LPAD(HEX(LEVEL), 8, '0'), REPEAT('aa', 8996)) AS BIT VARYING),
         CAST(CONCAT(LPAD(HEX(LEVEL), 8, '0'), REPEAT('bb', 8996)) AS BIT VARYING)
  FROM db_root CONNECT BY LEVEL <= 67;
```

slave가 이 commit을 반영한 뒤 slave에서 실행한다.

```sql
SELECT id, OCTET_LENGTH(a), OCTET_LENGTH(b) FROM t2 WHERE id = 1;
```

`LEVEL <= 66`이면 정상이다.

같은 문제는 `cubrid-testcases-private-ex`의 `tc/pr-8128`에 있는 비활성 TC로도 재현된다([커밋 `479035a45`](https://github.com/CUBRID/cubrid-testcases-private-ex/commit/479035a45f06545db1974e1369e88000fb98a89a), [PR #4365](https://github.com/CUBRID/cubrid-testcases-private-ex/pull/4365)). TC는 120행 INSERT ... SELECT를 쓴다. 다른 TC에 영향을 주지 않도록 실행 전에 원래 위치로 옮긴다.

```sh
cd cubrid-testcases-private-ex
mkdir -p shell/_40_guava/cbrd_26659_ha_flush_boundary/cases
cp disabled/failing/shell/_40_guava/cbrd_26659_ha_flush_boundary/cases/cbrd_26659_ha_flush_boundary.sh.disabled \
   shell/_40_guava/cbrd_26659_ha_flush_boundary/cases/cbrd_26659_ha_flush_boundary.sh
podman run --rm --privileged \
  -v <CUBRID install>:/home/CUBRID \
  -v <cubrid-testtools at 7dc9f41>:/home/cubrid-testtools \
  -v "$PWD":/home/cubrid-testcases-private-ex \
  -e TEST_SCENARIO=/home/cubrid-testcases-private-ex/shell/_40_guava/cbrd_26659_ha_flush_boundary \
  docker.io/cubridci/cubridci:test_rl8.10 /entrypoint.sh test shell
```

## Expected Result

slave의 모든 행이 master와 같다. 최소 재현의 slave 조회 결과는 `1`, `9000`, `9000`이다.

## Actual Result

- 최소 재현: slave에서 행 1의 조회가 `ERROR: Internal error: out-of-row storage record metadata is inconsistent or corrupted.`(`ER_HEAP_OOS_CORRUPTED_RECORD`, -1389)로 실패한다. slave server log에는 `OOS length mismatch: caller=9008 header=52 at oid={vol=1,page=898,slot=0}`(`src/storage/oos_file.cpp:2778`)이 남는다. master에서는 67행 모두 정상이다.
- 120행 TC: slave의 행 1과 56이 같은 오류로 실패한다(`caller=5208 header=196`, `caller=9008 header=196`). TC 결과는 `batch.each_row on oos-ha-node-b: rows not equal to the model or not readable: 1 56`이다. 120행 재현은 TC 2회와 probe 5회(값 크기를 바꾼 2회 포함)에서 모두 행 1과 56이었다.

## Additional Information

- 관련 코드: `LA_MAX_UNFLUSHED_REPL_ITEMS`(`log_applier.c:85`), pool 초기화(`log_applier.c:9336`), `la_assign_recdes_from_pool`, `la_flush_repl_items`의 `pending_oos_flush` 조건(`log_applier.c:5656`), `la_apply_oos_insert_log`의 `pending_oos_flush` 설정(`log_applier.c:6366`).
- 원인 설명은 코드 읽기와 위 실행 결과를 맞춘 것이다. 버퍼 덮어쓰기를 디버거로 직접 관찰하지는 않았다.
- 같은 TC 묶음의 활성 TC(`cbrd_26659_ha_queue`, `cbrd_26659_ha_async`)는 barrier 사이 항목을 200개 아래로 두어 이 조건을 피한다.
- 함께 찾은 별도 문제: 복합 기본 키 테이블에서 OOS 값이 있는 행을 UPDATE하면 slave의 applylogdb가 assertion으로 반복 종료한다. 원인과 조건이 달라 별도 이슈로 작성한다.
