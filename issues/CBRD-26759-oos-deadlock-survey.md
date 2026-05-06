# [OOS] [M2] [Survey] 다중 OOS 페이지 동시 fix 최적화 시 데드락 리스크 분석

<http://jira.cubrid.org/browse/CBRD-26759>

**상위 이슈**: [CBRD-26583](http://jira.cubrid.org/browse/CBRD-26583) -- OOS Milestone 2 Epic

> **TL;DR**: 현재 OOS 모듈은 페이지 버퍼 레이어에서 데드락-free이며 (single-page-hold invariant), M3 검토 중 최적화 3종 중 batch delete는 VPID 정렬 ordered fix가 필수, insert packing은 형태에 따라 ordered fix가 필요, PEEK prefetch는 conditional + fallback만으로 충분하다. M2에서는 회귀 방지용 디버그 진입 assertion 1개만 ship한다.

## Summary

- **문제 / 목적**: 다중 OOS 페이지 동시 fix 최적화 도입 전, 데드락 리스크 사전 식별과 선결 invariant 정리.
- **원인 / 배경**: 현재 OOS 코드는 single-page-hold로 페이지 버퍼 레이어에서 데드락-free; M3 검토 중인 최적화 3종 중 1종(batch delete)이 이 불변식을 깨뜨리며, 다른 1종(insert packing)은 구현 형태에 따라 깨뜨린다.
- **제안 / 변경**: M2 ship 범위는 공개 API 진입 assertion(AC-1)뿐. M3 다중 페이지 경로에는 VPID 오름차순 ordered fix를 의무화한다.
- **영향 범위**: `oos_insert`/`oos_read`/`oos_delete` 공개 API, vacuum-OOS 연동(CBRD-26592), M3 최적화 후속 티켓.

---

## Description

### 배경

현재 `feat/oos` 브랜치(`24954cb86`) OOS 모듈은 `oos_insert`, `oos_read`, `oos_delete` 모든 경로에서 **동시에 OOS 페이지를 1장만 unconditional latch한다는 불변식(single-page-hold invariant)** 을 지키고 있어 OOS 페이지 버퍼 레이어 안에서는 트랜잭션 간 데드락이 발생하지 않는다. 본 분석은 페이지 버퍼 레이어로 한정한다 -- 파일 매니저, 익스텐트, row-lock 등 상위 레이어 자원에 대한 데드락은 범위 밖이다.

향후 검토 중인 최적화가 적용되면 이 불변식이 깨질 수 있다. 동시에 여러 OOS 페이지를 latch한 채 다음 페이지를 fix하는 경로가 생기면 두 트랜잭션이 서로 다른 순서로 페이지를 잡아 AB-BA 사이클을 만들 수 있다.

다루는 최적화 아이디어는 다음 세 가지이다.

- **Optimization 1: `oos_insert` 다중 청크 packing**: 같은 페이지에 여러 청크를 묶어 한 번의 `pgbuf_fix` 로 처리하거나, N개의 페이지를 동시에 잡고 packing 결정을 한다.
- **Optimization 2: `oos_read` PEEK + prefetch**: PEEK 모드에서 reader가 chunk_i를 latch한 채 chunk_{i+1} 을 미리 fix하여 I/O를 overlap시킨다.
- **Optimization 3: `oos_delete_chain` batch delete**: 체인 전체를 한 sysop 안에서 처리하기 위해 모든 청크 페이지를 동시에 latch하고 일괄 log + delete한다.

이는 M2 Epic의 Remarks 표에 식별된 리스크("한 레코드 읽기에 여러 OOS page fix 시 데드락 -- ordered fix 정책 검토 필요")의 구체적 분석 및 대응 방안을 정리한 문서이다.

### 목적

1. 현재 OOS 모듈이 페이지 버퍼 레이어에서 데드락-free한 **구조적 근거** 를 함수별 `pgbuf_fix` 사이트 audit으로 명문화한다.
2. Optimization 1/2/3이 도입될 때 발생 가능한 **데드락 시나리오** 를 사전 식별한다.
3. 최적화와 함께 도입해야 할 **선결 invariant** 와 구현 가이드라인을 제시한다.

### 선결 조건

본 이슈의 close 자체는 AC-1 ship 만으로 가능하다. 단, AC-2(M3 batch delete)의 안전한 구현은 **caller-wiring 검증 티켓** 의 발행 및 완료에 의존한다. 이 placeholder 티켓의 발행은 본 이슈 작성자가 close 직전에 처리하며, 티켓의 검증 작업 자체는 CBRD-26592(vacuum-OOS 연동) 시작 시점에 vacuum 구현자가 수행한다(발행 owner와 작업 owner의 분리 -- AC-5 의 산출물에 발행 책임 명시).

---

### AS-IS: 현재 OOS 모듈의 데드락 안전성

페이지 버퍼 레이어 한정. OOS 레이어 내부의 모든 시나리오가 SAFE이다.

본 audit의 범위는 **이미 할당된 OOS 페이지(`PAGE_OOS`)에 대해 OOS 코드가 직접 호출하는 `pgbuf_fix`/`pgbuf_fix_auto_unfix` 사이트** 로 한정된다. `oos_create_file`, `oos_remove_file`, `oos_remove_page` 는 `file_create`/`file_postpone_destroy`/`file_dealloc`/`file_alloc_sticky_first_page` 등 파일 매니저 API를 통과하며, 해당 API 내부의 latch 프로토콜은 본 audit 범위 밖이다(파일 매니저 자체의 latch 안전성은 별도 자원이며 OOS-OOS 데드락 분석 대상이 아니다).

| 시나리오 | 결과 | 근거 |
|---|---|---|
| INSERT x INSERT | SAFE | bestspace 후보는 `PGBUF_CONDITIONAL_LATCH` 로 zero-wait 탐색(`oos_file.cpp:549-550`). 헤더는 데이터 페이지 unconditional re-fix 이전에 release됨(`:1595` -> `:1601`) |
| INSERT x READ | SAFE | 양측 모두 동시에 잡는 OOS 페이지는 1장. 차단되는 측은 그 시점에 다른 OOS 페이지를 잡고 있지 않음 |
| READ x READ | SAFE | READ latch는 호환 |
| INSERT x VACUUM | SAFE (NEEDS-INVARIANT) | M2 vacuum 연동(CBRD-26592) 시 cross-layer 순서(heap page -> OOS page)를 어겨서는 안 됨 |

이 안전성은 두 가지 구조적 invariant 위에 성립한다.

#### Invariant A: Single-page-hold (재기술 포함)

OOS 코드의 어느 경로에서도 unconditional `pgbuf_fix` 호출 시점에 다른 OOS 페이지 latch를 보유하지 않는다. 즉 OOS 페이지에 대한 blocking wait이 발생할 수 있는 시점에는 호출자의 OOS-page hold count가 0이다.

**OOS 데이터 또는 헤더 페이지에 대한 모든 `pgbuf_fix` 호출 사이트 audit**:

| 라인 | 함수 | 대상 페이지 | latch 모드 | 호출 시점 OOS hold count | 비고 |
|---|---|---|---|---|---|
| `:549-550` | `oos_stats_find_page_in_bestspace` | 데이터 | WRITE, **CONDITIONAL** | 0 (호출 직전 `:520` 에서 mutex unlock 후) | conditional이므로 wait 없음 |
| `:703-704` | `oos_stats_sync_bestspace` | 데이터 | READ, **CONDITIONAL** | 0 (페이지별 fix-use-unfix at `:719`) | conditional이므로 wait 없음, 매 이터레이션마다 release |
| `:875-876` | `oos_stats_update`(`:852` 정의) | 헤더 | WRITE, **CONDITIONAL** | 0 | header page; CONDITIONAL -- `:1496-1497` 의 UNCONDITIONAL header fix와 별개 |
| `:1354` | `oos_read_within_page` | 데이터 | READ, UNCONDITIONAL | 0 (호출 진입점, 이전 hold 없음) | `scope_exit page_unfixer` `:1363-1366` 으로 종료 시 자동 unfix |
| `:1475-1476` | `oos_file_alloc_new` 의 `pgbuf_fix_auto_unfix` | 데이터(신규) | WRITE, UNCONDITIONAL | 0 (`log_sysop_commit` 직후, 다른 OOS hold 없음) | 새로 할당된 페이지이므로 경합자 없음 |
| `:1496-1497` | `oos_find_best_page` 의 헤더 fix | 헤더 | WRITE, UNCONDITIONAL | 0 (함수 진입 직후) | 헤더 1장만 보유 |
| `:1562-1563` | `oos_find_best_page` 의 헤더 re-fix (sync 이후) | 헤더 | WRITE, UNCONDITIONAL | 0 (sync 진입 전 `:1551` 에서 unfix 완료) | sync 중 hold 없음을 보장 |
| `:1601-1602` | `oos_find_best_page` 의 데이터 페이지 unconditional re-fix | 데이터 | WRITE, UNCONDITIONAL | 0 (`:1595` 헤더 unfix, `:1599` candidate unfix 직후) | 본 invariant의 핵심 release-before-refix |
| `:1725` | `oos_delete_chain` 의 청크 페이지 fix | 데이터 | WRITE, UNCONDITIONAL | 0 (이전 청크는 `:1733-1736` `scope_exit` 로 unfix 완료 후 `:1779` 진행) | 1-page-at-a-time |
| `:1912` | `oos_get_length` | 데이터 | READ, UNCONDITIONAL | 0 (단발 호출) | `:1921-1923` `scope_exit` 로 자동 unfix |

모든 unconditional fix 사이트는 호출 시점에 다른 OOS 페이지를 보유하지 않는다. Conditional fix 사이트는 blocking이 아니므로 데드락 사이클에 기여하지 않는다.

**Invariant A의 conditional + 헤더 공존 창**:

`oos_find_best_page` 안에 OOS 페이지를 두 장 동시에 보유하는 짧은 창이 한 곳 존재한다. 또한 `oos_stats_find_page_in_bestspace` 호출은 caller(`oos_find_best_page`)가 헤더 WRITE latch를 보유한 상태에서 진행되므로, 안쪽 함수의 mutex 획득 및 conditional fix는 모두 헤더 latch 보유 중에 수행된다. 두 사실을 분리해 다룬다.

코드 walkthrough(`oos_find_best_page` 흐름):

1. `:1496-1497` -- `hdr_page = pgbuf_fix(hdr_vpid, WRITE, UNCONDITIONAL)`. 헤더 취득.
2. `:1518-1521` -- `oos_stats_find_page_in_bestspace` 호출(헤더 보유 중). 함수 내부에서 `bestspace_mutex` 잠금(`:485`) -> 후보 선택 -> mutex 해제(`:520`) -> conditional fix(`:549-550`). 함수 반환 시 `found_page` 는 caller 소유. NOTFOUND 반환 시 `found_page` 는 NULL.
3. `:1522-1525` -- `result == OOS_FINDSPACE_FOUND` 시 while 루프를 break. NOTFOUND 시 sync(`:1551-1583`)로 진행하며, sync 진입 전 헤더를 `:1551` 에서 unfix하고 sync 후 `:1562-1563` 에서 헤더를 재취득한다.
4. `:1586` -- `if (found_page != NULL)` 분기. **이 시점 hdr_page와 found_page를 동시에 보유**.
5. `:1595` -- `pgbuf_unfix_and_init(hdr_page)`. 헤더 즉시 해제.
6. `:1599` -- `pgbuf_unfix_and_init(found_page)`. conditional 후보 해제.
7. `:1601-1602` -- `pgbuf_fix_auto_unfix(vpid, WRITE, UNCONDITIONAL)`. unconditional re-fix.

(a) **두 페이지 보유 창(`:1586-:1595`)이 안전한 이유**:

- `found_page` 는 conditional latch 성공으로 취득되었으므로 해당 시점에 경쟁자가 없었다.
- 창 내부에서 새로운 `pgbuf_fix` 호출이 없다(둘 다 unfix 또는 set_dirty만).
- 새 unconditional fix(`:1601-1602`)는 두 페이지를 모두 release한 이후에만 호출된다.

(b) **헤더 latch 보유 중 mutex 획득 + conditional fix**:

- `bestspace_mutex` 는 `:485` 에서 잠기고 `:520` 에서 풀린다 -- 헤더 WRITE latch 보유 중에 잠기는 셈이지만, mutex가 풀린 *뒤* 에 데이터 페이지 conditional fix(`:549-550`)가 실행된다. 즉 `(헤더 latch 보유) -> (mutex 잠금/풀림) -> (mutex 미보유 상태에서 conditional fix)` 순서이다.
- 역순(`pgbuf_fix` 호출이 `bestspace_mutex` 보유 중인 경로)은 본 코드에 없다(아래 "Coding convention" 섹션 audit 참조). 따라서 mutex와 page latch 사이의 hold-and-wait 사이클은 형성되지 않는다.
- conditional fix는 zero-wait이므로 헤더 latch 보유 중이라도 다른 트랜잭션의 hold-and-wait에 차단되지 않는다.
- 헤더 WRITE latch는 안쪽 함수의 mutex 잠금/해제 + conditional fix 시퀀스 *전체* 동안 유지된다. 이는 헤더 critical section의 보유 시간을 늘리지만 사이클을 형성하지는 않는다 -- 다른 어떤 호출자도 conditional-fix 대상 데이터 페이지를 보유한 채 헤더 latch를 기다리지 않는다(헤더 진입은 항상 데이터 페이지 hold count 0인 상태에서 수행된다, audit 표 참조).

따라서 본 공존 창과 mutex-during-latch 구간 모두 페이지 버퍼 레이어 데드락에 기여하지 않는다. 본 안전 주장은 페이지 버퍼 레이어에 한정되며, 파일 매니저, 익스텐트, lock manager 등 상위 자원에 대한 cross-layer 데드락은 범위 밖이다.

#### Invariant B: Release-before-unconditional-refix

`oos_find_best_page` 는 unconditional re-fix 직전에 헤더와 conditional 후보 페이지를 모두 release한다.

```
oos_file.cpp:1595  pgbuf_unfix_and_init (thread_p, hdr_page);    // 헤더 해제
oos_file.cpp:1599  pgbuf_unfix_and_init (thread_p, found_page);  // conditional 후보 해제
oos_file.cpp:1601  auto result_page = pgbuf_fix_auto_unfix (thread_p, &vpid, OLD_PAGE,
                                                            PGBUF_LATCH_WRITE, PGBUF_UNCONDITIONAL_LATCH);
```

unconditional fix가 차단될 가능성이 있는 시점에 호출자는 다른 어떤 OOS latch도 잡고 있지 않다.

---

### TO-BE: 최적화가 도입되면 깨지는 가정

#### Optimization 1: `oos_insert` 다중 청크 packing -- 구현 형태에 따라 AB-BA

같은 페이지에 여러 청크를 묶거나 N개의 페이지를 동시에 잡고 packing 결정을 한다.

**구현 형태에 따른 분리**:

- **형태 A(위험)**: `oos_find_best_page` 호출로 페이지 X를 잡은 채 다음 청크의 `oos_find_best_page` 를 호출하여 페이지 Y를 잡는다. 페이지를 보유한 채 다음 페이지를 fix하므로 AB-BA가 가능해진다.
- **형태 B(안전)**: 모든 청크에 대해 latch-free로 후보 VPID 목록을 수집한 뒤(`oos_stats_find_page_in_bestspace` 의 conditional 시도만 사용, 실패 시 후보 변경 또는 alloc 결정), 정렬하여 ordered fix한다. Invariant 1이 처방하는 형태이다.

**형태 A의 데드락 시나리오 -- 참여 latch 명시**:

형태 A에서 두 트랜잭션이 packing 결정을 위해 데이터 페이지 X와 Y를 *보유한 채* 다음 데이터 페이지를 unconditional fix한다고 가정한다(보유 유지가 형태 A의 정의). 헤더 latch는 이 경로에서 어떻게 처리되는가:

1. T1, T2가 chunk_0의 `oos_find_best_page` 를 각각 호출하면, 두 트랜잭션은 헤더 fix(`:1496-1497`, UNCONDITIONAL WRITE)에서 **직렬화** 된다. 헤더는 VFID당 1장이며 WRITE latch는 비호환이므로 이 단계에서 한 번에 한 트랜잭션만 진입한다.
2. 헤더 latch는 `:1595` 에서 release되고, 데이터 페이지는 `:1601-1602` 에서 unconditional re-fix된다(현재 코드). 형태 A는 이 데이터 페이지를 *유지한 채* chunk_1을 위한 `oos_find_best_page` 를 다시 호출하므로, T1은 데이터 페이지 A 보유 -> 헤더 재진입(직렬화) -> 데이터 페이지 B unconditional fix를 시도한다.
3. T2도 대칭으로 데이터 페이지 B 보유 -> 헤더 재진입 -> 데이터 페이지 A unconditional fix를 시도한다.

헤더 직렬화 때문에 두 트랜잭션이 동시에 chunk_1의 헤더 단계에 머무르는 일은 없으나, 각각 헤더를 통과한 뒤 데이터 페이지 B와 A를 *서로 반대 방향으로* unconditional fix하므로 **데이터 페이지 latch 두 장으로 구성된 AB-BA 사이클** 이 형성된다. 헤더 직렬화는 사이클을 *지연* 시킬 뿐 *제거* 하지는 않는다.

**권장 사항**: Optimization 1은 형태 B(latch-free 수집 후 ordered fix)로 구현해야 한다. 형태 A는 채택하지 않는다. AS-IS 안전성은 이 시나리오와 무관하다.

#### Optimization 2: `oos_read` PEEK + prefetch -- conditional + fallback으로 충분

PEEK 모드에서 reader는 chunk_i를 latch한 채 chunk_{i+1} 을 미리 fix하여 I/O를 overlap시킨다.

**안전 근거**:

현재 `oos_read_within_page`(`:1347`)는 READ latch(`:1354`)로 페이지를 잡고 PEEK으로 `spage_get_record` 후 페이지를 즉시 해제한다(`:1363-1366`). 안전성의 핵심은 inserter, reader 모두 매 이터레이션마다 페이지를 완전히 release한 뒤 다음 페이지를 fix한다는 점이다. 즉 OOS 코드의 어떤 경로도 페이지를 잡은 채 다른 OOS 페이지에 대한 unconditional wait을 시도하지 않는다(Invariant A audit 표 참조).

PEEK prefetch가 도입될 때 AB-BA를 만들기 위해 필요한 조건:

1. reader가 chunk_i를 보유한 채 chunk_{i+1} 에 대해 unconditional wait
2. 다른 어떤 경로가 chunk_{i+1} 을 보유한 채 chunk_i 에 대해 unconditional wait

조건 1은 prefetch 구현이 unconditional latch를 사용할 때만 발생한다. **conditional latch + fallback으로 prefetch를 구현하면 unconditional wait이 없으므로 사이클이 형성되지 않는다**(Invariant 3).

조건 2는 *어떤 동시 경로* 가 페이지 X를 보유한 채 페이지 Y에 unconditional wait해야 성립한다. 현재 OOS 경로에는 그러한 사이트가 없다(audit 표 참조). 다만 향후 Optimization 1을 형태 A로 구현하거나, Optimization 3을 ordered fix 없이 batch화하거나, **vacuum-OOS 연동(CBRD-26592, 현재 `:1005` 의 TODO 표지)에서 vacuum이 페이지 X 보유 중 페이지 Y에 unconditional wait하는 코드가 추가되면** 조건 2가 충족된다. 따라서 vacuum-OOS 연동 코드는 이 invariant를 별도 검토해야 한다.

**권장 사항**: Optimization 2는 Invariant 3(conditional + fallback)만으로 충분하며, ordered fix까지 요구하지 않는다. 단 조건 2를 만들 수 있는 모든 신규 경로(Optimization 1 형태 A, ordered fix 없는 Optimization 3, vacuum-OOS 다중 fix)는 별도 invariant 검토 대상이다.

#### Optimization 3: `oos_delete_chain` batch delete -- 실제 AB-BA 발생

체인 전체를 한 sysop 안에서 처리하기 위해 모든 청크 페이지를 동시에 latch하고 일괄 log + delete한다.

**현재 코드의 동작과 batch 도입 시 비용**:

현재 `oos_delete_chain`(`:1717`)은 while 루프(`:1721-1780`)를 1-페이지씩 진행한다. 매 이터레이션은 `pgbuf_fix(WRITE, UNCONDITIONAL)`(`:1725`) -> `spage_get_record(PEEK)`(`:1739`) -> `oos_log_delete_physical`(`:1760`) -> `spage_delete`(`:1763`) -> `scope_exit page_unfixer`(`:1733-1736`) 로 페이지를 unfix한 뒤 `current_oid = next_chunk_oid`(`:1779`)로 진행한다. 각 청크 삭제는 `oos_log_delete_physical` 로 **개별** WAL 레코드(`RVOOS_DELETE`)를 생성하며, **현재 코드는 sysop으로 묶지 않는다**(`oos_delete` 함수 헤더 주석 `:1793-1813` 참조).

| 항목 | 현재 (1-page-at-a-time) | 2-pass batch |
|---|---|---|
| `pgbuf_fix`/unfix 횟수 (N청크) | N | 2N (pass-1 collect + pass-2 fix-and-delete) |
| WAL 레코드 수 | N개 `RVOOS_DELETE` | N개 `RVOOS_DELETE` (개별 청크 undo는 여전히 필요), 단일 sysop 경계로 묶임 |
| 페이지 버퍼 비용 | N | 2N (증가) |
| sysop/log overhead | 0 (현재 sysop 없음) | sysop start/commit 1회로 통합 |

**Batch의 이점은 페이지 버퍼 fix 비용을 줄이는 것이 아니라 sysop 경계 통합** 이다. Recovery 시 부분 재실행 가능성을 줄이고, log latency 측면에서 한 트랜잭션 내 chain delete를 단일 atomic 단위로 다룰 수 있게 한다. 단, 페이지 버퍼 비용은 2배가 되므로 M3에서 실측 후 채택 여부를 결정한다.

**Pass-1 latch 정책 -- "latch-free" 의 정확한 의미**:

Pass-1에서 `next_chunk_oid` 를 수집할 때 **각 페이지에 대해 READ latch를 잡고 `spage_get_record(PEEK)` 으로 슬롯을 읽은 뒤 즉시 unfix** 하는 방식을 의미한다(현재 `oos_delete_chain` 의 1-page-at-a-time walk와 latch 정책이 동일하나, delete는 수행하지 않는다). "latch-free"는 페이지를 잡지 않는다는 뜻이 아니라 **여러 페이지를 동시에 잡지 않는다(single-page-hold)** 는 뜻이다.

Pass-1과 pass-2 사이에 chain이 변경되지 않음을 보장하는 근거:

- **체인 X의 청크 자체에 대한 동시 삭제 차단**: caller가 OID 단위 X_LOCK(heap row-level)을 보유한다는 가정 하에, 다른 트랜잭션은 동일 chain의 동일 청크를 삭제할 수 없다. 따라서 pass-1이 수집한 *(VPID, slotid)* 쌍이 가리키는 *체인 X의 청크 슬롯* 은 pass-2 시점에도 존재한다 -- slot 재사용/비활성화는 청크가 먼저 삭제되어야 발생하는데, 그 삭제는 X_LOCK으로 차단된다. 따라서 **pass-2 진입 시 slot 상태 재검증은 필요 없다**(X_LOCK 가정이 성립하는 한).
- **페이지 자체의 회수 차단**: 페이지가 비어 있을 때 vacuum이 페이지를 회수하여 다른 파일이 재사용하는 시나리오는, CBRD vacuum이 commit 후 청소 모델이므로 본 트랜잭션이 진행 중인 동안에는 발생하지 않는다(`oos_delete` 헤더 주석 `:1812-1813` 참조: "Page deallocation is NOT done here. Empty pages will be reclaimed by vacuum after the transaction commits.").

`:1701-1702` 의 TODO 주석은 caller가 X_LOCK을 보유한다는 가정이 미검증임을 명시한다. M3 batch-delete 2-pass 설계는 이 caller-wiring 검증 완료에 의존(blocked)된다 -- 검증 티켓 발행은 본 이슈의 선결 조건에 포함된다(AC-2 비고 및 Description 선결 조건 참조).

**데드락 시나리오 -- 두 체인이 페이지를 교차 사용하는 단일 단락**:

Insert 단계에서 두 트랜잭션 T1(체인 X)과 T2(체인 Y)는 single-page-hold로 동작하므로 매 청크마다 페이지를 잡고 release하며 진행한다. bestspace 캐시는 VFID 키로 공유되며 동일 시점에 여러 후보 페이지를 보유할 수 있다. 따라서 T1과 T2가 서로 다른 시점에 best 후보로 페이지 A, B를 번갈아 선택하면 결과 체인 link 순서가 X = `[A, B, ...]`, Y = `[B, A, ...]` 와 같이 **서로 반대 방향으로 페이지를 가로지르는** 배치가 가능하다(이 배치는 현재 single-page-hold insert 의미론과 모순되지 않으며 기존 코드에서도 발생할 수 있다).

구체적인 4-step 인터리빙(어떻게 X, Y의 link 순서가 반대로 결정되는가):

```
t1: T1 -- bestspace에서 A를 best로 선택, A를 fix, X의 head chunk를 A에 insert, A unfix.
        bestspace 캐시 상태: A는 freespace 감소로 후보 우선순위 하락, B가 상대적으로 우선.
t2: T2 -- bestspace에서 B를 best로 선택, B를 fix, Y의 head chunk를 B에 insert, B unfix.
        bestspace 캐시 상태: B 우선순위 하락; 잔여 freespace는 A vs B 중 A가 더 큼(또는 동률에서 다른 후보).
t3: T1 -- chunk_1을 위해 다시 best 조회. A가 t1에서 한 청크 차감되어도 B 가용 공간 + 다른 후보보다
        높은 freespace를 유지한다고 가정하면 best는 B로 결정 가능; T1이 B를 fix, X의 chunk_1을 B에 insert, B unfix.
        결과 chain X의 link 순서: A -> B.
t4: T2 -- chunk_1을 위해 best 조회. 이번에는 A가 best로 결정; T2가 A를 fix, Y의 chunk_1을 A에 insert, A unfix.
        결과 chain Y의 link 순서: B -> A.
```

t1-t4 각 단계는 single-page-hold(매 fix 후 즉시 unfix)를 만족하므로 현재 insert 의미론과 일관된다. bestspace 결정이 페이지의 잔여 공간/캐시 정책에 따라 매 fix-and-update 후 달라질 수 있다는 점이 핵심이다 -- 두 트랜잭션이 동일 VFID에서 인터리브하면 chain link 순서는 VPID 정렬과 무관해질 수 있다.

이제 vacuum 시점에 두 체인을 batch delete로 처리한다고 하자. ordered fix 없이 chain link 순서대로 walk하면:

```
T0: vacuum1 -- 체인 X 처리, A WRITE 보유, B fix 시도
T1: vacuum2 -- 체인 Y 처리, B WRITE 보유, A fix 시도
==> AB-BA 데드락
```

체인의 OID 순서는 bestspace 결정에 따라 결정되므로 VPID-ordered가 아니다 -- 체인 link 순서대로 walk하는 것만으로는 데드락을 막을 수 없다. **VPID 정렬 + ordered fix가 필수이다**. 이는 Optimization 3에서 단일 구현 선택이 아닌 구조적 요건이다.

---

### 도입해야 할 Invariant

#### Invariant 1: VPID 오름차순 ordered fix

동시에 2장 이상 OOS 페이지를 latch하는 모든 경로는 다음 절차를 따른다.

1. 대상 VPID 목록을 수집한다. 사례별 수집 방식:
   - **batch delete(Optimization 3)**: 체인 walk 1차 패스, single-page-hold 보장 -- 한 번에 한 페이지만 잡고 즉시 release 후 다음 페이지로 진행하며 `next_chunk_oid` 를 따라간다.
   - **insert packing(Optimization 1, 형태 B)**: 수집할 체인이 아직 없으므로 `oos_stats_find_page_in_bestspace` 의 conditional latch + `spage_*` 검사로 packing 후보 N개를 누적한다. conditional 실패 또는 공간 부족인 후보는 alloc_new로 대체하여 최종 N개의 VPID를 확정한다.
2. `(volid, pageid)` 오름차순으로 정렬한다.
3. 정렬된 순서대로 `pgbuf_fix` 한다.

체인 자체는 VPID 순서가 아니므로 batch delete는 필연적으로 **2-pass** 가 된다(1차: single-page-hold로 next_chunk_oid 수집, 2차: VPID 정렬 후 fix + delete + log). Optimization 1을 형태 B로 구현할 때도 동일 절차가 적용된다.

#### Invariant 2: VPID 정렬 ordered fix (manual sort) 단일 채택, `pgbuf_ordered_fix` 는 비채택

CUBRID는 `heap_file.c` 에서 다중 페이지 fix용 `pgbuf_ordered_fix` 를 사용한다(`grep -c pgbuf_ordered_fix src/storage/heap_file.c` = 20). 대표 호출 예시: heap chain 헤더/forward/overflow 페이지의 동시 fix(`heap_file.c:21458`, `:21524`, `:22516`), heap object overflow vacuum 경로(`:18640`), heap compact(`:25526`).

OOS는 `pgbuf_ordered_fix` 가 아닌 **manual VPID 정렬 + 단일 unconditional fix 루프(Invariant 1)** 를 단일 채택 방안으로 결정한다. 결정 근거:

- OOS의 다중 페이지 fix 경로는 batch delete의 2-pass 구조에서 자연스럽게 VPID 목록을 가지므로 manual 정렬 비용이 추가 인프라를 요구하지 않는다.
- `pgbuf_ordered_fix` 는 deadlock detection + retry 로직을 내장하나, retry 비용 모델과 OOS 워크로드의 적합성 검증에 필요한 별도 비용 측정 작업을 본 이슈에서 수행하지 않는다.
- Manual 정렬은 동작 모델이 단순하여 코드 리뷰와 디버깅이 용이하다.

따라서 본 이슈의 권고는 **Invariant 1의 manual 방식을 단일 표준으로 채택** 하는 것이다. `pgbuf_ordered_fix` 도입 여부는 OOS 다중 페이지 워크로드에서 manual 정렬의 retry-free 특성이 측정 결과 부족하다고 판명되는 경우에 한해, 별도 후속 티켓에서 재검토한다.

#### Invariant 3: Opportunistic prefetch는 conditional latch + fallback

PEEK reader prefetch처럼 "가능하면 좋고, 안 되면 직렬로 가도 되는" 경로는 `PGBUF_CONDITIONAL_LATCH` 로 시도하고 실패 시 현재 페이지를 release한 뒤 직렬 walk로 fallback한다. unconditional blocking wait이 없으므로 사이클이 형성되지 않는다. Optimization 2(PEEK prefetch)에는 ordered fix가 아닌 이 패턴으로 충분하다.

#### Cross-layer note for CBRD-26592 (heap-OOS 호출 순서)

heap/vacuum 레이어가 OOS API를 호출할 때의 latch 순서를 다음으로 고정한다 -- **현재 OOS 코드에 적용되는 invariant가 아닌, vacuum-OOS 연동 코드(CBRD-26592)에 진입할 때 채택해야 할 설계 제약**.

```
heap page -> OOS header -> OOS data pages (VPID asc)
```

현재 OOS 코드에는 heap latch와 OOS latch가 동시에 존재하는 경로가 없다. `oos_file.cpp:1005` 의 `// TODO: will be called by vacuum when OOS vacuum is implemented` 주석과 `:1812-1813` 의 `Page deallocation is NOT done here. Empty pages will be reclaimed by vacuum after the transaction commits.` 주석은 향후 vacuum 진입 지점을 표시할 뿐, 실제 호출 경로는 아직 없다. 따라서 본 메모는 정보 제공이며 M2에서 코드 변경을 요구하지 않는다.

CBRD-26592 구현 담당자가 결정/수행해야 할 사항은 다음 체크리스트로 정리한다.

- (a) **enforcement 옵션 선택**: 코드 주석으로만 명문화(comment-only convention, code review에 의존) vs. debug build에서 OOS API 진입 assertion에 "thread가 heap-typed 페이지 latch를 보유하지 않음을 검증" 추가. 두 옵션 중 하나를 선택한다.
- (b) **assertion 옵션 선택 시 필요한 helper 2종**: (i) thread의 held-pages 리스트를 page-type으로 필터링해 카운트하는 새 함수 -- 내부적으로 `pgbuf_Pool.thrd_holder_info[thread_p->index].thrd_hold_list` 를 walk한다(자료구조 위치: `PGBUF_BUFFER_POOL.thrd_holder_info` 멤버 선언 `page_buffer.c:783`, anchor 구조의 `thrd_hold_list` 필드 `page_buffer.c:484`, anchor 배열 초기화 `:5712-5742`). 현재 외부 getter는 없으므로 신규로 추가한다. (ii) holder의 page-type을 조회하는 술어 -- 기존 `pgbuf_get_page_ptype`(`page_buffer.c:5081` 정의, `page_buffer.h:395` 선언)을 사용한다.
- (c) **page-type 필터링 집합**: 본 메모는 `PAGE_HEAP`(필수)을 권고한다. `PAGE_OVERFLOW`, `PAGE_HEAP_BMAP` 등 추가 type 포함 여부는 CBRD-26592에서 실제 caller가 어떤 page-type을 잡고 OOS API에 진입하는지 확정된 시점에 결정한다(현재 미정).
- (d) **비용 모델**: holder 리스트 길이 O(N)에 비례하며 thread당 통상 수개 이하. debug build에서만 발생하므로 release build에는 영향 없음.
- (e) **금지**: 역순(OOS page 보유 중 heap page fix)은 어떤 경우에도 금지한다.

#### Coding convention: bestspace mutex must not wrap `pgbuf_fix`

(데드락 invariant가 아닌 코딩 컨벤션) `oos_Bestspace->bestspace_mutex` 가 `pgbuf_fix` 를 감싸는 경로를 만들지 않는다. 현재 코드의 모든 `bestspace_mutex` lock/unlock 사이트:

- `:276-330` -- `oos_stats_add_bestspace`: lock -> hashtable 조작 -> unlock. `pgbuf_fix` 없음.
- `:342-356` -- `oos_stats_del_bestspace_by_vpid`: lock -> hashtable 조작 -> unlock. `pgbuf_fix` 없음.
- `:368-384` -- `oos_stats_del_bestspace_by_vfid`: lock -> hashtable 조작 -> unlock. `pgbuf_fix` 없음.
- `:485-520` -- `oos_stats_find_page_in_bestspace`(Phase A): lock(`:485`) -> candidate_vpid 선택 -> **unlock**(`:520`) -> 그 이후 Phase C에서 `pgbuf_fix`(`:549-550`).

`pgbuf_fix` 가 mutex 보유 상태에서 호출되는 경로는 현재 코드에 존재하지 않는다.

**컨벤션 enforcement**: AC-1의 단위 테스트 일부로 `grep -E '(pthread_mutex_lock.*bestspace_mutex|pthread_mutex_unlock.*bestspace_mutex)' src/storage/oos_file.cpp` 의 결과를 정렬해 lock/unlock 쌍 사이의 라인에 `pgbuf_fix` 가 등장하지 않음을 검증하는 정적 검사를 CI에 추가한다(AC-1 helper 작업의 일부로 묶이며 코드 ship 분량은 셸 1줄 + CI hook 1개). 신규 코드 리뷰의 보조 가드레일이다.

---

## Specification Changes

N/A -- M3 최적화도 사용자 가시 변경 없음(내부 latch 프로토콜).

---

## Implementation

### 권장 구현 순서

| 순서 | 작업 | 비고 | M 단계 |
|---|---|---|---|
| 1 | 디버그 빌드 assertion 추가 | 공개 API(`oos_insert`, `oos_read`, `oos_delete`) 진입 시점에 thread가 보유한 OOS 페이지 수가 0임을 검증 | M2 즉시 |
| 2 | cross-layer 호출 순서 주석 명문화 | CBRD-26592 내부에서 실제 call-site 코드 작성 시 해당 경로에 직접 명문화 | CBRD-26592 |
| 3 | `oos_delete_chain` batch 화(선택) | 1차 패스 single-page-hold로 VPID 수집 -> 정렬 -> sysop 안에서 ordered fix. M3 전 비용 측정 필요 | M3 |
| 4 | `oos_read` PEEK prefetch(선택) | conditional latch + fallback 패턴. ordered fix 불필요 | M3 |
| 5 | `oos_insert` packing(선택) | 형태 B(latch-free 수집 후 ordered fix)로 구현. 형태 A 채택 금지 | M3 |

3-5는 모두 M3에서 검토하며, 구현 우선순위는 별도 비용/복잡도 평가에 따라 결정한다.

### M2 시점의 범위 정의

M2에서 본 이슈가 ship하는 실체는 다음 한 가지로 한정한다.

1. **디버그 assertion**: `oos_insert`, `oos_read`, `oos_delete` 공개 진입점에서 thread가 OOS 페이지를 0장 보유 중임을 assert하는 코드.

   **구현 sketch**: 페이지 버퍼는 thread당 held-pages 리스트(`pgbuf_Pool.thrd_holder_info[thread_p->index].thrd_hold_list`)를 유지한다. 자료구조 위치는 `PGBUF_BUFFER_POOL.thrd_holder_info` 멤버 선언 `page_buffer.c:783`, anchor 구조의 `thrd_hold_list` 필드 `page_buffer.c:484`, anchor 배열 초기화 `:5712-5742` 이다. 외부에서 이 리스트를 walk할 수 있는 public getter는 현재 존재하지 않는다(공개 API는 `pgbuf_get_page_ptype` 정도 -- `page_buffer.h:395` 선언, `page_buffer.c:5081` 정의). 따라서 assertion 도입 시 다음 중 하나가 필요하다:

   - **옵션 A(권장)**: `page_buffer.c` 내부에 새 helper `pgbuf_count_thrd_held_pages_of_type(thread_p, PAGE_OOS)` 를 작성한다. 내부적으로 `pgbuf_Pool.thrd_holder_info[thread_p->index].thrd_hold_list` 를 직접 walk하며 각 holder의 BCB로부터 `pgbuf_get_page_ptype` 결과가 인자 type과 일치하는 entry를 카운트한다(`page_buffer.h` 에 선언만 추가, 정의는 `page_buffer.c` 에 둠 -- 내부 자료구조에 직접 접근하므로 선언/정의를 분리해야 한다). 비용은 holder 리스트 길이 O(N)에 비례하나 thread당 통상 수개 이하이므로 debug build에서 무시 가능. 본 helper 도입은 AC-1의 일부이다.
   - **옵션 B**: OOS API 진입 시 OOS 진입 카운터를 thread-local 변수로 별도 관리하고, 진입점에서 == 0을 assert. 페이지 버퍼와의 결합이 적으나 OOS 코드 모든 fix/unfix 경로에 카운터 increment/decrement를 삽입해야 하므로 코드 변경 면적이 더 크다.

   옵션 A를 채택한다. 또한 `oos_find_best_page` 내부의 conditional + 헤더 공존 창은 assertion 대상에서 제외(public entry point에서만 발동, helper 내부에서는 발동하지 않음 -- Invariant A 재기술 참조).

   추가로 AC-1과 함께 ship하는 정적 컨벤션 검사(`bestspace_mutex` 가 `pgbuf_fix` 를 감싸지 않음)는 CI에서 셸 grep 1줄 + Make/CMake step 1개로 수행한다(코드 ship은 검사 스크립트 자체).

Cross-layer 호출 순서(CBRD-26592 메모)는 vacuum-OOS 연동 코드가 실제로 작성되는 CBRD-26592 내부에서 해당 call-site에 직접 명문화한다. M2 시점에 선제적으로 cross-layer 주석을 삽입하지 않는다.

다중 페이지 최적화(ordered fix 헬퍼, batch delete, PEEK prefetch)는 M3 이후 별도 티켓으로 분리한다.

### M3 단계의 검증 도구 (참고)

M3에서 다중 페이지 최적화가 실제로 구현될 때 회귀 검증에 사용할 도구를 미리 명시한다. 본 도구는 M2 deliverable이 아니다 -- AC-4 의 일부로만 추적된다.

- **결정론적 AB-BA 단위 테스트(AC-4 의 단독 pass gate)**: ordered fix 회귀를 결정론적으로 잡는 테스트. 정확한 fixture 위치(`unit_tests/oos/`), interpose 대상 fix 사이트, sleep 주입 메커니즘, deadlock 검출 방법(`er_errid() == ER_LK_UNILATERALLY_ABORTED` + 스택의 `oos_*` 프레임)은 AC-4(1)에 명시한다. 본 절은 절차 개요만 제공한다.
  1. 두 스레드 T1, T2를 생성한다.
  2. T1이 페이지 A를 잡은 직후 hook에서 대기하도록 fix 사이트에 테스트 전용 hook 함수 포인터를 둔다.
  3. T2가 동시에 페이지 B를 취득 후 페이지 A를 시도하도록 `std::condition_variable` 로 staging한다.
  4. Optimization 1(형태 B)/3 구현이 manual VPID 정렬 ordered fix를 사용하면 두 트랜잭션이 동일한 (volid, pageid) 오름차순으로 fix하므로 hold-and-wait 사이클이 형성되지 않아 deadlock이 발생하지 않는다.
  5. ordered fix 적용을 의도적으로 제거한 변형 테스트는 동일 시나리오에서 deadlock을 재현해야 한다(negative test).

- **보조 stress test**: 신호 보강용. AC-4 의 pass/fail 판정에는 사용하지 않는 supplementary signal. 파라미터는 AC-4 에 명시.

---

## Acceptance Criteria

M2에서 ship하는 코드(AC-1)와 M3 구현 시 요구되는 AC(AC-2 -- AC-4)를 명확히 구분한다.

**[M2 -- 코드 ship 대상]**

- [ ] **AC-1**: `oos_insert`, `oos_read`, `oos_delete` 공개 진입점에, debug 빌드에서 thread가 OOS 페이지 0장 보유를 assert하는 코드가 추가된다. 구현 절차: (1) `page_buffer.c` 에 `pgbuf_count_thrd_held_pages_of_type(THREAD_ENTRY *, PAGE_TYPE)` helper를 정의하고 `page_buffer.h` 에 선언을 추가한다. 함수는 `pgbuf_Pool.thrd_holder_info[thread_p->index].thrd_hold_list` 를 walk하며 `pgbuf_get_page_ptype` 결과가 인자 type과 일치하는 entry를 카운트한다, (2) OOS public entry 3곳(`oos_insert`, `oos_read`, `oos_delete`)에서만 `assert(pgbuf_count_thrd_held_pages_of_type(thread_p, PAGE_OOS) == 0)` 를 호출한다, (3) `oos_find_best_page`, `oos_insert_within_page`, `oos_insert_across_pages`, `oos_read_within_page`, `oos_read_across_pages`, `oos_delete_chain`, `oos_file_alloc_new`, `oos_get_length`, `oos_stats_*` 등 어떤 내부 함수에서도 본 assertion을 호출하지 않는다 -- public API 진입점 3곳에서만 호출한다(Invariant A 재기술의 conditional + 헤더 공존 창 때문), (4) `bestspace_mutex` 가 `pgbuf_fix` 를 감싸지 않음을 보장하는 셸 grep 정적 검사를 CI에 추가한다. 검증 방법: debug 빌드에서 해당 함수 진입 시 OOS 페이지 1장을 의도적으로 보유하면 assert 실패 + grep 검사가 위반 사례를 detect함.

cross-layer 호출 순서 명문화(heap-OOS)는 본 이슈 M2 범위에서 제외된다. 실제 vacuum-OOS call-site 코드가 작성되는 CBRD-26592 에서 해당 경로에 직접 명문화한다.

**[M3 이후 -- 다중 페이지 최적화 구현 시 요구]**

- [ ] **AC-2**: `oos_delete_chain` batch 화 시, single-page-hold로 VPID 수집 pass -> 정렬 -> ordered fix 순서가 코드로 구현된다. 검증 방법: 두 vacuum 스레드가 역순 체인을 동시에 처리하는 결정론적 단위 테스트에서 OOS-page 관련 deadlock abort 0건. 본 AC는 caller-wiring 검증 티켓 완료 이후에만 안전하게 구현 가능하다(아래 비고 참조).
  - **비고 -- caller-wiring 검증 티켓**: 본 이슈 close 이전에 placeholder JIRA 티켓을 발행하여 M2 Epic CBRD-26583 의 Remarks 표에 본 이슈 closure와 함께 링크한다. 티켓 owner는 vacuum 구현 담당이며, CBRD-26592 시작 시점에 owner가 검증 작업을 수행한다. 본 이슈 close 시 placeholder 티켓의 키가 Remarks 표에 반영되어야 하며, 발행 자체는 본 이슈 작성자가 처리한다(AC-5 의 산출물에 포함).
- [ ] **AC-3**: `oos_read` PEEK prefetch 구현 시, 다음 청크 fix는 `PGBUF_CONDITIONAL_LATCH` 만 사용하고 실패 시 직렬 fallback한다. 검증 방법: (1) **코드 리뷰 gate** -- M3 PR에서 prefetch helper(예시 명: `oos_read_prefetch_next` 또는 M3 구현자가 채택한 단일 진입 함수)의 본문 전체에 `PGBUF_UNCONDITIONAL_LATCH` 인자가 등장하지 않음을 reviewer가 확인. PR description에 helper 함수명을 명시하고, reviewer는 해당 함수 본문에 한정해 검사한다(전체 `oos_file.cpp` 를 scan하는 grep은 기존 unconditional 사이트 -- `:1354`, `:1496-1497`, `:1562-1563`, `:1601-1602`, `:1725`, `:1912` -- 와 충돌하므로 사용하지 않는다), (2) **런타임 검사** -- prefetch path를 실행하는 단위 테스트에서 conditional latch 실패를 의도적으로 강제(예: 다른 스레드가 해당 페이지를 잡은 상태로 만든 뒤 prefetch 호출)했을 때 fallback 분기가 실행되어 직렬 walk로 진행됨을 코드 path 추적(line coverage 또는 trace log)으로 확인.
- [ ] **AC-4**: 다중 OOS 페이지 동시 fix를 포함하는 모든 신규 경로(Optimization 1 형태 B, Optimization 3)에 대해, 결정론적 단위 테스트가 단독 pass gate로 동작한다.
  1. **결정론적 AB-BA 단위 테스트(단독 pass gate)**: 아래의 fixture/주입 메커니즘을 명시한다.
     - **테스트 fixture 위치**: `unit_tests/oos/` 하위(기존 `test_oos_delete.cpp`, `test_oos_bestspace.cpp` 와 같은 위치). 신규 파일명 예시는 `test_oos_ordered_fix.cpp`. M3 PR에서 정확한 파일명을 확정한다.
     - **interpose 대상 fix 호출**: M3 batch-delete pass-2의 첫 번째 unconditional `pgbuf_fix`(`oos_delete_chain` batch 변형의 정렬된 VPID 루프 첫 청크)와 form B insert packing의 첫 번째 unconditional `pgbuf_fix`(`oos_insert` 다중 청크 packing 경로의 정렬된 VPID 루프 첫 청크). 각 경로의 fix 사이트에 테스트 전용 hook 함수 포인터 1개를 두어 fix 직후 호출되도록 한다(release build에서는 NULL, debug build에서만 비-NULL 가능).
     - **sleep 주입 메커니즘**: 테스트 hook 콜백에서 `std::condition_variable` 으로 양 스레드의 진행을 staging한다 -- T1이 첫 페이지 fix 후 hook에서 대기 -> T2가 첫 페이지 fix 후 신호 -> T1 재개 후 두 번째 페이지 fix 시도 -> ordered fix가 적용된 빌드에서는 T1, T2의 두 번째 페이지가 동일하므로 두 번째 fix는 직렬화되어 deadlock 사이클이 형성되지 않음을 검증.
     - **K=10 회 독립 실행** 모두 deadlock 0건이어야 한다(ordered fix 적용 코드).
     - **negative test**: 동일 hook 메커니즘 위에서 ordered fix를 의도적으로 제거한 변형(테스트 전용 컴파일 플래그)이 동일 fixture에서 deadlock을 재현해야 한다. K=10 회 중 1회 이상 재현하면 negative test pass.
     - **deadlock 검출 방법**: 테스트 thread의 abort 시점에 `er_errid()` 가 `ER_LK_UNILATERALLY_ABORTED`(`error_code.h:133`, value `-72`) 인 경우를 deadlock abort로 판정한다. CUBRID에는 deadlock 전용 perf counter가 없으므로(`PSTAT_LK_*` 카테고리에 deadlock 카운터 부재 -- `perf_monitor.h:315-323`), `er_errid()` + 호출 스택의 `oos_*` 프레임을 OOS-page 관련 분류 기준으로 사용한다.
  2. **보조 stress test(supplementary signal only)**: deadlock 재현 확률 보강용으로 실행하나 pass/fail 판정에는 사용하지 않는다(pass gate는 1번 단독). 파라미터:
     - **N** = 8 concurrent inserter threads (multi-chunk records, 3 chunks each).
     - **M** = 4 concurrent reader threads (`oos_read` on existing chains).
     - **vacuum** = 1 thread.
     - **페이지 크기** = 환경 설정 default(CUBRID `--with-pagesize=` 빌드 옵션 결과; 일반적으로 16K).
     - **레코드 크기** = 3 x (`max_chunk_size - sizeof(OOS_RECORD_HEADER)`) -- 3-chunk 체인 강제.
     - **runtime** = 60초 또는 10,000 operation 완료 중 빠른 쪽.
     - **목적**: ordered fix 적용 빌드에서 deadlock abort(`er_errid() == ER_LK_UNILATERALLY_ABORTED` + 스택에 `oos_*` 프레임)가 관측되지 않는지 손쉽게 점검하는 신호. 본 envelope이 ordered fix 미적용 시 OOS-page 관련 abort를 ≥1건 산출한다는 정량적 보장은 없으므로(컨트롤 빌드의 abort 발생률은 bestspace 캐시 정책 + scheduler 타이밍 의존), 1번의 negative test만이 ordered fix 회귀 검출 보장을 제공한다.

**[트래킹]**

- [ ] **AC-5**: 본 이슈 close 시점에 다음 두 산출물이 발행된다 -- (1) M2 Epic CBRD-26583 의 Remarks 표에 본 이슈 closure를 반영하는 PR 또는 commit, (2) AC-2 가 의존하는 caller-wiring 검증 placeholder JIRA 티켓의 키가 (1)에 함께 인용됨. 두 산출물 모두 본 이슈 close 직전에 작성자가 발행한다.

---

## Definition of done

- [ ] AC-1(M2 ship 범위) 구현 및 디버그 빌드 통과
- [ ] AC-5(트래킹) -- 본 이슈 close 시점에 (a) 상위 Epic CBRD-26583 의 Remarks 표 업데이트 PR/commit 발행, (b) caller-wiring placeholder JIRA 티켓 발행 및 Remarks 표에 키 인용
- [ ] QA 통과(디버그 빌드 진입 assertion 회귀 없음)
- [ ] AC-2, AC-3, AC-4(M3 이후)의 placeholder 티켓 정책: AC-2 placeholder는 본 이슈 close 직전에 발행한다(AC-5 (b)). AC-3, AC-4 는 별도 placeholder 티켓을 본 이슈 close 시점에 발행하지 않으며, 각 M3 최적화 구현 티켓(Optimization 1 형태 B, Optimization 2 PEEK prefetch, Optimization 3 batch delete)이 등록될 때 해당 티켓의 본문에 AC-3 또는 AC-4 검증 의무를 인라인으로 포함한다. 즉 AC-3/AC-4 자체는 추가 placeholder 없이 M3 구현 티켓 안에서 추적된다.

---

## Remarks

### M2 시점에 분석을 작성하는 이유

본 분석은 "지금 구현하라"가 아닌 다음 이유로 M2 시점에 작성된다.

1. **진입 assertion(AC-1)은 지금 추가해야 한다**. 단순하고 비용이 낮으며, 향후 잘못된 최적화가 들어올 때 즉시 포착된다. 구현 후에 assertion을 추가하면 그 사이 슬며시 도입된 버그를 놓친다.
2. **현재의 데드락-free 근거를 명문화해 두면**, M3 최적화 PR 리뷰 시 reviewer가 "이 변경이 어떤 invariant를 깨는지"를 구체적인 라인 번호와 함께 짚을 수 있다. 분석 없이 PR이 들어오면 같은 audit을 매번 반복해야 한다.

M2에서 이 이슈가 ship하는 코드는 AC-1(디버그 assertion + helper + bestspace_mutex 정적 검사) 하나뿐이다.

다중 페이지 최적화 자체(ordered fix 헬퍼, batch delete, PEEK prefetch)는 M2에서 구현하지 않으며 AC에도 포함하지 않았다.

### 우선순위

| 단계 | 시점 | 근거 |
|---|---|---|
| 즉시(M2) | 디버그 assertion 추가(AC-1) | 회귀 방지 비용이 낮고 향후 최적화 PR 리뷰의 회귀 방어선 |
| CBRD-26592 내부 | cross-layer 호출 순서 명문화(heap-OOS 메모) | 실제 vacuum-OOS call-site가 작성될 때 해당 경로에 직접 적용; 현재 코드에는 호출 경로 없음 |
| M3 | OOS API 다중 페이지 최적화 본 구현 | Invariant 1-3 선결, caller-wiring 검증 placeholder 티켓 완료 후 |

### 관련 이슈

| 이슈 | 관련도 |
|---|---|
| CBRD-26583(M2 Epic) | 상위 이슈, 본 분석의 트리거 |
| CBRD-26592(Vacuum 연동) | cross-layer 순서 검토 필요 |
| CBRD-26609(`oos_delete` 구현) | 현재 single-page-hold 패턴의 기준 구현 |
| CBRD-26658(3-Tier Bestspace) | conditional latch 정책의 적용 사례 |

---

## 참고 코드

`oos_file.cpp` 의 OOS 페이지 fix 사이트별 라인 번호와 latch 정책은 위 AS-IS audit 표에 일괄 정리되어 있다. 본 섹션은 재방문이 잦은 함수의 entry point만 열거하여 길찾기에 사용한다.

- `src/storage/oos_file.cpp:453` -- `oos_stats_find_page_in_bestspace`
- `src/storage/oos_file.cpp:633` -- `oos_stats_sync_bestspace`
- `src/storage/oos_file.cpp:852` -- `oos_stats_update`
- `src/storage/oos_file.cpp:1072` -- `oos_insert` (public)
- `src/storage/oos_file.cpp:1124` -- `oos_insert_across_pages` (private)
- `src/storage/oos_file.cpp:1216` -- `oos_insert_within_page` (private)
- `src/storage/oos_file.cpp:1279` -- `oos_read_across_pages` (private)
- `src/storage/oos_file.cpp:1347` -- `oos_read_within_page` (private)
- `src/storage/oos_file.cpp:1406` -- `oos_read` (public)
- `src/storage/oos_file.cpp:1453` -- `oos_file_alloc_new`
- `src/storage/oos_file.cpp:1481` -- `oos_find_best_page`
- `src/storage/oos_file.cpp:1717` -- `oos_delete_chain` (private; X_LOCK 가정 TODO `:1701-1702`)
- `src/storage/oos_file.cpp:1816` -- `oos_delete` (public; sysop 미사용 근거 헤더 주석 `:1793-1813`)
- `src/storage/oos_file.cpp:1907` -- `oos_get_length`
- `src/storage/oos_file.cpp:1005` -- `oos_remove_page` (vacuum 진입 지점 표시 TODO)
- `src/storage/page_buffer_util.hpp:39` -- `auto_unfix_page_ptr` 정의
- `src/storage/page_buffer.h:395` / `src/storage/page_buffer.c:5081` -- `pgbuf_get_page_ptype` 선언/정의 (AC-1 helper에 사용)
- `src/storage/page_buffer.c:783` -- `PGBUF_BUFFER_POOL.thrd_holder_info` 멤버 선언 (anchor 배열 포인터)
- `src/storage/page_buffer.c:484` -- `PGBUF_HOLDER_ANCHOR.thrd_hold_list` 필드 (per-thread holder 리스트의 head)
- `src/storage/page_buffer.c:5712-5742` -- anchor 배열 할당 및 초기화 (AC-1 helper에서 walk 진입점)
- CUBRID 기존 ordered fix 사용처: `src/storage/heap_file.c` 의 `pgbuf_ordered_fix` 호출부 20곳.

---

## Related Issues

- **parent**: [CBRD-26583](http://jira.cubrid.org/browse/CBRD-26583)
- **CBRD-26592**: Vacuum 연동 (cross-layer 호출 순서 명문화 위치)
- **CBRD-26609**: `oos_delete` 구현 (현재 single-page-hold 패턴의 기준 구현)
- **CBRD-26658**: 3-Tier Bestspace (conditional latch 정책의 적용 사례)
