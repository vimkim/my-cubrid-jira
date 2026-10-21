# [CBRD-27712] Linux 서드파티 의존성 prefix 재사용

## Issue Triage

**이슈 수행 목적**: 같은 Linux 머신과 C/C++ 컴파일러 환경에서 완성된 서드파티 의존성을 여러 CUBRID worktree와 clean 재빌드에 재사용한다.

**이슈 수행 이유**: 기존 빌드는 의존성 준비 상태를 CUBRID build 디렉터리에 보관한다. 해당 디렉터리를 clean하거나 새 worktree를 만들면 같은 의존성을 다시 준비해야 한다.

**영향**: CUBRID 코드만 다시 빌드하려는 개발자도 서드파티 다운로드·configure·빌드를 반복하게 된다. 이 준비 단계를 분리하면 완성된 의존성을 유지하면서 CUBRID 빌드와 설치를 다시 수행할 수 있다.

**이슈 수행 방안**: 사용자가 공개 producer 스크립트로 별도 prefix를 먼저 준비하고, CUBRID configure에 `CUBRID_3RDPARTY_ROOT`로 지정하는 2단계 방식을 적용한다. consumer는 필수 파일과 레시피·컴파일러·플랫폼 fingerprint를 확인하고 준비된 파일만 읽는다. prefix 경로의 Gateway 설치물에는 unixODBC 공유 라이브러리와 대응 소스·고지를 동봉한다. prefix를 지정하지 않은 기존 경로를 유지하며, 공유 CI 캐시 배포와 일반 Linux unixODBC 정책 변경은 범위에 포함하지 않는다.

---

## AI-Generated Context

> 아래는 AI가 코드와 맥락을 분석해 작성한 상세 자료다.

## Description

### 배경과 변경 목적

CUBRID는 빌드 과정에서 Expat, libedit, LZ4, OpenSSL, unixODBC, RapidJSON, RE2, oneTBB를 준비한다. 기존 방식에서는 의존성의 빌드 산출물과 완료 기록이 CUBRID build 디렉터리에 속한다. 따라서 CUBRID 코드를 다시 빌드하려고 그 디렉터리를 지우면 이미 완성한 의존성도 다시 준비하게 된다. 별도 worktree에서도 준비 상태를 그대로 사용할 수 없다.

이 작업은 의존성을 준비하는 producer와 완성된 의존성을 사용하는 CUBRID consumer를 분리한다. prefix는 consumer에 제공할 헤더·라이브러리·라이선스 등을 모아 둔 디렉터리다. producer의 build·ccache·prefix를 CUBRID build·install과 분리해 두면, CUBRID만 clean한 뒤 같은 prefix로 다시 빌드할 수 있다. 여러 worktree도 같은 지원 조건 안에서 완성된 prefix를 함께 읽을 수 있다.

| 항목 | 변경 전 | 변경 후 |
| --- | --- | --- |
| 의존성 준비 | CUBRID 빌드에 포함된다. | 사용자가 별도 명령으로 먼저 수행한다. |
| clean 후 재빌드 | build 디렉터리와 함께 사라진 의존성을 다시 준비한다. | CUBRID build·install과 분리된 prefix를 재사용한다. |
| prefix 입력 오류 | 해당 입력 경로가 없다. | 필수 파일 누락이나 fingerprint 불일치 시 configure에서 실패한다. |
| 기존 빌드 선택 | 기존 방식으로 빌드한다. | prefix를 지정하지 않으면 기존 방식을 사용한다. |

### 합의한 지원 범위

첫 지원 범위는 같은 머신과 같은 C/C++ 컴파일러 환경의 네이티브 Linux 빌드다. fingerprint는 수동 레시피 revision, C/C++ 컴파일러 종류·버전, OS 이름·CPU·포인터 크기를 비교한다. 전체 ABI 호환성을 증명하지 않으며 libc, sysroot, 임의의 컴파일러 옵션은 검사하지 않는다. 다른 머신·배포판으로의 이동, 크로스 컴파일, sanitizer·LTO 조합은 지원 범위 밖이다.

완성된 prefix는 consumer가 읽기만 한다. 의존성 버전·빌드 옵션·패치·package 구성이 바뀌면 레시피 revision을 올리고 새 상태 경로에 준비한다. 사용 중인 prefix 덮어쓰기와 같은 상태 경로에 대한 producer 동시 실행은 지원하지 않는다. CUBRID configure는 producer를 자동 실행하지 않으며, 잘못된 prefix를 받았을 때 기존 빌드로 자동 전환하지 않는다.

기존 8개 의존성의 버전·해시·최적화·정적/동적 링크 방식을 유지하고 Catch2 헤더도 prefix에 준비한다. Manager와 CCI는 기존 통합 구조를 사용한다. 공유 CI 이미지·원격 binary cache 배포와 전체 의존성 관리 체계 도입은 이 작업에 포함하지 않는다.

### 구현과 사용 흐름

`3rdparty/build.sh`는 독립 CMake producer를 실행한다. 기본 상태 경로는 저장소 루트의 `.thirdparty/`이며, 그 아래에 `build/`, `ccache/`, `prefix/`를 둔다. producer는 한 번에 의존성 하나를 빌드하고 내부 작업 수를 제한한다. `CUBRID_3RDPARTY_STATE`, `CUBRID_3RDPARTY_CC`, `CUBRID_3RDPARTY_CXX`, `CUBRID_3RDPARTY_JOBS`로 상태 경로·컴파일러·작업 수를 지정할 수 있다.

consumer의 `3rdparty/CMakeLists.txt`는 prefix가 지정되면 package와 fingerprint를 확인하고 imported target 및 기존 CMake 변수를 사용한다. 이 경로는 의존성 다운로드·configure·build target을 만들지 않는다. `unit_tests/CMakeLists.txt`도 prefix에 준비된 Catch2를 사용한다.

아래는 저장소 루트에서 producer를 실행하고 같은 컴파일러로 Release 빌드·설치를 수행하는 공개 사용 예다. producer에는 CMake 3.21 이상, Ninja, make, ccache와 의존성 빌드 도구가 필요하다. CUBRID에는 JDK, Flex, Bison 등 기존 빌드 환경과 선택한 submodule이 필요하다. `CUBRID_3RDPARTY_ROOT`에는 절대 경로를 지정한다. 별도 상태 경로를 사용했다면 그 아래의 `prefix`를 지정한다.

```bash
bash 3rdparty/build.sh
cmake --preset release \
  -DCMAKE_C_COMPILER=/usr/bin/gcc \
  -DCMAKE_CXX_COMPILER=/usr/bin/g++ \
  -DCMAKE_INSTALL_PREFIX="$PWD/build/reuse-install" \
  -DCUBRID_3RDPARTY_ROOT="$PWD/.thirdparty/prefix" \
  -DUNIT_TEST_JSON_BUILDER=ON
cmake --build --preset release --parallel 8
cmake --install build_preset_release
./build_preset_release/bin/test_json_builder
```

### Gateway 설치와 운영 조건

prefix 경로에서는 `broker/CMakeLists.txt`가 unixODBC 공유 라이브러리 실물과 `libodbc.so.2` SONAME 링크를 설치한다. 설치된 Gateway의 RUNPATH는 `$ORIGIN/../lib`이며, 원본 prefix나 producer build 없이 설치물 내부의 드라이버 관리자를 사용한다.

DB별 ODBC 드라이버와 `odbcinst.ini`는 운영자가 제공한다. `CGW_LINK_ODBC_DRIVER_NAME`에는 등록된 드라이버 이름을 지정하고, Gateway 시작 전에 `ODBCSYSINI`로 등록 파일이 있는 디렉터리를 지정한다. 예를 들어 `ODBCSYSINI=/etc`는 `/etc/odbcinst.ini`를 선택한다. 이 작업은 전체 ODBC 도구나 DB별 드라이버·시스템 의존성을 동봉하지 않는다.

설치물에는 `3rdparty/libodbc_license.txt`, `3rdparty/unixODBC/unixODBC-2.3.14.tar.gz`, 재빌드·공유 라이브러리 교체 안내인 `README.txt`를 포함한다. 설치된 라이선스와 upstream `COPYING`의 일치, 소스 압축파일의 기존 SHA-256 일치, 압축파일 내 고지·configure·libltdl 소스 포함을 확인했다. 이는 실제 설치 내용의 확인이며 모든 배포 채널의 법률 검토 완료를 뜻하지 않는다.

일반 Linux 경로의 unixODBC 빌드·설치 정책은 변경하지 않는다. 해당 정책 문제는 별도 이슈인 [CBRD-27711](https://jira.cubrid.org/browse/CBRD-27711)에서 다룬다.

### 로컬 검증 결과와 조건

구현 기준은 `15609d2a779e3082aafe5af576487ebbdc8d70f6`이다. 로컬 검증은 Rocky Linux 9.6, GCC/G++ 11.5.0, CMake 3.26.5, Ninja에서 CCI와 Manager를 초기화한 상태로 수행했다. 프로젝트의 Release preset은 `RelWithDebInfo`, OptDebug는 `OptDebug`에 해당한다.

| 검사 | 관찰한 결과 |
| --- | --- |
| 일반·prefix 각각 Release·OptDebug | 네 조합의 빌드·설치와 JSON builder 실행에 성공했다. 각 JSON 실행은 21개 사례, 13,191개 assertion을 통과했다. |
| 의존성 API probe | 8개 의존성을 실제로 compile·link·run하는 CTest 1/1을 통과했다. |
| prefix package 검사 | 정상 경로, 없는 경로, `OFF`라는 명시적 경로, 라이브러리·헤더·SONAME 링크·라이선스·소스 누락, fingerprint 불일치를 포함한 10/10을 통과했다. |
| clean 재사용 | CUBRID build·install을 비운 뒤 producer 재실행 없이 configure·build·install·JSON 실행에 성공했다. |
| 의존성 불변성 | prefix 411개 파일과 producer stamp 151개 파일의 SHA-256·mtime·symlink 대상이 같았고 producer 전용 ccache 통계도 변하지 않았다. consumer 빌드 그래프·로그에 의존성 준비 작업이 없었다. |
| 설치물 독립 실행 | 원본 prefix·producer·CUBRID build를 가린 namespace에서 Gateway가 등록된 MariaDB 드라이버로 쿼리 결과 `42`를 반환했다. `LD_LIBRARY_PATH`를 제거한 loader 검사와 process map에서도 설치물의 unixODBC 사용을 확인했다. |

Release의 초기 검증 이후 필수 ODBC 헤더 검사 보완을 커밋했다. 최종 revision에서는 prefix Release clean 재빌드와 설치물 실행을 다시 확인했다. 위 표는 모든 조합을 최종 revision에서 다시 실행했다는 뜻은 아니다.

이 호스트에서는 기존 engine 경고가 오류로 처리되는 문제와 Manager의 prebuilt libevent가 참조하는 `sysctl` 링크 문제가 있었다. 로컬 검증에서 `stringop-truncation`, `maybe-uninitialized`, `format-overflow`, `format-truncation` 진단을 경고로 낮췄고, 검증 전용 객체로 `sysctl` 호출을 glibc의 `__sysctl@GLIBC_2.2.5` 호환 심벌에 전달했다. 보정은 네 로컬 검증 설정에 적용했으며 제품 PR에는 포함하지 않았다. 따라서 로컬 빌드 성공은 이 보정 조건에서의 결과다.

의존성 소스 압축파일은 이미 확보한 해시 검증 파일로 준비했다. 이 결과로 cold build 시간, 다운로드 속도, CI 병목 개선율을 주장하지 않는다. 이전 PoC의 측정값도 이번 구현의 검증으로 사용하지 않았다.

집중 검사는 producer 준비 후 다음 공개 명령으로 수행할 수 있다. 실제 CUBRID 빌드·설치 검증에는 호스트별 기존 문제가 별도로 영향을 줄 수 있다.

```bash
python3 3rdparty/tests/check-package.py .thirdparty/prefix
cmake -S 3rdparty/tests/probe -B .thirdparty/probe -G Ninja \
  -DCubridThirdParty_DIR="$PWD/.thirdparty/prefix/lib/cmake/CubridThirdParty"
cmake --build .thirdparty/probe --parallel 2
ctest --test-dir .thirdparty/probe --output-on-failure
```

### PR과 CI 확인 상태

2026-10-21 조회 시 [PR #8227](https://github.com/CUBRID/cubrid/pull/8227)은 open draft다. base는 `develop`, head는 `vimkim/cubrid:CBRD-27712-thirdparty-reuse`이며 위 구현 기준과 일치한다. [기존 CI 실행](https://github.com/CUBRID/cubrid/actions/runs/39541991227)은 한 번만 요청했다. source commit에 연결된 두 build context는 통과했고 `test_shell`, `test_sql`, `test_medium`은 아직 대기 또는 실행 중이다. 전체 회귀 결과는 미확정이다.

별도 자동 [license 검사](https://github.com/CUBRID/cubrid/actions/runs/39541817707/job/119031051143)는 실패했다. 로그에 `3rdparty/build.sh: FAIL`, `3rdparty/tests/probe/main.cpp: FAIL`이 있다. 이 검사는 위에서 확인한 unixODBC 동봉 파일·소스의 라이선스 검증과 구분한다. 후속 source 수정·push·CI 재실행은 하지 않았다.

TC 저장소 변경은 필요하지 않다. [공개 TC PR #3826](https://github.com/CUBRID/cubrid-testcases/pull/3826)과 [비공개 TC PR #4514](https://github.com/CUBRID/cubrid-testcases-private-ex/pull/4514)는 open draft이며 사람이 확인하여 닫아야 한다. 조회한 `Check TC PRs` required check는 통과했다. 두 TC PR이 열려 있다는 후속 처리 상태와 gate 검사 결과를 구분한다.

### 상세 근거

- [설계·구현·로컬 검증 상세](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-27712/CBRD-27712-thirdparty-prefix_15609d2_codex.md): 합의한 계약, 파일별 책임, 검증 조건과 설치물 확인을 기록한다. 문서 작성 당시의 PR·CI 예정 문구보다 위에서 조회한 현재 게시 상태를 우선한다.
- [구현 revision의 공개 사용법](https://github.com/CUBRID/cubrid/blob/15609d2a779e3082aafe5af576487ebbdc8d70f6/3rdparty/README.md): 사용 명령, 지원 범위, 운영 조건과 집중 검사 진입점을 설명한다.
- [구현 commit](https://github.com/CUBRID/cubrid/commit/15609d2a779e3082aafe5af576487ebbdc8d70f6): ODBC 필수 헤더 누락을 configure에서 거부하도록 보완한 최종 revision이다.
