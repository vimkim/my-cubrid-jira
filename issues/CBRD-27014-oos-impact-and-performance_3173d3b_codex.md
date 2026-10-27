# [OOS] [M2] [Survey] [No-Triage] OOS 도입 의의와 성능 검증 결과 정리 및 공유

## Issue Triage

**이슈 수행 목적**: OOS가 해결하는 저장·조회 비효율과 도입 의의를 설명하고, SELECT 성능 시험에서 확인한 효과와 비용을 개발팀 기술 리뷰 및 사내 워크숍 자료로 정리하여 공유한다.

**이슈 수행 이유**: 큰 컬럼을 별도로 저장하는 구조가 사용자 조회에 어떤 이점을 주는지, 어떤 조건에서는 추가 비용이 발생하는지 설명할 근거가 필요하다. 저장 구조와 실측 결과를 연결하여 OOS의 적용 가치를 판단할 수 있도록 한다.

**영향**: 큰 컬럼을 읽지 않는 조회에서 불필요한 페이지 접근을 줄이는 효과를 확인했다. 대표 시험에서 약 22KB 행의 `id` 집계 시간이 66.3% 감소했고, 약 14.5KB 행의 큰 컬럼 하나를 읽는 시간은 13.6% 증가했다. 효과는 기존 저장 형태와 조회 컬럼에 따라 달라지며, 이 수치는 2026-07-10의 고정 revision 비교 결과다.

**이슈 수행 방안**: 기술 리뷰 발표자료(PPT A), 사내 워크숍 발표자료(PPT B), SELECT 성능 시험 상세 보고서를 작성하고 본 이슈에 첨부했다. 저장 구조의 설계 근거, 성능 효과와 한계, 후속 검증 사항을 함께 정리했다.

---

## AI-Generated Context

> 아래는 본 이슈의 첨부 발표자료 2종과 성능 시험 상세 보고서를 바탕으로 정리한 완료 기록이다. 성능 수치는 첨부 보고서의 측정 결과이며, 이번 본문 정리에서 시험을 다시 실행하지 않았다.

## Description

### 무엇을 정리했는가

본 이슈는 [OOS M2(CBRD-26583)](https://jira.cubrid.org/browse/CBRD-26583)의 발표자료 작성 하위 작업이다. OOS(Out-of-row Overflow Storage)의 필요성, 저장·읽기 구조, 실측 성능과 적용 의의를 기술 검토용 자료와 사내 공유용 자료로 정리했다.

CUBRID의 기존 행 저장 방식에서는 작은 컬럼만 조회해도 큰 컬럼을 포함한 행이 차지하는 페이지를 읽는다. 행이 한 페이지를 넘어 `REC_BIGONE`으로 저장되면, 필요한 컬럼을 꺼내기 위해 행 전체의 overflow chain을 따라가 복원하는 비용도 발생한다.

OOS는 큰 가변 컬럼을 별도 OOS file에 저장하고 heap record에는 작은 값과 16B 참조 정보를 남긴다. 작은 컬럼만 필요하면 compact heap을 읽고, 분리된 큰 값이 필요할 때 해당 컬럼의 OOS 데이터를 읽는 구조다. 발표자료는 이 차이를 저장 전후 그림과 조회 예시, 성능 시험 결과로 설명한다.

### 왜 의미가 있는가

본문·이미지처럼 큰 값이 있는 행에서 식별자나 목록 정보만 자주 읽는 경우를 생각할 수 있다. 기존 구조에서는 조회 결과에 쓰지 않는 큰 값도 페이지 접근과 버퍼 사용에 영향을 준다. OOS는 이 비용을 줄여, 필요한 작은 값을 조회하는 작업이 큰 컬럼의 크기에 덜 좌우되도록 한다.

또한 기존에 행 전체를 overflow로 저장하던 경우에는 큰 컬럼 하나를 읽을 때도 필요한 값만 가져올 수 있다. **OOS의 의의는 조회 컬럼에 따라 큰 값의 읽기 비용을 선택적으로 지불할 수 있는 저장 기반을 마련하는 데 있다.** 성능 시험은 이러한 구조적 이점이 실제 실행 시간과 페이지 접근 감소로 이어지는 조건을 보여준다.

개발팀 기술 리뷰 자료는 이 효과를 저장 구조의 선택 근거와 MVCC·복구·vacuum 연동까지 연결한다. 사내 워크숍 자료는 사용자 조회 관점에서 효과와 비용을 설명한다. 이를 통해 OOS가 유리한 작업과 후속 검증이 필요한 범위를 함께 공유한다.

## Deliverables

| 산출물 | 주요 내용 | 첨부 파일 |
| --- | --- | --- |
| PPT A: 개발팀 기술 리뷰 | 전용 OOS file 선택 근거, 저장 형식과 읽기 경로, MVCC·WAL·vacuum 연동, 성능 실측과 검토 질문 | [PPTX][ppt-a] / [HTML][html-a] |
| PPT B: 사내 워크숍 | 큰 컬럼 분리의 필요성, 조회별 페이지 접근 차이, 대표 성능 결과와 활용 의의 | [PPTX][ppt-b] / [HTML][html-b] |
| SELECT 성능 시험 상세 보고서 | 비교 revision, 데이터·SQL·측정 절차, 조회별 결과, 공간 결과와 재측정 사항 | [Markdown][report] |

HTML 자료는 필요한 CSS·JavaScript·로고를 포함한 단일 파일이다. 원본 자료는 [발표자료 저장소의 `88f3297` revision][presentation-source](2026-07-15)을 기준으로 하며, 저장소 접근 권한 없이 받을 수 있도록 JIRA에 직접 첨부했다.

## Performance Results

### 측정 조건

첨부 [성능 시험 상세 보고서][report]의 3~9장을 기준으로 한다.

- 측정일: 2026-07-10.
- 기준 구현: `develop` @ `e3b1bf014ac37fcf3b72b9816a245ff23d9a5e1f`.
- OOS 구현: `CBRD-27006-oos-recdes-locality` @ `3173d3bd5a9c615a17fb9425c2e1c2fee1095474`.
- 데이터: layout별 100,000행. 기준 구현에서 약 14.5KB ordinary heap인 경우와 약 22KB `REC_BIGONE`인 경우를 비교했다.
- 공통 조건: 16KiB page, 512MiB data buffer, 동일 GCC `RelWithDebInfo` 빌드, serial scan. Restart-only와 warm 각각 5회 측정하고 branch 실행 순서를 교대했다.

Restart-only는 DB 서버를 재시작한 조건이다. OS page cache를 비우지 않았으므로 완전한 cold 측정이 아니다. Warm은 1회 준비 실행 후 반복한 조건이며 전체 데이터가 CUBRID 버퍼에 들어간다는 뜻은 아니다. 동일 shared host에서 수행한 branch 간 비교다.

### 확인한 효과와 비용

아래는 5회 측정의 wall time 중앙값이다. 백분율은 기준 구현 대비 OOS의 실행 시간 변화로, 음수는 시간 감소, 양수는 시간 증가를 뜻한다.

| 기준 저장 형태 | 조회 | restart-only: 기준 → OOS | warm: 기준 → OOS |
| --- | --- | --- | --- |
| 약 14.5KB ordinary heap | 작은 컬럼 집계: `SUM(id)` | 0.93 → 0.61초 (-34.4%) | 0.57 → 0.27초 (-52.6%) |
| 약 22KB `REC_BIGONE` | 작은 컬럼 집계: `SUM(id)` | 1.69 → 0.57초 (-66.3%) | 0.91 → 0.16초 (-82.4%) |
| 약 14.5KB ordinary heap | 큰 컬럼 하나의 내용 비교 | 1.40 → 1.59초 (+13.6%) | 0.91 → 0.98초 (+7.7%) |
| 약 22KB `REC_BIGONE` | 큰 컬럼 하나의 내용 비교 | 2.28 → 1.67초 (-26.8%) | 1.59 → 1.21초 (-23.9%) |

약 22KB 행의 restart-only `SUM(id)`에서 query trace의 page fetch는 300,088회에서 33,339회로 줄었다. 큰 값의 overflow chain을 따라가는 대신 compact heap만 읽는 효과와 일치한다. 이 counter는 페이지 접근 횟수이며 디스크에서 실제로 읽은 횟수와 구분한다.

반면 ordinary heap에 있던 큰 값을 OOS에서 다시 읽으면 별도 페이지 접근 비용이 추가된다. Random index lookup도 매 행의 heap 접근이 남을 수 있으며, ordinary heap의 warm 시험에서는 개선폭이 6.2%에 그쳤다. 모든 컬럼을 읽는 시험에서는 조건별 실행 시간 변화가 -6.1%~+7.6%로, 작은 컬럼만 읽을 때의 이점이 크게 줄었다. 이 시험은 서버에서 값을 읽고 검증한 것으로, 큰 결과 전체를 클라이언트에 전송하는 `SELECT *`의 종단 간 성능과 구분한다.

## Limitations and Follow-up

### 측정 결과의 범위

이 결과는 위 revision과 시험 조건에서의 잠정 측정이다. INSERT·UPDATE는 이번 SELECT 시험 대상에 포함되지 않는다.

첨부 보고서는 두 테이블 합계 permanent data가 4,806MiB에서 5,847MiB로 21.7% 증가한 결과도 기록한다. 당시 compact heap 목표 크기 계산에 `unfill_space`와 slotted-page overhead가 반영되지 않아 페이지당 3행만 저장된 문제가 포함되어 있다. 보고서의 페이지당 4행·공간 감소 수치는 수정 목표와 예상치이며 실측값이 아니다. 최종 공간 비용과 수정 후 조회 성능은 별도 재측정으로 판단해야 한다.

발표자료의 구현 현황·저장 정책·제안 기능도 자료 작성 당시 기준이다. 워크숍 자료의 `PREFER_INLINE`·`FORCE_OUTLINE`은 제안으로 표시되어 있으며, 본 이슈의 완료를 해당 기능의 구현 완료로 해석하지 않는다.

### 완료 범위

발표자료 2종과 성능 시험 상세 보고서의 작성·첨부를 완료했다. OOS의 개발 완료, 후속 결함 수정과 재측정은 상위 개발 작업 및 관련 이슈에서 추적한다.

## References

- [CBRD-27014: 발표자료와 성능 보고서 첨부 이슈][issue]
- [CBRD-26583: OOS M2 상위 작업](https://jira.cubrid.org/browse/CBRD-26583)
- [SELECT 성능 시험 상세 보고서][report]: 3장 비교 환경, 6장 실제 SQL, 8~9장 조회별 결과, 10장 공간 결과와 재측정 사항.

[issue]: https://jira.cubrid.org/browse/CBRD-27014
[ppt-a]: https://jira.cubrid.org/secure/attachment/1021351/pptA-oos-review.pptx
[html-a]: https://jira.cubrid.org/secure/attachment/1021350/pptA-oos-review-standalone.html
[ppt-b]: https://jira.cubrid.org/secure/attachment/1021348/oos-ppt-for-workshop.pptx
[html-b]: https://jira.cubrid.org/secure/attachment/1021349/oos-workshop-standalone.html
[report]: https://jira.cubrid.org/secure/attachment/1021347/oos-performance-report.md
[presentation-source]: https://github.com/vimkim/cubrid-oos-presentation/tree/88f3297fbf10a2786ed4b2d1dff85bf55aaddc12
