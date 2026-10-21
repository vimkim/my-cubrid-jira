# [PGBUF] 페이지 버퍼의 정확성·운영성·성능을 개선한다

## Issue Triage

**이슈 수행 목적**: 페이지 버퍼의 사용·보호 회계와 오류 후 진행을 일관되게 유지하고, 페이지 상태와 처리 비용을 관측하여 필요한 기능 및 성능 개선을 검증할 수 있게 한다.

**이슈 수행 이유**: 현재 소스에 fix·보호·로딩 기록의 소유권 불일치, flush 실패 정리 누락과 실행되지 않는 예비 공급 경로가 남아 있다. 과거 직접 API 검증과 개발자 댓글에도 회계 오류 및 debug 서버 중단이 보고되었다. 설정·진단·성능 비교의 공백을 함께 다루되, 독립적으로 판단할 수 있는 문제는 각 하위 과제로 처리해야 한다.

**영향**: 해당 조건을 사용하는 엔진 작업의 페이지 접근 보호, 오류 복구와 진행에 영향을 줄 수 있으며, 개발자·QA·운영자의 상태 진단과 변경 효과 판단도 어렵게 한다. 과거 실행 보고와 현재 소스에서 도출한 위험을 구분한다. 현재 기준 빌드의 운영 장애, 데이터 손상, 발생 빈도와 전체 영향 릴리스는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다. 하위 과제별로 필요한 결과와 검증·종료 판단을 관리하며, 이미 기록된 기능 결정은 해당 근거와 함께 유지한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

페이지 버퍼는 디스크 페이지를 메모리 슬롯에 보관하고 접근, 교체와 flush를 관리한다. BCB(Buffer Control Block)는 슬롯의 상주 페이지와 사용 수·latch·dirty 상태 등을 담는 제어 정보이고, VPID는 볼륨 번호와 페이지 번호의 식별자다. fix/unfix는 페이지의 상주 사용을 등록·반환하는 회계이며, page latch는 메모리 페이지 접근을 조정한다. 트랜잭션의 논리 접근을 조정하는 transaction lock과는 목적과 수명이 다르다. dirty는 페이지 변경을 추적하는 상태이고 LSA(Log Sequence Address)는 로그 내 위치다. flush 진행, 파일 기록, 페이지 교체와 transaction commit은 서로 다른 사건이다. [BCB와 holder 정의][S1]

LRU(Least Recently Used)는 페이지 사용 이력을 바탕으로 관리하는 교체 목록이며 shared/private 영역으로 나뉜다. direct victim은 슬롯을 기다리는 스레드에 재사용 가능한 BCB를 직접 넘기는 기존 장치다. 대기 스레드의 우선 선택과 LRU 후보의 발견·공급은 서로 다른 단계다.

이 모듈에서는 성공한 사용의 계수, 페이지를 잠시 놓는 동안의 회수 방지, 로딩 중인 페이지의 소유권, 실패한 flush의 정리와 대기자 진행이 서로 맞아야 한다. 현재 분석 기준에는 다음과 같이 그 대응이 어긋나는 구체적 경로가 있다.

- `OLD_PAGE_PREVENT_DEALLOC`의 빠른 READ fix는 보호 등록을 건너뛰고 공통 해제에 도달한다. 일반 중첩 READ-to-WRITE fix는 BCB 수를 1로 저장하면서 스레드 holder 수를 늘린다. 두 문제는 각각 회수 방지 보호와 미반환 fix 수라는 다른 회계를 다룬다. [보호 등록·해제][S2], [중첩 승격과 holder 증가][S3]
- TDE 암호화 또는 DWB 준비가 오류를 반환하면 flushing 상태를 되돌리는 정규 실패 처리를 거치지 않는다. 첫 준비와 재시도에서는 LSA 이동 단계도 다르므로 실패 시점에 맞는 정리가 필요하다. TDE는 데이터 페이지 암호화이며 DWB는 원래 위치 쓰기 전에 별도 사본을 기록하는 보호 장치다. [flush 준비·재시도·실패 처리][S4]
- `pgbuf_simple_fix`의 일부 로딩 실패는 helper와 호출자에서 연속으로 기록을 제거한다. VPID만으로 제거하는 연산 사이에 소유자가 바뀌면 다른 요청의 기록까지 제거할 수 있다는 소스 기반 위험이 있다. 실제 엔진의 같은 VPID 동시 호출·실패·교차 실행은 확인해야 한다. [호출자 정리][S5], [helper 실패 정리][S6], [제거 조건][S7]

설정과 진단에도 별도의 공백이 있다. 크기를 나타내는 `double_write_buffer_size`에는 단위 문법이 없고, 추가 진단 코드에는 현행 자료구조와 맞지 않는 참조가 남아 있다. 풀 집계만으로 특정 VPID의 상태를 관찰할 수도 없다. 성능 조사는 실제 엔진의 같은 작업을 비교하면서 foreground, 데몬, 교체·I/O 비용을 구분할 수 있어야 한다. 각 공백은 아래 하위 과제의 독립 결과로 다룬다.

### 왜 문제인가

사용·보호 회계가 어긋나면 호출자가 반환 의무를 지켜도 접근 보호가 일찍 끝나거나 회수 판단이 부정확해질 수 있다. 실패한 작업의 상태가 남으면 오류를 반환한 뒤에도 후속 작업이 진행하지 못할 가능성이 있다. 다만 정적 경로의 존재만으로 현재 SQL 장애나 데이터 손상을 확정할 수는 없다.

실행 근거도 구별해야 한다. CBRD-27370의 보존된 직접 API probe는 과거 SA 빌드에서 조기 latch 해제와 후속 unfix 오류를 기록한다. CBRD-27356의 2026-09-29 Il Han, Song 댓글은 두 debug 빌드에서 transaction zero-wait가 DROP TABLE commit/postpone의 예상 밖 page-fix 실패와 서버 abort로 이어졌다고 보고한다. 현재 소스에는 thread-local override와 국소 force-wait 보완도 있으므로, 과거 보고가 현재 어느 경로에 적용되는지 다시 판별해야 한다. [과거 API 검증][H1], [개발자 중단 보고][C3], [현재 대기값 조회][S8]

관측 지표의 의미를 혼동하면 다른 원인도 같은 문제처럼 보인다. 현재 SHOW의 폐기된 9개 counter 컬럼은 NULL이며, statdump의 `Num_data_page_iowrites`는 DWB 파일과 원위치 쓰기의 페이지 단위 집계를 포함한다. 이를 작업량 0, syscall 수, 고유한 논리 flush 수 또는 고정 2배 관계로 읽으면 설정·정책·구현의 효과를 잘못 비교할 수 있다. [현재 SHOW 계약][S9], [DWB 집계 지점][S10]

### 왜 해결해야 하는가

이러한 불일치는 페이지 버퍼 호출부가 의존할 성공·실패 계약을 불명확하게 하고, 장애 원인과 성능 비용을 분리하는 작업을 어렵게 한다. 사용자 설정 변경, 개별 호출부의 우회 또는 새 구현 도입만으로 서로 다른 소유권·정리 문제와 진단 공백이 함께 해소되지는 않는다. 현재 소스의 구체적 근거와 과거 실행 보고를 출발점으로, 필요한 수정과 기능을 좁혀 검증할 이유가 있다. 긴급도와 처리 순서를 일괄 확정할 근거는 아직 부족하다.

부모 과제는 이 결과를 연결한다. 독립 결함의 처리를 장기 설계와 공통 도구 완성까지 미루지 않고, 반대로 조사 제안을 승인된 구현으로 취급하지 않는다. 각 과제에서 유지할 계약, 확인한 영향, 선택한 조치와 남은 일을 명시해야 전체 개선의 완료 여부를 판단할 수 있다.

## Scope and Outcomes

2026-10-21 계층 조회에서 본 이슈와 직속 Sub-task 19개를 확인했으며 더 아래 자식은 없다. 실제 부모 유형은 `Development Subject`다. 기존 제목의 EPIC은 여러 페이지 버퍼 과제를 묶은 명칭으로 사용한다. 아래 표는 번호순 범위이며 우선순위·담당 확정 목록은 아니다. [현재 상위 이슈](https://jira.cubrid.org/browse/CBRD-27193)

| 하위 이슈 | 필요한 결과와 책임 경계 | 판정할 사항 |
|---|---|---|
| [CBRD-27194](https://jira.cubrid.org/browse/CBRD-27194) | 초기화·부분 실패·종료에서 확보한 자원만 정리하고 private LRU 0개를 유효한 빈 구성으로 처리한다. | 교체된 페이지 식별자 이력인 AOUT의 활성 경로, 상위 호출자의 추가 정리와 서버/SA 수명을 구분한다. 과거 크기 비교는 런타임 장애 증거가 아니다. |
| [CBRD-27196](https://jira.cubrid.org/browse/CBRD-27196) | 현재 B-tree split/merge에서 SX latch의 필요성·이득·비용과 적용 범위를 조사한다. | 재시작·읽기 차단 비용을 확인하여 도입·보류·미도입을 권고한다. 현행 snapshot flush의 정확성이 SX를 요구한다는 전제는 두지 않는다. |
| [CBRD-27211](https://jira.cubrid.org/browse/CBRD-27211) | direct victim을 받을 high/low priority **대기 스레드 선택**의 전역 `my_count % 4` 주기를 평가한다. | 선택 비용과 큐별 대기를 분리하여 유지/변경을 판단한다. 호출 주기는 실제 배정 비율이나 최대 대기시간 보장이 아니다. |
| [CBRD-27252](https://jira.cubrid.org/browse/CBRD-27252) | default/v2 병행 유지·선택·비교·복귀 전략과 검증·유지보수 경계를 정한다. | 제품 도입 여부와 초기 범위는 분석한다. 학습용 M0~M8을 승인된 제품 v2 설계로 승계하지 않는다. |
| [CBRD-27262](https://jira.cubrid.org/browse/CBRD-27262) | flush 준비 실패 후 변경 추적과 후속 flush·대기자의 진행을 복구한다. | 첫 준비/재시도, 실제 오류/주입 실패를 구분한다. DWB read의 정상 구현은 NO_ERROR만 반환하므로 방어 분기의 운영 도달성을 별도로 판정한다. |
| [CBRD-27263](https://jira.cubrid.org/browse/CBRD-27263) | 요청 페이지 dealloc 보호의 등록·해제 소유권을 빠른·일반·재정렬 경로에서 맞춘다. | 실제 원자 갱신과 같은 BCB 상주 기간을 추적한다. 과거 VPID 합계로 정확한 타 요청 보호 소실 횟수나 영구 회수 불가를 단정하지 않는다. |
| [CBRD-27264](https://jira.cubrid.org/browse/CBRD-27264) | 실행되지 않는 direct-victim 예비 공급 경로와 저활동 대기자의 진행 책임을 처리한다. | 기존 중복 대상 CBRD-24029와 단일 수정·결과의 기록 책임을 조정한다. 복원 또는 대체 경로에 근거한 제거를 판단한다. |
| [CBRD-27265](https://jira.cubrid.org/browse/CBRD-27265) | 추가 `CUBRID_DEBUG` 진단의 컴파일 불일치와 TDE 보상 복구 로그의 미초기화 VPID 읽기, 두 결함을 처리한다. | 일반 Debug와 조건을 구별한다. 진단 재활성화는 컴파일 외 안전성·런타임 검토도 필요하며 추가 발견의 포함/후속 분리를 결정한다. |
| [CBRD-27266](https://jira.cubrid.org/browse/CBRD-27266) | 논리 페이지 처리·파일 기록량·읽기·victim 후보의 정의와 수집 조건을 정리한다. | 기존 SHOW NULL 계약과 소비자 호환성을 보존하고, 설명·설정으로 충분한 부분과 관측 기능 변경을 구분한다. |
| [CBRD-27267](https://jira.cubrid.org/browse/CBRD-27267) | big private victim queue의 초기 등록·재등록·제한 소비 정책을 조사한다. | 일반 private 큐 소비 후 big 큐 생산 경로가 존재한다. 현행 유지/변경을 부하 근거로 판단하며 죽은 큐 삭제로 처리하지 않는다. |
| [CBRD-27268](https://jira.cubrid.org/browse/CBRD-27268) | `double_write_buffer_size`에 `512K`, `2M` 입력을 지원하며 바이트 정수·0·범위·크기 보정 의미를 보존한다. | 파서·타입·출력·전달 호환성을 정한다. 현재 재현 설정에는 바이트 정수를 쓰며, 출력값과 실제 적용 크기를 구분한다. |
| [CBRD-27269](https://jira.cubrid.org/browse/CBRD-27269) | 확인한 9개 낡은 주석·미사용 코드 항목군을 의도한 동작을 보존하며 정리한다. | 항목별 정리/유지 근거를 남긴다. 예비 공급과 big 큐의 미결 정책을 자동 삭제 범위로 흡수하지 않는다. |
| [CBRD-27270](https://jira.cubrid.org/browse/CBRD-27270) | 복구·종료 중 임시 볼륨 판정과 실제 페이지 접근의 안전성을 조사한다. | 생성자·boot manager 재사용·마운트 수명, 영구 형식/임시 용도 메타데이터와 LSA 마커를 구분한다. 암호화 payload의 실제 피해는 미확인이다. |
| [CBRD-27316](https://jira.cubrid.org/browse/CBRD-27316) | 동시 fix/unfix, private/shared LRU 배치와 victim 출처·비용의 관계를 조사한다. | 재작성 전 2026-10-21 스냅샷에는 본문·댓글이 없어 동기는 미확인이다. 제목과 현재 코드에 근거한 한정 조사 제안으로 범위를 확인한다. |
| [CBRD-27356](https://jira.cubrid.org/browse/CBRD-27356) | transaction lock 설정과 page latch 획득·대기·실패 계약의 결합 및 보고된 debug 중단을 처리한다. | 현재 override·force-wait·거절 오류 분류를 반영하고 의도한 nonblocking 호출을 보존한다. 현재 debug/release 재현과 정책 선택은 분석한다. |
| [CBRD-27370](https://jira.cubrid.org/browse/CBRD-27370) | 일반 중첩 READ-to-WRITE fix의 BCB/holder 회계를 일치시킨다. | 일반 승격의 허용/거부 계약과 실제 호출부를 확인한다. 과거 SA probe와 현재 SQL 도달성을 구분한다. |
| [CBRD-27398](https://jira.cubrid.org/browse/CBRD-27398) | Volmap용 선택적 읽기 전용 페이지 상태 인터페이스를 제공한다. | 기록된 state-only v1와 후속 개정을 유지하며 Draft 구현·소비자 계약·release 검증의 차이를 해소한다. |
| [CBRD-27423](https://jira.cubrid.org/browse/CBRD-27423) | 실제 엔진의 같은 작업으로 변경 전후를 재현·비교할 성능 분석 프레임워크와 검증 경계를 정한다. | 첫 부하·자산·지표·실행 능력을 정하고 구현을 분리하면 미완료 능력과 후속 과제를 남긴다. 도구·수치·일일 CI는 미확정이다. |
| [CBRD-27630](https://jira.cubrid.org/browse/CBRD-27630) | simple-fix 실패 정리가 다른 요청의 로딩 기록과 대기를 보존하게 한다. | 소스·Lean 모델의 조건부 반례와 실제 엔진의 동일 임시 VPID cold miss·오류·스케줄 도달성을 구분한다. |

## Evidence and Constraints

### 현재 기준과 과거 결과

현재 동작의 공통 소스 기준은 CUBRID `f6cac312310f39f46711693da157a08f0e725693`이다. 이는 고정 분석 기준이며 모든 출시 버전이나 원격 최신 소스를 뜻하지 않는다. 이 부모 보고서 작성에서 엔진 빌드·오류 주입·부하 시험·벤치마크·Lean 검증을 새로 실행하지 않았다. 하위 과제는 과거 결과의 실제 빌드와 현재 소스 확인을 분리하고, 적용 릴리스와 자연 발생 조건을 별도로 판정한다.

소스로 확인한 예비 공급 순회의 미실행과 big 큐 정책을 혼동하지 않는다. 전자는 시작 인덱스와 첫 조건이 모순되지만, 후자는 일반 private 소비 후 big 등록과 이후 재등록이 가능하다. CBRD-24029는 기존 Develop 상태의 중복 관련 이슈이며 직속 자식이 아니다. 한 번의 수정을 두 개의 독립 수정 약속으로 계산하지 않는다. [예비 순회][S11], [big 큐 소비·생산][S12], [기존 중복 이슈](https://jira.cubrid.org/browse/CBRD-24029)

복구 중 temp 판정도 단순한 가드 오류로 결론내리지 않는다. 로그 상태는 생성자에서 recovery analysis로 시작하며, bootstrap은 임시 voltype 볼륨을 건너뛴다. 영구 형식·임시 용도 볼륨의 헤더·할당 맵 접근과 명시적 임시 LSA 설정은 존재한다. 이 사실은 모든 temp 처리가 사라진다는 주장을 정정하지만, 암호화된 임시 데이터의 기록·재독출 안전성을 대신 증명하지 않는다. [초기 상태][S13], [마운트 범위][S14], [메타데이터 접근][S15], [마커 설정][S16]

### 보존할 개발자 요청과 기능 결정

Daehyun Kim은 2026-08-06 댓글에서 [CBRD-27188](https://jira.cubrid.org/browse/CBRD-27188)·[CBRD-27191](https://jira.cubrid.org/browse/CBRD-27191) 등 TPC-H 성능을 함께 고려하도록 요청했다. 2026-08-21에는 버퍼 매니저 유닛테스트 프레임워크와 부하·병목 지점 및 시나리오 검토를 요청했다. CBRD-27423과 관련 정책 조사는 해당 부하의 실행 가능성·대표성과 필요한 집중 검증을 평가하여 채택 또는 보류 근거를 남긴다. 이 댓글들은 측정 결과나 특정 프레임워크 채택 결정이 아니다. [TPC-H 요청][C1], [테스트·병목 조사 요청][C2]

CBRD-27398에는 별도의 기록된 결정이 있다. 기본 off·시작 시점 전용 활성화, 로컬 Unix stream socket, 의미값을 제공하는 제한된 resident-set scan과 Volmap의 별도 관찰 책임을 유지한다. 후속 전송량·HTTP·표시 범위·브라우저 예산 개정도 해당 계약에서 관리한다. 원래 수락한 순회 경과 한계 100ms와 Draft PR #7940의 1,500ms는 아직 일치하지 않는다. scan 시작 간격과도 다른 값이므로 명시적으로 해결해야 한다. 이 Draft를 develop에 채택된 기능으로 취급하지 않는다. [활성화 결정][H6], [wire 결정][H7], [후속 소비자 계약][H2], [원래 순회 예산][H3], [Draft 상수][H4]

## Specification Changes

부모의 요구 결과는 페이지 버퍼의 정확성·진행·관측·비교 능력을 개선하고, 각 하위 과제의 결과를 근거와 함께 확인하는 것이다. 구체 API, 대기 정책, 교체 알고리즘과 구현 범위는 해당 과제의 ANALYSIS에서 결정한다. 설정·지표·진단 인터페이스가 바뀌면 기존 사용자·도구와의 호환 요구도 그 변경의 일부로 확인한다.

SX 채택, 제품 v2 전면 재작성, 특정 timeout·벤치마크 도구와 성능 목표값은 공통 확정 사양이 아니다. 기존 M0~M8은 엔진 통합과 성능 동등성을 비목표로 둔 학습 제안이다. 과거 prefetch/AIO·hash 크기·dirty index 아이디어도 현재 19개 자식과 별개인 검토 자료이며, 필요성이 확인되면 후속 범위를 별도로 판단한다. [학습 계획의 목표·비목표][H5]

## Implementation

TBD - ANALYSIS 단계에서 결정한다.

### 조율할 책임과 정보

- CBRD-27211의 대기자 선택, CBRD-27264의 예비 공급, CBRD-27267의 private LRU 인덱스 큐 정책은 부하 정보를 공유하되 각각 판단한다. CBRD-27316은 이를 흡수하지 않고 동시 접근·배치·victim 비용 관계를 설명한다.
- CBRD-27263의 회수 방지 보호, CBRD-27370의 미반환 fix 회계, CBRD-27630의 로딩 기록은 다른 소유권이다. 오류·timeout 경로의 관찰을 공유하되 한 정책 선택을 다른 회계 수정의 선행 조건으로 두지 않는다.
- CBRD-27262에서 읽기 방어 분기의 정리를 변경하면 CBRD-27630과 helper/호출자 책임을 조율한다. CBRD-27265의 추가 진단은 재활성화 안전성과 새 발견의 처리 범위를 별도로 결정한다. 컴파일 성공만으로 진단 전체의 안전성을 판정하지 않는다.
- CBRD-27266·27423은 공통 지표·부하·실행 신원을 제공할 수 있다. 특정 결과에 실제 필요한 기능이 없을 때 그 능력과 한계를 명시한다. 공통 프레임워크 전체, SX, v2 또는 timeout 조사의 완료를 일괄 관문으로 만들지 않는다. 같은 함수·파일을 수정한다는 이유만으로 병합 순서도 확정하지 않는다.

### 종료 판단

결함·기능 과제는 합의한 계약에 맞는 결과와 검증을 남긴다. 조사 과제는 변경 권고, 현행 유지·미도입, 확인 범위에서 기능 결함 없음, 또는 구체적 증거 부족에 따른 보류로 결론낼 수 있다. 보류는 해결과 구분하고 남은 질문·재검토 조건·후속 처리 결정을 명시한다. 구현을 분리하면 요청된 능력이 아직 미완료임을 표시하고 연결 과제와 완료 책임을 남긴다.

부모를 종료할 때는 19개 모두의 결과 또는 승인된 처리 결정을 확인한다. 중복 과제는 단일 결과를 연결하고, 미해결 문제를 옮겼다면 수용된 후속 범위와 추적 위치를 남긴다. 조사 종료나 후속 이관만으로 결함이 수정되었거나 기능이 구현되었다고 보고하지 않는다.

## Acceptance Criteria

- [ ] 19개 하위 과제 각각의 문제·요구 결과·책임 경계와 분석 결과 또는 남은 질문이 추적된다. 중복과 실제 선행 조건은 근거와 함께 구분된다.
- [ ] 소스 관찰, 과거 실행 보고, 오류 주입, 모델 반례와 현재 엔진 검증을 구분한다. 영향·재현 범위와 미확인 릴리스를 해당 근거로 설명한다.
- [ ] 구현한 변경은 선택한 계약에 맞는 상태·회계·진행 또는 기능 결과를 보여 주며, 변경의 영향을 받는 호출부·설정·소비자와 회귀 범위를 검증한다.
- [ ] 성능 판단에는 실제 수행한 동일 작업, 빌드·환경·계측 조건과 원시 결과를 연결한다. NULL·미수집·비활성을 작업량 0으로 쓰거나 국소 비용 감소를 전체 개선으로 일반화하지 않는다.
- [ ] TPC-H, 유닛테스트 기반과 병목 시나리오 요청의 평가 결과를 남긴다. 기존 기능 결정의 변경이나 미해결 계약 차이는 명시적으로 처리한다.
- [ ] 각 조사의 유지·미도입·결함 미확인·보류·후속 구현 판단과 그 한계를 기록한다. 부모 종료 시 모든 미완료 결과의 수용된 처리와 추적 위치가 확인된다.

## Definition of done

각 하위 과제의 검토 가능한 결과·검증·미확인 범위와 종료 판단을 부모에 연결한다. 실제 변경에 필요한 문서·설정·지표·소비자 호환 조치를 완료하고, 코드·기능 완료와 조사 완료·중복 연결·후속 이관을 구분하여 상태를 정리한다. 선택한 검증을 실행하지 못했거나 결과를 판정하지 못한 경우에는 그 사실과 승인된 후속 처리를 남긴다. 모든 제안의 구현이나 모든 부하의 벤치마크를 부모 완료의 일률 조건으로 요구하지 않는다.

## Triage Request

페이지 버퍼의 상태·소유권·진행 계약과 진단·비교 능력을 개선할 상위 과제로 문제와 19개 하위 범위를 확인하고, 작성자 측에 ANALYSIS 조율을 배정할 것을 요청한다. 각 하위 과제의 확인·담당·우선순위는 triage에서 결정한다. 분석에서는 현재 도달성과 영향, CBRD-24029와의 단일 수정 책임, 기존 기능 계약의 미해결 차이, 필요한 검증과 후속 처리를 명확히 한다. 이 요청은 전면 재작성이나 미선정 설계의 승인을 대신하지 않는다.

[S1]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L439-L522
[S2]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2266-L2469
[S3]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L6361-L6495
[S4]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10747-L10866
[S5]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2644-L2656
[S6]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8430-L8517
[S7]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8069-L8139
[S8]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16914-L16948
[S9]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L17422-L17488
[S10]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L2085-L2352
[S11]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9561-L9602
[S12]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16384-L16469
[S13]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_global.c#L49-L64
[S14]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/boot_sr.c#L1039-L1049
[S15]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/disk_manager.c#L2452-L2484
[S16]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/disk_manager.c#L4942-L5006
[H1]: https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/cbrd-27370/CBRD-27370-claim-verification-report_5f3a30d_claude.md#L56-L92
[H2]: https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/docs/runtime-page-buffer-observation.md
[H3]: https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/15-set-overlay-resource-budgets.md
[H4]: https://github.com/CUBRID/cubrid/blob/6bf4753eaa136fb87a4632deac44dc403ad0538e/src/storage/pgbuf_inspector_scan.hpp#L29-L33
[H5]: https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/pgbuf/e6ed61e_claude/08-page-buffer-new-plan.md#L1-L30
[H6]: https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/04-define-gating-matrix.md
[H7]: https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/05-define-wire-contract-v1.md
[C1]: https://jira.cubrid.org/browse/CBRD-27193?focusedCommentId=4775680&page=com.atlassian.jira.plugin.system.issuetabpanels:comment-tabpanel#comment-4775680
[C2]: https://jira.cubrid.org/browse/CBRD-27193?focusedCommentId=4775935&page=com.atlassian.jira.plugin.system.issuetabpanels:comment-tabpanel#comment-4775935
[C3]: https://jira.cubrid.org/browse/CBRD-27356?focusedCommentId=4776561&page=com.atlassian.jira.plugin.system.issuetabpanels:comment-tabpanel#comment-4776561
