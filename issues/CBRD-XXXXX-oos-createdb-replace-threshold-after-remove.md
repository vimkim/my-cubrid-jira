# [OOS] createdb -r에서 oos_trigger_threshold가 허용 범위를 벗어나면 기존 DB를 지운 뒤 생성에 실패하고 databases.txt 항목만 남는다

**한 줄 요약**: PR #8632(CBRD-28062)가 추가하는 `oos_trigger_threshold` 의 범위 검사가 `createdb -r`(기존 DB 교체)에서는 기존 볼륨을 지운 뒤에 실행된다. 그래서 값이 범위를 벗어나면 새 DB는 만들어지지 않고 열 수 없는 `databases.txt` 항목만 남는다. PR #8632 리뷰(F3)에서 재현했고, PR에서는 고치지 않기로 한 후속 이슈다.

## Issue Triage

**이슈 수행 목적**: `createdb -r` 은 `oos_trigger_threshold` 가 새 DB의 페이지 크기에 맞지 않으면 기존 DB를 지우기 전에 실패한다. 실패하더라도 기존 DB와 `databases.txt` 가 서로 맞는 상태로 남는다.

**이슈 수행 이유**: `oos_trigger_threshold` 의 허용 범위는 페이지 크기에 따라 다르다(4K 988~3948, 8K 2012~8044, 16K 4060~16236, 0은 자동값). 서버는 이 범위를 `heap_manager_initialize ()` 에서 검사한다. `createdb` 에서는 이 함수가 볼륨을 만드는 `boot_create_all_volumes ()` 안에서 불린다. 그런데 `-r` 로 기존 DB를 교체할 때는 그 전에 `boot_remove_all_volumes ()` 가 기존 DB의 볼륨을 지운다. 그래서 설정이 틀렸다는 것을 기존 DB를 지운 뒤에야 알게 된다. PR #8632 head `44dab49185` 의 debug 빌드에서 재현했다.

**영향**: 잘못된 `oos_trigger_threshold` 설정(예: 16K용 값을 4K DB에 쓰는 경우)으로 `createdb -r` 을 실행한 운영자나 테스트 스크립트가 겪는다. `-r` 은 원래 기존 DB를 버리는 옵션이므로 데이터 손실 자체가 새 문제는 아니다. 문제는 교체가 실패해 DB가 없는 상태가 되고, `databases.txt` 에는 항목이 남아 그 DB를 열면 "Unable to locate volume information"으로 실패한다는 것이다. 콘솔에는 "Unable to create volumes"만 나오고 원인 파라미터 이름이 나오지 않아, 원인을 찾기도 어렵다. 설정을 고친 뒤 `createdb -r` 을 다시 실행해 회복할 수 있는지는 확인하지 않았다. 기본값(0)을 쓰는 사용자에게는 생기지 않는다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 원인 (PR #8632 head `44dab49185`, `src/transaction/boot_sr.c`)

`xboot_initialize_server ()` 의 실행 순서는 다음과 같다.

1. [boot_sr.c:1700](https://github.com/CUBRID/cubrid/blob/44dab49185a64f2417b7b8d1ae7d9d4e33335654/src/transaction/boot_sr.c#L1700): `-r` 이면 `boot_remove_all_volumes ()` 로 기존 DB의 볼륨을 지운다.
2. [boot_sr.c:1750](https://github.com/CUBRID/cubrid/blob/44dab49185a64f2417b7b8d1ae7d9d4e33335654/src/transaction/boot_sr.c#L1750): `db_set_page_size ()` 로 새 DB의 페이지 크기를 정한다.
3. [boot_sr.c:4975](https://github.com/CUBRID/cubrid/blob/44dab49185a64f2417b7b8d1ae7d9d4e33335654/src/transaction/boot_sr.c#L4975): `boot_create_all_volumes ()` 가 `heap_manager_initialize ()` 를 부르고, 여기서 `oos_trigger_threshold` 를 검사해 `ER_PRM_BAD_VALUE` 로 실패한다([heap_file.c:3970-3976](https://github.com/CUBRID/cubrid/blob/44dab49185a64f2417b7b8d1ae7d9d4e33335654/src/storage/heap_file.c#L3970-L3976)).

PR #8632 전에는 `heap_manager_initialize ()` 가 설정 때문에 실패하는 일이 없었으므로, 이 순서가 문제가 되지 않았다. 범위는 페이지 크기에 따라 정해지고, 페이지 크기는 2단계에서 정해진다. 그래서 검사를 1단계 앞으로 옮기려면 원하는 페이지 크기(`db_desired_pagesize`)로 범위를 계산해야 한다.

## Test Build

- PR #8632 head `44dab49185`(`feature/oos-merge` 대상), debug 빌드(gcc), 2026-11-19.

## Repro

PR #8632 리뷰에서 4K 페이지 DB에 `oos_trigger_threshold=3949`(4K 상한 3948보다 1 큼)로 `createdb -r` 을 실행해 재현했다. 아래 명령은 같은 조건을 다시 만드는 제안 절차다. 값은 `cubrid.conf` 의 `[@thrdb]` 절이나 `[common]` 절에 넣어도 된다.

```bash
cubrid createdb --db-page-size=4K --log-page-size=4K --db-volume-size=64M --log-volume-size=64M thrdb en_US.utf8

CUBRID_OOS_TRIGGER_THRESHOLD=3949 \
  cubrid createdb -r --db-page-size=4K --log-page-size=4K --db-volume-size=64M --log-volume-size=64M thrdb en_US.utf8
echo "rc=$?"

ls <DB 디렉터리>
grep thrdb "$CUBRID_DATABASES/databases.txt"
csql -S -u dba thrdb -c "select 1"
```

## Expected Result

- `createdb -r` 이 기존 DB를 지우기 전에 실패하고, 오류 메시지에 `oos_trigger_threshold` 와 허용 범위가 나온다.
- 기존 DB는 그대로 열린다.

## Actual Result

- `createdb -r` 이 rc=1로 실패하고, 콘솔에는 "Unable to create volumes"만 나온다.
- DB 디렉터리에는 `lob/` 만 남고, 데이터·로그 볼륨은 지워졌다.
- `databases.txt` 의 `thrdb` 항목은 남아 있고, DB를 열면 "Unable to locate volume information"으로 실패한다.

## Additional Information

- PR #8632 리뷰의 다른 지적(F2, `restoredb` 가 볼륨을 덮어쓴 뒤 범위를 검사하는 문제)은 PR #8632에서 다룬다. 이 이슈는 PR에서 고치지 않기로 한 `createdb -r` 경우만 다룬다.
- `ER_PRM_BAD_VALUE` 메시지가 페이지 크기별 허용 범위를 알려 주지 않는 것도 같은 리뷰에서 지적했다(F4). 메시지 개선을 이 이슈에 포함할지는 ANALYSIS에서 정한다.
- `-r` 없이 `createdb` 를 실행할 때 실패 뒤 남는 파일이나 `databases.txt` 항목이 있는지는 확인하지 않았다.

### 관련 이슈

- CBRD-28062: `oos_trigger_threshold` 를 추가하는 이슈다(PR #8632).
