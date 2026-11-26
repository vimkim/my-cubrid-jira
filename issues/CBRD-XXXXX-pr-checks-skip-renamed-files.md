# [CI] PR 정적 검사가 이름이 바뀐 파일을 검사하지 않는다

**한 줄 요약**: CBRD-27539 후속 감사에서, PR 정적 검사(`check.yml`)가 변경 파일 목록에서 이름이 바뀐(`renamed`) 파일을 빼기 때문에 `.c` → `.cpp` 전환처럼 이름과 내용을 함께 바꾼 파일이 라이선스·코드 스타일·cppcheck·memory_wrapper 검사를 모두 건너뛴다는 것을 확인했다.

## Issue Triage

**이슈 수행 목적**: PR에서 이름이 바뀐 파일도 추가·수정된 파일과 같은 정적 검사를 받게 한다.

**이슈 수행 이유**: `.github/actions/changed-files/action.yml`은 GitHub compare API 결과에서 `status`가 `added` 또는 `modified`인 파일만 고른다. GitHub는 이름이 바뀐 파일을 내용 변경 여부와 상관없이 `renamed`로 보고하므로, 이런 파일은 목록에 들어가지 않는다. `check.yml`의 모든 검사 job은 이 목록(`added_modified`)만 순회한다.

**영향**: 개발자가 `src/` 아래 `.c` 파일을 `.cpp`로 `git mv` 하면서 내용도 고치면, 해당 파일은 라이선스 헤더, 코드 스타일(`.cpp`는 astyle), cppcheck, `memory_wrapper.hpp` include 순서 검사 없이 병합될 수 있다. 저장소는 `src/c_to_cpp.sh`로 이런 전환을 지원하고 AGENTS.md도 전환 절차를 안내하므로 실제로 일어나는 경로다. 검사를 실제로 빠져나간 사례가 있는지는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

기준 소스: `CUBRID/cubrid` `develop` `ca5c2153ed`.

`.github/actions/changed-files/action.yml:20`:

```text
--jq '[.files[] | select(.status == "added" or .status == "modified") | .filename] | join(" ")'
```

`check.yml`의 `license`, `code-style`, `cppcheck`, `memory-monitor-check` job은 모두 이 action의 `added_modified` 출력을 대상으로 한다. GitHub compare API의 `files[].status` 값에는 `added`, `modified`, `removed`, `renamed`, `copied`, `changed`, `unchanged`가 있다. 그중 `renamed`(이름 변경, 내용 변경 포함 가능)와 `copied`는 검사 대상에서 빠진다.

### ANALYSIS 확인 사항

1. `renamed`, `copied`, `changed` 중 어떤 상태를 검사 대상에 넣을지 정한다. `removed`는 제외해야 한다.
2. 이름만 바뀌고 내용이 같은 파일까지 검사하면 기존 위반이 새로 드러날 수 있다. 이것이 허용 가능한지 판단한다.
3. 이름을 바꾸는 PR 하나로 수정 결과를 확인한다.

## Acceptance Criteria

- 내용을 수정하며 `.c`를 `.cpp`로 이름 바꾼 파일이 PR 정적 검사 대상 목록에 나타난다.
- 삭제된 파일은 계속 검사 대상에서 빠진다.

## Related

- [CBRD-27539](https://jira.cubrid.org/browse/CBRD-27539): 에이전트 지침 감사 중 발견
