# [SERIAL] 다른 페이지로 옮겨진 serial 행에 NEXT VALUE를 실행하면 home 슬롯을 덮어써 serial 카탈로그 힙이 손상된다

**한 줄 요약**: PR #8514(CBRD-28073) 리뷰에서 리뷰어 두 명이 각각 찾은 기존 결함이다. ALTER SERIAL로 커져 다른 페이지로 옮겨진(relocation) serial 행에 NEXT VALUE를 실행하면, 서버가 8바이트 forward 슬롯에 행 전체를 덮어써 `_db_serial` 힙이 손상된다. 이 이슈는 그 쓰기가 옮겨진 행의 실제 위치를 갱신하게 하는 것을 다룬다. 릴리스 11.4에서도 기본 설정과 SQL만으로 재현된다.

## Issue Triage

**이슈 수행 목적**: serial 행이 어느 저장 상태에 있든 NEXT VALUE와 캐시 write-back이 그 행을 올바르게 갱신한다. 또한 `_db_serial` 힙과 `checkdb` 결과가 정상으로 유지된다.

**이슈 수행 이유**: serial 값을 내줄 때 서버는 `heap_update`를 거치지 않는다. `serial_update_serial_object`가 OID의 home 페이지 슬롯을 직접 덮어쓴다. 행이 relocation 상태이면 home 슬롯에는 다른 페이지를 가리키는 8바이트 forward OID만 있다. 그런데도 서버는 그 슬롯에 행 전체를 쓰고 슬롯 종류는 `REC_RELOCATION`으로 그대로 둔다. 옮겨 간 쪽의 실제 행(`REC_NEWHOME`)은 갱신되지 않은 채 고아로 남는다. 이후 그 행을 읽으면 레코드 앞부분을 forward OID로 해석하게 된다. 4K 페이지, 기본 `unfill_factor`, 일반 SQL 문(CREATE/ALTER/DROP SERIAL, NEXT VALUE)만으로 재현된다. OOS는 필요하지 않다.

**영향**: 손상이 생긴 뒤에는 `db_serial` 조회, 해당 serial의 NEXT VALUE, `cubrid checkdb`가 모두 실패한다(debug 빌드에서 확인). NEXT VALUE 자체는 성공으로 끝나므로 손상 시점에는 아무 신호도 없다. 복구 redo는 같은 슬롯의 종류를 바꾸므로 crash 뒤 재시작한 DB는 실행 중 상태와 다른 모양으로 손상된다(소스 분석, 미실행). release 빌드에서 손상 뒤 읽기가 어떻게 끝나는지와 운영 DB에서의 발생 빈도는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 배경 용어

- **relocation**: heap 행이 갱신으로 커져 원래 페이지(home 페이지)에 들어가지 못하면 다른 페이지로 옮겨진다. OID는 바뀌지 않는다. home 슬롯은 `REC_RELOCATION` 종류의 8바이트 레코드가 되고 forward OID만 담는다. 실제 행은 forward 페이지에 `REC_NEWHOME` 종류로 저장된다.
- **serial 행**: `CREATE SERIAL`마다 `_db_serial`(11.4에서는 `db_serial`) 카탈로그 힙에 한 행이 생긴다. `ALTER SERIAL ... COMMENT`, `ALTER SERIAL ... INCREMENT BY` 등은 클라이언트가 일반 heap update로 이 행을 고친다. 그래서 행이 커지고 페이지에 자리가 없으면 relocation이 일어난다. comment는 최대 1024바이트라 serial 행이 페이지보다 커지지는 않는다. 그래서 `REC_BIGONE` 상태는 생기지 않는다.

### 결함 경로 (develop `48cfe21b07`)

1. NEXT VALUE(`xserial_get_next_value_internal`)와 캐시 write-back(`serial_store_cur_val_of_serial`)은 `heap_get_visible_version`으로 행을 읽는다. 그 뒤 `scan_cache.page_watcher.pgptr`와 `serial_oidp`를 `serial_update_serial_object`에 넘긴다([serial.c:1006-1008](https://github.com/CUBRID/cubrid/blob/48cfe21b078f68272a62227d197bc666cb3dd78d/src/query/serial.c#L1006-L1008), [serial.c:1079](https://github.com/CUBRID/cubrid/blob/48cfe21b078f68272a62227d197bc666cb3dd78d/src/query/serial.c#L1079), [serial.c:1261-1263](https://github.com/CUBRID/cubrid/blob/48cfe21b078f68272a62227d197bc666cb3dd78d/src/query/serial.c#L1261-L1263), [serial.c:1432](https://github.com/CUBRID/cubrid/blob/48cfe21b078f68272a62227d197bc666cb3dd78d/src/query/serial.c#L1432)).
2. 행이 `REC_RELOCATION`이면 읽기는 forward 페이지의 `REC_NEWHOME` 레코드를 복사해 돌려준다([heap_file.c:7722-7734](https://github.com/CUBRID/cubrid/blob/48cfe21b078f68272a62227d197bc666cb3dd78d/src/storage/heap_file.c#L7722-L7734)). 읽기가 끝나면 home 페이지는 `scan_cache->page_watcher`에 남고 forward 페이지는 unfix된다([heap_file.c:27736-27756](https://github.com/CUBRID/cubrid/blob/48cfe21b078f68272a62227d197bc666cb3dd78d/src/storage/heap_file.c#L27736-L27756)). 따라서 `serial_update_serial_object`가 받는 페이지는 home 페이지다.
3. `serial_update_serial_object`는 새 이미지의 종류를 읽은 레코드 종류(`REC_NEWHOME`)로 정한다. 그 이미지를 redo 전용 `RVHF_UPDATE`로 기록한 뒤 home 페이지의 `serial_oidp->slotid`에 `spage_update`한다([serial.c:1569-1578](https://github.com/CUBRID/cubrid/blob/48cfe21b078f68272a62227d197bc666cb3dd78d/src/query/serial.c#L1569-L1578)). 행 종류는 확인하지 않는다.
4. `spage_update`는 슬롯 데이터만 바꾸고 슬롯 종류는 바꾸지 않는다([slotted_page.c:2527](https://github.com/CUBRID/cubrid/blob/48cfe21b078f68272a62227d197bc666cb3dd78d/src/storage/slotted_page.c#L2527)). 결과적으로 home 슬롯은 `REC_RELOCATION` 종류에 행 전체 길이를 갖게 된다. forward 페이지의 `REC_NEWHOME`는 이전 값을 가진 채 아무도 가리키지 않는다.
5. 복구 redo(`heap_rv_undoredo_update` → `heap_update_physical`)는 같은 이미지를 쓴 뒤 슬롯 종류를 레코드 종류(`REC_NEWHOME`)로 바꾼다([heap_file.c:18400](https://github.com/CUBRID/cubrid/blob/48cfe21b078f68272a62227d197bc666cb3dd78d/src/storage/heap_file.c#L18400), [heap_file.c:24913-24917](https://github.com/CUBRID/cubrid/blob/48cfe21b078f68272a62227d197bc666cb3dd78d/src/storage/heap_file.c#L24913-L24917)). 실행 중에는 `REC_RELOCATION`, 재시작 뒤에는 `REC_NEWHOME`가 되어 실행 경로와 복구 경로의 결과가 다르다. 두 결과 모두 올바른 힙 상태가 아니다. 이 항목은 소스 분석이며 실행하지 않았다.

이 쓰기는 home 페이지에 새 이미지가 들어갈 자리가 있을 때만 성공한다. 즉 relocation 뒤 home 페이지에 공간이 생겨야 한다(같은 페이지의 다른 serial 삭제 등). 자리가 없으면 debug 빌드는 [serial.c:1573](https://github.com/CUBRID/cubrid/blob/48cfe21b078f68272a62227d197bc666cb3dd78d/src/query/serial.c#L1573)의 `spage_is_updatable` assert로 중단된다. release 빌드는 `ER_QPROC_CANNOT_UPDATE_SERIAL`을 반환한다. 이 경우는 공간 확인 전에 redo를 기록하는 별도 결함(같은 리뷰에서 함께 발견, 별도 이슈 초안)과 겹친다.

### 버전 범위

- 위 코드는 release/11.4(`065c452fe8`)에도 같다([serial.c:961-970](https://github.com/CUBRID/cubrid/blob/065c452fe82724f12c78e136f90cb6c595cbbc49/src/query/serial.c#L961-L970), [heap_file.c:7772-7783](https://github.com/CUBRID/cubrid/blob/065c452fe82724f12c78e136f90cb6c595cbbc49/src/storage/heap_file.c#L7772-L7783)). release/11.2(`67a6a27274`)의 `serial_update_serial_object`도 같은 순서다(소스 확인만 함).
- OOS와 무관하다. comment를 늘리는 `ALTER SERIAL ... COMMENT`만으로 relocation이 생긴다.
- develop은 `de7bc5ec26`(CBRD-26006, #6486, 2026-06-03)부터 고정 정밀도 NUMERIC을 값에 따라 4-20바이트로 저장한다(당시 `mr_data_lengthval_numeric`의 `_gv_mr_fixed_numeric_bytes_to_size[mr_get_fixed_numeric_size (numeric)]`). `2b3bb62543`(CBRD-27819)은 이 계산을 `numeric_repr_disk_size_by_value`로 옮겼을 뿐이다. 그래서 `ALTER SERIAL ... INCREMENT BY <큰 값>`도 행을 키워 relocation을 만들 수 있다. release/11.4는 정밀도로 크기가 정해지므로(`mr_data_lengthval_numeric` → `OR_NUMERIC_SIZE`) 이 경로는 없다. 하지만 comment 경로만으로 재현된다.

## Test Build

| 빌드 | 결과 | 실행자 |
|---|---|---|
| release/11.4 `82957b8f41` + 무관한 커밋 1개(`3a9eae91f0`, `log_page_buffer.c`만 변경), debug_gcc, 4K, **기본 `unfill_factor`** | 재현 | 이 초안 작성 중 |
| 같은 빌드, `unfill_factor=0` | 재현 | 이 초안 작성 중 |
| feature/oos-merge `71993ddb63`(PR #8514 base), debug, 4K, `unfill_factor=0`, `ALTER SERIAL ... INCREMENT BY 10^37`로 relocation | 재현 | PR #8514 리뷰어 R3, R5 |
| PR #8514 head `8d736ff51c`, debug, 4K, `unfill_factor=0` | 재현(R3). 새 이미지가 home 페이지에 들어가지 않은 변형에서는 assert로 중단되고 손상은 없었다(R5) | PR #8514 리뷰어 R3, R5 |
| develop `48cfe21b07` | 미실행. 관련 코드는 위와 같다 | — |

release 빌드, 16K 페이지, 서버 모드는 실행하지 않았다.

## Repro

CUBRID 설치(`$CUBRID`, `$CUBRID_DATABASES` 설정)에서 실행한다. `cubrid.conf`는 기본값을 쓰고(`unfill_factor` 미설정) SA 모드로 실행한다. 11.4에서는 카탈로그 이름이 `db_serial`이다. develop에서는 `_db_serial`로 바꾼다.

```bash
#!/bin/bash
db=pe2demo; dir=$CUBRID_DATABASES/$db
mkdir -p "$dir" && cd "$dir" || exit 1
cubrid createdb --db-volume-size=20M --log-volume-size=20M --db-page-size=4K --log-page-size=4K \
  $db en_US.utf8 -F "$dir" </dev/null || exit 1
rs() { head -c 9000 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
q() { echo "-- $1" | cut -c1-80; csql -S -u dba $db -c "$1" </dev/null; echo "exit=$?"; }
pg=$(csql -S -u dba $db -c "SHOW HEAP HEADER OF db_serial" </dev/null | awk "/'db_serial'/ {print \$5}")
slots() { csql -S -u dba $db -c "SHOW SLOTTED PAGE SLOTS OF VOLUME=0 AND PAGE=$pg" </dev/null | grep -E "^ +0 +$pg"; }

# 1. 한 페이지에 serial 4개를 만든다
q "CREATE SERIAL sg COMMENT '$(rs 100)'"
q "CREATE SERIAL sa COMMENT '$(rs 1000)'"
q "CREATE SERIAL sb COMMENT '$(rs 1000)'"
q "CREATE SERIAL sc COMMENT '$(rs 600)'"
# 2. sc를 키워 페이지 예약 공간을 쓰고, sg를 키워 relocation시킨다
q "ALTER SERIAL sc COMMENT '$(rs 1000)'"
q "ALTER SERIAL sg COMMENT '$(rs 1000)'"
slots            # sg 슬롯: 'RELOCATION', 길이 8
# 3. home 페이지에 공간을 만든다
q "DROP SERIAL sa"
q "DROP SERIAL sb"
# 4. NEXT VALUE
q "SELECT sg.NEXT_VALUE"
slots            # sg 슬롯: 'RELOCATION', 길이 1132 (손상)
q "SELECT sg.NEXT_VALUE"
q "SELECT name, current_val, length(comment) FROM db_serial"
cubrid checkdb -S $db; echo "checkdb exit=$?"
```

## Expected Result

모든 NEXT VALUE가 1, 2를 순서대로 반환한다. `db_serial` 조회는 `sc`, `sg`를 보여 준다. `checkdb`는 성공한다. sg 행은 relocation 상태를 유지하거나 home 슬롯으로 정상 이동한다. 어느 쪽이든 슬롯 종류와 내용이 서로 맞아야 한다.

## Actual Result

release/11.4 debug_gcc, 기본 `unfill_factor`(`SHOW HEAP HEADER`의 `Unfill_space` 405):

```
-- after ALTER sg
  0  3585  1   328  'RELOCATION'     8   0
-- SELECT sg.NEXT_VALUE   -> 1 (exit 0)
-- after NEXT VALUE #1
  0  3585  1  1460  'RELOCATION'  1132   0
-- SELECT sg.NEXT_VALUE   -> exit 134
csql: .../src/storage/page_buffer.c:10202: DISK_ISVALID pgbuf_is_valid_page(THREAD_ENTRY*, const VPID*, bool): Assertion `no_error' failed.
-- SELECT name, current_val, length(comment) FROM db_serial   -> exit 134 (같은 assert)
cubrid checkdb -S -> exit 254
cubrid: .../src/storage/heap_file.c:14239: DISK_ISVALID heap_check_heap_file(THREAD_ENTRY*, HFID*): Assertion `false' failed.
```

첫 NEXT VALUE는 성공으로 끝났다. 그 직후 home 슬롯은 `RELOCATION` 종류에 행 전체(1132바이트)를 담고 있다. 다음 읽기부터는 이 레코드의 앞 8바이트를 forward OID로 해석해 잘못된 페이지를 찾는다. PR #8514 base `71993ddb63`과 head `8d736ff51c`에서도 같은 assert 경로가 관측되었다(R3, `heap_file.c:17504`/`17600`의 `heap_check_heap_file`).

## Additional Information

### ANALYSIS에서 확인할 사항

- **release 빌드의 손상 뒤 동작**: debug의 `pgbuf_is_valid_page` assert 대신 무엇이 일어나는지 확인해야 한다. 오류 반환인지, 엉뚱한 페이지 읽기인지, 다른 serial과 AUTO_INCREMENT 컬럼, `unloaddb`에 어디까지 번지는지가 영향 범위를 정한다.
- **재시작 뒤 상태**: NEXT VALUE 뒤 page flush 전에 crash가 나면 redo가 home 슬롯을 `REC_NEWHOME`로 바꾼다(소스 분석). 이 상태에서 읽기, vacuum, `checkdb`가 어떻게 동작하는지 확인해야 한다.
- **발생 빈도**: 4K 페이지와 긴 comment에서는 위처럼 쉽게 재현된다. 16K 페이지에서는 한 페이지에 serial이 더 많이 모여야 한다. 운영 DB에 이미 이 상태가 있는지는 `checkdb`로 확인할 수 있다.
- **수정 범위**: 수정은 NEXT VALUE와 캐시 write-back 두 호출 경로를 모두 덮어야 한다. 기존 DB에 이미 생긴 손상을 복구할 수단이 필요한지도 정해야 한다.

### 관련 이슈

- [CBRD-28073](https://jira.cubrid.org/browse/CBRD-28073): 같은 함수(`serial_update_serial_object`)에서 NEXT VALUE가 OOS chain을 쓰지 않게 하는 이슈다. 이 결함은 그 PR(#8514) 리뷰에서 발견되었다. CBRD-28073은 ALTER 병합 경로의 "`REC_HOME`이 아닌 serial 행"을 미확인 사항으로 남겼다. 이 이슈는 NEXT VALUE 경로에서 그 상태가 실제로 생기고 힙을 손상시킨다는 것을 보인다. PR #8514는 이 경로를 바꾸지 않는다.
- [CBRD-28035](https://jira.cubrid.org/browse/CBRD-28035), [CBRD-28052](https://jira.cubrid.org/browse/CBRD-28052): 같은 함수의 OOS 관련 결함이다. 원인과 조건(OOS comment)이 다르다.
- 같은 리뷰에서 함께 발견된 "공간 확인 전 redo 기록" 결함(별도 이슈 초안): home 페이지에 새 이미지가 들어가지 않을 때 이 이슈와 같은 호출에서 이어진다. 원인과 수정 위치가 달라 분리한다.

### 분류 제안

- JIRA 유형: Correct Error. 일반 SQL 문으로 카탈로그 힙이 손상된다.
- 문제 범주: Correctness / data integrity, Reliability / recovery.
- 컴포넌트: serial(`src/query/serial.c`), heap(`src/storage/heap_file.c`).
