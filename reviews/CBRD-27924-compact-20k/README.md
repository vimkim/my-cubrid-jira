# 24KB lazy-default compact fixture

이 입력은 CBRD-27924의 SA compact 경로를 재현한다. 3,000B VARBIT 원본 행에 21,000B VARBIT default를 lazy ADD한다. `make-fixture.py`는 seed 27924의 전체 바이트를 SQL hex literal로 기록한다. 선언된 열 용량이나 SQL 문자의 개수를 데이터 크기로 사용하지 않는다.

별도 CUBRID 테스트 인스턴스에서 실행한다. 설치, 설정, registry, master port, TMP가 해당 인스턴스에 함께 선택되어 있어야 한다. 이 디렉터리에 `make-fixture.py`, `compact-20k.gdb`, `compact-20k-probe.py`를 둔다. 출력 디렉터리는 새 이름을 사용한다.

```bash
python3 make-fixture.py fixture
cubrid createdb --db-page-size=16K --log-page-size=16K \
  --db-volume-size=64M --log-volume-size=64M compact20k en_US
setsid cubrid server start compact20k </dev/null >start.log 2>&1
csql -C -u dba --no-auto-commit -i fixture/setup.sql compact20k >setup.log 2>&1
csql -C -u dba --line-output -i fixture/probe_sa.sql compact20k >sa-before.log 2>&1
csql -C -u dba --line-output -i fixture/probe_cs.sql compact20k >cs-before.log 2>&1
cubrid server stop compact20k </dev/null >stop.log 2>&1

gdb -nx -q -batch -x compact-20k.gdb --args "$CUBRID/bin/cub_admin" \
  compactdb -S -v compact20k dba.probe_sa >sa-compact.log 2>&1
cubrid diagdb -d 9 --dump-records --class-name dba.probe_sa compact20k >sa-heap.log 2>&1

setsid cubrid server start compact20k </dev/null >restart.log 2>&1
csql -C -u dba --line-output -i fixture/probe_sa.sql compact20k >sa-after.log 2>&1
csql -C -u dba --no-auto-commit -i fixture/update.sql compact20k >update.log 2>&1
csql -C -u dba --line-output -i fixture/probe_sa.sql compact20k >update-after.log 2>&1
cubrid compactdb -C -v compact20k dba.probe_cs >cs-compact.log 2>&1
csql -C -u dba --line-output -i fixture/probe_cs.sql compact20k >cs-after.log 2>&1
cubrid server stop compact20k </dev/null >final-stop.log 2>&1
cubrid checkdb -S compact20k >checkdb.log 2>&1
```

실측 baseline `e3589ae42d42b04eb020e1ae43e165b01d31b12a`의 결과는 다음과 같다.

- `probe.events.log`의 `serialize_return`과 첫 `heap_update` 길이는 24,052B이다. `overflow`는 `FILE_MULTIPAGE_OBJECT_HEAP`, 24,068B이며 stack에 `heap_update_home`가 있다.
- SA 이후 `t_rectype=5`, `t_length=8`, `t_reprid=2`, `t_flags=7`이다. 8B는 heap home slot의 forwarding OID 크기이다. 전체 값을 8B로 줄인 결과가 아니다. `SHOW HEAP OOS`는 소유 파일과 청크가 0이다.
- 일반 UPDATE와 새 fixture의 CS compact 이후 `t_rectype=2`, `t_length=3076`, `t_flags=13`이다. 각 테이블은 OOS 파일 1개와 OOS record 2개를 가진다.
- 각 조회에서 `row_count=exact_rows=1`, `payload_bytes=3000`, `added_bytes=21000`이어야 한다.

소유 테스트 인스턴스의 서비스 종료는 해당 환경에서 수행한다. 위 명령은 DB 자료를 삭제하지 않는다. 이 명령 모음은 실제 native 실행의 동일 SQL 입력과 GDB probe를 옮긴 것이다. 실행에 사용한 native containment wrapper 전체의 대체 검증을 주장하지 않는다. 생성한 값의 SHA-256은 실측 입력과 대조했다.

실측의 구조화 결과는 [observations.json](observations.json)에 있다. [CBRD-27924 본문](../../issues/CBRD-27924-sa-compact-layout.md)에 기대 동작, 수리 범위와 검증 한계를 기록한다.
