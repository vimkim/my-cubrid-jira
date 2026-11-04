# [TDE] vacuum이 relocation된 삭제 행을 제거할 때 행 전체를 평문 undo 로그로 남긴다

**한 줄 요약**: OOS 대체 설계를 검토하던 중 develop에서 발견한 결함으로, `ENCRYPT=AES` 테이블에서 relocation된 행을 삭제하면 vacuum이 그 행 전체를 암호화되지 않은 `RVVAC_HEAP_RECORD_VACUUM` undo 로그로 남긴다. 이 로그도 암호화 테이블의 다른 로그처럼 암호화되도록 고친다.

## Issue Triage

**이슈 수행 목적**: vacuum이 TDE 테이블의 삭제 행을 제거할 때 남기는 로그에도 TDE 암호화를 적용하여, 활성 로그와 보관 로그에 해당 행의 평문이 남지 않게 한다.

**이슈 수행 이유**: 로그 레코드는 recovery index가 `LOG_MAY_CONTAIN_USER_DATA` 목록에 있을 때만 TDE 암호화 대상으로 표시된다. vacuum은 relocation된 삭제 행을 제거할 때 REC_NEWHOME 레코드 전체를 `RVVAC_HEAP_RECORD_VACUUM` 의 undo 데이터로 기록하는데, 이 recovery index는 목록에 없다. develop `e64a04a79` debug 빌드에서 삭제 전후에는 없던 평문 마커가 vacuum 뒤 로그 파일에 나타나는 것을 반복 확인했다.

**영향**: TDE는 데이터 볼륨이나 로그 파일이 유출되어도 암호화 테이블의 내용을 읽을 수 없게 하는 기능이다. 매뉴얼도 암호화 테이블과 관련된 모든 로그를 활성 로그와 보관 로그에서 암호화한다고 설명한다. 이 결함으로 UPDATE로 relocation된 뒤 DELETE된 행의 값이 로그 파일에 평문으로 남아, 로그 파일을 읽을 수 있는 사람이 키 없이 그 값을 볼 수 있다. 로그 암호화가 로그 페이지 단위이므로 같은 로그 페이지에 암호화 대상 레코드가 함께 있으면 평문이 가려진다. 따라서 노출 여부는 실행마다 달라질 수 있고, 운영 환경에서의 빈도는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

heap 행이 UPDATE로 커져 원래 페이지(home 페이지)에 들어가지 않으면, home 슬롯에는 새 위치를 가리키는 REC_RELOCATION 레코드만 남고 실제 행은 다른 페이지에 REC_NEWHOME 레코드로 저장된다. 이 행을 DELETE하면 MVCC 삭제 표시만 남고, 이후 vacuum이 더 이상 필요 없는 행을 물리적으로 제거한다.

vacuum은 행을 준비할 때 undo 로그에 쓰려고 REC_NEWHOME 레코드를 복사한다. [REC_NEWHOME 복사](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/query/vacuum.c#L2050-L2059) `vacuum_heap_record` 의 REC_RELOCATION 분기는 home 슬롯과 forward 슬롯을 하나의 system operation 안에서 제거한다. forward 페이지에 대해서는 복사한 REC_NEWHOME 레코드 전체(`&helper->record`)를 `vacuum_log_redoundo_vacuum_record` 에 넘긴다. [REC_RELOCATION 분기](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/query/vacuum.c#L2414-L2446) 이 함수는 레코드 유형과 레코드 본문을 undo crumb으로 만들어 `RVVAC_HEAP_RECORD_VACUUM` 으로 기록한다. [undo 기록](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/query/vacuum.c#L7525-L7553)

`log_append_undoredo_crumbs` 는 `LOG_MAY_CONTAIN_USER_DATA (rcvindex)` 가 참이고 대상 페이지가 TDE 페이지일 때만 로그 레코드를 암호화 대상으로 표시한다. [암호화 표시 조건](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_manager.c#L2248-L2258) 이 목록에는 `RVHF_INSERT`, `RVHF_UPDATE`, B-tree 레코드 변경 등은 있지만 `RVVAC_HEAP_RECORD_VACUUM` 은 없다. [LOG_MAY_CONTAIN_USER_DATA](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/tde.h#L106-L137) 따라서 forward 페이지가 TDE 페이지여도 행 전체를 담은 이 undo 레코드는 암호화 대상이 되지 않는다.

[매뉴얼의 로그 데이터 암호화 절](https://github.com/CUBRID/cubrid-manual/blob/develop/ko/security.rst?plain=1#L202-L207)은 암호화 테이블이 변경되며 생기는 REDO, UNDO 로그에 암호화가 필요한 데이터가 있을 수 있으므로 암호화 테이블과 관련된 모든 로그 정보를 암호화한다고 설명한다. 이 결함은 그 설명과 다르다.

home 슬롯에 대한 같은 유형의 로그는 forward OID만 담은 REC_RELOCATION 레코드를 기록한다. REC_BIGONE의 home 슬롯 로그도 overflow OID만 담는다. 행 본문이 들어가는 것은 REC_RELOCATION 분기의 forward 페이지 로그이다.

### 로그 페이지 단위 암호화와 재현의 변동

로그 암호화는 레코드가 아니라 로그 페이지 단위로 적용된다. 암호화 대상 레코드를 append하면 그 레코드가 걸친 로그 페이지 전체가 TDE 페이지로 표시된다. [append 시 표시](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_page_buffer.c#L3025-L3026), [페이지 표시](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_page_buffer.c#L4303-L4311) 그러므로 이 vacuum 레코드가 암호화 대상 레코드와 같은 로그 페이지에 있으면 디스크에서는 평문이 보이지 않는다.

실제로 TDE 테이블에 PRIMARY KEY를 둔 실행에서는, vacuum이 같은 로그 페이지에 B-tree 정리 로그(`RVBT_RECORD_MODIFY_NO_UNDO`, `RVBT_DELETE_OBJECT_PHYSICAL`)를 함께 기록하여 평문 마커가 0건이었다. 그러나 `cubrid diagdb -d 8` 로 본 해당 `RVVAC_HEAP_RECORD_VACUUM` 레코드에는 행 전체(undo 3066바이트)가 들어 있었다. 같은 PRIMARY KEY 구성의 다른 실행에서는 vacuum 뒤 마커가 2건 나타났다. 아래 재현은 결과가 로그 페이지 배치에 좌우되지 않도록 인덱스 없는 테이블을 쓴다.

## Test Build

- CUBRID `develop` `e64a04a79a5842827a124b3f8313516d0da2594c` (`11.5.0.2802-e64a04a`), Linux 64bit debug 빌드
- 기본 파라미터: 16KB 페이지, 기본 vacuum 설정, HA 사용 안 함
- release 빌드와 다른 릴리스 브랜치는 시험하지 않았다.

## Repro

준비 사항은 다음과 같다.

- CUBRID 환경 변수(`CUBRID`, `CUBRID_DATABASES`, `PATH`, `LD_LIBRARY_PATH`)가 설정되어 있다.
- `cubrid service start` 로 master를 띄웠고, `tdeleak` 이라는 데이터베이스가 없다.
- `od`, `fold`, `awk`, `grep`, `realpath` 를 사용할 수 있다.

방법은 다음과 같다. ASCII 마커를 `BIT VARYING` 값의 앞부분에 넣고, 나머지는 압축되지 않도록 난수 바이트로 채운다. 각 단계 뒤 활성 로그(`tdeleak_lgat`)와 보관 로그(`tdeleak_lgar*`)에서 `grep -c -a` 로 마커를 포함한 줄 수를 센다. 비암호화 테이블 `ctl_t` 는 이 방법으로 평문을 찾을 수 있음을 보이는 대조군이다. filler 테이블의 INSERT와 DELETE는 vacuum이 DELETE의 로그 블록을 처리하도록 로그를 채운다. 마지막 INSERT는 vacuum이 남긴 로그를 디스크로 flush하는 커밋이다.

아래 스크립트를 `tde-vacuum-leak-repro.sh` 로 저장하고 `bash tde-vacuum-leak-repro.sh /path/to/workdir` 로 실행한다. 작업 디렉터리를 생략하면 현재 디렉터리 아래 `tdeleak-work` 를 쓴다.

```bash
#!/usr/bin/env bash
set -euo pipefail

DB=tdeleak
WORK=$(realpath -m "${1:-./tdeleak-work}")
mkdir -p "$WORK/db"
cd "$WORK/db"

hexrand() { od -An -v -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }
hexstr()  { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
count()   { cat "$WORK/db/${DB}_lgat" "$WORK/db/${DB}_lgar"* 2>/dev/null | grep -c -a "$1" || true; }
heapcap() { csql -u dba "$DB" -l -c "SHOW HEAP CAPACITY OF tde_t" | grep -E 'Num_recs|Num_relocated_recs'; }

CTL=CTLMARKER9ZW
TDE=PLAINLEAKMARK7Q

cubrid createdb --db-volume-size=128M --log-volume-size=64M "$DB" en_US.utf8
cubrid server start "$DB"

{
  echo "CREATE TABLE ctl_t (id INT, v BIT VARYING);"
  echo "INSERT INTO ctl_t VALUES (1, X'$(hexstr $CTL)$(hexrand 32)');"
  echo "CREATE TABLE tde_t (id INT, v BIT VARYING) ENCRYPT=AES;"
  echo "INSERT INTO tde_t VALUES (1, X'$(hexrand 20)');"
  for i in $(seq 2 15); do echo "INSERT INTO tde_t VALUES ($i, X'$(hexrand 1000)');"; done
  echo "UPDATE tde_t SET v = X'$(hexstr $TDE)$(hexrand 3000)' WHERE id = 1;"
} > "$WORK/1-setup.sql"
csql -u dba "$DB" -i "$WORK/1-setup.sql" > "$WORK/1-setup.out"
echo "[1] non-TDE control $CTL: $(count $CTL)"
echo "[2] TDE after relocating update $TDE: $(count $TDE)"; heapcap

csql -u dba "$DB" -c "DELETE FROM tde_t WHERE id = 1" > /dev/null
echo "[3] TDE after DELETE commit $TDE: $(count $TDE)"

{
  echo "CREATE TABLE filler_t (id INT, v BIT VARYING);"
  hexrand 1500000 | fold -w 2000 | awk '{printf "INSERT INTO filler_t VALUES (%d, X'\''%s'\'');\n", NR, $0}'
  echo "DELETE FROM filler_t;"
} > "$WORK/2-filler.sql"
csql -u dba "$DB" -i "$WORK/2-filler.sql" > "$WORK/2-filler.out"

for _ in $(seq 60); do
  heapcap | grep -qE 'Num_relocated_recs *: *0$' && break
  sleep 1
done
csql -u dba "$DB" -c "INSERT INTO ctl_t VALUES (2, X'00')" > /dev/null
echo "[4] TDE after vacuum $TDE: $(count $TDE)"; heapcap
```

csql은 기본적으로 autocommit이므로 각 문장이 바로 커밋된다. 15개 행 중 1번 행만 20바이트로 넣고 나머지는 1000바이트로 넣어 home 페이지를 거의 채운다. 그 뒤 1번 행을 약 3000바이트로 늘리면 home 페이지에 들어가지 않아 relocation된다. `Num_relocated_recs` 가 1이면 의도한 상태이다.

정리는 `cubrid server stop tdeleak` 과 `cubrid deletedb tdeleak` 으로 한다.

## Expected Result

`[2]`, `[3]`, `[4]` 의 TDE 마커가 모두 0이다. vacuum이 행을 제거한 뒤에도 TDE 테이블 행의 값이 로그 파일에 평문으로 나타나지 않는다. 대조군 `[1]` 은 0보다 크다.

## Actual Result

같은 빌드에서 새 데이터베이스로 두 번 실행한 결과가 같았다.

```text
[1] non-TDE control CTLMARKER9ZW: 2
[2] TDE after relocating update PLAINLEAKMARK7Q: 0
        Num_recs                                : 15
        Num_relocated_recs                      : 1
[3] TDE after DELETE commit PLAINLEAKMARK7Q: 0
[4] TDE after vacuum PLAINLEAKMARK7Q: 2
        Num_recs                                : 14
        Num_relocated_recs                      : 0
```

relocation을 만든 UPDATE와 DELETE 커밋 뒤에는 마커가 없다. vacuum이 행을 제거한 뒤(`Num_recs` 15에서 14, `Num_relocated_recs` 1에서 0)에만 마커가 나타난다. 따라서 평문은 DELETE가 아니라 vacuum의 로그에서 나온다.

PRIMARY KEY를 둔 실행에서 `cubrid diagdb -d 8` 로 확인한 해당 레코드의 앞부분은 다음과 같다. vacuum worker(`Trid = -2`)의 forward 페이지 레코드이고, `50 4C 41 49 ...` 가 `PLAINLEAKMARK7Q` 이다.

```text
Type = LOG_UNDOREDO_DATA, Recv_index = RVVAC_HEAP_RECORD_VACUUM,
Volid = 0 Pageid = 4870 Offset = -32766,
Undo(Before) length = 3066, Redo(After) length = 0,
-->> Undo (Before) Data:
  00000: 03 00 C7 00 00 01 00 00 00 00 00 00 00 00 00 00
  00016: 00 16 00 00 00 00 00 00 00 17 B1 00 00 00 00 00
  00032: C0 21 00 0C 0B D8 00 00 00 01 41 E8 09 9A FF 00
  00048: 00 5E 38 50 4C 41 49 4E 4C 45 41 4B 4D 41 52 4B
  00064: 37 51 05 F2 29 48 6A 53 65 13 82 1F FC 47 36 AB
```

## Additional Information

- 관련 이슈: [CBRD-27780](http://jira.cubrid.org/browse/CBRD-27780)은 데이터 볼륨과 DWB에 평문이 기록되는 페이지 해제·버퍼 재사용 경로를 다룬다. [CBRD-24113](http://jira.cubrid.org/browse/CBRD-24113)은 복구 중 system operation의 postpone에서 생기는 TDE 누출을 다루며 본문은 아직 작성되지 않았다. 둘 다 이 이슈의 vacuum undo 로그 경로와 다르다.
- 확인하지 않은 범위: release 빌드, 11.x 릴리스 브랜치, 장시간 실행 뒤 보관 로그, `backupdb` 백업 볼륨, HA 로그 복제이다.

ANALYSIS에서 확인할 사항은 다음과 같다.

- 같은 recovery index가 다른 경로에서도 행 이미지를 담는가. 예를 들어 system operation abort나 복구에서 이 undo를 적용할 때 남는 compensation 로그도 같은 recovery index와 `LOG_MAY_CONTAIN_USER_DATA` 로 암호화 여부를 정한다. [compensation의 조건](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_manager.c#L3173-L3189)
- 다른 vacuum 로그나 system operation 로그 중 TDE 테이블의 행 이미지를 담으면서 목록에 없는 recovery index가 있는가. REC_BIGONE 행의 overflow 페이지 삭제 경로도 여기에 포함한다.
- 이미 평문이 남은 활성 로그, 보관 로그, 백업에 대해 운영자에게 안내할 내용이 있는가.
