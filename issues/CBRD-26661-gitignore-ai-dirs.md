# [BUILD] .gitignore에 AI 도구 관련 캐시 디렉토리 추가

## Description

### 배경

최근 AI 코딩 도구(Claude Code, Cursor, GitHub Copilot, Aider, Continue 등)의 사용이 급증하면서, 각 도구가 프로젝트 루트에 자체 설정/캐시 디렉토리를 생성하고 있다. 이러한 디렉토리들이 `git status` 에 untracked file로 표시되어 개발자의 작업 흐름을 방해하고, 실수로 커밋될 위험이 있다.

현재 CUBRID `.gitignore` 에는 `.vscode/*`, `.omc/`, `/.cache/` 등 일부 도구 디렉토리만 등록되어 있으며, AI 도구 관련 디렉토리는 체계적으로 관리되지 않고 있다.

### 목적

주요 AI 코딩 도구가 생성하는 디렉토리 및 파일을 `.gitignore` 에 추가하여, 개발자가 개별적으로 관리할 필요 없이 깔끔한 `git status` 를 유지하도록 한다.

---

## Spec Change

### 추가 대상 항목

`.gitignore` 의 기존 `## Development Environments` 섹션 아래에 AI 도구 전용 섹션을 추가한다.

```gitignore
## AI Coding Tools
.claude/
.cursor/
.copilot/
.aider*
.continue/
.codeium/
.tabnine/
.windsurf/
.cody/
.codex/
.omc/
AGENTS.md
```

### 항목별 설명

| 디렉토리/파일 | 도구 | 설명 |
|---|---|---|
| `.claude/` | Claude Code | 세션 설정, 메모리, 프로젝트 설정 |
| `.cursor/` | Cursor IDE | AI IDE 프로젝트 설정 |
| `.copilot/` | GitHub Copilot | Copilot 에이전트 설정 |
| `.aider*` | Aider | `.aider.conf.yml`, `.aider.tags.cache.v3/` 등 |
| `.continue/` | Continue | VS Code/JetBrains AI 확장 설정 |
| `.codeium/` | Codeium (Windsurf) | AI 자동완성 도구 캐시 |
| `.tabnine/` | TabNine | AI 자동완성 도구 캐시 |
| `.windsurf/` | Windsurf IDE | Codeium 기반 AI IDE 설정 |
| `.cody/` | Sourcegraph Cody | AI 코딩 어시스턴트 설정 |
| `.codex/` | OpenAI Codex CLI | Codex CLI 설정 |
| `.omc/` | oh-my-claudecode | Claude Code 멀티 에이전트 오케스트레이션 플러그인 설정/상태 |
| `AGENTS.md` | 여러 AI 도구 | AI 에이전트 컨텍스트 파일 (개인 설정) |

### 기존 `.gitignore` 와의 관계

현재 이미 등록된 관련 항목:

- `.vscode/*` — VS Code 설정 (이미 등록됨)
- `/.cache/` — 범용 캐시 (clangd 등 포함, 이미 등록됨)
이들은 그대로 유지하고, 새 섹션은 별도로 추가한다.

---

## A/C

- [ ] `.gitignore` 에 `## AI Coding Tools` 섹션이 추가됨
- [ ] 위 표의 모든 항목이 포함됨
- [ ] 기존 `.gitignore` 항목과 중복 없음
- [ ] `git status` 에서 해당 디렉토리들이 untracked로 표시되지 않음

---

## Remarks

- 이 변경은 개발 편의성 개선이며, 빌드/런타임에 영향 없음
- AI 도구 생태계가 빠르게 변화하므로, 새 도구가 등장하면 추가 업데이트 필요할 수 있음
- `.clangd/` 디렉토리도 추가 고려 가능 (LSP 서버 캐시, AI 도구는 아니지만 개발 도구)
