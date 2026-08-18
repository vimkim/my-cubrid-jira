# [PGBUF] [Survey] pgbuf default / v2 병행 버전 도입 전략을 설계한다

## Issue Triage

**이슈 수행 목적**: 기존 `src/storage/page_buffer.c`(default)를 그대로 둔 채 개선판(v2)을 함께 유지할 수 있는지, 가능하다면 어떤 방식으로 둘 중 하나를 고를지 판정할 근거를 확보한다. 이 이슈는 조사이며 v2 자체의 구현은 후속 이슈로 분리한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | 이 이슈의 본문은 아직 placeholder 한 줄이라 조사 범위가 정의되어 있지 않다. 그리고 부모 EPIC 이 뽑아 둔 개선 후보 중 자료구조나 동기화 방식을 건드리는 것들(SX latch CBRD-27196, direct victim 대기자 선택 CBRD-27211, buffer hash 크기 산정, dirty page 색인)은 단일 파일 `page_buffer.c` 를 제자리에서 고치는 길밖에 없고, 그 파일은 `cub_server` 와 `cubridsa` 두 빌드 타깃에 동시에 들어간다. |
| **TO-BE (목표 상태 / 기대 동작)** | default 와 v2 를 병행하는 구조에 대해 (1) 버전 선택 메커니즘 후보, (2) v2 가 실제로 개선할 대상, (3) 단계적 검증 전략, (4) 이중 유지보수 위험 네 축이 비교표와 함께 정리돼, 도입 여부를 결정할 수 있는 상태가 된다. |
| **영향** | 기술 부채 — 구조 변경 후보를 안전하게 실측할 경로가 없어서, SX latch 처럼 이득이 예상되는 조사조차 "전면 교체냐 포기냐"의 이분법에 걸려 착수 판단을 못 한 상태로 남는다. |

**이슈 수행 방안**: EPIC CBRD-27193 의 C3 행이 요구한 대로 병행 구현의 마일스톤과 테스트 전략, 기존 코드와의 대조 기준을 본문으로 확정한다. 조사 항목은 아래 네 가지로 고정한다. 병행 버전 도입 여부, 선택 메커니즘, v2 의 최초 범위는 전부 `TBD - 합의 미확인` 이다.

------------------------------------------------------------------------

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: 조사 단계라 코드 변경은 없다. 조사가 다루는 표면은 `src/storage/page_buffer.c`(17,535줄), `src/storage/page_buffer.h`(522줄), 빌드 타깃 정의 2곳(`cubrid/CMakeLists.txt:525`, `sa/CMakeLists.txt:530`), 그리고 소문자 `pgbuf_` 식별자를 참조하는 나머지 엔진 파일 46개(참조 2,121건, 서로 다른 심볼 96개)다. 병행 버전을 실제로 도입하면 CMake 타깃 구성, 시스템 파라미터 목록, QA 실행 매트릭스가 함께 영향을 받는다. 아래 라인 번호는 별도 표기가 없으면 develop `e6ed61e87` 의 `page_buffer.c` 기준이다.

------------------------------------------------------------------------

## Description

부모 EPIC 은 CBRD-27193 이고 이 이슈는 그 C3 항목이다. 담당 결함 번호(D/N)는 없다 — 결함 수정이 아니라 개선판을 어떤 그릇에 담을지의 조사다.

`pgbuf` (page buffer manager — 디스크 page 를 메모리 frame 에 캐시하고 fix, latch, 교체, flush 를 관리하는 모듈)는 서버 프로세스 안의 단일 전역 인스턴스 `pgbuf_Pool` 로 동작한다(`:847`). 이 변수는 `static` 이라 파일 밖에서는 손댈 수 없고, 상위 모듈(heap, btree, catalog, recovery, vacuum)은 `pgbuf_fix`(VPID — 볼륨 번호와 page 번호로 page 를 지정하는 식별자 — 로 page 를 잠가 가져오기) / `pgbuf_unfix` / `pgbuf_set_dirty` / `pgbuf_set_lsa` / flush 계열의 자유 함수만 쓴다. 내부에는 BCB(Buffer Control Block — frame 에 올라온 page 의 fix 수, latch(page 단위 읽기/쓰기 잠금), dirty(수정됐지만 아직 디스크에 반영되지 않은 상태)를 보관하는 제어 블록), LRU(Least Recently Used — 최근 사용 시점 기준의 page 교체 목록), victim(재사용 대상으로 뽑힌 frame), WAL(Write-Ahead Logging — data page 보다 log 를 먼저 기록하는 규칙) 강제 지점이 한 파일에 함께 들어 있다.

이 구조에서 개선안을 검증하는 방법은 지금까지 하나뿐이었다. 원본을 직접 고치고 전체 회귀를 돌리는 것이다. 정확성 결함 수정(EPIC A1~A5)은 변경 범위가 좁아 이 방식으로 충분하지만, `pgbuf_fix`/`pgbuf_unfix` 는 초당 수백만 번 불리는 경로라서 latch 표현을 바꾸거나 자료구조를 추가하는 변경에는 되돌리기 어려운 성능 회귀가 섞여 들어갈 수 있다. 그래서 "두 가지 버전의 pgbuf 를 가져간다"는 발상이 나왔고, 그 발상을 실행 가능한 형태로 좁히는 것이 이 조사다.

참고 자료로 쓰는 재구현 계획서는 원래 엔진 통합을 비목표로 두고 학습용 병행 코드를 설계한 문서다. 이 이슈는 그 마일스톤(M0~M8)과 테스트 전략을 엔진 관점의 조사 항목으로 승격시킨 것이며, 학습용 구현을 그대로 제품에 넣자는 뜻이 아니다.

## 주요 검토 항목

### 1. 버전 선택 메커니즘

메커니즘을 고르기 전에 현재 API 형태 셋을 확인해야 한다.

- **자유 함수 + 이중 진입점**. `page_buffer.h` 에는 매크로와 `_debug`/`_release` 변형을 합쳐 108개의 서로 다른 `pgbuf_` 이름이 등장한다. 그중 14개는 `NDEBUG` 여부에 따라 다른 실체 함수로 전개되는 매크로 진입점이다 — `pgbuf_fix` 는 debug 빌드에서 `pgbuf_fix_debug`(`page_buffer.h:277`), release 빌드에서 `pgbuf_fix_release`(`page_buffer.h:327`)가 된다. v2 는 이 이중 진입점을 그대로 갖춰야 한다. 참고로 그 14개 중 `pgbuf_fix_without_validation`(`page_buffer.h:320`)은 release 빌드 전용 매크로인데, 전개 대상인 `pgbuf_fix_without_validation_release` 가 `src/` 어디에도 정의되어 있지 않고 호출자도 없다 — 아무도 부르지 않아서 링크가 깨지지 않은 채로 남은 선언이다. v2 가 따라 만들 대상이 아니라 EPIC B4(죽은 코드 정리)로 넘길 항목이다.
- **풀 상태가 한 덩어리의 파일 정적 변수**. `static PGBUF_BUFFER_POOL pgbuf_Pool`(`:847`) 하나에 해시 테이블, BCB 배열, LRU 목록, 대기 큐가 모두 들어 있다. 두 구현이 같은 프로세스에서 이 심볼을 공유할 수 없으므로, 어떤 방식을 택하든 "한 프로세스에는 한 구현만 살아 있다"가 전제다.
- **빌드 모드는 2개**. `page_buffer.c` 는 `cubrid`(SERVER_MODE — 서버 프로세스)와 `sa`(SA_MODE — 클라이언트와 서버가 한 프로세스에 있는 standalone) 타깃에만 들어가고 `cs/CMakeLists.txt`(클라이언트 라이브러리)에는 없다. 파일 안 `SERVER_MODE` 조건부 컴파일이 146곳이라, v2 는 데몬이 없는 SA_MODE 변형까지 같이 만들어야 한다.

후보 비교 (권장 순서):

| 순위 | 후보 | 방식 | 권장 이유 / 고려사항 |
|---|---|---|---|
| 1 | 빌드 타임 소스 스왑 | CMake 옵션으로 `page_buffer.c` 와 v2 파일 중 하나만 타깃에 넣는다 | 호출측 무변경, 런타임 비용 0, 롤백이 파일 단위로 깔끔하다. 대신 한 바이너리로 두 버전을 비교할 수 없어 QA 가 빌드 2종을 받아야 한다. |
| 2 | 기동 시 확정 분기 | 호출측 이름을 유지한 채 실제 구현으로 넘기는 얇은 계층을 두고, 그 안에서 `pgbuf_v1_*` / `pgbuf_v2_*` 로 분기. 선택값은 `pgbuf_initialize` 에서 1회 읽어 고정 | `src/storage/es.c` 에 같은 형태의 선례가 있다 — `es_initialized_type`(`es.c:47`)을 기동 시 정하고 각 함수가 if/else 로 백엔드를 고른다. 한 바이너리로 비교가 되지만 최고빈도 경로에 분기가 들어가고, 진입점 14개의 debug/release 쌍을 전부 복제해야 한다. |
| 3 | 함수 포인터 테이블 | `pgbuf_initialize` 에서 함수 포인터 표를 채우고 그 계층이 간접 호출 | 버전 추가 확장이 쉽다. 그러나 간접 호출이 인라인을 막고, 매크로 진입점과 겹쳐 스택 추적이 한 겹 깊어진다. fix/unfix 호출 빈도를 감안하면 실측 없이 채택하기 어렵다. |
| 4 | 별도 라이브러리 또는 별도 바이너리 | v2 를 다른 라이브러리로 빼고 패키징 단계에서 고른다 | 격리는 가장 강하다. 대신 CMake, 패키징, 설치 스크립트까지 손대야 하고 현장에서 어느 쪽이 돌고 있는지 확인할 수단을 따로 만들어야 한다. |
| 5 | 엔진 밖 병행 구현 | `unit_tests/` 하위 독립 모듈로만 유지 (재구현 계획서의 원안) | 회귀 표면이 0 이라 불변식 성문화와 학습에는 최적이지만 제품 경로가 열리지 않는다. 1~4 의 대안이 아니라 그 선행 단계로 보는 편이 맞다. |

선택값을 시스템 파라미터로 노출한다면, 값을 이름으로 고르는 파라미터(`PRM_KEYWORD` 타입)의 선례는 `tde_default_algorithm`(`src/base/system_parameter.c:4586`)이다. 기동 시 1회 읽기는 pgbuf 가 이미 하는 방식이라 새로 만들 것이 없다 — `pgbuf_initialize` 가 `prm_get_integer_value (PRM_ID_PB_NBUFFERS)` 로 버퍼 개수를 읽는다(`:1666`). 다만 파라미터로 고르게 하면 "운영 중 변경 불가"를 코드와 매뉴얼 양쪽에 명시해야 한다.

### 2. v2 가 개선할 대상 확정

v2 를 만드는 명분은 "개선을 안전하게 실을 그릇"이다. 그릇만 만들고 실을 것이 없으면 이중 유지보수 비용만 남는다. 부모 EPIC 의 조사 이슈들이 후보 재료다.

| 후보 | 근거 이슈 | v2 로 옮길 때의 성격 |
|---|---|---|
| SX page latch 도입 | CBRD-27196 | latch 상태 표현 자체를 바꾸는 변경. default 의 64-bit atomic latch 를 건드리지 않고 v2 에서 먼저 재는 편이 자연스럽다. v2 의 1순위 후보. |
| direct victim 대기자 선택 규칙 | CBRD-27211 | direct victim(빈 frame 을 못 찾아 잠든 스레드에게 재사용 가능한 BCB 를 직접 넘기는 방식)의 고정값 4 를 다른 규칙으로 바꾸는 실험. 파라미터 하나로도 실험이 되므로 v2 편입 이득이 작은 쪽. |
| buffer hash 크기 산정 | EPIC C6 | `HASH_SIZE_BITS 20`(`:297`)이라 버킷이 pool 크기와 무관하게 1,048,576개로 고정된다. 버킷 하나가 `hash_mutex` + `hash_next` + `lock_next` 구조(`:577-584`)라 작은 pool 에서도 고정 비용이 그대로 붙는다. 자료구조 초기화 단계(M0)에서 바로 다르게 만들 수 있어 v2 와 궁합이 좋다. |
| dirty page 색인과 checkpoint 비용 | EPIC C7 | checkpoint(dirty page 를 일괄 반영해 복구 시작점을 전진시키는 작업)를 수행하는 `pgbuf_flush_checkpoint` 가 BCB 전수를 순회하며 하나씩 mutex 를 잡는다(`:4174`, `:4198-4199`). 색인 도입은 dirty 전이 비용과 맞바꾸는 설계 변경이라 v2 에서 재는 편이 안전하다. |
| 원본 결함을 설계로 차단 | EPIC A1 (D1) | flush 진입 시 `pgbuf_bcb_mark_is_flushing`(`:10741`)이 {FLUSHING 설정, DIRTY 해제} 전이를 하는데, 그 뒤 TDE(Transparent Data Encryption — data page 암호화) 실패(`:10755`)와 DWB(Double Write Buffer — 원래 위치에 쓰기 전 별도 파일에 page 사본을 남기는 torn-write 보호 장치) 슬롯 확보 실패(`:10767`)가 복구 없이 반환한다. v2 는 모든 조기 반환이 복구 지점을 반드시 거치는 구조를 택해 같은 실수가 아예 나올 수 없게 만드는 것을 목표로 삼을 수 있다. |

여기서 판정할 것은 후보별로 default 를 직접 고칠지 v2 로 미룰지다. 판정 기준 후보는 되돌리기 비용, 성능 회귀 판별 가능성, 변경이 자료구조 자체를 바꾸는지 세 가지이며, 기준 확정은 `TBD - 합의 미확인` 이다.

### 3. 단계적 검증 전략

재구현 계획서의 마일스톤을 v2 수용 기준으로 차용한다. 각 단계는 앞 단계까지만으로 빌드와 테스트가 통과해야 하고, 통과 기준은 분석서 총론이 정리한 불변식 16종에서 뽑는다.

| 단계 | 범위 | 통과 기준 후보 |
|---|---|---|
| M0 | BCB/iopage 쌍 배열, 해시 테이블, invalid list(page 가 아직 올라오지 않은 BCB 프리리스트), flags 워드 비트 인코딩 | 구조체 크기와 오프셋을 `static_assert` 로 고정. flags 인코딩 왕복 테스트. zone 비교가 동등 비교임을 강제 — `LRU_3_ZONE` 값이 zone1/zone2 비트합과 같아서 비트 검사를 하면 틀린다 (불변식 6) |
| M1 | 단일 스레드 fix/unfix | 같은 VPID 재fix 가 같은 포인터를 주는지, 미스 시 디스크 read 가 정확히 1회인지 |
| M2 | atomic latch 의 CAS(compare-and-swap) 판정, 대기/기상, 재진입, promote(READ latch 를 WRITE 로 승격) | CAS 판정 9케이스를 각각 단위 테스트로. WRITE 대기자가 있으면 신규 READ 도 블록되는지 (불변식 11) |
| M3 | VPID 단위 I/O 락 | N스레드 동시 미스에서 read 호출 수가 1인지, 기상한 쪽이 소유권을 받지 않고 해시를 재탐색하는지 (불변식 10) |
| M4 | 3-zone LRU(각 LRU 목록을 hot / 완충 / victim 구간으로 나눈 구조)와 victim 선정 | zone 카운트 합이 리스트 크기와 같은지, fix 된 page 와 dirty page 가 victim 후보에서 배제되는지 (불변식 2) |
| M5 | dirty, flush, WAL | page write 전에 로그 flush 가 선행됐는지를 mock 이 assert (불변식 5). write 실패를 주입하면 DIRTY 와 `oldest_unflush_lsa`(디스크에 아직 없는 가장 오래된 변경의 로그 위치)가 완전히 복원되는지 (불변식 4) |
| M6 | flush 데몬과 direct victim | 버퍼 크기가 워킹셋보다 작은 부하에서 모든 스레드가 유한 시간 안에 진행하는지 |
| M7 | 세션별 private LRU, quota(private 목록 크기 상한), AOUT(목록에서 밀려난 page 식별자의 최근 이력 큐) | 풀스캔 세션과 핫셋 세션을 섞었을 때 핫셋 히트율이 유지되는지 |
| M8 | ordered fix(page 를 두 장 이상 잡을 때 정해진 전역 순서를 강제해 데드락을 막는 방식), dealloc, checkpoint | 데드락 타임라인을 ordered fix 없이 재현하고 ordered fix 로 해소되는지. `fix_count == watch_count` (불변식 14) |

검증 하네스는 두 갈래가 있고, 어느 쪽을 쓸지가 조사 대상이다.

| 방식 | 내용 | 고려사항 |
|---|---|---|
| 자립 하네스 | 표준 라이브러리만 쓰고 디스크와 로그를 mock 인터페이스로 주입 (계획서 원안의 `storage_iface`/`wal_iface`) | 실패 주입, 지연 주입, 호출 순서 검증(write 전 로그 flush 선행)이 쉽다. 대신 검증한 코드가 엔진에 그대로 들어가지 않으면 증거 가치가 떨어진다. |
| 엔진 링크 하네스 | `unit_tests/double_write_buffer` 선례처럼 `SA_MODE` 를 정의하고 `cubridsa` 를 링크해 Catch2 로 검사 | 실제로 제품에 들어갈 코드를 검증한다. 대신 실패 주입 지점을 엔진 안에 만들어야 한다. |

경계를 명시적 인터페이스로 뽑는 계획에는 현실 장벽이 있다. pgbuf 는 log manager 를 함수 호출로만 쓰지 않는다 — `pgbuf_set_lsa` 는 `log_Gl.chkpt_redo_lsa` 를 직접 읽고 `log_Gl.chkpt_lsa_lock` 을 직접 잡는다(`:4999-5007`). 스레드 관리 쪽으로는 `THREAD_ENTRY` 안에 pgbuf 가 소유한 통계 필드가 있다. 어느 경계를 어느 순서로 명시화할지 자체가 조사 항목이며, 경계 정리를 v2 의 선행 조건으로 둘지 v2 안에서 함께 할지도 정해야 한다.

### 4. 이중 유지보수 위험

| 위험 | 내용 | 완화 후보 |
|---|---|---|
| 이중 유지보수 | 결함 수정을 두 구현에 모두 반영해야 한다. EPIC A1~A5 같은 정확성 수정이 v2 에 누락되면 v2 는 이미 고친 버그를 다시 갖고 태어난다 | 정확성 수정은 default 에만 하고, v2 는 그 결함이 구조적으로 불가능한 설계를 택한다. 결함별 대응 상태를 표로 관리 |
| 회귀 표면 | 분기 계층이나 함수 포인터 표를 넣는 순간, v2 를 쓰지 않는 default 경로의 코드도 함께 바뀐다 | 1순위 후보(빌드 타임 스왑)에는 이 위험이 없다는 점이 그 후보의 최대 강점 |
| QA 매트릭스 배가 | SQL/medium/shell 회귀를 버전마다 돌리면 실행 시간이 두 배가 된다 | v2 는 기본 비활성으로 두고 지정 잡에서만 실행. 기본값 승격 시점에 전량 실행 |
| 성능 비교의 신뢰도 | 두 구현의 성능 차이를 같은 조건에서 재려면 계측 지점의 의미가 같아야 한다. 지금은 DWB 경유 write 가 집계되지 않는 등 통계 자체에 왜곡이 있다 | 통계 의미 정리(EPIC B1)를 v2 성능 비교보다 앞 순서에 둘지 검토 |
| 리뷰 부담 | 원본과 같은 규모의 대안 구현은 한 번에 리뷰할 수 없다 | 마일스톤 단위 PR 로 쪼개고, 각 PR 이 자기 단계의 불변식 테스트를 함께 낸다 |
| 사장 위험 | v2 가 기본값이 되지 못한 채 남으면 죽은 코드가 된다. pgbuf 안에는 이미 실행되지 않는 경로가 여럿 있다 (EPIC A3, B2) | 승격 기한과 미달 시 제거 조건을 조사 결론에 함께 적는다 |

## Specification Changes

조사 단계라 사용자가 관측하는 동작 변경은 없다. 선택 메커니즘이 시스템 파라미터로 결정되면 파라미터 이름, 기본값, 운영 중 변경 불가 여부를 매뉴얼에 반영해야 하며, 그 작업은 도입 결정 이후 별도 이슈로 분리한다.

## Implementation

조사 진행 순서와 산출물:

1. 검토 항목 1의 후보 5종을 표 기준으로 평가하고, 1순위 후보에 대해서만 실제 빌드 가능성을 확인한다 — `page_buffer.c` 를 그대로 복사한 파일을 CMake 옵션으로 바꿔 넣어 `cubrid` 와 `sa` 두 타깃이 빌드되는지 보는 수준으로 충분하다.
2. 검토 항목 2의 후보별로 default 직접 수정과 v2 편입 중 어느 쪽인지 판정표를 채우고, 판정에 쓴 기준을 함께 적는다.
3. 검토 항목 3의 하네스 두 갈래 중 하나를 고르고, M0 의 통과 기준 한 개를 실제 테스트로 작성해 그 방식이 성립하는지 확인한다.
4. 위 결과와 검토 항목 4의 위험표를 합쳐 도입 여부 권고안을 낸다. 권고가 도입이면 마일스톤별 후속 이슈 목록을, 미도입이면 그 근거와 대안(default 직접 수정 순서)을 남긴다.

## Acceptance Criteria

- [ ] 버전 선택 메커니즘 후보가 비교표로 정리되고, 후보별 호출측 변경량, 런타임 비용, QA 영향이 명시된다.

- [ ] v2 가 개선할 대상이 후보별로 default 직접 수정 또는 v2 편입으로 판정되고, 판정 기준이 함께 적힌다.

- [ ] 마일스톤별 통과 기준과 검증 하네스 방식이 정해지고, 불변식 16종 중 어느 것을 어느 단계에서 자동 검증할지 대응된다.

- [ ] 이중 유지보수, 회귀 표면, QA 매트릭스 위험이 완화안과 함께 표로 정리된다.

- [ ] 위 네 항목을 근거로 도입 여부 권고안이 나온다. 권고가 도입이면 후속 이슈 목록까지, 미도입이면 대안까지 포함한다.

## Definition of done

- [ ] 위 Acceptance Criteria 를 충족한다.

- [ ] 도입 결정 시 마일스톤별 후속 이슈가 EPIC CBRD-27193 아래에 등록된다.

- [ ] 미도입 결정 시 그 근거가 EPIC 본문에 반영되고 이 이슈가 종료된다.

- [ ] 조사 결과가 문서로 남고 EPIC 링크와 상태가 최신으로 유지된다.

## Open Questions

### 병행 버전 도입 자체의 승인

두 구현을 동시에 유지하는 비용을 감수할지가 아직 합의되지 않았다 (`TBD - 합의 미확인`). 이 조사의 결론이 "미도입"일 수도 있고, 그 경우에도 검토 항목 2의 판정표는 default 직접 수정 순서를 정하는 데 그대로 쓰인다.

### v2 의 최초 범위

SX latch 부터 시작할지, 자료구조(hash 크기, dirty 색인)부터 시작할지 미정이다 (`TBD - 합의 미확인`). 전자는 이득이 크지만 검증이 어렵고, 후자는 M0 단계에서 바로 확인 가능하다.

### 선택값의 노출 수준

숨김 파라미터, 공개 파라미터, 빌드 옵션 중 어느 수준으로 노출할지 미정이다 (`TBD - 합의 미확인`). 공개하면 현장에서 v2 를 켤 수 있게 되므로 지원 범위 결정이 함께 필요하다.

### v2 의 언어와 파일 형태

`page_buffer.c` 는 GNU indent 로 정형화되는 C 파일이라 C++ 문법을 `/* *INDENT-OFF* */` 로 감싸야 한다. v2 를 `.cpp` 로 시작하면 이 제약에서 자유롭지만 default 와 줄 단위로 대조하기는 어려워진다 (`TBD - 합의 미확인`).

## 참고 코드

| 위치 | 내용 |
|---|---|
| `page_buffer.c:847` | `static PGBUF_BUFFER_POOL pgbuf_Pool` — 풀 상태 전체를 담은 파일 정적 변수 |
| `page_buffer.c:1666` | `pgbuf_initialize` 가 `PRM_ID_PB_NBUFFERS` 를 읽는 지점. 기동 시 1회 파라미터 읽기의 기존 예 |
| `page_buffer.c:297-298` | `HASH_SIZE_BITS 20` / `PGBUF_HASH_SIZE` — pool 크기와 무관한 고정 버킷 수 |
| `page_buffer.c:577-584` | `struct pgbuf_buffer_hash` — 버킷 하나의 구성 |
| `page_buffer.c:4174`, `:4198-4199` | `pgbuf_flush_checkpoint` 의 BCB 전수 순회와 BCB 단위 mutex 획득 |
| `page_buffer.c:4999-5007` | `pgbuf_set_lsa` 가 `log_Gl.chkpt_redo_lsa` 를 직접 읽고 `log_Gl.chkpt_lsa_lock` 을 직접 잡는 지점 |
| `page_buffer.c:10741`, `:10755`, `:10767` | flush 진입 전이와, 복구 없이 반환하는 두 조기 실패 경로 |
| `page_buffer.h:277`, `:320`, `:327` | `NDEBUG` 분기 매크로 진입점의 예 |
| `src/storage/es.c:47` 부근 | 기동 시 확정한 타입으로 백엔드를 고르는 in-tree 선례 |
| `src/base/system_parameter.c:4586` | `tde_default_algorithm` — `PRM_KEYWORD` 열거형 파라미터 선례 |
| `cubrid/CMakeLists.txt:525`, `sa/CMakeLists.txt:530` | `page_buffer.c` 가 들어가는 두 빌드 타깃 |
| `unit_tests/double_write_buffer/CMakeLists.txt` | `SA_MODE` 정의 + `cubridsa` 링크로 storage 모듈을 단위 검증하는 선례 |

## References

- 부모 EPIC: CBRD-27193
- 형제 조사 이슈: CBRD-27196 (SX latch), CBRD-27211 (direct victim 대기자 선택)
- 기준 소스: [`page_buffer.c`](https://github.com/CUBRID/cubrid/blob/e6ed61e87d68baf1c38cee83ddd3bb4b2fa71b2e/src/storage/page_buffer.c), [`page_buffer.h`](https://github.com/CUBRID/cubrid/blob/e6ed61e87d68baf1c38cee83ddd3bb4b2fa71b2e/src/storage/page_buffer.h)
- 분석서 세트 (commit `e6ed61e87` 기준, 총론의 불변식 16종과 재구현 계획서 포함): my-cubrid-docs 게시 후 링크를 추가한다.
