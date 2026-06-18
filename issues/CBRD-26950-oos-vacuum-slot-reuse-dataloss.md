# [OOS] vacuum 이 재사용된 OOS 슬롯의 살아있는 데이터를 삭제한다

## 한 줄 요약

vacuum 이 죽은 행의 OOS 청크를 회수할 때, **"슬롯에 뭔가 있나?"** 만 확인하고 **"그게 내가 지울 그 청크가 맞나?"** 는 확인하지 못해서, 그 사이 다른 살아있는 행이 재사용한 슬롯의 데이터를 말없이 삭제할 수 있다.

> 비유: 옷보관소 직원(vacuum)이 "5번 고리의 코트를 치워라"는 오래된 표를 들고 왔다. 직원은 *"5번 고리에 코트가 걸려 있나?"* 만 보고 치운다. 그런데 그 사이 5번 고리는 비었다가 **다른 손님** 이 자기 코트를 걸었다. 직원은 남의 코트를 치운다. → 고리에 **주인 이름표** 를 달고 치우기 전에 이름을 대조하면 막힌다.

> 용어: **OOS**(Out-of-row Storage) = heap 의 큰 가변 컬럼을 별도 페이지로 빼서 저장하는 방식. **vacuum** = MVCC 에서 DELETE/UPDATE 직후 바로 안 지우고, 나중에 "이제 아무도 안 보는 죽은 버전"을 모아 회수하는 단계. **undo image** = 행이 죽기 전 모습을 찍어둔 로그 스냅샷 (불변).

---

## 왜 생기나 — 세 가지가 겹칠 때

| # | 조건 | 코드 |
|---|------|------|
| 1 | **식별자 없는 확인** — 청크 헤더 `oos_record_header` 에 `total_data_length / chunk_index / next_chunk_oid` 만 있고 owner OID·generation 같은 신원 필드가 없다. 그래서 회수 직전 확인 함수 `oos_chunk_exists()` 는 슬롯에 레코드만 있으면 무조건 `true` 를 돌려준다 ("내 것인지"는 못 본다). | `oos_file.hpp:26`, `oos_file.cpp:1779` (true 반환 `1805-1808`) |
| 2 | **슬롯 재사용** — OOS 페이지는 `ANCHORED` 라 삭제된 slotid 가 그대로 재할당되고, 빈 페이지는 bestspace 풀로 돌아간다. 그래서 다른 살아있는 행의 `oos_insert` 가 같은 `(volid, pageid, slotid)` 를 다시 받을 수 있다. | `oos_file.cpp:1630`, `1753` |
| 3 | **같은 block 재처리** — vacuum 은 block 단위로 처리하고 청크 삭제를 sysop 으로 확정하는데, block 을 끝까지 못 끝내면 진행 위치 `start_lsa` 를 전진시키지 않는다. 그래서 worker 중단·중간 에러·크래시 복구 시 같은 block 을 **처음부터 다시** 처리한다 (이미 확정된 삭제는 안 돌아오고, 불변 undo image 는 여전히 옛 OID 를 가리킨다). | `vacuum_oos.cpp:171`(sysop), `174`(주석), `vacuum.c:3754`(TODO) |

---

## 사고 시퀀스

```
[1차 회수]  vacuum forward-walk
  undo image -> 옛 OOS OID = V|P|S
  oos_chunk_exists(V|P|S) -> true
  oos_delete(V|P|S)                     정상: 죽은 행의 청크 회수
                                        (이 시점 start_lsa 는 아직 전진 안 함)

[그 사이]  다른 살아있는 행 R2 의 INSERT
  oos_insert -> 비어 있던 V|P|S 재사용    이제 V|P|S 는 R2(살아있는 행)의 데이터

[2차 회수]  같은 block 재처리 (worker 중단 / 크래시 복구 후)
  undo image -> 여전히 옛 OOS OID = V|P|S
  oos_chunk_exists(V|P|S) -> true        <-- 살아있는 R2 데이터인데 구분 불가
  oos_delete(V|P|S)                      데이터 손실: R2 의 청크 삭제
```

**멀티청크면 피해 확대**: 값이 한 청크에 안 들어가면 `next_chunk_oid` 로 이어진 체인이 된다. probe 는 머리 청크만 보지만 `oos_delete` 는 체인을 끝까지 따라가며 지운다 (`oos_file.cpp:1758`). 머리 슬롯이 재사용된 거라면 R2 의 **체인 전체** 가 사라진다.

---

## 왜 eager(비-MVCC) 경로는 안전한가

eager 삭제 `heap_oos_delete_unreferenced` (`heap_oos.cpp:425`) 는 행을 지우는 **그 연산 안에서 동기적으로** OOS 를 회수한다. 그 순간 대상 OID 는 아직 이 행의 청크가 확실하고 (OOS OID 는 행마다 새로 할당되어 공유 안 됨, `heap_oos.cpp:400` 주석), 재사용이 끼어들 창 자체가 없다. → **신원 필드 없이도 안전.**

vacuum 은 회수를 임의의 나중으로 미루므로 그 창이 열린다. eager 가 동기 실행으로 거저 얻는 신원 보장을, 지연되는 vacuum 은 헤더 신원 필드 없이는 못 얻는다. (참고: eager 경로의 old-vs-new OID 비교 `heap_oos.cpp:477` 는 UPDATE 전후 보존용이지 슬롯 재사용 방지 장치가 아니다.)

---

## 영향

- **고객 데이터 손실 (silent)** — 에러도 경고 로그도 없이 살아있는 행의 데이터만 사라진다.
- **장애·복구 상황에서 발현 가능성↑** — 1차 회수와 2차 재처리 사이에 슬롯 재사용이 끼어야 하는데, 크래시 복구는 block 재처리를 강제하므로 이 창을 크게 벌린다. 무중단 정상 운영보다 위험.

---

## 해결 방안 (제안 — 세부는 ANALYSIS 단계에서 합의)

청크 헤더 `oos_record_header` 에 **owner OID 또는 generation 식별자** 를 추가하고, `oos_delete` 직전에 기대 식별자와 대조해 불일치(= 슬롯 재사용됨) 면 회수를 **건너뛴다(no-op)**. 같은 근본 원인(신원 부재)이 단일 청크·멀티청크 두 경우를 모두 만들므로, 헤더 신원 필드 하나로 둘 다 막는다.

TBD: 식별자를 owner OID 로 둘지 generation 카운터로 둘지 / 헤더 포맷 변경에 따른 온디스크 호환·마이그레이션 / 슬롯 재사용 자체를 지연시키는 대안과의 비교.

**영향 범위**: `src/storage/oos_file.cpp` · `.hpp` (헤더 포맷·probe·delete), `src/query/vacuum_oos.cpp` (forward-walk 회수).

---

## 참고

- 발견: PR [#6986](https://github.com/CUBRID/cubrid/pull/6986) ("[CBRD-26668] Wire vacuum to clean up OOS records after DELETE/UPDATE") 리뷰 (finding #1 단일 청크, #2 멀티청크 체인 확대). 미출시 feature 코드, 빌드 실행이 아닌 코드 리뷰로 발견.
- 확인 기준: `origin/feat/oos` 머지 후 HEAD `2c329a4e0`.
- 재현: 레이스라 단일 SQL 결정적 재현 불가 — 위 사고 시퀀스대로 R1 INSERT/DELETE → vacuum 회수 → worker 중단·크래시 복구로 block 재처리 강제 → 그 사이 R2 INSERT 로 슬롯 재사용. 결정적 재현엔 vacuum 도중 fault injection 필요.
