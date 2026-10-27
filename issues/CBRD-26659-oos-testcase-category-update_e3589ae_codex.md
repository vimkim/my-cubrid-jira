# [OOS] 개발자 회귀 테스트 보완·분류 및 검증·리뷰 전달

## Issue Triage

**이슈 수행 목적**: OOS의 사용자 연산, 저장 상태와 자원 수명을 검증하는 개발자 회귀 테스트를 작성·보완하고, 검증 결과와 남은 공백을 구분하여 QA와 동료 리뷰에 전달한다.

**이슈 수행 이유**: 초기 SQL 17개·shell 18개 전달 이후 정책·SHOW·유틸리티, 연산별 저장 상태, 내부 계약, 경계, 회수, 큰 키에 대한 보완을 진행했다. 현재 SQL/answer 28쌍과 OOS shell 진입점 133개를 보유하며, 개별 파일 전체를 나열하는 대신 여섯 분류와 TC 별칭으로 진행 상태를 정리한다.

**영향**: 값 조회의 성공만으로 물리 배치·소유권·회수까지 검증했다고 판단하거나, 비활성 실패를 통과 범위에 포함하면 미검증 동작을 놓칠 수 있다. 분류별 산출물과 정확한 실행 리비전을 연결하여 리뷰 대상, 통과 범위와 후속 작업을 확인할 수 있게 한다.

**이슈 수행 방안**: 공개 SQL, 비공개 shell과 C++ 내부 계약 검증을 함께 유지한다. 본문에는 분류·대표 TC 별칭·실행 결과·완료 조건을 기록하고, 전체 파일 목록과 개별 기대값·증거는 `my-cubrid-docs`의 상세 보고서로 연결한다. 실패·장시간 사례와 필수 항목별 독립 검증은 별도로 추적한다.

---

## AI-Generated Context

> 아래는 기존 이슈, 테스트 문서와 2026-10-27 확인한 PR·CI 근거를 바탕으로 정리한 진행 기록이다. 과거 검증 결과와 최신 PR의 상태를 구분한다.

## Description

이 이슈는 [CBRD-26357](https://jira.cubrid.org/browse/CBRD-26357)의 개발자 회귀 테스트 하위 작업이다. OOS(Out-of-row Overflow Storage)의 전체 값 보존뿐 아니라 실제 저장 레코드의 `HAS_OOS` 설정·해제, 파일·청크 소유권, 트랜잭션·복구와 정리 동작을 검증 대상으로 삼는다.

초기 전달 이후 피드백을 여섯 검증 영역으로 정리하고 테스트를 보완하여 두 TC PR에 게시했다. **현재 두 TC PR은 OPEN, Ready for review이며, 최신 전체 CI는 shell 실패로 FAIL이다.** 테스트 작성·게시, 활성 선택의 통과와 요구사항 전체의 검증 완료는 각각 구분한다.

| 산출물 | 전체 보유 수 | 정규 실행 활성 | 비활성 또는 검증 한계 |
| --- | ---: | ---: | --- |
| 공개 SQL/answer | 28쌍 | 25쌍 | 실패 3쌍을 원래 기대값과 함께 보존한다. |
| 비공개 OOS shell 진입점 | 133개 | 69개 | 실패 또는 60초 초과 64개를 보존한다. FAIL 61개와 장시간 8개 중 5개가 중복된다. |
| C++ 보완 테스트 함수 | 14개 | 위 SQL/shell 집계와 별도 | 기존 내부 계약 유지와 보완 함수 수다. 최신 리비전의 PASS 수를 뜻하지 않는다. |

위 수는 기존 TC를 포함한 현재 보유 수이며, 이번에 새로 추가한 수가 아니다. Shell helper 자체는 TC 수에 포함하지 않는다.

## Implementation

### 여섯 검증 분류와 대표 TC 별칭

`SQL-01`–`SQL-28`, `SH-001`–`SH-133`, `UT-01`–`UT-14`는 [피드백별 TC 대응 보고서][coverage]에서 정의한 조회용 별칭이다. CI의 전역 TC 번호나 구현 티켓 번호가 아니다. 아래에는 대표 별칭만 기재한다. 하나의 TC가 여러 분류에 대응할 수 있으므로 분류별 수를 합산하지 않는다.

| 분류 | 작성·보완한 검증 | 대표 TC 별칭 |
| --- | --- | --- |
| 1. 정책 구문·의미·SHOW·유틸리티 | STORAGE 정책의 정상·오류 구문과 문맥, SHOW 대상·권한, unload/load·compact·backup/restore의 정책·값·소유권 보존 | `SQL-08`, `SQL-27`; `SH-072`, `SH-097`, `SH-115`–`SH-116`, `SH-124`–`SH-132` |
| 2. 사용자 연산과 OOS 상태 | 읽기·복사·DML·MERGE/REPLACE/중복 키 UPDATE, 제약·트리거·트랜잭션, 스키마·파티션·LOB. 실제 저장 레코드의 `HAS_OOS` set/clear와 전체 행 모델을 연결 | `SQL-01`–`SQL-03`, `SQL-12`, `SQL-19`; `SH-019`, `SH-084`, `SH-099`–`SH-100` |
| 3. C++ 내부 계약 | SQL 결과만으로 대체하기 어려운 stored/Expand 읽기, 호출자 버퍼 수명·재시도, identity·소유권, system-worker undo와 기존 OOS 파일의 TDE 계약 | `UT-10`–`UT-14`; 기존 read/Expand·identity·rollback·reclaim 모듈 유지 |
| 4. 경계와 limit+1 | 직렬화 이득, chunk·VOT, stub·buffer의 exact/short capacity, 길이 guard, 물리 record target·bigone·key-overflow 경계 | `SQL-04`, `SQL-28`; `SH-101`–`SH-106`, `SH-114`; `UT-01`–`UT-09`, `UT-11` |
| 5. 저장 효율·회수·불리한 시나리오 | 반복 INSERT/UPDATE/DELETE, abort/retry, snapshot, crash/restart, notification·whole-stub 보존, 페이지 회수·재사용과 survivor 검증 | `SH-012`–`SH-017`, `SH-075`–`SH-078`, `SH-117`–`SH-118`, `SH-133`; `UT-12`–`UT-13` |
| 6. 큰 OOS PK/UNIQUE·FK | 실제 indexed attribute의 OOS 상태, 단일·복합 키, build/maintenance, 중복·NULL·FK action·rollback 및 index 경로 | `SQL-25`–`SQL-26`; `SH-004`, `SH-027`–`SH-040`, `SH-073` |

**전체 별칭→원본 경로·검사 내용·활성 여부·관측 결과는 [상세 Markdown 보고서][coverage]의 분류별 설명과 부록 A–C에서 확인한다.** 해당 보고서의 2026-10-27 스냅샷을 별칭 기준으로 사용하며, 최신 CI 상태는 아래에 별도로 기록한다.

### 공통 검증과 실행 지원

- 독립적인 전체 값·행·트랜잭션 모델을 기대값으로 사용하고, 실제 저장 레코드와 값·행 ID를 연결하는 관측 helper를 보완했다. 별도 SQL 실행의 논리 결과와 shell fixture의 물리 증거를 같은 실행의 증거로 합치지 않는다.
- Shell의 OOS helper는 C++17·Bash/jq를 사용한다. 사례별 DB·등록·파일·프로세스의 소유권, 명령 제한 시간과 정리 결과를 확인한다.
- 실패·장시간 사례는 정규 발견 경로 밖에 보존하고 원본 경로·리비전·hash·실행 결과·비활성 사유를 기록한다. 비활성화를 위해 본문·assertion·expected answer를 바꾸지 않았으며, 실패를 통과 커버리지로 계산하지 않는다.
- C++는 동등한 대체 assertion을 확인하지 못한 내부 계약을 유지하고 14개 함수를 보완했다. 기존 302개 GTest의 과거 PASS는 해당 리비전의 증거로 유지하며 최신 엔진의 전체 PASS로 확대하지 않는다.

## Validation

### 최신 PR과 전체 CI

2026-10-27 확인한 세 PR의 base는 모두 `feature/oos-merge`다. 두 TC PR의 head branch는 `tc/pr-8128`이다.

| 대상 | 현재 head | 현재 상태 |
| --- | --- | --- |
| [Engine PR #8128](https://github.com/CUBRID/cubrid/pull/8128) | `e3589ae42d42b04eb020e1ae43e165b01d31b12a` | OPEN, draft |
| [SQL TC PR #3688](https://github.com/CUBRID/cubrid-testcases/pull/3688) | `45e21ad799d82ebadc04a93c7d2f69517d53bf39` | OPEN, Ready for review |
| [Shell TC PR #4365](https://github.com/CUBRID/cubrid-testcases-private-ex/pull/4365) | `98723aa473cde722abbc729799cf489b7f3f732f` | OPEN, Ready for review |

**[최신 전체 CI run40472072791](https://github.com/CUBRID/cubrid/actions/runs/40472072791)는 FAIL이다.** Plan 로그에서 위 Engine·public TC·private TC 입력을 확인했다. Debug/release build, SQL과 medium은 PASS이고 shell shard 14·23·40은 실패했다. 이 갱신에서는 개별 실패 원인과 OOS TC 귀속을 분석하지 않았으므로, 세 shard 실패를 세 OOS 결함이나 세 TC 실패로 계산하지 않는다.

### 상세 보고서가 보존하는 이전 실행 근거

| 실행 | 입력·결과 | 인정하는 범위 |
| --- | --- | --- |
| [Full CI run40324320840](https://github.com/CUBRID/cubrid/actions/runs/40324320840) | Engine `c4c4f5c5`, public `4f6557f`, private `10fb4b63f`. Build·SQL·medium PASS, shell 실패로 전체 FAIL | Shard09 한정 대조에서 활성 OOS SQL 25개는 각각 PASS다. 다른 SQL shard의 summary/JUnit 수 불일치로 전체 testcase 수집 검증은 미완료다. |
| [Shell-only CI run40335925801](https://github.com/CUBRID/cubrid/actions/runs/40335925801) | Engine `c4c4f5c5`, private `8486abd`. 전체 shell 3,523 PASS / 0 FAIL / 30 SKIP | 활성 OOS 69개는 모두 실행·PASS, skip 0이다. 비활성 64개는 실행하지 않았다. 이 결과는 최신 head의 전체 CI 통과를 뜻하지 않는다. |

두 이전 실행의 결과를 하나의 동일 입력 full run PASS로 합치지 않는다. 개별 티켓의 native 실행과 C++ 결과도 해당 source·TC·oracle·실행 phase의 범위에서 유지한다.

## Remaining Work

- 최신 전체 CI의 실패 shard에서 개별 실패를 확인하고 원인·처리 범위를 정리한다. 과거 활성 OOS 69개 PASS로 최신 실패를 덮지 않는다.
- 비활성 SQL 3개·shell 64개의 실패 원인·후속 수정 연결과 장시간 사례의 별도 실행 경로를 정리한다. 모든 실패를 엔진 결함으로 일괄 확정하지 않는다.
- 지원 연산별 적용 가능한 `HAS_OOS` 상태, 독립 기대값, 실제 실행 phase와 C++ 필수 선택을 [연산 요구 목록][operations] 및 [C++ 인벤토리][cpp]와 최종 대조한다. 파티션 소유권, 정책 roundtrip, 물리 target, notification·회수 등 남은 항목의 완료를 활성 선택 통과만으로 선언하지 않는다.
- 큰 키 종합 선택 `SH-073`은 과거 PASS 관측이 있지만 381.773초로 비활성이다. 기능 결과로 성능 저하가 없다고 판단하지 않으며 성능 비교와 HA Work463은 계속 보류한다.
- QA·동료 리뷰에서 전달 범위와 잔여 공백을 확인한다. 두 TC PR이 OPEN이므로 TC Merge Gate의 두 TC PR 병합 또는 close 조건은 아직 충족하지 못했다. TC PR의 병합·close는 동료가 결정한다.

## Acceptance Criteria

- [x] 여섯 검증 분류별 SQL/shell/C++ 산출물을 작성·보완하고 관련 PR에 게시한다.
- [x] TC 별칭과 상세 Markdown, 실행 리비전·활성 여부·실패 및 장시간 사례의 근거를 연결한다.
- [x] 활성 선택의 실행 결과와 최신 전체 CI 상태를 구분하여 기록한다.
- [ ] 최신 CI 실패와 비활성·미실행 항목의 처리 또는 후속 추적·수락 범위를 확정한다.
- [ ] 필수 요구사항별 독립 검증, QA·동료 리뷰 및 TC Merge Gate 조건을 충족한다.

## References

- [피드백 6항목·TC 별칭·전체 파일 목록과 개별 결과][coverage]
- [CBRD-26659 문서 목록][index]
- [연산·상태별 요구사항과 후속 검증 지도][operations]
- [기존 C++ 내부 계약 유지·검증 범위][cpp]

[coverage]: https://github.com/vimkim/my-cubrid-docs/blob/343344b44377fb62604d104a5eac84d07210c45a/cbrd-26659/CBRD-26659-feedback-testcase-coverage-report_20261027_codex.md
[index]: https://github.com/vimkim/my-cubrid-docs/blob/343344b44377fb62604d104a5eac84d07210c45a/cbrd-26659/README.md
[operations]: https://github.com/vimkim/my-cubrid-docs/blob/343344b44377fb62604d104a5eac84d07210c45a/cbrd-26659/supplement-operation-inventory-work456-20261021.md
[cpp]: https://github.com/vimkim/my-cubrid-docs/blob/343344b44377fb62604d104a5eac84d07210c45a/cbrd-26659/supplement-cpp-inventory-work456-20261021.md
