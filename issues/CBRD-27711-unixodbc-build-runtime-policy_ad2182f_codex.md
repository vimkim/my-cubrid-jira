# [CBRD-27711] unixODBC 반복 빌드 비용과 Gateway 배포 의존성 정리

## Issue Triage

**이슈 수행 목적**: 메인 엔진의 반복 빌드에서 unixODBC 준비 비용을 줄이고, Gateway/DBLINK가 사용하는 unixODBC의 공급·배포 방식을 결정한다.

**이슈 수행 이유**: CI 등에서 unixODBC 빌드가 긴 시간을 차지하는 병목 중 하나로 지적됐다. 현재 Linux 빌드는 unixODBC를 직접 빌드해 Gateway에 연결하지만, CUBRID 설치물에는 해당 공유 라이브러리를 넣지 않는다. 확인한 설치본은 시스템 라이브러리를 로드한다. 가능하면 unixODBC 빌드를 메인 엔진 빌드 과정에서 제거하는 방향을 우선 검토한다.

**영향**: Gateway/DBLINK 사용 여부와 관계없이 기본 빌드가 unixODBC를 준비하며, clean 후 다시 준비하는 비용이 반복될 수 있다. 설치 환경에 따라 빌드에 사용한 라이브러리와 실행 시 로드하는 라이브러리가 달라질 수 있다.

**이슈 수행 방안**: unixODBC의 기본 서드파티 빌드를 제거하고 Gateway/DBLINK용 의존성을 별도로 공급하는 방안과, 선택한 unixODBC 공유 라이브러리를 CUBRID 설치물에 동봉하는 방안을 비교한다. 후자를 선택하려면 실제 배포 구성의 라이선스 준수 조건을 검토한다. 최종 방안은 TBD - ANALYSIS 단계에서 결정한다. 결정 전까지 기존 일반 Linux 빌드·설치 정책은 유지한다.

---

## AI-Generated Context

> 아래는 AI가 코드와 맥락을 분석해 작성한 상세 자료다.

## Description

unixODBC는 Linux에서 ODBC 연결을 관리하는 라이브러리다. CUBRID Gateway는 이 라이브러리를 통해 외부 DB의 ODBC 드라이버를 사용한다. unixODBC 자체와 각 외부 DB가 제공하는 ODBC 드라이버는 구분해야 한다.

요청자는 unixODBC 빌드가 CI 등 전체 빌드에서 큰 비중을 차지하는 병목 중 하나라고 보고했다. 따라서 메인 엔진 빌드에서 분리하거나 제거할 수 있다면 제거하는 방향을 우선 검토한다. 현재 확보한 자료에는 unixODBC 단독 빌드 시간과 전체 CI 시간 대비 비율이 없으므로, 실제 절감량은 동일 조건에서 측정해야 한다.

기존 Linux 경로는 `ExternalProject`로 unixODBC 2.3.14를 다운로드·빌드하고, 빌드 디렉터리 아래 `3rdparty/lib/libodbc.so`를 Gateway에 연결한다. 이때 unixODBC의 `make install`은 서드파티 작업 디렉터리에 파일을 넣는다. CUBRID의 최종 설치 디렉터리에 공유 라이브러리를 복사한다는 뜻은 아니다.

Gateway 코드는 `SQLAllocHandle`, `SQLDriverConnectW` 등 ODBC API를 실제로 사용한다. 직접 빌드한 unixODBC는 Gateway의 빌드·링크 입력이지만, 확인한 설치본은 실행 시 시스템 라이브러리를 사용한다. 메인 엔진 빌드에서 unixODBC 준비를 제거하려면 Gateway에 필요한 헤더·링크 라이브러리와 실행용 공유 라이브러리의 공급 방법도 함께 정해야 한다. 현재 자료만으로 빌드 규칙을 즉시 삭제해도 안전하다고 단정하지 않는다.

| 단계 | 확인한 기존 Linux 경로 |
|---|---|
| 의존성 준비 | unixODBC 소스를 받아 공유 라이브러리를 빌드한다. |
| Gateway 링크 | 빌드한 `libodbc.so`에 연결한다. |
| CUBRID 설치 | Gateway와 unixODBC 라이선스는 설치하지만 `libodbc.so*`는 복사하지 않는다. |
| 설치 후 실행 | 확인한 설치본은 시스템의 `/lib64/libodbc.so.2`를 로드한다. |

공유 라이브러리에 연결한 실행 파일에는 `libodbc.so.2`가 필요하다는 의존성이 남는다. 실행 시 실제 파일은 동적 로더가 검색한다. 따라서 직접 빌드한 파일로 링크했다는 사실만으로 그 파일이 설치 후에도 사용된다고 보장할 수 없다.

## Test Build

- 소스 분석 기준: CUBRID 11.5.0, `develop`의 `cc947788d3b7dc402f46192d0f3299ddcc8563ba`.
- 작성 작업 기준: `thirdparty-reuse-poc`의 `ad2182f08d2cb5e1c7b56f1b6b47cef704171aa9`. 기존 일반 Linux 경로를 분석 대상으로 구분했다.
- 실행 경로 확인에 사용한 기존 설치본: `11.5.0.2683-4adcd40`, Linux x86_64 Debug.
- 실행 환경: Rocky Linux 9.6.
- `4adcd409072b189f5d965bde5750c53176d90de0`과 소스 분석 기준 사이에서 `3rdparty/CMakeLists.txt`, `broker/CMakeLists.txt`, `src/broker/cas_cgw_odbc.c`, 루트 `CMakeLists.txt`의 내용은 동일하다.
- 이번 작성에서는 기존 설치본의 설치 목록과 ELF 의존성·로드 경로를 확인했다. 새로운 전체 빌드나 외부 DB 연결 시험은 수행하지 않았다.

## Repro

### 확인 조건과 절차

Linux 빌드 요구사항과 시스템 `libodbc.so.2`가 준비된 별도 작업 디렉터리에서 기존 소스로 빌드·설치한다. 설치 디렉터리에 unixODBC를 수동 복사하거나 라이브러리 검색 경로를 별도로 지정하지 않는다. 아래 절차는 같은 동작을 확인하기 위한 재현 절차다.

```bash
git checkout cc947788d3b7dc402f46192d0f3299ddcc8563ba
git submodule update --init --recursive
odbc_check_build="$PWD/build-unixodbc-check"
odbc_check_install="$PWD/install-unixodbc-check"
cmake -S . -B "$odbc_check_build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_INSTALL_PREFIX="$odbc_check_install"
cmake --build "$odbc_check_build" --parallel 8
cmake --install "$odbc_check_build"
find "$odbc_check_build/3rdparty/lib" -maxdepth 1 -name 'libodbc.so*' -ls
grep -E 'cub_cas_cgw|libodbc' "$odbc_check_build/install_manifest.txt"
readelf -d "$odbc_check_install/bin/cub_cas_cgw" | grep -E 'NEEDED|RPATH|RUNPATH'
env -u LD_LIBRARY_PATH -u LD_PRELOAD \
  ldd "$odbc_check_install/bin/cub_cas_cgw" | grep 'libodbc'
```

## Expected Result

unixODBC의 빌드 부담을 줄이는 방안과 Gateway/DBLINK에 필요한 의존성 공급 방법을 일관되게 결정한다.

메인 엔진에서 분리할 수 있는 빌드는 분리하고, 동봉 방안을 선택하면 실제 배포 구성에 적용되는 라이선스 의무를 확인한다. 최종 구현과 지원 버전은 TBD로 둔다.

## Actual Result

확인한 기존 설치 목록에는 `bin/cub_cas_cgw`와 `3rdparty/libodbc_license.txt`가 있으며, `libodbc.so*`는 없다. 실행 파일의 확인 결과는 다음과 같다. 경로의 `<CUBRID_INSTALL>`은 확인한 설치 위치를 나타낸다.

```text
NEEDED:  libodbc.so.2
RUNPATH: <CUBRID_INSTALL>/lib
ldd:     libodbc.so.2 => /lib64/libodbc.so.2
```

이 관측은 해당 Linux 설치본에 대한 결과이며, 모든 OS와 배포물에서 같은 검색 결과가 나온다고 단정하지 않는다. 현재 코드에서 unixODBC를 빌드·링크에 사용하지만, 해당 설치본의 실행 시에는 별도로 설치된 시스템 공유 라이브러리를 사용한다.

## Additional Information

### 비교할 방안

| 항목 | 방안 1: 메인 빌드에서 분리하고 별도 공급 | 방안 2: CUBRID 설치물에 동봉 |
|---|---|---|
| 기본 빌드 | unixODBC 자동 빌드 제거를 검토한다. Gateway를 빌드할 때 필요한 개발용 헤더·라이브러리는 별도로 공급한다. | 사용할 unixODBC를 빌드하거나 별도로 준비한다. 반복 빌드 병목을 줄이려면 준비 작업의 분리·재사용도 함께 검토한다. |
| 실행 환경 | Gateway/DBLINK 사용 환경에 unixODBC를 별도 패키지 또는 별도 제공물로 공급한다. | 선택한 공유 라이브러리와 필요한 링크를 CUBRID 설치 디렉터리에 포함한다. |
| 확인 사항 | 지원 버전·ABI, 별도 설치 절차, Gateway 미사용 빌드에서 제거 가능한 범위와 누락 시 진단을 정한다. | 설치된 Gateway가 동봉한 라이브러리를 로드하는지, 원본 빌드 경로를 제거해도 동작하는지 확인한다. |
| 책임 범위 | 별도 제공물의 배포·업데이트·라이선스 의무를 정한다. | 동봉한 버전의 배포·보안 업데이트와 라이선스 준수 책임을 정한다. |

방안 1을 우선 검토하되, 두 방안 중 최종 선택은 아직 확정하지 않았다. 방안 2의 파일 동봉만으로 엔진 빌드 시간이 줄어드는 것은 아니므로, 성능 개선과 배포 정책을 함께 판단한다.

### 동봉 시 라이선스 검토

사용한 unixODBC 2.3.14 소스의 `README`는 라이브러리를 LGPL 2.1, 프로그램을 GPL 2.0으로 구분한다. 상위 프로젝트의 [README](https://github.com/lurcher/unixODBC/blob/master/README)와 [COPYING](https://github.com/lurcher/unixODBC/blob/master/COPYING)에서도 관련 라이선스를 확인할 수 있다.

동봉을 선택하기 전에 실제 배포 파일과 수정 여부를 기준으로 저작권·라이선스 고지, 대응 소스 제공 방식, 라이브러리 교체·재링크 관련 조건 등 적용되는 의무를 검토한다. 라이브러리 외에 도구나 외부 DB용 드라이버를 추가하면 그 구성요소도 별도로 확인한다. 현재 라이선스 파일이 설치된다는 사실만으로 동봉 시 준수 조건이 충족됐다고 판단하지 않는다. 위반 여부와 이행 방안은 TBD - ANALYSIS 단계에서 결정한다.

### 결정 완료 조건

- [ ] 동일 환경에서 unixODBC 준비 시간과 전체 빌드 시간을 측정하고, 메인 엔진 빌드에서 제거·분리할 수 있는 범위를 확인한다.
- [ ] 두 공급 방안 중 하나를 선택하고 빌드·설치·업데이트 책임을 기록한다.
- [ ] Gateway의 빌드 입력과 실제 실행 라이브러리의 버전·로드 경로를 검증한다.
- [ ] 동봉 또는 별도 제공물 배포 시 적용되는 라이선스 의무와 이행 방안을 검토한다.
- [ ] 선택한 방식으로 Gateway/DBLINK의 외부 DB 연결·조회와 설치 절차를 검증한다. 이번 로드 경로 확인을 해당 기능 시험의 통과로 간주하지 않는다.

### 소스 근거

- [unixODBC 다운로드·빌드·서드파티 작업 경로 설치](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/3rdparty/CMakeLists.txt#L430-L460)
- [Gateway의 unixODBC 링크](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/broker/CMakeLists.txt#L293-L302)
- [ODBC 핸들 생성 API 사용](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/src/broker/cas_cgw_odbc.c#L128-L149)
- [외부 DB 연결 API 사용](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/src/broker/cas_cgw_odbc.c#L244-L252)
- [설치 시 라이브러리 검색 경로](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/CMakeLists.txt#L59-L65)
- [Gateway 설치 대상](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/broker/CMakeLists.txt#L637-L653)
- [기존 라이선스 설치 규칙](https://github.com/CUBRID/cubrid/blob/cc947788d3b7dc402f46192d0f3299ddcc8563ba/CMakeLists.txt#L845-L847)
