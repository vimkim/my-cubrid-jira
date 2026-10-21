# [BUILD] 커밋 후 버전 표시가 갱신되지 않거나 불필요한 재빌드가 발생하는 문제

## Issue Triage

**이슈 수행 목적**: 커밋 후 빌드하면 현재 커밋이 버전에 표시되고, 커밋 정보만 바뀌었을 때 관계없는 소스를 다시 빌드하지 않게 한다.

**이슈 수행 이유**: 지금은 커밋 후 빌드해도 이전 버전이 표시될 수 있다. 버전을 갱신하려고 CMake 설정을 다시 실행하면 버전과 관계없는 소스까지 다시 빌드하게 된다.

**영향**: 개발자는 실행 파일이 어느 커밋에서 만들어졌는지 잘못 판단할 수 있고, 소스를 바꾸지 않은 커밋 뒤에도 빌드를 기다릴 수 있다. 2026-10-21 로컬 Debug 실측에서는 소스가 같은 빈 커밋 후 재구성으로 1,135개 오브젝트가 재컴파일되었고, 빌드에 152.8초가 걸렸다. 다른 구성과 CI의 영향은 추가 측정이 필요하다.

**이슈 수행 방안**: 커밋 변경을 빌드에서 감지하고, 커밋 정보를 사용하는 코드만 갱신하는 방향을 검토한다. 구체적인 구현 방식은 ANALYSIS 단계에서 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 현재 문제

커밋 후 빌드할 때 두 가지 문제가 있다.

1. 빌드만 실행하면 `cubrid_rel`에 이전 커밋이 표시될 수 있다. 개발자는 방금 만든 실행 파일의 버전을 보고도 어떤 소스로 빌드했는지 정확히 알기 어렵다.
2. 버전을 맞추려고 CMake 설정을 다시 실행하면, 버전 정보만 바뀌어도 엔진 대부분이 다시 빌드할 대상으로 잡힌다. 실제 소스 변경이 없는 빈 커밋에서도 같은 일이 발생한다.

필요한 동작은 명확하다. 평소처럼 빌드하면 현재 커밋이 표시되어야 하고, 커밋 정보만 바뀌었을 때는 그 정보를 사용하는 코드만 갱신해야 한다.

### 문제 원인

첫 번째 원인은 커밋 정보를 읽는 시점과 변경 감지 방식이다. 지금은 CMake 설정을 실행할 때 커밋 정보를 읽는다. 이후 빌드에서 감시하는 Git 파일은 새 커밋이 생겨도 내용이 그대로일 수 있어, 커밋 변경을 놓친다. 기존 재현에서도 빈 커밋 후 빌드는 할 일이 없다고 끝났고 이전 버전이 남았다.

두 번째 원인은 커밋 정보를 너무 넓게 공유하는 헤더 구조이다. 커밋 정보가 들어 있는 `version.h`를 공통 설정 헤더인 `config.h`가 포함한다. 거의 모든 엔진 코드가 이 공통 헤더를 사용하므로, 버전 문자열을 출력하지 않는 코드도 커밋 정보가 바뀌면 다시 빌드할 대상이 된다.

ccache는 이전 컴파일 결과를 재사용하여 이 비용을 줄일 수 있다. 다만 빌드 대상이 넓게 잡히는 구조는 그대로이며, 캐시를 재사용하지 못하면 실제 컴파일이 발생한다. 따라서 재빌드 대상 수와 실제 소요 시간은 따로 확인해야 한다. 이번 로컬 Debug 실측에서는 동일 커밋 전체 재빌드의 hit율이 99.43%였지만, 소스가 같은 빈 커밋 후 재구성한 빌드는 0.00%였다. 환경과 결과는 아래에 구분하여 기록한다.

### 해결 방향

빌드할 때 커밋 변경을 감지하여 버전을 갱신하고, 자주 바뀌는 커밋 정보는 필요한 코드에서만 사용하도록 분리하는 방향을 검토한다.

공통으로 필요한 릴리스 정보는 계속 제공하고, 커밋마다 바뀌는 값의 전달 범위를 좁힌다.

이렇게 하면 개발자는 별도의 CMake 설정 명령을 기억할 필요가 없고, 커밋 정보만 바뀌었을 때 관계없는 소스의 재빌드를 줄일 수 있다. 현재 제공하는 버전 표시와 디버깅 기능은 유지한다. 파일을 어떻게 나누고 갱신할지는 ANALYSIS에서 결정한다.

### 해결이 문제가 되지 않는 근거

커밋 정보를 실제로 사용하는 코드의 범위가 제한적이라는 근거가 있다. 기존 분석에서 버전 문자열은 주로 `release_string` 코드가 제공하고, 빌드 번호는 일부 broker 코드가 직접 사용하였다. 현재 확인한 직접 사용 범위는 엔진 전체보다 훨씬 좁다.

따라서 필요한 코드에 새 커밋 정보가 전달되도록 연결을 유지하면서, 관계없는 코드로 변경이 퍼지는 범위를 줄일 수 있다. 버전 표시와 디버깅 기능을 유지하면서 빌드 범위를 줄이는 방향이다.

다만 실제 수정의 안전성은 구현 후 확인해야 한다. `cubrid_rel`, broker, 패키지가 올바른 버전을 사용하는지, 커밋 정보만 바뀌면 필요한 코드만 갱신되는지, 아무 변경 없이 다시 빌드하면 불필요한 작업이 없는지를 검증한다.

## Test Build

| 근거 | 환경과 확인 범위 |
|---|---|
| 기존 CBRD-27124 재현 기록 | CUBRID `f30f1c26003e5aa8e93182648e06cad76fc77064`, `11.5.0.2374-f30f1c2`, Rocky Linux 9.6 x86_64, Debug, CMake 3.26.5, Ninja 1.10.2. 이전 재현의 환경과 결과이며 아래 2026-10-21 추가 실측과 구분한다. |
| 2026-10-21 실제 CUBRID 빌드 | A `f30f1c26003e5aa8e93182648e06cad76fc77064`, 빈 커밋 B `d606df3f6c6ef152a8f1ba9a0c2cd4e7232f01ba`. Rocky Linux 9.6 x86_64, GCC 11.5.0, ccache 4.5.1, CMake 3.26.5, Ninja 1.10.2, Debug, 16 jobs. 전용 캐시 20G, 통계 기록 활성화, 빌드별 카운터 초기화. JDBC·Manager는 제외되었고 설치·DB 실행은 하지 않았다. |
| 2026-10-21 소스 대조 | 로컬 develop `f6cac312310f39f46711693da157a08f0e725693`에도 `HEAD_FILE` 감시, 구성 단계 버전 계산, `config.h`의 `version.h` 포함 구조가 남아 있음을 확인하였다. 해당 커밋에서 동일 증상과 오브젝트 수를 실측한 것은 아니다. |
| 버전 매크로 최소 캐시 실험 | Rocky Linux 9.6 x86_64, GCC 11.5.0, ccache 4.5.1. 버전 매크로를 포함하되 사용하지 않는 단일 C 파일로 원인 설명만 확인하였다. 전체 CUBRID 빌드나 CI 성능 검증이 아니다. |
| CBRD-25560 댓글 실험 | GCC 8.5.0, ccache 3.7.7, Ninja 1.8.2, 80 논리 CPU, 기본 `-j82`. CUBRID compile+link 구간이며 third-party·JDBC를 제외한다. 원시 로그와 소스 SHA는 제공되지 않아 댓글의 측정 보고로 인용한다. |
| PR #8217 CI 로그 확인 | 2026-10-20의 OptDebug 작업 2개. 실제 소스 SHA는 각각 `be5e8fc50a745215ec65a80e2ce6e57bf1972c9f`, `5c2586fef889f2ab504a1fe82eb073f10ee7f7a1`이다. 실행 화면의 `c966fab`는 workflow 기준 커밋이며 실제 빌드 소스 SHA와 구분한다. 작업 URL과 통계 해석은 아래에 기록한다. |

유지보수 릴리스별 영향은 TBD이다. 기준 소스가 11.5 개발 버전이라는 사실만으로 모든 11.5 배포 버전이 영향받는다고 판단하지 않는다.

## Repro

### 커밋 감지와 재빌드 범위 확인

다음은 기존 커밋 감지 재현을 표준 CMake 명령으로 정리한 재검증 절차이다. 아래 2026-10-21 실측에서는 명시적으로 재구성했으며, 이 build-only 감지 절차를 새로 실행한 것은 아니다. 별도의 폐기 가능한 clone에서 실행하며, [기준 커밋의 빌드 요구사항](https://github.com/CUBRID/cubrid/blob/f30f1c26003e5aa8e93182648e06cad76fc77064/README.md#build-requirements)과 Ninja를 준비한다. 구성·빌드 중 외부 의존성 다운로드에 필요한 네트워크 접근도 필요하다.

```bash
git clone https://github.com/CUBRID/cubrid.git cbrd-27124-repro
cd cbrd-27124-repro
git switch -c repro/cbrd-27124 f30f1c26003e5aa8e93182648e06cad76fc77064
git submodule update --init --recursive

cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DCMAKE_INSTALL_PREFIX="$PWD/_install" -DWITH_CCI=ON
cmake --build build
git rev-parse --short=7 HEAD
./build/bin/cubrid_rel

git -c user.name="CBRD Repro" \
  -c user.email="cbrd-repro@example.invalid" \
  -c commit.gpgsign=false \
  commit --allow-empty -m "repro: move HEAD without source changes"
git rev-parse --short=7 HEAD
cmake --build build -- -d explain
./build/bin/cubrid_rel

cmake -S . -B build
version_h="$PWD/build/version.h"
ninja -C build -t deps |
  awk -v RS='' -v h="$version_h" 'index($0, h) {n++} END {print n}'
ninja -C build -n -d explain
cmake --build build
./build/bin/cubrid_rel
```

`ninja -t deps`는 헤더 의존 범위, `ninja -n`은 예약된 작업을 보여준다. 실제 컴파일러 실행 수와 ccache hit는 별도의 로그로 확인해야 한다.

### 버전 매크로 변경에 따른 캐시 동작 확인

다음은 최소 캐시 실험을 재현하는 명령이다. 각 조건에 새 전용 캐시를 사용하므로 기존 개발 캐시를 비우지 않는다. `env -i`로 다른 ccache 환경변수의 개입을 배제한다. A와 B는 실제 커밋 대신 버전 매크로 값만 바꾸는 모의 조건이다.

```bash
probe_dir=$(mktemp -d)
cd "$probe_dir"
printf '#include "version.h"\nint value(void) { return 42; }\n' > probe.c
printf 'stats = true\ndirect_mode = true\n' > ccache.conf

for mode in g3 g3-common g2; do
  case "$mode" in
    g3) set -- -ggdb3 ;;
    g3-common) set -- -ggdb3 -ggdb ;;
    g2) set -- -ggdb ;;
  esac
  mkdir -p "$mode/tmp"
  for revision in A B; do
    printf '#define VERSION_STRING "%s"\n' "$revision" > version.h
    gcc "$@" -E probe.c > "$mode/$revision.i"
    env -i PATH="$PATH" HOME="$HOME" \
      CCACHE_DIR="$probe_dir/$mode/cache" \
      CCACHE_CONFIGPATH="$probe_dir/ccache.conf" \
      CCACHE_TEMPDIR="$probe_dir/$mode/tmp" \
      sh -c 'ccache --zero-stats && ccache gcc "$@" -c probe.c -o probe.o && ccache --show-stats' sh "$@"
  done
  diff -u "$mode/A.i" "$mode/B.i"
done
```

`diff`는 g3와 g3-common에서 차이를 보여주기 위해 실행하며, 이때 종료 코드 1은 예상 결과이다.

### 2026-10-21 실제 빌드 측정 방법

기준 커밋 A를 새 전용 캐시로 빌드한 뒤, 오브젝트를 정리하고 캐시는 유지하여 같은 커밋을 다시 빌드하였다. 이때 구성된 오브젝트 1,189개가 모두 제거된 것을 확인하였다. Ninja clean은 RapidJSON의 비어 있지 않은 include 디렉터리를 제거하지 못해 종료 코드 1을 반환했으므로, 실제 오브젝트 제거 여부를 별도로 검증하였다.

다음으로 A와 Git tree가 동일한 빈 커밋 B를 `git commit-tree`로 만들고 detached HEAD에서 사용하였다. CMake를 재구성하고 캐시는 유지한 채 카운터만 초기화하여 빌드하였다. 이 단계에서는 오브젝트 정리 명령을 실행하지 않았다. 이후 원래 커밋으로 복귀하여 다시 재구성·빌드하였다. 두 커밋의 `compile_commands.json`은 같았으며, 실제 compile 작업 수는 빌드 로그에서 집계하였다.

각 빌드의 hit율은 `ccache --print-stats`와 `ccache --show-stats --verbose`로 확인하였다. `CCACHE_NOSTATS`를 적용하지 않았고, 별도 stats log도 저장하였다. 재구성 후 빌드 구간 직전에 카운터를 초기화하여 구성 단계의 호출은 해당 구간 통계에서 제외하였다. [상세 환경·재현 절차·로그 위치](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27124/ccache-commit-change-measurement_2026-10-21.md)에 원시 근거와 한계를 기록한다.

## Expected Result

- 빈 커밋 뒤 별도의 구성 명령 없이 일반 빌드만 실행해도 `cubrid_rel`이 현재 소스 커밋을 표시한다.
- 커밋 수·해시만 바뀔 때 변동 버전 값을 직접 사용하지 않는 오브젝트의 불필요한 재빌드를 피한다. 필요한 relink와 패키지 메타데이터 갱신 범위는 ANALYSIS에서 정한다.
- 버전 정합성을 유지하며, 캐시 유무에 따른 효과를 실제 작업 수와 시간으로 검증한다. CI hit 비율의 목표값은 현재 합의된 요구사항이 아니다.

## Actual Result

기존 이슈 기록에서는 빈 커밋 뒤 첫 빌드가 `ninja: no work to do.`로 끝나고 `cubrid_rel`은 이전 해시를 유지하였다. 재구성 후 `version.h`와 `config.h`의 의존성 조회 결과는 각각 1,135개였다. 이 수를 현재 구성의 보편적인 재컴파일 수로 사용하지 않는다.

최소 캐시 실험에서는 첫 컴파일로 A를 캐시에 저장한 뒤 매크로만 B로 변경한 두 번째 컴파일에서 다음 결과를 확인하였다.

| 옵션 | 전처리 결과의 `VERSION_STRING` 정의 | A → B 전처리 결과 | 두 번째 컴파일의 ccache 결과 |
|---|---|---|---|
| `-ggdb3` | 남는다 | 달라진다 | hit 0, miss 1 |
| `-ggdb3 -ggdb` | 남는다 | 달라진다 | hit 0, miss 1 |
| `-ggdb` | 남지 않는다 | 같다 | preprocessed hit 1, miss 0 |

작은 예제에서는 버전 매크로 변경 때문에 `-ggdb3`의 캐시를 재사용하지 못하는 현상이 재현되었다. 아래에는 같은 기준 소스에서 추가로 수행한 실제 CUBRID Debug 빌드 결과를 기록한다.

### 2026-10-21 실제 CUBRID Debug 빌드 실측

| 조건 | 실제 compile 작업 수 | Hit | Miss | Hit율 | 빌드 시간 |
|---|---:|---:|---:|---:|---:|
| A, 빈 캐시에서 최초 빌드 | 1,189 | 37 | 3,999 | 0.92% | 275.1초 |
| A, 오브젝트 제거 후 같은 커밋 전체 재빌드 | 1,189 | 1,565 | 9 | 99.43% | 23.4초 |
| B, 캐시 유지 및 재구성 후 증분 빌드 | **1,135** | **0** | **2,270** | **0.00%** | **152.8초** |
| A로 복귀, 캐시 유지 및 재구성 후 빌드 | 1,135 | 1,132 | 6 | 99.47% | 31.2초 |

모든 빌드는 성공하였다. A와 B의 소스 tree는 동일하며, 재구성으로 `version.h`의 `EXTRA_VERSION`, `BUILD_NUMBER`, `VERSION_STRING`만 바뀌었다. 커밋 수는 2374에서 2375로, 버전은 `11.5.0.2374-f30f1c2`에서 `11.5.0.2375-d606df3`으로 바뀌었다. Ninja dry-run과 실제 빌드 로그 모두 compile 작업 1,135개를 확인했고, `cubrid_rel`은 B의 새 버전을 표시하였다. 재구성에는 빌드 시간과 별도로 1.35초가 걸렸다.

**1,135는 오브젝트 수이고 2,270은 ccache miss 호출 카운터이다.** 이번 구성은 ccache launcher와 ccache compiler wrapper가 중첩되어 있었다. Hit율은 `hit / (hit + miss)`이며 uncacheable 호출을 제외한다. 같은 출력의 primary storage hit 49.93%는 컴파일 결과 재사용 hit율 0.00%와 구분한다.

각 조건은 공유 서버에서 한 번씩 측정하였다. 최초·동일 커밋 빌드는 외부 라이브러리 작업도 포함하므로 시간 차이를 동일 작업량의 순수 캐시 비용으로 해석하지 않는다. 이번 결과는 기준 커밋의 로컬 Debug 구성에 한정하며, 현재 develop·OptDebug·Release·CI의 실제 hit율이나 반복 성능은 확인하지 않았다. 기존 캐시를 유지한 동일 커밋 대조군에서 캐시 재사용이 확인되었고, 커밋 변경 후 재구성한 조건에서는 재사용이 사라졌다는 점이 확인된 결과이다. 원래 브랜치·커밋·버전 헤더·기존 Git 상태는 복구하였다.

## Additional Information

### CI의 캐시 hit율은 어떻게 해석해야 하는가

[CBRD-25560의 실험 댓글](http://jira.cubrid.org/browse/CBRD-25560?focusedCommentId=4777097&page=com.atlassian.jira.plugin.system.issuetabpanels%3Acomment-tabpanel#comment-4777097)은 버전 헤더를 바꾼 Debug 빌드에서 CUBRID 소스의 hit가 `0/1170`이었다고 보고하였다. 캐시 없음 52.3초, ccache 사용 58.8초였다. OptDebug는 작은 예제만 확인했다고 명시하였다. 전체 빌드에는 외부 라이브러리의 캐시 효과도 있으므로 측정 범위를 구분해야 한다.

[후속 댓글](http://jira.cubrid.org/browse/CBRD-25560?focusedCommentId=4777107&page=com.atlassian.jira.plugin.system.issuetabpanels%3Acomment-tabpanel#comment-4777107)에는 실제 CI hit가 40% 이상이라는 보고가 있다. 이번 요청에서 제공된 PR #8217 로그의 59.82%를 확인한 결과, 이 수치는 공유 캐시에 쌓인 과거 통계였다.

| 확인한 OptDebug 작업 | direct hit / preprocessed hit / miss | 표시된 hit율 |
|---|---|---|
| [PR #8217 첫 번째 빌드](https://github.com/CUBRID/cubrid/actions/runs/39377825558/job/118479884072) | `100948 / 1296 / 68689` | `59.82%` |
| [PR #8217 두 번째 빌드](https://github.com/CUBRID/cubrid/actions/runs/39383918389/job/118499169707) | `100948 / 1296 / 68689` | `59.82%` |

서로 다른 커밋을 빌드했지만 카운터와 통계 갱신 시각(`Tue Oct 20 12:58:24 2026`)이 같았다. [해당 CI 설정](https://github.com/CUBRID/cubrid/blob/c966fabc6b4c8ac86aa4b5abb0a4cbefae01bf5b/.github/workflows/gha-ci.yml#L481-L562)과 두 로그에서, 이 PR 빌드들은 캐시를 읽기만 하고 통계 기록을 끄는 `CCACHE_READONLY=1 CCACHE_NOSTATS=1` 설정으로 실행된 것을 확인하였다.

따라서 59.82%만으로는 이 두 빌드에서 캐시가 얼마나 재사용되었는지 알 수 없다. 기존 실험이 틀렸다고 판단할 근거도 되지 않는다. 실제 빌드별 hit율과 시간은 통계가 기록되는 별도 검증 환경에서 확인해야 한다.

### 원인과 해결 방향을 뒷받침하는 자료

- [2026-10-21 로컬 Debug 빌드 실측 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27124/ccache-commit-change-measurement_2026-10-21.md): 동일 커밋 재빌드, 빈 커밋 후 재구성, 원래 커밋 복귀의 카운터·작업 수·시간과 한계.
- [커밋 정보를 읽고 변경을 감시하는 코드](https://github.com/CUBRID/cubrid/blob/f30f1c26003e5aa8e93182648e06cad76fc77064/CMakeLists.txt#L102-L183): CMake 설정을 실행할 때 Git 정보를 읽고 `HEAD` 파일을 감시한다.
- [공통 헤더의 version.h 포함](https://github.com/CUBRID/cubrid/blob/f30f1c26003e5aa8e93182648e06cad76fc77064/cmake/config.h.cmake#L95): 커밋 정보 변경이 엔진 전반에 퍼지는 경로이다.
- [기존 소비 코드 분석과 계획](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27124/wayfinder/map.md): `VERSION_STRING`은 주로 `release_string` 코드가 사용하고, `BUILD_NUMBER`는 `release_string.c`와 broker 소스 7개가 직접 사용한 것으로 정리되어 있다. 구현 전 최종 사용 범위를 재확인한다.
- [GCC 문서](https://gcc.gnu.org/onlinedocs/gcc/Debugging-Options.html)와 [ccache 3.7.7 문서](https://ccache.dev/manual/3.7.7.html): 디버그 정보에 매크로가 포함되는 조건과 캐시 통계의 의미를 설명한다.

본 이슈는 버전 갱신과 불필요한 재빌드를 다룬다. 캐시 도구의 도입·설정·사용 안내는 CBRD-25560에서 다룬다. 두 이슈에는 `relates to` 링크를 추가하고 양쪽에서 확인하였다.

## Triage Request

두 문제를 확인하고, 작성자 측에 ANALYSIS를 배정할 것을 요청한다. 분석에서는 커밋 변경 감지와 버전 정보 분리 방법을 정하고, 아래 결과를 확인할 검증 계획을 마련한다.

1. 평소처럼 빌드하면 현재 커밋이 표시되고, broker와 패키지의 버전도 올바르게 유지된다.
2. 커밋 정보만 바뀌면 필요한 코드만 갱신되고, 아무 변경 없이 다시 빌드하면 불필요한 작업이 없다.
3. Debug·OptDebug의 실제 빌드별 캐시 hit와 소요 시간을 측정하여 개선 효과를 설명할 수 있다.

우선순위와 담당자는 triage에서 결정한다.
