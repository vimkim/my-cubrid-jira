# [OOS] LSA gate로 유예된 빈 페이지의 회수 재시도 경로 분석 및 보완

**한 줄 요약**: 빈 OOS 페이지가 안전 gate에서 유예된 뒤 반환되지 않는 재현을 분석하고, 안전한 eventual return에 필요한 회수 재시도 경로를 보완한다.

## Issue Triage

**이슈 수행 목적**: 완전히 빈 OOS 데이터 페이지가 결국 파일 관리자로 반환되고, 지금 안전하게 회수 가능한 빈 페이지를 두고 불필요하게 새 섹터를 예약하지 않도록 한다.

**이슈 수행 이유**: Engine `e3589ae42d42b04eb020e1ae43e165b01d31b12a`의 churn·snapshot 진단에서 빈 페이지의 LSA gate 거부를 실제 VPID·page LSA로 연결했다. Horizon 전진만으로 유예 batch의 재시도가 보장되지 않으며, 후속 sweep은 해당 OOS 파일의 페이지 할당 지점에 의존한다. Horizon을 제한한 실제 입력과 abort 잔여 두 페이지의 최종 판정은 미확정이다.

**영향**: 삭제·vacuum 뒤 chunk 수가 줄어도 빈 OOS 페이지가 파일 관리자에 반환되지 않아 공간 반환과 재사용의 검증이 실패한다. 관측된 20초 실패만으로 영구 누수나 모든 성장 경로의 위반을 확정하지 않는다. 한 성장 대조에서는 빈 20개 페이지가 새 섹터의 live page보다 먼저 재사용됐다.

**이슈 수행 방안**: Horizon 채취 입력과 회수 최종 결과를 함께 관측해 유예·재방문 경로를 확정하고 필요한 엔진 보완을 정한다. LSA 안전 gate와 eventual-return 요구를 유지한다. 재시도 방식과 구현 범위는 ANALYSIS 단계에서 결정한다.

---

## AI-Generated Context

## Description

[OOS TODO CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978)의 후속 작업이며, [CBRD-26659](https://jira.cubrid.org/browse/CBRD-26659)의 `churn_abort_retry`, `churn_insert_delete`, `churn_insert_update_delete`, `churn_restart`, `snapshots_reclaim`을 다룬다. 기준은 Engine `e3589ae42d42b04eb020e1ae43e165b01d31b12a`, TC `01df2600ac75180812451462b5c044cfa56b732a`다. 최신 수정 대상에서 같은 현상인지 먼저 확인한다.

## Observations

- IUD 191개, restart 89개, snapshots 5+15개, insert/delete 20개의 빈 페이지는 진단별 동일 VPID·raw page LSA의 gate 거부와 연결됐다. 이는 새 진단의 증거이며 과거 모든 실패에 대한 소급 증명은 아니다.
- Abort a11의 빈 11개 중 9개만 gate 거부와 연결됐다. 남은 `1|1312`, `1|1313`은 a15에서 rollback undo callback과 성장 sweep 진입을 관측했다. 진입 horizon `182|14448`보다 이후 raw page LSA `182|14640`, `182|14576`이 크지만, 진입 시 page LSA·latch 상태·최종 reclaim enum은 함께 기록하지 못했다.
- 별도 성장 대조에서 재시작·barrier 뒤 140회 INSERT가 기존 빈 20개 VPID를 새 섹터 live page보다 먼저 재사용했다. 이 결과는 해당 재사용 순서를 증명하며, 모든 성장의 회수 판정이나 일반적인 eventual return을 인증하지 않는다.

## Analysis

[Horizon sample](https://github.com/CUBRID/cubrid/blob/e3589ae42d42b04eb020e1ae43e165b01d31b12a/src/storage/oos_file.cpp#L1439)은 active transaction·system tdes의 최소 head와 pre-scan append clamp로 정한다. [회수 gate](https://github.com/CUBRID/cubrid/blob/e3589ae42d42b04eb020e1ae43e165b01d31b12a/src/storage/oos_file.cpp#L1512)는 page LSA와 안전 조건을 재검사한다. Fast path는 rollback equality 예외를 사용하지 않는다. 유예 뒤 [성장 지점](https://github.com/CUBRID/cubrid/blob/e3589ae42d42b04eb020e1ae43e165b01d31b12a/src/storage/oos_file.cpp#L2006) 외에 무엇이 재방문을 보장하는지 확인한다. 다른 테이블의 log filler와 반복 SHOW는 해당 파일의 재시도를 보장하지 않는다.

Sampling 뒤 채취한 active-head 목록만으로 horizon 공급자를 특정하지 않는다. 실제 최소 LSA scan이 제외하는 system index 0을 원인으로 쓰지 않는다. Source line probe의 대상 불일치 자료도 원인 증거에서 제외한다.

## Acceptance Criteria

- [ ] 최신 수정 대상 revision·설정·재현 범위를 고정하고 원래 다섯 FAIL을 보존한다.
- [ ] Sampling 시점의 pre-scan append, 실제 scan 대상 transaction·system head와 선택된 최소값을 함께 기록해 horizon 공급자를 특정한다.
- [ ] Abort 잔여 두 페이지의 진입 시 page LSA·emptiness·latch와 최종 reclaimed/deferred/skipped 결과를 동일 호출에 연결한다.
- [ ] Horizon 전진 뒤 추가 쓰기가 없는 경우와 재할당·재시작·오류가 있는 경우의 재방문을 구분한다. 안전한 eventual return에 필요한 보완을 구현·검증한다.
- [ ] 회수 전 undo 안전성과 생존 값, 파일 관리자 반환, 성장 전 재사용을 각각 검증한다. 20초를 명세의 수치 보장으로 취급하거나 timeout 증가만으로 완료하지 않는다.
- [ ] 수정 및 검증 결과를 CBRD-26659에 연결하고, 진행 중인 회수 설계 개정과 정합성을 확인한다.

## Related Work

[진단 보고서](https://github.com/vimkim/my-cubrid-docs/blob/0c5c05f713ca1953725743b865c7d3c14bd1272f/cbrd-26659/reclaim-compact-diagnosis.md)에 원본 관측과 한계가 있다. Resolved 상태의 [CBRD-26786](https://jira.cubrid.org/browse/CBRD-26786)의 회수 불변식에 대한 후속이다. [CBRD-27213](https://jira.cubrid.org/browse/CBRD-27213)의 부분 여유 공간 bestspace 재설계, [CBRD-27872](https://jira.cubrid.org/browse/CBRD-27872)의 할당 시 회수 검사 비용과 범위를 구분하되 변경이 겹치면 함께 검증한다.
