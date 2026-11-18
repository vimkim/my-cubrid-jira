# [OOS] [VACUUM] 서버를 재시작하면 재시작 직후 log block의 vacuum이 비워진 heap 페이지를 반납하지 않는다

**한 줄 요약**: develop 동기화 중 shell TC `cbrd_27780` check 3에서 발견했다. OOS 엔진은 서버를 재시작할 때마다 첫 log block을 "중단된 vacuum job"으로 표시한다. 그래서 그 block의 DELETE로 비워진 heap 페이지가 파일에 반납되지 않는다. 이 이슈는 그 표시가 standalone vacuum이 실제로 중단된 경우에만 붙도록 바로잡는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: 서버를 재시작한 뒤에도 develop과 같이 vacuum이 DELETE로 비워진 heap 페이지를 heap 파일에서 반납하게 한다.

**이슈 수행 이유**: 4K 페이지 DB에서 행 하나가 페이지 하나를 채우는 200행 테이블로 재현했다. 서버를 재시작한 뒤 전체 DELETE를 하면 develop은 heap 페이지가 201개에서 2개로 줄지만, OOS 엔진은 120초 뒤에도 201개 그대로다. OOS 컬럼이 없는 `bit(16000)` 테이블에서도 같다. 원인은 OOS 브랜치에 직접 들어간 커밋 `ff4dc0691a`("Preserve unfinished standalone vacuum through shutdown")다. 이 커밋은 standalone vacuum이 실패한 partial block만 표시하려 했지만, 서버 모드의 평범한 재시작에도 표시를 남긴다.

**영향**: OOS 엔진에서 서버를 재시작하면, 재시작 직후 log block(기본 31 log page) 안에서 DELETE된 행의 heap 페이지가 OOS 컬럼 유무와 관계없이 모든 테이블에서 반납되지 않는다. 행은 vacuum되고 빈 공간은 같은 테이블의 INSERT가 다시 쓸 수 있다. 그러나 페이지를 파일 관리자에 돌려주지 않으므로 다른 테이블과 파일은 그 공간을 쓰지 못한다. 대량 DELETE 뒤 공간 반환을 기대하는 운영자와, 페이지 반납을 확인하는 TC(`cbrd_27780`)가 영향을 받는다. PR #7990(OOS → develop)을 머지하면 develop에도 들어가므로 그 전에 고쳐야 한다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 배경: vacuum이 heap 페이지를 반납하는 조건

vacuum은 로그를 log block 단위의 job으로 처리한다. 각 heap 페이지는 "앞으로 이 페이지를 방문할 vacuum job 수"를 페이지 헤더에 NONE / ONCE / UNKNOWN으로 기억한다. `vacuum_heap_page ()`는 다음 조건을 모두 만족할 때만 빈 페이지를 `heap_remove_page_on_vacuum ()`으로 반납한다(`src/query/vacuum.c:1933`, 3e541fcf67 기준).

- 페이지 상태가 ONCE이고 job이 중단 표시(`was_interrupted`) 없이 실행된다. 중단된 job은 상태가 NONE일 때만 반납한다.
- 남은 레코드가 1개 이하이고 heap이 REUSE_OID다.

`was_interrupted`는 이전 실행이 shutdown이나 crash로 끊긴 job을 다시 돌릴 때 쓰는 보수적 모드다. 이 모드에서는 상태가 ONCE인 페이지의 상태도 NONE으로 바꾸지 않고 반납도 하지 않는다. 이미 처리했을 수도 있는 페이지를 잘못 반납하지 않기 위해서다.

### 원인

커밋 `ff4dc0691a`(2026-10-26, `feature/oos-merge`에 직접 커밋, PR 없음)가 다음 두 곳을 추가했다.

1. `vacuum_boot ()`(`src/query/vacuum.c:1364`)는 `log_Gl.hdr.does_block_need_vacuum`이 참이면 그 시점의 partial block id를 `vacuum_Data.interrupted_partial_blockid`에 기록한다. 주석에 따르면 "이전 standalone 세션이 일부 vacuum한 partial block"을 보존하려는 의도다.
2. `vacuum_consume_buffer_log_blocks ()`(`src/query/vacuum.c:5643`)는 그 block을 vacuum data에 추가할 때 `set_interrupted ()`로 INTERRUPTED 플래그를 붙인다.

그러나 `does_block_need_vacuum`은 standalone vacuum 실패의 표시가 아니다. `log_append.cpp:1370`은 MVCC 로그 레코드를 쓸 때마다 이 값을 참으로 만들고, block이 vacuum data로 넘어갈 때만 거짓이 된다. 따라서 마지막 log block에 MVCC 연산이 있는 상태로 서버를 내리면, 다음 서버 기동은 항상 그 block을 INTERRUPTED로 등록한다. 재시작 뒤 같은 block에 기록된 DELETE도 `was_interrupted=true`로 vacuum되고, 위의 조건 때문에 페이지가 반납되지 않는다. 상태는 ONCE로 남고 그 뒤 vacuum job이 그 페이지를 다시 방문하지 않으므로, 이 결과는 영구적이다.

PR #8417(CBRD-27933)의 `ER_VACUUM_OOS_LOOKUP_DEFERRED` 경로는 원인이 아니다. 재현 로그에 deferral이나 vacuum 오류가 한 건도 없고, OOS 컬럼이 없는 레코드는 그 조회를 하지 않는다(`heap_recdes_contains_oos ()`가 거짓).

### 근거

`er_log_vacuum=4563`(ERROR, WARNING, HEAP, VACUUM_DATA, WORKER, MASTER, JOBS)으로 두 엔진의 vacuum 로그를 비교했다. 표의 heap 페이지 0|4934는 테이블 `h`의 페이지이고 delete는 재시작 뒤에 했다.

| 엔진 | block 28 등록 플래그 | 0\|4934의 delete vacuum | 결과 |
|---|---|---|---|
| develop 5b38db9 | `0x4000000000000000`(IN_PROGRESS) | "from vacuum once to no vacuum" → "Successfully removed page 0\|4934" | 반납 |
| OOS 3e541fcf67 | 추가 시점부터 `0x2000000000000000`(INTERRUPTED), 실행 시 `0x6000000000000000` | 로그 없음(상태 ONCE 유지) | 반납 안 됨 |

OOS 로그에서 INTERRUPTED가 붙은 block은 재시작 직후의 block 28 하나뿐이고, `h`의 delete 200건이 모두 이 block에 들어 있다. develop에는 `interrupted_partial_blockid`가 없다. merge 결과 `5b61c728e6`에도 같은 코드가 있다(`vacuum.c:1365`, `vacuum.c:5661`).

### Test Build

| 엔진 | 커밋 | 빌드 |
|---|---|---|
| develop | 5b38db9 | debug, gcc |
| OOS (develop 동기화 전) | 3e541fcf67 | debug, gcc |
| OOS (develop 동기화 merge, 미push) | 5b61c728e6 | debug, gcc |

### Repro

DB를 4K 페이지로 만들고 서버 모드로 실행한다. `cubrid.conf`에 `enable_string_compression=no`, `data_buffer_size=16M`를 둔다.

```sh
cubrid createdb -r x --db-volume-size=20M --log-volume-size=20M --db-page-size=4K en_US
cubrid server start x
csql -u dba -c "create table h (a bit(16000)); insert into h select cast(X'AB' as bit(16000)) from db_class a, db_class b limit 200;" x
csql -u dba -l -c "show heap capacity of h" x      # Num_pages 201
cubrid server stop x
cubrid server start x
csql -u dba -c "delete from h; create table f (a char(2000)); insert into f select 'f' from db_class a, db_class b limit 3000;" x
# 5초 간격으로 120초 동안 Num_pages를 확인한다
csql -u dba -l -c "show heap capacity of h" x
```

`f`에 대한 INSERT는 log block을 넘겨 vacuum job이 만들어지게 한다.

### Expected Result

delete를 vacuum한 뒤 `h`의 `Num_pages`가 develop처럼 2로 줄어든다.

### Actual Result

| 엔진 | 행 형태 | 재시작 | vacuum 뒤 heap 페이지 |
|---|---|---|---|
| develop 5b38db9 | `char(2000)` / `bit(16000)` | 있음 또는 없음 | 201 → 2 |
| OOS 3e541fcf67 | `bit(16000)` | 있음 | 201 → 201 |
| OOS 5b61c728e6 | `bit(16000)` / `char(2000) storage force_inline` | 있음 | 201 → 201 |
| OOS 3e541fcf67 | `bit(16000)` | 없음 | 201 → 13 |
| OOS 5b61c728e6 | `char(2000) storage force_inline` | 없음 | 201 → 13 |

`Num_recs`는 모든 경우 0이 된다. 레코드는 지워지고 페이지 반납만 빠진다.

### 재시작 없이 13페이지가 남는 현상(별개, develop의 기존 동작)

재시작 없는 경우에는 INTERRUPTED block이 없다. 남은 13페이지는 헤더 페이지, 첫 페이지, 마지막 11개 페이지(0|5122~0|5132)다. 마지막 11개 페이지는 INSERT와 DELETE가 같은 log block(28)에 들어가 상태가 ONCE에서 UNKNOWN으로 내려갔다. 이 상태로는 반납이 허용되지 않는다. OOS 엔진은 같은 작업에서 log를 몇 페이지 더 쓴다. 그래서 `h`의 마지막 INSERT가 develop에서는 block 27(log page 866)에, OOS에서는 block 28(log page 869)에 떨어진다. 같은 규칙이 develop에도 있고 [CBRD-27331](https://jira.cubrid.org/browse/CBRD-27331)이 이를 다룬다. 이 이슈의 범위가 아니다.

### TC

`cbrd_27780` check 3은 vacuum 뒤 `s1_heap`의 heap 페이지가 줄어드는지 확인한다. OOS에서는 `char(2000)` 값이 OOS로 옮겨 가서 이 확인이 무의미해졌다. 그래서 컬럼에 `STORAGE FORCE_INLINE`을 지정해 확인을 되살린 수정이 있다. 그 수정이 이 결함 때문에 실패한다. 수정은 cubrid-testcases-private-ex 브랜치 `CBRD-oos-heap-dealloc-restart-tc`(head `31bdbef3a`, 수정 커밋 `5939a8625`)에 보존되어 있고, 2026-11-18 TC develop 동기화에서는 제외했다. 이 이슈를 고친 뒤 그 커밋을 `feature/oos-merge`와 `tc/pr-7990`에 다시 넣어야 한다.

### ANALYSIS 확인 사항

- `ff4dc0691a`가 보호하려던 경우는 standalone(`SA_MODE`) `xvacuum ()`에서 partial block 처리가 실패한 뒤 종료하는 경우다. 이 경우를 평범한 "아직 vacuum 안 된 partial block"과 구별할 지속 정보가 필요한지 정한다. 지금은 `xvacuum ()` 실패 때만 메모리의 `interrupted_partial_blockid`를 설정하고, 그 값은 shutdown을 넘어 유지되지 않는다.
- 같은 표시가 INSERT를 vacuum하는 job에도 적용되어, 페이지 상태가 ONCE에서 NONE으로 정리되지 않는다. 그러면 이후 DELETE가 그 페이지를 UNKNOWN으로 만들어 재시작 뒤 INSERT된 페이지도 반납을 잃을 수 있다. 코드에서 추론했고 실측하지 않았다.
- crash 뒤 재시작(recovery 경유)도 같은지 확인하지 않았다.
- [CBRD-28018](https://jira.cubrid.org/browse/CBRD-28018)은 반대 방향의 문제다. 중단 표시 없는 job이 이미 해제된 heap 페이지를 만난다. 수정이 그 이슈의 전제(어떤 block이 INTERRUPTED인가)와 충돌하지 않는지 함께 본다.

### 관련 이슈

- 상위: [CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978) [OOS] [EPIC] TODO
- PR [#7990](https://github.com/CUBRID/cubrid/pull/7990) 머지 전에 해결해야 한다.
- [CBRD-27331](https://jira.cubrid.org/browse/CBRD-27331): 같은 block 안의 INSERT와 DELETE로 페이지가 UNKNOWN에 고정되는 develop의 기존 제약. 재시작 없는 13페이지는 이 이슈다.
- [CBRD-27925](https://jira.cubrid.org/browse/CBRD-27925): 빈 OOS 파일 페이지의 회수(LSA gate, ADR-0009). 대상이 OOS 파일 페이지라 이 이슈와 다르다.
- [CBRD-28018](https://jira.cubrid.org/browse/CBRD-28018): 재시작 뒤 vacuum이 해제된 heap 페이지를 만나는 assert. 원인이 다르다.
