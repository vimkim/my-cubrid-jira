# [Schema] 클래스 loader commands 문자열이 공백 없이 끝나면 sm_count_tokens가 문자열 끝을 넘어 읽는 문제

**한 줄 요약**: CodeQL `cpp/nested-loops-with-same-variable` 경고를 확인하다가, 클래스의 loader commands 문자열이 공백 없이 토큰으로 끝나면 `sm_count_tokens`가 NUL 종료 문자 다음 바이트부터 읽고 인접 메모리의 바이트를 토큰으로 더 세는 것을 debug 빌드에서 재현했다. 이 경계 밖 읽기를 없애야 한다.

## Issue Triage

**이슈 수행 목적**: `sm_count_tokens`가 입력 문자열의 NUL 종료 문자에서 멈추고 문자열 안의 토큰 수만 반환하게 한다. 그러면 `sm_split_loader_commands`가 만드는 명령 배열도 실제 토큰만 담는다.

**이슈 수행 이유**: `src/object/schema_manager.c`의 `sm_count_tokens`는 바깥 루프와 안쪽 루프가 같은 인덱스 `i`를 증가시킨다. 문자열이 토큰으로 끝나면 안쪽 루프가 `'\0'`에서 멈춘 뒤 바깥 루프의 `i++`가 종료 문자를 건너뛰어, 할당 영역 밖의 `string[len+1]`부터 다음 `'\0'`까지 읽는다. C API로 loader commands를 `"-lm"`처럼 설정한 클래스에서 동적 메서드 링크를 일으켜, gdb로 이 동작을 확인했다.

**영향**: 경계 밖 읽기는 정의되지 않은 동작이다. 재현에서는 한 토큰짜리 문자열인데도 토큰 수가 2로 계산되었고, `sm_split_loader_commands`는 이 수만큼 명령 배열을 채운다. 이 경로는 loader commands가 설정된 클래스에서, 정적으로 링크되지 않은 C 메서드를 동적으로 링크할 때만 실행된다. loader commands는 공개 C API(`db_set_loader_commands`, `dbt_set_loader_commands`)로만 설정되며, SQL 문법이나 loaddb에서 설정하는 경로는 찾지 못했다. Linux에서는 분리된 명령 배열을 사용하지 않으므로, 확인된 영향은 경계 밖 읽기 자체와 빈 문자열 원소가 추가되는 것이다. 읽는 위치가 매핑되지 않은 페이지에 걸려 프로세스가 종료되는 경우는 관찰하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

클래스에는 C 메서드를 동적으로 링크할 때 쓰는 loader commands 문자열(`SM_CLASS::loader_commands`)이 있다. 이 값은 카탈로그에 저장되며, 메서드 링크 시 `sm_dynamic_link_class`가 `sm_split_loader_commands`로 공백 기준으로 나눈다. 토큰 수와 가장 긴 토큰 길이는 `sm_count_tokens`가 계산한다.

```c
/* src/object/schema_manager.c:703-737 (develop e64a04a79a) */
  for (i = 0; string[i] != '\0'; i++)
    {
      if (char_isspace (string[i]))
	{
	  continue;
	}
      tokens++;

      for (chars = 0; string[i] != '\0' && !char_isspace (string[i]); i++, chars++)
	;
      if (chars > maxchars)
	{
	  maxchars = chars;
	}
    }
```

문자열이 `"-lm"`이면 안쪽 루프는 `i = 3`(`'\0'`)에서 멈춘다. 바깥 루프의 증가식이 `i`를 4로 만들고, 조건식은 할당 영역 밖의 `string[4]`를 읽는다. 그 바이트가 `'\0'`이 아니면 루프가 계속되고, 공백이 아닌 바이트를 만나면 토큰 수가 늘어난다. 문자열이 공백으로 끝나면 바깥 루프가 그 공백 다음의 `'\0'`에서 멈추므로 문제가 없다.

`sm_split_loader_commands`(`schema_manager.c:749-819`)는 이 토큰 수로 `commands` 배열을 할당하고 토큰 수만큼 반복한다. 실제 토큰을 다 쓴 뒤의 반복에서는 `ptr`이 `'\0'`에 머물러 빈 문자열을 복사한다. 따라서 토큰 수가 늘면 빈 문자열 원소가 추가된다. 이는 코드를 읽고 판단한 결과이며, 배열 내용을 직접 확인하지는 않았다.

### 호출 경로

- `sm_link_methods`, `sm_link_method` → `sm_dynamic_link_class` → `sm_split_loader_commands` → `sm_count_tokens`
- `sm_dynamic_link_class`는 정적 링크로 찾지 못한 메서드가 있을 때만 호출된다. `sm_link_method`는 `obj_send` 계열(`object_accessor.c`)에서, `sm_link_methods`는 `db_force_method_reload`(`sm_force_method_link`)에서 호출된다. 여러 클래스를 한 번에 링크하는 `sm_prelink_methods`는 loader commands를 쓰지 않는다.
- Linux의 `sm_link_dynamic_methods`는 `commands` 인자를 받지 않는다. 분리 결과는 바로 해제되지만, 분리 자체는 플랫폼과 관계없이 실행된다.

### Test Build

- 정적 분석: CodeQL 2.27.4, 질의 `cpp/nested-loops-with-same-variable`(Likely Bugs/NestedLoopSameVar), build-mode none, CUBRID develop `e64a04a79a`.
- 재현: 이미 설치되어 있던 CUBRID 11.5.0.2635-30043f4 (64bit debug build, GCC, Linux), SA 모드(`libcubridsa`). `30043f4`는 `e64a04a79a`의 조상이며, 두 리비전 사이에 `sm_count_tokens`, `sm_split_loader_commands`, `sm_dynamic_link_class`, `db_set_loader_commands`, `dbt_set_loader_commands`는 바뀌지 않았다. `e64a04a79a` 빌드에서는 실행하지 않았다.

### Repro

`$CUBRID`는 debug 빌드 설치 경로다. 아래 프로그램은 클래스 메서드 하나와 존재하지 않는 메서드 파일, loader commands를 가진 클래스를 만든 뒤 동적 메서드 링크를 일으키고, 트랜잭션을 롤백한다.

```c
/* repro.c */
#include <stdio.h>
#include "dbi.h"

int
main (int argc, char **argv)
{
  const char *cmds = argc > 2 ? argv[2] : "-lm";
  DB_CTMPL *t;
  DB_OBJECT *c;

  if (db_restart (argv[0], 0, argv[1]) != NO_ERROR)
    return 1;
  t = dbt_create_class ("oob_loader_cmd_t");
  if (t == NULL
      || dbt_add_class_method (t, "m", "oob_no_such_function_xyz") != NO_ERROR
      || dbt_add_method_file (t, "/nonexistent/oob_method.o") != NO_ERROR
      || dbt_set_loader_commands (t, cmds) != NO_ERROR)
    return 1;
  c = dbt_finish_class (t);
  if (c == NULL)
    return 1;
  printf ("loader_commands=[%s]\n", db_get_loader_commands (c));
  db_force_method_reload (c);	/* sm_force_method_link -> sm_link_methods -> sm_dynamic_link_class */
  printf ("after reload: err=%d\n", db_error_code ());
  db_abort_transaction ();
  db_shutdown ();
  return 0;
}
```

```sh
gcc -g -I"$CUBRID/include" repro.c -o repro_sa -L"$CUBRID/lib" -lcubridsa -Wl,-rpath,"$CUBRID/lib"

mkdir -p oobdb && (cd oobdb && cubrid createdb --db-volume-size=64M --log-volume-size=64M oobdb en_US.utf8)

cat > gdbcmds <<'EOF'
set pagination off
break schema_manager.c:731
run
printf "strlen=%d final_i=%d tokens=%d\n", (int) strlen (string), i, tokens
x/24xb string
continue
EOF

gdb -batch -x gdbcmds --args ./repro_sa oobdb "-lm"
gdb -batch -x gdbcmds --args ./repro_sa oobdb "-lm "
gdb -batch -x gdbcmds --args ./repro_sa oobdb "-Labcdefghijklm"

cubrid deletedb oobdb
```

`schema_manager.c:731`은 루프 다음의 `if (maxcharp != NULL)` 행이다.

### Expected Result

루프가 끝났을 때 `i`는 `strlen (string)`과 같고, 토큰 수는 문자열 안의 토큰 수와 같다. `"-lm"`과 `"-Labcdefghijklm"`은 모두 토큰 1개다.

### Actual Result

| loader commands | strlen | 루프 종료 시 `i` | tokens | 판정 |
|---|---|---|---|---|
| `"-lm"` | 3 | 4 | 1 | `string[4]`(할당 영역 밖)를 읽음 |
| `"-lm "` (대조군) | 4 | 4 | 1 | 정상 |
| `"-Labcdefghijklm"` (15자) | 15 | 18 | 2 | 경계 밖 바이트 `0x2b`를 토큰으로 셈 |
| `"-Labcdefghijklm…u"` (23자) | 23 | 26 | 2 | 경계 밖 바이트를 토큰으로 셈 |

15자 경우의 메모리 덤프에서 문자열의 `'\0'`(오프셋 15) 다음 바이트가 `0x2b`이고, 이것이 두 번째 토큰으로 계산되었다. 어느 경우든 `db_force_method_reload` 이후 오류는 `-390`(`ER_DL_EFILE`, 존재하지 않는 메서드 파일)이었고 프로세스는 종료되지 않았다.

### Additional Information

- 같은 프로그램을 valgrind로 실행했지만 이 읽기는 보고되지 않았다. SA 모드의 workspace 문자열은 `db_ws_alloc`이 lea heap(`hl_lea_alloc`)에서 할당하므로, valgrind는 할당 경계를 알지 못한다. 메모리 검사 도구로 관찰하려면 workspace 할당이 `malloc`으로 가는 구성이나 ASan 빌드가 필요하다.
- ANALYSIS 확인 사항: 현재 제품의 어떤 도구나 드라이버가 loader commands를 설정하는지, 그리고 C 메서드 동적 링크가 지원 기능으로 남아 있는지 확인하지 않았다. 이 답에 따라 사용자 도달 가능성과 우선순위가 달라진다.
- ANALYSIS 확인 사항: CS 모드에서 SQL `CALL ... ON CLASS`로 C 메서드를 호출할 때 같은 경로를 지나는지 실행으로 확인하지 않았다.
