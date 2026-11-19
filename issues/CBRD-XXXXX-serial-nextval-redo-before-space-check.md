# [SERIAL] 페이지 공간이 부족해 실패한 NEXT VALUE가 redo 로그를 남겨, 장애 후 DB를 재시작할 수 없다

**한 줄 요약**: PR #8514(CBRD-28073) 리뷰에서 Greptile이 지적한 "redo 로그도 공간 확보를 확인한 뒤 기록해야 한다"([리뷰 댓글](https://github.com/CUBRID/cubrid/pull/8514#discussion_r4627183032))를 검증하다 develop에도 있는 기존 결함으로 확인하여, 실패한 serial 갱신이 남긴 redo 로그 때문에 장애 후 DB를 재시작할 수 없게 되는 문제를 다루는 후속 이슈다.

## Issue Triage

**이슈 수행 목적**: serial 행 갱신(NEXT VALUE, serial cache 값 기록)이 페이지 공간 부족으로 실패하더라도, 그 뒤 장애가 나면 DB가 정상적으로 재시작되게 한다.

**이슈 수행 이유**: `serial_update_serial_object`는 새 행을 같은 slot에 덮어쓰기 전에 redo 전용 로그(`RVHF_UPDATE`)를 먼저 남긴다. 공간 확인은 debug 빌드에만 있는 `assert`라서, release 빌드에서 새 행이 페이지에 들어가지 않으면 갱신은 `ER_QPROC_CANNOT_UPDATE_SERIAL`로 실패하지만 redo 로그는 그대로 남는다. 그 뒤 다른 커밋이 로그를 디스크에 쓰고, 다음 checkpoint 전에 서버가 죽으면 restart recovery가 이 로그를 적용하다 실패해 서버가 fatal error로 멈춘다. develop에서 NUMERIC 디스크 크기가 값에 따라 달라지면서(CBRD-26006) NEXT VALUE가 serial 행을 키울 수 있게 되었고, 그래서 이 경로에 도달할 수 있다. develop release 빌드와 OOS 브랜치 base release 빌드에서 재현했다.

**영향**: 해당 DB는 재시작할 때마다 같은 redo 로그에서 멈추고, `cubrid checkdb`도 같은 오류로 실행되지 않는다. 운영자는 서버를 띄울 정상 경로를 잃는다. 장애가 없더라도 해당 serial의 NEXT VALUE는 페이지에 공간이 생길 때까지 계속 실패한다. 발생 조건은 좁다. serial 행이 있는 heap 페이지의 여유 공간이 값 증가분(최대 16바이트)보다 작아야 하며, 재현에서는 `unfill_factor=0`으로 만든 DB를 썼다. 기본 설정(`unfill_factor=0.1`)에서 다른 갱신이 예약 공간을 소진해 이 상태가 되는 빈도는 확인하지 않았다. 출시된 11.4는 NUMERIC 크기가 정밀도로 고정되어 알려진 발생 조건이 없다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 무엇이 잘못되는가

`_db_serial`의 `current_val`은 `NUMERIC(38,0)`이다(`schema_system_catalog_install.cpp:921`). develop에서는 CBRD-26006(`de7bc5ec26`, #6486)부터 NUMERIC이 가변 길이 타입이고(`object_primitive.c:1636`), 디스크 크기가 값의 크기에 따라 4, 8, 12, 16, 20바이트로 달라진다(`numeric_opfunc.h:305` `numeric_repr_disk_size_by_value`, `object_primitive.c:8689`). 그래서 NEXT VALUE로 값이 커지면 serial 행이 최대 16바이트 커진다.

`serial_update_serial_object`(develop `48cfe21b07` 기준 `src/query/serial.c`)는 다음 순서로 행을 갱신한다.

| 순서 | 위치 | 동작 |
|---|---|---|
| 1 | `serial.c:1573` | `assert (spage_is_updatable (...))`. debug 빌드에서만 공간을 확인한다. |
| 2 | `serial.c:1575` | `log_append_redo_recdes (RVHF_UPDATE)`. 새 행 전체를 redo 전용 로그로 남기고 페이지 LSA를 이 로그로 올린다. |
| 3 | `serial.c:1578` | `spage_update`. 같은 slot에 덮어쓴다. 공간이 부족하면 `SP_DOESNT_FIT`. |
| 4 | `serial.c:1581`, `1614-1618` | `ER_QPROC_CANNOT_UPDATE_SERIAL`을 설정하고 `log_sysop_abort`. redo 전용 로그는 undo가 없으므로 취소되지 않는다. |

release 빌드에서는 1번이 없으므로, 새 행이 들어가지 않으면 디스크 페이지에는 적용되지 않은 redo 로그가 남는다. 이후 다른 커밋이 로그를 디스크에 쓰고, checkpoint가 redo 시작 위치를 이 로그 뒤로 옮기기 전에 서버가 죽으면 restart recovery는 다음 경로로 멈춘다.

- `log_rv_redo_record_sync` → `heap_rv_undoredo_update`(`heap_file.c:18400`) → `heap_update_physical`(`heap_file.c:24877`)의 `spage_update`가 런타임과 같은 이유로 실패하고 `ER_FAILED`를 돌려준다.
- `log_rv_redo_record_sync`가 redo 실패를 `logpb_fatal_error`로 처리한다(`log_recovery_redo.hpp:665-671`).
- 재시작할 때마다 같은 로그를 다시 적용하므로 결과가 같다.

호출 경로는 NEXT VALUE(`xserial_get_next_value_internal`, `serial.c:1432`)와 serial cache 값 기록(`serial_store_cur_val_of_serial`, `serial.c:1079`)이다.

### 발생 조건 (트리거)

이 결함은 같은 slot에서 행이 커지는데 페이지에 공간이 없을 때 드러난다. `serial_update_serial_object`는 다른 페이지로 행을 옮기는 경로가 없어서, 이 조건에서는 release 빌드에서 NEXT VALUE가 실패하고 debug 빌드에서는 1번 assert로 서버가 abort한다. 이 조건 자체는 OOS와 무관하며 OOS 브랜치 base와 develop의 일반 inline 행에서 같다.

- serial 행이 들어 있는 heap 페이지의 여유 공간이 이번 증가분보다 작다.
- `current_val`이 더 큰 크기 구간으로 넘어간다. 크기 구간 경계는 값의 바이트 수 기준으로 1, 2-5, 6-9, 10-13, 14-16바이트다.
- `heap_hdr->unfill_space`는 heap을 만들 때 정해진다. 재현은 `unfill_factor=0`으로 `createdb`한 DB를 썼다. 기본값 `unfill_factor=0.1`에서는 4K 페이지마다 405바이트를 남기므로, serial 160개를 균일하게 키운 시험에서는 실패하지 않았다(PR #8514 리뷰 R3 S3). 다른 갱신(예: `ALTER SERIAL ... COMMENT`로 이웃 행이 커짐)이 이 예약 공간을 먼저 쓰면 기본 설정에서도 같은 상태가 된다(리뷰 R5가 `ALTER`로 12바이트 여유 상태를 만듦).

### 재현 결과

| 빌드 | 결과 | 근거 |
|---|---|---|
| develop release `11.5.0.2906-a7f220d`(2026-11-12, OOS 없음) | NEXT VALUE `ERROR: Cannot update serial object.` 이후 restart와 `checkdb` 모두 `LOG FATAL ERROR: log_rv_redo_record_sync: Error applying redo record at log_lsa=(792, 1752), rcv = {mvccid=0, vpid=(0, 3777), offset = 1, data_length = 766}`. 두 번째 재시작도 같은 오류. | 이 이슈 작성 중 실행 |
| `feature/oos-merge` base release `11.5.0.3036-71993dd` | 같은 오류, `log_lsa=(794, 1560)`, `data_length = 766`, `heap_file.c:26334` | PR #8514 리뷰 R3 S6' base |
| PR #8514 head release `8d736ff51c` | 같은 오류(`log_lsa=(794, 1232)`) | PR #8514 리뷰 R3 S6' |
| 대조: 실패 뒤 로그 flush 없이 kill | 재시작 정상 | PR #8514 리뷰 R3 S6-noflush |

`a7f220d`와 develop `48cfe21b07` 사이에 `serial.c`, `log_recovery_redo.hpp`, `slotted_page.c`는 바뀌지 않았고, `heap_file.c`의 변경도 `heap_update_physical`과 `heap_rv_undoredo_update`에는 닿지 않는다.

PR #8514 리뷰의 R5는 debug 빌드를 gdb로 조작해 release 경로를 흉내 낸 1회 시험에서, 실패 뒤 커밋하고 kill했는데도 재시작이 정상이었다. 원인은 밝히지 못했다. 위 release 빌드 재현 세 건과 결과가 다르므로, redo가 건너뛰어지는 조건(예: 디스크 페이지 LSA가 이미 이 로그보다 큰 경우)은 ANALYSIS에서 확인한다.

### Test Build

- develop release 빌드 `11.5.0.2906-a7f220d`, SA 모드, 4K 페이지. 원 소스 기준은 develop `48cfe21b078f68272a62227d197bc666cb3dd78d`이다.

### Repro

`$CUBRID`가 release 빌드 설치 경로를 가리키고 `$CUBRID/conf/cubrid.conf`의 `[common]`에 다음을 둔다. checkpoint 설정은 재현 중 checkpoint가 끼어들지 않게 하려는 것이다.

```
unfill_factor=0
checkpoint_interval=60min
checkpoint_every_size=1G
```

```bash
db=pe1db; dir=$HOME/pe1/$db; mkdir -p "$dir" && cd "$dir"
cubrid createdb --db-volume-size=20M --log-volume-size=20M \
  --db-page-size=4K --log-page-size=4K $db en_US.utf8 -F "$dir"

B=10000000000000000000000000000000000000   # 10^37: 두 번째 값에서 current_val이 4 -> 20바이트
rc() { C=$(head -c 6000 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | head -c "$2");
       echo "CREATE SERIAL $1 START WITH 1 INCREMENT BY $3 COMMENT '$C';"; }
{ rc sa 600 $B; rc sb 600 $B; rc sc 600 $B; rc sg 468 1; echo "SELECT sa.NEXT_VALUE;"; } > s1.sql
csql -S -u dba $db -i s1.sql

# serial 행이 있는 페이지의 여유 공간 확인: 헤더 행의 total free가 8이어야 한다.
csql -S -u dba $db -c "SHOW SLOTTED PAGE HEADER OF VOLUME=0 AND PAGE=3777; SHOW SLOTTED PAGE SLOTS OF VOLUME=0 AND PAGE=3777"

# 실패하는 NEXT VALUE, 그 뒤 로그를 flush하는 커밋, 그리고 프로세스 강제 종료
printf 'SELECT sa.NEXT_VALUE;\nCREATE TABLE pe1t (a int);\nINSERT INTO pe1t VALUES (1);\nSELECT SLEEP(120);\n' > s2.sql
csql -S -e -u dba $db -i s2.sql > s2.out 2>&1 &
pid=$!
until grep -q 'row affected' s2.out; do sleep 1; done; sleep 2
kill -9 $pid

# 재시작(recovery)과 checkdb
csql -S -u dba $db -c "SELECT name, current_val FROM _db_serial"
cubrid checkdb -S $db
```

페이지 번호(3777)와 여유 공간은 리비전에 따라 다를 수 있다. 여유 공간이 16바이트 이상이면 `sg`의 comment 길이를 늘려 8바이트로 맞춘다. 예를 들어 base `71993dd`에서는 heap 헤더 행이 8바이트 더 커서 `sg`가 460자일 때 여유 공간이 8바이트였다.

### Expected Result

- 실패한 serial 갱신은 restart recovery가 적용할 수 없는 로그를 남기지 않는다.
- 장애 뒤 재시작과 `checkdb`가 정상 완료되고, serial 값은 실패 직전의 커밋된 값(`sa`의 `current_val` 1)이다.

### Actual Result

```
In the command from line 1,
ERROR: Cannot update serial object.
...
*** FATAL ERROR ***
LOG FATAL ERROR: log_rv_redo_record_sync: Error applying redo record at log_lsa=(792, 1752), rcv = {mvccid=0, vpid=(0, 3777), offset = 1, data_length = 766}
... ABORT/EXIT IMMEDIATELY ...
```

`checkdb`도 같은 메시지로 종료 코드 1을 돌려준다. 오류 로그에는 `heap_file.c`의 `heap_update_physical`(ER_GENERIC_ERROR)과 `log_recovery_redo.hpp:667`(ER -644)의 FATAL 두 건이 남는다.

### 영향 버전

| 대상 | 판단 | 근거 |
|---|---|---|
| develop (`48cfe21b07`) | 영향 있음 | 소스(`serial.c:1573-1581`) + release 빌드 `a7f220d` 재현 |
| `feature/oos-merge` (base `71993ddb63`) | 영향 있음 | base release 빌드 재현. OOS는 필요 조건이 아니다. |
| release/11.4 (`065c452fe8`) | 알려진 발생 조건 없음 | 같은 순서의 코드가 있으나(`serial.c:965-970`), NUMERIC 크기가 정밀도로 고정되어(`tp_Numeric` 가변 아님, `mr_data_lengthval_numeric`가 `OR_NUMERIC_SIZE (precision)`) NEXT VALUE가 행을 키우지 않는다. 소스 판독만 했다. |

develop에서 NUMERIC 크기가 값에 따라 달라진 것은 CBRD-26006(`de7bc5ec26`, 2026-06-03)부터다. 그 이전 develop과 11.4 계열에서는 이 경로로 행이 커지지 않는다.

### Additional Information

- **오류 경로의 replication flush mark (부수 사항, 소스만 확인)**: `serial_update_serial_object`는 시작할 때 `repl_start_flush_mark`(`serial.c:1556`)를 부르지만, `exit_on_error` 경로(`serial.c:1614-1621`)는 `repl_end_flush_mark`를 부르지 않는다. 그래서 갱신이 실패하면 `tdes->fl_mark_repl_recidx`가 트랜잭션 종료까지 설정된 채 남고, 같은 트랜잭션의 이후 replication 레코드가 `LOG_REPL_NEED_FLUSH`로 표시될 수 있다(`replication.c:483-505`, `658`). HA에서 실제로 어떤 차이가 생기는지는 확인하지 않았다.
- **server 모드**: 재현은 모두 SA 모드에서 프로세스를 `kill -9`한 것이다. recovery redo 코드는 server 모드와 같으므로 같은 결과가 예상되나 실행하지 않았다.
- **같은 함수의 다른 기존 결함**: 같은 리뷰에서 relocation된 `_db_serial` 행에 NEXT VALUE가 home slot을 덮어쓰는 문제도 찾았다. 원인과 결과가 달라 별도 이슈로 다룬다.

### ANALYSIS에서 확인할 사항

- 공간 확인을 redo 로그 앞으로 옮기는 것만으로 충분한가, 아니면 같은 slot에 들어가지 않을 때 행을 옮기거나 최대 증가분을 미리 확보해 NEXT VALUE 자체가 성공해야 하는가. 후자는 이 이슈에 포함할지, 별도 이슈로 나눌지 triage가 정한다.
- 이미 이 상태에 빠진 DB를 복구하는 절차가 있는가.
- R5 시험에서 재시작이 정상이었던 조건이 무엇이며, 그 조건이 결함의 노출 범위를 줄이는가.
- 기본 `unfill_factor`에서 예약 공간이 소진되는 현실적인 작업 패턴이 있는가.

### 관련 이슈

| 이슈 | 관계 |
|---|---|
| [CBRD-28073](https://jira.cubrid.org/browse/CBRD-28073) | NEXT VALUE가 serial 행의 저장 형태를 유지하게 하는 이슈(PR #8514). 이 결함을 찾은 리뷰의 대상이다. [댓글 4778798](https://jira.cubrid.org/browse/CBRD-28073?focusedCommentId=4778798#comment-4778798)은 같은 순서 문제를 debug 빌드 에뮬레이션과 소스 판독으로 보고하며 CBRD-28073에 남는 문제로 적었다. 이후 PR #8514의 리뷰 답변에서 별도 이슈로 다루기로 했으므로 이 이슈가 그 후속이다. 같은 댓글은 `oos_trigger_threshold`를 높여 OOS comment가 inline으로 돌아오는 경우도 행을 키우는 트리거로 들었다. PR #8632(CBRD-28062)가 시스템 클래스 행에 이 파라미터를 적용하지 않기로 해 그 경로는 막힌다. |
| [CBRD-28035](https://jira.cubrid.org/browse/CBRD-28035), [CBRD-28052](https://jira.cubrid.org/browse/CBRD-28052) | 같은 `serial_update_serial_object`의 redo 전용 쓰기 경로에서 생긴 OOS chain 누수와 SA 롤백 손상. 원인(OOS chain 쓰기)과 결과가 달라 이 이슈와 중복되지 않는다. |

### 참고

- PR #8514 리뷰 보고서: [code-review-pr8514.md, Pre-existing defects PE1](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-28073/code-review-pr8514.md#pre-existing-defects-found-not-attributed-to-this-pr-separate-cbrd-issues-recommended)
- Greptile 리뷰 댓글과 답변: [discussion_r4627183032](https://github.com/CUBRID/cubrid/pull/8514#discussion_r4627183032)
