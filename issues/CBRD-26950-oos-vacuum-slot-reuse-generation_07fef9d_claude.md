# [OOS] vacuum 이 재사용된 OOS 슬롯의 살아있는 데이터를 삭제한다

## Issue Triage

**이슈 수행 목적** (필수): OOS 청크에 신원 스탬프를 부여해, vacuum 이 지연 회수 시점에 그 슬롯을 물려받은 다른 행의 살아있는 데이터를 지우지 않게 한다.

**이슈 수행 이유** (필수):

**AS-IS (현재 동작 / 배경)**: OOS 청크에는 신원 정보가 없다 - 청크 헤더 `oos_record_header` (`oos_file.hpp:26`) 에 owner OID 나 generation 같은 필드가 없어서, 회수 직전 확인이 "슬롯이 차 있나"까지만 가고 "그게 내가 지울 그 청크인가"에는 닿지 못한다. OOS OID 는 논리 식별자가 아니라 물리 주소 `(volid, pageid, slotid)` 라, 슬롯이 재할당되는 순간 같은 OID 가 남의 청크를 가리킨다. 스톡 debug 빌드에서 소스 수정도 fault injection 도 없이 3회 실행 3회 모두 발현했다.

**TO-BE (목표 상태 / 기대 동작)**: 삭제 직전에 기대 신원과 청크에 저장된 신원을 등가 비교하고, 불일치하면 슬롯이 재사용된 것이므로 삭제를 건너뛴다 (no-op).

**영향**: 고객 데이터 손실 (silent). 잘못 지우는 시점에는 에러도 경고 로그도 없고, 한참 뒤 그 행의 값을 읽을 때에야 internal error 로 드러난다. 크래시가 전제조건도 아니다 — 정상 `cubrid server stop` 후 재시작만으로 발현한다.

**이슈 수행 방안**: **4B generation** 을 신원 스탬프로 채택한다. 청크를 INSERT 할 때 페이지 단위 카운터에서 generation 을 발급해 청크 헤더와 heap inline stub 양쪽에 같은 값을 기록하고, `oos_delete` 진입 전에 둘을 등가 비교해 불일치하면 삭제하지 않는다. 카운터는 각 OOS 데이터 페이지의 slot 0 에 신설하는 페이지 헤더 레코드에 둔다. 복제는 slave 가 자체 `oos_insert` 를 수행하는 기존 방식에 맞춰 generation 도 slave 에서 로컬 발급한다.

같은 자리에 MVCCID 를 넣는 변형 4종과 owner OID 도 검토했으나 앞의 3종은 정확성 요건 위반으로, 나머지 2종은 비용과 불변식 반경 열세로 탈락했다. 판정 근거와 온디스크 레이아웃·바이트 수치는 `## Implementation` 에 있다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**:

| 영역 | 내용 |
|------|------|
| 온디스크 포맷 | 3곳 변경 — OOS 데이터 페이지(헤더 레코드 신설), 청크 헤더(+4B), heap inline stub(+4B) |
| 마이그레이션 | 대상 없음 — `feat/oos` 는 미출시라 기존 OOS 파일 형식과의 호환 처리가 필요 없다 |
| 소스 | `src/storage/oos_file.cpp`·`oos_file.hpp` (페이지 초기화·헤더 포맷·probe·delete), `src/query/vacuum_oos.cpp` (forward-walk 회수), `src/base/object_representation.h` (`OR_OOS_INLINE_SIZE`) |
| 파생 | `OR_OOS_INLINE_SIZE` 를 참조하는 demotion 수익성 판정, `unit_tests/oos/` 의 16B 하드코딩 테스트, OOS-CONTEXT 명세가 함께 움직인다 (항목별 목록은 Implementation) |
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

### 스탬프 발급과 대조

```
[발급] oos_insert (W-latch 보유 상태)
  페이지 slot 0 헤더 레코드의 uint32 카운터 += 1
   └ 발급값 g 를 청크 헤더에 기록
   └ 같은 g 를 heap 의 OOS inline stub 에도 기록

[대조] vacuum forward-walk -> oos_delete 진입 전
  undo image 의 stub 에서 기대값 g_expected 획득
  현재 청크 헤더에서 g_stored 획득
   ★ g_expected != g_stored  -> 슬롯 재사용 -> no-op (누수 아님, 정당한 소유자가 살아 있음)
     g_expected == g_stored  -> 정당한 대상 -> oos_delete
```

발급은 쓰기 경로에 새 페이지 접근을 만들지 않는다. 청크를 넣는 시점에 그 페이지의 W-latch 를 이미 잡고 있으므로 카운터 증가가 같은 latch 구간 안에서 끝나고, owner OID 방식이 요구하는 backfill 이나 OID 할당 순서 변경도 없다.

기대값이 undo image 안 stub 에 실려 있다는 점이 핵심이다. undo image 는 recdes 를 통째로 보존하고 stub 은 variable area 에 있으므로, vacuum 이 오래된 레코드의 MVCC 헤더에서 insert MVCCID 를 정리하는 정상 작업(`vacuum.c:2282-2290`)의 영향을 받지 않는다. 즉 재시도 시점에도 비교할 기대값이 항상 손에 있다.

### 온디스크 변경

| 대상 | AS-IS | TO-BE |
|------|-------|-------|
| OOS 데이터 페이지 | 청크 레코드만 있는 slotted page | slot 0 에 페이지 헤더 레코드 신설, `uint32` generation 카운터 보관 |
| 청크 헤더 `oos_record_header` | 16B (`total_data_length` 4B + `chunk_index` 4B + `next_chunk_oid` 8B) | 20B (+ generation 4B) |
| OOS inline stub | 16B (head OOS OID 8B + full length 8B) | 20B (+ 기대 generation 4B) |
| 삭제 조건 | 슬롯 점유 여부 (`oos_chunk_exists`) | generation 등가 비교, 불일치면 no-op |

- `uint32` 폭이면 충분하다. 잘못 일치하려면 블록 재처리 구간 안에 같은 페이지에서 2^32 회의 INSERT/DELETE 가 일어나야 한다.
- stub 은 24B 가 아니라 20B 로 둔다. stub 은 행마다·OOS 컬럼마다 반복 지불하는 비용인데, variable area 의 시작 오프셋이 일정하지 않아 24B 로 늘려도 8바이트 정렬이 보장되지 않는다 - 정렬 처리는 어차피 reader 책임이라 4B 를 더 낼 이유가 없다. 향후 확장 공간이 필요하면 행마다 반복되는 stub 이 아니라 체인당 한 번만 저장되는 청크 헤더 쪽에 두는 편이 낫다.
- slot 0 을 페이지 헤더 레코드가 점유하게 되므로, 페이지 초기화·빈 공간 회계·slot 0 이 청크라고 가정하는 지점을 함께 손봐야 한다.

### 왜 generation 인가 - 대안 비교

신원 스탬프가 만족해야 하는 요건: **R1** 기대값이 재시도 시점에 항상 가용할 것, **R2** 다른 신원과는 반드시 불일치할 것(오탐 = 데이터 손실), **R3** 같은 신원과는 반드시 일치할 것(누수 = CBRD-26668 회수 목적 붕괴), **R4** 비용(stub 은 행·컬럼마다 반복 지불), **R5** 정확성 논증이 의존하는 코드 반경.

| 안 | 비교 형태 | 판정 근거 | 판정 |
|----|-----------|-----------|------|
| 6a. 청크에 생성 MVCCID, undo image 의 MVCC 헤더와 비교 | 등가 | R1 위반 - vacuum 의 insid 정리(`vacuum_heap_record_insid_and_prev_version`, `vacuum.c:2232`)가 기대값 자체를 지운다. 오래 산 행일수록 방어가 사라지는 비결정적 보호 | 제외 |
| A. 청크 MVCCID 를 재시도 시점의 현재 oldest visible 과 비교 | 부등호 | R2 위반 - 재시작 후에는 pre-crash 트랜잭션이 전부 닫혀 임계값이 이전 모든 MVCCID 보다 커진다. 검사가 "항상 삭제"로 퇴화해 대표 트리거에서 보호 0 | 제외 |
| B. 청크 MVCCID 를 블록에 동결된 oldest_visible 과 비교 | 부등호 | R3 위반 - MVCCID 는 첫 write 시점에 발급되므로 MVCCID 순서와 커밋 순서가 다르다. 장기 실행 writer 하나가 사는 동안 채워진 모든 블록이 skip 되어 시스템적 영구 누수 | 제외 |
| 6b. 청크와 stub 양쪽에 생성 MVCCID, 등가 비교 | 등가 | 성립한다. 다만 8B 라 stub 24B·청크 헤더 24B (R4 열세), 오탐 불가 논증이 vacuum 디스패치 게이팅·MVCCID 단조증가·롤백 보상 의미론·eager 경로 가드를 횡단하는 전역 불변식에 의존한다 (R5 열세) | 차선 |
| 7. 청크 헤더에 owner OID | 등가 | `heap_attrinfo_insert_to_oos` 는 recdes 변환 단계(`heap_file.c:13128`)에서 실행돼 heap 슬롯 할당보다 앞서므로, INSERT 로 만든 첫 체인에는 쓸 owner OID 가 아직 없다. backfill 을 넣으면 쓰기 경로에 페이지 고정과 WAL 이 추가된다 | 차선 |
| **4B generation (페이지 카운터 발급)** | 등가 | R1-R3 을 동일하게 충족하면서 최소 비용(stub 20B), 정확성 불변식이 "슬롯 재할당마다 그 페이지 카운터가 증가한다" 하나로 국소화되어 발급 지점과 대조 지점 두 곳만 보면 검증이 끝난다 | **채택** |

임계값 계열(A/B)은 어떤 조합으로도 재구성하지 않는다. 재사용자는 항상 블록보다 뒤이므로 블록 유도 임계값으로 걸러낼 수 있지만, 정당한 삭제 대상의 생성자 MVCCID 는 블록의 어떤 값과도 순서 관계가 없다. 두 모집단이 MVCCID 축에서 분리되지 않으므로 "손실 없음"과 "누수 없음"을 동시에 만족하는 임계값이 존재하지 않는다.

### 복제·복구·파생 변경

| 영역 | 내용 |
|------|------|
| 복제 | slave 는 master 의 OOS OID 를 받아쓰지 않고 자체 `oos_insert` 를 수행한다. generation 도 같은 원칙으로 slave 에서 로컬 발급하며, 이 규칙을 명시적으로 문서화한다 |
| 복구 | 핸들러 변경 없음. `RVOOS_INSERT`/`RVOOS_DELETE` 가 레코드 전체 이미지를 물리 로깅하므로 이미지 길이만 4B 늘어난다 |
| 상수 | `OR_OOS_INLINE_SIZE` (`object_representation.h:459`) 를 16 에서 20 으로. `heap_file.c` 의 demotion 수익성 판정은 상수를 참조하므로 코드 변경 없이 경계가 `> 20B` 로 이동한다 |
| 단위 테스트 | `unit_tests/oos/test_oos.cpp`·`test_oos_server.cpp` 의 `ASSERT_EQ (OR_OOS_INLINE_SIZE, 16)` 및 stub 직렬화 버퍼, `unit_tests/oos/sql/test_oos_sql_boundary.cpp` 의 16B 기준 경계값 |
| 명세 | OOS-CONTEXT 의 inline stub 크기·수익성 기준·청크 헤더 레이아웃 |

## Acceptance Criteria

- [ ] OOS 데이터 페이지 slot 0 에 페이지 헤더 레코드가 생기고, 청크 INSERT 마다 `uint32` generation 카운터가 증가한다
- [ ] `oos_insert` 가 발급한 generation 이 청크 헤더와 heap inline stub 양쪽에 동일하게 기록된다
- [ ] `oos_delete` 는 기대 generation 과 청크 저장 generation 이 일치할 때만 삭제하고, 불일치면 에러 없이 no-op 으로 넘어간다
- [ ] 첨부 `cbrd-26950-poc.sh` 가 기본값과 `ROWS=40000` 양쪽에서 exit 1 (재삭제 0건, 판독 불가 0건) 로 종료한다
- [ ] 정당한 회수 대상은 계속 삭제된다 - 수정 전후로 UPDATE 후 옛 체인의 회수량이 동등함을 확인해 CBRD-26668 의 누수 방지 목적이 유지됨을 보인다
- [ ] slave 가 generation 을 로컬 발급하고, master/slave 간 OOS 값 판독이 일치한다
- [ ] `OR_OOS_INLINE_SIZE` 변경에 따른 단위 테스트와 경계 테스트가 20B 기준으로 갱신되어 통과한다
- [ ] OOS-CONTEXT 명세의 stub 크기·수익성 기준·청크 헤더 레이아웃이 갱신된다

## Additional Information

- 발견 경위: PR [#6986](https://github.com/CUBRID/cubrid/pull/6986) (`[CBRD-26668] Wire vacuum to clean up OOS records after DELETE/UPDATE`) 코드 리뷰. finding #1 이 단일 청크, #2 가 멀티청크 체인 확대였고, 이후 재현 스크립트로 실증했다.
- 인용 기준: `feat/oos` + `origin/develop` 머지 HEAD `07fef9d48`. 본문의 파일·라인은 모두 이 리비전 기준이다.
- 첨부: 재현 스크립트 `cbrd-26950-poc.sh`, 실행 가이드와 3회 결과 리포트, generation 필드 제안 리포트, 신원 스탬프 비교 분석서(MVCCID 계열 대안의 반례 시나리오와 검증 체인 전문), 4바이트 비용 수용 검토 보고서.

## Remarks

- 수정 PR: [#7695](https://github.com/CUBRID/cubrid/pull/7695) (`feat/oos` 대상 draft). 첨부 재현 스크립트가 수정 후 미발현(재삭제 0건, 판독 불가 0건)이며 정당한 회수도 유지됨을 확인했다.
- 같은 "삭제 전 신원 대조" 계약을 재사용하는 후속 작업: **CBRD-26786** (OOS 빈 페이지 회수 - 재시도 가능한 삭제 호출자를 추가한다), **CBRD-26847 FU-01** (flashback 이 vacuum 회수 완료된 옛 체인을 `oos_read` 할 수 있는 문제 - 잘못된 참조를 차단할 장치가 필요하다).
- 상위 이슈: CBRD-26583.
