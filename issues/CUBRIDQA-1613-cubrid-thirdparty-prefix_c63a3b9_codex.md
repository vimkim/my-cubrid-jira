# [Improve] CI 이미지에 3rdparty prefix를 포함해 반복 빌드 제거

## Issue Triage

**이슈 수행 목적**: CUBRID 소스만 바뀐 CI build에서는 이미지에 포함된 검증 완료 3rdparty prefix를 재사용하고, pod에서는 CUBRID 소스의 compile과 link만 수행하도록 한다. 기존 CUBRID 산출물과 dependency linkage는 유지한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | `build_rl8.10` entrypoint가 `./build.sh ... clean build`를 실행하면 `${CMAKE_BINARY_DIR}/3rdparty` 아래의 download, source, object, install 결과와 ExternalProject stamp가 모두 사라진다. 엔진 소스만 변경돼도 8개 dependency의 download/configure/compile/install이 반복된다. |
| **TO-BE (목표 상태 / 기대 동작)** | cubridci image build가 고정 CUBRID revision으로 relocatable prefix를 한 번 만들고, 일반 CI pod는 canonical manifest와 prefix를 검증한 뒤 ExternalProject 없이 같은 prefix를 Release와 OptDebug build에 사용한다. |
| **영향** | 성능 저하 - 수명이 짧은 pod마다 3rdparty network 수신과 build 시간이 누적된다. `ccache`는 compiler object만 재사용하므로 download, configure, install과 완성 library 재생성을 없애지 못한다. |

**이슈 수행 방안**:

| 항목 | 확정 계약 |
|------|-----------|
| source identity | CUBRID가 canonical `3rdparty/manifest.json`을 소유하고 그 파일 byte의 SHA-256을 source/image specification fingerprint로 사용한다. |
| producer | `cubrid_thirdparty_prefix` target이 `CUBRID_3RDPARTY_PREFIX_OUTPUT`에 expanded prefix를 생성한다. |
| consumer | `CUBRID_3RDPARTY_MODE=CI_PREBUILT`가 `CUBRID_3RDPARTY_ROOT`를 검증하고 ExternalProject를 만들지 않는다. mode 미설정 또는 `EXTERNAL`은 기존 경로를 유지한다. |
| compatibility | Release와 OptDebug가 같은 prefix를 사용한다. expat, libedit, LZ4, OpenSSL, RE2, oneTBB는 기존 static linkage를 유지하고 unixODBC는 shared linkage를 유지한다. |
| failure | 명시적 `CI_PREBUILT`에서 root, metadata, artifact 또는 fingerprint가 잘못되면 fallback 없이 configure 단계에서 실패한다. |
| first scope | `build_rl8.10`, Linux x86_64만 대상으로 한다. image tag, rollout 순서와 배포 책임은 `TBD - 구현 및 측정 완료 후 결정`으로 둔다. |

---

## AI-Generated Context

> 아래는 AI가 코드와 작업 맥락을 분석해 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현과 리뷰 단계에서 참고하면 된다.

### 요약

- **변경 범위 / 영향**: CUBRID의 `3rdparty/manifest.json`, `3rdparty/CMakeLists.txt`, 신규 CMake contract/producer module과 standalone contract test가 중심이다. 후속으로 cubridci PR #125의 Dockerfile/entrypoint를 이 계약에 연결한다.
- **호환성 경계**: 기본 developer build, CUBRID package 형식, dependency link 순서와 static/shared 구성을 바꾸지 않는다. Windows와 system-library 조합은 v1 범위 밖이다.
- **분석 기준**: CUBRID `c63a3b993be552ef6ad3ce244c386d5081147958`, cubridci POC `8f1855ddab659eab7af149419a9992743751662c`를 기준으로 한다.

## Description

CUBRID의 Linux 3rdparty graph는 `${CMAKE_BINARY_DIR}/3rdparty`를 ExternalProject base로 사용한다. 이 directory에는 archive download, 압축 해제 source, build object, install 결과와 각 단계의 완료 stamp가 함께 놓인다. `build.sh clean`은 선택한 build directory 전체를 비우므로 다음 configure가 이전 완료 상태를 확인할 수 없다.

현재 graph가 만드는 소비 대상은 8개다.

| dependency | 현재 소비 형태 |
|------------|----------------|
| expat | `libexpat.a`, installed header |
| CUBRID libedit | `libedit.a`, installed header |
| LZ4 | `Source/lz4/lib/liblz4.a`, source-tree header |
| OpenSSL | `libssl.a`, `libcrypto.a`, installed header |
| unixODBC | `libodbc.so` shared library와 installed header |
| RapidJSON | `Source/rapidjson/include`의 header-only tree |
| RE2 | `Source/re2/obj/libre2.a`, source-tree header |
| oneTBB | `libtbb.a`, source-tree TBB/oneAPI header |

LZ4, RapidJSON, RE2와 oneTBB의 일부 consumer path는 ExternalProject `Source/` tree를 가리킨다. 따라서 현재 build tree를 그대로 복사하지 않고, producer가 필요한 header와 library를 `include/`와 `lib/` 아래로 정규화해야 한다.

unixODBC는 다른 dependency와 다르다. 현재 build에서 `libodbc.so`와 `libodbc.so.2`는 versioned payload인 `libodbc.so.2.0.0`을 가리키며 payload SONAME은 `libodbc.so.2`다. `cub_cas_cgw`도 `DT_NEEDED libodbc.so.2`를 가진다. 이 symlink chain과 SONAME은 cache 구현 세부가 아니라 보존해야 하는 linkage 계약이다.

관련 source:

- [3rdparty graph와 recipe](https://github.com/CUBRID/cubrid/blob/c63a3b993be552ef6ad3ce244c386d5081147958/3rdparty/CMakeLists.txt)
- [common library linkage](https://github.com/CUBRID/cubrid/blob/c63a3b993be552ef6ad3ce244c386d5081147958/cubrid/CMakeLists.txt#L731-L750)
- [unixODBC consumer](https://github.com/CUBRID/cubrid/blob/c63a3b993be552ef6ad3ce244c386d5081147958/broker/CMakeLists.txt#L293-L302)
- [cubridci interface POC](https://github.com/CUBRID/cubridci/commit/8f1855ddab659eab7af149419a9992743751662c)

## Specification Changes

### Canonical manifest 계약

`3rdparty/manifest.json`은 v1 dependency specification의 단일 authority다. CMake recipe에 같은 URL, checksum과 option을 별도로 유지해 drift가 생기지 않도록 manifest 값을 실제 recipe가 읽어야 한다. 단계적 전환이 필요하면 configure 시 manifest와 기존 변수의 equality를 먼저 강제한다.

최상위 schema는 닫힌 형태로 두며 unknown key, missing field, 중복 dependency 이름과 지원하지 않는 recipe/linkage 값을 거부한다.

```json
{
  "dependencies": [
    {
      "build": {
        "build_arguments": [],
        "configure_arguments": [],
        "environment": {},
        "install_arguments": [],
        "recipe": "autoconf"
      },
      "licenses": [
        {
          "destination": "licenses/example_license.txt",
          "sha256": "64-lowercase-hex-digits",
          "source": "3rdparty/license/example_license.txt"
        }
      ],
      "name": "example",
      "outputs": {
        "headers": ["include/example.h"],
        "libraries": [
          {
            "link_name": "lib/libexample.a",
            "linkage": "static",
            "soname": null
          }
        ]
      },
      "patches": [],
      "source": {
        "sha256": "64-lowercase-hex-digits",
        "url": "https://example.invalid/source.tar.gz"
      }
    }
  ],
  "platform": {
    "architecture": "x86_64",
    "os": "linux",
    "variant": "build_rl8.10-default"
  },
  "recipe_revision": 1,
  "schema": "cubrid-thirdparty-manifest-v1"
}
```

manifest는 다음 specification input을 포함한다.

- dependency 순서, 이름, source URL과 SHA-256
- patch path, SHA-256과 적용 argument. 현재 patch가 없어도 `patches: []`를 필수로 둔다.
- configure/build/install recipe, semantic argument, 고정 environment와 compile/link flag
- 정규화된 header/library path, linkage kind와 shared-library SONAME/link name
- platform profile과 prefix에 포함할 license source/destination/SHA-256 mapping

producer commit, compiler/CMake/generator, base image, package version, build timestamp, output file digest와 image digest는 특정 build의 관측값이므로 fingerprint에서 제외하고 provenance에 기록한다. timeout, log option과 parallel job 수는 artifact specification을 바꾸지 않으므로 양쪽에서 제외한다.

### Canonical serialization과 fingerprint

runtime JSON canonicalizer를 추가하지 않는다. source-controlled manifest 자체를 canonical byte stream으로 삼고 producer가 byte-for-byte 복사한다.

| 규칙 | 값 |
|------|----|
| encoding | UTF-8, BOM 없음 |
| line ending | LF |
| indentation | space 2개 |
| object key | 모든 level에서 Unicode code-point 오름차순 |
| array order | dependency는 graph 선언 순서, set 성격의 string array는 오름차순 |
| scalar | string을 기본으로 하고 `recipe_revision`만 integer 허용, float 금지 |
| EOF | 마지막 LF 정확히 1개 |

fingerprint는 마지막 LF를 포함한 manifest 전체 byte의 lowercase SHA-256이다. CMake는 source manifest와 prefix manifest를 각각 직접 hash한다. `provenance.json`의 `spec_fingerprint`는 진단용 중복 값이며 compatibility 판단은 실제 prefix manifest hash로 수행한다.

### Prefix layout과 검증

```text
<CUBRID_3RDPARTY_PREFIX_OUTPUT>/
  include/
    editline/  openssl/  rapidjson/  re2/  tbb/  oneapi/  ...
  lib/
    libexpat.a  libedit.a  liblz4.a  libssl.a  libcrypto.a
    libodbc.so -> libodbc.so.<full-version>
    libodbc.so.<SONAME-major> -> libodbc.so.<full-version>
    libodbc.so.<full-version>
    libre2.a  libtbb.a
  licenses/
    <manifest가 선언한 license files>
  share/cubrid-thirdparty/
    manifest.json
    provenance.json
```

shared-library full filename은 upstream patch version에 따라 달라질 수 있으므로 고정 이름 하나만 검사하지 않는다. unixODBC manifest는 `link_name: "lib/libodbc.so"`, `linkage: "shared"`, `soname: "libodbc.so.2"`를 선언한다. 모든 symlink hop은 relative path이고 `<root>/lib` 안에 머물며 non-empty regular payload로 끝나야 한다. payload ELF SONAME도 manifest 값과 같아야 한다.

`libodbcinst`와 `libodbccr`는 upstream install 결과에 존재하더라도 현재 CUBRID graph가 소비하지 않으므로 v1 prefix에 넣지 않는다.

### Provenance 기록

`share/cubrid-thirdparty/provenance.json`은 다음 값을 기록한다.

- schema와 spec fingerprint
- full 40-character producer CUBRID commit과 source dirty 여부
- production timestamp
- manifest에 선언한 platform/variant와 실제 OS/architecture
- compiler ID, path, version, target
- CMake version과 generator
- 제공된 경우 base-image reference/digest와 cubridci image reference/digest, 미제공 optional 값은 `null`
- regular artifact SHA-256와 symlink target inventory

provenance 변경은 specification fingerprint를 바꾸지 않는다.

### Consumer mode 동작

| mode | 동작 |
|------|------|
| 미설정 | 기존 ExternalProject path |
| `EXTERNAL` | 기존 ExternalProject path |
| `CI_PREBUILT` | root와 contract를 모두 검증한 뒤 prefix path만 export |
| 그 외 | configure 실패 |

`CI_PREBUILT`는 ExternalProject를 선언하기 전에 다음 순서로 검증한다.

CMake cache variable과 같은 이름의 environment variable을 모두 interface로 허용한다. 둘 다 설정된 경우 값이
같아야 하며, 다르면 configure에서 실패한다. mode 미설정은 `EXTERNAL`과 같지만 root만 설정된 상태는 잘못된
부분 설정으로 거부한다. 이 규칙으로 cubridci entrypoint의 environment export와 직접 `-D` 실행을 같은 계약으로
묶는다.

1. `CUBRID_3RDPARTY_ROOT`가 설정된 absolute directory인지 확인한다.
2. source/prefix manifest가 non-empty regular file인지 확인하고 raw SHA-256을 비교한다.
3. provenance schema, producer revision, recorded spec fingerprint와 platform observation을 검증한다.
4. manifest가 선언한 header, library와 license가 root 안에 존재하며 resolved path가 root 밖으로 나가지 않는지 확인한다.
5. static library는 non-empty regular file인지, shared library는 relative/in-root/non-dangling symlink chain과 SONAME을 만족하는지 확인한다.
6. 기존 `*_INCLUDES`, `*_LIBS`, `EP_INCLUDES`, `EP_LIBS`와 TBB-specific 변수를 prefix path로 설정하고 `EP_TARGETS`, `TBB_TARGETS`는 empty로 둔다.

검증이 끝나기 전에 `include(ExternalProject)`나 dependency target 생성을 실행하지 않는다. 실패 후 source build fallback도 허용하지 않는다.

### Failure diagnostic 형식

모든 `CI_PREBUILT` configure failure는 같은 형식으로 아래 값을 출력한다.

```text
mode=<CI_PREBUILT>
root=<resolved or supplied root>
source_manifest=<path>
prefix_manifest=<path>
expected_fingerprint=<sha256 or unavailable>
actual_fingerprint=<sha256, missing, or unreadable>
producer_revision=<40-char SHA or unknown>
failed_check=<precise check and artifact>
```

## Implementation

### Producer 호출 흐름

```text
[CUBRID exact revision]
  -> manifest parse/canonical-format validation
  -> 8 ExternalProject dependency targets
  -> cubrid_thirdparty_prefix
       -> declared output만 temporary sibling에 정규화
       -> license + exact manifest + provenance 생성
       -> artifact/path/symlink/SONAME/fingerprint 검증
       -> complete stage를 output path로 publish
```

`CUBRID_3RDPARTY_PREFIX_OUTPUT`은 producer target에 필수이며 absolute path여야 한다. filesystem root, source root, binary root 또는 그 ancestor는 거부한다. target은 8개 dependency target 모두에 의존하고, 실패한 stage를 consumable output처럼 남기지 않는다.

final prefix에는 `include`, `lib`, `licenses`, `share/cubrid-thirdparty`만 허용한다. ExternalProject의 `Download`, `Source`, `Build`, `Stamp`, object와 build tool은 포함하지 않는다.

### Consumer 호출 흐름

```text
[ordinary CI pod]
  entrypoint exports CI_PREBUILT + /opt/cubrid-thirdparty
    -> build.sh clean build
       -> CMake validates source manifest against prefix
          -> EP_TARGETS/TBB_TARGETS = empty
          -> existing include/library variables point into prefix
          -> CUBRID compile/link only
```

현재 consumer가 plain variable과 `${EP_TARGETS}` dependency를 사용하므로 v1은 변수 이름과 library order를 유지한다. imported target 전환은 이 이슈의 필수 조건이 아니다.

## Behavioral Test Seam

확정한 최고 behavioral seam은 root project와 분리된 `3rdparty/tests` CMake/CTest black-box suite다. 이 suite는 production contract module을 직접 include하며 CUBRID engine, JDK, submodule, 실제 dependency download와 Catch2를 요구하지 않는다.

fixture는 deterministic local file로 static library 1개, header-only dependency 1개, versioned shared payload와 relative linker/SONAME symlink chain 1개를 만든다. ExternalProject route에는 marker/failure sentinel을 둔다. 기본/`EXTERNAL` case는 marker 생성을 요구하고, 모든 `CI_PREBUILT` case는 sentinel에 닿으면 실패하도록 한다.

| phase | 검증 동작 |
|-------|-----------|
| producer | 실제 target 이름 `cubrid_thirdparty_prefix`를 build해 선언된 normalized tree만 생성하고 manifest/provenance/symlink를 검증한다. |
| relocation | 생성 prefix를 다른 absolute path로 옮긴다. file content와 symlink에 producer source/build/output path가 남지 않아야 한다. |
| consumer success | nested configure/build가 relocated prefix의 header/static/shared fixture를 compile/link하고 `EP_TARGETS`가 empty이며 sentinel marker가 없음을 확인한다. |
| compatibility | mode 미설정과 `EXTERNAL`이 기존 route를 선택해 marker를 남기는지 확인한다. |
| incomplete prefix | root, manifest, provenance, 각 header/library/license 누락, empty artifact, dangling/absolute/escaping symlink가 configure에서 실패하는지 확인한다. |
| schema/fingerprint | byte mutation, 다른 valid canonical manifest, malformed JSON, unsupported schema와 provenance fingerprint 불일치가 실패하는지 확인한다. |
| fail-closed | 모든 negative `CI_PREBUILT` case에서 sentinel이 untouched이고 diagnostic에 expected/actual/root/manifests/producer/check가 포함되는지 확인한다. |

검증 명령은 repository public tool만 사용한다.

```sh
cmake -S 3rdparty/tests -B build-thirdparty-contract -G Ninja
ctest --test-dir build-thirdparty-contract --output-on-failure
```

CTest `WILL_FAIL`만 사용하지 않고 driver가 subprocess exit code와 안정된 diagnostic fragment를 함께 검사한다. full Release/OptDebug build는 이 suite를 대체하지 않으며 실제 recipe, ABI와 linkage를 검증하는 느린 acceptance gate로 둔다.

## Acceptance Criteria

- [ ] canonical-format 검사와 closed-schema 검사가 `3rdparty/manifest.json`의 drift를 차단한다.
- [ ] `cubrid_thirdparty_prefix`가 manifest가 선언한 header, library, license와 metadata만 output에 생성하며 build working state를 남기지 않는다.
- [ ] 생성 prefix를 다른 absolute path로 옮긴 뒤에도 standalone consumer success case가 통과한다.
- [ ] matching prefix를 쓰는 clean Release와 OptDebug build에서 3rdparty download/configure/compile/install과 network access가 발생하지 않는다.
- [ ] mode 미설정 또는 `EXTERNAL` build는 기존 ExternalProject path를 사용한다.
- [ ] root, metadata, artifact 또는 fingerprint가 잘못된 명시적 `CI_PREBUILT` configure는 fallback 없이 실패하고 합의된 diagnostic field를 출력한다.
- [ ] unixODBC relative symlink chain과 `libodbc.so.2` SONAME/`DT_NEEDED`를 보존한다.
- [ ] `file`, `readelf -d`, `ldd` 비교에서 `cub_server`, `csql`, `libcubrid`, `libcubridsa`, `libcubridcs`, `cub_cas`, `cub_cas_cgw`의 기존 static/shared linkage가 유지된다.
- [ ] cubridci image에 `include`, `lib`, `licenses`, canonical manifest와 provenance만 남고 download/source/object/stamp는 남지 않는다.
- [ ] 같은 CUBRID revision의 기존 방식과 `CI_PREBUILT` 방식에 대해 clean-build elapsed time과 pod network receive byte를 기록한다.
- [ ] standalone contract suite와 CUBRID/cubridci 자동화 검증이 통과한다.

## Definition of done

- [ ] 위 Acceptance Criteria를 모두 충족한다.
- [ ] CUBRID producer/consumer 계약이 merge된 exact revision으로 cubridci PR #125를 갱신하고 실제 prefix image build를 통과한다.
- [ ] manifest schema, prefix 갱신 절차, failure message와 linkage 검증 절차를 운영 문서에 반영한다.
- [ ] 측정 결과와 production image tag, rollout 순서, 배포 책임을 CUBRIDQA-1613에 기록한다.

## Remarks

- cubridci draft PR: https://github.com/CUBRID/cubridci/pull/125
- interface POC commit: `8f1855ddab659eab7af149419a9992743751662c`
- accepted ADR: https://github.com/CUBRID/cubridci/blob/8f1855ddab659eab7af149419a9992743751662c/docs/adr/0001-use-ci-image-prebuilt-thirdparty-prefix.md
- CUBRID source snapshot: `c63a3b993be552ef6ad3ce244c386d5081147958`
- 기존 shared archive, tar/zstd, restore/publisher, ccache 기반 3rdparty reuse 설계는 범위에서 제외한다.
