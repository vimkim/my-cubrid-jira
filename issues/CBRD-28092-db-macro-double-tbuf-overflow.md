# [Type] 지수가 세 자리인 음수 DOUBLE을 문자열로 바꿀 때 valcnv_convert_double_to_string이 24바이트 스택 버퍼를 1바이트 넘겨 쓰는 문제

**한 줄 요약**: CodeQL `cpp/overrunning-write` 경고를 확인하다가, `-1.2345678901234567e-300`처럼 지수가 세 자리인 음수 DOUBLE 값을 `%.17g`로 출력하면 `src/compat/db_macro.c`의 `valcnv_convert_double_to_string`이 24바이트 `tbuf`에 25바이트를 쓰는 것을 debug 빌드에서 재현했다. 이 스택 버퍼 오버플로를 없애야 한다.

## Issue Triage

**이슈 수행 목적**: DOUBLE 값을 문자열로 바꾸는 `valcnv_convert_double_to_string`이 모든 DOUBLE 값에 대해 `tbuf` 경계 안에서만 쓰고, 지금과 같은 문자열을 만들게 한다.

**이슈 수행 이유**: `valcnv_convert_double_to_string`은 `char tbuf[24]`에 `sprintf (tbuf, "%.17g", value)`로 쓴다. 부호, 유효숫자 17자리, 소수점, 세 자리 지수(`e-300`)를 합치면 24자이고, NUL 종료 문자까지 25바이트가 필요하다. `snprintf`가 아니라 `sprintf`를 쓰므로 잘림이 아니라 1바이트 오버플로가 일어난다. `CREATE TABLE ... (d DOUBLE DEFAULT -1.2345678901234567e-300)`과 `SHOW COLUMNS`를 실행해 gdb로 이 동작을 확인했다.

**영향**: 스택 버퍼 경계 밖 쓰기는 정의되지 않은 동작이다. 이 경로는 서버에서 DOUBLE 기본값을 카탈로그 문자열로 바꿀 때(`CREATE TABLE`, `DROP TABLE` 등 카탈로그 갱신)와 `SHOW COLUMNS`에서 실행되므로, 일반 SQL 사용자가 값을 골라 실행할 수 있다. 재현한 debug 빌드에서는 넘친 1바이트가 같은 함수 프레임의 사용하지 않는 패딩에 떨어져 결과가 정상이었고 프로세스도 종료되지 않았다. release 빌드는 디스어셈블로만 확인했으며, 넘친 바이트가 DOUBLE 경로에서 읽지 않는 스택 영역에 떨어지는 것으로 보인다. 따라서 debug 빌드에서 관찰된 오동작은 없고, release GCC 빌드에서도 드러나는 오동작은 없을 것으로 추정한다. 그러나 결과는 컴파일러의 스택 배치에 달려 있으므로, 다른 컴파일러나 옵션, 이후 코드 변경에서도 안전하다고 보장할 수 없다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

`valcnv_*` 함수들은 `DB_VALUE`를 사람이 읽을 수 있는 문자열로 바꾼다. 진입점은 `valcnv_convert_value_to_string`이고, DOUBLE 값은 `valcnv_convert_data_to_string`을 거쳐 `valcnv_convert_double_to_string`이 처리한다.

```c
/* src/compat/db_macro.c:2226-2244 (develop e64a04a79a) */
static VALCNV_BUFFER *
valcnv_convert_double_to_string (VALCNV_BUFFER * buffer_p, const double value)
{
  char tbuf[24];

  sprintf (tbuf, "%.17g", value);                                       /* 2231 */
  ...
  if (strstr (tbuf, "Inf"))
    {
      sprintf (tbuf, "%.17g", (value > 0 ? DBL_MAX : -DBL_MAX));        /* 2240 */
    }

  return valcnv_append_string (buffer_p, tbuf);
}
```

glibc의 `%.17g` 출력 길이를 직접 재었다.

| 값 | `%.17g` 출력 | 길이 | NUL 포함 |
|---|---|---|---|
| `-1.2345678901234567e-300` | `-1.2345678901234568e-300` | 24 | 25 (넘침) |
| `-DBL_MAX` | `-1.7976931348623157e+308` | 24 | 25 (넘침) |
| `-1.2345678901234567e-100` | `-1.2345678901234567e-100` | 24 | 25 (넘침) |
| `1.2345678901234567e-300` (양수) | `1.2345678901234568e-300` | 23 | 24 |
| `-1.2345678901234567e-99` (두 자리 지수) | `-1.2345678901234566e-99` | 23 | 24 |

따라서 넘침 조건은 값이 음수이고, 지수의 절댓값이 100 이상이며, `%.17g`가 뒤의 0을 지우지 않아 유효숫자 17자리가 모두 출력되는 경우다.

- 2240행의 `sprintf`도 `-DBL_MAX`를 출력하면 같은 25바이트를 쓴다. 다만 glibc는 무한대를 `inf`(소문자)로 출력하므로 `strstr (tbuf, "Inf")`가 참이 되지 않아, Linux에서는 이 행이 실행되지 않는다고 판단했다. 코드와 glibc 출력으로 판단한 결과이며, 다른 플랫폼은 확인하지 않았다.
- 같은 파일의 `valcnv_convert_float_to_string`(2203, 2212행)도 같은 형태지만, FLOAT 값의 지수는 두 자리를 넘지 않는다. `-FLT_MAX`와 가장 작은 음의 비정규 FLOAT 모두 23자로 측정되어 24바이트 안에 들어간다.

### 호출 경로

- 카탈로그 갱신: `catcls_get_or_value_from_attribute`(`src/storage/catalog_class.c:1517`, `1571`) → `valcnv_convert_value_to_string` → `valcnv_convert_db_value_to_string` → `valcnv_convert_data_to_string` → `valcnv_convert_double_to_string`. 재현에서 `CREATE TABLE`과 `DROP TABLE` 모두 이 경로를 지났다.
- `SHOW COLUMNS`: `qexec_execute_build_columns`(`src/query/query_executor.c:32866`)가 컬럼 기본값을 문자열로 바꿀 때 같은 함수를 호출한다.
- 그 밖에 `db_collection_to_string_dbval`(`src/query/arithmetic.c:5215`)이 컬렉션 원소를 문자열로 바꿀 때도 이 함수를 지난다. 이 경로는 실행으로 확인하지 않았다.

### Test Build

- 정적 분석: CodeQL 2.27.4, 질의 `cpp/overrunning-write`, build-mode none, CUBRID develop `e64a04a79a`.
- 재현: 이미 설치되어 있던 CUBRID 11.5.0.2635-30043f4 (64bit debug build, GCC, Linux), SA 모드(`csql -S`). `30043f4`는 `e64a04a79a`의 조상이며, 두 리비전의 `valcnv_convert_double_to_string` 본문은 같다. `e64a04a79a` 빌드에서는 실행하지 않았다.
- 디스어셈블 확인: 11.5.0.2802-e64a04a (release build, GCC)의 `libcubrid.so`.

### Repro

`$CUBRID`는 debug 빌드 설치 경로다. 아래 gdb 명령은 `sprintf` 직전에 `tbuf` 바로 다음 바이트를 기록하고, 호출이 끝난 뒤 문자열 길이와 그 바이트를 다시 읽는다. `db_macro.c:2223`과 `+0x24`는 `30043f4` 빌드의 `sprintf` 행과 그 호출이 끝난 다음 명령어 위치다. 다른 빌드에서는 행 번호와 오프셋을 그 빌드에 맞게 바꿔야 한다.

```sh
cat > repro.sql <<'EOF'
CREATE TABLE vc_t (d DOUBLE DEFAULT -1.2345678901234567e-300);
SELECT attr_name, default_value FROM db_attribute WHERE class_name = 'vc_t';
SHOW COLUMNS FROM vc_t;
DROP TABLE vc_t;
EOF

cat > repro.gdb <<'EOF'
set pagination off
set breakpoint pending on
break db_macro.c:2223
commands
  silent
  set $guard = (unsigned char *) &tbuf + sizeof (tbuf)
  printf "[before sprintf] value=%.17g sizeof(tbuf)=%d byte_after_tbuf=0x%02x\n", value, (int) sizeof (tbuf), *$guard
  tbreak *($pc + 0x24)
  continue
end
run
printf "[after sprintf] strlen(tbuf)=%d tbuf=\"%s\" byte_after_tbuf=0x%02x\n", (int) strlen (tbuf), tbuf, *$guard
bt 6
EOF

mkdir -p vcdb && (cd vcdb && cubrid createdb --db-volume-size=20M --log-volume-size=20M vcbug en_US)
gdb -batch -x repro.gdb --args "$CUBRID/bin/csql" -S -u dba vcbug -i repro.sql
csql -S -u dba vcbug -i repro.sql
cubrid deletedb vcbug
```

CodeQL이 예로 든 `-1.2345678901234567e-308`은 비정규 수라서 SQL 리터럴로 쓰면 파서가 `1.2345678901234567e-308 exceeds limit of double.` 오류를 낸다. 그래서 같은 길이의 정규 수 `-1.2345678901234567e-300`을 사용했다.

### Expected Result

`sprintf`가 `tbuf` 24바이트 안에서만 쓰고, 기본값 문자열은 `-1.2345678901234568e-300`으로 지금과 같다.

### Actual Result

gdb 출력(첫 번째 호출, `CREATE TABLE`의 카탈로그 갱신):

```text
[before sprintf] value=-1.2345678901234568e-300 sizeof(tbuf)=24 byte_after_tbuf=0xa8
[after sprintf] strlen(tbuf)=24 tbuf="-1.2345678901234568e-300" byte_after_tbuf=0x00
#0  valcnv_convert_double_to_string (...) at src/compat/db_macro.c
#1  valcnv_convert_data_to_string (...) at src/compat/db_macro.c:2436
#2  valcnv_convert_db_value_to_string (...) at src/compat/db_macro.c:2818
#3  valcnv_convert_value_to_string (...) at src/compat/db_macro.c:2844
#4  catcls_get_or_value_from_attribute (...) at src/storage/catalog_class.c:1587
#5  catcls_get_subset (...) at src/storage/catalog_class.c:2811
```

24바이트 배열에 24자 문자열이 들어갔고, 배열 바로 다음 바이트가 `0xa8`에서 `0x00`(NUL 종료 문자)으로 바뀌었다. 별도 실행에서 이 바이트에 하드웨어 watchpoint를 걸었을 때 `__vsprintf_internal`이 이 바이트를 썼다. 같은 SQL에서 `SHOW COLUMNS`는 `qexec_execute_build_columns`(`query_executor.c:26487`, `30043f4` 기준) 경로로 이 함수를 호출했다.

gdb 없이 실행한 결과는 정상으로 보였다. `default_value`와 `SHOW COLUMNS`의 `Default`는 모두 `'-1.2345678901234568e-300'`이었고, 오류나 프로세스 종료는 없었다.

### Additional Information

- debug 빌드에서 결과가 정상인 이유: `valcnv_convert_double_to_string` 프레임은 `rbp-0x30`까지 잡혀 있고 `tbuf`는 `rbp-0x20`부터 24바이트다. 넘친 바이트 `rbp-0x8`은 같은 프레임의 사용하지 않는 패딩이며, 이 함수에는 stack protector canary가 없다.
- release 빌드(`e64a04a`)는 이 함수를 `valcnv_convert_data_to_string`에 인라인하고, `__sprintf_chk`가 아닌 `sprintf`를 그대로 호출한다. 그 함수에도 stack protector canary 검사가 없으므로, 넘침은 검출되지 않는다.
- 같은 release 빌드에서 `tbuf`는 `rbp-0x1390`에 놓이고, 넘친 바이트는 `rbp-0x1378`이다. 이 스택 영역은 다른 `case`에서 쓰는 지역 저장 공간과 공유되며, `rbp-0x1378`을 직접 참조하는 명령은 다른 `case` 분기의 쓰기 한 곳뿐이다. 그래서 DOUBLE 경로에서는 덮인 바이트를 읽지 않는다고 판단했다. 디스어셈블로 판단한 결과이며 release 빌드에서 실행해 확인하지는 않았다.
- ANALYSIS 확인 사항: clang 빌드나 다른 최적화 옵션에서 `tbuf` 다음에 살아 있는 변수가 놓이는지 확인하지 않았다. 이 답에 따라 영향과 우선순위가 달라진다.
- ANALYSIS 확인 사항: CS 모드(`cub_server`)에서 같은 SQL을 실행해 확인하지는 않았다. 호출 경로는 서버 쪽 코드이므로 같은 동작을 예상하지만, 이는 추론이다.
