본문의 "기본 `unfill_factor`에서 이 상태가 되는 빈도는 확인하지 않았다"와 ANALYSIS 항목 "기본 `unfill_factor`에서 예약 공간이 소진되는 현실적인 작업 패턴"에 대해, develop에서 직접 실행해 확인한 결과를 공유합니다. relocation된 serial 행(CBRD-28272)도 같은 재시작 불가에 이른다는 것도 함께 적습니다. 증거 수준은 항목마다 적었습니다(실행 = 직접 실행, 에뮬레이션 = debug 빌드를 gdb로 조작, 소스 = 코드 판독).

**조건 (실행)**

* develop `de4f32740e`, debug 빌드(gcc), SA 모드, **기본 `unfill_factor`(0.1)**. OOS 코드는 없습니다.
* 결과 판정은 debug 빌드의 `serial.c:1573` `spage_is_updatable` assert(rc=134)로 했습니다. 이 assert가 걸리는 상태가 release 빌드에서는 본문의 `ERROR: Cannot update serial object.`와 재시작 실패로 이어집니다.

**1. 기본 설정에서 도달하는 경로 (실행)**

* **이웃 행의 ALTER가 예약 공간을 쓴 뒤 평범한 값 증가**: 같은 페이지의 다른 serial에 `ALTER SERIAL ... COMMENT`를 하면 `heap_update_home`(`heap_file.c:24731`)은 `spage_is_updatable`만 보고 같은 페이지에서 갱신합니다. 이때 insert용 예약 공간(`unfill`)도 씁니다. 4K 페이지에서 이렇게 여유를 0~8바이트로 만든 뒤, 평범한 serial이 255에서 256으로 넘어가면 실패합니다. 255는 성공하고 256에서 abort합니다. 이때 `current_val` 디스크 크기가 4바이트에서 8바이트로 바뀌므로 증가분은 4바이트입니다.
* **DDL 없이 CREATE SERIAL과 NEXT VALUE만 (작위적)**: insert는 `행 + unfill`이 들어가는 페이지만 고릅니다(`bestspace.hpp:426`). 그래서 채워진 페이지의 여유는 `unfill`(4K 405바이트, 16K 1634바이트) 이상 `unfill + 행 + slot` 미만입니다.
  * 행 하나의 최대 증가는 16바이트(`current_val` 4바이트에서 20바이트)이고, 최소 serial 행은 132바이트입니다. 증가분이 행 크기의 약 11.8%로 예약 비율 10%보다 커서, 원리상 예약만으로는 막을 수 없습니다.
  * 실제로 이름 길이로 행 크기를 섞어 페이지 여유를 맞추고, 같은 페이지의 모든 serial을 2^104 이상으로 키우면 실패합니다.
  * 4K 페이지: serial 26개, 여유 412바이트에 최대 증가 416바이트. 25개 성공, 26번째에서 abort.
  * 기본 16K 페이지: serial 107개, 여유 1708바이트에 최대 증가 1712바이트. 106개 성공, 107번째에서 abort.
  * 모든 행이 약 2×10^31 이상이어야 하므로 실제 작업에서는 거의 일어나지 않을 것으로 봅니다(추정).
* 본문의 "serial 160개를 균일하게 키운 시험에서는 실패하지 않았다"와 맞습니다. 행 크기가 같으면 여유가 남습니다(4K에서 132바이트 행 26개는 증가 416 < 여유 444). 행 크기가 섞여야 넘칩니다.

**2. relocation된 serial도 같은 결과 (실행 + 에뮬레이션, CBRD-28272)**

* `ALTER SERIAL ... COMMENT`로 relocation된 serial(home 슬롯은 8바이트 forward OID)에 NEXT VALUE를 하면, 1140바이트 새 이미지를 home 슬롯에 쓰려 합니다. home 페이지에 자리가 없으면 debug는 같은 `serial.c:1573` assert로 abort합니다(실행).
* release 동작은 `serial.c:1573`, `page_buffer.c:7387` assert만 gdb로 건너뛰어 흉내 냈습니다. NEXT VALUE는 `ERROR: Cannot update serial object.`로 실패합니다. 다른 커밋 뒤 crash하고 다시 열면 recovery redo가 `heap_update_physical`에서 실패해 `logpb_fatal_error (log_exit=true)`(`log_recovery_redo.hpp:667`)에 도달합니다(에뮬레이션). 본문의 release 결과와 같은 지점입니다.
* 따라서 이 이슈의 발생 조건은 "값 증가로 행이 커짐"만이 아닙니다. 다음도 포함됩니다.
  * relocation 상태의 serial 행에 대한 모든 NEXT VALUE와 캐시 write-back. 새 이미지는 항상 8바이트보다 큽니다.
* 재시작 단계 흉내에서는 `heap_file.c:24898` `assert (false)`와 `heap_file.c:18421` `assert_release (false)`를 `return -1`로 대체했습니다. `jump`로 건너뛰면 debug 빌드에서는 그 뒤 코드가 noreturn 최적화로 사라져 성공 경로로 갑니다. 그래서 그 방식의 결과는 쓰지 않았습니다.

**3. 그 밖에 확인한 것**

* 실패한 갱신은 page LSA만 올리고 page를 dirty로 표시하지 않습니다. debug 빌드는 unfix 때 `page_buffer.c:7387` 검사에도 걸립니다(실행). 같은 page가 이미 dirty였던 경우에는 걸리지 않았습니다.
* 이 page가 나중에 다른 변경으로 flush되면 page LSA가 그 redo의 LSA 이상이 되어 재시작이 레코드를 건너뛸 것으로 봅니다(추정). 위험 구간은 "로그 flush 뒤, 그 page flush 전의 crash"입니다. checkpoint와의 상호작용은 확인하지 않았습니다.
* 확인하지 않은 것: 실제 release 빌드에서의 위 경로, 서버 모드의 값 증가 경로, HA.

**재현 스크립트 (CREATE SERIAL과 NEXT VALUE만, 4K, 실행한 절차)**

```bash
#!/bin/bash
# CUBRID 환경($CUBRID, $CUBRID_DATABASES)을 로드한 셸에서 실행한다. 기본 cubrid.conf.
db=grow28271; dir=$CUBRID_DATABASES/$db
mkdir -p "$dir" && cd "$dir" || exit 1
cubrid createdb --db-page-size=4K --log-page-size=4K --db-volume-size=64M --log-volume-size=64M \
  -F "$dir" $db en_US.utf8 </dev/null >/dev/null || exit 1
INC=1000000000000000000000000000000   # 10^30
{ for c in {a..r}; do echo "create serial $c increment by $INC;"; done       # 헤더 페이지를 채운다
  for c in {a..d}; do echo "create serial q${c}z increment by $INC;"; done   # 140바이트 행 4개
  for c in {a..v}; do echo "create serial p${c} increment by $INC;"; done    # 132바이트 행 22개
} > create.sql
csql -S -u dba $db -i create.sql </dev/null >/dev/null
# 다음 페이지(이 환경에서 0|3782): serial 26개, Total_free_area 412. 최대 증가 26 x 16 = 416.
{ for s in qaz qbz qcz qdz $(for c in {a..v}; do echo p$c; done); do
    echo "select '$s', serial_next_value($s, 1), serial_next_value($s, 25) from db_root;"; done; } > nv.sql
csql -S -u dba $db -t -i nv.sql </dev/null
# debug: 25개 성공 뒤 26번째(pv)에서 serial.c:1573 assert.
# release: pv는 'Cannot update serial object.'. 이어서 커밋된 NEXT VALUE 하나 뒤 crash하면 재시작 시 LOG FATAL ERROR.
```

위 스크립트 경로의 release 동작을 흉내 냈을 때(26번째 실패 뒤 커밋, crash, 재시작) 재시작이 남긴 메시지입니다(에뮬레이션).

```
LOG FATAL ERROR: log_rv_redo_record_sync: Error applying redo record at log_lsa=(817, 920), rcv = {mvccid=0, vpid=(0, 3782), offset = 26, data_length = 150}
```

**수정 방향 제안 (CBRD-28272와 함께)**

* redo를 남기기 **전에** release에서도 두 가지를 확인해야 합니다. 하나는 읽은 레코드 종류가 `REC_HOME`인지, 다른 하나는 새 이미지가 그 슬롯에 들어가는지입니다.
* 아니면 로그를 남기지 않고, 같은 sysop 안에서 일반 heap update 경로(relocation 처리 포함)로 넘기거나 행의 실제 위치를 갱신합니다. home의 forward 슬롯에는 쓰지 않습니다.
* 이렇게 하면 NEXT VALUE가 실패하지도 않고(본문 ANALYSIS 첫 항목의 후자), CBRD-28272도 함께 닫힙니다.
* CBRD-28073(OOS)이 같은 `serial_update_serial_object`를 고치므로 이 수정은 `feature/oos-merge`에도 반영해야 합니다.
* 시험 후보:
  * 위 스크립트(4K, 16K)
  * 이웃 ALTER로 여유를 줄인 뒤 255에서 256
  * relocation된 serial의 NEXT VALUE(자리 있음, 자리 없음)
  * NOCACHE, CACHE, 캐시 write-back
  * 각 경우의 `kill -9` 뒤 재시작과 `checkdb`
  * 서버 모드

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
