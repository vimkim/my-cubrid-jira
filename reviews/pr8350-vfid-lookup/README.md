# PR #8350 별도 이슈 초안과 등록 준비

2026-11-04에 [원댓글](https://github.com/CUBRID/cubrid/pull/8350#discussion_r4452180248), live JIRA 검색과 후보 본문, 고정 소스를 확인했다. 리뷰어는 PR을 승인하면서 기존 조회 오류 처리 결함의 별도 등록과 이슈 번호 회신을 요청했다.

이번 산출물은 [번호 없는 이슈 초안](../../issues/vacuum-oos-vfid-lookup-error.md), 등록용 dry-run payload와 [원댓글 답글 초안](reply-draft.md)이다. 외부 등록·게시 전 상태다. PR #8350의 엔진 변경에는 이 결함 수정을 섞지 않는다.

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

이 범위에서는 정확히 같은 별도 이슈를 확인하지 못했으므로 새 초안을 준비했다. 전체 JIRA에 중복이 없다는 증명은 아니다. 실제 생성 직전에 같은 검색을 다시 실행한다. 기존 후보의 본문과 상태는 변경하지 않았다.

## Proposed creation fields

이슈의 성격은 실제 오류 처리와 자원 회수 결함이다. OOS 후속 과제로 독립 배정할 단위이므로 JIRA 유형은 `Sub-task` 를 제안한다. 개념상 범주는 정확성, 자원 누수, 오류 복구다. 영향 모듈은 `src/query/vacuum*` 와 `src/storage/heap_file.c` 이며, 이를 검증되지 않은 JIRA component나 label로 지정하지 않는다.

| 필드 | 제안 값과 근거 |
|---|---|
| Project | `CBRD`, live project ID `217031` 이다. |
| Issue type | `Sub-task`, live type ID `5` 이다. `Correct Error` ID `40` 도 존재하지만 이번 payload는 OOS 후속 이슈의 하위 작업으로 준비했다. |
| Parent | [CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978), `[OOS] [EPIC] TODO` 다. Confirmed·Unresolved이며 남은 결함과 검증 과제를 모으는 현재 본문에 부합한다. |
| Summary | `[OOS] vacuum이 OOS 파일 조회 실패를 삼켜 삭제된 행의 OOS 값을 남긴다` |
| Description | `issues/vacuum-oos-vfid-lookup-error.md` 의 실제 Jira wiki 변환 결과다. |
| QA Scenario | `customfield_210565 = {"value":"Required"}` 를 제안한다. live 필수 필드이며 허용 값이다. 장애 주입과 재기동 검증이 필요하다는 뜻이며 QA 실행 완료를 뜻하지 않는다. |
| Related issue | 생성 후 `Relates` 로 `CBRD-27860` 과 연결하도록 준비했다. |

[생성 메타데이터](create-metadata.json)는 인증된 읽기 전용 GET으로 조회한 현재 필수 필드와 허용 값의 요약이다. `Sub-task` 는 project·type·summary·parent·QA Scenario가 필수다. 담당자·우선순위·label·component·workflow transition은 payload에서 지정하지 않았다.

[CBRD-26583](https://jira.cubrid.org/browse/CBRD-26583)은 기존 M2와 PR #8350 이슈의 부모지만 조회 시 Handover·Fixed다. [CBRD-26835](https://jira.cubrid.org/browse/CBRD-26835)도 Handover다. 별도 후속 결함을 현재 TODO 아래에 두고 원이슈와 연결하는 선택이며, 부모 확정은 등록 전 검토 대상이다.

## Rebuild the dry-run payload

[prepare-create.sh](prepare-create.sh)는 이슈 첫 줄에서 제목을 읽고 canonical `cubrid-jira` CLI로 본문을 변환한다. 항상 `--dry-run` 으로 실행하며 인자를 받아 live 모드로 전환하는 기능은 없다. 저장소 루트에서 다음과 같이 재생성한다.

```sh
bash reviews/pr8350-vfid-lookup/prepare-create.sh > /tmp/pr8350-create-dry-run.json
```

[보존한 payload](create-dry-run.json)의 `dry_run` 은 `true` 다. 억제된 요청 두 개는 issue 생성과 관련 링크 생성이다. `<new-issue-key>` 는 CLI가 dry-run에서 사용하는 미발급 표식이며 실제 번호가 아니다. dry-run은 변환과 요청 형태를 확인한 결과이고, 서버가 이 payload로 생성을 수락했다는 검증은 아니다.

## Evidence and verification

소스 근거는 PR #8350 head `1ef6ed6125eb6028c06b0e05282dc0041bde3f48` 과 base `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67` 다. 원댓글과 head의 조회 실패·재준비·삭제 분기, base에도 있는 오류 삼킴을 확인했다. 본문은 debug assertion 중단과 release의 성공 반환을 구분한다.

OOS 요구사항은 현재 normative specification §3 DELETE와 §4 Vacuum + OOS를 참고했다. DELETE 행의 REMOVE 정리와 UPDATE의 소유권·알림 정리, 빈 페이지 회수는 별개다. 이번 초안은 DELETE 행의 값 회수로 범위를 한정한다.

문서와 실제 CLI 변환을 대상으로 shared-link 검사, BMP·UTF-8·문서 구조 검사, 상대 링크와 local-only 명령 검사, shell 문법 검사, 보존 payload와 재생성 결과의 일치, `git diff --check` 가 통과했다. GitHub에서 고정 revision의 네 소스 경로와 base helper를 읽었고, 반환된 blob SHA가 로컬의 같은 revision과 일치했다. 엔진 빌드·테스트·장애 주입·누수 측정은 실행하지 않았다.

## Resume publication

문서 작업 checkout은 `my-cubrid-jira-pr8350-vfid-error-followup`, 브랜치는 `docs/pr8350-vfid-error-followup` 이다. 시작점은 notes 저장소 `d41c9363199a3244adaa1f16d6b8c2ea052aab9c` 이며 로컬 통합 대상은 원래 저장소의 `main` 이다. 이번 요청은 로컬 커밋까지이므로 통합·push·JIRA 생성·답글 게시를 수행하지 않는다.

게시 지시를 받은 세션은 다음 순서로 이어간다.

1. PR과 원스레드, 중복 검색과 부모·필수 필드 메타데이터를 다시 확인한다. 변경이 있으면 초안과 payload를 검토한다.
2. 사용자 Git 절차에 맞춰 문서를 `main` 에 통합하고 push한다. 생성 작업과 원댓글 회신이 승인된 범위인지 확인한다.
3. 보존 payload와 같은 필드로 JIRA를 생성하고 실제 key를 받는다. live 본문·부모·유형·관련 링크를 재조회하여 검증한다.
4. 이슈 파일을 실제 key로 이름 바꾸고 문서와 인덱스의 초안 상태를 갱신한다. 답글 초안의 두 표식을 실제 key와 URL로 치환한 뒤 원 inline thread에 게시한다. 게시된 답글을 다시 읽어 검증한다.
5. PR #8350은 계속 open으로 유지한다. 별도 엔진 수리는 통합 상태를 확인한 새 source branch에서 시작한다.

진행 기록은 Work 676에 연결한다. PR 병합, 엔진 수리, 다른 OOS 후속 이슈는 이번 초안의 완료 조건에 포함하지 않는다.
