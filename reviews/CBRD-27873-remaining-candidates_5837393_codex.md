# CBRD-27873 잔여 후보 검토 및 이슈 생성 결과

2026-11-02에 남은 후보 3개를 서로 다른 subagent가 검토했다. 사용자는 이슈로 다룰 근거와 기존 JIRA 중복을 확인한 뒤 생성하고, OOS는 CBRD-26978 하위에 두며 담당자를 vimkim으로 지정하도록 요청했다. 검토 도중 사용자가 OOS 테스트 작업을 `[misc] midxkey, copyarea, workspace 테스트 생성` 한 건으로 묶는 방향을 정했다.

## Result

| 후보 | 검토 결과 | 최종 처리 |
|---|---|---|
| midxkey OOS COPY | 임시 값 수명 계약을 보호하는 테스트 보완 작업이 타당하다. 현재 엔진의 결함을 새로 재현한 것은 아니다 | [CBRD-27880](http://jira.cubrid.org/browse/CBRD-27880)에 포함 |
| 플래그가 다른 copyarea/workspace UPDATE | 현재 private UPDATE 호출처에는 그런 조합이 없다. 그 가정만으로 별도 이슈를 만들 근거가 없다 | 사용자 요청에 따라 지원되는 copyarea 및 workspace 경로의 테스트 보완을 CBRD-27880에 통합 |
| shutdown의 db_ws_free ASan 보고 | 원본 stack, 포인터, 실패 테스트 및 재현 명령을 확보하지 못해 원인과 중복을 판정할 수 없다 | 일반 이슈 생성 보류. 필요한 증거를 [CBRD-27873](http://jira.cubrid.org/browse/CBRD-27873)에 기록 |

CBRD-27880은 [OOS TODO CBRD-26978](http://jira.cubrid.org/browse/CBRD-26978)의 Sub-task다. 생성 시 assignee를 vimkim으로 지정하고 실제 본문, 유형, 부모, 담당자 및 관련 이슈를 다시 읽어 생성 payload와 비교했다.

기존 CBRD-27874는 담당자가 없어서 vimkim으로 지정했다. CBRD-27875부터 CBRD-27878까지는 이미 vimkim이었다. 이 5건과 새 CBRD-27880의 담당자를 확인했다. OOS TODO의 다른 작업 담당자는 변경하지 않았다.

## Source and method

- PR #8299의 현재 head `5837393ffb9d69bccb93271d63b0e38b884e0ed4`, base `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`를 기준으로 `git show`, `git grep` 및 호출처 추적을 수행했다.
- 과거 리뷰 head는 `f8114e432d3e97cc7a11149ab8ac852de4a1b935`, 보관된 review harness는 `7472ed577850c13be1aed915691a35b6dec23b6b`다.
- non-OOS 비교에는 develop `d5674fe94f08d084c6832ba4e3f6521d66cbee0e`도 사용했다. 최신 develop 소스의 존재만으로 같은 실패가 재현된다고 주장하지 않는다.
- worker 3명은 각각 midxkey, owner flags, shutdown을 맡았다. 모델은 모두 gpt-6.1-terra다. root가 결과와 핵심 코드를 다시 확인하고 최종 범위를 정했다.
- 이번 검토에서는 CUBRID를 새로 빌드하거나 runtime 및 mutation 테스트를 실행하지 않았다. 기존 결과의 출처는 [원본 리뷰 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr8299-adversarial-review_f8114e432_claude.md)와 [공개 harness](https://github.com/vimkim/cubrid/tree/CBRD-27785-review-harness)다.

## Midxkey evidence

[heap_midxkey_get_value](https://github.com/CUBRID/cubrid/blob/5837393ffb9d69bccb93271d63b0e38b884e0ed4/src/storage/heap_file.c#L11749)는 stack scratch를 준비하고 OOS resolve 결과를 타입 reader로 변환한다. COPY 인수는 transient storage를 나타내는 `oos_owned_buffer`다. 할당 버퍼는 helper가 반환하기 전에 해제한다.

압축하지 않은 VARCHAR reader는 COPY가 false이면 원본 바이트를 빌릴 수 있다. 호출자가 helper 반환 뒤 값을 쓰므로 임시 버퍼의 수명과 독립적인 값이 필요하다. 압축된 값은 별도 할당으로 이 문제를 가릴 수 있고, 큰 payload가 실제 인덱스 제한 안에서 어느 버퍼 경로에 도달하는지도 확인해야 한다.

과거 리뷰의 COPY 변형 생존 결과는 보고된 결과다. 최신 head에서 같은 변형이 생존한다고 새로 검증하지 않았다. 등록한 이슈의 완료 조건은 정상 코드에서는 통과하고 해당 COPY만 제거한 변형에서는 실패하는 판별 가능한 테스트를 제시하는 것이다.

## Copyarea and workspace evidence

[locator_update_force 호출처](https://github.com/CUBRID/cubrid/blob/5837393ffb9d69bccb93271d63b0e38b884e0ed4/src/transaction/locator_sr.c#L6845)는 네 곳이다. 두 곳은 두 플래그에 true를 전달하고, 두 곳은 false와 기본 false를 전달한다. 현재 비동일 UPDATE 인수를 생산하는 호출처는 찾지 못했다.

[공통 finalizer](https://github.com/CUBRID/cubrid/blob/5837393ffb9d69bccb93271d63b0e38b884e0ed4/src/transaction/locator_sr.c#L4921)는 INSERT에도 사용한다. [기존 테스트](https://github.com/CUBRID/cubrid/blob/5837393ffb9d69bccb93271d63b0e38b884e0ed4/unit_tests/oos/sql/test_oos_sql_deferred_write.cpp#L280)는 두 플래그가 다른 조합으로 bypass 및 실패 처리를 호출한다. 따라서 UPDATE 호출처에서 값이 같다는 이유로 두 개념을 전체 API에서 같은 의미로 취급해서는 안 된다.

최종 misc 이슈는 지원되는 입력 경로의 OOS 준비, owner 수명 및 저장 결과를 검증하는 작업이다. 기존 테스트의 보호 범위를 확인하고 보완 대상을 정하며, 새로운 UPDATE 입력 조합을 기능으로 추가하지 않는다.

## Shutdown evidence and hold

원본 리뷰와 보관된 lifetime harness의 teardown 주석은 SA 모드 종료 중 db_ws_free ASan 보고가 있었다고 기록한다. 이는 같은 과거 관측을 설명하는 문서이며 독립 재현이 아니다. 검토한 경로에서는 원본 ASan stack이나 실패 test filter와 명령을 찾지 못했다.

quick_fit.c의 allocation header 검사 코드는 검토한 head, base 및 develop에서 같았다. 이 사실은 검출 코드의 동일성을 보여 주며, 같은 실패가 모든 revision에서 발생함을 증명하지 않는다. 현재 정보로는 엔진, fixture 및 instrumentation 중 어느 쪽이 부적절한 포인터를 전달했는지 판단할 수 없다.

다음 검토에 필요한 것은 전체 ASan 보고서, binary revision과 compiler flags, DB 준비와 test filter 및 실행 명령이다. ASan이 지목한 global과 포인터의 생성 또는 대입 경로를 추적한 뒤, fixture를 분리한 최소 재현과 develop 비교를 수행한다. 이를 확보한 뒤 Correct Error 또는 조사 Task 여부와 기존 이슈 중복을 판단한다.

## Duplicate search

JIRA indexed text를 조회하고 관련 issue 본문을 읽었다. 아래 결과는 검색 범위 내 판단이며 의미가 같은 모든 ticket이 없다는 보장은 아니다.

| 후보 | 주요 검색 조건 | 관측 결과와 구분 |
|---|---|---|
| midxkey | `text ~ "heap_midxkey_get_value"`; `text ~ "midxkey" AND text ~ "OOS"`; `text ~ "OOS" AND text ~ "COPY"` | 각각 4, 9, 29건. CBRD-26769는 오류 전파, CBRD-26547은 covered index 값, CBRD-26565는 버퍼 크기다. CBRD-22638은 오래된 압축 레코드 손상 사례다. 이번 수명 테스트의 직접 중복으로 판단하지 않았다 |
| flags | `text ~ "locator_update_force"`; `text ~ "from_copyarea"`; `text ~ "from_workspace"`; `text ~ "pending owner"` | 첫 검색은 94건, from_copyarea는 0건이었다. CBRD-27424는 workspace, CBRD-27089는 deferred write의 실제 기능을 다룬다. 현재 비동일 UPDATE 결함의 근거로 사용하지 않았다 |
| shutdown | `text ~ "db_ws_free"`; `text ~ "quick_fit"`; `text ~ "global-buffer-overflow"`; `text ~ "db_shutdown"` | 각각 12, 39, 1, 35건. global-buffer-overflow 검색 결과는 후보 기록 CBRD-27873이었다. 원인과 stack이 없어 중복 판정도 보류했다 |
| 최종 misc 제목 | `summary ~ "midxkey" AND summary ~ "workspace"` | 생성 직전 검색 결과 0건 |

shutdown의 추가 broad 검색 `text ~ "workspace" AND text ~ "shutdown"`은 157건 중 앞 100건을 검토했다. 이 검색의 전체 결과를 확인했다고 주장하지 않는다.

[CBRD-22936](http://jira.cubrid.org/browse/CBRD-22936)은 loaddb에서 DB_VALUE 포인터를 해제하는 별도 trigger였고 재현 불가로 종료되었다. [CBRD-26016](http://jira.cubrid.org/browse/CBRD-26016)은 CAS signal과 shutdown의 다른 stack이다. [CBRD-24475](http://jira.cubrid.org/browse/CBRD-24475)는 allocator 리팩토링이다. 검출 함수가 비슷하다는 이유로 이 후보를 그 이슈들의 중복으로 확정하지 않았다.
