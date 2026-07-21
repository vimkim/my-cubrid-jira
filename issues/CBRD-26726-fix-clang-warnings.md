# [BUILD] Clang 빌드 경고 전수 정리와 단계별 리팩터링

## Issue Triage

**이슈 수행 목적**: Clang debug 빌드에서 확인되는 경고를 원인과 변경 위험도에 따라 하위 이슈로 분리하고, 최종적으로 경고가 없는 빌드를 만든다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | Clang 19.1.7 clean build 는 보이는 경고 메시지 496건을 출력한다. 실제 compile command에는 `-Wno-unknown-warning-option` 등 suppression이 들어 있어 496건은 무억제 전체 수치가 아니다. 보이는 경고 안에도 `delete`/`new[]` 불일치, `va_start`의 잘못된 마지막 인자, 항상 참인 비트 조건식처럼 실제 오동작 또는 UB(Undefined Behavior - 언어 표준이 결과를 보장하지 않는 동작) 후보가 섞여 있다. |
| **TO-BE (목표 상태 / 기대 동작)** | 공개 build 절차에서 warning policy를 먼저 고정하고 모든 경고를 담당 하위 이슈와 검증 항목에 연결한다. CUBRID가 직접 유지하는 first-party 코드는 원인을 수정하며, 생성 코드와 외부 코드는 원본·생성기·의존성을 우선 수정해 전체 빌드 출력도 0건으로 만든다. |
| **영향** | 기술 부채 - 반복 출력되는 저위험 경고 때문에 `-Wvarargs`, `-Wtautological-bitwise-compare` 같은 결함 신호가 묻히며, 새 경고가 추가되어도 build log 차이만으로 발견하기 어렵다. |

**이슈 수행 방안**: warning policy 정규화를 선행한 뒤 12개 하위 이슈로 나누어 쉬운 변경부터 처리하는 방안을 권장한다. 전역 `-Wno-*` 추가는 사용하지 않고, 외부 코드의 target 단위 격리 허용 여부와 하위 이슈 번호는 `TBD - 합의 미확인` 으로 남긴다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: first-party 55개 파일이 `base`, `broker`, `CCI`, `object`, `optimizer`, `parser`, `query`, `storage`, `transaction` 등 17개 모듈에 걸쳐 있다. Build warning flag, Flex/Bison 생성 경로와 RapidJSON·dlmalloc·`mprec.c` 도 별도 범위로 포함한다. 공개 API와 디스크 포맷 변경은 의도하지 않지만 CCI/CAS 프로토콜 타입, optimizer 가변 인자 함수, 숫자 경계 판정에는 호환성 검증이 필요하다.

---

## Description

기존 문서는 한 작업에서 일부 경고를 바로 고친 결과를 기록한 완료 보고서에 가깝다. 1,590건이라는 수치도 GCC 전용 옵션으로 생긴 `-Wunknown-warning-option` 을 포함한 과거 환경의 값이라 현재 build log를 설명하지 못한다. 해당 옵션 문제는 CBRD-26725 범위이며 이번 조사에서는 다시 세지 않는다.

현재 `build_preset_debug_clang/build.log` 는 2026-07-21에 clean build 1,352개 단계를 수행한 로그다. 같은 소스가 `SERVER_MODE`, `SA_MODE`, `CS_MODE` 등 여러 target에 들어가므로 하나의 소스 위치가 여러 번 출력된다. 따라서 이 문서는 다음 두 수치를 구분한다.

- `출력 건수`: build log에 실제로 나타난 diagnostic 횟수다. 빌드 잡음의 크기를 나타낸다.
- `고유 위치`: `파일:행:열 + 경고 종류 + 메시지` 가 같은 항목을 한 번만 센 값이다. 수정 지점의 규모를 나타낸다.

이 build directory의 `compile_commands.json`에는 `-Wno-c++11-narrowing`, `-Wno-cast-qual`, `-Wno-implicit-function-declaration`, `-Wno-inline-new-delete`, `-Wno-int-conversion`, `-Wno-non-pod-varargs`, `-Wno-unknown-pragmas`, `-Wno-unknown-warning-option`, `-Wno-unused`, `-Wno-unused-parameter`, `-Wno-unused-result`가 나타난다. 일부는 프로젝트 기본 flag이고 일부는 개인 `CMakeUserPresets.json`의 `debug_clang` 설정이다. 특히 `-Wno-unknown-warning-option` 때문에 현재 로그에서 해당 경고가 0건인 사실만으로 CBRD-26725가 해결됐다고 판단할 수 없다. 먼저 공개 build 명령의 유효 warning policy와 기준 로그를 확정해야 한다.

현재 작업트리에는 화폐 literal의 parser enum을 DB enum으로 잘못 받던 경계를 정리하는 변경이 있다. 나머지 계획과 섞지 않고 S1로 따로 마감한다.

나머지 경고는 단순 문법 정리만으로 끝나지 않는다. 예를 들어 `OR_CHECK_BIGINT_OVERFLOW()` 가 `DB_BIGINT_MAX` 를 `double` 또는 `float` 와 비교하면 상수가 정확히 표현되지 않아 경계가 한 단계 바뀔 수 있다. `PT_SPEC_FLAG_*` 검사에서 `|`를 사용한 네 위치는 플래그가 0이 아니기만 하면 조건 전체가 항상 참이므로 `&` 가 의도였는지 실행 경로별 확인이 필요하다. 이 차이 때문에 건수만 큰 묶음보다 의미와 검증 범위가 같은 묶음으로 나눈다.

## Specification Changes

N/A. 사용자 SQL 동작, 공개 API, 네트워크 프로토콜, 디스크 포맷의 변경을 의도하지 않는다. 경고 수정 과정에서 기존 조건식이 실제 결함으로 확인되면 해당 하위 이슈에 AS-IS/TO-BE와 회귀 테스트를 별도로 명시한다.

## Implementation

### 조사 기준

| 항목 | 값 |
|------|----|
| 소스 기준 | `3aac1a6bb` + 현재 작업트리의 `src/parser/csql_grammar.y` 변경 |
| 도구 | Clang 19.1.7, Flex, Bison |
| 조사 로그 | `build_preset_debug_clang/build.log` (2026-07-21 00:31 KST) |
| Clang diagnostic | 출력 490건, 고유 위치 178개 |
| first-party | 출력 311건, 고유 위치 149개 |
| 생성 C 소스 | 출력 8건, 고유 위치 4개 |
| 외부·bundled 코드 | 출력 171건, 고유 위치 25개 |
| 생성기 자체 메시지 | Flex 4건, Bison 2건 |
| 유효 suppression | 목록·출처·유지 필요성은 S0에서 audit |

조사 결과를 다시 만들 때는 개인 preset 대신 프로젝트의 공개 build script를 사용한다.

```bash
./build.sh -m debug -C clang -b build_clang_warning_audit build \
  2>&1 | tee clang-debug-build.log
```

### 전체 경고 목록

현재 로그의 모든 경고를 하위 이슈에 빠짐없이 연결했다. `고유 위치` 의 `-`는 컴파일러 source diagnostic이 아니라 생성기 요약 메시지라는 뜻이다.

| 경고 | 출력 건수 | 고유 위치 | 소유 | 권장 하위 이슈 |
|------|----------:|----------:|------|----------------|
| `-Wmismatched-new-delete` | 2 | 1 | first-party | S2 |
| `-Wformat` | 3 | 3 | first-party | S2 |
| `-Wstring-concatenation` | 1 | 1 | first-party | S2 |
| `-Wparentheses-equality` | 8 | 4 | first-party | S2 |
| `-Wself-assign` | 6 | 3 | first-party | S2 |
| `-Wpessimizing-move` | 21 | 10 | first-party | S2 |
| `-Woverloaded-virtual` | 12 | 1 | first-party | S2 |
| `-Wdeprecated-copy-with-user-provided-copy` | 2 | 1 | first-party | S2 |
| `-Wmismatched-tags` | 1 | 1 | first-party | S2 |
| `-Winstantiation-after-specialization` | 1 | 1 | first-party | S2 |
| `-Wunused-parameter` | 4 | 4 | first-party | S2 |
| `-Wpointer-bool-conversion` | 14 | 3 | first-party | S3 |
| `-Wtautological-pointer-compare` | 12 | 9 | first-party | S3 |
| `-Wmissing-field-initializers` | 45 | 25 | first-party | S4 |
| `-Wmissing-braces` | 11 | 3 | first-party | S4 |
| `-Wimplicit-const-int-float-conversion` | 42 | 16 | first-party | S5 |
| `-Wsign-compare` | 23 | 11 | first-party | S5 |
| `-Wconstant-conversion` | 2 | 2 | first-party | S6 |
| `-Wtautological-constant-out-of-range-compare` | 23 | 22 | first-party | S6 |
| `-Wtautological-bitwise-compare` | 8 | 4 | first-party | S8 |
| `-Wvarargs` | 4 | 2 | first-party | S9 |
| `-Wvla-cxx-extension` | 66 | 22 | first-party | S10 |
| `-Wdeprecated-declarations` | 48 | 4 | RapidJSON | S7 |
| `-Wgnu-null-pointer-arithmetic` | 120 | 20 | dlmalloc 2.8.3 | S7 |
| `-Wlogical-not-parentheses` | 3 | 1 | `mprec.c` | S7 |
| `-Wunused-parameter` | 6 | 3 | 생성 C 소스 | S11 |
| `-Wsometimes-uninitialized` | 2 | 1 | 생성 C 소스 | S11 |
| Flex 도달 불가 rule·default rule | 4 | - | `load_lexer.l` | S11 |
| `-Wconflicts-sr` | 1 | - | 생성 CSQL grammar, 796개 shift/reduce conflict 요약 | S11 |
| `-Wconflicts-rr` | 1 | - | 생성 CSQL grammar, 1,457개 reduce/reduce conflict 요약 | S11 |

> **요지**: 생성기와 외부 코드도 명시적인 처리 정책이 필요하며, 현재 숨겨진 warning class는 공개 build 기준으로 다시 조사해야 한다.

### 권장 하위 이슈 상세

순서는 구현 난이도와 회귀 위험을 함께 반영한다. 번호는 계획용 식별자이며 실제 CBRD 번호는 발급 후 교체한다.

| 순서 | 난이도 | 하위 이슈 | 현재 출력 | 구현 방향 | 필수 검증 |
|------|--------|-----------|----------:|-----------|-----------|
| S0 | 쉬움-보통 | Clang warning policy와 공개 build baseline 확정 | 현재 로그 밖 | 개인 preset을 배제한 `./build.sh -m debug -C clang` compile command를 기준으로 suppression의 출처와 필요성을 audit한다. CBRD-26725가 맡은 compiler option 문제를 반영한 뒤 전체 경고 목록을 한 번 갱신한다. | 활성 compile flag 목록, 공개 clean build log, CBRD-26725 결과 |
| S1 | 쉬움 | Parser 화폐 enum 경계 정리 | 0 | `pt_value_set_monetary()` 와 `PT_VALUE` 저장 타입을 `PT_CURRENCY` 로 통일한다. DB 값으로 바꾸는 기존 `pt_currency_to_db()` 경계는 유지한다. | 모든 화폐 기호의 literal parse와 `-Wenum-conversion` 0건 |
| S2 | 쉬움 | 언어 규칙·수명·형식 경고 정리 | 61 | `delete[]`, 정확한 format specifier, 불필요한 self assignment·`std::move` 제거, base overload 노출, copy/tag/template 선언 순서를 각각 원인에 맞게 고친다. | Clang/GCC debug build와 변경 모듈 unit test |
| S3 | 쉬움-보통 | 고정 배열의 NULL·빈 문자열 의미 분리 | 26 | `char[N]` 자체의 NULL 검사를 없앤다. 호출 의도가 문자열 존재 여부라면 `array[0] != '\0'`, 객체 존재 여부라면 상위 포인터를 검사한다. | broker·CCI·utility의 빈 문자열과 정상 문자열 경로 |
| S4 | 보통 | aggregate 초기화 계약 정리 | 56 | 누락된 `has_dblink`, `classoids`, `end_lsa` 등을 위치별로 덧붙이는 데 그치지 않고 공통 initializer 또는 명시적 초기화 함수가 가능한 타입은 한곳으로 모은다. C++17에서 비표준 designated initializer를 새로 도입하지 않는다. | parser DBLINK, flashback, network interface, migration 경로 |
| S5 | 보통 | 정수·실수 경계와 signedness 정리 | 65 | `INT32_MAX`, `DB_BIGINT_MAX` 가 float/double로 반올림되는 비교를 입력 타입별로 다시 정의한다. signed/unsigned 비교는 값 범위를 증명한 뒤 공통 타입으로 맞춘다. 단순 cast로 음수를 숨기지 않는다. | 경계값 바로 아래·같음·바로 위, 음수, 최대 page/file 길이 |
| S6 | 보통-어려움 | CCI/CAS protocol 값의 표현 타입 정리 | 25 | `T_CCI_CUBRID_STMT`, `T_CAS_PROTOCOL`, wire byte의 유효 범위와 sentinel(`-1`, `0x7e`, `0x7f`)을 구분한다. 비교식을 지우기 전에 wire decoding 타입과 public typedef 호환성을 확정한다. | 구·신 protocol handshake, statement type 0x7e/0x7f, cancel request byte |
| S7 | 보통-어려움 | 외부 코드 경고 경계 정리 | 171 | RapidJSON은 호환 버전 갱신을 우선 검토한다. dlmalloc과 `mprec.c` 는 upstream 수정 가능성을 확인하고, 수정하지 않는다면 해당 target/source에만 경고 정책을 제한한다. | Linux Clang/GCC build, packaging, external library smoke test |
| S8 | 어려움 | 항상 참인 비트 조건식 복원 | 8 | `virtual_object.c` 와 `xasl_generation.c` 의 `flags | MASK` 조건 네 곳을 호출 흐름별로 조사한다. `&`로 바꾸거나 조건을 제거할지는 MVCC reevaluation과 VID updatable 의미를 확인한 뒤 결정한다. | vclass 갱신 가능 여부, UPDATE/DELETE reevaluation, subquery·derived table |
| S9 | 어려움 | Optimizer varargs ABI 제거 | 4 | `QO_PARAM` enum이 default argument promotion되는 상태에서 `va_start(args, param)` 을 호출하는 UB를 없앤다. 권장안은 level/cost용 typed 함수로 분리하고 기존 wrapper의 호환 범위를 최소화하는 것이다. | optimization level get/set, cost function 선택, client/SA build |
| S10 | 어려움 | C++17 VLA 제거 | 66 | `numeric_opfunc.c` 의 21개 배열은 numeric precision에서 상한을 증명해 고정 크기 buffer 재사용을 우선 검토한다. `tcp.c` hostname buffer는 입력 길이 VLA 없이 동작하도록 별도 처리한다. 엔진 C 코드에 `std::vector` 를 일괄 도입하지 않는다. | NUMERIC 사칙연산·비교 최대 precision, hostname 길이 경계, stack 사용량 |
| S11 | 매우 어려움 | Flex/Bison 및 생성 C 경고 정리 | 14 | `csql_lexer.l` 에서 `c` 초기화와 unused parameter를 원본에서 고치고, `load_lexer.l` 의 도달 불가 rule을 정리한다. CSQL grammar의 796개 shift/reduce 및 1,457개 reduce/reduce conflict는 state별로 audit하며, 검토 없이 `%expect` 로 숨기지 않는다. | lexer token 회귀, loaddb 입력, parser conflict diff, SQL regression suite |

### 의존 관계

```text
S0 warning policy와 공개 build baseline
  |
  +--> S1-S4 낮은 위험의 source 정리
         |
         +--> S5 숫자 경계 -----------+
         +--> S6 protocol 표현 --------+--> first-party warning 0건
         +--> S8 비트 조건식 ----------+
         +--> S9 optimizer varargs -----+
         +--> S10 VLA -----------------+

S7 외부 코드 정책 ------------------> 전체 build warning 0건
S11 생성기·grammar ------------------>
```

S0이 기준 로그와 warning policy를 고정한 뒤 S1-S4는 서로 독립적으로 진행할 수 있다. S5-S10도 코드 의존성은 작지만 동작 회귀 가능성이 높아 각 하위 이슈에서 테스트를 먼저 확정한다. S7과 S11은 first-party 수정과 병렬로 진행하되, parent 완료 조건인 전체 출력 0건의 마지막 gate가 된다.

### 수정 원칙

1. first-party 경고는 compiler option으로 숨기지 않고 타입·조건·수명 문제를 소스에서 고친다.
2. 동일 source 위치가 여러 build mode에서 반복되면 한 원인 수정으로 묶되 `SERVER_MODE`, `SA_MODE`, `CS_MODE` 를 모두 다시 빌드한다.
3. 생성 파일을 직접 고치지 않는다. `csql_lexer.l`, `csql_grammar.y`, `load_lexer.l` 같은 원본 또는 생성 명령을 수정한다.
4. bundled third-party는 CUBRID 로직과 분리한다. 전역 suppression은 금지하며 source/target 단위 정책에는 upstream 링크와 제거 조건을 남긴다.
5. 위험 경고는 warning 수 감소만으로 완료하지 않는다. 해당 조건이 참·거짓인 최소 회귀 테스트를 함께 추가한다.

## Acceptance Criteria

- [ ] S0-S11 하위 이슈를 생성하고 현재 경고 종류를 하나 이상 담당 이슈에 연결한다.
- [ ] 개인 `CMakeUserPresets.json` 에 의존하지 않는 공개 Clang debug build에서 suppression 목록과 기준 로그를 확정한다.
- [ ] 현재 작업트리의 `-Wenum-conversion` 수정이 parser 화폐 literal 테스트와 함께 별도 하위 이슈로 마감된다.
- [ ] `./build.sh -m debug -C clang ... build` clean build에서 first-party Clang diagnostic이 0건이다.
- [ ] 생성 C, Flex/Bison, bundled third-party를 포함한 전체 build warning 출력이 0건이다. 단, target 단위 격리 허용 여부는 합의 후 확정한다.
- [ ] 전역 `-Wno-*` option을 추가하지 않는다.
- [ ] 생성된 `.c`/`.cpp` 파일을 직접 수정하지 않는다.
- [ ] GCC debug build가 성공해 Clang 전용 수정으로 기존 compiler 경로가 깨지지 않는다.
- [ ] S5, S6, S8, S9, S10은 표에 적은 경계·protocol·실행 경로 회귀 테스트를 포함한다.
- [ ] parent 완료 시 새 clean-build log와 경고 집계표를 첨부한다.

## Definition of done

- [ ] 위 A/C 충족
- [ ] 각 하위 이슈의 변경 모듈 unit test와 SQL regression test 통과
- [ ] Clang/GCC clean build 통과
- [ ] QA 통과
- [ ] 문서/매뉴얼 반영: 사용자 동작 변경이 없으면 N/A 근거 기록

## Open Questions

- 외부 코드가 현재 compiler에서만 발생시키는 경고를 source/target 단위로 격리해 전체 출력 0건을 만들지: `TBD - 합의 미확인`.
- RapidJSON을 갱신할지, 현재 버전에 제한된 patch를 유지할지: S7에서 dependency·packaging 영향 확인 후 결정한다.
- CSQL grammar conflict 가운데 의도된 conflict가 있는지와 허용 가능한 conflict budget: S11 분석 전에는 확정하지 않는다.
- 실제 하위 이슈 번호와 담당자: `TBD - 합의 미확인`.

## Remarks

- 이슈 유형: Refactoring (`Improve Function/Performance` 템플릿)
- 관련 이슈: [CBRD-25784](http://jira.cubrid.org/browse/CBRD-25784) - Clang compiler 지원
- 관련 이슈: [CBRD-26725](http://jira.cubrid.org/browse/CBRD-26725) - GCC 전용 warning option의 Clang 호환성
- 조사 원본: `build_preset_debug_clang/build.log`
- 현재 작업트리의 `src/parser/csql_grammar.y` 변경은 사용자 변경으로 보존하며 이 문서 작업에서 수정하지 않았다.
