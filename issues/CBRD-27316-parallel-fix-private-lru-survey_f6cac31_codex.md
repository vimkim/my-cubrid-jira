# [PGBUF] 병렬 fix와 private LRU의 victim 선택 패턴 및 비용을 조사한다

## Issue Triage

**이슈 수행 목적**: 여러 작업의 동시 fix/unfix가 private/shared LRU 배치와 victim 확보에 미치는 관계를 설명하고, 관측 결과를 바탕으로 현행 유지 또는 후속 개선의 필요성과 범위를 판단한다.

**이슈 수행 이유**: 원제는 `parallel fix + private LRU survey (victimize pattern)`이지만, 재작성 전 2026-10-21 조회 스냅샷에는 본문과 댓글이 없어 조사 동기, 대상 부하, 완료 기준이 확인되지 않았다. 현재 소스에는 작업의 private LRU 문맥, 마지막 unfix 시의 배치, quota, victim 탐색 순서가 연결되어 있으므로, 이 관계를 분리해 확인할 조사 범위가 필요하다.

**영향**: 페이지 버퍼 개발자가 동시 접근의 비용을 분석할 때, 페이지 자체의 경합과 교체 목록 관리·victim 탐색·할당 대기의 비용을 구분할 근거가 부족하다. 이 조사에서 성능 회귀나 사용자 장애를 확인한 것은 아니며, 실제 발생 부하·비용·개선 효과는 미확인이다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

이 이슈는 [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)의 하위 조사다. 재작성 전 2026-10-21 조회 스냅샷의 [CBRD-27316](https://jira.cubrid.org/browse/CBRD-27316)은 작성 중 제목만 있고 본문과 댓글이 없었다. 따라서 원래 등록자가 어떤 현상이나 비용을 문제로 보았는지, `parallel fix`가 특정 병렬 실행 경로를 지칭하는지는 확인되지 않았다. 이 설명은 원제의 병렬 fix, private LRU, victim 패턴이라는 범위를 보존하여 **여러 작업이 동시에 기존 fix/unfix를 수행할 때의 교체 동작 조사**로 구체화한 제안이다. 새 병렬 fix API 도입 요구는 확인되지 않았다.

페이지 버퍼는 디스크 페이지를 메모리 슬롯에 보관한다. VPID는 볼륨과 페이지 번호의 조합이고, BCB는 한 슬롯의 상주 페이지, fix 수, page latch와 교체 상태를 관리하는 제어 블록이다. fix/unfix는 사용 중인 슬롯의 유지·사용 회계를 수행하며, page latch는 메모리 페이지 접근을 조정한다. page latch 대기와 새 페이지를 담을 슬롯을 얻기 위한 victim 대기는 분석 대상이 다르다. private/shared LRU는 BCB를 묶는 교체 목록이다. private LRU라는 이름만으로 worker마다 별도 페이지 사본이나 독립적인 캐시 용량을 가진다고 해석할 수 없다. [BCB 구조](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L492-L533), [슬롯 할당과 victim 대기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8168-L8279)

현재 소스는 세션에 private LRU 인덱스를 배정하고 요청 worker에 그 값을 전달한다. 배정 함수에는 기존 세션이 사용하는 목록을 함께 선택할 수 있는 경로도 있다. 따라서 worker 수, 세션 수, private LRU 수를 같은 값으로 가정하지 않고, 실제 실행 경로의 매핑부터 확인해야 한다. 이 설명은 소스에서 도출한 조사상의 주의점이며, 잘못된 매핑이 발생했다는 오류 보고가 아니다. [세션 배정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/session/session.c#L733-L742), [요청 worker 문맥 설정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/connection/server_support.c#L2088-L2101), [private LRU 선택](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14481-L14551)

### 왜 문제인가

동일 페이지를 동시에 fix하는 부하와 서로 다른 페이지를 읽으며 버퍼를 교체하는 부하는 다른 비용을 드러낼 수 있다. 전자는 페이지의 사용·latch 경합을, 후자는 목록 배치, quota와 victim 확보를 함께 관측해야 한다. 현재 이슈에는 이 차이를 구별할 부하나 결과가 없다. 동시성에 따른 실행 시간 변화만 측정하면 어떤 경로가 비용을 만들었는지 판단하기 어렵고, 특정 작업의 이득과 다른 세션의 할당 지연을 함께 평가할 수도 없다. 이는 조사 설계에서 해결할 공백이며, 어느 경로가 실제 병목인지는 아직 모른다.

소스상 일반 unfix 경로의 LRU 처리는 한 worker의 해제가 아니라 BCB 전체 fix 수가 0이 되는 조건과 연결된다. 그때도 대기자, zone, 현재 작업의 private LRU 문맥에 따라 유지·이동·boost가 달라진다. victim 탐색 역시 자기 private LRU, 다른 private LRU, shared LRU를 조건에 따라 사용한다. 따라서 동시 fix 수와 보유 시간이 바뀔 때 목록 이동과 victim 출처가 어떻게 변하는지 관측해야 원제의 `victimize pattern`을 설명할 수 있다. 모든 unfix가 목록을 이동하거나, private LRU의 후보 수가 즉시 사용 가능한 victim 수와 같다고 전제해서는 안 된다. 구체적 조건은 아래 소스 근거와 같다.

### 왜 해결해야 하는가

부모 이슈에서 Daehyun Kim은 2026-08-06에 CBRD-27188·CBRD-27191 등 TPC-H 성능을 함께 고려하도록 요청했고, 2026-08-21에는 버퍼 매니저 유닛테스트 프레임워크와 부하·병목 시나리오 검토를 요청했다. 이는 조사 착수의 관련 배경이며, CBRD-27316의 성능 저하나 특정 구현안에 대한 합의는 아니다. [부모 댓글 4775680](https://jira.cubrid.org/browse/CBRD-27193?focusedCommentId=4775680&page=com.atlassian.jira.plugin.system.issuetabpanels:comment-tabpanel#comment-4775680), [부모 댓글 4775935](https://jira.cubrid.org/browse/CBRD-27193?focusedCommentId=4775935&page=com.atlassian.jira.plugin.system.issuetabpanels:comment-tabpanel#comment-4775935)

제목만 남겨 두면 인접한 quota·victim 정책 조사와 구별되는 산출물을 정하기 어렵다. 기존 동작을 기준으로 작업 문맥, 목록 배치, victim 출처와 비용의 관계를 남기면 변경 필요성을 판단하고, 필요할 때 근거가 있는 좁은 후속 과제로 연결할 수 있다. 조사 결과가 현행 유지여도 이 판단 근거를 남기는 것이 완료 결과다. 우선순위와 착수 긴급성을 뒷받침하는 실행 결과는 현재 없다.

## Evidence

소스 분석 기준은 CUBRID `f6cac312310f39f46711693da157a08f0e725693`이다. 이는 이 설명에서 고정한 분석 기준이며, 특정 출시 버전의 영향이나 런타임 재현을 증명하지 않는다. 이 설명 작성 중 엔진 실행이나 벤치마크는 수행하지 않았다.

| 확인한 동작 | 조사에서 구별할 사항 | 근거 |
|---|---|---|
| 일반 unfix가 BCB의 전역 fix 수를 줄이고, 0이 되면 zone별 LRU 처리에 진입한다. 일반 배치·boost 경로에는 reader/writer 대기 여부도 관여한다. | worker 한 명의 unfix와 페이지 전체 사용 종료, 목록 유지와 실제 이동을 구별한다. | [전역 fix 수 감소](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L6633-L6674), [zone별 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L6676-L6801) |
| private→shared 판단은 현재 작업의 private LRU 인덱스가 BCB의 목록과 다른지, 또는 hot·age 조건을 충족하는지 확인한다. | 접근이 겹치는 작업들의 private 문맥과 마지막 unfix 시점이 배치에 어떻게 연결되는지 기록한다. | [이동 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L6960-L6991) |
| private quota는 활동량을 바탕으로 나누며, quota 초과 여부는 zone 조정과 victim 목록 등록에 사용된다. | 동시성 변화, 활동량, quota 변화와 실제 victim 선택을 연결하되 같은 현상으로 취급하지 않는다. | [quota 배분과 목록 등록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14380-L14423) |
| victim 탐색은 조건부 자기 private 탐색, 다른 private 탐색, shared 탐색을 수행하며, 실패 후 아직 탐색하지 않은 자기 목록을 quota 이하에서도 시도한다. | 성공한 victim의 출처와 각 단계의 실패·대기를 구별한다. | [탐색 경로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9070-L9194) |
| 후보가 있어도 dirty·flush·direct-victim 상태, fix·대기자, BCB mutex 획득과 재검증이 실제 선택을 제한한다. | 후보 개수, 스캔한 BCB 수, 거절 이유와 성공한 victim 수를 분리한다. | [제외 상태](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L253-L262), [fix·대기자 검사](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9220-L9265), [스캔과 재검증](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9360-L9408) |
| 빈 슬롯과 LRU 탐색으로 BCB를 얻지 못하면, flush 데몬을 사용할 수 있는 서버 경로는 direct victim을 기다린다. | page latch 대기, victim 검색 시간, 슬롯 할당 대기와 I/O를 별도 원인으로 기록한다. | [할당 경로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8190-L8279) |

2026-10-02 분석 문서는 실패한 victim 탐색, zone 조정, mutex 보유 시간과 할당 지연을 측정하고 이 이슈와 연계할 것을 권고했다. 해당 문서도 벤치마크를 실행하지 않은 제안이며, 당시 CUBRID 기준 `c63a3b993be552ef6ad3ce244c386d5081147958`과 세미나 기준 `f799e05d77d5300c6ea5753b4a6cc7caee6d8912`를 구분한다. 이 설명의 현재 동작 근거는 위 `f6cac312...` 소스를 직접 확인한 결과다. [분석 문서의 근거 범위](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/pgbuf/report-2026-10-02.md#L24-L35), [victim 측정 제안](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/pgbuf/report-2026-10-02.md#L155-L171)

## Investigation Scope

### 조사 질문과 필요한 결과

핵심 질문은 **동시 fix의 수·대상 페이지 겹침·보유 시간이 private/shared LRU 배치 및 victim 출처를 어떻게 바꾸며, 관측된 비용이 어느 경로에서 발생하는가**다. ANALYSIS에서 원래 등록자의 동기와 대상 실행 경로를 확인한 뒤, 다음 범위의 최소 비교 부하와 판정 방법을 확정한다.

1. 실제 worker·세션·private LRU 인덱스의 대응을 기록한다. 같은 private 문맥을 공유하는 작업과 다른 문맥의 작업을 구별한다.
2. 상주 페이지 재사용 조건과 교체 압력이 있는 조건을 구분하여 단일 작업과 동시 작업을 비교한다. 페이지 집합의 겹침과 fix 보유 시간을 기록하고, 처리한 전체 작업량·페이지 수·버퍼 크기·초기 상태를 함께 남긴다. 읽기 중심 비교로 시작할지, dirty/flush 또는 vacuum을 포함할지는 대상 부하에 맞춰 결정한다.
3. 목록 유지·private→shared 이동, quota, victim의 목록 출처, 스캔 실패 이유와 슬롯 할당 대기를 연결한다. fix/unfix당 CPU·지연, LRU/BCB 경합, miss·I/O를 필요한 범위에서 분리하여 관측한다. 한 작업의 결과와 다른 세션의 진행·지연을 함께 기록한다.
4. 현행 유지, 추가 관측 필요, 별도 개선 과제 필요 중 어떤 결론을 뒷받침하는지 설명한다. 개선을 제안한다면 예상 이득과 함께 foreground·daemon 총비용, 메모리·계측 비용, miss 증가나 다른 세션의 지연 가능성을 평가한다. 이득이나 허용 한계의 수치는 측정 없이 확정하지 않는다.

기존 통계로 구별할 수 없는 항목은 필요한 관측 위치와 계측 비용을 조사 결과에 남긴다. 비활성·미수집 지표를 0으로 해석하지 않고, 상세 통계 활성화와 계측 유무가 비교에 미치는 차이를 기록한다. 실행 가능한 최소 시나리오, 비교 횟수·기간과 최종 판단 기준은 ANALYSIS 산출물이다.

### 인접 이슈와의 경계

| 이슈 | 해당 이슈가 결정할 범위 | 이 조사와 공유할 정보 |
|---|---|---|
| [CBRD-27211](https://jira.cubrid.org/browse/CBRD-27211) | high/low priority 큐 중 direct victim을 받을 **대기 스레드**를 선택하는 `my_count % 4` 정책 | victim 공급·탐색 비용과 수신자 선택 비용을 구분한 관측 결과 |
| [CBRD-27264](https://jira.cubrid.org/browse/CBRD-27264) | 도달하지 않는 direct-victim 예비 공급 경로의 처리와 CBRD-24029 중복 관계 정리 | 조사한 기준에서 실제 사용된 공급 경로와 할당 대기 조건 |
| [CBRD-27267](https://jira.cubrid.org/browse/CBRD-27267) | private LRU **인덱스** 큐의 초기 등록·승격·재공급 정책 | 부하별 victim 출처와 restricted 탐색의 관측 결과. 현재 소스에는 일반 private 큐에서 소비한 뒤 big-private 큐에 넣는 생산 경로가 있다. [소비와 생산](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16408-L16442) |
| [CBRD-27423](https://jira.cubrid.org/browse/CBRD-27423) | 공통 성능 분석·테스트·부하 프레임워크 | 이 조사에 필요한 최소 시나리오, 지표 정의와 재현 자료 |
| [CBRD-27252](https://jira.cubrid.org/browse/CBRD-27252) | default/v2 병행 버전 도입 전략 | 비교해야 할 교체 동작과 비용에 대한 근거 |

CBRD-27188의 quota 및 CBRD-27191의 LRU 비용 관련 검토와도 부하·관측 자료를 공유한다. 위 이슈의 수정이나 구현 전략을 이 조사의 완료 조건으로 두지 않는다. 관측한 결함은 해당 과제로 연결하고, 조사 자체는 선택 패턴과 비용 관계를 설명하는 결과로 평가한다.

## Specification Changes

현재 합의된 외부 동작 변경은 확인되지 않았다. 조사 결과는 동시 fix/private LRU/victim 관계의 설명과 후속 판단이다. 알고리즘, quota, 대기 정책, API 또는 병행 버전 변경의 필요성과 구체적 범위는 ANALYSIS 결과로 결정한다.

## Implementation

TBD - ANALYSIS 단계에서 결정한다.

## Acceptance Criteria

- 원제의 조사 동기와 대상 실행 경로를 확인하여 기록하거나, 확인할 수 없었던 내용과 제안 범위를 명시한다.
- 분석한 소스·빌드, worker/세션/private LRU 매핑, 부하·설정·초기 상태와 실행 방법을 다른 개발자가 확인할 수 있게 남긴다.
- 상주 재사용과 교체 압력이 있는 조건의 단일/동시 비교에서 목록 배치, victim 출처와 비용을 설명한다. 측정한 값, 소스에서 추론한 관계, 미관측 항목을 구분하고, 결과를 설명하지 못한 차이도 기록한다.
- 현행 유지 또는 후속 개선 필요 여부를 근거와 한계로 판단한다. 추가 조사가 필요하면 무엇을 확인해야 판단 가능한지 남기고 triage에서 후속 처리를 결정한다.
- 인접 이슈와 공유할 관측 결과 및 각 이슈가 결정할 범위를 기록한다. 특정 속도 향상이나 코드 변경을 조사 완료의 전제로 삼지 않는다.

## Definition of done

조사 질문, 재현 가능한 비교 자료, 결과의 해석과 한계, 후속 처리가 검토 가능한 보고서에 남아 있어야 한다. 계측을 추가했다면 활성화 조건과 계측 비용을 기록하고, 실행 결과 없이 소스 분석만으로 끝나는 경우에는 미측정 질문의 처리까지 triage에서 명시적으로 결정한다. 일반 QA 통과만으로 조사 질문에 대한 답을 대신하지 않는다.

## Triage Request

병렬 fix/private LRU/victim 패턴의 관계를 확인할 조사 과제로 범위를 확인하고, 작성자 측에 ANALYSIS 배정을 요청한다. 원래 조사 동기와 첫 대상 실행 경로를 확인한 뒤 최소 부하·관측 지표·판단 기준을 정한다. 담당·우선순위·후속 구현 여부는 triage와 ANALYSIS에서 결정한다.
