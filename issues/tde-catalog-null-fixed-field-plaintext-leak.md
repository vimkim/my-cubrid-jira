# [TDE] 시스템 카탈로그 행의 NULL 고정 길이 필드에 서버 메모리의 이전 내용이 남아, 암호화 테이블의 데이터가 평문으로 디스크에 기록된다

**한 줄 요약**: PR #7990 CI(run 44461741652)에서 shell TC `cbrd_27780`(CBRD-27780)이 "암호화 테이블의 marker가 데이터 볼륨에서 평문으로 발견됨"으로 실패한 원인을 추적하다가 develop에도 있는 결함을 찾았다. 서버가 `_db_class`·`_db_attribute`·`_db_index` 같은 시스템 카탈로그 행을 만들 때 NULL인 고정 길이 필드를 쓰지 않고 건너뛰므로, 초기화하지 않은 `malloc` 버퍼에 남아 있던 다른 테이블의 데이터가 그대로 카탈로그 행에 들어가고, 암호화되지 않는 카탈로그 페이지로 디스크에 기록된다. 이 이슈는 카탈로그 행이 쓰지 않은 바이트를 디스크에 남기지 않도록 바로잡는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: 시스템 카탈로그 행에 서버 메모리의 이전 내용이 들어가지 않게 하여, TDE로 암호화한 테이블의 데이터가 암호화되지 않은 카탈로그 페이지를 통해 평문으로 디스크에 기록되지 않게 한다.

**이슈 수행 이유**: TDE(Transparent Data Encryption)는 `ENCRYPT` 테이블의 페이지를 암호화해서 디스크에 쓰고, 시스템 카탈로그 페이지는 암호화하지 않는다. 서버는 CREATE TABLE, CREATE INDEX 같은 DDL에서 카탈로그 행을 `catcls_put_or_value_into_buffer ()`로 만든다. 이 함수는 NULL인 고정 길이 필드를 0으로 채우지 않고 건너뛴다(`or_advance`). 행 버퍼는 `malloc`으로 받고 초기화하지 않는다. 그래서 그 버퍼 자리에 직전에 쓰고 해제한 메모리 내용, 예를 들어 암호화 테이블의 복호화된 값이 남아 있으면 그 바이트가 카탈로그 행의 NULL 필드 자리에 들어간다. develop `2e66081fd2`와 `feature/oos-merge` debug 빌드에서 재현했고, 평문이 들어간 위치를 페이지·레코드·필드 단위로 확인했다.

**영향**: TDE를 쓰는 사용자는 암호화 테이블의 데이터가 데이터 볼륨에 평문으로 남지 않는다고 기대한다. 이 결함으로 암호화 테이블의 값 일부(재현에서 필드당 8-12바이트)가 암호화되지 않는 카탈로그 페이지에 평문으로 기록된다. 데이터 볼륨 파일을 읽을 수 있는 사람은 키 파일 없이 그 조각을 읽을 수 있다. 어떤 값이 새는지는 서버 메모리 재사용에 달려 있어 예측할 수 없고, 한 번 들어간 조각은 그 카탈로그 행이 남아 있는 동안 디스크에 남는다. 또 이 결함 때문에 shell TC `cbrd_27780`이 develop과 OOS에서 간헐적으로 실패할 수 있다. OOS CI(run 44461741652)에서 실제로 실패했고, develop에서는 같은 TC 시나리오를 로컬에서 12번 돌려 1번 재현했다. 실제 운영 환경에서의 발생 빈도와 새는 양은 알 수 없다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 배경: 카탈로그 행과 NULL 고정 길이 필드

CUBRID 힙 레코드는 고정 길이 필드 영역과 bound bit 배열을 가진다. 고정 길이 필드는 값이 NULL이어도 자리를 차지하고, bound bit가 0이면 읽는 쪽은 그 자리의 바이트를 보지 않는다. 그래서 NULL 필드의 바이트는 읽기 결과에는 영향이 없지만, 쓰는 쪽이 채우지 않으면 디스크에 그대로 기록된다.

서버는 `_db_class`, `_db_attribute`, `_db_index` 같은 시스템 카탈로그 행을 `src/storage/catalog_class.c`에서 직접 만든다. 이 카탈로그 클래스는 암호화 대상이 아니므로 그 페이지는 평문으로 디스크에 쓰인다.

### 원인 (develop `2e66081fd2` 기준)

- 행 쓰기: `catcls_put_or_value_into_buffer ()`(`src/storage/catalog_class.c:3203`)는 NULL인 고정 길이 필드에서 `or_advance (buf_p, (*tp_Type_id_map[data_type]).disksize)`(3263)로 포인터만 옮기고 그 바이트를 쓰지 않는다. 바로 아래 고정 영역 끝의 남는 자리는 `or_pad ()`로 0을 채우는 것과 다르다.
- 행 버퍼: 이 함수를 부르는 `catcls_put_or_value_into_record ()`의 세 호출처가 모두 `record.data = (char *) malloc (record.length)`로 버퍼를 받고 초기화하지 않는다.
  - `catcls_insert_instance ()`(`catalog_class.c:3835`): 3918에서 할당, 3927에서 호출. 새 카탈로그 행(CREATE TABLE, CREATE INDEX 등)
  - `catcls_update_instance ()`(`catalog_class.c:4151`): 4246에서 할당, 4255에서 호출. 카탈로그 행 갱신
  - 같은 파일의 세 번째 호출처: 4508에서 할당, 4517에서 호출
- 그래서 NULL 고정 길이 필드 자리에는 `malloc`이 돌려준 메모리에 직전에 있던 내용이 남는다. 재현에서 그 내용은 같은 서버가 방금 처리한 암호화 테이블의 값이었다. 어떤 버퍼가 그 값을 담았다가 해제했는지는 확인하지 않았다.
- 새는 필드는 새 행에서 보통 NULL인 고정 길이 컬럼이다. 재현에서 확인한 위치와 크기는 다음 컬럼과 일치한다. `_db_attribute.from_class_of`(OID 8바이트, 상속받지 않은 컬럼에서 NULL), `_db_index.referential_class`(OID 8바이트)와 `delete_rule`·`update_rule`·`referential_match_option`(정수 3개 12바이트, 외래 키가 아닌 인덱스에서 NULL), `_db_class`의 datetime 컬럼 하나(8바이트). bound bit까지 디코드해 확인하지는 않았고, 위치·크기와 위 코드로 판단했다.
- `feature/oos-merge`(`e262e79fab`)의 `catcls_put_or_value_into_buffer ()`는 가변 필드 정렬만 바뀌었고 NULL 고정 길이 필드 처리와 `malloc` 할당은 develop과 같다.

### Test Build

- develop `2e66081fd2`, debug 빌드(CMake preset `debug_gcc`), CS 모드(서버 기동)
  - 이 호스트에서는 `src/broker/cas_cgw_odbc.c`에 `#include <ctype.h>`가 없어 develop이 컴파일되지 않았다. 빌드를 위해 이 한 줄만 로컬에 추가했다(broker 코드, 이 경로와 무관).
- `feature/oos-merge` `e262e79fab`, debug 빌드. CBRD-28254 수정(`heap_file.c`만 변경, 이 경로와 무관)을 적용한 빌드다.
- release 빌드는 실행하지 않았다.

### Repro

데이터 볼륨에 marker 문자열이 몇 번 나오는지 서버를 정상 종료한 뒤 센다. 암호화 테이블의 marker는 한 번도 나오면 안 된다.

```bash
db=dleak
cat >> $CUBRID/conf/cubrid.conf <<'EOF'

[@dleak]
data_buffer_size=16M
enable_string_compression=n
EOF
mkdir -p vol && (cd vol && cubrid createdb $db --db-volume-size=20M --log-volume-size=20M --db-page-size=4K en_US.utf8)
cubrid server start $db
{
  echo "create table secret (a varchar(300)) encrypt;"
  echo "create index i_secret on secret (a);"
  for t in $(seq 1 60); do
    echo "insert into secret select lpad('SECRET' || ($t * 1000 + rownum), 300, 'SECRET') from db_class a, db_class b limit 100;"
    echo "create table p$t (a int, b varchar(10)); create index i_p$t on p$t (a);"
  done
} | csql -u dba $db > load.log 2>&1
cubrid server stop $db
cat $(awk '$1 >= 0 { print $2 }' vol/${db}_vinf) | grep -a -o SECRET | wc -l    # 0이어야 한다
grep -a -b -o SECRET $(awk '$1 >= 0 { print $2 }' vol/${db}_vinf)                # 바이트 위치(4096으로 나누면 페이지 번호)
```

발생 여부는 서버 메모리 재사용에 달려 있어 매번 재현되지는 않는다. 같은 shell TC 시나리오는 `cubrid-testcases-private-ex`의 `shell/_06_issues/_26_2h/cbrd_27780/cases/cbrd_27780.sh`(시나리오 1, 확인 2·4)다.

### Expected Result

데이터 볼륨에서 `SECRET`이 한 번도 발견되지 않는다. 카탈로그 행의 NULL 고정 길이 필드 자리는 0이거나 적어도 다른 데이터에서 온 바이트가 아니다.

### Actual Result

| 빌드·시나리오 | 결과 | 평문 위치 |
|---|---|---|
| develop, 위 Repro, 3회 | 6, 2, 0번 발견(3번 중 2번) | 모두 PAGE_HEAP(`ptype=2`), TDE 플래그 없음(`pflag=0`)인 `_db_attribute` 페이지(1회차 page 1508·1509, 2회차 page 1507). 112바이트 `_db_attribute` 행(컬럼 `a`, `b`)의 같은 위치에 `SECRET`으로 시작하는 8바이트가 들어 있다 |
| develop, `cbrd_27780` 시나리오 1을 따른 스크립트, 12회 | 1번 발견(`S1IDX` 1회) | page 1358(`ptype=2`, `pflag=0`)의 `_db_class` 행(테이블 `s1_ovf`) 레코드 오프셋 112에 `S1IDX3je`(8바이트). 앞뒤는 정상 값이다 |
| OOS, 같은 스크립트, 14회 | 1번 발견(`S1HEAP` 1회) | page 2502(`ptype=2`, `pflag=0`)의 `_db_index` 행(인덱스 `i_s1_idx`, slot 19, 160바이트) 레코드 오프셋 36-47에 `1HEAPS1HEAPS`(12바이트), 오프셋 92-99에 `EAPS1HEA`(8바이트). 같은 페이지의 다른 `_db_index` 행은 같은 자리가 0이거나 정상 OID다 |
| OOS, 위 Repro, 3회 | 0번 | — |
| OOS CI run 44461741652, shell `cbrd_27780` | 확인 2·4 NOK, `S1HEAP=1` | CI DB가 지워져 위치는 확인하지 못했다. 개수(1)와 시나리오(확인 2와 4에서 같은 개수)가 위 OOS 재현과 일치한다 |
| `testkit`으로 실행한 shell `cbrd_27780`(OOS), 8회 | 8번 모두 통과 | — |

### Additional Information

- **CBRD-27780과의 관계**: CBRD-27780(Resolved)은 해제한 암호화 페이지와 재사용한 버퍼의 내용이 평문으로 기록되는 문제를 고쳤고, 그 수정(`6fa7524098`)은 develop과 OOS에 모두 들어 있다. 이 이슈는 페이지나 버퍼가 아니라 카탈로그 행을 만드는 메모리 버퍼에서 생기므로 CBRD-27780 수정이 다루지 않는 별도 경로다. CBRD-27780의 shell TC가 데이터 볼륨 전체를 검사하기 때문에 이 결함이 그 TC의 간헐적 실패로 드러났다.
- **TC 영향**: `cbrd_27780`은 이 결함이 고쳐질 때까지 develop과 OOS CI에서 간헐적으로 실패할 수 있다. OOS CI에서는 run 44461741652에서 실패했고 2c38bef05b의 run 44296776118에서는 통과했다. develop CI에서의 실패 기록은 CI 이력 도구에 이 run들이 색인되지 않아 확인하지 못했다.
- **ANALYSIS 확인 사항**:
  1. 세 호출처의 버퍼를 0으로 초기화할지, `catcls_put_or_value_into_buffer ()`에서 NULL 고정 길이 필드를 0으로 쓸지(`or_pad ()`). 후자는 호출처와 관계없이 막는다.
  2. 같은 방식으로 NULL 고정 길이 필드를 건너뛰는 다른 레코드 쓰기 경로가 있는지(예: 클라이언트 쪽 객체 변환 경로). 같은 파일의 `catcls_get_or_value_from_buffer ()`(3432)도 `or_advance`를 쓰지만 읽기 경로라 문제가 아니다.
  3. 이미 만들어진 DB의 카탈로그 행에 남은 조각을 지울 방법이 필요한지(예: 카탈로그 행을 다시 쓰는 방법, 또는 안내).
  4. 로그 볼륨: 카탈로그 행의 insert·update 로그에도 같은 바이트가 평문으로 들어가는지(확인하지 않음).
- **회귀 테스트 후보**: 위 Repro를 여러 번 반복해 데이터 볼륨에 marker가 없음을 확인하는 shell TC. 발생이 확률적이므로, 가능하면 카탈로그 행의 NULL 필드 자리가 0인지 직접 확인하는 방법을 ANALYSIS에서 정한다.
- **관련**: CBRD-27780(TDE: 페이지 해제·버퍼 재사용 경로의 평문 기록, Resolved). CBRD-27937·CBRD-27942·CBRD-28071·CBRD-28072는 암호화 테이블의 데이터가 로그 레코드로 평문 기록되는 다른 경로들이다(모두 Resolved). 이 이슈는 데이터 볼륨의 카탈로그 행이라는 점이 다르다. 중복 이슈는 찾지 못했다.
