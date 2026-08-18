# [BUILD] cubrid_rel 커밋 버전 갱신 누락과 광범위한 재컴파일 문제

## Issue Triage

**이슈 수행 목적**: 이번 이슈는 커밋 후 CMake 빌드에서 발생하는 버전 정합성 문제와 개발 생산성 문제를 함께 해결한다.

**이슈 수행 이유**: 현재 빌드에서는 서로 다른 실행 경로에서 다음 문제가 나타난다.

| 실행 경로 | **AS-IS (현재 동작 / 배경)** | 영향 |
|-----------|-----------------------------|------|
| 커밋 후 일반 CMake 빌드 | `cubrid_rel`에 이전 커밋의 해시가 남을 수 있다. | 버전 정합성 문제 - 개발자가 방금 만든 바이너리의 소스 커밋을 잘못 판단할 수 있다. |
| CMake 재구성 후 빌드 | `empty commit`(파일 변경이 없는 커밋)처럼 소스 코드에 영향이 없는 커밋도 버전 정보가 바뀌면 현재 Debug 빌드용 Ninja 의존성 그래프에서 1,135개 오브젝트가 재컴파일 대상이 된다. | 개발 생산성 문제 - 작은 변경을 확인할 때도 엔진 대부분을 다시 빌드하므로 개발·검증이 늦어진다. |

**TO-BE (목표 상태 / 기대 동작)**:

1. 커밋 후 일반 CMake 빌드만 실행해도 `cubrid_rel`의 해시가 현재 `HEAD`와 일치한다.
2. 커밋 수/해시만 바뀌면 버전 값을 실제로 사용하는 파일만 다시 컴파일한다.

**이슈 수행 방안**: 구현 방식은 아직 합의되지 않았다. 세부 결정과 검증 계획은 [Wayfinder 계획 tracker](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27124/wayfinder/map.md)에서 현재 frontier를 따라 단계적으로 확정한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: 최상위 CMake 버전 생성 규칙, 생성 헤더, `release_string` 및 `broker`(응용 프로그램 연결을 처리하는 CUBRID 중계 모듈) 버전 소비 경로가 대상이다. SQL/API, 디스크 포맷, 네트워크 프로토콜 호환성 변경은 없다.

## Description

CMake는 구성 단계에서 `git rev-list`와 `git rev-parse`를 실행해 커밋 수와 해시를 계산한다. 계산 결과는 `CUBRID_VERSION`과 `BUILD_NUMBER`를 거쳐 생성된 `version.h`에 기록된다. 빌드 단계에는 현재 Git 커밋 위치를 다시 읽는 독립 규칙이 없다.

일반 브랜치에서 `HEAD` 파일은 커밋 ID가 아니라 `ref: refs/heads/<branch>`를 담는다. 이 형식을 `symbolic HEAD`(브랜치 ref 이름을 담는 `HEAD` 형식)라고 한다. 새 커밋이 생기면 branch ref가 이동하지만 `HEAD` 파일의 내용은 그대로다. 현재 CMake 규칙은 일반 clone의 `.git/HEAD` 또는 linked worktree(한 저장소에서 별도 작업 디렉터리와 `HEAD`를 사용하는 Git 작업 트리)의 worktree별 `HEAD`를 `configure_file(... COPYONLY)` 입력으로 등록한다.

`version.h` 안의 `EXTRA_VERSION`, `BUILD_NUMBER`, `VERSION_STRING`은 커밋에 따라 달라진다. `config.h`가 `version.h`를 포함하고 엔진 전반이 `config.h`를 사용하므로, 이 세 매크로의 의존성이 실제 버전 소비 범위를 넘어 전파된다.

```
[커밋 위치 감지]
refs/heads/<branch> 이동
  └ ★ CMake 입력으로 등록된 symbolic HEAD 파일은 그대로

[버전 의존성]
git rev-list / git rev-parse                CMake 구성 단계
  └ CUBRID_VERSION, BUILD_NUMBER
       └ 생성된 version.h
            └ config.h
                 └ ★ 실제 버전 소비 범위를 넘어 엔진 오브젝트 전반으로 전파
```

## Test Build

- 소스 커밋: `f30f1c26003e5aa8e93182648e06cad76fc77064`
- 빌드 버전: `CUBRID 11.5.0 (11.5.0.2374-f30f1c2) (64bit debug build for Linux)`
- 운영체제: Rocky Linux 9.6, x86_64
- 도구 버전: CMake 3.26.5 / Ninja 1.10.2

## Repro

```bash
export CUBRID="$PWD/_install"

git switch -c repro/cbrd-27124
cmake --preset debug
cmake --build --preset debug

git rev-parse --short=7 HEAD
./build_preset_debug/bin/cubrid_rel

git -c user.name="CBRD Repro" \
  -c user.email="cbrd-repro@example.invalid" \
  -c commit.gpgsign=false \
  commit --allow-empty -m "repro: move HEAD without source changes"
git rev-parse --short=7 HEAD

cmake --build --preset debug -- -d explain 2>&1 | tee /tmp/cbrd-27124-build-only.log
./build_preset_debug/bin/cubrid_rel

cmake --preset debug
version_h="$PWD/build_preset_debug/version.h"
config_h="$PWD/build_preset_debug/config.h"
ninja -C build_preset_debug -t deps |
  awk -v RS='' -v h="$version_h" 'index($0, h) {n++} END {print n}'
ninja -C build_preset_debug -t deps |
  awk -v RS='' -v h="$config_h" 'index($0, h) {n++} END {print n}'

ninja -C build_preset_debug -n -d explain 2>&1 | tee /tmp/cbrd-27124-reconfigure.log
grep -Ec 'Building (C|CXX) object' /tmp/cbrd-27124-reconfigure.log

cmake --build --preset debug
./build_preset_debug/bin/cubrid_rel
```

## Expected Result

- `empty commit` 후 CMake 구성을 직접 실행하지 않아도 `cubrid_rel`의 해시가 `git rev-parse --short=7 HEAD`와 일치한다.
- 커밋 수/해시만 바뀌면 버전 값 직접 소비자만 재컴파일하고, 관계없는 엔진 오브젝트는 재컴파일하지 않는다.

## Actual Result

- `empty commit` 후 첫 빌드 로그는 `ninja: no work to do.`를 출력하고, `cubrid_rel`은 커밋 전 해시를 유지한다.
- CMake 구성 후 두 의존성 조회 명령은 각각 `1135`를 출력한다.

## Additional Information

### Wayfinder 계획 tracker

- **Canonical map**: [CBRD-27124 CMake build version refresh](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27124/wayfinder/map.md)
- **목적지**: 구현자가 추가 설계 질문 없이 작업을 시작할 수 있는 구현 명세, 실행 순서, 검증 계약을 만든다. 실제 소스 구현은 map 범위 밖이다.
- **현재 frontier**: [Git 커밋 갱신 계약 잠금](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27124/wayfinder/tickets/T1-lock-git-revision-refresh-contract.md)과 [변동 버전 의존성 경계 잠금](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27124/wayfinder/tickets/T2-lock-volatile-version-dependency-boundary.md)을 독립적으로 결정할 수 있다.
- **후속 흐름**: 런타임·패키지 버전 정체성 계약, 최소 재빌드 예산, 검증 및 CI 행렬을 차례로 잠근 뒤 구현 가능한 명세와 JIRA handoff를 조립한다.

### 버전 생성 위치

| 위치 | 역할 |
|------|------|
| `CMakeLists.txt:102-117` | 일반 clone과 linked worktree의 `HEAD_FILE` 선택 |
| `CMakeLists.txt:133-167` | CMake 구성 시 커밋 수/해시 계산 |
| `CMakeLists.txt:168-169` | `HEAD_FILE`을 CMake 구성 재실행 의존성으로 등록 |
| `CMakeLists.txt:174-183` | `CUBRID_VERSION`, `BUILD_NUMBER` 구성 |
| `CMakeLists.txt:601-603` | `config.h`, `version.h` 생성 |
| `cmake/config.h.cmake:95` | 모든 `config.h` 소비자에게 `version.h` 의존성 전파 |
| `cmake/version.h.cmake:25-35` | 커밋마다 바뀌는 매크로와 고정 릴리스 매크로를 한 헤더에 함께 정의 |

### 실제 버전 값 소비 범위

`cubrid_rel`은 `src/executables/cubrid_version.c` 자체에 해시를 갖지 않고 `cubridsa`(클라이언트와 서버 기능을 한 프로세스에서 실행하는 standalone 라이브러리)의 `release_string.c`가 제공하는 문자열을 출력한다. 커밋마다 바뀌는 매크로의 직접 소비 범위는 다음과 같이 제한적이다.

| 매크로 | 직접 소비 위치 |
|-------|----------------|
| `EXTRA_VERSION` | 생성 헤더 외 직접 소비 없음 |
| `VERSION_STRING` | `src/base/release_string.c`, `src/base/release_string.h` |
| `BUILD_NUMBER` | `src/base/release_string.c`, broker 소스 7개 |

### Git 작업 트리 지원 이력

커밋 `41e5be7ee8` (`[CBRD-25432] Add Support for Git Worktrees in CMake Configuration`)은 `.git/HEAD` 대신 현재 worktree의 `HEAD`를 찾도록 수정했다. linked worktree 경로 문제는 해결했지만 symbolic `HEAD`가 가리키는 실제 branch ref 이동은 여전히 감지하지 않는다.

### 수락 조건

- [ ] 최초 CMake 구성 이후 빌드만 실행해도 `cubrid_rel` 해시와 현재 `HEAD`가 일치한다.
- [ ] revision-only 변경 후 버전 값 직접 소비자 밖의 C/C++ 오브젝트 재컴파일이 발생하지 않는다.
