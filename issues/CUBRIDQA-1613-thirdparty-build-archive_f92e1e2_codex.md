# [CUBRIDQA-1613] [CI] 서드파티 반복 다운로드로 인한 성능 지연 해결

## Issue Triage

**이슈 수행 목적**: CUBRID 소스만 변경된 CI 빌드에서는 변경되지 않은 서드파티 빌드 결과를 재사용해, 매번 반복되는 다운로드와 컴파일을 건너뛰도록 한다. 최종 CUBRID 산출물과 링크 방식은 현재와 동일하게 유지한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | `build_rl8.10` entrypoint는 항상 `build.sh ... clean build`를 실행한다. 따라서 엔진 소스만 바뀌어도 서드파티 다운로드 및 빌드 상태가 함께 사라지며, `ccache`(compiler 출력 cache)가 있어도 다운로드·configure·archive/link 단계는 다시 수행한다. |
| **TO-BE (목표 상태 / 기대 동작)** | 서드파티 입력과 도구 체인이 같으면 검증된 불변 archive(완료 후 변경하지 않는 압축 묶음)를 pod 로컬 빌드 디렉터리에 복원하고 CUBRID 소스만 다시 빌드한다. 서드파티 버전이나 빌드 입력이 바뀐 경우에만 새로 빌드한다. |
| **영향** | 성능 저하 — 짧게 실행되고 폐기되는 CI pod마다 외부 네트워크 접근과 동일한 서드파티 컴파일이 반복되어, 소스 변경과 무관한 대기 시간이 빌드 시간에 누적된다. |

**이슈 수행 방안**:

| 항목 | 결정 |
|------|------|
| 저장 단위 | 기존 `clean` 동작은 유지하되, 완료된 `build_<target>_<mode>/3rdparty/` 전체를 checksum이 포함된 `tar.zst` archive로 보관하고 `clean` 직후 복원한다. |
| 읽기와 발행 | 일반 PR job은 archive를 읽기만 한다. 명시적으로 허용한 신뢰 job만 임시 디렉터리에서 archive를 완성한 뒤 최종 key로 rename한다. |
| 무효화 기준 | key에는 `3rdparty/CMakeLists.txt`, compiler/CMake 및 관련 package 버전, build 인자·flag와 경로를 포함하고 CUBRID commit은 제외한다. |
| 설정 오류 | archive 경로 환경 변수가 설정됐지만 비어 있거나 mount가 없으면 즉시 실패시켜 CI 설정 오류를 숨기지 않는다. |
| 압축 | 복원이 발행보다 자주 일어난다는 전제에서 빠른 해제 속도를 우선해 `zstd -3`을 사용한다. |

실제 Kubernetes volume의 rename 보장, publisher 권한, 보존 기간, 손상 archive 교체 정책과 최종 구현 범위는 `TBD - CUBRIDQA-1613 구현 단계에서 결정`한다.

---

## AI-Generated Context

> 아래는 AI가 코드와 작업 맥락을 분석해 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현과 리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `CUBRID/cubridci`의 `build_rl8.10` branch와 CI pod의 archive volume 구성이 대상이다. CUBRID engine repository의 build interface는 변경하지 않는다.
- **호환성**: archive 기능을 사용하지 않으면 기존 `clean build` 경로가 그대로 실행된다. 서드파티 결과를 재사용해도 설치 경로와 최종 package 형식은 바뀌지 않는다.
- **참고 구현**: [CUBRID/cubridci PR #125](https://github.com/CUBRID/cubridci/pull/125)는 entrypoint 방식의 POC이며, production merge가 아니라 후속 구현의 출발점이다.

## Description

CUBRID는 외부 라이브러리의 다운로드부터 설치까지 관리하는 CMake `ExternalProject`로 서드파티 build를 구성한다. 다운로드 파일, 압축 해제한 source, 중간 build 결과, 설치 파일과 완료 stamp를 모두 `${CMAKE_BINARY_DIR}/3rdparty` 아래에 두며, 완료 stamp는 각 단계가 끝났다는 기록이다.

현재 entrypoint가 호출하는 `build.sh clean`은 선택된 build directory의 모든 항목을 비운다. 이때 `3rdparty`의 결과뿐 아니라 완료 stamp도 함께 없어지므로, 이어지는 `build`는 외부 라이브러리가 이미 준비됐다는 사실을 알 수 없다. 기존 `ccache`는 compiler가 생성하는 object 재사용에는 도움이 되지만 이 상태 전체를 보존하지는 않는다.

로컬 debug build에서 완성된 `3rdparty` tree는 약 363 MiB였으며 `Download/`, `Source/`, `Build/`, `Stamp/`, 설치된 `lib/`와 `include/`를 포함했다. 이 수치는 고정 규격이 아니라 archive 방식의 실용성을 확인한 관측값이다. 라이브러리 파일만 따로 복사하면 완료 stamp와 절대 경로가 사라지므로, 이 POC는 tree 전체를 같은 source/build 경로에 복원한다.

현재 expat, libedit, OpenSSL, LZ4, RE2, TBB는 정적 library를 사용하고 RapidJSON은 header-only다. unixODBC는 `libodbc.so`를 사용하는 예외다. 이번 작업은 이 구성을 그대로 재사용하며, unixODBC를 정적으로 바꾸는 제품 링크 변경은 포함하지 않는다.

## Specification Changes

| 설정 | 동작 |
|------|------|
| `CUBRID_3RDPARTY_ARCHIVE_DIR` 미설정 | 기존 `build.sh ... clean build` 실행 |
| 유효한 archive directory로 설정 | key를 계산하고 checksum과 완료 marker가 유효한 archive만 복원 |
| 설정값이 비었거나 directory가 없음 | mount 오류로 처리하고 build 시작 전에 실패 |
| `CUBRID_3RDPARTY_ARCHIVE_PUBLISH=true` | cache miss 후 성공한 build 결과를 발행할 수 있는 trusted publisher로 동작 |
| 그 외 | 읽기 전용 consumer로 동작하며 miss 또는 손상 시 pod 안에서 정상 build 수행 |

archive 한 건은 다음 파일로 구성한다.

```text
<archive-root>/v1/<key>/
  manifest.txt
  thirdparty.tar.zst
  thirdparty.tar.zst.sha256
  complete
```

## Implementation

POC가 제안하는 실행 순서는 다음과 같다.

```text
/entrypoint.sh build
  |
  +-- archive 기능 미사용 ----------------> 기존 clean build
  |
  +-- build.sh ... clean
       |
       +-- key 계산
       |
       +-- hit: checksum 확인 -> pod 로컬 3rdparty tree 복원
       |                         -> build.sh ... build
       |
       +-- miss/손상: build.sh ... build
                      |
                      +-- trusted publisher만 임시 경로에 압축
                          -> checksum/complete 생성 -> 최종 key로 rename
```

PR #125는 이를 확인할 수 있도록 다음 세 파일만 수정한다.

- `docker/ci/Dockerfile`: Rocky Linux 8.10 package에 `zstd` 추가
- `docker/ci/docker-entrypoint.sh`: key 계산, 검증·복원, cold build 및 선택적 발행 흐름 추가
- `README.md`: 환경 변수, `zstd` 선택 이유와 production 적용 전 검토 항목 기록

POC의 archive key는 CUBRID commit을 넣지 않는다. 엔진 소스만 바뀐 경우 같은 key를 사용해야 재사용 목적을 달성하기 때문이다. 반대로 서드파티 URL·hash가 있는 `3rdparty/CMakeLists.txt`, compiler와 CMake, 관련 package, build 인자·flag 또는 고정 경로가 바뀌면 다른 key를 만든다.

## Acceptance Criteria

- [ ] `CUBRID_3RDPARTY_ARCHIVE_DIR`를 설정하지 않은 build가 기존과 같은 `clean build` 결과를 만든다.
- [ ] archive hit에서는 서드파티 URL에 접근하지 않고 download, configure, build, install 단계가 다시 실행되지 않는다.
- [ ] `3rdparty/CMakeLists.txt`의 dependency version 또는 hash를 바꾸면 cache miss가 발생한다.
- [ ] 설정된 archive directory가 없거나 읽을 수 없으면 원인을 포함한 오류로 즉시 실패한다.
- [ ] checksum 불일치나 불완전한 entry는 사용하지 않고 pod 로컬에서 cold build한다.
- [ ] 같은 key를 두 job이 동시에 발행해도 완료된 entry 하나만 보이며 consumer가 중간 파일을 읽지 않는다.
- [ ] release와 optdebug 각각에서 cold/warm build 시간과 network 수신량을 비교해 개선 효과를 기록한다.
- [ ] `file`, `readelf -d`, `ldd` 비교로 주요 CUBRID 실행 파일의 산출물 및 동적 dependency가 기존 build와 같음을 확인한다.

## Definition of done

- [ ] 위 A/C를 충족한다.
- [ ] production Kubernetes storage와 권한 구성에서 hit, miss, 동시 발행, 중단된 publisher를 검증한다.
- [ ] 자동화된 entrypoint test와 운영 문서를 반영한다.
- [ ] CUBRIDQA-1613에 최종 측정 결과와 적용 방식을 기록하고 관련 PR을 리뷰 완료한다.

## Remarks

- POC source commit: `f92e1e2748d358344c16f492284e623b553f90aa`
- 장기적으로는 CMake에 relocatable `PREBUILT` mode를 추가하고 image layer에 dependency prefix를 넣는 방식도 가능하다. 이 방식으로 전환할지는 이번 구현 결과를 바탕으로 별도 결정한다.
