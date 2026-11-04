import argparse
import hashlib
import json
import random
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('directory',type=Path)
args=parser.parse_args()
args.directory.mkdir()
rng=random.Random(27924)
values={name:rng.randbytes(size) for name,size in [('payload',3000),('added',21000)]}
expr={name:"X'"+value.hex()+"'" for name,value in values.items()}
setup=[]
for table in ['probe_sa','probe_cs']:
    setup.append(f"create table {table}(id int,note int,payload bit varying);insert into {table} values(1,101,{expr['payload']});commit;")
    setup.append(f"set system parameters 'add_column_update_hard_default=no';alter table {table} add added bit varying default {expr['added']};commit;")
(args.directory/'setup.sql').write_text('\n'.join(setup)+'\n')
for table in ['probe_sa','probe_cs']:
    model=f"case when id=1 and note=101 and payload={expr['payload']} and added={expr['added']} then 1 else 0 end"
    sql=f"select count(*) as row_count,sum({model}) as exact_rows,sum(octet_length(payload)) as payload_bytes,sum(octet_length(added)) as added_bytes from {table};\n"
    sql+=f"select /*+ SELECT_RECORD_INFO */ id,t_volumeid,t_pageid,t_slotid,t_rectype,t_reprid,t_length,t_flags from {table};\nshow heap oos of {table};\n"
    (args.directory/(table+'.sql')).write_text(sql)
(args.directory/'update.sql').write_text('update probe_sa set payload=payload,added=added;commit;\n')
(args.directory/'values.json').write_text(json.dumps({k:{'bytes':len(v),'sha256':hashlib.sha256(v).hexdigest()} for k,v in values.items()},indent=2)+'\n')
