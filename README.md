# my-cubrid-jira

CUBRID JIRA 이슈의 초안, 분석 보고서, 재현·검증 자료를 Markdown으로 관리하는 개인 저장소입니다.
문서를 검토한 뒤, 업로드 스크립트로 기존 JIRA 이슈의 설명에 반영합니다.

## 문서 찾기

| 경로 | 내용 |
| --- | --- |
| [issues/](issues/) | 이슈 설명 초안, 원인 분석, 성능 보고서. 이슈 번호로 찾습니다. |
| [CONTEXT.md](CONTEXT.md) | CUBRID 전송 보안과 TDE를 구분하는 용어. |
| [CLAUDE.md](CLAUDE.md) | 에이전트의 문서 작성·업로드 규칙. |

이슈 번호나 본문 키워드로 검색합니다.

```sh
rg --files issues | rg 'CBRD-27213'
rg -n 'vacuum' issues
```

`just list`는 로컬 이슈 파일을 수정 시각이 최신인 순서로 보여줍니다.
현재 JIRA 상태는 `just fetch <이슈 키>`로 확인합니다.

## 이슈 문서 작성하기

문서는 `issues/`에 저장합니다. 파일명은 이슈 키로 시작하고, 뒤에 설명이나 리비전 정보를 붙일 수 있습니다.

| 파일명 예시 | 용도 |
| --- | --- |
| `CBRD-25356.md` | 이슈 키만 사용하는 문서. |
| `CBRD-26517-oos-todo.md` | 설명을 붙인 문서. |
| `CBRD-27213-oos-bestspace-shared-module_dcbf09e_claude.md` | 기준 리비전과 작성 도구를 붙인 검토본. |
| `CUBRIDQA-1369-run-sql.md` | 다른 JIRA 프로젝트의 이슈 문서. |
| `CBRD-XXXXX-oos-vacuum-crash-injection-tests.md` | 이슈 번호 발급 전 초안. 업로드하려면 실제 이슈 키로 이름을 바꿉니다. |

같은 이슈에 여러 문서가 있을 수 있습니다. 업로드할 파일은 내용과 기준 리비전을 확인해 고릅니다.
업로더는 파일명 앞의 이슈 키로 대상을 정하고, 뒤의 설명과 리비전은 무시합니다.

## JIRA 설명에 반영하기

### 도구와 인증 준비하기

Bash와 GNU 명령행 도구를 사용하는 Linux 환경을 기준으로 합니다.
다음 도구를 `PATH`에 설치합니다.

- [just](https://github.com/casey/just). 저장소 명령을 실행합니다.
- [cubrid-jira](https://github.com/vimkim/cubrid-jira). JIRA 조회·수정과 Markdown 변환을 처리합니다.
- [pandoc](https://pandoc.org/). `cubrid-jira`가 Markdown 변환에 사용합니다.
- Python 3. `just doctor`가 인증 설정을 확인할 때 사용합니다.
- [fzf](https://github.com/junegunn/fzf). `just upload`의 파일 선택에 필요합니다.

인증은 `CUBRID_JIRA_USER`와 `CUBRID_JIRA_PASSWORD` 환경변수 또는 `~/.netrc`의 `jira.cubrid.org` 항목으로 설정합니다.
도구와 인증 설정을 확인합니다.

```sh
just doctor
```

### 대상과 변환 결과 확인하기

업로드하면 기존 이슈의 **설명 전체를 교체합니다**. 먼저 현재 설명과 변환 결과를 확인합니다.

```sh
just fetch CBRD-26517
just upload-dry issues/CBRD-26517-oos-todo.md
```

`upload-dry`는 대상 이슈와 로컬 문서 일부를 보여준 뒤, 실제로 변환한 요청 내용을 출력합니다.
JIRA를 수정하지 않습니다.

### 확인 후 업로드하기

파일을 고르고 확인 질문에 답하려면 다음 명령을 실행합니다.

```sh
just upload
```

파일을 지정하려면 다음 명령을 실행합니다.

```sh
just upload-file issues/CBRD-26517-oos-todo.md
```

두 명령 모두 변환을 검증한 뒤 `Upload to <KEY>? [y/N]`에서 확인을 받습니다.
업로드를 마치면 `just fetch <이슈 키>`로 반영된 설명을 확인합니다.

확인 질문 없이 바로 설명을 교체하려면 다음 명령을 사용합니다.
에이전트는 사용자가 해당 파일의 업로드를 명시적으로 요청한 경우에만 실행합니다.

```sh
just upload-yes issues/CBRD-26517-oos-todo.md
```

Markdown 변환과 인증, 실제 갱신은 `cubrid-jira`가 처리합니다.
이 저장소의 업로드 스크립트는 로컬 Markdown 원문을 변경하지 않습니다.

## 미리보기와 검증하기

`markserv`를 설치하면 `just serve`로 문서를 미리 볼 수 있습니다.
서버는 `0.0.0.0:8000`에서 수신하고, 브라우저를 자동으로 열지 않습니다.
`bat`을 설치하면 `just upload`의 파일 선택창에서 구문 강조를 사용합니다.

업로드 스크립트를 검증하려면 다음 명령을 실행합니다.

```sh
just test
```

테스트는 가짜 `cubrid-jira` 명령으로 실행하며 실제 JIRA를 수정하지 않습니다.
전체 명령 목록은 `just --list`로 확인합니다.
