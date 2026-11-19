본문의 "재시작 뒤 상태(소스 분석, 미실행)", "develop 미실행", "서버 모드 미실행" 항목을 develop에서 직접 실행해 확인한 결과를 공유합니다. 증거 수준은 항목마다 적었습니다(실행 = 직접 실행, 에뮬레이션 = debug 빌드를 gdb로 조작, 소스 = 코드 판독).

**조건 (실행)**

* develop `de4f32740e`, debug 빌드(gcc), `--db-page-size=4K --log-page-size=4K`, 기본 `unfill_factor`. OOS 코드는 없습니다.
* comment 없는 serial 80개(행 116바이트)를 만들면 `s21`~`s49`가 한 페이지(`0|3782`, 여유 500바이트)에 들어갑니다.
* `ALTER SERIAL s30 COMMENT '<무작위 1000자>'`로 relocation이 생깁니다. home 슬롯 `0|3782|10`은 `RELOCATION` 8바이트가 되고, 실제 행은 `0|3784|3`에 `NEWHOME` 1140바이트로 갑니다.
* home 페이지에 자리를 만들 때는 같은 페이지의 `s21`~`s26`을 DROP합니다(여유 1304바이트).

**1. 실행 중 손상 (실행, SA)**

* NEXT VALUE는 `1`을 돌려주며 성공합니다. 직후 home 슬롯은 `RELOCATION` 종류에 1140바이트이고, `0|3784|3`의 `NEWHOME`는 고아로 남습니다. 본문의 11.4 결과와 같습니다.
* 그 뒤 `s30` 조회, `select count(*) from db_serial`, `s30.next_value` 모두 `page_buffer.c:11929` `pgbuf_is_valid_page` assert로 abort합니다.
* `checkdb`가 남긴 오류 로그는 다음과 같습니다. 레코드 앞 8바이트(표현 정보와 CHN)를 forward OID로 읽어 `512|16777408|0`이 됩니다.

```
Unable to find relocation/home object for relocated_oid=0|3784|3
Unable to find relocated record with oid=512|16777408|0 for home object with oid=0|3782|10
```

**2. 재시작 뒤 상태 (실행, 본문 5번의 실측)**

* 같은 손상을 만든 뒤 세 가지로 재시작했습니다. 셋 모두 결과가 같습니다.
  * SA csql을 NEXT VALUE 커밋 뒤 `kill -9`
  * CACHE 5 serial에서 NEXT VALUE(첫 블록 예약 쓰기) 뒤 프로세스 abort
  * 서버 모드에서 NEXT VALUE 뒤 다음 조회가 `cub_server`를 abort시키고 `cub_master`가 서버를 되살림(`Server revive success`)
* recovery redo가 home 슬롯 종류를 `REC_NEWHOME`로 바꿉니다.

```
0  3782  10  2624  'NEWHOME'  1140  0      <- home 슬롯
0  3784   3   304  'NEWHOME'  1140  0      <- 고아
select name, current_val from db_serial where name='s30'  -> There are no results.
select count(*) from db_serial                           -> 73   (80 - DROP 6 - s30)
select s30.next_value  -> ERROR: Serial 'dba.s30' not defined.
create serial s30      -> ERROR: Operation would have caused one or more unique constraint violations. INDEX pk_db_serial_unique_name ... key: 'dba.s30'
```

* 즉 재시작 뒤에는 abort가 사라지는 대신 **serial이 카탈로그에서 조용히 사라집니다.** heap scan은 `REC_NEWHOME` 슬롯을 건너뛰고(`heap_file.c:7583-7587`), OID로 직접 읽으면 `ER_HEAP_BAD_OBJECT_TYPE`이 됩니다(`heap_file.c:7590-7595`, 소스). PK 인덱스 키는 남아 있어 같은 이름으로 다시 만들 수도 없습니다. 이 serial을 쓰는 애플리케이션과 AUTO_INCREMENT 컬럼은 이 시점부터 실패할 것으로 봅니다(AUTO_INCREMENT는 소스 추정, 실행하지 않음).
* `checkdb`:

```
Unable to find relocation/home object for relocated_oid=0|3782|10
Unable to find relocation/home object for relocated_oid=0|3784|3
```

**3. home 페이지에 자리가 없을 때 (실행 + 에뮬레이션)**

* debug 빌드는 `serial.c:1573` `spage_is_updatable` assert로 abort합니다. 이 assert는 redo 기록보다 앞이므로 다시 열면 DB는 정상입니다(실행, `checkdb` 통과).
* release 동작은 `serial.c:1573`, `page_buffer.c:7387` assert만 gdb로 건너뛰어 흉내 냈습니다. NEXT VALUE는 `ERROR: Cannot update serial object.`로 실패합니다. 이어서 다른 커밋으로 로그가 flush된 뒤 crash하면, 재시작 redo가 `heap_update_physical`에서 실패하고 `logpb_fatal_error (log_exit=true)`(`log_recovery_redo.hpp:667`)에 도달합니다. release에서는 `exit (EXIT_FAILURE)`이므로 재시작할 수 없습니다(소스, `log_page_buffer.c:11454`).
* 재시작 단계는 `heap_file.c:24898` `assert (false)`와 `heap_file.c:18421` `assert_release (false)`에서 `return -1`(ER_FAILED)로 흉내 냈습니다. `jump`로 건너뛰면 debug 빌드에서는 그 뒤 코드가 noreturn 최적화로 사라져 성공 경로로 갑니다. 그래서 이 결과는 쓸 수 없습니다.
* 따라서 relocation된 serial은 자리가 없을 때 CBRD-28271과 같은 "재시작 불가"로 이어집니다. 두 이슈는 같은 쓰기(`serial.c:1569-1578`)의 두 결과입니다.

**4. 그 밖에 확인한 것**

* **자가 회복 (실행)**: relocation 뒤 home 페이지에 자리가 생긴 상태에서 일반 heap update(`ALTER SERIAL s30 CACHE 5`)를 하면 행이 home으로 돌아옵니다. `heap_update_relocation`(`heap_file.c:24320`)이 처리하며, `NEWHOME`는 `DELETED_WILL_REUSE`가 되고 이후 NEXT VALUE는 정상입니다. 위험 구간은 "relocation 뒤, 다음 일반 update 전의 NEXT VALUE"입니다.
* **`REC_BIGONE` (실행)**: serial 이름 상한 222바이트(`DB_MAX_SERIAL_NAME_LENGTH`)와 comment 상한 1024바이트를 모두 채운 행이 1596바이트입니다. 4K 페이지의 overflow 기준(약 3.9KB)에 못 미치므로 `REC_BIGONE`는 생기지 않습니다.
* **확인하지 않은 것**:
  * release 빌드에서 손상 뒤 읽기의 실제 결과. `volid 512`가 없는 볼륨이라 오류로 끝날 것으로 봅니다(추정).
  * 16K 페이지
  * HA 복제
  * 손상된 DB의 복구 절차

**재현 스크립트 (실행한 절차)**

```bash
#!/bin/bash
# CUBRID 환경($CUBRID, $CUBRID_DATABASES)을 로드한 셸에서 실행한다. develop은 _db_serial, 11.4는 db_serial.
db=reloc28272; dir=$CUBRID_DATABASES/$db
mkdir -p "$dir" && cd "$dir" || exit 1
cubrid createdb --db-page-size=4K --log-page-size=4K --db-volume-size=64M --log-volume-size=64M \
  -F "$dir" $db en_US.utf8 </dev/null >/dev/null || exit 1
rnd() { head -c 20000 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
q() { csql -S -u dba $db -c "$1" </dev/null 2>&1 | grep -Ev '^$'; }
for i in $(seq -w 1 80); do echo "create serial s$i;"; done > mk.sql
csql -S -u dba $db -i mk.sql </dev/null >/dev/null
q "alter serial s30 comment '$(rnd 1000)'"
q "drop serial s21; drop serial s22; drop serial s23; drop serial s24; drop serial s25; drop serial s26;"
# 페이지 번호는 SHOW HEAP HEADER OF _db_serial로 확인한다(이 환경에서는 s30 home 3782, forward 3784).
q "show slotted page slots of volume=0 and page=3782" | grep -v "'HOME'"
q "select s30.next_value"                       # 1, 성공
q "show slotted page slots of volume=0 and page=3782" | grep -v "'HOME'"   # 슬롯 10: RELOCATION 1140
# 재시작 뒤 상태를 보려면: 이 상태에서 csql을 NEXT VALUE 커밋 뒤 kill -9 하거나(SA), 서버 모드에서 실행한 뒤 다시 연다.
q "select name, current_val from _db_serial where name='s30'"
cubrid checkdb -S $db; echo "checkdb exit=$?"
```

**수정 방향 제안 (CBRD-28271과 함께)**

* `serial_update_serial_object`는 redo를 남기기 **전에** 두 가지를 release에서도 확인해야 합니다. 하나는 읽은 레코드 종류가 `REC_HOME`인지, 다른 하나는 새 이미지가 그 슬롯에 들어가는지입니다.
* 둘 중 하나라도 아니면 같은 sysop 안에서 일반 heap update 경로(`heap_update_logical`과 같은 경로, relocation 처리 포함)로 넘기거나 행의 실제 위치(forward 페이지)를 갱신해야 합니다. home의 forward 슬롯에는 절대 쓰지 않아야 합니다.
* 한 번의 수정으로 CBRD-28271과 이 이슈가 함께 닫힙니다. CBRD-28073(OOS)도 같은 함수를 고치므로, 수정은 `feature/oos-merge`에도 반영해야 합니다.
* 시험 후보:
  * relocation 뒤 home에 자리가 있을 때와 없을 때의 NEXT VALUE(NOCACHE, CACHE)
  * 캐시 write-back 경로(`serial.c:1079`)
  * 각 경우의 `kill -9` 뒤 재시작과 `checkdb`
  * 서버 모드 반복

**수정 시 주의 (fallback을 일반 heap update로 할 때)**

* **병합 훅이 새 값을 버립니다 (소스).** 일반 heap update인 `heap_update_logical`은 `_db_serial` 행이면 `serial_row_write_begin`을 활성화합니다(`heap_file.c:25615`, applier는 제외, `serial.c:2180`). 행이 `REC_HOME`이면 `serial_row_write_keep_value`를 부릅니다(`heap_file.c:25665-25679`). 이 함수는 `thread_p->serial_restart`가 아니면 새 레코드의 `current_val`/`started`를 page에 있는 이전 값으로 바꿔 씁니다(`serial.c:2234-2275`). 원래 DDL이 이미 발급된 값을 되돌리지 않게 하려는 훅입니다.
  * 그래서 NEXT VALUE가 이 경로로 fallback하면 값이 디스크에 반영되지 않습니다. 예를 들어 REC_HOME 행이 255에서 256으로 커지지 못하는 경우, 호출자는 256을 돌려주지만 행은 255로 남습니다. 다음 호출이 256을 다시 내주므로 같은 값이 중복 발급됩니다(추정, 실행하지 않음).
  * fallback 경로는 이 훅을 반드시 우회해야 합니다. 예를 들어 serial 값 쓰기임을 알리는 플래그로 `serial_row_write_begin`을 비활성화할 수 있습니다.
* **undo 가능한 fallback에서는 CACHE 블록을 serial cache에 설치하면 안 됩니다 (소스, 시나리오는 추정).** `serial_update_serial_object`는 `lock_mode == X_LOCK`이면 sysop을 열지 않고 부모 트랜잭션 안에서 씁니다(`serial.c:1549-1552`). SA 모드에서는 `lock_get_object_lock`이 늘 `X_LOCK`을 돌려줍니다(`lock_manager.c:8117-8118`). 서버 모드에서는 같은 트랜잭션이 그 serial에 DDL을 한 경우가 X_LOCK입니다. 오늘은 쓰기가 redo-only라 rollback이 값을 되돌리지 않지만, fallback이 undo 가능한 heap update면 되돌립니다. 그러면 다음 순서가 생길 수 있습니다.
  1. SA `--no-auto-commit`에서 CACHE 10 serial의 첫 NEXT VALUE가 fallback으로 블록 끝 10을 씁니다.
  2. 블록 1..10은 cache entry로 설치됩니다(`serial.c:1467-1491`).
  3. `ROLLBACK`으로 행은 이전 값으로 돌아가지만, entry는 메모리에 남습니다.
  4. 이후 entry에서 값을 받아 COMMIT합니다.
  5. 종료 시 write-back은 행 값이 entry의 블록 끝과 다르므로 `row_moved`로 건너뜁니다(`serial.c:1053-1070`, `:1195`).
  6. 다음 세션이 같은 값을 다시 발급합니다. 즉 commit된 값이 중복됩니다.
  * 이 구멍은 fallback을 도입하면서 새로 생깁니다. undo 가능한 fallback으로 예약한 블록은 cache entry에 설치하지 말고 그 호출을 NOCACHE처럼 처리하거나, X_LOCK에서는 fallback을 오류로 거부하는 등의 처리가 필요합니다. 서버 모드의 X_LOCK이 아닌 경우는 sysop을 commit하므로 부모 rollback의 영향을 받지 않습니다.
* **relocation 행은 훅을 거치지 않습니다 (소스).** 훅은 `REC_HOME`에서만 실행됩니다(`heap_file.c:25665`). 따라서 위 첫 항목은 relocation 행의 fallback에는 해당하지 않습니다. 대신 relocation된 serial 행에 대한 DDL(ALTER SERIAL 등)은 NEXT VALUE가 그 사이에 올린 값을 지키지 못할 수 있습니다. 이 부분은 실행하지 않았으며, 수정 범위를 정할 때 함께 볼 항목입니다.
