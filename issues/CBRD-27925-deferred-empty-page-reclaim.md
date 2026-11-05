# [OOS] LSA gate로 유예된 빈 페이지의 회수 재시도 경로 분석 및 보완

**한 줄 요약**: 삭제·rollback 뒤 빈 OOS 페이지가 반환되지 않는 진단을 바탕으로, LSA gate의 회수 유예와 CBRD-27944에서 추가한 READ 래치 경합 가설을 함께 조사하고 안전한 회수 재시도를 보완한다.

## Issue Triage

**이슈 수행 목적**: 완전히 빈 OOS 데이터 페이지가 안전해진 뒤 파일 관리자로 반환되도록 한다. 지금 안전하게 회수 가능한 빈 페이지를 두고 불필요하게 새 섹터를 예약하지 않도록 한다.

**이슈 수행 이유**: 기존 churn·snapshot 진단은 빈 페이지의 LSA gate 거부를 확인했으나, 이후 재시도와 abort 잔여 두 페이지의 최종 판정을 확정하지 못했다. 추가 모델·소스 검토에서는 INSERT rollback과 1차 READ 검사 경합으로 재시도 표시가 사라질 수 있는 순서를 찾았다. 두 근거를 구분하여 같은 회수 재시도 문제 안에서 검증한다.

**영향**: 큰 값의 삽입·삭제·rollback을 반복할 때, 사용 중인 chunk가 줄어도 빈 OOS 페이지가 파일 관리자에 반환되지 않아 공간 반환 검증이 실패했다. 추가 공간 할당으로 이어질 가능성은 있으나 실제 발생 빈도와 디스크 증가량은 미확인이다. 한 성장 대조에서는 빈 페이지를 먼저 재사용했으므로 영구 누수나 모든 성장 경로의 위반으로 단정하지 않는다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

[OOS TODO CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978)의 Sub-task다. [CBRD-26659](https://jira.cubrid.org/browse/CBRD-26659)의 회수 검증 실패를 조사하고, [CBRD-27944](https://jira.cubrid.org/browse/CBRD-27944)의 추가 가설과 검증 조건을 이 이슈에서 함께 추적한다.

OOS는 큰 값을 별도 데이터 페이지의 chunk에 저장한다. 마지막 chunk를 지워 페이지가 비어도, rollback이 그 페이지를 다시 필요로 할 수 있어 바로 반환할 수는 없다. LSA gate는 페이지의 로그 위치인 page LSA를 안전 기준인 horizon과 비교하여 반환 가능 여부를 판단한다. 안전하지 않으면 회수를 유예한다.

`sweep`은 파일 안의 페이지를 순회하며 회수 가능한 빈 페이지를 찾는 검사다. `pending_deletes`는 실제 빈 페이지 목록이 아니라, 삭제 뒤 이 검사를 다시 시작하게 하는 파일별 메모리 힌트다. 조사의 핵심은 안전 검사를 통과하지 못했거나 래치 경합으로 확인하지 못한 페이지를 이후 다시 방문할 수 있는지다.

## Native Observations

기존 실제 DB 진단 기준은 Engine `e3589ae42d42b04eb020e1ae43e165b01d31b12a`, TC `01df2600ac75180812451462b5c044cfa56b732a`다. 원래 FAIL은 `churn_abort_retry`, `churn_insert_delete`, `churn_insert_update_delete`, `churn_restart`, `snapshots_reclaim`의 다섯 건이다. [원본 진단 보고서](https://github.com/vimkim/my-cubrid-docs/blob/0c5c05f713ca1953725743b865c7d3c14bd1272f/cbrd-26659/reclaim-compact-diagnosis.md)에 관측과 한계가 있다.

- IUD 191개, restart 89개, snapshots 5+15개, insert/delete 20개의 빈 페이지를 진단별 동일 VPID·raw page LSA의 gate 거부와 연결했다. 이 진단 결과를 과거 모든 실패의 원인으로 소급하지 않는다.
- Abort a11의 빈 11개 중 9개만 gate 거부와 연결했다. 남은 `1|1312`, `1|1313`은 a15에서 rollback undo callback과 성장 sweep 진입을 관측했다. 진입 horizon은 `182|14448`이었다. 이후 채취한 raw page LSA는 각각 `182|14640`, `182|14576`으로 더 컸지만, 진입 시 page LSA·래치 상태·최종 reclaim enum을 함께 기록하지 못했다.
- 별도 성장 대조에서는 재시작·barrier 뒤 140회 INSERT가 기존 빈 20개 VPID를 새 섹터 live page보다 먼저 재사용했다. 이 결과는 해당 실행의 재사용 순서만 증명한다. 모든 성장의 회수 판정이나 결국 반환된다는 보장을 증명하지 않는다.

관측된 20초 내 반환 실패는 명세가 20초 반환을 보장한다는 뜻이 아니다. 또한 위의 잔여 두 페이지가 아래 READ 경합 순서를 실제로 겪었다는 증거는 없다.

## Source and Model Evidence

### 기존 LSA 유예 경로

기존 기준의 [horizon 채취](https://github.com/CUBRID/cubrid/blob/e3589ae42d42b04eb020e1ae43e165b01d31b12a/src/storage/oos_file.cpp#L1439)는 active transaction·system tdes의 최소 head와 scan 전 append 위치에 의한 상한으로 정한다. [회수 gate](https://github.com/CUBRID/cubrid/blob/e3589ae42d42b04eb020e1ae43e165b01d31b12a/src/storage/oos_file.cpp#L1512)는 page LSA와 안전 조건을 재검사한다. Fast path는 rollback equality 예외를 사용하지 않는다.

Horizon이 전진하는 것만으로 유예 batch의 재시도가 보장되지는 않는다. 후속 sweep은 [해당 OOS 파일의 페이지 할당 지점](https://github.com/CUBRID/cubrid/blob/e3589ae42d42b04eb020e1ae43e165b01d31b12a/src/storage/oos_file.cpp#L2006)에 의존한다. 다른 테이블에 로그를 만드는 작업이나 반복 SHOW도 해당 파일의 재시도를 보장하지 않는다.

### 추가한 INSERT rollback·READ 경합 가설

2026-11-04부터 11-05까지의 모델·추출 소스 실행은 `f67f2f692a7ad9f9efada2178759ca713e596b9d`를 기준으로 한다. [삭제 알림](https://github.com/CUBRID/cubrid/blob/f67f2f692a7ad9f9efada2178759ca713e596b9d/src/storage/oos_file.cpp#L3658-L3680), [1차 READ 검사](https://github.com/CUBRID/cubrid/blob/f67f2f692a7ad9f9efada2178759ca713e596b9d/src/storage/oos_file.cpp#L1587-L1611), [한 바퀴 종료 후 정산](https://github.com/CUBRID/cubrid/blob/f67f2f692a7ad9f9efada2178759ca713e596b9d/src/storage/oos_file.cpp#L1790-L1807)을 연결한 후보 순서는 다음과 같다.

1. INSERT undo가 페이지의 마지막 chunk를 삭제하고, 페이지 WRITE 래치를 유지한 채 삭제를 알린다.
2. 성장 sweep이 알림 건수를 저장한 뒤 그 페이지의 조건부 READ 획득에 실패한다. 1차 READ 실패는 LSA 검사에 도달하기 전에 `SKIPPED`로 끝나므로 유예 건수에 포함되지 않는다.
3. Rollback이 래치를 해제하고 끝난다. Sweep은 나머지 페이지를 검사하고 한 바퀴를 마친다.
4. 다른 알림·유예·앞선 회수 성공이 없는 조건에서, 정산이 시작 건수를 차감하여 `pending_deletes=0`, `swept_this_boot=true`로 만든다. 다음 성장 호출이 회수 검사를 생략하는 모델 경로가 있다.

TLA+ 모델 범위는 파일 1개, 데이터 페이지 2개, 각 1회 호출하는 sweep 호출자 2개, 한 번의 단일 페이지 삭제다. `NoLostHint`는 삭제가 끝나고 sweep이 없는 때 빈 페이지의 재검사 표시가 남는지 검사한다. 최단 반례는 11개 전이다. 후속 성장 호출의 검사 생략을 확인하는 `NoSkippedEmptyGrowth`도 별도로 실패했다. 일반 삭제와 부팅 뒤 첫 검사 대조군은 해당 유한 범위에서 통과했다. 이는 임의의 실행 순서에서 결국 회수된다는 증명은 아니다.

추출 소스 실행은 페이지 검색, 선택적 bestspace 보충, sweep, 정산, undo callback과 할당 호출을 연결했다. 트랜잭션 관리자·페이지 버퍼·bitmap 수집·파일 할당 의존 함수는 대체했다. Bestspace는 여유 공간이 있는 페이지를 찾기 위한 캐시·힌트다. 표본 검색이 빈 페이지를 다시 찾는 대조군에서는 추가 할당을 피했다. Rollback이 WRITE를 해제하고 끝난 뒤 sweep을 시작한 대조군도 회수·재사용했다. 이 결과는 실제 서버·SQL 재현이나 실제 섹터 증가 측정값이 아니다.

### 현재 비교 브랜치와 과거 수리의 구분

2026-11-05 소스 비교 대상인 `feature/oos-merge`의 `d52b1889e907abcf84190ec504dde3bc93de260d`에도 [undo의 삭제 알림](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/oos_file.cpp#L3649-L3673), [1차 READ 실패의 SKIPPED 처리](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/oos_file.cpp#L1570-L1604), [시작 건수 차감](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/oos_file.cpp#L1777-L1798)이 남아 있다. [2차 WRITE 획득 실패](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/oos_file.cpp#L1621-L1631)는 `DEFERRED`를 반환한다. 따라서 이번 1차 READ 가설을 [CBRD-26786](https://jira.cubrid.org/browse/CBRD-26786)의 과거 2차 WRITE 실패 수리와 같은 것으로 취급하지 않는다.

`f67f2f6` 이후 bestspace 검색의 임시 zero-wait 설정이 제거되어 진입 시점과 재발견에 영향을 줄 수 있다. 핵심 경로가 남았다는 사실만으로 이전 추출 실행을 `d52b188`의 전체 실행 증거로 사용할 수 없다. 비교한 develop `be0a9ab1fd83daa509f5ca53dcc03f6c3cbea16d`에는 해당 OOS 파일·상태·경로가 없었다. 이 결과는 develop의 다른 공간 재사용 결함까지 부정하지 않는다.

## Open Questions

- Horizon을 실제로 제한한 입력은 아직 특정하지 못했다. Sampling 뒤 채취한 active-head 목록만으로 공급자를 특정하지 않는다. 최소 LSA scan이 제외하는 system index 0과 대상이 불일치한 source line probe 자료는 원인 증거에서 제외한다.
- 최신 수정 대상에서 READ 경합 순서가 실제 SQL로 도달 가능한지, bestspace 재발견을 거쳐도 추가 할당에 이르는지 확인해야 한다. 원래 잔여 두 페이지의 판정과 새 가설의 성립 여부는 각각 검증한다.
- Horizon 전진 뒤 추가 쓰기가 없는 경우, 재할당·재시작·오류가 있는 경우에 무엇이 재방문을 보장하는지 확인해야 한다. LSA 안전 gate를 유지하면서 필요한 보완과 구현 범위를 정한다.

## Acceptance Criteria

- [ ] 팀장에게 실제 DB 재현의 목적·환경·실행 범위를 승인받고 근거를 기록한다. 승인 전 서버·DB를 이용한 재현에 착수하지 않는다.
- [ ] 승인 후 최신 수정 대상 revision·설정·재현 범위를 고정하고, CBRD-26659의 원래 다섯 FAIL을 보존하여 비교한다.
- [ ] Sampling 시점의 pre-scan append, 실제 scan 대상 transaction·system head와 선택된 최소값을 함께 기록해 horizon 공급자를 특정한다.
- [ ] Abort 잔여 두 페이지의 진입 시 page LSA·emptiness·래치 상태와 최종 `RECLAIMED`·`DEFERRED`·`SKIPPED` 결과를 동일 호출에 연결한다.
- [ ] 추가 가설은 삭제 알림, sweep 시작 건수 snapshot, 1차 READ 결과, 한 바퀴 정산을 같은 sweep 호출로 연결하고 후속 재시도까지 추적하여 확인하거나 기각한다. 2차 WRITE 실패와 구분한다.
- [ ] 일반 삭제·부팅 뒤 첫 검사·경합 없는 rollback·bestspace 표본 재발견을 대조한다. 부분 여유 공간 재사용, 파일 관리자 반환, 새 섹터 예약을 구분하여 실제 영향을 기록한다.
- [ ] 추가 쓰기 유무와 재할당·재시작·오류별 재방문을 확인한다. 결국 안전하게 반환되도록 필요한 보완을 구현·검증하고, 회수 전 undo 안전성·생존 값과 성장 전 재사용을 각각 검증한다. Timeout 증가만으로 완료하지 않는다.
- [ ] 수정 및 검증 결과를 CBRD-26659에 연결하고, 진행 중인 회수 설계 개정과 정합성을 확인한다.

## Related Work

Resolved 상태의 CBRD-26786이 다룬 회수 불변식의 후속이다. [CBRD-27213](https://jira.cubrid.org/browse/CBRD-27213)의 부분 여유 공간 bestspace 재설계, [CBRD-27872](https://jira.cubrid.org/browse/CBRD-27872)의 할당 시 회수 검사 비용과 범위를 구분하되 변경이 겹치면 함께 검증한다.

[CBRD-27945](https://jira.cubrid.org/browse/CBRD-27945)는 메타데이터 full table 포화와 재귀 섹터 예약 시점의 별도 OOS 조사로 유지한다. 회수 힌트가 남아 있어도 성립하는 모델이므로 이번 READ 경합 가설을 해결하거나 기각해도 그 검증을 대신하지 않는다.
