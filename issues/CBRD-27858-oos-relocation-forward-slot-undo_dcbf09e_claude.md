# [OOS] relocation 행의 vacuum 취소가 다른 트랜잭션이 재사용한 슬롯을 덮어써 DB가 손상된다

## Issue Triage

**이슈 수행 목적**: vacuum이 다른 페이지로 옮겨진(relocation) 행과 그 OOS 값을 지우다가 실패하거나 서버가 중단되어도, 그 사이 다른 트랜잭션이 commit한 행이 보존되고 DB를 다시 열 수 있게 한다.

**이슈 수행 이유**: vacuum은 relocation 행의 forward 슬롯을 비운 직후 그 페이지의 래치를 놓고, 같은 내부 작업(sysop) 안에서 OOS 값을 지운다. 그 사이 다른 트랜잭션이 같은 슬롯에 행을 넣고 commit할 수 있다. 이후 OOS 삭제가 실패하거나 commit 전에 서버가 중단되면, 취소 처리가 옛 레코드를 이미 사용 중인 슬롯에 다시 넣는다. PR 7990의 hornetmj 리뷰에서 보고됐으며, 재현 전용 계측으로 이 구간을 넓혀 debug와 release에서 독립 재현했다.

**영향**: debug에서는 서버가 assertion으로 종료되고, 재시작 복구도 같은 assertion에서 실패해 DB를 열 수 없었다. release에서는 페이지의 레코드 수가 어긋나 서버가 FATAL로 종료되고, 재시작한 서버도 같은 FATAL로 종료됐다. 계측 없이 실제로 얼마나 자주 생기는지는 측정하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 소스와 직접 실행한 결과를 바탕으로 작성했다. 리뷰어의 관찰, 재현 전용 계측을 사용한 결과, 소스에서 추론한 내용을 구분한다.

## Description

### 무엇이 문제인가

행이 커져 원래 페이지에 들어가지 않으면 CUBRID는 행을 다른 페이지로 옮긴다. 원래 자리(home)에는 새 위치를 가리키는 `REC_RELOCATION` 레코드가 남고, 옮겨간 자리(forward)에는 실제 데이터인 `REC_NEWHOME` 레코드가 있다. 이 행을 DELETE하면 vacuum이 나중에 두 슬롯을 함께 지운다. 행에 OOS 값(행 밖에 저장한 큰 컬럼 값)이 있으면 그 OOS 값도 함께 지운다.

vacuum은 이 삭제들을 하나의 내부 작업(sysop)으로 묶는다. sysop이 끝나기 전에는 작업을 취소(abort)할 수 있고, 서버가 중단되면 재시작 복구가 끝나지 않은 sysop을 되돌린다. 어느 쪽이든 undo는 지운 `REC_NEWHOME`을 **원래 슬롯 번호에 다시 넣는다**. 따라서 sysop이 끝날 때까지 그 슬롯을 다른 트랜잭션이 쓰면 안 된다.

분석 기준은 PR 7990의 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`이다. [`REC_RELOCATION` 처리](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/query/vacuum.c#L2532-L2577)는 다음 순서로 실행된다.

1. forward 슬롯을 재사용 가능한 빈 슬롯으로 만들고, 그 페이지의 빈 공간을 INSERT 후보로 등록한다.
2. forward 페이지의 변경을 로그에 남기고 래치를 놓는다.
3. 같은 sysop 안에서 OOS 값을 지운다. 성공하면 sysop을 commit하고, 실패하면 abort한다.

2와 3 사이에 다른 트랜잭션이 그 페이지에 행을 넣으면 같은 슬롯 번호를 받을 수 있고, 그 행을 commit할 수 있다. 이후 3이 abort하면 undo가 [`vacuum_rv_undo_vacuum_heap_record`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/query/vacuum.c#L7771-L7776)를 거쳐 `spage_insert_for_recovery`로 옛 레코드를 같은 슬롯에 넣는다. 이 함수는 [슬롯이 비어 있다고 가정](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/slotted_page.c#L1964-L1970)한다. debug 빌드는 이 assertion으로 종료한다. release 빌드는 슬롯을 다시 할당해 옛 레코드를 쓰므로, commit된 행의 레코드가 슬롯에서 떨어지고 페이지의 레코드 수가 어긋난다. commit 전에 서버가 중단되어도 재시작 복구가 같은 undo를 실행하므로 같은 손상이 생긴다.

develop `4f1a68c1ebec12f29bc8ba98b5ce8cacb1fc8735`의 같은 경로도 [래치를 놓은 뒤 sysop을 commit](https://github.com/CUBRID/cubrid/blob/4f1a68c1ebec12f29bc8ba98b5ce8cacb1fc8735/src/query/vacuum.c#L2428-L2442)하지만, 그 사이에 실패할 수 있는 처리가 없다. PR 7990이 그 사이에 OOS 삭제를 넣으면서 abort 경로가 생겼고, 서버 중단이 걸릴 수 있는 구간도 OOS 페이지 고정과 I/O만큼 길어졌다. develop의 짧은 구간에서 서버가 중단되는 경우는 소스상 같은 조건이지만 실행으로 확인하지 않았다. OOS가 없는 출시 버전이 실제로 영향을 받는다고 주장하지 않는다.

같은 vacuum의 다른 경로는 이 문제가 없다. `REC_HOME`의 OOS 경로는 home 페이지를 sysop이 끝난 뒤까지 고정하고, `REC_BIGONE`도 vacuum한 home 페이지를 고정한 채 실패를 처리한다.

### 왜 문제인가

사용자는 commit한 행이 다른 작업의 실패나 서버 재시작 때문에 사라지거나 손상되지 않기를 기대한다. 운영자는 서버가 중단되더라도 재시작 복구로 DB를 다시 열 수 있다고 기대한다. 이 결함에서는 사용자가 지운 행을 vacuum이 정리하는 과정이, 그와 무관한 다른 사용자가 commit한 행을 덮어쓴다. 피해를 입는 트랜잭션은 vacuum 작업과 아무 관계가 없으며 사용자가 이를 피할 방법도 없다.

재현 결과는 데이터 손상에서 끝나지 않았다. debug에서는 재시작 복구가 매번 같은 assertion에서 실패해 DB를 열 수 없었다. release에서는 서버가 손상된 페이지를 정리하려다 FATAL로 종료했고, 재시작한 서버도 복구 뒤 같은 FATAL로 종료했다. 즉 한 테이블의 한 페이지에서 생긴 충돌이 DB 전체의 가용성 문제로 번졌다. 리뷰어는 release에서 서버가 유지된 채 commit된 행 1건이 사라지고 `checkdb`가 레코드 수 불일치를 보고하는 결과를 관찰했다. 이번 실행에서도 같은 레코드 수 불일치가 생겼고, 그 직후 페이지 정리가 일어나 FATAL로 이어졌다.

발생하려면 다음 조건이 겹쳐야 한다. 지운 행이 relocation 상태이고 OOS 값을 가져야 한다. vacuum이 forward 페이지를 놓은 뒤 OOS 삭제를 끝내기 전에, 다른 트랜잭션이 그 페이지에 행을 넣어 같은 슬롯을 받고 commit해야 한다. 그리고 그 OOS 삭제가 실패하거나 서버가 중단되어야 한다. 이번 재현은 계측으로 이 구간을 최대 120초까지 늘렸으며, 계측 없는 실제 빈도는 측정하지 않았다. OOS 삭제가 실제로 실패할 수 있는 조건(메모리 부족, 페이지 고정 오류 등)의 범위도 ANALYSIS에서 확인할 사항이다.

### 왜 해결해야 하는가

이 결함은 OOS 도입 PR이 만든 경로이며, commit된 데이터의 손상과 DB를 열 수 없는 상태로 이어진다. 발생 빈도가 낮더라도 결과가 복구 불가능한 손상이므로, OOS를 develop에 반영하기 전에 막아야 한다. 사용자나 운영자가 쓸 수 있는 우회책이 없다. vacuum의 실행 시점과 다른 트랜잭션의 INSERT 위치를 사용자가 제어할 수 없고, 서버 중단 시점도 제어할 수 없다.

2026-10-30 JIRA에서 `REC_NEWHOME`, `REC_RELOCATION`, `spage_insert_for_recovery`, `vacuum_heap_oos_delete`, `spage_compact`, sysop과 vacuum의 조합으로 검색한 결과, 이 heap forward 슬롯 결함의 별도 티켓은 찾지 못했다. [CBRD-27781](https://jira.cubrid.org/browse/CBRD-27781)은 취소 처리가 이미 재사용된 슬롯에 복원하려는 같은 부류의 결함이지만, 대상이 OOS 파일의 chunk 슬롯이다. 이 이슈는 heap 파일의 forward 슬롯을 다룬다. 한쪽의 수정이 다른 쪽을 해결하지 않으므로 따로 배정·검증한다. [CBRD-27237](https://jira.cubrid.org/browse/CBRD-27237)은 rollback된 UPDATE의 옛 OOS 체인을 vacuum이 지우는 다른 결함이다.

## Test Build

- CUBRID 소스는 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`에 아래의 재현 전용 계측을 더한 것이다. 계측은 이 구간을 넓히고 OOS 삭제 실패를 흉내 낼 뿐, 반영 대상이 아니다.
- CUBRID `11.5.0.2781`, 64-bit debug와 release(RelWithDebInfo), GCC 11.5.0, Linux `5.14.0-570.30.1.el9_6.x86_64`에서 실행했다.
- 기본 16KB 페이지, 64MB 데이터 볼륨, 32MB 로그 볼륨, `en_US.utf8`로 만든 별도 DB를 CS 서버로 실행하고 passwordless DBA로 접속했다. `cubrid.conf`는 `data_buffer_size=64M`, `log_buffer_size=16M`, `ha_mode=off`이고 나머지 파라미터는 기본값이다.
- 테이블은 기본값인 REUSE_OID 테이블이다. DONT_REUSE_OID 테이블, 여러 chunk로 나뉜 OOS 값의 삭제 도중 실패, HA 복제는 실행하지 않았다.

## Repro

이 재현은 서버 코드에 계측을 넣어야 한다. 실패를 주입한 수정 전 debug DB는 다시 열 수 없으므로, 실행마다 업무 DB와 다른 새 테스트 DB를 사용한다. 기존 DB를 삭제하거나 대체하지 않는다.

1. 분석 기준 소스를 독립 checkout에서 받아 아래 계측 diff를 `r5-repro-hook.patch`로 저장하고 적용한다. 빌드 의존성은 프로젝트의 `docs/install_build_requirements.md`를 따른다. `CUBRID`는 별도 설치 경로로, `CUBRID_DATABASES`는 별도 registry 경로로 설정한다. `$CUBRID/bin`을 PATH에, `$CUBRID/lib`를 라이브러리 경로에 추가하고, 다른 인스턴스와 겹치지 않는 `cubrid_port_id`를 사용한다.

```sh
git checkout --detach dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67
git apply r5-repro-hook.patch
cmake --preset debug
cmake --build build_preset_debug
cmake --install build_preset_debug
```

release로 확인하려면 `debug` 대신 `release` preset과 `build_preset_release`를 사용한다.

2. 새 테스트 DB를 만들고, 계측이 사용할 디렉터리를 서버 환경에 넣어 CS 서버를 시작한다. 아래 DB 이름이 이미 있으면 새 이름을 선택한다.

```sh
cubrid createdb --db-volume-size=64M --log-volume-size=32M r5db en_US.utf8
mkdir r5-fi
CUBRID_R5_REPRO_DIR="$PWD/r5-fi" cubrid server start r5db </dev/null >server-start.out 2>&1
```

3. 아래 드라이버를 `r5_repro.py`로 저장하고 새 출력 디렉터리를 지정해 실행한다. `--mode abort`는 OOS 삭제 실패를 주입하고, `--mode crash`는 같은 시점에 서버를 `kill -9`한다. 드라이버는 테이블과 모든 입력·출력을 보존하며, DB를 만들거나 지우지 않는다. 종료 코드 0은 commit된 행이 모두 보존됐다는 뜻이고, 1은 행 유실이나 서버 실패, 2는 재현 조건에 도달하지 못했다는 뜻이다.

```sh
python3 r5_repro.py r5db ./r5-fi ./r5-out-abort --mode abort
```

4. 서버 오류 로그(`$CUBRID/log/server/`)와 서버 표준 오류, 출력 디렉터리의 `summary.json`을 확인한다. `summary.json`의 `before_go.landed`가 commit된 행이 forward 슬롯에 들어갔는지를 보여 준다. crash 모드는 새 DB에서 `--mode crash`로 다시 실행한다.

드라이버는 다음 순서로 실행한다.

1. `id INT PRIMARY KEY, pad VARCHAR(16000), big VARCHAR(8000) STORAGE FORCE_OUTLINE` 테이블에 피해 행 하나와 다른 행 40개를 넣는다. 피해 행의 `pad`를 100자에서 3,400자로 늘려 relocation을 만들고, `SHOW HEAP CAPACITY`의 `Num_relocated_recs`가 1 이상인지 확인한다. 반복 문자열은 압축돼 relocation이 생기지 않으므로 난수 hex 값을 쓴다. 레코드가 `DB_PAGESIZE/4`를 넘으면 큰 열이 OOS로 옮겨지므로 커진 피해 행을 4KB 미만으로 둔다.
2. 계측을 켜고 피해 행을 DELETE한 뒤, 다른 테이블에 로그를 써서 vacuum이 계측 지점에 도달하게 한다.
3. 계측이 기록한 forward 슬롯을 `SET TRANSACTION LOCK TIMEOUT 0`과 `SHOW SLOTTED PAGE SLOTS`로 관찰하면서, 행마다 commit하는 INSERT를 그 슬롯이 `HOME`이 될 때까지 반복한다. REUSE_OID 테이블은 OID를 조회할 수 없으므로 슬롯을 직접 본다.
4. 실패를 주입하거나 서버를 중단한 뒤, 인덱스 경로(`id >= 1000`)와 heap 경로(`id + 0 >= 1000`)의 결과를 commit된 id와 비교한다. 행이 맞으면 vacuum 재시도로 피해 행의 OOS 레코드 수가 0이 되는지 확인한다.

### 재현 전용 계측

서버 환경에 `CUBRID_R5_REPRO_DIR`이 있고 그 아래 `arm` 파일이 있을 때만 한 번 동작한다. forward 페이지의 래치를 놓은 뒤 OOS 삭제를 호출하는 자리에서 forward OID를 파일에 쓰고, `go` 파일을 최대 120초 기다린다. 그 뒤 OOS 삭제가 메모리 부족으로 실패한 것처럼 `ER_OUT_OF_VIRTUAL_MEMORY`를 반환한다. 호출자는 이 오류에서 [로그 블록을 미완료로 남기고 다시 시도](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/query/vacuum.c#L1820-L1833)한다. 이 계측은 OOS chunk를 지우기 전에 실패하므로 CBRD-27781의 경로를 실행하지 않는다.

```diff
diff --git a/src/query/vacuum.c b/src/query/vacuum.c
index aebb42f68..ed4df6b03 100644
--- a/src/query/vacuum.c
+++ b/src/query/vacuum.c
@@ -2451,6 +2451,49 @@ vacuum_heap_record_insid_and_prev_version (THREAD_ENTRY * thread_p, VACUUM_HEAP_
   return NO_ERROR;
 }
 
+/*
+ * vacuum_r5_repro_inject () - REPRODUCTION ONLY. Never part of a fix.
+ *
+ *   When CUBRID_R5_REPRO_DIR is set and <dir>/arm exists, consume the arm file once, publish the
+ *   forward OID to <dir>/forward_oid, wait until <dir>/go appears (bounded), and fail as if the OOS
+ *   delete helper had run out of memory before deleting any chunk.
+ */
+static int
+vacuum_r5_repro_inject (THREAD_ENTRY * thread_p, const OID * forward_oid)
+{
+  const char *dir = getenv ("CUBRID_R5_REPRO_DIR");
+  char arm_path[PATH_MAX], consumed_path[PATH_MAX], oid_path[PATH_MAX], tmp_path[PATH_MAX], go_path[PATH_MAX];
+  FILE *fp;
+  int waited_ms;
+
+  if (dir == NULL)
+    {
+      return NO_ERROR;
+    }
+  snprintf (arm_path, sizeof (arm_path), "%s/arm", dir);
+  snprintf (consumed_path, sizeof (consumed_path), "%s/arm.consumed", dir);
+  snprintf (oid_path, sizeof (oid_path), "%s/forward_oid", dir);
+  snprintf (tmp_path, sizeof (tmp_path), "%s/forward_oid.tmp", dir);
+  snprintf (go_path, sizeof (go_path), "%s/go", dir);
+  if (rename (arm_path, consumed_path) != 0)
+    {
+      return NO_ERROR;
+    }
+  fp = fopen (tmp_path, "w");
+  if (fp != NULL)
+    {
+      fprintf (fp, "%d|%d|%d\n", forward_oid->volid, forward_oid->pageid, forward_oid->slotid);
+      fclose (fp);
+      rename (tmp_path, oid_path);
+    }
+  for (waited_ms = 0; waited_ms < 120000 && access (go_path, F_OK) != 0; waited_ms += 100)
+    {
+      thread_sleep (100);
+    }
+  er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_OUT_OF_VIRTUAL_MEMORY, 1, (size_t) 1);
+  return ER_OUT_OF_VIRTUAL_MEMORY;
+}
+
 /*
  * vacuum_heap_record () - Vacuum heap record.
  *
@@ -2560,8 +2603,12 @@ vacuum_heap_record (THREAD_ENTRY * thread_p, VACUUM_HEAP_HELPER * helper,
       /* Delete OOS records (if any) before committing the sysop. */
       if (has_oos)
 	{
-	  int oos_err = vacuum_heap_oos_delete_within_sysop (thread_p, &helper->oos_vfid, &helper->record,
+	  int oos_err = vacuum_r5_repro_inject (thread_p, &helper->forward_oid);
+	  if (oos_err == NO_ERROR)
+	    {
+	      oos_err = vacuum_heap_oos_delete_within_sysop (thread_p, &helper->oos_vfid, &helper->record,
 							     oos_emptied_pages_out);
+	    }
 	  if (oos_err != NO_ERROR)
 	    {
 	      log_sysop_abort (thread_p);
```

### 재현 드라이버

아래 드라이버는 실제 수정 전후 검증에 사용한 내용이다. `csql`이 PATH에 있어야 하고, crash 모드는 `$CUBRID` 아래에서 실행된 해당 DB의 `cub_server`를 찾아 중단한다.

```python
#!/usr/bin/env python3
"""R5 reproduction driver: relocation-vacuum abort vs. a committed row in the reused forward slot.

Usage (prepared CS environment, server started with CUBRID_R5_REPRO_DIR=<fi_dir>):
    python3 -I r5_repro.py DB FI_DIR OUT_DIR [--max-inserts N]

Requires the repro-only hook vacuum_r5_repro_inject in the server. The driver
  1. builds a table whose victim row is REC_RELOCATION and carries an OOS value,
  2. arms the hook, deletes the victim, and writes unrelated log until vacuum reaches the hook,
  3. while vacuum is paused (forward page released in the unfixed code), inserts committed rows
     until one occupies the exact forward slot, observed with SHOW SLOTTED PAGE SLOTS,
  4. releases the hook (which fails the OOS delete), then checks the committed rows.
Exit 0 = every committed row survives; 1 = committed row lost or server failure; 2 = setup did not
reach the scenario (no conclusion). summary.json "landed" tells whether a committed row occupied the
forward slot while vacuum was paused; a red baseline needs landed=true.
--mode crash kills the server at the same point instead of failing the OOS delete.
"""
import argparse
import json
import os
import random
import re
import subprocess
import time
import uuid
from pathlib import Path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('database')
    ap.add_argument('fi_dir', type=Path)
    ap.add_argument('out_dir', type=Path)
    ap.add_argument('--max-inserts', type=int, default=60)
    ap.add_argument('--hook-timeout', type=int, default=90)
    ap.add_argument('--mode', choices=('abort', 'crash'), default='abort',
                    help='abort: release the hook so the OOS delete fails; crash: kill -9 the server instead')
    args = ap.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=False)
    table = 'r5t_' + uuid.uuid4().hex[:8]
    summary = {'table': table, 'database': args.database, 'steps': [], 'status': 'running'}
    seq = [0]
    rng = random.Random(7990)

    def rnd(n):
        # Incompressible literal: repeated text is compressed and would never force a relocation.
        return "'" + ''.join(rng.choice('0123456789abcdef') for _ in range(n)) + "'"

    def csql(sql, name, timeout=60, check=True):
        seq[0] += 1
        base = args.out_dir / f'{seq[0]:03d}_{name}'
        base.with_suffix('.sql').write_text(sql)
        cmd = ['csql', '-C', '-u', 'dba', '--no-pager', '--line-output', args.database]
        with base.with_suffix('.sql').open('rb') as src, base.with_suffix('.out').open('wb') as out:
            proc = subprocess.run(cmd, stdin=src, stdout=out, stderr=subprocess.STDOUT, timeout=timeout)
        text = base.with_suffix('.out').read_text(errors='replace')
        if check and (proc.returncode != 0 or re.search(r'\bERROR\b', text)):
            raise RuntimeError(f'{name} failed (exit {proc.returncode}); see {base}.out')
        return proc.returncode, text

    def slot_of(vol, page, slot):
        _, text = csql(f'SET TRANSACTION LOCK TIMEOUT 0;\n'
                       f'SHOW SLOTTED PAGE SLOTS OF VOLUME={vol} AND PAGE={page};\n', 'slots', check=False)
        rows = re.split(r'^<\d+>', text, flags=re.M)[1:]
        for row in rows:
            fields = dict(re.findall(r'^\s*(\w+)\s*:\s*(.*?)\s*$', row, re.M))
            if fields.get('Slot_id') == str(slot):
                return {'type': fields.get('Type', '').strip("'"), 'length': int(fields.get('Length', -1))}
        if 'ERROR' in text:
            return {'type': 'ERROR', 'detail': text.strip().splitlines()[-1][:300]}
        return {'type': 'ABSENT'}

    def server_pid():
        cub = os.environ['CUBRID']
        for pid in subprocess.run(['pgrep', '-x', 'cub_server'], capture_output=True, text=True).stdout.split():
            try:
                exe = os.readlink(f'/proc/{pid}/exe')
                cmd = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
            except OSError:
                continue
            if exe.startswith(cub + '/') and args.database.encode() in cmd:
                return int(pid)
        return None

    def wait_server(seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            rc, text = csql('SELECT 1;\n', 'ping', timeout=30, check=False)
            if rc == 0 and 'ERROR' not in text:
                return True
            time.sleep(2)
        return False

    def step(name, **kw):
        summary['steps'].append({'step': name, 'time': time.time(), **kw})
        (args.out_dir / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')

    exit_code = 2
    try:
        for f in ('arm', 'arm.consumed', 'forward_oid', 'forward_oid.tmp', 'go'):
            (args.fi_dir / f).unlink(missing_ok=True)
        csql(f'CREATE TABLE {table} (id INT PRIMARY KEY, pad VARCHAR(16000), '
             f'big VARCHAR(8000) STORAGE FORCE_OUTLINE);\n'
             f'CREATE TABLE {table}_log (id INT, v VARCHAR(4000));\n', 'create')
        # Victim first, then fillers so the victim's home page has no room left to grow in place. Records above
        # DB_PAGESIZE/4 move columns to OOS, so the grown victim stays below 4 KB to remain inline and relocate.
        sql = f"INSERT INTO {table} VALUES (1, {rnd(100)}, {rnd(6000)});\n"
        sql += ''.join(f"INSERT INTO {table} VALUES ({10 + i}, {rnd(1500)}, NULL);\n" for i in range(40))
        csql(sql, 'fill')
        csql(f"UPDATE {table} SET pad = {rnd(3400)} WHERE id = 1;\n", 'relocate')
        _, text = csql(f'SHOW HEAP CAPACITY OF {table};\n', 'capacity')
        relocated = re.search(r'Num_relocated_recs\s*:\s*(\d+)', text)
        step('relocated_check', num_relocated_recs=int(relocated.group(1)) if relocated else None)
        if not relocated or int(relocated.group(1)) < 1:
            raise SystemExit(2)
        step('setup_done')
        (args.fi_dir / 'arm').write_text('1\n')
        csql(f'DELETE FROM {table} WHERE id = 1;\n', 'delete_victim')
        step('armed_and_deleted')
        deadline = time.monotonic() + args.hook_timeout
        n_log = 0
        while not (args.fi_dir / 'forward_oid').exists():
            if time.monotonic() > deadline:
                step('hook_not_reached', log_rows=n_log)
                raise SystemExit(2)
            csql(''.join(f"INSERT INTO {table}_log VALUES ({n_log + i}, {rnd(3900)});\n" for i in range(50)),
                 'log_fill')
            n_log += 50
        vol, page, slot = map(int, (args.fi_dir / 'forward_oid').read_text().strip().split('|'))
        step('hook_reached', forward_oid=[vol, page, slot], log_rows=n_log,
             forward_slot=slot_of(vol, page, slot))
        landed = None
        for i in range(args.max_inserts):
            row_id = 1000 + i
            pad_len = 3300 - 10 * i
            started = time.monotonic()
            try:
                # In crash mode the server must die while vacuum is still paused (the hook waits 120 s),
                # so an INSERT blocked behind the held forward page is abandoned after 30 s.
                csql(f"INSERT INTO {table} VALUES ({row_id}, {rnd(pad_len)}, NULL);\n", f'insert_{row_id}',
                     timeout=30 if args.mode == 'crash' else 180)
            except subprocess.TimeoutExpired:
                step('insert_blocked', id=row_id, secs=round(time.monotonic() - started, 3))
                break
            insert_secs = round(time.monotonic() - started, 3)
            state = slot_of(vol, page, slot)
            step('inserted', id=row_id, pad_len=pad_len, insert_secs=insert_secs, forward_slot=state)
            if state.get('type') in ('HOME', 'NEWHOME', 'RELOCATION', 'BIGONE', 'ASSIGN_ADDRESS'):
                landed = {'id': row_id, 'pad_len': pad_len, 'slot': state}
                break
        _, text = csql(f'SELECT id, LENGTH(pad) AS len FROM {table} WHERE id >= 1000 ORDER BY id;\n', 'before_go')
        committed_ids = sorted(int(x) for x in re.findall(r'^\s*(?:<\d+>\s*)?id\s*:\s*(\d+)', text, re.M))
        step('before_go', landed=landed, committed_ids=committed_ids)
        if args.mode == 'abort':
            (args.fi_dir / 'go').write_text('1\n')
            time.sleep(5)
        else:
            server = server_pid()
            subprocess.run(['kill', '-9', str(server)], check=True)
            step('killed_server', pid=server)
        up = wait_server(90)
        step('server_reachable', up=up, pid=server_pid())
        rc, text = csql(f'SELECT id, LENGTH(pad) AS len FROM {table} WHERE id >= 1000 ORDER BY id;\n'
                        f'SELECT id, LENGTH(pad) AS len FROM {table} WHERE id + 0 >= 1000 ORDER BY id;\n',
                        'after_rows', check=False)
        index_ids, heap_ids = [], []
        for idx, block in enumerate(text.split('=== <Result of SELECT Command')[1:]):
            ids = [int(x) for x in re.findall(r'^\s*(?:<\d+>\s*)?id\s*:\s*(\d+)', block, re.M)]
            (index_ids if idx == 0 else heap_ids).append(ids)
        result = {'csql_rc': rc, 'index_ids': index_ids[0] if index_ids else None,
                  'heap_ids': heap_ids[0] if heap_ids else None, 'expected_ids': committed_ids,
                  'forward_slot': slot_of(vol, page, slot) if rc == 0 else None}
        step('verify', **result)
        rows_ok = rc == 0 and result['index_ids'] == committed_ids and result['heap_ids'] == committed_ids
        if rows_ok:
            # The aborted or undone vacuum must be retried: the victim's OOS chain has to disappear.
            deadline = time.monotonic() + args.hook_timeout
            while True:
                _, text = csql(f'SHOW HEAP OOS OF {table};\n', 'oos_count')
                oos = int(re.search(r'Oos_num_recs\s*:\s*(\d+)', text).group(1))
                if oos == 0 or time.monotonic() > deadline:
                    break
                csql(''.join(f"INSERT INTO {table}_log VALUES ({n_log + i}, {rnd(3900)});\n" for i in range(50)),
                     'log_fill_retry')
                n_log += 50
            step('vacuum_retry', oos_num_recs=oos, log_rows=n_log)
        summary['landed'] = landed is not None
        if not rows_ok:
            exit_code = 1
            summary['status'] = 'committed_row_lost_or_server_failed'
        else:
            exit_code = 0
            summary['status'] = 'committed_rows_intact'
    except SystemExit as e:
        exit_code = e.code
        summary['status'] = summary.get('status') if summary['status'] != 'running' else 'inconclusive'
    except Exception as e:
        summary['status'] = 'error'
        summary['error'] = str(e)
        exit_code = 1
    finally:
        (args.out_dir / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({'status': summary['status'], 'out': str(args.out_dir), 'error': summary.get('error')}))
    return exit_code


if __name__ == '__main__':
    raise SystemExit(main())
```

## Expected Result

vacuum의 OOS 삭제가 실패하거나 서버가 중단되어도, 그 사이 다른 트랜잭션이 commit한 행이 인덱스와 heap 양쪽에서 조회된다. assertion이나 FATAL 없이 서버가 계속 실행되거나 재시작 복구를 마친다. vacuum 재시도가 지운 행의 OOS 값을 정리하고, `checkdb`가 통과한다.

## Actual Result

수정 전 소스에 계측을 적용해 실행했다. 세 실행 모두 피해 행의 forward 슬롯이 `DELETED_WILL_REUSE`인 동안 commit된 INSERT id 1000이 같은 슬롯에 `HOME` 3,344바이트로 들어갔다.

debug, abort 모드: forward 슬롯은 `1|1603|6`이었다. 실패를 주입하자 서버가 다음 assertion으로 종료했다. master의 자동 재시작과 SA 모드 `checkdb`의 복구도 UNDO에서 같은 assertion으로 실패해, DB를 다시 열 수 없었다.

```text
cub_server: .../src/storage/slotted_page.c:1969: int spage_insert_for_recovery(THREAD_ENTRY*, PAGE_PTR, PGSLOTID, RECDES*): Assertion `slot_p->offset_to_record == SPAGE_EMPTY_OFFSET' failed.
```

release, abort 모드: forward 슬롯은 `1|707|6`이었다. abort 중 page 707의 손상이 기록됐고, 이어서 vacuum의 페이지 정리(`spage_compact`)가 FATAL로 서버를 종료했다. master가 다시 시작한 서버에서는 재시작 복구의 UNDO가 같은 손상을 다시 기록했고, 복구를 마친 서버도 같은 FATAL로 종료했다.

```text
Internal error: The page 707 of volume "..._x001" may be corrupted.
NUM SLOTS = 7, NUM RECS = 8, TYPE OF SLOTS = ANCHORED_DONT_REUSE_SLOTS,
...
Internal error: The page 707 of volume "..._x001" may be corrupted. 6 records was found when 7 was expected.
LOG FATAL ERROR: spage_compact
```

release, crash 모드: OOS 삭제 실패 없이 같은 시점에 서버를 `kill -9`했다. 재시작 복구의 UNDO가 page 707의 같은 손상을 기록했고, 복구를 마친 서버가 같은 `spage_compact` FATAL로 종료했다. 세 실행 모두 드라이버의 종료 코드는 1이었다.

## Additional Information

- 로컬 후보 수정은 forward 페이지를 sysop의 commit이나 abort가 끝날 때까지 고정하는 것이다. 래치를 놓는 `pgbuf_set_dirty`의 `FREE`를 `DONT_FREE`로 바꾸고 commit 뒤에 페이지를 놓는다. 실패 경로는 abort 뒤 반환하며, 호출자가 이미 forward 페이지를 놓는다. 6줄 추가와 2줄 삭제이며, 팀 리뷰 전 후보이다.
- 후보의 래치 순서는 `REC_HOME`의 OOS 경로와 같다. vacuum이 heap 페이지를 쥔 채 OOS 페이지를 고정하며, OOS 삭제는 heap 페이지나 heap 헤더를 고정하지 않는다. 비용은 OOS 삭제 동안 forward 페이지의 래치를 더 오래 쥐는 것이다.
- 후보에 같은 계측을 적용해 debug와 release에서 abort·crash 모드를 각각 실행했다. INSERT가 고정된 forward 페이지를 기다린 뒤 진행해 그 슬롯을 재사용하지 못했다. commit된 행이 인덱스와 heap에서 모두 조회됐고, vacuum 재시도로 피해 행의 OOS 레코드 수가 0이 됐다. assertion, FATAL, 손상 메시지는 없었고, 네 DB 모두 SA 모드 `checkdb`가 통과했다.
- 계측 없는 후보 수정의 debug 빌드에서 구성된 CTest 44개가 모두 통과했다. OOS vacuum과 crash recovery 테스트를 포함한다.
- 계측은 서버 코드에 환경 변수 검사를 넣으므로 반영하지 않으며, 이 재현을 그대로 회귀 테스트로 남길 수 없다.
- 관련 원본은 [PR 7990](https://github.com/CUBRID/cubrid/pull/7990), [리뷰 원문](https://github.com/CUBRID/cubrid/pull/7990#discussion_r4409499688), 상위 작업 [CBRD-26583](https://jira.cubrid.org/browse/CBRD-26583)이다.

## Triage Request

relocation 행의 vacuum 취소로 commit된 행이 손상되는 문제를 확인하고, OOS 담당 작성자 측의 ANALYSIS 배정을 요청한다. 분석에서는 다음을 확인한다.

- 슬롯을 다시 쓸 수 있게 되는 시점을 sysop의 끝으로 미루는 로컬 후보의 래치 범위와 비용이 적절한가.
- 여러 chunk로 나뉜 OOS 값의 삭제 도중 실패, DONT_REUSE_OID 테이블, HA 복제에 추가 검증이 필요한가.
- 엔진 계측 없이 이 경로를 검증할 회귀 테스트가 가능한가.

독립 회사 PR의 리뷰와 CI를 받은 뒤 반영한다.
