# [OOS] serial NEXT VALUE가 OOS chain을 쓰지 않도록 serial 행의 저장 형태를 유지한다

**한 줄 요약**: serial NEXT VALUE가 `_db_serial` 행을 다시 인코딩하면서 comment를 새 OOS chain으로 옮기는 것이 CBRD-28035(chain 누수)와 CBRD-28052(SA 롤백 뒤 손상)의 공통 원인이므로, NEXT VALUE가 OOS에 아무것도 쓰지 않게 해서 두 문제를 함께 해결하는 이슈다.

## Issue Triage

**이슈 수행 목적**: serial NEXT VALUE가 SA 모드와 서버 모드 모두에서 롤백, crash 복구, 반복 호출 뒤에도 serial comment를 손상 없이 유지하고, OOS 레코드를 남기지 않게 한다.

**이슈 수행 이유**: NEXT VALUE는 `_db_serial` 행을 redo 전용 로그로 쓴다. 롤백되어도 값이 되돌아가지 않아야 하기 때문이다. 그런데 행 전체를 `heap_attrinfo_transform_to_disk`로 다시 인코딩하면서 OOS 배치를 새로 결정한다. 4K 페이지 DB에서는 이때 comment가 undo가 있는 새 OOS chain으로 옮겨진다. "롤백되지 않는 행"과 "롤백되는 chain"이 한 쓰기 안에 섞이면서 CBRD-28035와 CBRD-28052가 생겼다. 두 이슈의 PR(#8492, #8496)은 이 섞임의 결과를 각각 수습하는 방식이라, 하나를 막으면 다른 경우가 남았다.

**영향**: 4K 페이지(이름이 긴 경우 8K)로 만든 DB에서 긴 comment를 가진 serial을 쓰는 사용자와 운영자가 영향을 받는다. SA 모드(`csql -S`, standalone 유틸리티)에서 NEXT VALUE를 롤백하거나 비정상 종료하면 serial을 읽을 수 없게 된다(`ER_HEAP_OOS_CORRUPTED_RECORD`, -1397). 모든 모드에서 NEXT VALUE마다 OOS 레코드가 하나씩 쌓인다. `checkdb`는 두 문제를 모두 잡지 못한다. 기본 16K 페이지 DB에서는 comment가 OOS로 가지 않으므로 영향이 없다.

**이슈 수행 방안**: NEXT VALUE가 행을 다시 쓸 때 바꾸지 않은 열은 기존 저장 형태를 그대로 유지한다. inline 열은 inline으로 두고, 이미 OOS에 있는 열은 기존 chain을 그대로 가리킨다. OOS에는 아무것도 쓰지 않는다. 이 방향은 2026-11-12 시제품 검증 뒤 담당자가 결정했다. 상세 내용은 아래 Implementation에 적는다.

---

## AI-Generated Context

## Description

serial의 NEXT VALUE 결과는 트랜잭션과 무관하게 남아야 한다. 트랜잭션 A가 5번을 받고 롤백해도 다음 사람은 6번을 받아야 한다. 그래서 `serial_update_serial_object`(`src/query/serial.c`)는 `_db_serial` 행을 undo 없이 redo 로그만 남기고 쓴다.

OOS(out-of-row storage)는 큰 열 값을 다른 페이지의 chain으로 빼서 저장하고, 행에는 그 chain을 가리키는 참조만 남긴다. OOS chain 삽입은 undo를 남기므로 롤백하면 지워진다.

`_db_serial`에는 `comment VARCHAR(1024)` 열이 있다. OOS로 빼는 기준은 대략 페이지 크기의 1/4이므로, 4K 페이지에서는 긴 comment가 OOS 대상이 된다. NEXT VALUE는 `current_val`과 `started`만 바꾸지만, 행 전체를 다시 인코딩하면서 OOS 배치도 다시 결정한다. CREATE SERIAL과 ALTER SERIAL은 comment를 inline으로 쓰고, 그 뒤 첫 NEXT VALUE가 comment를 새 chain으로 옮긴다. 이 한 번의 쓰기에서 행은 롤백되지 않고 chain은 롤백된다.

| 증상 | 이슈 | 원인 |
|---|---|---|
| NEXT VALUE마다 OOS 레코드가 하나씩 쌓인다 | CBRD-28035 | 매번 새 chain을 쓰고 이전 chain을 아무도 지우지 않는다 |
| SA 모드에서 롤백이나 crash 뒤 serial을 읽을 수 없다 | CBRD-28052 | SA에는 락 관리자가 없어 topop(system operation)을 열지 않으므로, 롤백이 행이 가리키는 chain을 지운다 |

### 기존 PR이 근본 해결이 되지 못한 이유

- #8492(CBRD-28035)는 이미 OOS에 있는 comment에 대해 기존 chain을 재사용한다. 그러나 inline comment를 처음 OOS로 옮기는 NEXT VALUE는 여전히 undo가 있는 chain을 쓴다.
- #8496(CBRD-28052)은 SA 모드에서도 topop을 열어 행과 chain을 함께 확정한다. 그러나 SA에서는 "같은 트랜잭션이 방금 이 serial을 CREATE나 ALTER했는가"를 구분할 수 없다. 그래서 같은 트랜잭션에서 DDL, 첫 NEXT VALUE, 롤백 순서로 실행하면 참조 없는 chain이 하나 남는다. 또 #8434(CBRD-27781)가 먼저 병합되어야 한다.

두 PR 모두 "NEXT VALUE가 OOS chain을 쓴다"는 전제 위에서 그 결과를 수습한다.

## Test Build

- 브랜치 `feature/oos-merge`, 커밋 `67220b7e23`, debug 빌드(gcc).
- DB는 `--db-page-size=4K --log-page-size=4K`로 만든다.

## Repro

아래 명령은 같은 조건을 재현하는 제안 절차다. Actual Result의 관찰값은 단위 테스트에서 얻었다. 긴 comment는 압축되지 않도록 무작위 문자로 만든다(반복 문자열은 압축되어 inline에 남는다).

```bash
cubrid createdb --db-page-size=4K --log-page-size=4K --db-volume-size=64M --log-volume-size=64M serialdb en_US.utf8
long=$(head -c 4000 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | head -c 1000)
csql -S -u dba serialdb -c "create serial s1 nocache comment '$long'"

# SA 모드에서 첫 NEXT VALUE를 롤백한다 (CBRD-28052)
printf 'select s1.next_value;\nselect s1.next_value;\nselect s1.next_value;\nrollback;\n' > first.sql
csql -S -u dba serialdb --no-auto-commit -i first.sql
csql -S -u dba serialdb -c "select current_val, comment from _db_serial where name = 's1'"

# NEXT VALUE마다 OOS 레코드가 늘어난다 (CBRD-28035)
csql -S -u dba serialdb -c "create serial s2 nocache comment '$long'"
for i in $(seq 1 10); do csql -S -u dba serialdb -c "select s2.next_value" > /dev/null; done
csql -S -l -u dba serialdb -c "show heap oos of _db_serial" | grep Oos_num_recs
```

## Expected Result

- 롤백 뒤 `s1`의 `current_val`은 3이고 comment는 원래 값 그대로 읽힌다.
- NEXT VALUE를 반복해도 `Oos_num_recs`가 늘지 않는다.

## Actual Result

`feature/oos-merge`의 serial 단위 테스트(`unit_tests/oos/sql/`, 4K 페이지 DB)에서 확인했다.

- 롤백 뒤 serial을 읽으면 -1397(`out-of-row storage record metadata is inconsistent or corrupted`)로 실패한다.
- NOCACHE serial에 NEXT VALUE를 10번 실행하면 OOS 레코드가 10개 남는다.

## Implementation

2026-11-12 시제품으로 다음 방향을 검증했다.

- `heap_attrinfo_transform_to_disk_keep_form`을 추가한다. 일반 인코딩과 같지만, 모든 가변 열은 기존 레코드의 저장 형태를 따른다. inline 열은 inline으로 두고, 바뀌지 않은 OOS 열은 기존 chain의 참조를 그대로 쓴다. OOS 삽입 경로는 타지 않는다.
- `serial_update_serial_object`가 이 함수를 쓴다. 바뀌는 값인 `current_val`과 `started`는 평소처럼 인코딩되므로, NUMERIC 값이 커져 바이트 수가 늘어도 처리된다(이 브랜치의 NUMERIC은 값 크기에 맞춰 저장 바이트가 달라진다).
- HA applier는 RVHF_UPDATE 로그의 전체 레코드 이미지를 읽는다(`src/transaction/log_applier.c`). 로그 형식은 바뀌지 않는다. comment가 inline으로 남으므로, slave가 찾을 수 없는 OOS 참조를 담은 이미지가 생기지 않는다.

이 방향은 다음을 대체한다.

- CBRD-28035의 #8492와 CBRD-28052의 #8496은 병합하지 않고 닫는다. 두 이슈는 이 이슈로 해결된 것으로 처리한다.
- #8434(CBRD-27781)의 slot 재사용 수정은 serial과 무관한 일반 경로에도 필요하므로 그대로 유지한다.

## Acceptance Criteria

- SA 모드와 서버 모드에서 NEXT VALUE 롤백, kill -9 뒤 복구, 다른 serial의 ALTER/DROP과 섞인 롤백 뒤에도 serial comment가 그대로 읽힌다.
- CREATE SERIAL 이후 NEXT VALUE를 반복하고 재시작해도 `_db_serial`의 OOS 레코드 수가 늘지 않는다.
- `current_val`의 저장 바이트 수가 바뀌는 경우(NOCACHE 255에서 256, CACHE 300의 첫 블록)에도 NEXT VALUE가 성공한다.
- 이전 빌드에서 comment가 이미 OOS로 옮겨진 DB를 열어도, NEXT VALUE가 기존 chain을 그대로 쓰고 레코드 수를 늘리지 않는다.

## Additional Information

시제품(브랜치 `CBRD-26978-serial-inplace-nextval`, `feature/oos-merge` `67220b7e23` 기반) 검증 결과:

| 확인 항목 | 수정 전 | 수정 후 |
|---|---|---|
| serial 단위 테스트 (chain 수, 크기 변화, 롤백 5종) | 실패 (chain 1개, 10개, 10개 남음, -1397) | 통과 |
| SA와 서버 모드의 롤백, kill -9 복구, cross-serial ALTER/DROP | SA에서 -1397 | 모두 정상, `Oos_num_recs` 0 |
| `current_val` 크기 변화 (250에서 259, 65535를 넘는 롤백, CACHE 300) | 정상, OOS 레코드 남음 | 정상, `Oos_num_recs` 0 |
| 이전 빌드에서 OOS chain이 생긴 DB | | chain 3개 그대로 재사용, 값과 comment 정상 |
| `ctest -R oos` 전체 | | 53/53 통과 |

ANALYSIS에서 확인할 사항:

- HA 환경에서 실제 복제를 실행해 보지는 않았다. 로그 형식이 바뀌지 않는다는 점과 applier 코드를 읽은 결과에 근거한다.
- 검증은 debug 빌드에서만 했다.
