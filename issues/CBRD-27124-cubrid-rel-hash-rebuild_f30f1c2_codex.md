# [BUILD] cubrid_rel 커밋 버전 갱신 누락과 버전 헤더 변경에 따른 광범위한 재빌드

## Issue Triage

**이슈 수행 목적**: 일반 CMake 빌드에서 현재 소스 커밋을 정확히 표시하고, 커밋 수·해시만 바뀔 때 버전 값을 사용하지 않는 오브젝트까지 재빌드하는 비용을 줄인다.

**이슈 수행 이유**: 기존 재현에서는 빈 커밋 후 빌드만 실행하면 `cubrid_rel`에 이전 해시가 남았고, CMake를 재구성하면 `version.h` 의존성이 엔진 전반으로 전파되었다. CBRD-25560의 후속 CI hit 40% 이상 보고와 관련하여 제공된 PR #8217 로그의 59.82%는 해당 빌드의 측정값이 아닌 공유 캐시 누적 통계임을 확인하였다. 버전 변경에 따른 실제 캐시 효과와 시간 비용은 실행별로 측정해야 한다.

**영향**: 개발자는 바이너리의 소스 커밋을 잘못 식별하거나 소스 변경이 없는 커밋 뒤에도 광범위한 빌드 작업을 기다릴 수 있다. 기존 Debug/Ninja 기록에서 `version.h`에 의존하는 오브젝트는 1,135개였다. 이 수는 실제 컴파일러 실행 횟수나 소요 시간을 뜻하지 않으며, 현재 CI의 커밋 변경별 hit와 시간 영향은 미확인이다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

CMake는 구성 단계에서 Git 커밋 수와 해시를 계산하여 `version.h`를 생성한다. 일반 브랜치의 `HEAD` 파일에는 커밋 ID 대신 `ref: refs/heads/<branch>`가 들어 있다. 현재 규칙은 일반 clone 또는 linked worktree의 이 `HEAD` 파일을 구성 입력으로 등록하므로, 해당 파일이 그대로인 채 branch ref만 이동하는 새 커밋을 놓칠 수 있다. 기존 재현에서는 빈 커밋 뒤 빌드가 `ninja: no work to do.`로 끝나고 `cubrid_rel`이 이전 해시를 출력하였다.

반대로 명시적인 재구성 등으로 새 커밋 값이 `version.h`에 반영되면 광범위한 재빌드가 발생한다. `config.h`가 `version.h`를 포함하고 엔진 전반이 `config.h`를 사용하기 때문이다. 버전 값을 직접 사용하는 파일이 아니어도 헤더 의존성 때문에 빌드 대상이 된다. 커밋 감지의 정확성과 버전 변경의 의존성 범위를 함께 개선해야 한다.

빌드 시스템이 오브젝트를 다시 만들도록 예약하는 것, ccache가 결과를 재사용하는 것, 실제 컴파일러가 컴파일하는 것은 구분해야 한다. ccache hit가 있더라도 넓은 헤더 의존성 자체가 사라지는 것은 아니다. 다만 hit가 많으면 실제 재컴파일과 시간 비용이 줄어들므로 의존 오브젝트 수만으로 성능 저하의 크기를 단정할 수 없다.

### 왜 문제인가

버전 표시가 뒤처지면 개발·검증 중인 바이너리가 어느 커밋에서 만들어졌는지 확인하기 어렵다. 출력된 버전을 기준으로 소스와 실행 결과를 대응시키는 작업도 부정확해질 수 있다. 실제 오배포나 장애 사례는 확인되지 않았다.

버전을 맞추려고 매번 재구성하면 갱신 누락은 우회할 수 있으나 넓은 의존성 때문에 재빌드가 발생한다. 캐시가 없는 환경에서는 재컴파일 비용을 부담하고, 캐시가 있는 환경에서도 조회·전처리·miss 비용이 남을 수 있다. 발생 빈도와 현재 CI에서의 순수 시간 손실은 추가 측정이 필요하다.

### 왜 해결해야 하는가

정확한 커밋 표시를 얻기 위해 광범위한 재빌드를 감수하거나, 이를 피하려고 오래된 버전 정보를 사용하는 상태는 개발 흐름의 정상 동작으로 삼기 어렵다. 두 문제를 함께 개선하면 개발자가 별도의 재구성 절차를 기억하지 않아도 바이너리를 식별하고 작은 변경의 검증을 이어갈 수 있다.

CBRD-25560의 ccache 사용 개선만으로 Git 커밋 감지 누락이나 헤더 의존성 전파가 해결되지는 않는다. 제공된 CI 통계는 이번 확인에서 빌드별 hit율의 근거로 사용할 수 없는 것으로 드러났다. 그렇다고 현재 CI의 CUBRID 소스가 모두 miss라고 확정된 것도 아니다. 측정 범위를 맞춘 뒤 비용을 평가해야 한다. 긴급성은 입증되지 않았으며 기존 이슈의 낮은 중요도 의견을 뒤집을 근거도 아직 없다.

## Test Build

| 근거 | 환경과 확인 범위 |
|---|---|
| 기존 CBRD-27124 재현 기록 | CUBRID `f30f1c26003e5aa8e93182648e06cad76fc77064`, `11.5.0.2374-f30f1c2`, Rocky Linux 9.6 x86_64, Debug, CMake 3.26.5, Ninja 1.10.2. 이번 개정에서 전체 빌드를 다시 실행하지 않았다. |
| 2026-10-21 소스 대조 | 로컬 develop `f6cac312310f39f46711693da157a08f0e725693`에도 `HEAD_FILE` 감시, 구성 단계 버전 계산, `config.h`의 `version.h` 포함 구조가 남아 있음을 확인하였다. 해당 커밋에서 동일 증상과 오브젝트 수를 실측한 것은 아니다. |
| 이번 개정의 최소 캐시 실험 | Rocky Linux 9.6 x86_64, GCC 11.5.0, ccache 4.5.1. 버전 매크로를 포함하되 사용하지 않는 단일 C 파일로 원인 설명만 확인하였다. 전체 CUBRID 빌드나 CI 성능 검증이 아니다. |
| CBRD-25560 댓글 실험 | GCC 8.5.0, ccache 3.7.7, Ninja 1.8.2, 80 논리 CPU, 기본 `-j82`. CUBRID compile+link 구간이며 third-party·JDBC를 제외한다. 원시 로그와 소스 SHA는 제공되지 않아 댓글의 측정 보고로 인용한다. |
| PR #8217 CI 로그 확인 | 2026-10-20의 OptDebug 작업 2개. 실제 소스 SHA는 각각 `be5e8fc50a745215ec65a80e2ce6e57bf1972c9f`, `5c2586fef889f2ab504a1fe82eb073f10ee7f7a1`이다. 실행 화면의 `c966fab`는 workflow 기준 커밋이며 실제 빌드 소스 SHA와 구분한다. 작업 URL과 통계 해석은 아래에 기록한다. |

유지보수 릴리스별 영향은 TBD이다. 기준 소스가 11.5 개발 버전이라는 사실만으로 모든 11.5 배포 버전이 영향받는다고 판단하지 않는다.

## Repro

### 커밋 감지와 재빌드 범위 확인

다음은 기존 재현을 표준 CMake 명령으로 정리한 재검증 절차이다. 이번 개정에서 실행한 절차는 아니다. 별도의 폐기 가능한 clone에서 실행하며, [기준 커밋의 빌드 요구사항](https://github.com/CUBRID/cubrid/blob/f30f1c26003e5aa8e93182648e06cad76fc77064/README.md#build-requirements)과 Ninja를 준비한다. 구성·빌드 중 외부 의존성 다운로드에 필요한 네트워크 접근도 필요하다.

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

다음은 이번 최소 실험을 재현하는 명령이다. 각 조건에 새 전용 캐시를 사용하므로 기존 개발 캐시를 비우지 않는다. `env -i`로 다른 ccache 환경변수의 개입을 배제한다. A와 B는 실제 커밋 대신 버전 매크로 값만 바꾸는 모의 조건이다.

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

## Expected Result

- 빈 커밋 뒤 별도의 구성 명령 없이 일반 빌드만 실행해도 `cubrid_rel`이 현재 소스 커밋을 표시한다.
- 커밋 수·해시만 바뀔 때 변동 버전 값을 직접 사용하지 않는 오브젝트의 불필요한 재빌드를 피한다. 필요한 relink와 패키지 메타데이터 갱신 범위는 ANALYSIS에서 정한다.
- 버전 정합성을 유지하며, 캐시 유무에 따른 효과를 실제 작업 수와 시간으로 검증한다. CI hit 비율의 목표값은 현재 합의된 요구사항이 아니다.

## Actual Result

기존 이슈 기록에서는 빈 커밋 뒤 첫 빌드가 `ninja: no work to do.`로 끝나고 `cubrid_rel`은 이전 해시를 유지하였다. 재구성 후 `version.h`와 `config.h`의 의존성 조회 결과는 각각 1,135개였다. 이 수를 현재 구성의 보편적인 재컴파일 수로 사용하지 않는다.

이번 최소 실험에서는 첫 컴파일로 A를 캐시에 저장한 뒤 매크로만 B로 변경한 두 번째 컴파일에서 다음 결과를 확인하였다.

| 옵션 | 전처리 결과의 `VERSION_STRING` 정의 | A → B 전처리 결과 | 두 번째 컴파일의 ccache 결과 |
|---|---|---|---|
| `-ggdb3` | 남는다 | 달라진다 | hit 0, miss 1 |
| `-ggdb3 -ggdb` | 남는다 | 달라진다 | hit 0, miss 1 |
| `-ggdb` | 남지 않는다 | 같다 | preprocessed hit 1, miss 0 |

따라서 버전 매크로 변경이 `-ggdb3`의 캐시 재사용을 방해할 수 있다는 설명은 이번 최소 실험에서도 성립한다. GCC 8.5.0·ccache 3.7.7의 전체 CUBRID 결과, OptDebug의 전체 빌드 결과, 현재 CI 전체 hit가 0이라는 주장을 검증한 것은 아니다.

## Additional Information

### CBRD-25560의 상충해 보이는 보고

[CBRD-25560](http://jira.cubrid.org/browse/CBRD-25560)과 본 이슈는 `relates to` 관계이다. 관련 댓글은 서로 다른 측정 범위일 수 있으므로 다음과 같이 구분한다.

| 근거 | 보고 내용 | 해석의 한계 |
|---|---|---|
| [실험 댓글 4777097](http://jira.cubrid.org/browse/CBRD-25560?focusedCommentId=4777097&page=com.atlassian.jira.plugin.system.issuetabpanels%3Acomment-tabpanel#comment-4777097), 2026-10-20 | 생성된 `version.h`의 커밋 수·해시만 바꾼 Debug에서 hit `0/1170`, 캐시 없음 52.3초 / ccache 58.8초. RelWithDebInfo는 preprocessed hit `1154/1170`, 66.0초 / 17.4초라고 보고하였다. | CUBRID 소스 구간의 특정 조건 실험이다. OptDebug 전체 빌드는 같은 조건으로 검증하지 않았다고 명시한다. |
| 같은 댓글의 전체 빌드 설명 | third-party를 포함한 `build.sh -m debug`에서는 third-party hit가 miss 비용을 상쇄하여 캐시 유무의 전체 시간이 비슷했다고 보고하였다. | 해당 댓글 자체도 모든 컴파일 호출의 hit가 0이라고 주장한 것은 아니다. |
| [후속 댓글 4777107](http://jira.cubrid.org/browse/CBRD-25560?focusedCommentId=4777107&page=com.atlassian.jira.plugin.system.issuetabpanels%3Acomment-tabpanel#comment-4777107), 2026-10-20 및 이번 요청 | 담당자 문의 결과 실제 CI에서 ccache hit ratio가 40% 이상이라는 보고가 있다. 이번 요청에서 PR #8217의 59.82% 출력이 추가로 제공되었다. | 해당 출력과 일치하는 실제 작업 로그를 확인한 결과, PR 빌드 중 통계를 갱신하지 않은 공유 캐시 누적 통계였다. 댓글이 근거로 삼은 다른 실행이 있는지는 미확인이다. |

### PR #8217의 59.82%는 빌드별 hit율이 아니다

다음 두 `build (debug)` 작업의 로그에서 실제 소스 SHA가 다르지만 같은 통계가 출력됨을 확인하였다. 두 작업 모두 OptDebug 빌드를 수행하였다.

| 작업 | 실제 소스 SHA | direct hit / preprocessed hit / miss | hit율과 통계 갱신 시각 |
|---|---|---|---|
| [run 39377825558, job 118479884072](https://github.com/CUBRID/cubrid/actions/runs/39377825558/job/118479884072) | `be5e8fc50a745215ec65a80e2ce6e57bf1972c9f` | `100948 / 1296 / 68689` | `59.82%`, `Tue Oct 20 12:58:24 2026` |
| [run 39383918389, job 118499169707](https://github.com/CUBRID/cubrid/actions/runs/39383918389/job/118499169707) | `5c2586fef889f2ab504a1fe82eb073f10ee7f7a1` | `100948 / 1296 / 68689` | `59.82%`, `Tue Oct 20 12:58:24 2026` |

[해당 workflow 커밋의 설정](https://github.com/CUBRID/cubrid/blob/c966fabc6b4c8ac86aa4b5abb0a4cbefae01bf5b/.github/workflows/gha-ci.yml#L481-L562)은 `/home/ci/cache/ccache/develop-debug`를 공유하고 debug 작업에 `-m optdebug`를 전달한다. 빌드 뒤 `ccache -s`를 실행하며, `CACHE_WRITE`가 true가 아니면 `CCACHE_READONLY=1 CCACHE_NOSTATS=1`을 설정한다. 두 작업 로그에서 `CACHE_WRITE: false`와 이 조건문 실행을 확인하였다. 따라서 캐시 조회는 가능하지만 해당 PR 빌드의 hit·miss는 이 통계에 기록되지 않는다.

표시된 59.82%는 `(100948 + 1296) / (100948 + 1296 + 68689)`로 계산되는 기존 카운터의 비율이다. 이 값으로 두 PR 빌드 중 실제 hit가 몇 건이었는지 알 수 없다. 제공된 출력이 기존 조건부 실험을 반증한다는 해석은 성립하지 않는다. 다만 기존 댓글의 전체 CUBRID 측정과 OptDebug 추정까지 이번 확인으로 입증된 것은 아니다.

현재 CI의 실제 결과는 별도 측정이 필요하다. CUBRID 소스와 third-party, 같은 커밋 재실행과 커밋 변경, 빌드 모드를 구분해야 한다. 공유 통계가 비활성화되었거나 다른 작업도 갱신하는 상태에서 빌드 전후 카운터만 빼는 방법으로는 실행별 hit를 얻을 수 없다.

### 소스와 도구 근거

- [버전 계산과 HEAD 감시](https://github.com/CUBRID/cubrid/blob/f30f1c26003e5aa8e93182648e06cad76fc77064/CMakeLists.txt#L102-L183): configure 시점의 Git 조회와 `HEAD_FILE` 등록이다.
- [version.h 포함](https://github.com/CUBRID/cubrid/blob/f30f1c26003e5aa8e93182648e06cad76fc77064/cmake/config.h.cmake#L95)과 [버전 매크로](https://github.com/CUBRID/cubrid/blob/f30f1c26003e5aa8e93182648e06cad76fc77064/cmake/version.h.cmake#L25-L35): 변동 버전 값이 넓은 범위로 전파되는 경로이다.
- [GNU 빌드 옵션](https://github.com/CUBRID/cubrid/blob/f30f1c26003e5aa8e93182648e06cad76fc77064/CMakeLists.txt#L219-L246): Debug와 OptDebug의 `-ggdb3` 및 공통 `-ggdb` 설정이다. 실제 CI의 최종 컴파일 명령도 별도로 확인해야 한다.
- `cubrid_rel`은 `cubridsa`의 `release_string.c`가 제공하는 버전을 출력한다. 기존 분석에서 `VERSION_STRING`의 직접 소비 위치는 `release_string.c`·`release_string.h`, `BUILD_NUMBER`는 `release_string.c`와 broker 소스 7개였다. 최종 소비 범위는 ANALYSIS에서 재확인한다.
- [GCC 디버그 정보 문서](https://gcc.gnu.org/onlinedocs/gcc/Debugging-Options.html)는 디버그 레벨 3이 매크로 정의를 포함함을 설명한다. 이번 실험은 `-ggdb3 -ggdb` 조합도 직접 확인하였다.
- [ccache 3.7.7 문서](https://ccache.dev/manual/3.7.7.html#_troubleshooting)는 빌드 전후 통계 카운터를 비교하는 방법을 안내한다. `--zero-stats`는 통계 초기화이며 캐시 내용 삭제와 다르다.

### 기존 계획과 분석 경계

[기존 계획 map](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27124/wayfinder/map.md)은 버전 갱신, 의존성 경계, 런타임·패키지 버전 정합성, 검증 범위를 정리한 미완료 계획이다. 이 문서를 구현 방식의 확정 근거로 삼지 않는다.

본 이슈는 버전 정보의 정확성과 불필요한 재빌드 범위를 다룬다. ccache 자동 도입 여부, 중첩 wrapper, 도구 선택과 사용 문서화는 CBRD-25560에서 다루되, 실제 캐시 동작과 측정 근거는 함께 확인한다.

## Triage Request

커밋 버전 갱신 누락과 변동 버전 헤더의 넓은 의존성 문제를 확인하고, 작성자 측에 ANALYSIS를 배정할 것을 요청한다. 우선순위와 담당자 확정은 triage에서 결정한다. 분석에서는 다음을 확인한다.

1. 일반 clone과 linked worktree에서 커밋 후 빌드만으로 버전이 갱신되는 계약과, 관련 런타임·패키지 버전의 정합성 범위를 정한다.
2. 버전 값의 직접 소비자와 필요한 재빌드 대상을 식별하고, 버전만 바뀐 경우의 작업량을 캐시 유무와 별개로 검증한다.
3. PR #8217의 누적 통계와 실제 실행별 통계를 구분한 상태에서, 최종 컴파일 명령과 ccache 버전·설정을 확보한다. CUBRID 소스와 third-party, 동일 커밋 재실행과 커밋 변경, direct/preprocessed hit·miss를 나누어 기존 실험과 비교한다. 후속 댓글에 다른 실행별 근거가 있는지도 확인한다.
4. 캐시 없는 빌드와 동일 조건의 warm-cache 빌드를 비교하여 실제 시간 비용을 평가한다. 통계가 활성화된 격리 검증 캐시나 해당 도구 버전이 지원하는 실행별 로그를 사용한다. 공유 CI 통계는 초기화하지 않으며, Debug·OptDebug 전체 결과를 최소 예제의 결과와 구분한다.
5. 확인된 차이와 결론을 CBRD-25560에도 연결하여 캐시 도입 효과와 본 이슈의 개선 효과를 각각 판단할 수 있게 한다. 구현 방식과 최종 검증 행렬은 ANALYSIS에서 결정한다.
