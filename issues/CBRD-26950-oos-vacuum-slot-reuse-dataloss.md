# [OOS] vacuum 이 재사용된 OOS 슬롯의 살아있는 데이터를 삭제한다

## 한 줄 요약

vacuum 이 죽은 행의 OOS 청크를 회수할 때, **"슬롯에 뭔가 있나?"** 만 확인하고 **"그게 내가 지울 그 청크가 맞나?"** 는 확인하지 못해서, 그 사이 다른 살아있는 행이 재사용한 슬롯의 데이터를 말없이 삭제할 수 있다.

> 비유: 옷보관소 직원(vacuum)이 "5번 고리의 코트를 치워라"는 오래된 표를 들고 왔다. 직원은 *"5번 고리에 코트가 걸려 있나?"* 만 보고 치운다. 그런데 그 사이 5번 고리는 비었다가 **다른 손님** 이 자기 코트를 걸었다. 직원은 남의 코트를 치운다. → 고리에 **주인 이름표** 를 달고 치우기 전에 이름을 대조하면 막힌다.

> 용어: **OOS**(Out-of-row Storage) = heap 의 큰 가변 컬럼을 별도 페이지로 빼서 저장하는 방식. **vacuum** = MVCC 에서 DELETE/UPDATE 직후 바로 안 지우고, 나중에 "이제 아무도 안 보는 죽은 버전"을 모아 회수하는 단계. **undo image** = 행이 죽기 전 모습을 찍어둔 로그 스냅샷 (불변).

---

## 왜 생기나 — 세 가지가 겹칠 때

| # | 조건 | 코드 |
|---|------|------|
| 1 | **식별자 없는 확인** — 청크 헤더 `oos_record_header` 에 `total_data_length / chunk_index / next_chunk_oid` 만 있고 owner OID·generation 같은 신원 필드가 없다. 그래서 회수 직전 확인 함수 `oos_chunk_exists()` 는 슬롯에 레코드만 있으면 무조건 `true` 를 돌려준다 ("내 것인지"는 못 본다). | `oos_file.hpp:26`, `oos_file.cpp:2236` (`S_SUCCESS` 면 true) |
| 2 | **슬롯 재사용** — OOS 페이지는 `ANCHORED` 라 삭제된 slotid 가 그대로 재할당되고, 삭제 시 페이지가 즉시 bestspace 캐시에 재등록된다. 그래서 다른 살아있는 행의 `oos_insert` 가 같은 `(volid, pageid, slotid)` 를 다시 받을 수 있다. | `oos_file.cpp:2087`(ANCHORED), `330`(bestspace) |
| 3 | **같은 block 재처리** — vacuum 은 block 단위로 처리하고 undo image 하나 분량의 청크 삭제를 sysop 으로 그때그때 확정하는데, block 을 끝까지 못 끝내면 진행 위치 `start_lsa` 를 전진시키지 않는다. 그래서 **정상 `cubrid server stop`**·worker 중단·크래시 복구 시 같은 block 을 **처음부터 다시** 처리한다 (이미 확정된 삭제는 안 돌아오고, 불변 undo image 는 여전히 옛 OID 를 가리킨다). | `vacuum_oos.cpp:171`(sysop), `vacuum.c:3764-3767`(TODO) |

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

[2차 회수]  같은 block 재처리 (정상 종료·재시작 / worker 중단 / 크래시 복구 후)
  undo image -> 여전히 옛 OOS OID = V|P|S
  oos_chunk_exists(V|P|S) -> true        <-- 살아있는 R2 데이터인데 구분 불가
  oos_delete(V|P|S)                      데이터 손실: R2 의 청크 삭제
```

**멀티청크면 피해 확대**: 값이 한 청크에 안 들어가면 `next_chunk_oid` 로 이어진 체인이 된다. probe 는 머리 청크만 보지만 `oos_delete` 는 체인을 끝까지 따라가며 지운다 (`oos_delete_chain`, `oos_file.cpp:2153`). 머리 슬롯이 재사용된 거라면 R2 의 **체인 전체** 가 사라진다.

---

## 왜 eager(비-MVCC) 경로는 안전한가

eager 삭제 `heap_oos_delete_unreferenced` (`heap_oos.cpp:702`) 는 행을 지우는 **그 연산 안에서 동기적으로** OOS 를 회수한다. 그 순간 대상 OID 는 아직 이 행의 청크가 확실하고 (OOS OID 는 행마다 새로 할당되어 공유 안 됨, `heap_oos.cpp:679` 주석), 재사용이 끼어들 창 자체가 없다. → **신원 필드 없이도 안전.**

vacuum 은 회수를 임의의 나중으로 미루므로 그 창이 열린다. eager 가 동기 실행으로 거저 얻는 신원 보장을, 지연되는 vacuum 은 헤더 신원 필드 없이는 못 얻는다. (참고: eager 경로의 old-vs-new OID 비교 `heap_oos.cpp:758` 는 UPDATE 전후 보존용이지 슬롯 재사용 방지 장치가 아니다.)

---

## 영향

- **고객 데이터 손실 (silent)** — 삭제 시점에는 에러도 경고 로그도 없다. 이후 피해 행을 읽을 때에야 internal error 로 나타나고, 재사용 타이밍에 따라서는 원리상 **오류조차 없이 남의 값이 반환** 될 수도 있다.
- **크래시가 필요 없다** — 1차 회수와 2차 재처리 사이에 슬롯 재사용이 끼어야 하는데, **정상 `cubrid server stop` 후 재시작** 만으로 block 재처리가 일어나 발현됨을 재현으로 확인했다 (아래). 크래시 복구는 같은 창을 더 크게 벌릴 뿐이다.

---

## 재현 — 소스 수정 없이 스크립트 한 번으로 발현

첨부 스크립트 `cbrd-26950-poc.sh` 가 스톡 debug 빌드에서 재현한다 (fault injection 없음, **3회 실행 3회 모두 발현**). 세 조건을 레이스에 맡기지 않고 각각 구조적으로 만든다:

1. `payload BIT VARYING` 5,000 B 짜리 R1 20,000 행 INSERT — 전부 OOS 로 나간다.
2. R1 전체를 **한 트랜잭션으로** UPDATE — 커밋 순간 옛 체인 20,000 개가 한꺼번에 vacuum 대상이 되고, 그 참조는 undo image 에만 남는다. (DELETE 가 아니라 UPDATE 인 이유: DELETE 회수는 heap sysop 안에서 MVCC 헤더로 멱등 확인이 되므로 이 버그가 아니다.)
3. vacuum 이 회수하는 동안 별도 세션 6개가 같은 크기의 R3 행들을 INSERT (위 사고 시퀀스의 R2 역할; 스크립트에서 `gen=3`) — `oos_insert` 가 방금 비워진 슬롯을 bestspace 캐시에서 그대로 받아간다. → 조건 2
4. 회수 30% 시점에 정상 `cubrid server stop` — backlog 가 남은 block 이 IN_PROGRESS 로 남는다. → 조건 3
5. 재시작 — 그 block 이 interrupted 로 재장전되어 처음부터 재실행되고, undo image 에서 다시 꺼낸 옛 OID 를 probe 가 "차 있음"으로 통과시켜 → 조건 1 — R3 의 살아있는 체인을 삭제한다.

**결과 (3회):**

| 실행 | 두 pass 모두에서 삭제된 OOS OID | 판독 불가가 된 커밋된 R3 행 | 대조군 (R1 2만 행) |
|---|---|---|---|
| 1 | 293 | 293 | 무손상 |
| 2 | 163 | 163 | 무손상 |
| 3 | 240 | 240 | 무손상 |

피해 행의 증상 — 행은 존재하는데 (`SELECT id, gen` 정상) payload 만 읽을 수 없다:

```
SELECT DISK_SIZE(payload) FROM t WHERE id = 20273;
ERROR: Internal error: slot 2 on page 8079 of volume ".../oos26950" is not allocated.
```

**증거 해석:**

- **결정적** — 피해 행들은 슬롯이 비워진 뒤 INSERT·커밋됐고 이후 아무도 건드리지 않았다. 커밋 후 이 행을 만진 유일한 주체가 2차 vacuum pass 다. payload 앞 8자에 자기 id 를 각인해 두므로 "오류 없이 남의 값이 반환되는" 오염도 검출된다 (관측치 0).
- **보강** — oos.log (debug 전용) 에 같은 `(vol,page,slot)` 이 재시작 전후로 두 번 "deleted" 기록된다. 청크는 슬롯이 차 있어야만 삭제되므로, 두 삭제 사이에 그 슬롯이 재배부되었다는 스토리지 레벨 물증이다. (엄밀히는 "재삭제된 슬롯 수"다 — 종료 중 sysop 이 abort 된 삭제가 복원 후 정당하게 재삭제돼도 같은 목록에 잡힌다.)
- **대조군** — 회수 시작 전에 자리 잡은 R1 의 UPDATE 후 체인 20,000 행은 3회 모두 무손상. 피해가 "재사용 슬롯을 물려받은 행"에만 국한됨을 보인다.
- 서로 독립인 두 지표(스토리지 로그의 재삭제 슬롯 수 / SQL 판독 불가 행 수)가 3회 모두 정확히 일치했다.

debug 빌드가 필요한 것은 관측 채널(oos.log)이 debug 전용이라서일 뿐, 발현 자체는 debug 코드와 무관하다. 사용 설정은 `vacuum_worker_count=1`, `vacuum_log_block_pages=128`, `vacuum_master_interval_in_msecs=10`, `enable_string_compression=no` (payload 가 압축돼 OOS 문턱 밑으로 내려가는 것 방지) — 전부 정식 시스템 파라미터이며, 안전장치를 끄는 종류가 아니라 발현 빈도를 높이는 종류다.

---

## 해결 방안 (제안 — 세부는 ANALYSIS 단계에서 합의)

청크 헤더 `oos_record_header` 에 **owner OID 또는 generation 식별자** 를 추가하고, `oos_delete` 직전에 기대 식별자와 대조해 불일치(= 슬롯 재사용됨) 면 회수를 **건너뛴다(no-op)**. 같은 근본 원인(신원 부재)이 단일 청크·멀티청크 두 경우를 모두 만들므로, 헤더 신원 필드 하나로 둘 다 막는다.

TBD: 식별자를 owner OID 로 둘지 generation 카운터로 둘지 / 헤더 포맷 변경에 따른 온디스크 호환·마이그레이션 / 슬롯 재사용 자체를 지연시키는 대안과의 비교.

**영향 범위**: `src/storage/oos_file.cpp` · `.hpp` (헤더 포맷·probe·delete), `src/query/vacuum_oos.cpp` (forward-walk 회수).

**수정 검증**: 위 재현 스크립트가 회귀 판정을 제공한다 — 발현 시 exit 0, 미발현 시 exit 1. 수정 후 반복 실행으로 exit 1 (판독 불가 0건, 재삭제 0건) 을 확인하면 된다.

---

## 참고

- 발견: PR [#6986](https://github.com/CUBRID/cubrid/pull/6986) ("[CBRD-26668] Wire vacuum to clean up OOS records after DELETE/UPDATE") 리뷰 (finding #1 단일 청크, #2 멀티청크 체인 확대). 미출시 feature 코드, 처음에는 코드 리뷰로 발견 → 이후 위 스크립트로 실증.
- 확인 기준: `feat/oos` + `origin/develop` 머지 HEAD `07fef9d48` (본문의 파일·라인 인용 기준).
- 재현 스크립트: `cbrd-26950-poc.sh` (첨부) — 소요 수 분, 자체 DB (`oos26950`) 를 만들어 쓰므로 기존 DB 에 영향 없음.
