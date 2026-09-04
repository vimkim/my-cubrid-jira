# [OOS] vacuum 이 재사용된 OOS 슬롯의 살아있는 데이터를 삭제한다

> **Update 2026-09-04 — 수정 설계를 generation counter 에서 page LSA identity stamp 로 변경했다.** PR [#7695](https://github.com/CUBRID/cubrid/pull/7695) 리뷰에서 hgryoo 님이 "새 카운터 대신 이미 모든 페이지에 있는 page LSA 를 쓰면 관리 장치가 통째로 사라진다"고 제안했고, 검증 결과 옳았다. PR 은 `feat/oos` 최신 (CBRD-26786 빈 페이지 회수 포함) 위에 새 head `c09d6c6d9` 로 재구현되어 다시 열려 있다. 아래 Issue Triage 의 방안과 Implementation 절은 새 설계 기준으로 갱신했고, 문제 서술·재현·측정 결과는 그대로다. 설계 비교: [page LSA vs generation](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-26950/2026-08-20-CBRD-26950-page-lsa-vs-generation_ecebe62_claude.md), 구현 상세: [PR 상세 문서](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-26950/CBRD-26950-oos-identity-stamp-page-lsa_c09d6c6_claude.md).

## Issue Triage

**이슈 수행 목적** (필수): OOS 청크에 신원 스탬프를 부여해, vacuum 이 지연 회수 시점에 그 슬롯을 물려받은 다른 행의 살아있는 데이터를 지우지 않게 한다.

**이슈 수행 이유** (필수):

**AS-IS (현재 동작 / 배경)**: OOS 청크에는 신원 정보가 없다 - 청크 헤더 `oos_record_header` (`oos_file.hpp:26`) 에 owner OID 나 generation 같은 필드가 없어서, 회수 직전 확인이 "슬롯이 차 있나"까지만 가고 "그게 내가 지울 그 청크인가"에는 닿지 못한다. OOS OID 는 논리 식별자가 아니라 물리 주소 `(volid, pageid, slotid)` 라, 슬롯이 재할당되는 순간 같은 OID 가 남의 청크를 가리킨다. 스톡 debug 빌드에서 소스 수정도 fault injection 도 없이 3회 실행 3회 모두 발현했다.

**TO-BE (목표 상태 / 기대 동작)**: 삭제 직전에 기대 신원과 청크에 저장된 신원을 등가 비교하고, 불일치하면 슬롯이 재사용된 것이므로 삭제를 건너뛴다 (no-op).

**영향**: 고객 데이터 손실 (silent). 잘못 지우는 시점에는 에러도 경고 로그도 없고, 한참 뒤 그 행의 값을 읽을 때에야 internal error 로 드러난다. 크래시가 전제조건도 아니다 — 정상 `cubrid server stop` 후 재시작만으로 발현한다.

**이슈 수행 방안**: **page LSA 를 identity stamp (신원 스탬프) 로 채택한다** (2026-09-04 변경, 이전 안은 4B generation counter). 청크를 INSERT 할 때 write latch 아래에서 청크 헤더를 만들기 직전에 읽은 그 페이지의 page LSA 를 청크 헤더와 heap 의 OOS inline stub 양쪽에 기록하고, `oos_delete` 가 삭제 직전에 stub 의 스탬프와 head 청크의 스탬프를 등가 비교해 같을 때만 지운다. head 부재·스탬프 불일치·페이지 해제는 에러 없는 no-op 이다. 읽기 경로 (`oos_read`) 도 같은 스탬프를 검증해 남의 체인 바이트를 돌려주는 대신 `ER_HEAP_OOS_CORRUPTED_RECORD` 를 낸다. 복제는 slave 가 자체 `oos_insert` 를 수행하는 기존 방식에 맞춰 스탬프도 slave 가 발급한 값으로 stub 을 고쳐 쓴다.

page LSA 는 이미 모든 페이지에 있고, 페이지별로 단조 증가하며 정상 운영에서 역행하지 않고, 로깅된 청크 이미지 안에 들어 있어 redo 가 그대로 복원한다. 그래서 counter 안이 필요로 했던 slot 0 헤더 레코드, 새 복구 인덱스, redo 의 단조 재생, wrap-around 은퇴, 페이지 재할당 시 리셋 규칙이 전부 사라진다. 특히 마지막 항목이 결정적이다: CBRD-26786 이 페이지 해제·재할당을 실제로 만들면서 counter 리셋은 같은 결함을 페이지 단위로 재발시켰을 것이다. 비용은 스탬프가 4B 대신 8B 라는 것 하나다 (stub 16B → 24B, 8B 정렬 유지). MVCCID 변형 4종과 owner OID 는 이전과 같은 이유로 탈락이며, 판정표는 Implementation 절에 있다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**:

| 영역 | 내용 |
|------|------|
| 온디스크 포맷 | 2곳 변경 — 청크 헤더 16B → 24B (`LOG_LSA identity_stamp`), heap OOS inline stub 16B → 24B (bigint 하나로 packing 한 스탬프). 데이터 페이지 자체의 레이아웃은 그대로 (slot 0 헤더 레코드 없음) |
| 마이그레이션 | 대상 없음 — `feat/oos` 는 미출시라 기존 OOS 파일 형식과의 호환 처리가 필요 없다 |
| 소스 | `src/storage/oos_file.cpp`·`oos_file.hpp` (발급·읽기 검증·삭제 계약·accessor), `src/storage/heap_file.c`·`heap_oos.cpp` (stub 작성·파싱·추출, eager 경로), `src/query/vacuum_oos.cpp`·`vacuum.c` (forward walk·REMOVE, emptied 목록), `src/transaction/locator_sr.c`·`src/thread/thread_entry.hpp` (복제 publication·fixup), `src/base/object_representation.h` (`OR_OOS_INLINE_SIZE`) |
| 파생 | `OR_OOS_INLINE_SIZE` 를 참조하는 demotion 수익성 경계가 16B → 24B 로 이동 (FORCE_OUTLINE 경계 테스트 22/23자), `unit_tests/oos/` 의 16B 하드코딩 테스트, OOS-CONTEXT 명세 (갱신 필요). CBRD-26786 의 회수 후보 목록을 "실제로 비워진 페이지만, 한 번씩" 으로 정제하고 touched → emptied 로 개명한 변경을 같은 PR 에 의도적으로 포함 (온디스크 포맷을 이미 바꾸는 PR 이라 함께) |
| 후속 계약 | OOS 빈 페이지 회수(CBRD-26786)와 flashback retention(CBRD-26847 FU-01)이 같은 "삭제 전 신원 대조" 계약을 재사용한다 |

---

## Description

용어: **OOS**(Out-of-row Storage) = heap 의 큰 가변 컬럼을 별도 파일의 페이지로 빼서 저장하는 방식. **vacuum** = MVCC 에서 DELETE/UPDATE 직후 바로 지우지 않고, 나중에 아무도 보지 않는 죽은 버전을 모아 회수하는 단계. **undo image** = 행이 바뀌기 전 모습을 로그에 찍어둔 스냅샷 (불변). **forward-walk** = vacuum 이 로그 블록의 undo image 를 훑어 UPDATE 이전 버전의 OOS 체인을 찾아 회수하는 경로.

### 왜 생기나 - 세 가지가 겹칠 때

| # | 조건 | 코드 |
|---|------|------|
| 1 | **점유 여부만 보는 확인** - `oos_chunk_exists()` 는 페이지를 fix 하고 `spage_get_record` 가 `S_SUCCESS` 를 주면 `true` 를 돌려준다. `false` 는 슬롯이 비었을 때뿐이라, "점유자가 그대로"와 "점유자가 바뀜"이 같은 답으로 뭉개진다 | `oos_file.cpp:2236` |
| 2 | **슬롯 재사용** - OOS 페이지는 `ANCHORED` 로 초기화돼 해제된 slotid 가 그대로 재할당되고, 삭제 시 그 페이지가 곧바로 bestspace 후보로 재등록된다. 다른 살아있는 행의 `oos_insert` 가 같은 `(volid, pageid, slotid)` 를 다시 받는다 | `oos_file.cpp:2087`(ANCHORED), `330`(bestspace) |
| 3 | **같은 block 재처리** - vacuum 은 로그 블록 단위로 처리하고 undo image 하나 분량의 청크 삭제를 sysop 으로 그때그때 확정하는데, 블록을 완주하지 못하면 진행 위치 `start_lsa` 를 전진시키지 않는다. 그래서 정상 종료·worker 중단·크래시 복구 뒤 같은 블록을 처음부터 다시 훑는다. 이미 확정된 삭제는 돌아오지 않고, 불변인 undo image 는 여전히 옛 OID 를 가리킨다 | `vacuum_oos.cpp:171`(sysop), `vacuum.c:3764-3766`(TODO) |

### 사고 시퀀스

```
[1차 회수]  vacuum forward-walk
  undo image -> 옛 OOS OID = V|P|S
  oos_chunk_exists(V|P|S) -> true
  oos_delete(V|P|S)                     정상: 죽은 행의 청크 회수
                                        (이 시점 start_lsa 는 아직 전진 안 함)

[그 사이]  다른 살아있는 행 R2 의 INSERT
  oos_insert -> 비어 있던 V|P|S 재사용    이제 V|P|S 는 R2 의 데이터

[2차 회수]  같은 block 재처리 (정상 종료 후 재시작 / worker 중단 / 크래시 복구)
  undo image -> 여전히 옛 OOS OID = V|P|S
  ★ oos_chunk_exists(V|P|S) -> true      살아있는 R2 데이터인데 구분할 근거가 없다
  oos_delete(V|P|S)                      데이터 손실: R2 의 청크 삭제
```

값이 한 청크에 안 들어가면 `next_chunk_oid` 로 이어진 체인이 되는데, probe 는 머리 청크만 보는 반면 `oos_delete` 는 체인을 끝까지 따라가며 지운다 (`oos_delete_chain`, `oos_file.cpp:2153`). 머리 슬롯이 재사용된 것이라면 R2 의 **체인 전체** 가 사라지므로 피해가 커진다.

### 왜 다른 경로는 같은 문제를 안 겪나

**eager(비-MVCC) 삭제**. `heap_oos_delete_unreferenced` (`heap_oos.cpp:702`) 는 행을 지우는 그 연산 안에서 동기적으로 OOS 를 회수한다. 그 순간 대상 OID 는 아직 이 행의 청크가 확실하고 (OOS OID 는 행마다 새로 할당되어 공유되지 않는다), 재사용이 끼어들 창 자체가 없다. 신원 필드 없이도 안전한 이유가 이것이고, 회수를 임의의 나중으로 미루는 vacuum 은 같은 보장을 공짜로 얻지 못한다. (eager 경로의 old-vs-new OID 비교 `heap_oos.cpp:758` 는 UPDATE 전후 보존용이지 슬롯 재사용 방지 장치가 아니다.)

**heap 슬롯 재사용**. heap 이 재처리에 안전한 것은 삭제 판단을 로그가 아니라 **현재 점유자의 헤더에서 다시 유도** 하기 때문이다 (`mvcc_satisfies_vacuum`, `mvcc.c:321`). heap 헤더의 delid 는 죽음 정보라 "delid < 임계값이면 쓰레기"가 점유자 내재적 기준이 되고, 재사용된 슬롯이든 아니든 결론이 항상 옳다. OOS 청크에는 이 방식이 이식되지 않는다. 청크가 쓰레기인지는 청크 자신의 속성이 아니라 **소유 heap 버전이 죽었다는 외재적 사실** 이고, 그 버전은 페이지에서 이미 사라져 undo image 에만 남아 있다. 죽음 정보를 청크에 쓰려면 DELETE/UPDATE 가 OOS 페이지를 만져야 해서 지연 정리 설계와 정면으로 충돌한다. 그래서 남는 길은 판단의 재유도가 아니라 신원 확인이다.

## Test Build

- `feat/oos` + `origin/develop` 머지 HEAD `07fef9d48`, `debug_gcc` 프리셋, Linux x86_64 (el9).
- debug 빌드가 필요한 것은 관측 채널인 `$CUBRID/log/oos.log` 가 `!NDEBUG` 전용(`oos_log.hpp`)이기 때문이며, 발현 자체는 debug 코드와 무관하다.

## Repro

첨부 스크립트 `cbrd-26950-poc.sh` 를 CUBRID 소스 수정 없이 그대로 실행한다. fault injection 훅도 디버거도 쓰지 않고, 서버 제어는 정상 `cubrid server stop` 하나뿐이다.

```bash
# $CUBRID / $CUBRID_DATABASES 가 debug 빌드를 가리키고 csql 이 PATH 에 있어야 한다
export CUBRID=/path/to/debug-build
export CUBRID_DATABASES=$CUBRID/databases

./cbrd-26950-poc.sh
```

- 전용 DB `oos26950` 과 전용 `cubrid.conf` 를 스크립트가 직접 만들어 `CUBRID_CONF_FILE` 로 주입하므로 설치본의 다른 DB 에 영향이 없다. 포트 21950, 디스크 약 1GB, 기본값 약 3분.
- 조절값은 전부 환경변수다: `ROWS=20000` (vacuum backlog 규모), `R3_WRITERS=6` (재사용용 INSERT 세션 수), `STOP_AT_PCT=30` (회수 진행률 30% 에서 정지), `BLOCK_PAGES=128`, `PAYLOAD_UNITS=4996` (5,000B 페이로드 - OOS 트리거 문턱 약 4KB 를 넘겨 전부 OOS 로 빠진다). 부하를 키우려면 `ROWS=40000` 으로 실행한다.
- 스크립트가 세 조건을 각각 강제한다: 회수와 **동시에** 같은 크기 페이로드를 INSERT 하는 세션 6개로 조건 2 를, 회수 30% 시점의 정상 종료로 backlog 를 남겨 조건 3 을 만든다. 두 조건이 서면 조건 1 은 자동으로 발동한다.
- 사용하는 시스템 파라미터(`vacuum_worker_count=1`, `vacuum_log_block_pages=128`, `vacuum_master_interval_in_msecs=10`, `enable_string_compression=no`)는 전부 정식 파라미터이며, 안전장치를 끄는 종류가 아니라 발현 빈도를 높이는 종류다. 압축을 끄는 것은 payload 가 압축돼 OOS 문턱 밑으로 내려가는 것을 막기 위해서다.
- 판정: 발현하면 exit 0, 미발현이면 exit 1. 수정 후 회귀 판정에 그대로 쓴다.

## Expected Result

2차 pass 에서 슬롯 점유자가 undo image 가 가리키던 그 체인이 아니므로 삭제를 건너뛰고, R3 행은 전부 payload 를 읽을 수 있다. 재삭제된 OOS OID 0건, 판독 불가 행 0건, 스크립트 exit 1.

## Actual Result

3회 실행 결과 (스크립트 exit 0):

| 실행 | 두 pass 모두에서 삭제된 OOS OID | 판독 불가가 된 커밋된 R3 행 | 대조군 (R1 2만 행) |
|------|------|------|------|
| 1 | 293 | 293 | 무손상 |
| 2 | 163 | 163 | 무손상 |
| 3 | 240 | 240 | 무손상 |

피해 행은 존재하는데 (`SELECT id, gen` 은 정상) payload 만 읽지 못한다:

```
SELECT DISK_SIZE(payload) FROM t WHERE id = 20273;
ERROR: Internal error: slot 2 on page 8079 of volume ".../oos26950" is not allocated.
```

서로 독립인 두 지표 - 스토리지 로그의 재삭제 슬롯 수와 SQL 판독 불가 행 수 - 가 3회 모두 정확히 일치했다. 피해 행들은 슬롯이 비워진 뒤 INSERT·커밋됐고 그 뒤 아무도 건드리지 않았으므로, 커밋 후 이 행을 만진 유일한 주체가 2차 vacuum pass 다. 회수 시작 전에 자리 잡은 대조군 2만 행은 3회 모두 무손상이라, 피해가 재사용 슬롯을 물려받은 행에만 국한됨을 보인다. 상세 증거 해석은 첨부 실행 가이드를 참고한다.

## Implementation

구현은 PR [#7695](https://github.com/CUBRID/cubrid/pull/7695) head `c09d6c6d9` (base `feat/oos` `2940b1cfb`) 에 티켓 단위 커밋 6개로 들어 있다. 상세는 [PR 상세 문서](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-26950/CBRD-26950-oos-identity-stamp-page-lsa_c09d6c6_claude.md).

### 스탬프 발급과 대조

```
[발급] oos_insert_record_in_fixed_page (W-latch 보유 상태)
  stamp = pgbuf_get_lsa (page)            ← 청크 헤더 바이트를 만들기 전, 이 청크의 로그 append 전
   └ 청크 헤더 identity_stamp 에 기록 (raw LOG_LSA 8B)
   └ head 청크의 값을 oos_insert 출력으로 보고 → heap 이 OOS inline stub 에 기록 (bigint 하나로 packing)

[대조] oos_delete (ref = {head OID, stub 의 stamp})
  head 페이지를 해제 허용 fix 로 잡고 (W-latch), head 청크 헤더의 stamp 를 읽는다
   ★ 페이지 해제 / head 슬롯 부재 / stamp 불일치  → er_clear, debug 로그, NO_ERROR, 아무것도 안 바꿈, 회수 후보 없음
     stamp 일치                                     → 종전처럼 체인을 걷어 삭제 (뒤 청크는 일반 fix)
```

대조가 head 를 지우는 바로 그 write latch 아래에서 일어나므로 검사와 삭제 사이에 슬롯이 비고 재사용될 틈이 없다. 이 계약 하나로 vacuum 블록 재시도와 같은 체인의 중복 삭제자가 호출자 측 lock 없이 안전해진다. forward walk 의 사전 점유 probe (`oos_chunk_exists`) 는 제거했고, 함수 자체는 테스트·진단용으로 남기되 "점유만 증명하고 신원은 증명하지 않으며 삭제를 gate 하면 안 된다" 는 주석을 달았다. REMOVE 경로와 eager 경로 (`heap_oos_delete_unreferenced`) 도 같은 계약을 쓴다.

발급 지점에 적어 둔 세 불변식:

1. 스탬프는 이 청크의 로그 append **이전** 의 page LSA 다. redo 는 자신이 재생하는 레코드의 LSA 를 알 수 없지만, 스탬프가 로깅된 청크 이미지 안에 있어 redo 와 undo 가 그대로 복원한다.
2. 한 슬롯의 두 점유 세대 사이에는 로깅된 페이지 연산이 최소 하나 있다. 첫 점유자의 insert 로그가 page LSA 를 스탬프 너머로 올리고 page LSA 는 역행하지 않으므로 다음 점유자는 항상 다른 스탬프를 받는다. 지금은 배치 삽입을 포함해 청크 insert·delete 하나가 로그 레코드 하나다. 여러 insert 를 하나의 로그 레코드로 합치는 최적화가 생기면 이 불변식을 지켜야 한다.
3. NULL 은 특별 취급 없는 보통 값이다. NULL page LSA 를 만드는 것은 오프라인 로그 재생성 유틸리티 (`log_recreate`) 뿐이고, 그것은 로그와 함께 대기 중인 회수 요청도 모두 버리므로 stale 참조가 새 LSA 공간으로 넘어올 수 없다.

### 온디스크 변경

| 대상 | AS-IS | TO-BE |
|------|-------|-------|
| 청크 헤더 `oos_record_header` | 16B (`total_data_length` 4B + `chunk_index` 4B + `next_chunk_oid` 8B) | 24B (+ `LOG_LSA identity_stamp` 8B). 페이지당 최대 청크 payload 는 헤더 상수를 따라 8B 감소 |
| OOS inline stub (`OR_OOS_INLINE_SIZE`) | 16B (head OOS OID 8B + full length 8B) | 24B (+ identity stamp 8B, `LOG_LSA` 를 bigint 하나로 packing: pageid 상위 48비트, offset 하위 16비트) |
| OOS 데이터 페이지 | 청크 레코드만 있는 slotted page | **변경 없음** (counter 안의 slot 0 헤더 레코드는 채택하지 않음) |
| 삭제 조건 | 슬롯 점유 여부 (`oos_chunk_exists`) | head 청크 stamp == stub stamp. 불일치·부재·페이지 해제는 no-op |
| 읽기 조건 | `chunk_index`, `total_data_length` 일치 | + stamp 일치. 불일치는 `ER_HEAP_OOS_CORRUPTED_RECORD` (새 에러 코드 없음) |
| 회수 후보 목록 (CBRD-26786) | 청크를 지운 모든 페이지, 중복 허용 ("touched") | 삭제로 레코드 0개가 된 페이지만, 한 번씩 ("emptied") |

- stub 은 24B 로 8B 정렬을 유지한다. 12B 를 쓰는 기존 `or_put_log_lsa` 계열 helper 는 쓰지 않고 `oos_pack_identity_stamp` / `oos_unpack_identity_stamp` 로 bigint 하나에 넣는다. NULL_LSA (-1, -1) 는 -1 로 packing 되어 모든 값이 정확히 라운드트립한다.
- `feat/oos` 는 미출시라 마이그레이션은 없다. 기존 feat/oos 테스트 DB 는 재생성한다.

### 왜 page LSA 인가 - counter 와의 비교

| counter 안이 필요로 한 것 | page LSA 에서는 |
|---|---|
| 모든 데이터 페이지의 slot 0 헤더 레코드 (페이지 용량 12B 차감) | 불필요 |
| 새 복구 인덱스 `RVOOS_NEWPAGE` | 불필요 |
| `oos_rv_redo_insert` 의 단조 증가 (MAX) 재생 | 불필요 — 스탬프가 로깅되는 청크 이미지 안에 있어 redo·undo 가 그대로 복원 |
| wrap-around 은퇴 로직 (이전 head `ecebe6288` 에서 이미 비용 지불) | 불필요 — 64비트 |
| 페이지 재할당 시 카운터 리셋 규칙 | **불필요 — 리셋될 상태가 없음.** CBRD-26786 의 페이지 재할당이 counter 안에서는 같은 결함을 페이지 단위로 재발시켰을 것 (리뷰어 H2SU 재현) |
| 비용 | 스탬프 4B → 8B (stub 20B 안 대신 24B) |

MVCCID 변형 4종과 owner OID 에 대한 판정은 이전 리포트와 같다: MVCCID 는 R1 (재시도 시점 가용성) 또는 R2/R3 (오탐·누수) 를 위반하고, owner OID 는 첫 체인 시점에 값이 없어 backfill 이 필요하다. page LSA 는 counter 와 같은 등가 비교를 하면서 관리 상태만 없앤 것이다.

### 복제·복구·파생 변경

| 영역 | 내용 |
|------|------|
| 복제 | thread 로컬 publication 벡터가 (head OID, identity stamp) 쌍을 싣고, slave 의 `locator_fixup_oos_oids_in_recdes` 가 publish 된 쌍 순서대로 stub 의 OID 와 스탬프를 재기록한다 (중간 8B 길이는 건너뜀, OOS 스토리지는 읽지 않음). 다중 페이지 체인의 경계 마커는 NULL OID + NULL 스탬프. stub 이 레코드 범위를 넘으면 쓰기 전에 `ER_HA_GENERIC_ERROR` |
| 복구 | 핸들러 변경 없음. `RVOOS_INSERT` redo 와 `RVOOS_DELETE` undo 가 레코드 전체 이미지를 복원하므로 스탬프도 함께 복원된다 |
| 상수 | `OR_OOS_INLINE_SIZE` 16 → 24 (`OR_OOS_IDENTITY_STAMP_SIZE` = `OR_BIGINT_SIZE`). demotion 수익성 경계가 `> 24B` 로 이동 |
| 단위 테스트 | 새 파일 `unit_tests/oos/test_oos_identity_stamp.cpp` (발급·accessor·packing·읽기 검증·삭제 계약·슬롯 재사용·페이지 해제/재할당). 기존 `oos_delete` 호출 54곳은 공용 헬퍼 `oos_delete_with_current_identity_stamp` 로 이전. FORCE_OUTLINE 경계 테스트 22/23자, OOS+bigone 테스트는 압축되는 VARCHAR 대신 BIT VARYING 사용 |
| 명세 | OOS-CONTEXT 의 inline stub 크기 (16B → 24B)·수익성 기준·청크 헤더 레이아웃·"locked fix design" 서술 갱신 필요 |

## Acceptance Criteria

- [x] `oos_insert` 가 청크마다 write latch 아래에서 읽은 page LSA 를 identity stamp 로 청크 헤더에 기록하고, head 청크의 값을 heap OOS inline stub 에 동일하게 기록한다
- [x] `oos_delete` 는 stub 의 stamp 와 head 청크의 stamp 가 일치할 때만 삭제하고, 불일치·head 부재·페이지 해제는 에러 스택을 비운 no-op 으로 넘어간다 (forward walk·REMOVE·eager 세 경로 모두)
- [x] `oos_read` 는 stamp 불일치를 `ER_HEAP_OOS_CORRUPTED_RECORD` 로 보고한다
- [x] 첨부 `cbrd-26950-poc.sh` 가 기본값에서 exit 1 (재삭제 0건, 판독 불가 0건) 로 종료한다 — 2026-09-04 확인. `ROWS=40000` 은 미실행
- [x] 정당한 회수 대상은 계속 삭제된다 — PoC 에서 죽은 체인 20,000개 전부 회수 (1차 9,238 + 재주행 10,762), 살아있는 체인 수 = 남은 행 수 (21,958)
- [x] slave 가 자신이 발급한 stamp 로 stub 을 고쳐 쓴다 (단위 테스트; HA 통합 검증은 CI/QA 단계)
- [x] `OR_OOS_INLINE_SIZE` 변경에 따른 단위 테스트와 경계 테스트가 24B 기준으로 갱신되어 통과한다 (debug 빌드 OOS ctest 28/28)
- [ ] CircleCI sql·medium·shell 통과 후 PR draft 해제
- [ ] OOS-CONTEXT 명세의 stub 크기·수익성 기준·청크 헤더 레이아웃·설계 서술이 갱신된다

## Additional Information

- 발견 경위: PR [#6986](https://github.com/CUBRID/cubrid/pull/6986) (`[CBRD-26668] Wire vacuum to clean up OOS records after DELETE/UPDATE`) 코드 리뷰. finding #1 이 단일 청크, #2 가 멀티청크 체인 확대였고, 이후 재현 스크립트로 실증했다.
- 인용 기준: 문제 서술·재현은 `feat/oos` + `origin/develop` 머지 HEAD `07fef9d48`, 수정은 `feat/oos` `2940b1cfb` 위의 PR head `c09d6c6d9`.
- 첨부: 재현 스크립트 `cbrd-26950-poc.sh`, 실행 가이드와 3회 결과 리포트, generation 필드 제안 리포트, 신원 스탬프 비교 분석서, 4바이트 비용 수용 검토 보고서. 설계 변경 근거: [page LSA vs generation](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-26950/2026-08-20-CBRD-26950-page-lsa-vs-generation_ecebe62_claude.md).

## Remarks

- 수정 PR: [#7695](https://github.com/CUBRID/cubrid/pull/7695) (`feat/oos` 대상 draft, head `c09d6c6d9`, 2026-09-04 재개). 이전 head `ecebe6288` 의 generation counter 구현은 리뷰 (hgryoo: page LSA 제안, InChiJun: 이름·`er_clear`, H2SU: 페이지 재할당 리셋·읽기 경로·미발급 값) 를 반영해 page LSA 설계로 전면 재구현했다. 수정 후 재현 스크립트 결과: 두 pass 에서 모두 삭제된 OOS OID 0건, 판독 불가 커밋 행 0건, 살아있는 체인 수 = 남은 행 수 (21,958). 재주행이 되짚은 stale 참조 2,802건 (head 부재 2,350, 슬롯 재사용 452) 전부 no-op — 슬롯 재사용 452건이 이전 코드라면 잃었을 살아있는 값이다.
- 같은 PR 에 CBRD-26786 회수 후보 목록의 정제 (실제로 비워진 페이지만, 한 번씩; touched → emptied) 를 의도적으로 포함했다. 회수 게이트·성장 sweep·해제 경로는 건드리지 않았다.
- 리뷰에서 나온 후속 후보 (이 PR 범위 밖): thread 로컬 publication 벡터 이름 `oos_oids` 가 이제 (OID, stamp) 쌍을 담으므로 개명 검토; stub 을 손으로 읽고 쓰는 6곳 (`heap_file.c` 3곳, `heap_oos.cpp`, `locator_sr.c`, `log_applier.c`) 을 하나의 pack/unpack 헬퍼로 통합 검토; `oos_read` 가 head 바이트를 복사한 뒤 stamp 를 검사하므로 (호출자는 에러 반환 시 버퍼를 버린다) 검사를 복사 앞으로 옮기는 방어 검토.
- 같은 "삭제 전 신원 대조" 계약을 재사용하는 후속 작업: **CBRD-26786** (OOS 빈 페이지 회수 — 이 PR 이 그 위에 올라가며 페이지 재할당 시나리오를 단위 테스트로 재현), **CBRD-26847 FU-01** (flashback 이 vacuum 회수 완료된 옛 체인을 `oos_read` 할 수 있는 문제 — 읽기 경로 stamp 검증이 이 시나리오를 `ER_HEAP_OOS_CORRUPTED_RECORD` 로 드러낸다), **CBRD-27230** (UPDATE 체인 재사용 — publish 쌍의 모양만 의존).
- 상위 이슈: CBRD-26583.
