# [BUILD] 커밋 변경 시 버전 갱신 누락과 불필요한 재컴파일·ccache 재사용 저하

## Issue Triage

**이슈 수행 목적**: 개발자와 QA가 빌드 결과의 커밋을 정확히 확인하고, 커밋 정보만 바뀔 때 불필요한 재컴파일로 기다리지 않게 한다. CI의 OptDebug 빌드에서도 버전 정보 변경 때문에 기존 ccache를 재사용하지 못하는 상황을 줄인다.

**이슈 수행 이유**: 본 이슈는 [CBRD-25560](https://jira.cubrid.org/browse/CBRD-25560)의 ANALYSIS에서 확인한 빌드·캐시 문제의 후속 이슈이기도 하다. 현재는 커밋 후 빌드해도 이전 버전이 남을 수 있고, 버전을 갱신하면 관계없는 소스까지 재컴파일된다. 로컬 Debug 실측에서는 이때 ccache hit율도 0%가 되었다. CBRD-25560은 Won't Do로 종료되었으나, 확인된 문제는 남아 있어 본 이슈에서 후속 분석과 개선을 진행할 필요가 있다.

**영향**: 개발자·QA는 테스트한 실행 파일의 소스 버전을 잘못 판단하거나 불필요한 빌드를 기다릴 수 있다. CI 관리자는 캐시를 운영하면서도 커밋 변경 때 컴파일 자원을 반복 소비할 수 있다. 2026-10-21 로컬 Debug에서는 소스가 같은 빈 커밋 후 1,135개 오브젝트가 재컴파일되었고, ccache hit율 0%, 빌드 시간 152.8초를 기록했다. OptDebug CI의 실제 hit율과 시간 영향은 추가 측정이 필요하다. 업무 중단 수준의 문제는 아니므로 높은 우선순위의 긴급 대응을 요청하는 사안은 아니다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 배경과 CBRD-25560의 후속 관계

[CBRD-25560](https://jira.cubrid.org/browse/CBRD-25560)은 ccache를 빌드에 자동 적용하는 제안이었다. 해당 이슈를 재검토하는 과정에서 인치준님이 커밋 버전 정보가 바뀌면 Debug 빌드의 CUBRID 소스에서 ccache를 재사용하지 못한다는 실측 결과를 보고했다. 이는 본 이슈가 다루던 버전 갱신과 광범위한 재빌드 문제에 연결된다.

2026-10-22 보고자와 담당자가 협의하여 CBRD-25560을 Won't Do로 종료했다. 종료 댓글에는 ANALYSIS에서 확인한 문제의 후속을 CBRD-27124에서 다루고, 기존 담당자가 계속 진행한다고 기록되어 있다. 따라서 **CBRD-25560의 종료는 그 과정에서 발견한 빌드·캐시 문제가 해결되었다는 뜻이 아니며, 본 이슈가 그 후속을 이어서 다룬다.**

보고자와 인치준님은 인치준님이 후속을 진행하기로 협의했다. 다만 2026-10-22 확인 시 본 이슈의 JIRA 상태는 Open, 우선순위는 Trivial, 담당자는 `cubrid todo`이다. 협의 내용을 바탕으로 triage 재확인과 담당자 배정을 요청한다.

### 무엇이 문제인가

개발자와 QA는 커밋 후 평소처럼 빌드하여 현재 소스에 대응하는 실행 파일을 얻으려 한다. CI 관리자는 변경되지 않은 코드의 컴파일 결과를 ccache에서 재사용하여 반복 빌드 비용을 줄이려 한다. 현재 빌드에서는 다음 문제가 연결되어 발생한다.

1. **빌드 결과의 커밋 표시가 갱신되지 않을 수 있다.** 기존 재현에서 소스 변경이 없는 빈 커밋 후 빌드는 `ninja: no work to do.`로 끝났고, `cubrid_rel`에는 이전 커밋이 남았다.
2. **버전을 갱신하면 관계없는 코드까지 다시 빌드한다.** CMake 설정을 다시 실행하여 새 커밋 정보를 반영하면, 버전 문자열을 사용하지 않는 엔진 코드도 재컴파일 대상이 된다. 2026-10-21 로컬 Debug 실측에서는 소스 내용이 같은 두 커밋 사이에서 1,135개 오브젝트가 재컴파일되었다.
3. **캐시가 있어도 이 재컴파일을 피하지 못할 수 있다.** 같은 실측에서 동일 커밋의 전체 재빌드는 ccache hit율 99.43%였지만, 커밋 정보만 바꾸고 재구성한 빌드는 0.00%였다. 캐시를 준비해 두었어도 버전 정보 변경으로 재사용이 사라진 것이다.

필요한 결과는 일반 빌드만으로 현재 커밋을 표시하면서, 커밋 정보만 달라진 경우 관계없는 코드의 재컴파일과 캐시 무효화를 줄이는 것이다. 이 요구는 로컬 개발 빌드와 OptDebug CI의 캐시 활용 모두에 관련된다.

### 문제 원인

**커밋 변경을 놓치는 원인**은 버전 계산 시점과 변경 감지 방식이다. 커밋 정보는 CMake 설정 단계에서 읽고, 후속 빌드는 Git의 `HEAD` 파일을 감시하여 재구성이 필요한지 판단한다. 같은 브랜치에서 커밋하면 실제 커밋 값이 바뀌어도 `HEAD` 파일에는 같은 브랜치 이름이 남을 수 있다. 이 경우 재구성이 실행되지 않아 버전 표시가 이전 값으로 유지될 수 있다.

**재빌드가 넓게 발생하는 원인**은 커밋 정보를 공통 헤더로 전달하는 구조이다. 커밋 수와 해시가 들어 있는 `version.h`를 공통 설정 헤더인 `config.h`가 포함한다. 다수의 엔진 소스가 이 공통 헤더를 사용하므로, 버전 정보를 출력하지 않는 코드도 커밋 값이 바뀌면 빌드 입력이 달라진 것으로 처리된다.

**Debug·OptDebug에서 캐시 재사용까지 저하될 수 있는 원인**은 위 헤더 구조와 디버그 옵션의 결합이다. 두 구성은 `-ggdb3`를 사용하며, GCC의 디버그 레벨 3에는 매크로 정의 정보가 포함된다. 최소 실험에서는 사용하지 않는 버전 매크로의 값만 바꾸어도 전처리 결과가 달라져 ccache miss가 발생했다. 로컬 CUBRID Debug 빌드에서도 같은 조건의 hit율 0%가 확인되었다. OptDebug CI에도 이 원인이 작용할 가능성이 있으나, 실제 빌드별 비율은 아직 측정하지 않았다. [GCC 디버그 옵션 설명](https://gcc.gnu.org/onlinedocs/gcc/Debugging-Options.html)

CI 보고서에 과거 누적 통계를 표시한 문제는 위 캐시 무효화와 별개의 측정 문제이다. 보고 방식을 고쳐도 버전 헤더 때문에 캐시를 재사용하지 못하는 원인 자체가 해결되지는 않는다. 반대로 누적 통계만 보고 현재 CI의 실제 hit율이 0%라고 확정할 수도 없다. 확인 근거는 `Additional Information`에 기록한다.

### 문제 영향

| 영향을 받는 사람 | 하려는 작업과 현재의 어려움 | 업무상 영향과 확인 범위 |
|---|---|---|
| 개발자 | 수정·커밋 후 빌드하여 결과를 확인하려 하지만, 버전 표시를 갱신하려면 별도 재구성이 필요할 수 있고 그 과정에서 관계없는 코드도 다시 컴파일된다. | 코드 변경과 무관한 빌드 대기가 발생한다. 로컬 Debug에서 1,135개 재컴파일과 152.8초 소요를 실측했다. 일상 작업의 발생 빈도와 누적 대기 시간은 미측정이다. |
| QA·문제 분석 담당자 | 실행 파일의 버전을 보고 테스트 대상이나 오류가 발생한 소스 커밋을 확인하려 하지만, 출력에 이전 커밋이 남을 수 있다. | 테스트·재현 결과를 잘못된 커밋에 연결할 위험이 있고, 정확한 실행 파일을 사용했는지 추가 확인이 필요할 수 있다. 실제 오판 사례가 확인된 것은 아니다. |
| CI 관리자와 결과를 기다리는 개발자 | OptDebug 빌드에서 기존 캐시로 변경 없는 코드의 컴파일을 줄이려 하지만, 커밋 버전 변경이 캐시 재사용을 막을 수 있다. | 반복 컴파일에 따른 CPU 사용과 CI 결과 대기가 늘어날 가능성이 있다. CI의 실행별 hit율, 자원 사용량, 전체 소요 시간의 증가는 추가 측정이 필요하다. |

### 왜 해결해야 하는가

이 문제를 미루면 버전을 정확히 표시하기 위해 재구성할수록 넓은 재빌드가 발생하는 구조가 남는다. 개발자에게 매번 재구성을 요구하는 우회 방법은 버전 표시만 갱신할 뿐 빌드 대기와 캐시 무효화를 줄이지 못한다. CI 통계 보고를 바로잡는 작업도 실제 캐시 재사용을 회복하는 작업을 대신하지 못한다.

CBRD-25560 분석과 후속 실측을 통해, 단순한 버전 표시 문제에 더해 기존 캐시를 활용하지 못하는 비용이 확인되었다. 따라서 기존의 낮은 중요도 판단을 재검토할 근거가 생겼다. 다만 빌드가 실패하거나 업무가 중단되는 수준으로 확인된 문제는 아니며, 보고자도 여전히 우선순위가 높지는 않다고 판단한다. CI의 실제 영향과 다른 업무를 함께 고려하여 수행 순서를 정한다.

### 기대 효과와 남은 검증

커밋 변경을 정확히 감지하고 변동 버전 정보가 관계없는 코드의 컴파일 입력을 바꾸지 않게 하면, 버전 정합성을 유지하면서 로컬의 불필요한 재빌드를 줄일 수 있다. **OptDebug CI에서도 같은 원인이 작용한다면, 커밋 정보 변경 때문에 CUBRID 소스의 ccache hit율이 0%가 되는 상황을 방지하고 기존 캐시를 재사용할 수 있게 할 가능성이 있다.**

이는 구현 후 검증할 기대 효과이다. 기존 캐시의 유무, 소스·빌드 경로, 컴파일러 옵션 등 다른 조건도 캐시 재사용에 영향을 주므로, 모든 CI 실행의 hit율을 보장하지 않는다. 2026-10-21 댓글의 OptDebug hit율 50% 이상은 제안된 목표이며 확정된 완료 기준이 아니다. ANALYSIS에서 실제 실행별 통계를 확보하여 목표와 평가 방법을 정한다.

구체적인 해결 방식은 ANALYSIS에서 결정한다. 커밋 정보의 사용 범위를 좁히는 방향을 후보로 검토하되, `cubrid_rel`, broker, 패키지의 버전과 기존 디버깅 기능이 유지되는지 함께 확인한다.

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
- 캐시가 준비된 동일 조건에서 Debug·OptDebug의 관계없는 코드가 커밋 정보 변경만으로 캐시 재사용을 잃지 않도록 한다. OptDebug CI의 실제 hit·miss와 소요 시간을 개선 전후 측정하여 효과를 검증한다.
- 버전 정합성과 기존 디버깅 기능을 유지한다. CI hit 비율의 수치 목표와 최종 검증 조건은 ANALYSIS에서 정한다.

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

[CBRD-25560의 실험 댓글](https://jira.cubrid.org/browse/CBRD-25560?focusedCommentId=4777097&page=com.atlassian.jira.plugin.system.issuetabpanels%3Acomment-tabpanel#comment-4777097)은 버전 헤더를 바꾼 Debug 빌드에서 CUBRID 소스의 hit가 `0/1170`이었다고 보고하였다. 캐시 없음 52.3초, ccache 사용 58.8초였다. OptDebug는 작은 예제만 확인했다고 명시하였다. 전체 빌드에는 외부 라이브러리의 캐시 효과도 있으므로 측정 범위를 구분해야 한다.

[후속 댓글](https://jira.cubrid.org/browse/CBRD-25560?focusedCommentId=4777107&page=com.atlassian.jira.plugin.system.issuetabpanels%3Acomment-tabpanel#comment-4777107)에는 실제 CI hit가 40% 이상이라는 보고가 있다. 이후 PR #8217 로그의 59.82%를 확인한 결과, 이 수치는 공유 캐시에 쌓인 과거 통계였다.

| 확인한 OptDebug 작업 | direct hit / preprocessed hit / miss | 표시된 hit율 |
|---|---|---|
| [PR #8217 첫 번째 빌드](https://github.com/CUBRID/cubrid/actions/runs/39377825558/job/118479884072) | `100948 / 1296 / 68689` | `59.82%` |
| [PR #8217 두 번째 빌드](https://github.com/CUBRID/cubrid/actions/runs/39383918389/job/118499169707) | `100948 / 1296 / 68689` | `59.82%` |

서로 다른 커밋을 빌드했지만 카운터와 통계 갱신 시각(`Tue Oct 20 12:58:24 2026`)이 같았다. [해당 CI 설정](https://github.com/CUBRID/cubrid/blob/c966fabc6b4c8ac86aa4b5abb0a4cbefae01bf5b/.github/workflows/gha-ci.yml#L481-L562)과 두 로그에서, 이 PR 빌드들은 캐시를 읽기만 하고 통계 기록을 끄는 `CCACHE_READONLY=1 CCACHE_NOSTATS=1` 설정으로 실행된 것을 확인하였다.

따라서 59.82%만으로는 이 두 빌드에서 캐시가 얼마나 재사용되었는지 알 수 없다. 기존 실험이 틀렸다고 판단할 근거도 되지 않는다. 실제 빌드별 hit율과 시간은 통계가 기록되는 별도 검증 환경에서 확인해야 한다. QA팀 태우님께 보고 문제를 전달했으며, 2026-10-21 본 이슈 댓글에는 보고 스크립트를 수정 중이라고 기록되어 있다. 현재 수정 완료 여부는 별도 확인이 필요하다. [통계 설정·추가 PR 로그 확인 기록](https://github.com/vimkim/my-cubrid-docs/blob/main/code-analysis/build/cubrid-ci-ccache-statistics-note_2026-10-21.md)

[ccache 3.7.7 공식 문서](https://ccache.dev/manual/3.7.7.html#_configuration)에서도 읽기 전용 캐시 조회와 통계 기록 여부는 별도 설정이다. `CCACHE_NOSTATS=1`로 실행했다는 사실만으로 hit가 없었다고 판단하지 않는다.

### 원인과 해결 방향을 뒷받침하는 자료

- [2026-10-21 로컬 Debug 빌드 실측 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27124/ccache-commit-change-measurement_2026-10-21.md): 동일 커밋 재빌드, 빈 커밋 후 재구성, 원래 커밋 복귀의 카운터·작업 수·시간과 한계.
- [커밋 정보를 읽고 변경을 감시하는 코드](https://github.com/CUBRID/cubrid/blob/f30f1c26003e5aa8e93182648e06cad76fc77064/CMakeLists.txt#L102-L183): CMake 설정을 실행할 때 Git 정보를 읽고 `HEAD` 파일을 감시한다.
- [공통 헤더의 version.h 포함](https://github.com/CUBRID/cubrid/blob/f30f1c26003e5aa8e93182648e06cad76fc77064/cmake/config.h.cmake#L95): 커밋 정보 변경이 엔진 전반에 퍼지는 경로이다.
- [기존 소비 코드 분석과 계획](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27124/wayfinder/map.md): `VERSION_STRING`은 주로 `release_string` 코드가 사용하고, `BUILD_NUMBER`는 `release_string.c`와 broker 소스 7개가 직접 사용한 것으로 정리되어 있다. 구현 전 최종 사용 범위를 재확인한다.
- [GCC 문서](https://gcc.gnu.org/onlinedocs/gcc/Debugging-Options.html)와 [ccache 3.7.7 문서](https://ccache.dev/manual/3.7.7.html): 디버그 정보에 매크로가 포함되는 조건과 캐시 통계의 의미를 설명한다.

### 후속 작업의 범위

본 이슈는 CBRD-25560의 후속으로 커밋 버전 갱신, 불필요한 재빌드, 그에 따른 Debug·OptDebug의 캐시 재사용 저하를 다룬다. CBRD-25560에서 제안했던 ccache 자동 도입을 그대로 다시 추진하는 것으로 해석하지 않는다.

CBRD-25560 분석에서 확인한 ccache 중첩 실행과 환경 설정도 후속 분석의 참고 사항이다. 버전 정보 전달을 개선하는 것만으로 설정 충돌까지 해결된다고 가정하지 않고, 측정 조건과 추가 조치 필요성을 ANALYSIS에서 확인한다. CI 통계 보고 수정은 QA팀과 진행 상황을 확인하고, 본 이슈의 효과를 판단할 실행별 측정에 연결한다.

## Triage Request

CBRD-25560의 종료 후에도 남아 있는 버전 갱신·재빌드·캐시 재사용 문제를 본 이슈에서 이어서 다루는 것으로 재확인할 것을 요청한다. 보고자와 기존 담당자의 협의에 따라 인치준님이 후속 ANALYSIS를 진행할 수 있도록 배정을 검토한다. 최종 담당자와 우선순위는 triage에서 결정한다.

ANALYSIS에서는 다음 사항을 확인하고 해결 방안과 검증 범위를 정한다.

1. 평소처럼 빌드하면 현재 커밋이 표시되고, broker와 패키지의 버전도 올바르게 유지된다.
2. 커밋 정보만 바뀌면 필요한 코드만 갱신되고, 아무 변경 없이 다시 빌드하면 불필요한 작업이 없다.
3. 로컬 Debug·OptDebug와 CI OptDebug의 실행별 통계를 확보하고, CUBRID 소스와 외부 라이브러리, 동일 커밋과 커밋 변경 조건을 나누어 실제 hit·miss와 소요 시간을 확인한다. 로컬 실측에서 확인한 원인이 OptDebug CI에도 작용하는지, 이를 개선하여 버전 정보 변경에 따른 hit율 0% 상황을 방지할 수 있는지 검증한다.
4. ccache 중첩 설정 등 관련 발견 사항이 측정과 개선 효과에 미치는 영향을 확인하고, 추가 조치의 범위와 담당을 정한다.

빌드·캐시 비용이 추가로 확인되어 재검토할 근거는 생겼으나, 긴급 장애로 판단한 것은 아니다. 실제 CI 영향과 다른 업무를 고려하여 수행 순서를 정할 것을 요청한다.
