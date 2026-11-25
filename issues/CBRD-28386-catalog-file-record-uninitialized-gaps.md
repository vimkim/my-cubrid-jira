# [TDE] 클래스 통계·표현 정보를 담는 카탈로그 파일 레코드에 초기화하지 않은 서버 메모리가 그대로 기록된다

**한 줄 요약**: CUBRID/cubrid#8693(CBRD-28257) 코드 리뷰에서 같은 종류의 별도 결함으로 지적된 항목(U-1)이다. 서버가 클래스의 디스크 표현과 통계를 카탈로그 파일에 쓸 때 초기화하지 않은 버퍼를 쓰고 레코드의 일부 바이트를 채우지 않아, 서버 메모리의 이전 내용이 암호화되지 않는 카탈로그 페이지와 로그에 남는다. 이 이슈는 그 바이트가 이전 메모리 내용을 담지 않게 하는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: 카탈로그 파일 레코드(클래스의 디스크 표현, 컬럼별 통계, B-tree 통계, 표현 디렉터리)에 서버 메모리의 이전 내용이 들어가지 않게 하여, TDE로 암호화한 테이블의 데이터가 이 경로로 평문 기록될 가능성을 없앤다.

**이슈 수행 이유**: `catalog_add_representation ()` 은 레코드 버퍼를 `db_private_alloc (thread_p, DB_PAGESIZE)` 로 받고 0으로 채우지 않는다. 이 버퍼에 쓰는 `catalog_put_disk_attribute ()` 는 88바이트 컬럼 레코드 중 32-79바이트(48바이트)를 쓰지 않고, `catalog_put_disk_representation ()` 은 56바이트 표현 레코드 중 20-55바이트(36바이트)를 쓰지 않는다. 카탈로그 파일 페이지(`PAGE_CATALOG`)는 TDE 암호화 대상이 아니다. CBRD-28257 은 `_db_class` 같은 카탈로그 클래스의 힙 행을 다루며, 이 경로(`src/storage/system_catalog.c`)는 다루지 않는다. debug 빌드의 SA 모드에서 버퍼 할당 시 채우는 표식 바이트(`0xA5`)가 위 위치에 그대로 기록되는 것을 확인했다.

**영향**: TDE 사용자는 암호화 테이블의 데이터가 데이터 볼륨과 로그에 평문으로 남지 않는다고 기대한다. `CREATE TABLE`, `ALTER`, `UPDATE STATISTICS` 처럼 표현이나 통계를 쓰는 작업마다 컬럼당 48바이트, 표현당 36바이트의 서버 메모리 내용이 카탈로그 페이지와 로그(`RVCT_INSERT`)에 평문으로 기록된다. 기본 설정의 재현에서 그 자리에는 `gger` 같은 이전 문자열 조각과 정수 값이 들어 있었다. 암호화 테이블의 복호화된 값이 실제로 들어가는지는 확인하지 않았다. 48바이트는 TC `cbrd_27780` 이 찾는 marker 문자열이 통째로 들어갈 수 있는 크기라서, #8693 머지 뒤에도 `cbrd_27780` 이 간헐적으로 실패하면 이 경로가 원인일 수 있다(추론).

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 배경: 카탈로그 파일 레코드

`_db_class`, `_db_attribute` 같은 카탈로그 클래스와 별도로, 서버는 각 클래스의 디스크 표현(어떤 컬럼이 어떤 순서·크기로 저장되는지)과 통계를 카탈로그 파일에 고정 레이아웃 레코드로 저장한다. 레코드 하나는 표현 헤더(`DISK_REPR`, 56바이트), 컬럼마다 컬럼 정보(`DISK_ATTR`, 88바이트)와 기본값, 그리고 인덱스마다 B-tree 통계(120바이트)로 이어진다. 클래스마다 표현 목록을 가리키는 디렉터리 레코드도 따로 있다. 읽는 쪽은 정해진 오프셋만 읽으므로 쓰지 않은 바이트는 결과에 영향을 주지 않지만, 페이지와 로그에는 그대로 남는다.

### 원인 (develop `cbed1d5707` 기준)

develop `e23905d89a` 이후 `cbed1d5707` 까지 아래 파일은 바뀌지 않았다.

- 버퍼 할당: `catalog_add_representation ()`(`src/storage/system_catalog.c:2833`)이 2905행에서 `data = (char *) db_private_alloc (thread_p, DB_PAGESIZE)` 로 버퍼를 받고 초기화하지 않는다.
- 컬럼 레코드: 레이아웃 상수는 110-118행(`CATALOG_DISK_ATTR_N_BTSTATS_OFF` 28, `CATALOG_DISK_ATTR_NDV_OFF` 80, `CATALOG_DISK_ATTR_SIZE` 88)이다. `catalog_put_disk_attribute ()`(474-485행)는 0-31바이트와 80-87바이트만 쓰고 32-79바이트는 쓰지 않는다.
- 표현 헤더: `catalog_put_disk_representation ()`(423-432행)는 0-19바이트만 쓴다. `CATALOG_DISK_REPR_SIZE` 는 56(104행)이므로 20-55바이트가 비어 있다.
- B-tree 통계: `OR_PUT_BTID` 는 10바이트를 쓰지만 다음 필드는 `OR_BTID_ALIGNED_SIZE`(12)에서 시작하므로 10-11바이트가 비어 있다(소스 판단, 재현에서는 인덱스가 없어 확인하지 않음).
- 디렉터리 레코드: `catalog_put_repr_item_to_record ()`(554행)는 16바이트 항목 중 6-7바이트와 12-15바이트를 쓰지 않는다(첫 항목은 12바이트에 개수 1바이트를 쓴다). 버퍼는 `recdes_allocate_data_area ()` → `db_private_alloc ()` 이다.
- 이 레코드들은 `RVCT_INSERT` 로그(1124, 2066행)에도 그대로 들어간다.
- 호출 경로: `UPDATE STATISTICS` 의 `stats_update_statistics_internal ()`·`stats_update_partitioned_statistics ()`(`src/storage/statistics_sr.c:450, 1591`), 클래스를 만들거나 스키마를 바꿀 때 `locator_sr.c`(7021, 7570, 7591행)가 부르는 `catalog_insert ()`(4391행)·`catalog_update ()`(4508행), 그리고 `catalog_fixup_missing_disk_representation ()`(3800행).

### Test Build

- CUBRID/cubrid#8693 head `2a3d8b5147`(develop `e23905d89a` 머지 포함, debug 빌드, CMake preset `debug_gcc`). #8693 은 `catalog_class.c` 만 고치므로 이 경로는 develop 과 같다. 위 파일들은 develop `cbed1d5707` 과 차이가 없다.
- SA 모드(`csql -S`). release 빌드와 CS 모드(서버 기동)는 실행하지 않았다.

### Repro

debug 빌드의 SA 모드에서 `db_private_alloc ()` 은 기본적으로 CUBRID 자체 힙(lea heap)을 쓴다. glibc 할당 표식을 보려면 debug 전용 숨은 파라미터 `use_system_malloc=yes` 로 이 할당을 glibc `malloc` 으로 돌리고, `MALLOC_PERTURB_=90` 으로 새로 할당한 메모리를 `0xA5` 로 채운다. tcache 에서 꺼낸 메모리는 채우지 않으므로 tcache 를 끈다.

```bash
# CUBRID 는 debug 빌드 설치 경로, W 는 빈 작업 디렉터리(CUBRID_TMP 는 짧은 경로)
export CUBRID_DATABASES=$W CUBRID_CONF_FILE=$W/cubrid.conf CUBRID_TMP=<짧은 임시 디렉터리>
cat > $W/cubrid.conf <<'EOF'
[common]
data_buffer_size=32M
log_buffer_size=4M
[@u1leak]
use_system_malloc=yes
EOF
: > $W/databases.txt
mkdir -p $W/db && (cd $W/db && cubrid createdb --db-volume-size=20M --log-volume-size=20M u1leak en_US)
MALLOC_PERTURB_=90 GLIBC_TUNABLES=glibc.malloc.tcache_count=0 \
  csql -S -u dba u1leak -c "create table t (a int, b varchar(10)); update statistics on t;"
```

확인은 데이터 볼륨을 16KB 페이지 단위로 읽어, 페이지 헤더의 `ptype`(오프셋 14)이 `PAGE_CATALOG`(9)인 페이지에서 `0xA5` 가 4바이트 이상 이어지는 구간을 찾는다.

```bash
python3 - $W/db/u1leak 16384 <<'EOF'
import sys, re
path, pgsz = sys.argv[1], int(sys.argv[2])
data = open(path, 'rb').read()
for p in range(len(data) // pgsz):
    pg = data[p*pgsz:(p+1)*pgsz]
    if pg[14] != 9:
        continue
    runs = [(m.start(), m.end() - m.start()) for m in re.finditer(rb'\xa5{4,}', pg)]
    if runs:
        print(f"page {p} pflag={pg[15]}", " ".join(f"@{o}+{l}" for o, l in runs))
EOF
```

`cubrid diagdb -d 7`(dump catalog)은 레코드를 필드 단위로 해석해서 보여 주므로 빈 바이트는 보이지 않는다. 그래서 볼륨 파일을 직접 읽었다.

### Expected Result

카탈로그 페이지와 로그에 `0xA5` 구간이 없다. 레코드에서 어떤 필드에도 속하지 않는 바이트는 0이거나 적어도 이전 메모리 내용이 아니다.

### Actual Result

| 조건 | 결과 |
|---|---|
| `use_system_malloc=yes`, `MALLOC_PERTURB_=90` | 카탈로그 페이지 577(`pflag=0`)에서 `0xA5` 구간 10개: `@10492+36 @10560+48 @10648+48 @10732+4 @10812+36 @10880+48 @10968+48 @11044+36 @11112+48 @11200+48`. 표현 레코드 3개(10472, 10792, 11024에서 시작)마다 표현 헤더 20-55바이트(36), 컬럼 `a`·`b` 의 `DISK_ATTR` 32-79바이트(48)가 모두 `0xA5` 다. `@10732+4` 는 페이지 577의 디렉터리 레코드 항목의 비어 있는 바이트다. |
| 같은 실행의 로그 볼륨 | 활성 로그에서 `0xA5` 구간 36개(36·48바이트 구간 포함), 보관 로그에서 6개 |
| 기본 설정(lea heap), `MALLOC_PERTURB_=90` | 같은 위치에 `0xA5` 대신 이전 메모리 내용이 있다. 첫 컬럼 레코드의 32-79바이트에 `0000 0242 0028 ... 0000 0b40 ...` 같은 정수 값, 두 번째 컬럼 레코드의 같은 자리에 ASCII `gger` 조각이 있다. 디렉터리 레코드의 `@10732+4` 는 이 설정에서도 `0xA5` 였다. |

첫 번째 조건의 표현 레코드 하나(페이지 577, 오프셋 10472-10703) 덤프:

```text
000028e0: 0000 0000 0000 0000 0000 0001 0000 0001  ................
000028f0: 0000 0004 0000 0001 0000 0000 a5a5 a5a5  ................
00002900: a5a5 a5a5 a5a5 a5a5 a5a5 a5a5 a5a5 a5a5  ................
00002910: a5a5 a5a5 a5a5 a5a5 a5a5 a5a5 a5a5 a5a5  ................
00002920: 0000 0001 0000 0000 0000 0001 0000 0000  ................
00002930: 0000 0000 0000 00d1 0002 0000 0000 0000  ................
00002940: a5a5 a5a5 a5a5 a5a5 a5a5 a5a5 a5a5 a5a5  ................
00002950: a5a5 a5a5 a5a5 a5a5 a5a5 a5a5 a5a5 a5a5  ................
00002960: a5a5 a5a5 a5a5 a5a5 a5a5 a5a5 a5a5 a5a5  ................
00002970: 0000 0000 0000 0000 0000 0000 0000 0000  ................
```

### Additional Information

- **재현의 한계**: 표식 바이트와 이전 메모리 조각이 카탈로그 페이지와 로그에 기록되는 것은 확인했다. 암호화 테이블의 복호화된 값이 이 자리에 들어가는 것은 재현하지 않았다. 서버 모드에서는 스레드별 lea heap 을 쓰므로, 어떤 이전 할당이 이 버퍼 자리를 차지했는지에 따라 내용이 달라진다.
- **CBRD-28257 과의 관계**: CBRD-28257 은 `catalog_class.c` 가 만드는 카탈로그 클래스의 힙 행(NULL 고정 길이 필드)을 다룬다. 이 이슈는 `system_catalog.c` 가 만드는 카탈로그 파일 레코드로, 할당 함수, 레코드 형식, 페이지 종류(`PAGE_CATALOG`)가 모두 다르다. #8693 의 TC(`cbrd_28257`)는 이 페이지를 검사하지 않는다.
- **CBRD-27780 TC 와의 관계**: `cbrd_27780` 은 데이터 볼륨 전체에서 marker 문자열을 찾는다. 컬럼당 48바이트 구간은 marker 를 통째로 담을 수 있으므로, #8693 머지 뒤에도 이 TC 가 실패하면 이 경로를 먼저 확인할 수 있다(추론).
- **ANALYSIS 확인 사항**:
    1. 버퍼를 0으로 초기화할지, 각 `catalog_put_*` 함수가 빈 구간을 0으로 쓸지. 후자는 버퍼 할당 방식과 관계없이 막는다.
    2. 같은 파일에서 고정 레이아웃 레코드를 쓰는 다른 경로(클래스 정보 레코드는 `CATALOG_CLS_INFO_RESERVED` 만 0으로 채운다)에 빈 구간이 더 있는지.
    3. CS 모드 서버에서 암호화 테이블을 처리한 직후 `UPDATE STATISTICS` 를 실행하면 복호화된 값이 이 자리에 들어가는지.
    4. 이미 만들어진 DB의 카탈로그 레코드에 남은 내용을 지울 방법이 필요한지.
- **관련**: CBRD-28257(카탈로그 클래스 힙 행, 같은 종류의 결함), CBRD-27780(TDE: 페이지 해제·버퍼 재사용 경로, `cbrd_27780` TC), CBRD-27878(일반 힙 레코드 writer 의 padding·bound bit 초기화, 다른 writer). 중복 이슈는 찾지 못했다.
