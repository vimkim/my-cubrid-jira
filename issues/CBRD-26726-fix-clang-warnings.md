# [BUILD] clang 컴파일러 빌드 시 발생하는 경고 전수조사 및 정리

## Description

### 배경
CUBRID 소스를 `debug_clang` 프리셋으로 빌드하면 **1,590 건의 clang 경고** 가 출력된다. 이 중 `-Wunknown-warning-option` (GCC 전용 `-Wclobbered` 플래그를 clang 이 모르기 때문에 발생하는 경고) 은 비교적 최근에 추가된 경고로 **본 이슈에서는 다루지 않으며, [CBRD-26725](http://jira.cubrid.org/browse/CBRD-26725) 에서 선행 처리될 예정** 이다.

본 이슈는 `-Wmismatched-new-delete`, `-Wself-assign`, `-Wstring-concatenation`, `-Wpointer-bool-conversion`, `-Wtautological-pointer-compare`, `-Wformat`, `-Wenum-conversion` 등 **실제 버그 또는 UB 후보** 경고들의 정리를 목표로 한다.

| 분류 | 설명 |
|------|------|
| Critical | `-Wmismatched-new-delete` — `delete` 가 `new[]` 로 할당된 포인터에 적용됨 (`perf_monitor.c:4519`) |
| Real bug | `-Wself-assign` — `x = x;` no-op 할당 (코드 의도 불명) |
| Real bug | `-Wpointer-bool-conversion` / `-Wtautological-pointer-compare` — `char[]` 배열을 `NULL` 과 비교 (항상 true/false) |
| Real bug | `-Wstring-concatenation` — 배열 초기화에서 인접 string literal 이 암묵적으로 결합 |
| Real bug | `-Wformat` — `PGLENGTH (INT16)` 에 `%ld` 지정자 사용 |
| Code smell | `-Wpessimizing-move` — rvalue 에 `std::move` 중복 적용 (copy elision 방해) |
| Code smell | `-Wenum-conversion` — `pt_currency_types` → `DB_CURRENCY` 암묵 변환 (csql_grammar) |
| Code smell | `-Woverloaded-virtual` — `yylex` 오버로드가 base `yyFlexLexer::yylex` 을 숨김 |
| Cleanup | `-Wparentheses-equality` — `if ((x == y))` 중복 괄호 |

### 목적
- clang 에서 보고되는 **진성 버그/UB 경고를 직접 코드 수정으로 제거** 한다.
- `-Wno-*` 플래그 추가로 경고를 숨기는 방식은 **채택하지 않는다** (근본 원인 해결 우선).
- 3rd-party 파일(`src/heaplayers/malloc_2_8_3.c`, `src/base/mprec.c`) 은 수정 대상에서 제외한다.
- 생성 파일(`csql_grammar.c`, `csql_lexer.c`) 은 원본(`.y`, `.l`) 에서 수정 가능한 경우에만 수정한다.

---

## Implementation

### 경고 감소 요약

| 카테고리 | Before | After | 수정 방식 |
|----------|--------|-------|-----------|
| `-Wenum-conversion` | 50 | 0 | `pt_value_set_monetary` 의 파라미터 타입을 `DB_CURRENCY` → `PT_CURRENCY` 로 변경 |
| `-Wpessimizing-move` | 21 | 0 | 임시 객체에 대한 불필요한 `std::move` 제거 |
| `-Wpointer-bool-conversion` | 13 | 0 | `char[]` 배열의 truthiness 검사를 `arr[0] != '\0'` 또는 제거 |
| `-Wtautological-pointer-compare` | 12 | 0 | 배열-vs-`NULL` 비교를 `arr[0]` 검사로 교체 또는 제거 |
| `-Woverloaded-virtual` | 12 | 0 | `using yyFlexLexer::yylex;` 추가 |
| `-Wparentheses-equality` | 8 | 0 | `if ((x == y))` → `if (x == y)` |
| `-Wself-assign` | 6 | 0 | `x = x;` no-op 제거 |
| `-Wformat` | 3 | 0 | `%ld` → `%d` (`PGLENGTH`) |
| `-Wmismatched-new-delete` | 2 | 0 | `delete` → `delete[]` |
| `-Wstring-concatenation` | 1 | 0 | 인접 string literal 을 하나의 literal 로 병합 |

**전체 경고: 1,590 → 1,462** (128 건 감소, 빌드 성공 유지).

### 주요 수정 사항

#### 1. `perf_monitor.c` — `delete[]` 누락 (Critical, UB)
```c
// Before
char *strbuf = new char[STATS_DUMP_MAX_SIZE];
...
delete strbuf;                  // new[] 로 할당한 포인터에 delete 적용 — UB

// After
delete[] strbuf;
```

#### 2. `csql_grammar.y` — PT/DB enum 혼용
grammar action 은 전부 `PT_CURRENCY_*` 상수를 전달하는데, 함수 시그니처는 `DB_CURRENCY` 로 선언되어 있어 50 건의 `-Wenum-conversion` 이 발생했다. 두 enum 은 값이 동일하므로 시그니처를 `PT_CURRENCY` 로 맞추면 해결된다.

```c
// Before
static void pt_value_set_monetary (PARSER_CONTEXT *parser, PT_NODE *node,
                   const char *str, const char *txt, DB_CURRENCY type);

// After
static void pt_value_set_monetary (PARSER_CONTEXT *parser, PT_NODE *node,
                   const char *str, const char *txt, PT_CURRENCY type);
```

#### 3. `pl_executor.cpp` / `pl_session.cpp` / `db_json.cpp` — pessimizing move
rvalue (함수 반환 임시 객체) 에 `std::move` 를 씌우면 C++17 의 **mandatory copy elision** 을 방해한다.

```cpp
// Before
blk = std::move (pack_data_block (METHOD_RESPONSE_SUCCESS, *parameter_info));

// After
blk = pack_data_block (METHOD_RESPONSE_SUCCESS, *parameter_info);
```

#### 4. `char[]` 배열 포인터 비교 (7 개 파일)
`char arr[N]` 은 `NULL` 이 될 수 없으므로 `if (arr)` 또는 `if (arr != NULL)` 은 항상 true 다. 의도가 "문자열 비어있음" 검사인 경우 `arr[0] != '\0'` 로, 순수 방어 코드인 경우는 제거한다.

| 파일 | 수정 방식 |
|------|-----------|
| `src/base/tz_compile.c` | `zones[i].comments != NULL` → `zones[i].comments[0] != '\0'` |
| `src/base/unicode_support.c` | `if (str_p != NULL)` 제거 (항상 true) |
| `src/broker/cas_network.c` | `if (port_name == NULL)` 분기 제거 |
| `src/broker/cas_sql_log2.c` | `sql_log2_file == NULL` → `sql_log2_file[0] == '\0'` |
| `src/broker/shard_shm.c` | `client_info_p->driver_info` → `driver_info[0] != '\0'` |
| `src/executables/unload_schema.c`, `util_cs.c` | 중복/tautological NULL 검사 제거 |
| `src/method/method_callback.cpp` | `realname? realname : ""` → `realname` (배열이라 항상 비null) |
| `cubrid-cci/src/cci/cas_cci.c` | `err_buf.err_msg != NULL` 검사 제거 |

#### 5. `view_transform.c`, `parse_tree_cl.c` — self-assign
```c
// Before
default:
  statement = statement;    // no-op
  break;

for (temp = temp; temp; temp = temp->next)   // 의도 불명
```

Self-assign 은 코드 의도가 없는 죽은 문장이므로 제거한다. `for (temp = temp; ...)` 는 루프 초기화부를 비우는 `for (; temp; ...)` 로 변경.

#### 6. `log_applier.c` — `%ld` vs `int` (PGLENGTH 는 INT16)
```c
// Before
printf ("offset:%04ld ... o:%ld ...", lsa.offset, ..., lrec->back_lsa.offset, ...);

// After
printf ("offset:%04d ... o:%d ...", lsa.offset, ..., lrec->back_lsa.offset, ...);
```

#### 7. `load_scanner.hpp` — overloaded-virtual
```cpp
// Before
virtual int yylex (parser::semantic_type *, parser::location_type *);
// yyFlexLexer::yylex() 무인자 버전이 숨겨짐

// After
using yyFlexLexer::yylex;
virtual int yylex (parser::semantic_type *, parser::location_type *);
```

#### 8. `tz_compile.c` — 실수로 인접한 string literal
```c
// Before
"Invalid link definition (s1: %s, s2: %s). " "Format error or invalid data encountered.",

// After (하나의 literal 로 결합)
"Invalid link definition (s1: %s, s2: %s). Format error or invalid data encountered.",
```

---

## Acceptance Criteria

- [x] `cmake --build --preset debug_clang --clean-first` 빌드 성공
- [x] `-Wmismatched-new-delete` 경고 0 건
- [x] `-Wself-assign` 경고 0 건
- [x] `-Wstring-concatenation` 경고 0 건
- [x] `-Wpointer-bool-conversion` 경고 0 건
- [x] `-Wtautological-pointer-compare` 경고 0 건
- [x] `-Wparentheses-equality` 경고 0 건
- [x] `-Wformat` 경고 0 건
- [x] `-Woverloaded-virtual` 경고 0 건
- [x] `-Wpessimizing-move` 경고 0 건
- [x] `-Wenum-conversion` 경고 0 건
- [x] 3rd-party 파일 (`malloc_2_8_3.c`, `mprec.c`) 미수정
- [x] `-Wno-*` 로 경고를 숨기지 않음
- [x] 전체 clang 경고 수 1,590 → 1,462 로 감소

---

## Remarks

### 남은 경고 (follow-up 후보)

| 카테고리 | Count | 비고 |
|----------|-------|------|
| `-Wgnu-null-pointer-arithmetic` | 120 | 3rd-party `malloc_2_8_3.c` 전용, 수정 대상 아님 |
| `-Wmissing-field-initializers` | 45 | 대량 cosmetic, 주로 `has_dblink` 필드 누락 |
| `-Wimplicit-const-int-float-conversion` | 42 | 실제 정밀도 손실 가능성 — 개별 검토 필요 |
| `-Wsign-compare` | 24 | `size_t` vs `int` 혼용 |
| `-Wtautological-constant-out-of-range-compare` | 23 | enum vs `-1` 비교 등 |
| `-Wmissing-braces` | 11 | cosmetic subobject 초기화 |
| `-Wunused-parameter` | 10 | 생성 파일 `csql_lexer.c` (flex 출력) |
| `-Wtautological-bitwise-compare` | 8 | `(x \| NONZERO)` 류 — 의심 버그 |
| `-Wvarargs` | 4 | `QO_PARAM` (enum) 을 `va_start` 에 전달 — UB. 시그니처 변경 필요, callers 광범위 |
| `-Wvla-cxx-extension` | 3 | C VLA 를 C++ 로 빌드 — `std::vector` 로 치환 필요 |
| `-Wlogical-not-parentheses` | 3 | 3rd-party `mprec.c` 전용 |
| `-Wsometimes-uninitialized` | 2 | 생성 파일 `csql_lexer.c` |
| `-Wdeprecated-copy-with-user-provided-copy` | 2 | `btree_unique_stats` — 명시적 copy ctor 필요 |
| `-Wconstant-conversion` | 2 | `cci_network.c` — `char` 에 192 대입 (오버플로) |
| `-Wmismatched-tags` | 1 | `struct` / `class` 불일치 선언 |
| `-Winstantiation-after-specialization` | 1 | `px_heap_scan_result_handler.cpp` — 순서 조정 |

### PR
draft PR 로 링크 예정: `[CBRD-26726] Fix clang build warnings`

### 관련 이슈
- [CBRD-26725](http://jira.cubrid.org/browse/CBRD-26725) — `-Wunknown-warning-option` (GCC 전용 `-Wclobbered` 등) 선행 처리

### 참고
- clang `debug_clang` 프리셋은 `cmake --list-presets=build` 결과에 포함됨
- `-Wclobbered` 는 GCC 전용 플래그 — clang 은 각 컴파일 단위마다 `-Wunknown-warning-option` 을 발생시킴 (별도 해결 필요)
