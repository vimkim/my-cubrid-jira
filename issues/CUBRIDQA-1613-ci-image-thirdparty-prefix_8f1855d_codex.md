# [Improve] CI 이미지에 3rdparty prefix를 포함해 반복 빌드 제거

## Issue Triage

**이슈 수행 목적**: CUBRID 소스만 변경된 CI 빌드에서는 이미지에 포함된 3rdparty 빌드 결과를 재사용하고, pod에서는 CUBRID 소스의 compile과 link만 수행하도록 한다. 최종 CUBRID 산출물과 기존 link 방식은 유지한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | `build_rl8.10` entrypoint는 항상 `./build.sh ... clean build`를 실행한다. `clean`이 build directory와 그 아래 ExternalProject 상태를 지우기 때문에, 엔진 소스만 변경돼도 3rdparty 다운로드, configure, compile이 반복된다. |
| **TO-BE (목표 상태 / 기대 동작)** | cubridci 이미지를 만들 때 고정된 CUBRID revision으로 3rdparty prefix를 한 번 생성한다. 일반 CI pod는 이미지의 `/opt/cubrid-thirdparty`를 검증한 뒤 바로 사용하며, archive 복사나 압축 해제를 수행하지 않는다. |
| **영향** | 성능 저하 - 수명이 짧은 CI pod마다 소스 변경과 무관한 네트워크 접근과 3rdparty build 시간이 누적된다. `ccache`는 compiler object cache이므로 이 문제를 제거하지 못한다. |

**이슈 수행 방안**:

| 항목 | 결정 |
|------|------|
| 저장 위치 | 완성된 expanded prefix를 cubridci 이미지의 `/opt/cubrid-thirdparty`에 포함한다. 공유 volume과 3rdparty archive는 사용하지 않는다. |
| 생성 기준 | 이미지 build는 full 40-character CUBRID commit SHA를 사용하며, 해당 revision의 canonical `3rdparty/manifest.json`과 producer target으로 prefix를 만든다. |
| 소비 방식 | CI 전용 mode 이름은 `CI_PREBUILT`로 하고, `CUBRID_3RDPARTY_ROOT`로 prefix 경로를 전달한다. mode가 설정됐는데 prefix가 없거나 manifest fingerprint가 다르면 fallback 없이 실패한다. |
| 호환성 | Release와 OptDebug는 같은 prefix를 사용한다. 기존 static/shared 구성을 유지하며 unixODBC는 현재처럼 shared library를 사용한다. |
| 적용 범위 | 첫 적용 대상은 `build_rl8.10` Linux x86_64다. mode가 미설정이거나 `EXTERNAL`이면 개발자의 기존 ExternalProject build를 유지한다. |
| 운영 | image tag, rollout 순서, 배포 책임은 `TBD - CUBRIDQA-1613 구현 단계에서 결정`한다. |

---

## AI-Generated Context

> 아래는 AI가 코드와 작업 맥락을 분석해 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현과 리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `CUBRID/cubridci`의 `docker/ci/Dockerfile`, `docker/ci/docker-entrypoint.sh`와 CUBRID repository의 3rdparty CMake interface가 대상이다.
- **호환성**: 로컬 개발 build와 CI-prebuilt mode를 사용하지 않는 build는 기존 ExternalProject 경로를 그대로 사용한다. package 형식과 dependency linkage를 바꾸지 않는다.
- **POC**: [CUBRID/cubridci PR #125](https://github.com/CUBRID/cubridci/pull/125)는 cubridci 쪽 예상 변경을 코드로 보여주는 draft다. CUBRID 쪽 producer/consumer interface는 후속 구현이 필요하다.

## Description

CUBRID의 3rdparty CMake는 외부 dependency의 다운로드부터 설치까지 `ExternalProject`로 관리한다. 다운로드한 파일, 압축 해제한 source, 중간 object, 설치된 library와 각 단계의 완료 stamp가 CUBRID build directory 아래에 놓인다.

CI entrypoint가 호출하는 `build.sh clean`은 이 build directory를 비운다. 완료 stamp까지 사라지므로 이어지는 `build`는 동일한 dependency가 이미 준비됐는지 알 수 없고, ExternalProject 단계를 처음부터 수행한다. `ccache`가 일부 C/C++ compile을 단축할 수는 있지만 dependency 다운로드, configure, install 상태와 완성된 library 전체를 보존하지는 않는다.

이번 설계는 ExternalProject의 작업 tree 자체를 pod 간에 옮기지 않는다. 대신 cubridci image build stage에서 소비에 필요한 header와 library만 정규화된 prefix로 만들고, 그 결과를 final image layer에 저장한다. Docker image layer가 CI node에 남아 있으면 Kubernetes pod는 같은 prefix를 다시 전송하거나 해제하지 않고 바로 사용한다.

dependency version이나 build option이 바뀌면 canonical manifest가 달라지고 cubridci image도 다시 만들어야 한다. 3rdparty 변경 빈도가 낮고 image build와 Docker Hub push가 Jenkins에 자동화되어 있으므로, 변경 감지와 재빌드를 명시적인 image build 단계에 두는 쪽을 선택한다.

## Specification Changes

### CUBRID source interface

| 항목 | 계약 |
|------|------|
| `3rdparty/manifest.json` | dependency URL, checksum, patch, build option, linkage처럼 소비 결과에 영향을 주는 입력을 canonical 형식으로 선언한다. |
| spec fingerprint | canonical manifest의 SHA-256을 source와 image가 공통으로 사용한다. CUBRID commit 자체는 fingerprint 입력이 아니다. |
| `cubrid_thirdparty_prefix` | `CUBRID_3RDPARTY_PREFIX_OUTPUT`에 재배치 가능한 expanded prefix를 생성하는 build target이다. |
| `CUBRID_3RDPARTY_MODE=CI_PREBUILT` | ExternalProject를 실행하지 않고 `CUBRID_3RDPARTY_ROOT`의 header와 library를 소비한다. |
| `CUBRID_3RDPARTY_MODE=EXTERNAL` 또는 mode 미설정 | 현재의 source build 동작을 유지한다. |

prefix는 최소한 다음 구조를 제공한다.

```text
/opt/cubrid-thirdparty/
  include/
  lib/
  licenses/
  share/cubrid-thirdparty/
    manifest.json
    provenance.json
```

`manifest.json`은 source와 image 사이의 dependency specification 일치 여부를 판단한다. `provenance.json`은 producer revision, toolchain, base image, architecture처럼 산출물의 출처를 기록하며 spec fingerprint와 분리한다.

### Failure behavior

| 조건 | 결과 |
|------|------|
| image가 prebuilt prefix를 제공하지 않음 | mode 미설정 또는 `EXTERNAL`은 기존 build를 계속한다. `CI_PREBUILT`를 명시했다면 build 시작 전에 실패한다. |
| prefix directory 또는 필수 파일 누락 | entrypoint 또는 CMake configure 단계에서 실패한다. source build로 fallback하지 않는다. |
| source/image manifest fingerprint 불일치 | configure 단계에서 expected/actual fingerprint, root, producer revision을 포함한 오류를 출력하고 실패한다. |
| image의 mode/root와 사용자가 지정한 값 충돌 | entrypoint에서 즉시 실패한다. |

## Implementation

```text
[cubridci image build]
  full CUBRID commit SHA
    -> exact source checkout
    -> canonical manifest 확인
    -> cubrid_thirdparty_prefix target 실행
    -> include/lib/licenses/manifest/provenance 검증
    -> /opt/cubrid-thirdparty만 final image에 COPY

[ordinary CI pod]
  entrypoint
    -> baked prefix와 metadata 검증
    -> CUBRID_3RDPARTY_MODE=CI_PREBUILT export
    -> CUBRID_3RDPARTY_ROOT=/opt/cubrid-thirdparty export
    -> 기존 ./build.sh ... clean build 실행
         -> CMake manifest fingerprint 비교
         -> ExternalProject 생략
         -> CUBRID compile/link
```

builder stage의 download, source, object와 ExternalProject stamp는 final image에 넣지 않는다. final image에는 consumer에게 필요한 prefix와 license/metadata만 남긴다.

POC는 `CUBRID_3RDPARTY_REVISION`을 지정하지 않은 기존 Jenkins image build를 그대로 허용한다. 이 경우 checkout이나 prefix 생성이 일어나지 않는다. 실제 기능을 활성화할 때는 CUBRID repository의 producer target과 consumer mode가 먼저 구현되어야 한다.

이 설계에서 3rdparty archive, zstd, 공유 archive directory, publisher 권한, restore/publish 동시성 처리는 필요하지 않다. 이 항목들은 ccache와 함께 본 이슈의 구현 범위에서 제외한다.

## Acceptance Criteria

- [ ] `CUBRID_3RDPARTY_REVISION`을 지정하지 않은 cubridci image가 현재와 같은 build 동작을 유지한다.
- [ ] image build가 full 40-character lowercase commit SHA만 producer revision으로 허용한다.
- [ ] final image로 전달되는 3rdparty 산출물은 `include/`, `lib/`, `licenses/`, `manifest.json`, `provenance.json`으로 제한되고, builder의 download/source/object/stamp는 포함되지 않는다.
- [ ] matching prefix를 사용하는 Release와 OptDebug CI build에서 3rdparty network access와 download/configure/compile/install 단계가 실행되지 않는다.
- [ ] prefix나 필수 파일이 없거나 fingerprint가 다르면 fallback 없이 실패하며, 오류에 expected/actual fingerprint, root, producer revision이 표시된다.
- [ ] mode 미설정 또는 `EXTERNAL`인 로컬 개발 build는 기존 ExternalProject 경로를 사용한다.
- [ ] 주요 실행 파일에 대해 `file`, `readelf -d`, `ldd` 결과를 비교했을 때 기존 static/shared dependency 구성이 유지된다. unixODBC는 shared linkage를 유지한다.
- [ ] 같은 CUBRID source revision으로 기존 방식과 `CI_PREBUILT` 방식의 clean build 시간 및 pod network 수신량을 측정해 결과를 기록한다.

## Definition of done

- [ ] 위 A/C를 충족한다.
- [ ] CUBRID와 cubridci 양쪽의 자동화 test와 CI가 통과한다.
- [ ] manifest schema, image 갱신 절차와 failure message를 운영 문서에 반영한다.
- [ ] CUBRIDQA-1613에 측정 결과, 적용 image tag와 rollout 결정을 기록한다.

## Remarks

- POC source commit: `8f1855ddab659eab7af149419a9992743751662c`
- POC pull request: [CUBRID/cubridci #125](https://github.com/CUBRID/cubridci/pull/125)
- 설계 결정 기록: [Use a CI-image prebuilt third-party prefix](https://github.com/CUBRID/cubridci/blob/prototype/build-rl810-thirdparty-archive/docs/adr/0001-use-ci-image-prebuilt-thirdparty-prefix.md)
