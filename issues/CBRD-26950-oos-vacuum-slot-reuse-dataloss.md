# [OOS] vacuum 이 재사용된 OOS 슬롯의 살아있는 데이터를 삭제하는 문제

## Issue Triage

**이슈 수행 목적**: vacuum 이 죽은 행의 OOS 청크를 회수할 때, 그 사이 다른 살아있는 행이 재사용한 슬롯의 데이터를 잘못 삭제하지 않도록 막는다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `OOS` (Out-of-row Storage - heap 의 큰 가변 컬럼을 별도 페이지로 분리해 저장하는 방식) 청크를 회수하는 vacuum forward-walk (undo 로그를 앞으로 훑는 회수 단계) 는 죽은 행의 `undo image` (행이 죽기 전 모습을 찍어둔 로그 스냅샷) 에서 옛 OOS OID 를 읽고, `oos_chunk_exists()` (`oos_file.cpp:1779`) 로 "그 슬롯에 무언가 있는가" 만 확인한 뒤 `oos_delete` 한다. 그런데 청크 헤더 `oos_record_header` (`oos_file.hpp:26`) 에는 `total_data_length` / `chunk_index` / `next_chunk_oid` 세 필드뿐이라 owner OID 나 generation 같은 식별자가 없다. 즉 "아직 그 죽은 행의 청크" 인지 "다른 살아있는 행이 재사용한 청크" 인지 구분할 수단이 없다. 동시에 (1) vacuum 은 block 단위로 처리하면서 block 을 끝까지 못 끝내면 진행 위치 `start_lsa` 를 전진시키지 않아 작업자 중단 / 중간 에러 / 크래시 복구 시 같은 block 을 처음부터 다시 처리하고, (2) OOS 페이지는 `ANCHORED` 라 삭제된 slotid 가 그대로 재할당될 수 있어 다른 행의 `oos_insert` 가 동일한 `(volid, pageid, slotid)` 를 재사용할 수 있다.
- **영향**: 고객 데이터 손실(silent data loss). 회수 1차에서 비운 슬롯을 살아있는 행이 재사용한 뒤 같은 block 이 재처리되면, vacuum 이 그 살아있는 행의 OOS 데이터를 삭제한다. 멀티청크 체인일 경우 체인 머리부터 `next_chunk_oid` 를 따라가며 살아있는 행의 청크 전체가 삭제되어 피해가 확대된다. 에러도 경고도 없이 데이터만 사라진다.

**이슈 수행 방안** (제안 - 세부는 합의 필요):

- OOS 청크 헤더 `oos_record_header` 에 owner OID 또는 generation 식별자를 추가하고, `oos_delete` 직전에 기대 식별자와 비교하여 불일치(= 슬롯이 재사용됨) 시 회수를 건너뛴다. 비-MVCC eager 삭제 경로는 삭제하는 연산 안에서 동기적으로 회수해 재사용 창 자체가 없지만, 회수를 나중으로 미루는 vacuum 경로에는 그 보장이 없으므로 헤더 식별자로 대신 메운다.
- 식별자를 owner OID 로 둘지 generation 카운터로 둘지, 헤더 포맷 변경에 따른 마이그레이션 / 호환 처리, 슬롯 재사용 자체를 지연시키는 대안과의 비교: `TBD - ANALYSIS 단계에서 결정`.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드와 PR #6986 리뷰 맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현 / 리뷰 단계에서 참고하면 된다.

### Summary

- **문제 / 목적**: deferred vacuum 회수가 재사용된 OOS 슬롯의 살아있는 데이터를 삭제할 수 있다.
- **원인 / 배경**: OOS 청크 헤더에 식별자(owner / generation) 가 없어 회수 직전 probe `oos_chunk_exists` 가 "내 청크 맞는가" 를 판별하지 못한다.
- **제안 / 변경**: 청크 헤더에 식별자를 추가하고 회수 전 식별자 일치를 확인(불일치 시 no-op).
- **영향 범위**: `src/storage/oos_file.cpp` / `.hpp` (헤더 포맷, probe, delete), `src/query/vacuum_oos.cpp` (forward-walk 회수). 헤더 포맷 변경이므로 온디스크 호환성 검토 필요. PR #6986 (CBRD-26668) 리뷰 중 발견.

---

## Description

이 문제는 PR #6986 ("[CBRD-26668] Wire vacuum to clean up OOS records after DELETE/UPDATE") 리뷰 중 발견했다. CUBRID 는 `MVCC` 특성상 DELETE / UPDATE 직후 옛 버전을 즉시 지우지 않고, 나중에 vacuum 이 "이제 아무도 안 보는 죽은 버전" 을 회수한다. 이때 죽은 행이 가리키던 OOS 청크도 함께 회수해야 하는데, 그 회수가 다음 세 조건이 겹칠 때 살아있는 데이터를 삭제한다.

1. **block 재처리**: vacuum 은 회수를 block 단위로 수행하고, 한 forward-walk 회수 호출의 청크 삭제들을 하나의 sysop (system operation - 크래시 복구 단위의 all-or-nothing 작업) 으로 확정한다(`vacuum_oos.cpp:171`). 그러나 block 을 끝까지 못 끝내면 진행 위치 `start_lsa` 를 전진시키지 않아(`vacuum.c:3754` 의 TODO 가 이 점을 지적한다), 작업자 중단 / 중간 에러 / 크래시 복구 재가동 시 같은 block 을 처음부터 다시 처리한다. 이미 확정된 삭제는 되돌아오지 않고, 불변(immutable) 한 `undo image` 는 여전히 옛 OOS OID 를 가리킨다. forward-walk 코드 주석 자체도 "block 이 재시도되면 앞선 삭제가 이미 커밋됐을 수 있다" 고 적어 둔다(`vacuum_oos.cpp:174`).
2. **슬롯 재사용**: OOS 페이지는 `ANCHORED` (`oos_file.cpp:1630`) 라 삭제된 slotid 가 그대로 재할당될 수 있고, 비워진 페이지는 free-space 풀(bestspace) 로 돌아간다(`oos_file.cpp:1753`). 그래서 전혀 다른 살아있는 행의 `oos_insert` 가 동일 `(volid, pageid, slotid)` 를 배정받을 수 있다.
3. **식별자 없는 probe**: 삭제 전 확인 함수 `oos_chunk_exists` (`oos_file.cpp:1779`) 는 슬롯에 레코드가 있으면 무조건 `*out_exists = true` 를 돌려준다. 헤더에 owner / generation 이 없어 "그 죽은 행의 청크" 와 "재사용된 남의 청크" 를 구분하지 못한다.

### 사고 시퀀스

```
[1차 회수]  vacuum forward-walk
  undo image -> 옛 OOS OID = V|P|S
  oos_chunk_exists(V|P|S) -> true
  oos_delete(V|P|S)                         정상: 죽은 행의 청크 회수

[그 사이]  다른 살아있는 행의 INSERT
  oos_insert -> 비어 있던 V|P|S 재사용       이제 V|P|S 는 살아있는 행의 데이터

[2차 회수]  같은 block 재처리 (중단 / 크래시 복구 후)
  undo image -> 여전히 옛 OOS OID = V|P|S
  oos_chunk_exists(V|P|S) -> true            <-- 살아있는 데이터인데 구분 불가
  oos_delete(V|P|S)                          데이터 손실: 살아있는 행의 청크 삭제
```

### 멀티청크 체인 확대

값이 한 청크에 안 들어가면 `next_chunk_oid` 로 이어진 체인으로 저장된다. `oos_delete` 는 `oos_delete_chain` 으로 머리 청크부터 `next_chunk_oid` 를 따라가며 연쇄 삭제하는데(`oos_file.cpp:1758` 의 chain follow), probe 는 머리 청크만 본다. 머리 슬롯이 살아있는 멀티청크 행으로 재사용됐다면 vacuum 이 그 행의 체인 전체를 따라가며 삭제한다. 원인은 동일(식별자 부재) 하나 피해 범위가 한 청크에서 체인 전체로 커진다.

### eager 경로가 안전한 이유 (동기 삭제)

비-MVCC eager 삭제 경로 `heap_oos_delete_unreferenced` (`heap_oos.cpp:425`) 는 행을 지우는 그 연산 안에서 곧바로 OOS 를 회수한다. 그 순간 대상 OID 들은 아직 이 행의 청크가 확실하므로 (OOS OID 는 행마다 새로 할당되어 다른 행과 공유되지 않는다, `heap_oos.cpp:400` 주석) 재사용이 끼어들 창이 없다. 이 경로의 old-vs-new OID 비교(`heap_oos.cpp:477`) 는 UPDATE 전후 이미지에서 "갱신 후에도 여전히 참조되는 OOS" 를 보존하려는 것이지, 슬롯 재사용을 막는 장치가 아니다.

반면 MVCC vacuum 경로는 회수를 임의의 나중 시점으로 미루고, 슬롯이 이미 비워진(그리고 재사용된) 뒤에 불변 `undo image` 로부터 삭제를 다시 만들어낸다. 유일한 가드 `oos_chunk_exists` 는 "존재하는가" 만 보고 "내 것인가" 는 못 본다. eager 경로가 동기 실행으로 거저 얻는 식별 보장을, deferred 경로는 헤더 식별자 없이는 얻지 못한다.

## Test Build

`feat/oos` 브랜치, PR #6986 (head `oos-vacuum`), `origin/feat/oos` 머지 후 HEAD `2c329a4e0` 기준. 미출시 feature 코드로, 빌드 실행이 아니라 코드 리뷰로 발견했다.

## Repro

레이스 조건이라 단일 SQL 로 결정적 재현은 어렵다. 아래는 손실이 성립하는 논리 시퀀스이며, 결정적 재현에는 vacuum 도중 fault injection (worker 중단 또는 서버 크래시) 이 필요하다.

1. OOS 대상이 되는 큰 가변 컬럼을 가진 테이블에 행 R1 을 INSERT 한다. R1 의 값은 OOS 청크 `V|P|S` 에 저장된다.
2. R1 을 DELETE (또는 UPDATE) 한다. 옛 버전은 MVCC 로 남고, vacuum 회수 대상이 된다.
3. vacuum 이 해당 block 을 처리하여 `oos_delete(V|P|S)` 로 R1 의 청크를 회수한다(1차, 정상). 이 시점에 block 의 `start_lsa` 는 전진하지 않은 상태다.
4. vacuum worker 를 중단시키거나 서버를 크래시 후 복구시켜, 같은 block 이 재처리 대상으로 다시 적재되게 한다.
5. 중단 / 복구 전후로 다른 살아있는 행 R2 를 INSERT 하여 비워진 슬롯 `V|P|S` 가 R2 의 청크로 재사용되게 한다.
6. vacuum 이 같은 block 을 재처리하면 옛 `undo image` 의 `V|P|S` 를 다시 보고 `oos_chunk_exists(V|P|S) == true` 로 판단해 `oos_delete(V|P|S)` 를 수행한다.

## Expected Result

vacuum 은 재사용된 슬롯을 회수하지 않는다. 회수 직전 식별자 비교에서 불일치를 감지해 no-op 으로 건너뛰고, 살아있는 행 R2 의 OOS 데이터는 보존된다.

## Actual Result

재처리된 vacuum 이 `V|P|S` 를 삭제하여 살아있는 행 R2 의 OOS 청크(멀티청크면 체인 전체) 가 사라진다. 에러도 경고 로그도 없이 데이터만 손실된다.

## Additional Information

- 관련 PR: https://github.com/CUBRID/cubrid/pull/6986 (CBRD-26668)
- 코드 리뷰 출처: 2026-06-15 PR #6986 리뷰 finding #1 (단일 청크) 및 finding #2 (멀티청크 체인 확대).
- 등급 판단: 데이터 손실 구멍은 확실히 존재하나 발현에는 타이밍 창이 필요하다. 1차 회수와 2차 재처리 사이에 슬롯 재사용이 끼어야 하기 때문이다. 크래시 복구는 block 재처리를 강제하므로 이 창을 크게 벌린다. 즉 정상 무중단 운영보다 장애 / 복구 상황에서 발현 가능성이 높다.
- 참고: 같은 근본 원인(식별자 부재) 이 finding #1 과 #2 를 모두 만든다. 헤더 식별자 도입은 두 경우를 한 번에 막는다.
