#!/usr/bin/env bash
set -euo pipefail
expected=${1:?Usage: bash CBRD-27424-repro_e24b458_codex.sh before|after}
case "$expected" in before|after) ;; *) exit 2 ;; esac
repro_dir=$(mktemp -d "${TMPDIR:-/tmp}/cbrd27424-repro.XXXXXX")
export CUBRID_DATABASES="$repro_dir"
export CUBRID_CONF_FILE="$repro_dir/cubrid.conf"
cd "$repro_dir"
printf '[common]\ndata_buffer_size=64M\nlog_buffer_size=16M\n' > cubrid.conf
printf 'Evidence: %s\n' "$repro_dir"
cubrid createdb --db-page-size=16K --db-volume-size=32M --log-volume-size=32M -F "$repro_dir" oos27424 en_US.utf8 > createdb.out 2>&1
python3 - <<'PY'
from pathlib import Path
import random
rng = random.Random(27424)
payload = bytes(rng.randrange(256) for _ in range(5000)).hex()
Path('schema.sql').write_text('CREATE TABLE t_load(v BIT VARYING);\nCREATE TABLE t_ws(v BIT VARYING);\nCREATE TABLE t_normal(v BIT VARYING);\nCOMMIT;\n')
Path('load.objects').write_text("%%class t_load (v)\nX'%s'\n" % payload)
Path('workspace.sql').write_text("SET SYSTEM PARAMETERS 'insert_execution_mode=0';\nINSERT INTO t_ws VALUES (X'%s');\nCOMMIT;\n" % payload)
Path('normal.sql').write_text("INSERT INTO t_normal VALUES (X'%s');\nCOMMIT;\n" % payload)
for table in ('t_load', 't_ws', 't_normal'):
    Path(table + '.sql').write_text("SELECT CASE WHEN COUNT(*)=1 AND SUM(CASE WHEN v=X'%s' THEN 1 ELSE 0 END)=1 THEN 'VALUE_OK' ELSE 'VALUE_BAD' END AS verdict FROM %s;\n;oos_stats %s\n" % (payload, table, table))
PY
csql -S -u dba --no-auto-commit oos27424 < schema.sql > schema.out 2>&1
cubrid loaddb -S -u dba -d load.objects oos27424 > load.out 2>&1
csql -S -u dba --no-auto-commit oos27424 < workspace.sql > workspace.out 2>&1
# 새 CSQL 프로세스에서 기본 INSERT 경로를 실행한다.
csql -S -u dba --no-auto-commit oos27424 < normal.sql > normal.out 2>&1
for table in t_load t_ws t_normal; do
    csql -S -u dba --no-auto-commit oos27424 < "$table.sql" > "$table.out" 2>&1
done
python3 - "$expected" <<'PY'
from pathlib import Path
import re
import sys
expected = [0, 0, 1] if sys.argv[1] == 'before' else [1, 1, 1]
for table, wanted in zip(('t_load', 't_ws', 't_normal'), expected):
    output = Path(table + '.out').read_text()
    assert "'VALUE_OK'" in output and "'VALUE_BAD'" not in output, output
    match = re.search(r'Live OOS records\s*:\s*(\d+)', output)
    actual = int(match[1]) if match else 0 if 'has no OOS file' in output else None
    print('%s: VALUE_OK, OOS=%s (expected %s)' % (table, actual, wanted))
    assert actual == wanted, output
PY
cubrid deletedb oos27424 > deletedb.out 2>&1
