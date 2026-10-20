# [CBRD-27711] 빌드한 unixODBC가 설치된 Gateway에서 사용되지 않음

## Issue Triage

**이슈 수행 목적**: Gateway를 빌드할 때 준비한 unixODBC와 설치 후 사용하는 unixODBC의 선택이 달라지는 문제를 해결한다.

**이슈 수행 이유**: 일반 Linux 빌드는 unixODBC 2.3.14를 다운로드·컴파일하여 Gateway에 연결하지만, 확인한 CMake 설치와 CPack TGZ에는 `libodbc.so*`가 포함되지 않는다. 그 결과 확인한 설치 환경에서는 직접 빌드한 2.3.14 대신 시스템 unixODBC 2.3.9가 선택된다.

**영향**: 빌드에서 선택한 버전만으로 설치된 Gateway가 사용할 버전을 보장할 수 없으며, 실행용 의존성 공급이 설치 환경에 의존한다. Gateway/DBLINK를 실행하지 않는 엔진 빌드도 현재 공통 의존성 그래프 때문에 unixODBC를 준비한다. 반복 준비 비용이 CI 병목이라는 요청자의 보고가 있으나, CI 단독 소요 시간과 실제 절감량은 아직 검증하지 않았다.

**이슈 수행 방안**: 버그 수정의 범위는 빌드 입력과 설치 후 런타임 의존성의 공급·버전 선택을 일관되게 관리하는 것이다. 가능한 경우 unixODBC 자동 준비를 메인 엔진 빌드에서 제거·분리하는 방안을 우선 검토한다. Gateway에 필요한 헤더·링크 입력·실행 라이브러리의 별도 공급 또는 동봉 방식, 선택 기능과 지원 버전은 TBD - ANALYSIS 단계에서 결정한다. 동봉 여부만으로 빌드 비용 문제가 해결되었다고 판단하지 않는다.

---

## AI-Generated Context

> 아래는 AI가 코드와 맥락을 분석해 작성한 상세 자료다.

## Description

unixODBC는 Gateway가 외부 DB의 ODBC 드라이버를 사용하도록 중개하는 라이브러리이다. unixODBC 자체와 각 외부 DB용 ODBC 드라이버는 구분해야 한다. Gateway 소스에는 `SQLAllocHandle`, `SQLDriverConnectW` 등 실제 ODBC API 호출이 있으며, 생성된 실행 파일도 `libodbc.so.2`를 필요로 한다.

관측한 문제는 unixODBC 전체가 미사용이라는 것이 아니다. 일반 Linux 빌드에서 직접 준비하고 링크한 unixODBC가 최종 설치에 포함되지 않아, 설치된 Gateway가 다른 공급원의 라이브러리를 선택한다는 점이다. 기준 소스를 새로 빌드한 결과 build-tree의 Gateway는 빌드한 2.3.14를 선택했고, 같은 빌드의 설치 Gateway는 시스템 2.3.9를 선택했다. ELF의 라이브러리 검색 경로가 설치 단계에서 달라지는 것과 최종 설치에 해당 DSO가 없는 것이 이 결과를 설명한다.

현재 `ExternalProject`는 unixODBC를 빌드하고 `<BUILD>/3rdparty`에 설치한다. 이 작업 prefix에는 헤더·공유 라이브러리와 도구들이 생기지만, 이 단계는 CUBRID의 최종 설치가 아니다. CUBRID 설치는 Gateway와 unixODBC 라이선스 파일을 포함하고 `libodbc.so*`는 복사하지 않는다. 따라서 직접 빌드한 파일을 링크했다는 사실만으로 그 파일이 설치 후에도 사용된다고 보장할 수 없다.

이 차이를 버그 현상으로 추적하되, 해결 방법을 미리 동봉으로 한정하지 않는다. 시스템 라이브러리를 사용하기로 한다면 지원 버전과 설치 요구사항을 명확히 하고 불필요한 자동 준비를 제거·분리하는 방향을 검토할 수 있다. 선택한 라이브러리를 동봉하기로 한다면 실제 로드 경로와 업데이트·라이선스 책임까지 검증해야 한다. 빌드 준비를 외부로 분리하면서 최종 설치에는 동봉하는 조합도 가능하므로, 준비 위치와 런타임 공급 방식은 별도로 결정한다.

## Test Build

- 독립 검증 기준 소스: `cc947788d3b7dc402f46192d0f3299ddcc8563ba`, CUBRID `11.5.0.2704-cc94778`.
- 새 실험 구성: Linux x86_64 Debug, GCC 11.5.0, CMake 3.26.5, Ninja 1.10.2, Rocky Linux 9.6, kernel `5.14.0-570.30.1.el9_6.x86_64`.
- unixODBC: 기본 `WITH_LIBUNIXODBC=EXTERNAL`, 원본 2.3.14. 소스 archive SHA256: `4e2814de3e01fc30b0b9f75e83bb5aba91ab0384ee951286504bb70205524771`.
- CCI: `79d0888c26a2543d31f53eb7b6c9738db110fff4`, `WITH_CCI=true`. JDBC·Manager 하위 저장소는 새 실험에서 초기화하지 않았다.
- 새 실험은 O0·디버그 정보·프레임 포인터·C++17과 ccache를 사용했고 OOS·spage·page buffer 단위 테스트 빌드 옵션을 켰다. unixODBC의 기본 준비·링크·설치 규칙은 수정하지 않았다.
- 시스템 라이브러리: RPM `unixODBC-2.3.9-4.el9.x86_64`, 실제 파일 `/usr/lib64/libodbc.so.2.0.0`.
- 기존 설치본도 별도로 재검사했다: `11.5.0.2683-4adcd40`, Linux 64bit debug. 네 관련 소스 파일은 `4adcd409072b189f5d965bde5750c53176d90de0`와 새 기준 커밋에서 내용이 동일했다. 기존 바이너리 전체의 빌드 출처를 현재 checkout으로 간주하지 않는다.
- 기존 PoC 기준은 `ad2182f08d2cb5e1c7b56f1b6b47cef704171aa9`이며, PoC prefix 로드 결과와 일반 빌드의 시스템 로드 결과를 구분했다.
- 검증일: 2026-10-21. 새 전체 빌드·설치·TGZ 생성과 로더 검사를 수행했으며 외부 DB 연결·조회 시험은 수행하지 않았다.

## Repro

### 확인 조건

CUBRID Linux 빌드 요구사항과 시스템 unixODBC 런타임이 준비된 개발 VM을 사용한다. 아래 명령은 기존 설치나 작업 디렉터리를 지우지 않고 별도 worktree와 설치 위치를 사용한다. 디렉터리 이름이 이미 사용 중이면 다른 새 이름을 선택한다. `ccache` 등 개인 빌드 도구는 재현의 필수 조건이 아니다.

### 일반 빌드와 설치의 비교

```bash
# CUBRID Git 저장소에서 수행한다.
git worktree add --detach ../cbrd-27711-repro \
  cc947788d3b7dc402f46192d0f3299ddcc8563ba
cd ../cbrd-27711-repro
git submodule update --init --recursive

odbc_check_build="$PWD/build-unixodbc-check"
odbc_check_install="$PWD/install-unixodbc-check"
odbc_check_packages="$PWD/packages-unixodbc-check"
cmake -S . -B "$odbc_check_build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_INSTALL_PREFIX="$odbc_check_install"
cmake --build "$odbc_check_build" --parallel 8
cmake --install "$odbc_check_build"

find "$odbc_check_build/3rdparty/lib" -maxdepth 1 -name 'libodbc.so*' -ls
grep -E 'cub_cas_cgw|libodbc' "$odbc_check_build/install_manifest.txt"
find "$odbc_check_install" -name 'libodbc.so*' -ls
readelf -d "$odbc_check_build/bin/cub_cas_cgw" | grep -E 'NEEDED|RPATH|RUNPATH'
readelf -d "$odbc_check_install/bin/cub_cas_cgw" | grep -E 'NEEDED|RPATH|RUNPATH'
env -u LD_LIBRARY_PATH -u LD_PRELOAD \
  ldd -r "$odbc_check_build/bin/cub_cas_cgw" | grep 'libodbc.so.2 =>'
env -u LD_LIBRARY_PATH -u LD_PRELOAD \
  ldd -r "$odbc_check_install/bin/cub_cas_cgw" | grep 'libodbc.so.2 =>'
rpm -qf /lib64/libodbc.so.2

cpack --config "$odbc_check_build/CPackConfig.cmake" \
  -G TGZ -B "$odbc_check_packages"
for odbc_check_package in "$odbc_check_packages"/*.tar.gz; do
  tar -tzf "$odbc_check_package" | grep -E 'cub_cas_cgw|libodbc'
done
```

위 명령의 병렬 수 8은 재현 예시이다. 아래 로컬 시간 관측은 병렬 수와 캐시를 통제한 이 명령의 벤치마크 결과가 아니다. CPack도 설치 manifest를 갱신하므로 일반 설치 manifest는 CPack 실행 전에 확인한다.

### 런타임 선택 변경 확인

설치된 실행 파일은 재링크하지 않고 검색 경로만 바꾸어 선택이 달라지는지 확인할 수 있다. 원본 라이브러리를 옮기거나 삭제할 필요는 없다.

```bash
odbc_check_override="$PWD/odbc-runtime-copy"
mkdir -p "$odbc_check_override"
cp -a "$odbc_check_build"/3rdparty/lib/libodbc.so* "$odbc_check_override/"
env -u LD_PRELOAD LD_LIBRARY_PATH="$odbc_check_override" \
  ldd -r "$odbc_check_install/bin/cub_cas_cgw" | grep 'libodbc.so.2 =>'
```

기존 PoC prefix 제거 효과는 실행 파일을 복사하고 읽기 전용 mount namespace 안에서 prefix를 빈 디렉터리로 가리는 별도 실험으로 확인했다. 원본 prefix나 설치 파일은 변경하지 않았다.

## Expected Result

Gateway의 개발용 입력과 설치 후 실행용 의존성에 대해 지원하는 공급원·버전과 설치 요구사항이 명시되고, 그 선택을 빌드·패키지·실행 검증이 일관되게 확인해야 한다. 빌드에서 특정 unixODBC를 준비했다는 이유만으로 설치 후 그 버전을 사용한다고 간주해서는 안 된다.

자동 준비가 최종 실행에 필요하지 않은 공급 방식을 채택한다면 메인 엔진의 불필요한 준비를 제거·분리하는 방향을 우선 검토한다. Gateway에 필요한 입력을 대신 공급하거나 Gateway 제외 구성을 갖추는 변경과 함께 검증한다. 동봉 또는 시스템 공급 중 최종 구현, 지원 버전, 패키지별 책임은 TBD - ANALYSIS 단계에서 결정한다.

## Actual Result

새 일반 빌드의 실제 헤더 의존성에는 `3rdparty/include/sqltypes.h`, `sql.h`, `sqlext.h`, `sqlucode.h`가 있다. Gateway 링크 명령은 해당 빌드의 `3rdparty/lib`에 대한 `-L`과 `-lodbc`를 포함한다. 생성 ELF에는 ODBC 미해결 심볼 23개와 `NEEDED libodbc.so.2`가 있다. unixODBC를 빌드 입력이나 코드에서 사용하지 않는다는 해석은 맞지 않는다.

반면 최종 설치 목록 198개 중 관련 항목은 `bin/cub_cas_cgw`와 `3rdparty/libodbc_license.txt`였다. 설치 디렉터리 전체에도 `libodbc.so*`는 없었다. 실제 CPack TGZ에서도 같은 제외를 확인했다.

```text
일반 build-tree:
  NEEDED:  libodbc.so.2
  RUNPATH: <BUILD>/cs:<BUILD>/cubrid-cci/cci:<BUILD>/3rdparty/lib:
  ldd:     libodbc.so.2 => <BUILD>/3rdparty/lib/libodbc.so.2

같은 빌드의 최종 설치본:
  NEEDED:  libodbc.so.2
  RUNPATH: <INSTALL>/lib
  ldd:     libodbc.so.2 => /lib64/libodbc.so.2

실제 파일:
  빌드 입력: unixODBC 2.3.14
  시스템:    unixODBC-2.3.9-4.el9.x86_64
```

| 추가 검증 | 관측 결과 | 범위 |
| --- | --- | --- |
| 기존 일반 설치본 재검사 | 시스템 `/lib64/libodbc.so.2` 선택 | `11.5.0.2683-4adcd40`, 이 호스트의 결과 |
| 새 build-tree 복사본에서 빌드 라이브러리 경로를 숨김 | 시스템 라이브러리로 변경 | 같은 ELF, 원본 경로는 호스트에서 보존 |
| 새 설치 ELF에 별도 복사 라이브러리의 `LD_LIBRARY_PATH` 지정 | 복사한 2.3.14 선택 | 재링크 없이 검색 경로로 선택이 달라짐 |
| PoC 설치 ELF 복사본, prefix 유지 | PoC prefix의 2.3.14 선택 | 기존 PoC의 ldd 증거도 이 구성임 |
| 같은 PoC 복사본에서 prefix를 숨김 | 시스템 2.3.9로 변경 | prefix 로드 성공만으로 해당 버전의 사용을 보장할 수 없음 |
| CPack TGZ | Gateway·라이선스 포함, `libodbc.so*` 및 unixODBC 도구 6개 없음 | 새 로컬 TGZ 생성 성공 |
| CPack RPM | staging·생성 spec에는 `libodbc.so*` 없음 | 완성 RPM 생성은 Python shebang 검사 오류로 실패 |

새 기준·PoC 복사본의 `ldd -r` 검사에 미해결 심볼 또는 누락 DSO 진단은 없었다. 이 결과는 로더의 선택과 relocation 검사이며, 두 버전의 외부 DB 연결·조회가 완전히 호환된다는 기능 검증은 아니다. unixODBC가 없는 새 호스트에서의 실패도 별도로 재현하지 않았다.

## Additional Information

### 패키지 범위와 RPM 제한

생성한 TGZ는 `CUBRID-11.5.0.2704-cc94778-Linux.x86_64-debug.tar.gz`이며 SHA256은 `cf3a02fae35c5b69109b97cc80db629d75878aa2741e5ab3d140b05e0e16045b`이다. 이 실험 산출물을 공식 배포물로 게시하지 않았다.

RPM 생성은 `broker_log_top.py`, `brokerstatus_to_csv.py`, `statdump_to_csv.py`의 `#!/usr/bin/python` 계열 shebang을 Rocky 9 RPM 검사가 거부하여 실패했다. 이를 수정하거나 검사를 끄지 않았다. 따라서 완성 RPM, STGZ 및 외부 패키징으로 만든 공식 배포물 전체가 동일하다고 단정하지 않는다.

기준 소스의 RPM 설정은 자동 Requires 생성을 끄며 명시한 Requires에도 unixODBC가 없다. 런타임 공급 누락을 점검할 근거이지만, 완성 RPM 메타데이터와 새 호스트의 설치·기능 시험은 미검증이다.

### 반복 빌드 비용과 CI 증거

unixODBC는 공통 `EP_TARGETS`에 포함되어 엔진 라이브러리의 선행 의존성으로도 연결된다. 실행 중 Gateway/DBLINK를 사용하지 않아도 이 그래프는 바뀌지 않는다. `build.sh clean`은 별도 빌드 디렉터리의 내용을 지우므로 외부 프로젝트의 출력·다운로드·stamp도 사라질 수 있다. 이미 완료된 일반 증분 빌드가 매번 재다운로드한다는 뜻은 아니다.

요청자는 이 반복 준비가 CI 병목 중 하나라고 보고했다. 기준 커밋의 [기존 develop push CI](https://github.com/CUBRID/cubrid/actions/runs/39386422016)에서 실제 checkout SHA와 unixODBC의 download/configure/build/install 단계를 확인했다. Build step은 release 약 179초, debug 약 337초였지만 단독 unixODBC 계측은 없다. 단계 로그의 출력 시각이 묶여 있어 인접 시각 차이를 정확한 단독 시간으로 사용할 수 없다. 이번 검증을 위해 새 CI는 실행하지 않았다.

이번 로컬 `.ninja_log`에서 unixODBC 단계는 download·verify·extract 2.249초, configure 17.086초, build 5.905초, install 1.758초였고 전체 준비 edge는 약 27.088초였다. 전체 Ninja 빌드는 94.269초였다. 새 빌드 디렉터리였지만 호스트 ccache는 비우지 않았고, `MAKEFLAGS=-j80`, Ninja 기본 병렬 설정과 실제 네트워크를 사용했다. 캐시 hit·네트워크·부하를 통제한 벤치마크가 아니다.

다른 공통 의존성인 OpenSSL이 34.528초에 끝나 unixODBC의 완료 시각 27.095초보다 늦었다. 따라서 unixODBC 준비의 27초를 그대로 전체 빌드 절감량으로 볼 수 없다. 기존 PoC의 전체 의존성 producer 시간 125.28초도 unixODBC 단독 시간이 아니다. CI 병목의 비중과 실제 절감량은 같은 조건의 반복 비교와 임계 경로 분석으로 확인해야 한다.

### 수정 범위의 미결정 사항

현재 소스에는 지원되는 `WITH_LIBUNIXODBC=SYSTEM` 우회가 없으며 다른 값은 configure 오류이다. Gateway의 ODBC 헤더·링크 입력·런타임 DSO 의존성은 실제로 남아 있다. 따라서 기존 빌드 규칙만 즉시 삭제해도 안전하다고 판단하지 않는다.

다음 항목을 해결 방안과 함께 확정한다.

- Gateway를 빌드하는 구성의 개발 헤더·링크 입력·런타임 라이브러리 공급원, 지원 버전과 ABI.
- Gateway를 제외하는 구성을 지원할 경우 소스·타깃·공통 외부 의존성·설치 항목의 선택 범위.
- 설치 후 로드 경로, 준비 prefix가 없는 환경의 동작과 의존성 누락 진단.
- ODBC 드라이버 설정 및 실제 외부 DB 연결·조회 시험.
- 자동 준비의 제거·분리 후 실제 빌드 시간과 패키지별 설치 검증.

### 실제 artifact의 라이선스 식별

고정 SHA256의 unixODBC 2.3.14 원본 README는 라이브러리를 LGPL 2.1, 프로그램을 GPL 2.0으로 구분한다. 루트 `COPYING`은 LGPL 2.1, `exe/COPYING`은 GPL 2.0, `libltdl/COPYING.LIB`는 LGPL 2.1이다. [공식 다운로드](https://www.unixodbc.org/download.html)의 [2.3.14 tarball](https://www.unixodbc.org/unixODBC-2.3.14.tar.gz)을 별도로 받아 CMake 고정 hash와 동일함을 확인했다. 움직이는 master README만으로 버전별 근거를 대신하지 않는다.

개별 소스에는 `or later` 문구, libltdl 특별 예외, Patrick Powell snprintf의 별도 고지도 있다. 실제 libodbc에도 해당 내부 구성요소가 연결되므로 전체 tarball을 동일한 단일 라이선스 조건으로 취급하지 않는다. upstream 작업 prefix에는 `isql`, `iusql`, `odbcinst`, `odbc_config`, `dltest`, `slencheck`가 설치되지만, 확인한 최종 CUBRID 설치·TGZ에는 그 도구들이 없었다.

[LGPL 2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html)과 [GPL 2.0](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html)의 식별과 실제 배포 의무 이행은 별도 검증 대상이다. 최종 배포 파일·수정 여부·고지·대응 소스 제공·라이브러리 교체/재링크 조건 등을 검토해야 한다. 라이선스 파일이 설치된다는 사실만으로 준수 완료 또는 위반을 판정하지 않는다.

### 소스 근거

- [unixODBC 기본값·고정 archive 식별](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/3rdparty/CMakeLists.txt#L23-L93)
- [다운로드·빌드·작업 prefix 설치와 미지원 옵션 처리](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/3rdparty/CMakeLists.txt#L430-L460)
- [Gateway 소스·unixODBC 링크](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/broker/CMakeLists.txt#L282-L302)
- [ODBC 개발 헤더 사용](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/src/broker/cas_cgw_odbc.h#L44-L55)
- [ODBC 핸들 생성 API](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/src/broker/cas_cgw_odbc.c#L128-L149)
- [외부 DB 연결 API](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/src/broker/cas_cgw_odbc.c#L216-L252)
- [엔진 라이브러리의 공통 외부 프로젝트 의존성](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/cs/CMakeLists.txt#L637)
- [설치 시 라이브러리 검색 경로](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/CMakeLists.txt#L59-L65)
- [Gateway 설치 대상](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/broker/CMakeLists.txt#L637-L653)
- [라이선스 설치 규칙](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/CMakeLists.txt#L839-L847)
- [RPM 공급·의존성 설정](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/cmake/CPackOptions.cmake.in#L33-L54)
- [CPack을 호출하는 배포 경로](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/build.sh#L435-L475)
