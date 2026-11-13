# [Catalog] catcls_get_db_collation이 32자 콜레이션 이름을 복사할 때 coll_name 배열 바로 뒤에 '\0'을 써 codeset을 덮는 문제

**한 줄 요약**: [CBRD-28091](https://jira.cubrid.org/browse/CBRD-28091)(같은 함수의 realloc 실패 검사 오류)을 조사하면서 범위 밖으로 남겨 둔 결함이다. `catcls_get_db_collation`은 `_db_collation.coll_name`이 32자이면 32바이트 배열 `coll_name` 바로 뒤에 `'\0'`을 쓰고, 그 자리에 있는 `codeset` 필드를 0으로 덮는다. 현재 CUBRID가 만드는 콜레이션 이름은 최대 31자라 일반 사용 경로에서는 재현되지 않았지만, 카탈로그 컬럼이 32자를 허용하므로 복사 코드가 배열 크기 안에서 끝나도록 고쳐야 한다.

## Issue Triage

**이슈 수행 목적**: `_db_collation`에서 읽은 콜레이션 이름의 길이와 관계없이 `catcls_get_db_collation`이 `LANG_COLL_COMPAT` 배열 경계 밖에 쓰지 않게 한다.

**이슈 수행 이유**: 이름 길이를 `sizeof (coll_name)`(32)으로 제한한 뒤 `coll_name[길이]`에 `'\0'`을 쓰므로, 이름이 32자이면 인덱스 32에 쓴다. `_db_collation.coll_name` 컬럼은 `varchar(32)`라 32자 값을 담을 수 있다. gdb로 32자 이름을 주입했을 때 이미 읽어 둔 `codeset` 값 5(UTF-8)가 0으로 바뀌는 것을 관찰했다.

**영향**: 현재 확인한 범위에서는 잠재 결함이다. 내장 콜레이션 이름은 최대 14자이고, 사용자 정의(LDML) 콜레이션 이름은 파서와 로케일 라이브러리 로더가 31자로 자르며, SQL로 `_db_collation`을 고칠 수 없다. 따라서 일반 사용자가 이 경로를 밟을 방법은 찾지 못했다. 다만 카탈로그 손상이나 향후 이름 길이 제한 변경이 있으면 DB 기동(`boot_restart_server`)과 `cubrid synccolldb`의 콜레이션 호환성 검사가 잘못된 codeset을 보고 판단한다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

`catcls_get_db_collation`은 `_db_collation` 카탈로그의 모든 행을 읽어 `LANG_COLL_COMPAT` 배열을 만든다. 이 배열은 서버 기동 시 `lang_check_coll_compat`이 현재 로드된 콜레이션과 DB에 기록된 콜레이션의 ID, 이름, codeset, checksum이 같은지 확인하는 데 쓰인다.

```c
/* src/base/locale_support.h:84 */
#define COLL_NAME_SIZE 32

/* src/base/language_support.h:254-260 */
struct lang_coll_compat
{
  int coll_id;
  char coll_name[COLL_NAME_SIZE];
  INTL_CODESET codeset;
  char checksum[32 + 1];
};
```

```c
/* src/storage/catalog_class.c:5427-5432 (develop e64a04a79a) */
	      lang_str = db_get_string (&heap_value->dbvalue);
	      lang_str_len = (lang_str != NULL) ? strlen (lang_str) : 0;
	      lang_str_len = MIN (lang_str_len, sizeof (curr_coll->coll_name));

	      strncpy (curr_coll->coll_name, lang_str, lang_str_len);
	      curr_coll->coll_name[lang_str_len] = '\0';
```

- `lang_str_len`의 상한이 `sizeof (curr_coll->coll_name)` = 32다. 이름이 32자 이상이면 `strncpy`는 32바이트를 채우고, 다음 줄이 `coll_name[32]`에 쓴다. 상한은 `sizeof - 1`이어야 배열 안에서 끝난다. 다른 콜레이션 이름 복사 코드(`src/base/locale_support.c:1883-1884`, `src/base/language_support.c:7025`)는 `COLL_NAME_SIZE - 1`로 자른다.
- `coll_name`은 구조체 오프셋 4에서 시작하므로 `coll_name[32]`는 오프셋 36, 곧 `codeset`의 첫 바이트다(gdb로 `offsetof (codeset) = 36`, `sizeof (LANG_COLL_COMPAT) = 76` 확인). 쓰기가 같은 구조체 안에서 끝나므로 다른 힙 블록을 덮지는 않는다. 같은 이유로 AddressSanitizer 같은 블록 단위 경계 검사로는 드러나지 않을 것으로 본다(추정, 실행하지 않음).
- `heap_attrinfo_read_dbvalues`가 채운 값 배열에서 `charset_id`(정수, 고정 길이)는 `coll_name`(가변 길이)보다 먼저 온다. 따라서 `codeset`이 먼저 대입된 뒤 `'\0'` 쓰기가 그 하위 바이트를 0으로 덮는다. little-endian에서 UTF-8(5)은 `INTL_CODESET_ASCII`(0)가 된다.

### 이름 길이 상한 확인 결과

| 경로 | 최대 길이 | 근거 |
|---|---|---|
| `_db_collation.coll_name` 컬럼 | 32자 | `src/object/schema_system_catalog_install.cpp:1011`의 `format_varchar (32)` |
| 카탈로그 행 생성 | 원본 길이 그대로 | `src/object/schema_system_catalog_install.cpp:164-166`이 `strlen (coll_name)` 길이로 저장 |
| 내장 콜레이션 | 14자 | 새 DB의 `_db_collation` 10행 중 최대 `char_length(coll_name)` = 14 (`iso88591_en_cs` 등) |
| LDML 사용자 정의 콜레이션 | 31자 | `src/base/locale_support.c:1883-1884`가 `COLL_NAME_SIZE - 1`로 자름 |
| 로케일 라이브러리 로드 | 31자 | `src/base/language_support.c:7024-7025`가 `sizeof (coll_name) - 1`로 자름 |
| SQL로 카탈로그 수정 | 불가 | DBA 계정 `UPDATE _db_collation ...`이 `UPDATE is not authorized on _db_collation.` 오류 |

현재 생성 경로는 모두 31자 이하만 만든다. 32자 이름이 카탈로그에 들어가는 경로는 찾지 못했다.

### 호출 경로

- `boot_restart_server`(`src/transaction/boot_sr.c:2631-2652`): `check_db_coll`이 참이면 호출하고, 결과를 `lang_check_coll_compat`에 넘긴다. `cub_server` 기동과 SA 모드 접속이 해당한다.
- `synccoll_check`(`src/executables/util_sa.c:3158`): `cubrid synccolldb`가 직접 호출한다.

### Test Build

- 소스 확인: CUBRID develop `e64a04a79a`.
- 실행: 이미 설치되어 있던 CUBRID 11.5.0.2635-30043f4 (64bit debug build, GCC, Linux), SA 모드. `30043f4`는 `e64a04a79a`의 조상이며 `catcls_get_db_collation` 본문과 `LANG_COLL_COMPAT` 정의가 같다. 이 함수의 행 번호는 `30043f4`에서 16행 뒤에 있다. `e64a04a79a` 빌드에서는 실행하지 않았다.

### Repro

자연 재현은 하지 못했다. 위 표처럼 32자 이름을 카탈로그에 넣을 경로가 없기 때문이다. 대신 gdb로 이름 문자열만 32자로 바꿔 결함이 실제로 무엇을 덮는지 관찰했다. 아래 행 번호는 `30043f4` 빌드 기준이다(`e64a04a79a`에서는 각각 16을 뺀다).

```sh
mkdir -p collovf && cd collovf
cubrid createdb --db-volume-size=64M --log-volume-size=64M collovf en_US.utf8

cat > inject.gdb <<'EOF'
set pagination off
set breakpoint pending on
set var $done = 0
break catalog_class.c:5444
commands 1
  silent
  if $done == 0 && curr_coll->coll_id == 5
    printf "[inject] coll_id=%d original name=%s -> 32-char name\n", curr_coll->coll_id, lang_str
    set var lang_str = "utf8_aaaaaaaaaaaaaaaaaaaaaaaaaaa"
    set var $done = 1
  end
  continue
end
break catalog_class.c:5448
commands 2
  silent
  if curr_coll->coll_id == 5
    printf "[before-term] lang_str_len=%lu sizeof(coll_name)=%lu offsetof(codeset)=%lu sizeof(LANG_COLL_COMPAT)=%lu codeset=%d\n", lang_str_len, sizeof (curr_coll->coll_name), (unsigned long) &curr_coll->codeset - (unsigned long) curr_coll, sizeof (*curr_coll), (int) curr_coll->codeset
  end
  continue
end
break catalog_class.c:5430
commands 3
  silent
  if curr_coll->coll_id == 5
    printf "[attr i=%d attrid=%d] (coll_id=%d name=%d charset=%d checksum=%d) codeset=%d\n", i, heap_value->attrid, coll_id_att_id, coll_name_att_id, charset_id_att_id, checksum_att_id, (int) curr_coll->codeset
  end
  continue
end
break catalog_class.c:5413
commands 4
  silent
  if *coll_cnt > 0 && (*db_collations)[*coll_cnt - 1].coll_id == 5
    printf "[next-row] prev row coll_id=5 codeset=%d byte@coll_name+32=0x%02x\n", (int) (*db_collations)[*coll_cnt - 1].codeset, ((unsigned char *) (*db_collations)[*coll_cnt - 1].coll_name)[32]
  end
  continue
end
run
quit
EOF

gdb -q -batch -x inject.gdb --args "$CUBRID/bin/csql" -S -u dba collovf -c "select count(*) from _db_collation"

cd .. && cubrid deletedb collovf
```

### Expected Result

이름이 32자여도 `coll_name` 안에서 끝나는 문자열(최대 31자 + `'\0'`)이 되거나 오류로 처리되고, 앞서 읽은 `codeset` 값 5는 그대로 남는다.

### Actual Result

`30043f4` debug 빌드에서 관찰한 결과다(gdb 출력 발췌).

```text
[attr i=6 attrid=0] (coll_id=7 name=6 charset=5 checksum=0) codeset=5
[attr i=7 attrid=6] (coll_id=7 name=6 charset=5 checksum=0) codeset=5
[inject] coll_id=5 original name=utf8_en_ci -> 32-char name
[before-term] lang_str_len=32 sizeof(coll_name)=32 offsetof(codeset)=36 sizeof(LANG_COLL_COMPAT)=76 codeset=5
[next-row] prev row coll_id=5 codeset=0 byte@coll_name+32=0x00
ERROR: Unable to restart/initialize the database server. Locale initialization: Names of collation with id 5 do not match : on server, is 'utf8_aaaaaaaaaaaaaaaaaaaaaaaaaaa'; on database, is 'utf8_en_ci'.
```

- 이름 속성(attrid 6)은 값 배열의 마지막(i=7)이고, 그 전에 `codeset`이 5로 설정되어 있었다.
- `lang_str_len`이 32가 되어 `coll_name[32]`에 썼고, 다음 행으로 넘어갈 때 `codeset`은 0이었다.
- 이 실험에서는 주입한 이름이 로드된 콜레이션 이름(`utf8_en_ci`)과 달라 `lang_check_coll_compat`이 이름 비교에서 먼저 실패했다. 그래서 바뀐 codeset이 codeset 비교까지 가지는 않았다. 오류 문구의 server/database 표기가 실제 값과 뒤바뀌어 보이는 것은 `lang_check_coll_compat`의 인자 순서 때문이며 이 이슈와 별개다.
- 같은 DB에 gdb 주입 없이 `csql -S`로 접속하면 정상 동작했다.

### Additional Information

- 관련 이슈: [CBRD-28091](https://jira.cubrid.org/browse/CBRD-28091)은 같은 함수의 `db_private_realloc` 실패 검사 오류를 다룬다. 그 이슈의 조사에서 이 `coll_name` 복사 문제를 범위 밖으로 기록했다. 두 수정은 같은 함수를 고치므로 함께 처리할 수 있다.
- 같은 함수의 `checksum` 복사(`src/storage/catalog_class.c:5447-5453`)는 `checksum[32 + 1]`에 최대 32자를 쓰도록 `assert (str_len == 32)`에 기대지만, release 빌드에서 32자를 넘는 값을 자르지 않는다. 컬럼이 `varchar(32)`라 현재는 넘지 않는다. 같은 방식으로 정리할지는 ANALYSIS에서 판단한다.
- ANALYSIS 확인 사항: 32자 콜레이션 이름이 `_db_collation`에 들어갈 수 있는 경로(이전 버전 DB의 마이그레이션, 카탈로그 손상, `COLL_NAME_SIZE`나 컬럼 길이 변경)가 있는지 확인하지 않았다. 경로가 없다면 이 결함은 방어적 수정이며, 우선순위 판단에 반영할 수 있다.
