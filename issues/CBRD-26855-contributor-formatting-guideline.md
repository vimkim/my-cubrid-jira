# [docs] Contributor 를 위한 formatting guideline

**PR**: https://github.com/CUBRID/cubrid/pull/7226 (draft)

## Issue Triage

**이슈 수행 목적**: 새 contributor 가 `code-style` CI 잡(`.github/workflows/check.yml` 의 포맷터 검증 잡 — 변경 파일에 포맷터를 다시 돌렸을 때 워킹 트리에 diff 가 남으면 실패시킨다)을 첫 push 에서 통과하도록, 핀 박힌 포맷터 버전과 GNU indent 의 context-sensitive 한 재포맷을 회피하는 절차를 contributor-facing 문서에 옮긴다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: 포맷터 핀 정보는 두 군데에만 박혀 있다. 첫째는 `.github/workflows/check.yml:93-111` 의 install 단계 — `indent 2.2.11` 을 소스에서 빌드, `astyle` 은 Ubuntu 24.04 apt 패키지(Artistic Style 3.x)로 간접 핀, `google-java-format 1.7` jar 를 다운로드. 둘째는 `.github/workflows/codestyle.sh` 디스패처 스크립트로, 확장자별로 위 세 포맷터를 호출한다. `README.md`, `docs/install_build_requirements.md`, 기존 `CONTRIBUTING.md` 어디에도 이 정보가 없다. 특히 GNU `indent` 는 배포판 패키지(`2.2.12+`)와 CI 핀(`2.2.11`)의 출력이 다르며, 이는 `check.yml:101` 의 주석 `"indent 2.2.11, the lastest version (2.2.12) make a different result"` 이 명시한다.
- **영향**: onboarding 비용. 새 contributor 는 첫 PR 의 `code-style` 실패 로그를 읽고서야 핀 버전과 디스패처 위치를 학습한다. OS 표준 `indent` 로 로컬에서 검증하면 깨끗하게 보이지만 CI 만 빨갛게 뜨는 패턴이 반복된다.

**이슈 수행 방안**:

- `CONTRIBUTING.md` 의 기존 bug-report / fork-workflow 안내는 내용 보존하되, 문서 상단에 bulleted ToC 를 두고 fork-workflow 본문은 numbered list 로 재구성한다.
- `CONTRIBUTING.md` 에 신규 섹션 다섯 개를 추가한다: `## PR requirements` 표(제목 정규식, license header, code style, `memory_wrapper.hpp` 위치, `cppcheck` `error:` 0개, CLA), `## Code style`, `## Memory header rule (server-side files)`, `## Build & test` (README/unit_tests 진입점 포인터), `## Getting help`.
- `## Code style` 절은 확장자 -> 도구 매핑, 핀 버전, `codestyle.sh` 호출법, CI 게이트를 로컬에서 재현하는 스니펫, GNU indent 의 context-sensitivity 우회를 위한 5단계 revert-and-replay 절차(patch 저장, `git checkout HEAD`, baseline 포맷, patch 재적용, 다시 포맷), `git add -p` shortcut, `clang-format` 사용 금지 노트, 그리고 "Why CI sometimes flags lines you didn't touch" 설명 단락을 담는다. 5단계 절차 step 4 는 `git apply` 외에 "AI 에이전트로 hunk 단위 재도입" 도 동등한 대안으로 명시한다.
- `docs/install_build_requirements.md` 에 `## Code Formatters` 절을 추가한다. Linux 설치 명령은 `.github/workflows/check.yml:93-111` install 단계와 같은 결과를 산출하도록 작성하며, `google-java-format` jar 는 `wget -O .github/workflows/google-java-format-1.7-all-deps.jar ...` 로 위치를 명시한다 — `codestyle.sh:31` 의 `java -jar` 가 이 경로를 repo 루트 기준으로 하드코딩하기 때문이다.
- install 명령은 CI 와 cosmetic 한 차이(apt 플래그 순서·`-q` 누락 등)를 의도적으로 허용한다. 동등한 결과 산출물이 기준이다.
- `README.md` 에 `CONTRIBUTING.md` 로 가는 짧은 `## Contributing` 진입점을 둔다. 핀 버전 문자열은 README 에 인라인하지 않는다 — 갱신할 파일을 `CONTRIBUTING.md` + `docs/install_build_requirements.md` + `.github/workflows/check.yml` 3 곳으로 한정한다.
- 범위 밖 (별도 합의/티켓): Windows / macOS 의 포맷터 핀 빌드, 사내 lint 자동화, `clang-format` 등 포맷터 전환, PR 위에서 자동 commit/push 까지 하는 auto-format-fix bot (현재는 `reviewdog/action-suggester` 가 suggestion 만 띄우고 사람이 적용).

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료입니다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하시면 됩니다.

## Description

`## Code style` 절이 install 가이드만으로 끝낼 수 없는 이유, 즉 `astyle` 과 `indent` 의 비대칭을 짚어 둔다.

`code-style` 잡의 통과 조건은 변경 파일에 포맷터를 한 번 더 돌려도 워킹 트리에 새 diff 가 없는 fixed-point 상태다. `astyle` (`.cpp`/`.hpp`/`.ipp`) 은 실무적으로 이 조건을 한 번에 만족시키므로 install 가이드만 따라가면 끝이다. GNU `indent` (`.c`/`.h`/`.i`) 는 그렇지 않다 — 출력이 입력 컨텍스트에 민감해 같은 파일에 두 번 돌렸을 때 안정점에 수렴한다는 보장이 없다. 그래서 `## Code style` 절은 install 가이드와 함께 출력 안정성 한계를 회피하는 revert-and-replay 절차를 같은 곳에 둔다. `astyle` 만 쓰는 contributor 에게는 후자가 불필요함을 명시한다.

---

## 참고 코드

- `.github/workflows/check.yml` — `code-style` job (lines 86-131; install 블록 93-111, indent 빌드 102-107, 버전 차이 주석 line 101, reviewdog/action-suggester 128-131). `memory-monitor-check` job (~217-290).
- `.github/workflows/codestyle.sh` — 확장자 -> 포맷터 디스패처. `java -jar .github/workflows/google-java-format-1.7-all-deps.jar` 호출은 line 31.
- `CONTRIBUTING.md` — contributor 진입 문서.
- `docs/install_build_requirements.md` — 빌드/포맷터 설치 가이드.
- `README.md` — 프로젝트 진입점.
