# CBRD-27933 발급과 PR #8350 회신

2026-11-04에 [원댓글](https://github.com/CUBRID/cubrid/pull/8350#discussion_r4452180248), live JIRA 검색과 후보 본문, 고정 소스를 확인했다. 리뷰어는 PR을 승인하면서 기존 조회 오류 처리 결함의 별도 등록과 이슈 번호 회신을 요청했다.

[이슈 본문](../../issues/CBRD-27933-vacuum-oos-vfid-lookup-error.md)으로 [CBRD-27933](http://jira.cubrid.org/browse/CBRD-27933)을 발급하고, [원댓글에 답글](reply.md)을 게시했다. live 본문과 답글의 일치 검증은 [발급 기록](publication.json)에 보존한다. PR #8350은 open으로 유지했으며 엔진 수정은 별도 이슈에서 진행한다.

## Duplicate check

[검색 기록](duplicate-search.json)에 세 JQL, 조회 시각, 각 결과의 key·제목·상태·유형을 저장했다. 상태 필터를 두지 않아 Resolved와 Closed도 포함했다. 각 검색은 `--max 100 --start-at 0` 으로 전체 반환 수가 total과 같은지 대조했다.

| 검색 범위 | total | 반환 수 |
|---|---:|---:|
| 정확한 helper 이름 또는 vacuum과 누수 | 9 | 9 |
| OOS와 VFID·lookup·조회 실패·영구 누수·er_clear | 49 | 49 |
| 일반 조회 함수 이름 또는 vacuum과 lookup·조회 실패·영구 | 89 | 89 |

검색 결과의 합집합은 117건이다. 제목과 함수 언급을 선별한 뒤 아래 유력 후보의 live 문제 서술과 요구 범위를 직접 대조했다.

| 기존 이슈 | 조회 시 상태 | 이번 문제와의 차이 |
|---|---|---|
| [CBRD-27860](https://jira.cubrid.org/browse/CBRD-27860) | Confirmed | PR #8350의 heap 페이지와 헤더 사이 래치 순환을 해소한다. 실제 조회 실패의 오류 삼킴은 그대로 남는다. |
| [CBRD-27089](https://jira.cubrid.org/browse/CBRD-27089) | Resolved | 파티션 행과 OOS 값의 소유 heap 불일치를 producer 경로에서 고친다. 올바른 소유 관계에서 일어난 조회 실패와 원인이 다르다. |
| [CBRD-26715](https://jira.cubrid.org/browse/CBRD-26715) | Resolved | 과거 OOS 플래그 거짓 양성과 파일 없음에 따른 반복 처리 문제다. 실패를 성공으로 처리하는 임시 수정 이력이 있으나, 현재 조회 계약의 실제 실패를 재처리하는 후속 과제와 구분한다. |
| [CBRD-26792](https://jira.cubrid.org/browse/CBRD-26792) | Closed | release 오류 진단과 무결성 오류의 fatal-stop 정리다. 본문 Remarks도 transient lookup 실패를 같은 정책으로 묶지 않는다고 명시한다. |
| [CBRD-26668](https://jira.cubrid.org/browse/CBRD-26668) | Closed | OOS vacuum 정리 자체를 도입한 이슈다. 이미 있는 정리 경로를 조회 오류 때문에 생략하는 이번 결함과 구분한다. |
| [CBRD-26950](https://jira.cubrid.org/browse/CBRD-26950) | Closed | 재사용된 OOS 슬롯의 다른 행을 지우지 않도록 identity를 검증한다. 이번 문제는 조회 실패 뒤 정리를 하지 않는 것이다. |
| [CBRD-27886](https://jira.cubrid.org/browse/CBRD-27886) | Confirmed | DROP의 두 heap 삭제 함수에서 OOS 파일 정리를 공통화한다. vacuum의 DELETE 행 제거와 페이지 재처리는 범위 밖이다. |

이 범위에서는 정확히 같은 별도 이슈를 확인하지 못했다. 발급 직전에 같은 검색을 다시 실행했고 후보 집합과 본문에 변경이 없었다. 전체 JIRA에 중복이 없다는 증명은 아니다. 기존 후보의 본문과 상태는 변경하지 않았다.

## Creation fields

이슈의 성격은 실제 오류 처리와 자원 회수 결함이다. 사용자 승인에 따라 OOS 후속 과제의 `Sub-task` 로 발급했다. 개념상 범주는 정확성, 자원 누수, 오류 복구다. 영향 모듈은 `src/query/vacuum*` 와 `src/storage/heap_file.c` 이며 별도 JIRA component나 label은 지정하지 않았다.

| 필드 | 등록 값과 근거 |
|---|---|
| Project | `CBRD`, live project ID `217031` 이다. |
| Issue type | `Sub-task`, live type ID `5` 이다. `Correct Error` ID `40` 도 존재하지만 OOS 후속 이슈의 하위 작업으로 발급했다. |
| Parent | [CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978), `[OOS] [EPIC] TODO` 다. Confirmed·Unresolved이며 남은 결함과 검증 과제를 모으는 현재 본문에 부합한다. |
| Summary | `[OOS] vacuum이 OOS 파일 조회 실패를 삼켜 삭제된 행의 OOS 값을 남긴다` |
| Description | `issues/CBRD-27933-vacuum-oos-vfid-lookup-error.md` 의 실제 Jira wiki 변환 결과다. |
| QA Scenario | `customfield_210565 = {"value":"Required"}` 로 발급했다. live 필수 필드이며 허용 값이다. 장애 주입과 재기동 검증이 필요하다는 뜻이며 QA 실행 완료를 뜻하지 않는다. |
| Related issue | `Relates` 로 `CBRD-27860` 과 연결했다. |

[생성 메타데이터](create-metadata.json)는 인증된 읽기 전용 GET으로 조회한 현재 필수 필드와 허용 값의 요약이다. `Sub-task` 는 project·type·summary·parent·QA Scenario가 필수다. 담당자·우선순위·label·component·workflow transition은 payload에서 지정하지 않았다.

[CBRD-26583](https://jira.cubrid.org/browse/CBRD-26583)은 기존 M2와 PR #8350 이슈의 부모지만 조회 시 Handover·Fixed였다. [CBRD-26835](https://jira.cubrid.org/browse/CBRD-26835)도 Handover였다. 별도 후속 결함은 현재 TODO 아래에 두고 원이슈와 연결했다.

## Rebuild the dry-run payload

[prepare-create.sh](prepare-create.sh)는 발급한 이슈의 생성 요청을 재현하는 자료다. 이슈 첫 줄에서 제목을 읽고 canonical `cubrid-jira` CLI로 본문을 변환한다. 항상 `--dry-run` 으로 실행하며 인자를 받아 live 모드로 전환하는 기능은 없다. 저장소 루트에서 다음과 같이 재생성한다.

```sh
bash reviews/pr8350-vfid-lookup/prepare-create.sh > /tmp/pr8350-create-dry-run.json
```

[보존한 payload](create-dry-run.json)의 `dry_run` 은 `true` 다. 억제된 요청 두 개는 issue 생성과 관련 링크 생성이다. `<new-issue-key>` 는 CLI의 dry-run 표식이다. 실제 생성과 관련 링크는 별도 live 실행 후 재조회로 확인했다.

## Evidence and verification

소스 근거는 PR #8350 head `1ef6ed6125eb6028c06b0e05282dc0041bde3f48` 과 base `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67` 다. 원댓글과 head의 조회 실패·재준비·삭제 분기, base에도 있는 오류 삼킴을 확인했다. 본문은 debug assertion 중단과 release의 성공 반환을 구분한다.

OOS 요구사항은 현재 normative specification §3 DELETE와 §4 Vacuum + OOS를 참고했다. DELETE 행의 REMOVE 정리와 UPDATE의 소유권·알림 정리, 빈 페이지 회수는 별개다. 이번 초안은 DELETE 행의 값 회수로 범위를 한정한다.

문서와 실제 CLI 변환을 대상으로 shared-link 검사, BMP·UTF-8·문서 구조 검사, 상대 링크와 local-only 명령 검사, shell 문법 검사, 보존 payload와 재생성 결과의 일치, `git diff --check` 가 통과했다. GitHub에서 고정 revision의 네 소스 경로와 base helper를 읽었고, 반환된 blob SHA가 로컬의 같은 revision과 일치했다. 엔진 빌드·테스트·장애 주입·누수 측정은 실행하지 않았다.

## Publication

초안 커밋 `c0b5e1a` 를 `main` 에 fast-forward로 통합하고 `origin/main` 에 push했다. 최초 HTTPS 생성 요청은 HTTP로 향하는 302 리다이렉트 뒤 HTTP 405로 실패했다. 같은 제목의 이슈가 없음을 재검색한 뒤 CLI의 기본 서버 주소인 `http://jira.cubrid.org` 로 고쳤다. 승인된 요청 본문은 그대로였고 URL scheme만 바뀌었다. 교정 커밋 `5836c0f` 도 push한 뒤 생성했다.

발급과 회신에서 다음 값을 확인했다.

| 확인 항목 | 결과 |
|---|---|
| JIRA 생성 | `CBRD-27933`, 상태 `Open` 이다. |
| 본문 | live raw description과 dry-run 변환 본문이 정확히 같다. 제목·부모·유형·QA Scenario·관련 링크도 재조회했다. |
| 원댓글 회신 | [게시된 답글](https://github.com/CUBRID/cubrid/pull/8350#discussion_r4467124845)의 `in_reply_to_id` 는 `4452180248` 이며 본문이 [회신 기록](reply.md)과 정확히 같다. |
| PR 상태 | `open`, 미병합이며 head는 `1ef6ed6125eb6028c06b0e05282dc0041bde3f48` 이다. |

번호 없는 이슈 파일은 실제 key가 있는 이름으로 바꾸고 인덱스와 dry-run 재생성 경로를 갱신했다. 진행 기록은 Work 676에 연결한다. 엔진 수리는 그 시점의 통합 상태를 확인한 별도 source branch에서 시작한다. PR 병합과 다른 OOS 후속 이슈는 이번 발급·회신 작업의 범위 밖이다.
