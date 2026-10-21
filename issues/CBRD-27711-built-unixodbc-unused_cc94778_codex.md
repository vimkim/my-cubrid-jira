# [CBRD-27711] 빌드한 unixODBC가 설치된 Gateway에서 사용되지 않음

## Issue Triage

**이슈 수행 목적**: 설치된 Linux Gateway가 지원 대상으로 정한 unixODBC를 사용하도록, 빌드 입력과 설치 후 실행 의존성의 공급원·버전 선택 및 설치 요구사항을 일관되게 관리한다.

**이슈 수행 이유**: 같은 소스의 일반 Linux 빌드에서 build-tree Gateway는 직접 준비한 unixODBC 2.3.14를 선택하지만, 설치본은 시스템 2.3.9를 선택하는 현상을 확인했다. 확인한 CMake 설치와 CPack TGZ에는 `libodbc.so*`가 없어, 빌드에서 준비한 버전만으로 설치 후 사용할 의존성을 보장할 수 없다.

**영향**: Gateway/DBLINK의 빌드 검증과 설치 후 실행이 서로 다른 unixODBC를 대상으로 할 수 있어, 설치·QA 담당자는 실제 사용 버전과 공급 여부를 별도로 확인해야 한다. Gateway를 실행하지 않는 엔진 빌드에도 현재 unixODBC 준비가 연결된다. 외부 DB 기능 장애, 영향받는 배포 환경 수, CI의 unixODBC 단독 비용과 실제 절감량은 미확인이다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

Gateway는 외부 DB의 ODBC 드라이버를 통해 연결·조회 기능을 제공하며, unixODBC는 Gateway와 해당 드라이버 사이의 ODBC 호출을 중개한다. Gateway 소스의 `SQLAllocHandle`, `SQLDriverConnectW` 호출과 생성 ELF의 `NEEDED libodbc.so.2`에서 unixODBC 의존성을 확인했다. 빌드 시 헤더·링크 입력뿐 아니라 설치 후 실행에도 unixODBC 공유 라이브러리가 필요하다.

기준 소스의 일반 Linux 빌드는 unixODBC 2.3.14를 다운로드·컴파일하고 `<BUILD>/3rdparty`에 준비하여 Gateway의 빌드 입력으로 사용한다. 그러나 이 경로는 외부 프로젝트의 작업 디렉터리이며 CUBRID 최종 설치 경로가 아니다. 확인한 CMake 설치와 실제 CPack TGZ에는 Gateway와 unixODBC 라이선스 파일이 있지만 `libodbc.so*`는 없다.

2026-10-21 독립 검증에서는 같은 빌드의 build-tree Gateway가 준비한 2.3.14를 선택하고, 설치된 Gateway는 호스트의 시스템 2.3.9를 선택했다. 설치 전후 ELF의 라이브러리 검색 경로도 `<BUILD>/3rdparty/lib`를 포함하는 경로에서 `<INSTALL>/lib`로 달라졌다. 확인된 현상은 빌드에서 준비한 unixODBC와 설치 후 선택되는 unixODBC 사이의 불일치이다. 필요한 결과는 지원 대상으로 정한 공급원·버전과 설치 후 실제 선택이 일치하는 것이다. 시스템 라이브러리를 사용하는 것이 지원 정책상 허용되는지, 어떤 버전을 보장해야 하는지는 ANALYSIS에서 확인한다.

### 왜 문제인가

개발·QA가 build-tree에서 확인한 실행 의존성과 설치 환경의 실행 의존성이 달라질 수 있다. 따라서 build-tree에서 Gateway가 라이브러리를 찾았다는 결과만으로 설치본의 의존성 공급과 지원 버전을 확인했다고 판단할 수 없다. Gateway/DBLINK의 설치 검증과 장애 재현에서는 CUBRID 빌드 버전 외에 실제 로드한 unixODBC의 공급원·버전까지 별도로 확인해야 한다.

확인한 호스트에는 시스템 unixODBC가 있어 로더 검사가 성공했다. 이는 외부 DB 연결·조회가 두 버전에서 동일하게 동작한다는 증거는 아니다. unixODBC가 없는 호스트의 실행 실패, 실제 기능 장애, 운영 영향 빈도는 아직 검증하지 않았다. 현재 확인된 범위는 의존성 선택의 차이와 설치·TGZ의 라이브러리 미포함이며, 모든 공식 배포물에 같은 문제가 있다고 단정하지 않는다.

빌드 측면에서도 준비 비용과 최종 사용의 관계를 점검할 필요가 있다. unixODBC 준비는 공통 외부 프로젝트 의존성에 포함되어 Gateway를 실행하지 않는 엔진 빌드에도 연결된다. 요청자는 반복 준비가 CI 병목 중 하나라고 보고했다. 기존 CI에서 준비 단계는 확인했지만, unixODBC 단독 소요 시간과 전체 빌드의 실제 절감 가능량은 미확인이다.

### 왜 해결해야 하는가

이 상태를 유지하면 unixODBC를 직접 빌드해도 설치본이 어떤 공급원의 어떤 버전을 사용하는지 별도 확인해야 하는 상태가 남는다. 빌드·설치 검증이 지원 대상으로 정한 의존성 구성을 일관되게 확인하도록 해야, Gateway/DBLINK의 배포 요구사항을 설명하고 같은 조건에서 문제를 재현할 수 있다. 이미 같은 빌드의 설치 전후 차이가 확인되었으므로, 실제 기능 장애나 CI 절감량이 확정되기 전에도 공급·버전 정책과 검증 범위를 분석할 근거가 있다. 운영 장애에 따른 긴급성은 현재 자료로 판단할 수 없다.

확인한 환경에서는 시스템 unixODBC로 로더 검사가 통과하며, `LD_LIBRARY_PATH`로 별도 라이브러리를 지정하면 설치 ELF가 선택하는 파일을 바꿀 수 있다. 다만 이 결과만으로 지원 버전·설치 요구사항·외부 DB 기능 호환성을 확정할 수는 없다. 기준 소스에는 지원되는 `WITH_LIBUNIXODBC=SYSTEM` 구성도 없어, 빌드 옵션 변경만으로 공급 방식을 선택할 수 없다.

공통 3rdparty 분리 빌드와 경로 지정 재사용은 [CBRD-27712](https://jira.cubrid.org/browse/CBRD-27712)의 기능 범위다. 그 기능으로 준비 결과를 재사용하더라도 설치된 Gateway의 실제 라이브러리 선택과 지원 정책이 자동으로 일치하는 것은 아니다. 본 이슈는 unixODBC의 빌드 입력·설치·실행 사이의 공급과 버전 선택을 일관되게 관리하는 문제를 다룬다. 자동 준비의 필요성과 엔진 빌드와의 결합도 이 정책에 맞추어 검토하되, 구체적인 공급 방식과 구현은 분석에서 결정한다.

## Triage Request

동일 빌드에서 확인한 unixODBC 선택 불일치를 결함으로 확인하고, 작성자 측에 ANALYSIS를 배정할 것을 요청한다.

ANALYSIS에서는 지원할 unixODBC 공급원·버전, 설치·패키지별 의존성 보장, 준비 경로가 없는 환경의 동작, 실제 외부 DB 연결·조회 결과를 확인한다. 메인 엔진 빌드에서 unixODBC 자동 준비가 필요한 조건과 CBRD-27712와의 경계도 정리한다. 구현 선택과 최종 검증 기준은 분석에서 확정하며, 담당자와 우선순위는 triage에서 결정한다.

## Test Build

아래는 2026-10-21 독립 검증 기록의 환경과 결과다. 소스 기준과 실제 실행·패키지 검증 범위를 구분한다.

- 독립 검증 기준 소스: `cc947788d3b7dc402f46192d0f3299ddcc8563ba`, CUBRID `11.5.0.2704-cc94778`.
- 새 실험 구성: Linux x86_64 Debug, GCC 11.5.0, CMake 3.26.5, Ninja 1.10.2, Rocky Linux 9.6, kernel `5.14.0-570.30.1.el9_6.x86_64`.
- unixODBC: 기본 `WITH_LIBUNIXODBC=EXTERNAL`, 원본 2.3.14. 소스 archive SHA256: `4e2814de3e01fc30b0b9f75e83bb5aba91ab0384ee951286504bb70205524771`.
- CCI: `79d0888c26a2543d31f53eb7b6c9738db110fff4`, `WITH_CCI=true`. JDBC·Manager 하위 저장소는 새 실험에서 초기화하지 않았다.
- 새 실험은 O0·디버그 정보·프레임 포인터·C++17과 ccache를 사용했고 OOS·spage·page buffer 단위 테스트 빌드 옵션을 켰다. unixODBC의 기본 준비·링크·설치 규칙은 수정하지 않았다.
- 시스템 라이브러리: RPM `unixODBC-2.3.9-4.el9.x86_64`, 실제 파일 `/usr/lib64/libodbc.so.2.0.0`.
- 기존 설치본도 별도로 재검사했다: `11.5.0.2683-4adcd40`, Linux 64bit debug. 네 관련 소스 파일은 `4adcd409072b189f5d965bde5750c53176d90de0`와 새 기준 커밋에서 내용이 동일했다. 기존 바이너리 전체의 빌드 출처를 현재 checkout으로 간주하지 않는다.
- 기존 PoC 기준은 `ad2182f08d2cb5e1c7b56f1b6b47cef704171aa9`이며, PoC prefix 로드 결과와 일반 빌드의 시스템 로드 결과를 구분했다.
- 검증일: 2026-10-21. 새 전체 빌드·설치·TGZ 생성과 로더 검사를 수행했으며 외부 DB 연결·조회 시험은 수행하지 않았다.
- Release 설치본의 로더 선택, 다른 지원 릴리스와 Windows는 미검증이다. 기준 커밋의 존재만으로 해당 릴리스의 영향을 확정하지 않는다.

## Repro

### 확인 조건

CUBRID Linux 빌드 요구사항, Ninja, `readelf`, `ldd`, RPM 조회 도구와 시스템 unixODBC 런타임이 준비된 개발 VM을 사용한다. 소스와 외부 의존성을 내려받을 수 있어야 한다. 아래 명령은 기존 검증을 표준 도구로 재구성한 재현 절차 제안이며, 이 명령 블록 그대로 실행한 기록은 없다. 기존 설치나 작업 디렉터리를 지우지 않고 별도 worktree와 설치 위치를 사용한다. 디렉터리 이름이 이미 사용 중이면 다른 새 이름을 선택한다. `ccache` 등 개인 빌드 도구는 필수 조건이 아니다.

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

Gateway의 개발용 입력과 설치 후 실행용 의존성에 대해 지원하는 unixODBC 공급원·버전과 설치 요구사항을 명시하고, 설치된 Gateway가 그 정책에 맞는 라이브러리를 선택함을 확인해야 한다. 빌드·패키지·실행 검증에서 같은 지원 정책을 확인할 수 있어야 한다.

자동 준비의 필요성과 엔진 빌드 의존성도 확정한 공급 정책에 맞게 정리해야 한다. 라이브러리 동봉 여부, 시스템 공급 지원, Gateway 선택 구성과 상세 구현은 TBD - ANALYSIS 단계에서 결정한다. 빌드와 실행이 반드시 동일한 파일을 사용하도록 할지, 지원되는 서로 다른 버전을 허용할지도 분석에서 정한다.

## Actual Result

새 일반 빌드의 실제 헤더 의존성에는 `3rdparty/include/sqltypes.h`, `sql.h`, `sqlext.h`, `sqlucode.h`가 있다. Gateway 링크 명령은 해당 빌드의 `3rdparty/lib`에 대한 `-L`과 `-lodbc`를 포함한다. 생성 ELF에는 ODBC 미해결 심볼 23개와 `NEEDED libodbc.so.2`가 있다. unixODBC를 빌드 입력이나 코드에서 사용하지 않는다는 해석은 맞지 않는다.

반면 보존된 최종 설치 목록에서 관련 항목은 `bin/cub_cas_cgw`와 `3rdparty/libodbc_license.txt`였다. 설치 디렉터리 전체에도 `libodbc.so*`는 없었다. 실제 CPack TGZ에서도 같은 제외를 확인했다.

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
- 자동 준비 변경의 필요성과 실제 빌드 비용, 패키지별 설치 검증.

### 소스 근거

- [독립 검증 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-27711/independent-unixodbc-review_cc94778_codex.md): 일반 빌드·설치·TGZ·ELF·CI의 검증 결과와 한계를 기록한다. 기존 PoC 및 라이선스 식별 자료도 이 기록에 보존한다.
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
