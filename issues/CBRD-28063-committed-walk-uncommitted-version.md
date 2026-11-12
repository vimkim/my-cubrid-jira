# [MVCC] 커밋된 최신 버전 읽기가 쓰기 트랜잭션이 커밋한 적 없는 중간 버전을 돌려준다

**한 줄 요약**: Sidecar 개발 브랜치의 24시간 스트레스 시험에서 찾은 develop 결함이다. 락 없이 "마지막으로 커밋된 버전"을 읽는 경로(`LC_FETCH_COMMITTED_VERSION`, `mvcc_satisfies_committed`)가 이전 버전을 따라가는 도중 쓰기 트랜잭션이 커밋하면, 그 트랜잭션이 스스로 덮어써 커밋한 적이 없는 중간 버전을 돌려준다. develop에서는 쿼리 컴파일 때 `_db_histogram` 을 읽는 옵티마이저가 이 경로를 쓰며, 그 결과 커밋된 적 없는 히스토그램으로 실행 계획을 세운다.

## Issue Triage

**이슈 수행 목적**: 커밋된 최신 버전 읽기는 언제나 어떤 트랜잭션이 실제로 커밋한 버전(그 트랜잭션의 마지막 버전)만 돌려준다. 옵티마이저는 커밋된 히스토그램만 읽는다.

**이슈 수행 이유**: `heap_get_visible_version_from_log` 는 현재 버전이 보이지 않으면(TOO_NEW) 로그의 이전 버전을 하나씩 따라가며 버전마다 스냅샷 함수로 다시 판정한다. 트랜잭션 스냅샷은 판정 결과가 고정되어 있지만, `mvcc_satisfies_committed` 는 "판정하는 순간" 쓰기 트랜잭션이 활성인지를 본다. 쓰기 트랜잭션 W가 같은 행을 두 번 갱신했다면 현재 버전(W의 두 번째 버전)은 TOO_NEW이고, 바로 이전 버전은 W의 첫 번째 버전이다. W가 그 사이에 커밋하면 첫 번째 버전이 SATISFIED로 판정되어 반환된다. 이 버전은 W가 커밋하기 전에 스스로 덮어쓴 것이라 어느 시점에도 커밋된 상태가 아니었다. develop에서 디버그 지연 하나만 넣어 5회 중 5회 재현했고(아래 Repro), 지연 없이는 5회 중 0회였다.

**영향**: 한 트랜잭션 안에서 같은 테이블에 `UPDATE STATISTICS` 를 두 번 이상 실행하고(오토커밋 OFF), 그 트랜잭션이 커밋하는 순간 다른 세션이 그 테이블을 쓰는 쿼리를 처음 컴파일하면, 그 세션의 옵티마이저는 커밋된 적 없는 히스토그램을 읽는다. 클라이언트는 이 히스토그램을 클래스 통계가 다시 바뀔 때까지 캐시하므로, 그 세션의 이후 쿼리도 같은 잘못된 선택도로 계획을 세운다(측정: 커밋 1초 뒤 같은 세션 0.91, 새 세션 0.0011). 그 히스토그램은 W가 트랜잭션 도중 본 데이터(커밋되지 않았고 나중에 지운 행 포함)로 만든 것이다. 쿼리 결과는 바뀌지 않고 실행 계획의 카디널리티 추정만 바뀐다. 운영 부하에서의 발생 빈도는 측정하지 않았다. 지연 없이는 경합 구간이 로그에서 이전 버전 하나를 읽는 시간 정도로 짧다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 발견 경위

Sidecar(대형 컬럼 저장 POC) 브랜치의 24시간 스트레스 시험에서, 커밋된 최신 버전으로 행을 읽는 디버그 리더가 어느 트랜잭션도 커밋한 적 없는 값을 받았다. 로그 덤프에서 쓰기 트랜잭션은 그 행을 한 트랜잭션 안에서 두 번 갱신했고, 리더는 그 트랜잭션의 COMMIT이 진행 중일 때 행을 로그에서 읽었다. 리더는 Sidecar 전용 디버그 훅이지만, 원인은 develop의 버전 순회 코드에 있다. 그래서 Sidecar 코드 없이 develop의 실제 호출 경로로 다시 재현했다.

### 커밋된 최신 버전 읽기

CBRD-27369는 쿼리 컴파일 때 `_db_histogram` 읽기가 동시 `UPDATE STATISTICS` 의 락을 기다리지 않도록 "마지막으로 커밋된 버전을 락 없이 읽는" 경로를 추가했다.

- `mvcc_satisfies_committed` ([mvcc.c:642](https://github.com/CUBRID/cubrid/blob/81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953/src/transaction/mvcc.c#L642)): 다른 트랜잭션이 넣었고 그 트랜잭션이 아직 활성이면 TOO_NEW, 아니면 SATISFIED다. 트랜잭션 스냅샷 없이 판정 시점의 활성 여부만 본다.
- `xlocator_fetch` 의 `LC_FETCH_COMMITTED_VERSION` 이 이 함수를 스냅샷으로 쓴다([locator_sr.c:2459](https://github.com/CUBRID/cubrid/blob/81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953/src/transaction/locator_sr.c#L2459)).
- develop의 호출자는 `obj_find_multi_attr_committed` 하나이고([object_accessor.c:3866](https://github.com/CUBRID/cubrid/blob/81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953/src/object/object_accessor.c#L3866)), 이를 부르는 곳은 두 군데다.
  - 쿼리 컴파일의 히스토그램 적재 `stats_get_histogram` → `db_get_histogram_committed` ([histogram_cl.cpp:2767](https://github.com/CUBRID/cubrid/blob/81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953/src/optimizer/histogram/histogram_cl.cpp#L2767)). 결과는 클래스 객체의 `histogram` 에 캐시된다([schema_manager.c:4127](https://github.com/CUBRID/cubrid/blob/81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953/src/object/schema_manager.c#L4127)).
  - `UPDATE STATISTICS` 의 히스토그램 행 존재 확인 `smt_check_histogram_exist` → `db_find_multi_unique_committed`. 존재 여부만 쓰므로 이 결함으로 답이 바뀌지 않는다.
- 행을 찾는 인덱스 조회(`xbtree_find_unique`)도 `_db_histogram` 에 같은 스냅샷을 쓴다([btree.c:29908](https://github.com/CUBRID/cubrid/blob/81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953/src/storage/btree.c#L29908)). 그래서 새로 만든 히스토그램 행(같은 트랜잭션이 삽입 후 갱신)은 쓰기 트랜잭션이 커밋하기 전에는 인덱스에서 찾지 못하므로 이 결함에 닿지 않는다. 키가 바뀌지 않는, 이미 커밋된 행을 한 트랜잭션이 두 번 갱신하는 경우만 닿는다.

### 잘못된 버전이 반환되는 순서

`heap_get_visible_version_internal` 이 현재 버전을 TOO_NEW로 판정하면 `heap_get_visible_version_from_log` 가 이전 버전 LSA를 따라간다([heap_file.c:27143](https://github.com/CUBRID/cubrid/blob/81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953/src/storage/heap_file.c#L27143), 순회 안의 판정은 [heap_file.c:26858](https://github.com/CUBRID/cubrid/blob/81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953/src/storage/heap_file.c#L26858)).

1. H0: 이미 커밋된 히스토그램 행이다.
2. W(오토커밋 OFF)가 `UPDATE STATISTICS ON t` 로 행을 H1으로 갱신한다. H1의 insert MVCCID는 W이고, 이전 버전 LSA는 H0의 undo 이미지를 가리킨다.
3. W가 다시 `UPDATE STATISTICS ON t` 로 행을 H2로 갱신한다. H2의 insert MVCCID도 W이고, 이전 버전 LSA는 H1의 undo 이미지를 가리킨다.
4. 리더 R이 행을 커밋된 최신 버전으로 읽는다. H2는 W가 활성이므로 TOO_NEW다. 순회가 로그에서 H1을 읽는다.
5. 이 사이에 W가 커밋한다.
6. 순회가 H1을 판정한다. W는 더 이상 활성이 아니므로 SATISFIED이고, H1이 반환된다.

올바른 답은 H0(W 커밋 전) 또는 H2(W 커밋 후)다. 트랜잭션 스냅샷이라면 한 MVCCID에 대한 판정이 순회 내내 같으므로 이 순서가 생기지 않는다. 판정이 시간에 따라 바뀌는 `mvcc_satisfies_committed` 만 해당한다.

## Test Build

- develop `81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953`, CUBRID 11.5.0 (11.5.0.2902) debug 빌드, CMake preset `debug_gcc`, Linux x86_64.
- 위 커밋에 디버그 전용 지연 하나만 더했다(아래 Repro의 패치). 동작은 바꾸지 않고 경합 구간만 넓힌다.
- `cubrid.conf` 에 `er_log_debug=yes` 를 더해 판정 결과를 서버 오류 로그에 남겼다.

## Repro

### 1. 지연 패치

`heap_get_visible_version_from_log` 에서 커밋된 최신 버전 읽기가 첫 이전 버전을 읽은 뒤, 판정하기 전에 200 ms 기다린다. `fault_injection.h` 의 `FI_TEST_CODE` 에 `FI_TEST_HEAP_DELAY_COMMITTED_VERSION_WALK = 700013` 을 더하고, `heap_file.c` 에서 `fault_injection.h` 를 include한 뒤 [heap_file.c:26858](https://github.com/CUBRID/cubrid/blob/81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953/src/storage/heap_file.c#L26858) 의 판정 바로 앞에 다음을 넣는다.

```c
#if !defined (NDEBUG)
      if (FI_INSERTED (FI_TEST_HEAP_DELAY_COMMITTED_VERSION_WALK) && LSA_EQ (&process_lsa, previous_version_lsa)
	  && scan_cache->mvcc_snapshot->snapshot_fnc == mvcc_satisfies_committed)
	{
	  er_log_debug (ARG_FILE_LINE, "committed walk read version %lld|%d insid %llu, checking it in 200 ms",
			LSA_AS_ARGS (&process_lsa), (unsigned long long) MVCC_GET_INSID (&mvcc_header));
	  heap_prev_version_walk_release_pages (thread_p, &walk);
	  thread_sleep (200);
	}
#endif /* !NDEBUG */
```

판정 결과(현재 버전과 순회한 버전의 insert MVCCID, SATISFIED/TOO_NEW)도 같은 조건에서 `er_log_debug` 로 남겼다.

### 2. 한 라운드

```sql
-- 준비 (오토커밋)
drop table if exists t;
create table t (c int);
insert into t select mod(rownum, 10) from db_root connect by level <= 1000;
update statistics on t;            -- H0: c = 7 의 선택도 0.1
set system parameters 'fault_injection_ids=700013';

-- 세션 W (csql --no-auto-commit), 커밋하지 않고 둔다
insert into t select 7 from db_root connect by level <= 9000;
update statistics on t;            -- H1: c = 7 이 약 91%
delete from t where c = 7;
update statistics on t;            -- H2: c = 7 이 0건

-- 세션 R (새 csql 세션): 컴파일이 히스토그램을 읽는다
set optimization level 513;
select * from t ra where ra.c = 7;
select sleep (1);
select * from t rb where rb.c = 7;   -- W 커밋 1초 뒤, 같은 세션

-- 서버 오류 로그에 "committed walk read version" 이 찍히면 200 ms 안에 세션 W에서
commit;

-- 라운드가 끝난 뒤 새 세션에서
set optimization level 513;
select * from t fr where fr.c = 7;
```

쿼리마다 별칭을 바꾼 것은 계획 캐시를 피해 매번 컴파일하고 계획을 출력하기 위해서다. 200 ms 안에 커밋하려고 서버 오류 로그를 5 ms 간격으로 확인하다가 W에 `commit;` 을 보내는 스크립트로 실행했다. 사람이 손으로 하려면 패치의 지연을 몇 초로 늘리면 된다. 그 수동 절차는 실행하지 않았다.

### Expected Result

R의 히스토그램은 H0(`c=7 (sel 0.1)`, W 커밋 전) 또는 H2(`sel 0.00111111`, W 커밋 후)다.

### Actual Result

develop + 지연 패치, 5라운드 중 5라운드에서 R이 H1을 읽었다(측정).

| 라운드 | 현재 버전(insid) | 순회가 반환한 버전(insid, 판정) | R의 `c=7` 선택도(경합 컴파일, 1초 뒤) | 새 세션 |
|---|---|---|---|---|
| 1 | 1\|513\|7 (37), TOO_NEW | 1820\|13480 (37), SATISFIED | 0.91, 0.91 | 0.00111111 |
| 2 | 1\|513\|8 (42), TOO_NEW | 2068\|15496 (42), SATISFIED | 0.91, 0.91 | 0.00111111 |
| 3 | 1\|513\|9 (47), TOO_NEW | 2317\|760 (47), SATISFIED | 0.91, 0.91 | 0.00111111 |
| 4 | 1\|513\|10 (52), TOO_NEW | 2565\|4488 (52), SATISFIED | 0.91, 0.91 | 0.00111111 |
| 5 | 1\|513\|11 (57), TOO_NEW | 2813\|6760 (57), SATISFIED | 0.91, 0.91 | 0.00111111 |

순회가 반환한 버전의 insert MVCCID가 TOO_NEW였던 현재 버전과 같다. 즉 W가 덮어쓴 자기 버전 H1이다. 리더의 경합 컴파일은 약 0.2초 걸렸다(지연 구간). R은 W가 커밋한 뒤의 쿼리에서도 H1의 선택도 0.91을 그대로 썼다. 클래스 통계가 바뀌지 않아 캐시한 히스토그램을 다시 읽지 않기 때문이다.

### 대조

- 지연 없음(`fault_injection_ids=0`): 5라운드 중 0라운드. R은 W 커밋 전에 컴파일을 끝내 H0(0.1)을 읽었다. 지연 패치는 경합 구간을 넓힐 뿐이다.
- 지연 + 순회 수정 후보(아래): 5라운드 중 0라운드. 순회가 H1을 TOO_NEW로 넘기고 H0(0.1)을 반환했다.

## Additional Information

### ANALYSIS 확인 사항

- 수정 후보 하나를 로컬에서만 확인했다. 순회가 어떤 버전을 TOO_NEW로 넘겼다면, 그 버전과 insert MVCCID가 같은 이전 버전도 스냅샷 함수를 다시 부르지 않고 TOO_NEW로 본다. 한 트랜잭션의 버전은 모두 보이거나 모두 보이지 않아야 하고, 그중 마지막 버전만 반환될 수 있기 때문이다. 고정된 트랜잭션 스냅샷에서는 결과가 같다. `mvcc_satisfies_dirty` 는 TOO_NEW를 돌려주지 않아 이 순회에 들어오지 않는다. 수정 방향은 ANALYSIS에서 정한다.
- 수정 후보에서 순회는 이미 커밋된 H2가 아니라 H0을 반환하고, R은 그 뒤에도 H0을 캐시해 쓴다. 지연 없는 대조에서도 R은 W 커밋 뒤 H0(0.1)을 계속 썼다. 커밋된 히스토그램이 늦게 반영되는 것은 이 결함과 별개인 CBRD-27369 캐시 설계의 문제이며, 이 이슈의 범위가 아니다.
- Sidecar 브랜치의 같은 결함도 이 수정 후보로 막았다(스트레스 재현 5회 중 5회 → 0회).
- 관련 이슈: CBRD-27369(커밋된 최신 버전 읽기를 추가한 이슈), CBRD-27977(같은 이전 버전 순회 경로의 성능 개선 EPIC. 버전 판정은 다루지 않는다).
