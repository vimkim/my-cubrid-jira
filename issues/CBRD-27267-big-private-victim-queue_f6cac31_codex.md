# [PGBUF] [Survey] big private victim queue의 초기 등록과 재등록 정책을 검증한다

## Issue Triage

**이슈 수행 목적**: big private victim queue가 제한된 victim 탐색에 후보를 공급하는 조건과 효과를 확인하고, 현행 정책 유지 또는 변경의 근거를 마련한다.

**이슈 수행 이유**: 신규 private 리스트는 일반 private 큐에 등록되고, 그 큐에서 꺼낸 리스트가 크기 조건을 만족하면 big 큐에 처음 등록될 수 있다. 반면 `restricted == true` 호출은 big 큐 소비에 실패하면 일반 큐를 확인하지 않는다. 생산 경로는 존재하므로 기존의 생산자 부재 주장은 정정하며, 초기 등록에 필요한 호출과 실제 부하에서의 탐색 효과를 조사한다.

**영향**: big 큐 소비에 실패한 제한 호출은 다른 private 리스트 탐색을 마치고 shared LRU 탐색으로 진행한다. 일반 큐에만 있는 큰 리스트를 그 호출에서 발견하지 못하는 것은 코드로 확인한다. 이 정책이 추가 탐색 비용, victim 대기 또는 공용 작업 집합의 캐시 적중률 저하를 일으키는 빈도와 크기는 미확인이다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

페이지 버퍼는 디스크 페이지를 메모리 슬롯에 보관하고, 슬롯의 사용 상태와 교체를 관리한다. BCB(Buffer Control Block)는 슬롯의 페이지와 fix 수 등 제어 상태를 보관한다. 여기서 victim은 재사용할 슬롯을 확보하기 위한 회수 대상이다. LRU(Least Recently Used)는 페이지 교체 목록이며, 이 이슈의 큐는 페이지 자체가 아니라 victim 후보가 있는 LRU 리스트의 인덱스를 담는다. 따라서 큐 소비 성공과 실제 victim 확보 성공은 다르다.

`pgbuf_get_victim()`은 자기 private LRU, 다른 private LRU, shared LRU 순서로 탐색한다. 자기 리스트 탐색에 실패하고 quota 초과 여유분 조건을 만족하면 일부 호출에서 `restrict_other`가 참이 된다. 여유분은 `max(10, int(quota * 0.01))`이며, vacuum의 unfix 무시 조건은 이 제한 판정에서 제외한다. 다른 private 리스트 단계는 quota가 활성화되고 page flush 데몬을 사용할 수 있을 때 실행한다. 제한 호출도 big 큐는 사용할 수 있다. 이는 [현재 탐색 순서와 제한 설정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9047-L9138), [quota 판정식](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L1035-L1048)에서 확인한다.

현재 등록과 소비의 연결은 다음과 같다.

| 단계 | 소스에서 확인한 동작 | 해석 |
|---|---|---|
| 신규 등록 | `pgbuf_lfcq_add_lru_with_victims()`는 플래그와 CAS로 중복 등록을 막고 private/shared를 구분한다. private는 일반 private 큐에 넣는다. | 이 등록 함수는 big 큐로 직접 분류하지 않는다. |
| 우선 소비 | `pgbuf_lfcq_get_victim_from_private_lru()`는 big 큐 소비를 먼저 시도한다. | 제한 여부와 관계없이 이미 등록된 big 리스트를 사용할 수 있다. |
| 일반 큐 소비 | big 소비가 실패하고 `restricted == false`이면 일반 private 큐 소비를 시도한다. | 일반 큐의 인덱스가 big 큐로 처음 이동할 수 있는 진입 경로다. |
| big 등록 | 어느 큐에서 꺼냈든 리스트 크기 > 100, 크기 > 해당 리스트 quota의 2배, `count_vict_cand > 1`이면 big 큐에 다시 넣기를 시도한다. | 후보 수 조건은 2개 이상이다. 비교 기준은 대상 리스트 자신의 quota이며, 요청자 리스트와 크기를 비교하지 않는다. |
| victim 탐색 | big 재등록 시도 후 `pgbuf_get_victim_from_lru_list()`를 호출한다. | 재등록 성공은 victim 탐색 성공을 보장하지 않는다. |
| 이후 처리 | big에 재등록했으면 탐색 결과를 반환한다. 그렇지 않으면 후보가 남고 quota를 초과한 리스트를 일반 큐에 재등록하려 하며, 재등록하지 못하면 큐 등록 플래그를 지운다. | 리스트 상태와 등록 성공 여부에 따라 큐 소속이 달라진다. |

근거: [신규 등록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16337-L16381), [big 우선 소비와 최초 등록 경로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16384-L16443), [재등록과 플래그 정리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16445-L16469).

따라서 big 큐가 비어 있어도 비제한 호출이 일반 큐의 조건 충족 리스트를 소비하면 첫 인덱스를 넣을 수 있다. 이후에는 제한 호출도 big 큐를 소비하고 조건이 유지되면 같은 big 큐에 재등록할 수 있다. 기존의 “생산자가 없다”, “항상 비어 있다”, “over-quota 스레드는 생산 경로에 도달하지 못한다”는 일반화는 이 소스와 맞지 않는다. 후속 분석 문서도 일반 private 큐에서 big 큐를 채울 수 있다는 정정과 제한 탐색의 효과 조사를 요청한다. 이 문서는 현재 소스의 실측 성능 결과가 아니다. [후속 분석의 정정](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/pgbuf/report-2026-10-02.md#L174-L178)

남는 질문은 **big 큐에서 소비할 수 없을 때 제한 호출이 일반 큐에 있는 큰 리스트를 발견하지 않는 정책이 적절한가**이다. 이 호출은 `restricted` 분기에서 즉시 `NULL`을 반환하며, 호출자는 shared LRU 탐색을 진행한다. big 큐가 비어 있고 이후 비제한 호출이 일반 큐를 소비하지 않는 동안에는 이 소비 경로를 통한 최초 등록이 일어나지 않는다고 추론한다. 다만 “모든 세션이 quota 초과”라는 설명만으로 이 호출 상태나 큐 이력을 확정할 수는 없다. 비제한 여부는 호출마다 결정되며, 기존 big 항목은 제한 호출로도 재등록할 수 있다. [제한 호출의 반환](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16408-L16442), [shared 탐색으로의 진행](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9134-L9177)

### 왜 문제인가

일반 큐에 조건을 충족하는 리스트가 남아 있어도 제한 호출은 그 리스트를 선택하지 않을 수 있다. 해당 호출의 다른 private 탐색 기회가 줄어드는 만큼 shared 탐색 또는 이후 슬롯 대기에 비용이 옮겨갈 가능성이 있다. 이 차이는 동시 작업의 victim 확보 지연과 캐시 자원 배분을 검토할 이유가 된다. 그러나 자기 private 탐색은 먼저 수행되고, 전체 탐색 실패 뒤에는 direct victim을 기다리는 경로도 존재한다. 큰 private 리스트가 회수 압력을 전혀 받지 않는다거나 진행이 막힌다고 단정할 근거는 없다. [자기 리스트 우선 탐색](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9069-L9111), [탐색 실패 후 direct victim 대기 등록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8203-L8237)

큰 테이블 스캔의 동시 실행은 조사할 부하 후보이며, 모든 victim 호출을 제한 호출로 만든다는 보장은 없다. 현재 자료에는 이 정책 때문에 발생한 처리량 저하, 지연 증가, 공용 캐시 오염 또는 고객 장애를 분리해 입증한 결과가 없다. 따라서 이 이슈는 확인된 데이터 손상이나 생산 경로 단절의 수정으로 취급하지 않고, 제한 탐색 정책의 효과와 비용을 판별하는 조사로 다룬다.

### 왜 해결해야 하는가

생산 경로가 없다는 전제로 복구하거나 큐를 제거하면 현재 작동하는 초기 등록과 재등록을 잘못 변경할 수 있다. 반대로 실제 부하에서 제한 탐색이 유효한 후보를 반복해서 놓치는지 확인하지 않으면, victim 대기나 shared 탐색 비용을 줄일 여지가 있는지도 판단할 수 없다. 정정된 경로와 호출 조건에 맞춰 관측 근거를 남겨야 현행 유지, 등록 시점 변경, 큐 제거를 비교할 수 있다.

quota 비활성화는 이 정책을 조사하는 대체 수단이 아니다. 해당 설정에서는 private 큐 자체를 만들지 않으므로 private/shared 자원 배분까지 달라진다. 조사에서는 동일 설정의 현행 동작을 기준으로 삼고, 비활성 설정은 별도의 비교 조건으로 구분한다. 긴급도와 영향받는 릴리스는 현재 근거로 확정하지 않는다. [private 큐 생성 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L1790-L1809), [서버 및 standalone의 quota 설정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L13910-L13933)

## Evidence

분석 기준은 CUBRID `f6cac312310f39f46711693da157a08f0e725693`이다. 위 내용은 이 커밋의 소스 분기와 대입 순서를 확인한 결과이며, 새 서버 빌드나 SQL 부하 시험을 실행한 결과가 아니다. 2026-10-21 조회한 기존 이슈에는 댓글이 없다. 이전 문서의 `5cd4f860e`, `e6ed61e87` 기반 분석과 현재 기준의 런타임 결과를 동일시하지 않는다.

### 등록 경로와 조사 조건

quota 재계산의 두 private 루프와 victim 후보 증가 경로는 후보가 있고 quota를 초과한 private 리스트를 일반 등록 함수로 보낸다. quota 재계산 자체가 big 큐로 직접 넣는 경로는 아니다. 세션과 private 리스트의 일대일 소유도 전제하지 않는다. 리스트 배정은 빈 세션 리스트를 우선하되, 없으면 활동이 적은 리스트를 선택할 수 있다. [quota 재계산의 등록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14350-L14423), [후보 증가 시 등록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L15658-L15668), [private 리스트 배정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14489-L14546)

ANALYSIS에서는 최초 big 등록 전, 등록 후 제한 소비 및 재등록, 조건 미충족 후 일반 큐 재등록을 구분한다. 초기 큐 상태, 호출의 `restricted` 값, 대상 리스트 크기와 quota, 후보 수, 큐 연산 결과, 실제 victim 탐색 결과를 함께 기록해야 한다. 큐 구현은 선두 항목이 아직 생산 중인 경우에도 `consume()`이 실패할 수 있으므로, 소비 실패를 항상 물리적으로 빈 큐라고 해석하지 않는다. [소비 실패 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/lockfree_circular_queue.hpp#L335-L350)

### 지표의 의미와 한계

| 지표 | 현재 의미와 주의점 |
|---|---|
| `Num_lfcq_big_private_lists` | `pgbuf_peek_stats()`에서 big 큐의 `size()`를 읽은 게이지다. 단일 0 표본은 생산 경로가 없다는 증거가 아니다. |
| `Num_lfcq_prv_get_big` | big 큐 소비 성공 횟수다. 리스트에서 victim을 확보한 횟수가 아니다. |
| `Num_lfcq_prv_get_total_calls` | big 소비 성공 또는 비제한 일반 큐 시도에서 증가한다. 제한 호출의 big 소비 실패는 포함하지 않으므로 함수 전체 진입 횟수가 아니다. |
| `Num_lfcq_prv_get_empty` | big 소비 실패 뒤 비제한 호출의 일반 큐 소비도 실패할 때 증가한다. 제한 호출의 조기 반환을 세지 않는다. |
| `Num_victim_other_private_lru_success`, `Num_victim_other_private_lru_fail` | 선택한 private 리스트의 실제 victim 탐색 결과다. 큐 소비 횟수와 분리한다. |
| `alloc_bcb_get_victim_search_shared_list`, `alloc_bcb_cond_wait_high_prio`, `alloc_bcb_cond_wait_low_prio` | 탐색 또는 대기의 횟수와 시간 계열이다. shared 탐색 시간만으로 shared 페이지 회수량이나 캐시 오염을 판정하지 않는다. |

근거: [큐 소비 및 victim 결과 카운터](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16394-L16443), [지표 이름과 형식](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/perf_monitor.c#L505-L546), [게이지 등록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/perf_monitor.c#L561-L567), [큐 크기 조회](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14783-L14793).

private 소비 함수의 상세 카운터는 성능 추적과 `PERFMON_ACTIVATION_FLAG_PB_VICTIMIZATION` 활성 조건에 묶인다. `extended_statistics_activation` 기본 마스크에는 이 비트 `0x10`이 없다. 게이지와 모든 시간 지표를 동일한 게이트의 누적 카운터로 취급하지 않으며, 측정 시 추적 여부와 활성 마스크를 기록한다. 비활성 상태의 0과 관측된 사건 0회를 구분한다. [상세 추적 게이트](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16394-L16400), [활성 비트](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/perf_monitor.h#L56-L65), [기본 마스크](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L4155-L4165)

`pgbuf_peek_stats()`가 두 private 큐 포인터가 `NULL`일 때 해당 출력 인자에 대입하지 않는 것은 확인한다. 다만 perfmon의 이 함수 호출은 `SERVER_MODE` 안에 있고, 이 정적 사실만으로 운영 statdump에 미초기화값이나 이전 값이 노출됐다고 판단하지 않는다. 호출자의 버퍼 초기화와 모드별 사용 계약, 원하는 “비활성/미제공/0” 표현을 확인해야 한다. 단순 0 초기화를 이미 선정된 수정이나 본 조사 전제 조건으로 두지 않는다. [출력 초기화 목록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14697-L14717), [조건부 대입](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14783-L14793), [서버 모드 호출자](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/perf_monitor.c#L1949-L1968)

## Specification Changes

TBD - ANALYSIS 단계에서 제한 탐색이 보장해야 할 결과와 변경 필요성을 정한다. 현행 정책 유지도 조사 결론으로 허용한다. 큐를 제거한다면 이는 이미 사용 가능한 big 소비와 재등록을 없애는 정책 변경이므로, 단순한 죽은 코드 삭제로 취급하지 않는다. 관련 통계 항목의 유지, 폐기 또는 의미 변경과 호환성도 별도로 정해야 한다.

## Implementation

TBD - ANALYSIS 단계에서 결정한다. 현행 동작을 기준으로 등록 시점 변경과 큐 제거의 이득 및 비용을 비교한다. 등록 시점 변경은 일반 큐 소비에 앞서 big 후보를 알릴 수 있지만 후보 증가 경로의 실행 비용, 이미 등록된 인덱스의 이동과 중복 방지, 리스트 간 회수 편중을 검토해야 한다. 큐 제거는 구조를 줄일 수 있지만 현재 가능한 제한 호출의 big 회수를 없애므로, 현행과 동작이 같다고 전제할 수 없다. 구체 함수 변경, 주기, 성능 목표값은 합의된 설계가 아니다.

## Acceptance Criteria

- [ ] 일반 큐에서 첫 big 항목을 등록하는 경로와, 제한 호출이 기존 big 항목을 소비하고 재등록하는 경로를 기준 커밋에 맞춰 검증하고 증거를 남긴다.
- [ ] 제한 호출의 big 소비 실패 시 일반 큐 미탐색을 확인하고, 해당 상태의 발생 빈도와 지속 시간을 큐 이력 및 호출 상태와 함께 조사한다. 대표 부하에서 관측하지 못했다면 조건과 조사 한계를 기록한다.
- [ ] 설정, 빌드, 데이터와 동시 실행 조건을 명시한 부하에서 실제 victim 확보, shared 탐색, 슬롯 대기와 처리 지연을 비교한다. 측정하지 않은 캐시 오염이나 성능 향상을 결론으로 쓰지 않는다.
- [ ] 현행 유지 또는 변경의 근거와 남은 불확실성을 기록한다. 변경을 선택한 경우 자원 배분, 진행, 관측 지표의 계약과 수용 기준을 확정한다.
- [ ] 큐의 NULL 상태에서 통계 출력 계약을 확인하고, 필요한 조치의 범위와 담당 이슈를 정리한다. 큐 제거를 선택하면 통계 호환성 처리를 CBRD-27266과 조정한다.

## Definition of done

- [ ] 생산자 부재와 항상 비어 있다는 기존 주장을 정정한 조사 결과를 남긴다.
- [ ] 초기 등록 및 재등록 경로 증거와 부하 관측을 구분하고, 조사 질문에 대한 유지/변경 결론 또는 추가로 필요한 증거를 제시한다.
- [ ] 코드 변경이 필요하면 quota 활성/비활성, 비제한/제한 호출, 소비 성공 뒤 실제 victim 실패를 포함한 관련 검증 범위와 성능 비교 기준을 정하고 결과를 남긴다. 코드 변경이 필요 없으면 그 근거를 기록한다.

## Related Issues

- [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)의 페이지 버퍼 작업 중 big private victim queue의 등록과 소비 정책을 맡는다.
- [CBRD-27211](https://jira.cubrid.org/browse/CBRD-27211)은 direct victim을 받을 high/low 대기자의 우선 선택 주기를 다룬다. 큐 후보의 발견 가능성과 대기자 우선 선택 주기는 별개이며, 측정 맥락을 공유한다.
- [CBRD-27264](https://jira.cubrid.org/browse/CBRD-27264)의 direct victim 긴급 배정 경로와 본 큐의 도달 가능한 소비 경로를 구분한다. 한쪽의 복구 또는 제거 결정을 다른 쪽에 적용하지 않는다.
- [CBRD-27266](https://jira.cubrid.org/browse/CBRD-27266)과 지표 정의 및 출력 호환성을 공유한다. 본 조사 결과에 따른 큐 변경과 일반 통계 의미 정리의 작업 경계를 조정한다.
- [CBRD-27269](https://jira.cubrid.org/browse/CBRD-27269)의 정리 대상에 본 큐를 죽은 코드로 포함하지 않는다. [CBRD-27316](https://jira.cubrid.org/browse/CBRD-27316), [CBRD-27423](https://jira.cubrid.org/browse/CBRD-27423)과 private LRU 부하 및 측정 방법을 공유할 수 있으며, 공통 도구 완성을 본 조사 착수의 필수 선행 조건으로 두지 않는다.

## Triage Request

생산 경로가 없다는 기존 전제를 정정하고, 제한 탐색에서 big 후보를 발견하는 정책의 효과를 확인하는 조사로 이슈를 확인해 주기를 요청한다. 작성자 측에 ANALYSIS를 배정하여 초기 등록과 재등록의 실제 발생 조건, 부하에서의 영향, 통계 출력 계약을 확인하고 현행 유지 또는 변경의 근거를 제시하도록 요청한다. 생산 경로 변경과 큐 제거 중 어느 방향도 이 단계에서 선정하지 않는다.
