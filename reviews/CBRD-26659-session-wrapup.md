# CBRD-26659 후속 TODO와 세션 인계

2026-11-04 세션을 마무리하며 남은 작업을 기록한다. 전체 CBRD-26659는 미완료다. 원래 14 FAIL과 SA schema의 원래 120초 TIMEOUT을 유지한다.

## OOS TODO Subtasks

[OOS TODO CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978) 아래에 다음 두 하위 작업을 생성했다.

| 하위 작업 | 다음 행동과 완료 기준 |
| --- | --- |
| [CBRD-27924](https://jira.cubrid.org/browse/CBRD-27924) SA compact 배치 정책 수리 | 최신 수정 대상에서 재현을 확인한 뒤 엔진을 수정한다. 원래 `gap_compact_sa_cs`의 물리 기대값을 유지하고 SA·CS·일반 UPDATE의 값·물리 행·OOS owner를 검증한다. |
| [CBRD-27925](https://jira.cubrid.org/browse/CBRD-27925) 유예 빈 페이지 회수 분석·보완 | sampling 시점 horizon의 실제 공급자와 abort 두 페이지의 latch·최종 enum을 함께 관측한다. 안전 gate를 유지하고 eventual return에 필요한 재시도를 보완한다. 진행 중인 회수 설계 개정과 정합성을 확인한다. |

두 이슈 모두 live 본문이 생성 dry-run의 변환 본문과 일치하고, 부모 `CBRD-26978`, 유형 `Sub-task`, 상태 `Open`, 관련 이슈 링크를 재조회로 확인했다. 담당자·우선순위·workflow 상태를 별도로 지정하거나 변경하지 않았다.

SA compact는 엔진 수리 대상으로 처리한다는 담당자 결정을 반영했다. 이전 진단의 “수리 또는 TC 기대값 조정” 선택지는 후속 결정으로 정리됐다. TC 기대값을 낮추는 새 정책 결정을 기다리지 않는다.

## Remaining TODO

| 남은 작업 | 기존 추적 및 다음 행동 |
| --- | --- |
| `alt_stub_duplicate`, `alt_stub_merge`, `notify_nodrop`, `notify_commit` | [CBRD-27230](https://jira.cubrid.org/browse/CBRD-27230)의 미할당 stub 재사용·커밋 알림 범위에 연결한다. 최신 수정본에서 원래 TC로 검증하며, 현재 기록만으로 수리 완료나 모든 호출 경로의 원인을 확정하지 않는다. |
| `notify_abort`, `cbrd_27237_rollback_vacuum` | [CBRD-27237](https://jira.cubrid.org/browse/CBRD-27237)의 수리 후 원래 값 보존 TC로 재검증한다. 보존 실행에 실제 chain 삭제 stack이 없으므로 동일 원인 확정은 구분한다. |
| `record_target0`, `record_target10` | [CBRD-27785](https://jira.cubrid.org/browse/CBRD-27785)의 four-record target 후속과 대조한다. 두 TC의 물리 오류 모두를 최신 수정 대상에서 재확인한다. |
| 회수 5개·compact 1개 | 새 CBRD-27925·27924에서 처리한다. 진단 대조 PASS를 원래 FAIL의 PASS로 합산하지 않는다. |
| SQL CTP 집계·JUnit 중첩 디렉터리와 결과 정합성 | CBRD-26659의 기존 TODO를 유지한다. 실제 실행 선택·원본 결과·최종 집계를 대조한 뒤 전체 SQL 판정 범위를 확정한다. |
| `ctas02` native 종료 지연 | 성공 TC 결과 뒤 명령 timeout의 원인을 추가 분석한다. 이후 정상 종료 대조만으로 원래 지연을 해결 처리하지 않는다. |
| `serialized_chunks` 설정 복원 진단 | TC PASS와 `cubrid.conf.org` 누락 framework 복원 문제를 구분하고, 복원 경로를 확인한다. |
| `schema_rewrites_sa`·기타 장시간 TC | 원래 120초 TIMEOUT과 제한 연장 진단 PASS를 구분한다. QA와 실행 위치·주기·환경·담당을 합의한다. 120초 gate가 필요하면 상태·assertion을 유지하는 분할을 검증한다. |
| HA 연결 실패와 후속 수리 | master 연결 실패 원인을 별도 분석한다. [CBRD-27800](https://jira.cubrid.org/browse/CBRD-27800)·[CBRD-27801](https://jira.cubrid.org/browse/CBRD-27801)의 수리 후 원래 TC를 확인한다. 연결 실패를 두 엔진 결함으로 단정하지 않는다. |
| 커버리지 최종 대조 | 정책 구문·SHOW·유틸리티, 사용자 연산·HAS_OOS, C++ 내부 계약, 경계·limit+1, 저장 효율·단편화, 큰 키 요구를 실제 실행 증거 또는 명시적 공백에 연결한다. |
| TC·QA 리뷰와 실제 병합 | 개발 브랜치의 develop 병합 후 기존 TC PR 검토를 재개한다는 결정과 보류 상태를 유지한다. 사람이 리뷰·승인·실제 병합한다. 새 리뷰 날짜를 만들지 않는다. |

별도의 성능 비교 TC 승인·performance 편입은 기존 성능 작업 범위로 유지한다.

## Evidence and Resume Order

[회수·compact 진단](https://github.com/vimkim/my-cubrid-docs/blob/0c5c05f713ca1953725743b865c7d3c14bd1272f/cbrd-26659/reclaim-compact-diagnosis.md), [이전 수리·14 FAIL 분석](https://github.com/vimkim/my-cubrid-docs/blob/0c5c05f713ca1953725743b865c7d3c14bd1272f/cbrd-26659/follow-up-results.md), [상세 TODO](https://github.com/vimkim/my-cubrid-docs/blob/0c5c05f713ca1953725743b865c7d3c14bd1272f/cbrd-26659/CBRD-26659-todo-checklist_20261029_codex.md)를 보존한다.

다음 세션은 CBRD-27924의 최신 수정 대상 revision 확인과 SA compact 재현부터 시작한다. 이어 CBRD-27925의 미확정 관측을 진행한다. 기존 문서에 남은 정책 선택 문구보다 이번 세션의 수리 결정을 우선한다. 이번 정리에서는 엔진·TC 수리나 새 CI 실행을 시작하지 않는다.

이후 담당자 요청으로 [CBRD-27924의 20KB 초과 검사](../issues/CBRD-27924-sa-compact-layout.md#additional-verification)를 추가했다. 같은 고정 revision에서 SA compact는 24052B를 직렬화하고 heap overflow의 `REC_BIGONE`으로 저장했다. 일반 UPDATE·CS compact는 OOS를 사용했다. 엔진 수리와 원래 FAIL의 재검증은 계속 남아 있다.
