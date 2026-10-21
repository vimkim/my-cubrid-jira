# [PGBUF] direct victim 대기자 선택 주기 `my_count % 4`의 적정성을 조사한다

## Issue Triage

**이슈 수행 목적**: 페이지 버퍼의 direct victim 대기자 선택 규칙이 high/low priority 작업의 대기와 CPU 비용에 미치는 영향을 확인하고, 현행 주기 `4`의 유지 또는 변경 판단에 필요한 근거를 남긴다.

**이슈 수행 이유**: 현재 선택 함수는 모든 호출자가 공유하는 카운터를 증가시키고 네 번째 호출마다 low priority 큐를 먼저 시도한다. 그 밖의 호출에서는 high priority 큐를 먼저 시도하며, 실패하면 low priority 큐도 확인한다. 이 주기의 적정성과 공유 atomic 연산의 비용을 분리한 측정 근거가 확인되지 않아 조사할 필요가 있다.

**영향**: 재사용할 버퍼 슬롯이 부족해 direct victim을 기다리는 일반 작업과 vacuum 등 내부 작업이 대상이다. 선택 순서가 부하와 맞지 않으면 어느 한쪽의 대기가 늘어날 수 있으나, 현재 자료만으로 성능 저하의 발생 여부·빈도·크기를 확정하지 않는다. `4`는 실제 배정 비율이나 최대 대기시간을 보장하는 값이 아니다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

페이지 버퍼는 디스크 페이지를 메모리에 보관하고, 필요한 페이지를 올릴 버퍼 슬롯을 확보한다. BCB(Buffer Control Block)는 해당 슬롯의 사용 및 상태를 관리하는 제어 정보다. 서버에서 빈 슬롯과 일반 victim 탐색에 실패하고 page flush 데몬을 사용할 수 있으면, 요청 스레드를 대기 큐에 넣고 다른 실행 주체가 재사용 가능한 BCB를 직접 배정해 깨우는 direct victim 경로로 진행한다. 대기는 timeout이나 interrupt로도 끝날 수 있다. [할당·대기 진입 경로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8190-L8314)

조사 기준은 CUBRID `f6cac312310f39f46711693da157a08f0e725693`이다. 이 작성에서는 소스의 선택·등록·배정 경로를 확인했으며, 해당 빌드에서의 부하 시험이나 성능 저하 재현은 수행하지 않았다.

대기자는 다음 기준으로 두 큐에 등록된다. high priority는 특정 종류의 스레드만을 뜻하지 않으며, 일반 worker도 보유한 페이지와 재시도 상태에 따라 이 큐에 들어갈 수 있다.

| 큐 | 현재 등록 조건 | 조사에서 구분할 점 |
|---|---|---|
| high priority | vacuum 스레드이거나, 자신이 보유한 페이지에 다른 대기자가 있거나, volume header·file header·B-tree root·heap header를 보유한 경우다. 직접 배정받은 BCB가 다시 fix되어 사용할 수 없으면 재시도도 high priority로 진행한다. | 다른 작업의 진행에 영향을 줄 수 있는 페이지 보유자와 재시도 작업을 포함한다. 일반 worker 전체를 low로 분류하면 실제 동작과 다르다. |
| low priority | 위 조건에 해당하지 않는 대기자다. | low 큐 등록이 실패하면 high 큐 등록을 시도한다. 큐별 대기 통계와 작업의 원래 역할을 구분해야 한다. |

등록과 재시도는 [할당 경로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8211-L8285), 페이지 보유 조건은 [우선순위 판정 함수](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L11678-L11732)에서 확인한다. 여기서 fix는 페이지의 사용 및 메모리 체류를 관리하는 연산이다. 페이지 내용에 대한 짧은 접근을 조정하는 page latch와 트랜잭션의 논리 접근을 조정하는 transaction lock은 별도 개념이다.

`pgbuf_get_thread_waiting_for_direct_victim()`은 함수 내부의 공유 `static count`를 atomic 연산으로 증가시킨 뒤 다음 순서로 큐의 `consume()`을 시도한다. 각 단계가 성공하면 즉시 반환한다.

| 공유 카운터의 증가 후 값 | 시도 순서 |
|---|---|
| `my_count % 4 == 0` | low → 실패하면 high → 실패하면 low 재시도 |
| 그 밖의 값 | high → 실패하면 low |

즉, 모든 호출자를 합친 selector 호출 순번 중 네 번째마다 low-first 기회가 생긴다. 스레드별 네 번째 대기나 네 번째 배정을 뜻하지 않는다. high의 consume이 실패하면 나머지 호출에서도 low를 확인한다. low-first 호출의 마지막 low 재시도도 동시 실행 중 큐 상태가 달라질 수 있는 별도 시도다. [선택 함수](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L15509-L15539), [증가 후 값을 반환하는 atomic 연산](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/porting.h#L848-L858)

호출 횟수와 실제 배정 횟수도 다르다. 선택 함수는 큐 확인 전에 카운터를 증가시키므로 양쪽 consume이 모두 실패한 호출도 센다. 배정 함수는 꺼낸 스레드가 이미 대기를 끝냈으면 건너뛰고 선택 함수를 다시 부른다. `consume()`은 큐가 비었거나 선두 항목의 생산이 아직 완료되지 않은 경우에도 실패할 수 있다. 따라서 `4`를 high:low 배정 3:1, low에 대한 시간상 주기, 또는 starvation 방지의 증명으로 사용할 수 없다. [배정과 대기 종료 확인](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L15378-L15434), [큐 소비의 실패 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/lockfree_circular_queue.hpp#L318-L369)

본 이슈는 현행 규칙의 적정성을 판단할 근거 부족을 조사한다. [기존 CBRD-27211 로컬 설명](https://github.com/vimkim/my-cubrid-jira/blob/da39b0f3ee0bc1c55d2063588c3969a808a95687/issues/CBRD-27211-direct-victim-waiter-policy_f30f1c2_codex.md)은 주기와 적응형 후보의 검증을 제안하지만, 확인한 본문·댓글과 관련 자료에서는 숫자 `4`를 분리한 비교 결과나 현재 부하에 대한 적정성 판단을 확인하지 못했다. 이 판단 공백을 해소하는 것이 본 이슈의 조사 범위다.

### 왜 문제인가

재사용할 BCB를 기다리는 동안에는 해당 페이지를 필요로 하는 작업이 다음 단계로 진행하지 못한다. high priority 큐에는 다른 대기자가 있는 페이지나 중요 header·root 페이지의 보유자도 포함되므로, 배정이 늦어지면 그 작업을 기다리는 다른 작업으로 지연이 이어질 가능성이 있다. 반대로 high priority를 우선하는 규칙만 강화하면 일반 대기자의 지연을 키울 수 있다. 이는 소스에서 유도한 영향 가능성이며, 실제 지연 분포와 사용자 쿼리 영향은 측정해야 한다.

또한 모든 selector 호출은 같은 atomic 카운터를 갱신한다. 동시 호출이 많은 부하에서는 공유 갱신 비용이 조사 대상이지만, atomic 연산이 있다는 사실만으로 병목이라고 결론 내릴 수 없다. 큐 대기, victim 공급 부족, 선택 함수의 실행 비용을 분리하지 않으면 공급 경로의 문제를 선택 주기 탓으로 해석하거나 불필요한 정책 변경을 선택할 수 있다.

### 왜 해결해야 하는가

현재는 페이지 버퍼 압박 시 어느 작업군의 대기가 늘어나는지, 그 원인이 선택 규칙인지, 다른 규칙의 이득이 측정 비용과 복잡성을 정당화하는지 판단할 근거가 부족하다. 현행 값을 그대로 유지하는 결론도 가능하지만, 유지 이유와 측정 범위를 남겨야 이후 성능 문제에서 같은 가정을 반복하지 않을 수 있다. 주기 변경이나 운영자용 설정 추가 여부도 이 근거를 바탕으로 판단해야 한다.

따라서 먼저 현재 부하에서 선택 비용과 두 큐의 대기를 관찰하고, 문제가 확인되면 대안의 이득과 반대편 작업군의 영향을 비교할 필요가 있다. 현재 자료로 긴급도나 제품별 발생 범위는 확정하지 않으며, 코드 변경 없이 유지 근거를 남기는 조사 완료도 허용한다.

## Specification Changes

### 측정과 판단에 필요한 결과

| 조사 질문 | 남길 결과 |
|---|---|
| 현재 selector에 얼마의 비용이 드는가 | 호출 수, 큐별 consume 시도·성공 수, 실제 배정 수, 대기가 끝난 항목의 건너뜀, 선택 함수와 공유 atomic 갱신의 CPU 비용을 가능한 범위에서 분리한다. |
| 어떤 대기자가 오래 기다리는가 | 큐별 평균·상위 백분위·최대 대기시간과 표본 수, 큐 길이, 원래 작업 역할, 재시도·high 큐 fallback 여부를 구분한다. 큐 위치만으로 vacuum과 일반 worker를 나누지 않는다. |
| 전체 작업에 의미 있는 차이가 있는가 | 같은 소스·빌드·데이터·페이지 버퍼 크기·동시성·설정에서 처리량, 쿼리 경과시간, 페이지 I/O와 victim 공급 상태를 함께 기록한다. 반복 간 변동과 계측 비용을 구분한다. |

기존 `assign_direct_bcb`, `alloc_bcb_cond_wait_high_prio`, `alloc_bcb_cond_wait_low_prio`는 조사 출발점으로 활용할 수 있다. 다만 전자는 selector만이 아니라 배정 함수의 구간을 재고, 후자는 등록한 큐에 따른 대기 구간을 잰다. 이 값만으로 selector의 atomic CPU 비용, 작업 역할별 대기, p99 분포를 모두 알 수 있다고 가정하지 않는다. 필요한 추가 계측과 활성화 조건을 정하고, 계측을 켠 결과와 끈 결과의 차이도 확인한다. [통계 정의](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/perf_monitor.c#L503-L509), [배정 계측 구간](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L15384-L15430), [대기 통계 선택과 기록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8224-L8273)

현재 low-only, high-only, 혼합 대기를 구분하고 큐가 비는 경우도 관찰해야 한다. 일반 worker만 실행해도 high 큐에 들어갈 수 있으므로 실제 등록 상태로 부하를 확인한다. 부모 이슈의 Daehyun Kim은 2026-08-06 댓글에서 [CBRD-27188](https://jira.cubrid.org/browse/CBRD-27188)·[CBRD-27191](https://jira.cubrid.org/browse/CBRD-27191) 등 TPC-H 성능도 함께 고려하도록 요청했다. 이 workload가 direct victim 대기를 실제로 발생시키는지 확인한 뒤 비교에 활용한다. 해당 요청은 `my_count % 4`가 TPC-H 회귀의 원인이라는 결과를 뜻하지 않는다. [부모 댓글](https://jira.cubrid.org/browse/CBRD-27193?focusedCommentId=4775680&page=com.atlassian.jira.plugin.system.issuetabpanels:comment-tabpanel#comment-4775680)

기존 설명의 고정값 `2`·`8`과 적응형 규칙은 비교 후보로 볼 수 있으나, 필수 실험 조합이나 채택 방안으로 합의됐다는 근거는 확인되지 않았다. TPS 1%, p99 대기시간 5%, selector CPU 1% 기준도 승인된 판정 기준으로 사용하지 않는다. 표본 수·실행 변동·업무상 의미와 양쪽 작업군의 허용 영향을 바탕으로 비교 후보와 판정 기준을 ANALYSIS에서 정한다.

### 후보를 검토할 때의 제약

| 선택지 | 기대할 수 있는 점 | 확인할 비용·한계 |
|---|---|---|
| 현행 `4` 유지 | 선택 동작과 복잡성을 유지한다. | 관찰한 부하와 판단 범위가 명확해야 하며, 측정하지 못한 조건까지 적정하다고 일반화하지 않는다. |
| 다른 고정 주기 | low-first 빈도의 영향을 단순하게 비교할 수 있다. | 한쪽 대기를 줄이는 대신 반대쪽을 늦출 수 있고 부하마다 결과가 다를 수 있다. |
| 적응형 규칙 | 대기 상황에 따라 우선순위를 조정할 가능성이 있다. | 관측·동기화 비용과 정책 복잡성이 추가된다. 큐 길이와 최근 대기시간 중 무엇이 필요한지도 미정이다. |

고정 주기는 규칙과 검증이 단순하고, 적응형 규칙은 부하 변화에 대응할 가능성이 있는 대신 관측·동기화 비용이 추가된다. 어느 쪽이 필요한지는 측정 결과를 바탕으로 ANALYSIS에서 판단한다.

`circular_queue::size()`는 consume/produce cursor를 각각 읽어 계산하므로 동시 실행 중 일관된 전체 스냅샷으로 보장되지 않는다. 큐 길이를 적응형 입력으로 검토하더라도 consume 가능 여부를 대신하는 확정값으로 취급하지 않으며, 한쪽 큐의 소비 실패 때문에 다른 쪽의 진행을 막지 않는지 확인한다. 운영자용 system parameter 추가 필요성도 ANALYSIS에서 판단한다. [큐 길이 계산](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/lockfree_circular_queue.hpp#L393-L406)

### 관련 이슈와의 경계

본 이슈는 공급된 victim을 기다리는 **스레드 큐의 선택 규칙**을 조사한다. [CBRD-27264](https://jira.cubrid.org/browse/CBRD-27264)는 maintenance와 긴급 배정 경로의 도달성 및 복구·제거 판단을, [CBRD-27267](https://jira.cubrid.org/browse/CBRD-27267)은 victim 후보를 가진 private LRU 인덱스 큐의 생산·소비 정책을 다룬다. 서로 다른 큐와 문제이므로 이 조사에서 공급 경로의 구현 방안을 함께 확정하지 않는다. [maintenance 순회](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9570-L9599), [private LRU 인덱스 큐 소비·재등록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16384-L16442)

공급 경로가 바뀐 빌드에서는 대기 특성도 달라질 수 있으므로 비교 시 각 변경을 기록하고 효과를 분리한다. 다른 이슈의 코드 변경을 본 조사 착수의 일괄 선행 조건으로 두지는 않는다. [CBRD-27423](https://jira.cubrid.org/browse/CBRD-27423)의 성능 분석 작업과 측정 정의를 공유할 수 있으나, 별도 프레임워크 완성을 본 이슈의 필수 조건으로 가정하지 않는다.

## Implementation

TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

## Acceptance Criteria

- [ ] 기준 소스에서 전역 호출 카운터, low-first와 fallback 순서, 실제 high/low 등록 조건을 확인한 결과를 남긴다. 호출 수·consume 성공 수·실제 배정 수를 구분한다.
- [ ] 현재 `4`에서 큐별 대기와 selector 비용을 관찰한 결과를 소스·빌드·데이터·설정·동시성·표본 수·반복 조건과 함께 남긴다. 측정하지 못한 항목은 이유와 판단 한계를 적는다.
- [ ] low-only·high-only·혼합 상태와 TPC-H 관련 부하의 조사 결과 또는 적용하지 못한 이유를 기록한다. 공급 상태와 계측 비용을 함께 확인한다.
- [ ] 유지 또는 변경 필요 여부를 근거와 함께 결정한다. 대안을 비교했다면 선택한 후보, 판정 기준, 실행 변동, 양쪽 작업군과 전체 성능의 영향을 남긴다. 수치 기준과 구현 방안은 ANALYSIS에서 검토한 결정을 기록한다.
- [ ] 변경을 제안하는 경우 빈 큐, 대기를 끝낸 항목, timeout·interrupt·shutdown, 직접 배정 BCB 무효화 후 재시도에서 진행과 정리가 보존되는지 확인할 검증 범위와 후속 구현 작업을 명시한다. 이 조사 이슈가 구현까지 포함하게 되면 해당 검증과 필요한 기능·성능 QA 결과를 남긴다.

## Definition of done

- [ ] 조사 기준 소스, 측정 환경·방법·결과와 미확인 사항을 다른 담당자가 검토하고 이어받을 수 있는 형태로 남긴다.
- [ ] 현행 유지 또는 변경 필요성의 판단 근거와 적용 범위를 기록한다. 변경을 제안하면 후속 구현·검증 범위와 남은 결정을 함께 인계한다.
- [ ] 작성자 측의 ANALYSIS 결과와 후속 작업 유무를 이슈에 남겨, 조사 완료와 구현 완료를 구분한다.

## Open Questions

- `4`를 선택한 원래 근거와 현재에도 유효한 비교 자료가 있는가? 기존 설명이 언급한 [CBRD-20074](https://jira.cubrid.org/browse/CBRD-20074) 도입 이력과 전체 성능 시험이 주기 자체의 검증까지 포함하는지 확인해야 한다.
- 현재 workload에서 두 큐가 함께 대기하는 빈도와 공급 중단 구간은 어느 정도이며, 선택 비용과 공급 부족을 어떻게 분리할 것인가?
- 보호할 작업군의 대기 지표와 허용 영향은 무엇이며, 반복 측정의 변동에 비해 의미 있는 차이를 어떻게 판정할 것인가?
- 고정 주기 변경만으로 충분한가? 적응형 입력이나 운영자용 설정을 추가할 필요가 있다면 관측 비용과 관리 비용을 정당화할 수 있는가?

## Triage Request

부모 [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)의 Sub-task로서, direct victim 대기자 선택 주기의 적정성을 판단할 근거가 부족하다는 조사 과제를 확인하고 작성자 측에 ANALYSIS 배정을 요청한다. 분석 결과는 현재 정책의 유지 근거 또는 변경 필요성과 후속 범위를 제시해야 한다. 담당자·우선순위·최종 정책은 triage와 ANALYSIS에서 결정하며, 이 요청만으로 성능 결함이나 적응형 정책 도입을 확정하지 않는다.
