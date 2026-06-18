# [OOS] 컬럼별 OOS 회피 우선순위를 SQL 로 지정 (STORAGE PREFER_INLINE)

## Issue Triage

**이슈 수행 목적**: 사용자가 `CREATE TABLE` / `ALTER TABLE` 에서 특정 컬럼에 `STORAGE PREFER_INLINE` 을 지정할 수 있게 한다. 이 옵션을 붙인 컬럼은 OOS(Out-of-row Storage — heap 레코드의 큰 가변 컬럼을 별도 OOS 파일로 분리하는 저장 방식)로 빠지는 우선순위가 낮아져, 가능하면 heap 레코드 안에 인라인으로 남는다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: heap 레코드의 디스크 레이아웃을 확정하는 함수 `heap_attrinfo_determine_disk_layout`(`heap_file.c:12097`) 는, 레코드 총 길이가 `DB_PAGESIZE/4`(16KB 페이지에서 4KB)를 넘으면 OOS 후보 가변 컬럼을 크기 내림차순으로만 정렬해(`heap_file.c:12136`, `std::greater`) 큰 것부터 하나씩 OOS 로 demote(인라인 값을 OOS 파일로 떼어내는 동작) 한다. 고르는 기준이 "크기" 하나뿐이라, 특정 컬럼을 인라인에 남기고 싶다는 의사를 사용자가 표현할 길이 없다.
- **영향**: 설계상의 한계다. 자주 읽는 컬럼이라도 크기만 크면 가장 먼저 OOS 로 빠지고, 그 컬럼을 읽을 때마다 `oos_read`(OOS 파일에서 값을 가져오는 추가 디스크 읽기) 비용이 든다. PostgreSQL TOAST 의 `SET STORAGE MAIN`("가능하면 인라인 유지")에 해당하는 수단이 없어, 자주 읽는(hot) 컬럼을 OOS 로부터 보호할 방법이 없다.

**이슈 수행 방안**:

- 컬럼 옵션 `STORAGE PREFER_INLINE | DEFAULT` 를 추가한다. 옵션을 생략하면 `DEFAULT` 와 같고(현행 크기순 동작), `CREATE TABLE` 컬럼 정의와 `ALTER TABLE MODIFY/CHANGE` 에 똑같이 적용된다(둘 다 `attr_def_one` 규칙을 공유). 저장은 `INVISIBLE` 선례의 플래그 비트 1개(`SM_ATTFLAG_OOS_PREFER_INLINE`)를 그대로 따르며 카탈로그 디스크 포맷은 바뀌지 않는다.
- 동작은 전부 soft 다. `PREFER_INLINE` 컬럼은 demote 후보 정렬에서 맨 뒤로 밀려, 다른 후보를 모두 OOS 로 보내고도 레코드가 `DB_PAGESIZE/4` 안에 못 들어올 때에만 마지막 수단으로 demote 된다. "레코드는 항상 페이지에 들어간다"는 기존 불변식은 그대로 유지된다.
- OOS 대상이 될 수 없는 자리에는 에러로 거부한다(2026-06-18 결정): 진짜 고정 타입 컬럼과 뷰(VCLASS) 컬럼. 거부 기준은 `pr_is_variable_type()` 이며, `CHAR` 는 `CBRD-26663`(CHAR/VARCHAR 가변 길이 통합) 이후 가변 타입이라 허용된다.
- 이번 범위 제외(후속 이슈로 분리): hard 강제(컬럼을 절대 OOS 로 안 보냄). hard 는 컬럼을 OOS 후보에서 아예 빼버려, 레코드가 페이지를 넘으면 기존 overflow page 경로로 가므로 overflow 와 OOS 의 동시 동작을 따로 검증해야 한다. (사용자 인용: "DEFAULT == OOS 인 것으로 하자. PREFER_INLINE / DEFAULT (OOS)", "될 수 있으면 안 보내겠다는 의지를 표명할 수 있어야 해".)

---

## AI-Generated Context

> 아래 내용은 AI 가 코드와 맥락을 분석하여 정리한 상세 자료입니다. 빠르게 triage 만 하실 때는 위 **Issue Triage** 블록만 보셔도 충분하며, 본문은 구현이나 리뷰 단계에서 참고하시면 됩니다.

### Summary

- **문제 / 목적**: OOS demotion 이 컬럼을 크기순으로만 고르기 때문에, "이 컬럼은 인라인에 유지하라"고 지정할 수단이 없다. 컬럼 단위의 SQL 힌트를 추가한다.
- **원인 / 배경**: `heap_attrinfo_determine_disk_layout` 의 후보 정렬 키가 `{크기, attr index}` 뿐이라(`heap_file.c:12136`), 워크로드의 의도가 끼어들 여지가 없다.
- **제안 / 변경**: `STORAGE PREFER_INLINE` 컬럼 옵션을 추가한다. 정렬에 우선순위 1차 키를 더해 PREFER_INLINE 컬럼을 후보 맨 뒤로 보낸다(soft). 플래그 1비트로 저장한다.
- **영향 범위**: 파서(`csql_grammar.y`, `csql_lexer.l`, `keyword.c`, `parse_tree*.c`, `semantic_check.c`), 스키마(`storage_common.h`, `execute_schema.c`, `class_object.c`), 디스크 표현(`object_representation_sr.*`), heap demotion(`heap_file.c`). 카탈로그 disk 포맷과 시스템 테이블 컬럼은 바뀌지 않으며, 기존 테이블/데이터와 하위 호환된다(플래그를 설정하지 않으면 현행과 동일).

---

## Description

### 배경 - OOS 가 무엇을 하는가

CUBRID 는 한 행(row)을 하나의 heap 레코드로 디스크에 저장하고, 레코드는 고정 크기 단위인 페이지(`DB_PAGESIZE`, 보통 16KB) 안에 담긴다. 레코드가 커지면 작은 컬럼 하나를 읽을 때도 큰 덩어리를 통째로 읽어야 해서 불필요한 디스크 I/O 가 생긴다. OOS 는 이때 큰 가변 컬럼의 값을 별도의 OOS 파일로 떼어내고(demote), 레코드에는 그 값을 가리키는 16바이트 OOS OID(`volid + pageid + slotid + full_length`)만 남긴다. 그러면 작은 컬럼만 읽을 때 큰 값을 건드리지 않아 빨라진다. 값이 레코드 안에 그대로 있는 상태를 "인라인", OOS 파일로 떼어낸 상태를 "OOS" 라고 부른다.

어떤 컬럼을 떼어낼지는 `heap_attrinfo_determine_disk_layout`(`heap_file.c:12097`) 가 정한다.

### 현재 정책 - 크기순 demote

현재 동작은 단순하다.

1. **레코드 게이트**: 레코드 총 길이(`header + payload + mvcc_extra`)가 `DB_PAGESIZE/4` 이하면 아무것도 떼지 않고 전부 인라인으로 둔다.
2. **후보 자격**: 가변 컬럼이면서 값 크기가 `OR_OOS_INLINE_SIZE`(16바이트, demote 후 자리에 들어가는 OOS OID 크기)보다 큰 컬럼만 후보다. 16바이트 이하면 떼봤자 레코드가 줄지 않으므로 제외한다.
3. **크기순 루프**: 후보를 크기 내림차순으로 정렬해, 레코드가 `DB_PAGESIZE/4` 이하로 줄 때까지 큰 컬럼부터 하나씩 OOS 로 보낸다.

### 문제 - 고를 기준이 크기뿐이다

이 선택은 오직 크기에만 의존한다. 예를 들어 자주 조회하는 4KB 프로파일 컬럼과 거의 읽지 않는 3KB 로그 컬럼이 한 레코드에 있으면, 더 큰 프로파일 컬럼이 먼저 OOS 로 빠진다. 그 결과 자주 읽는 컬럼을 조회할 때마다 `oos_read` 비용을 치른다. 사용자는 "이 컬럼은 가능하면 인라인에 둬 달라"는 의사를 SQL 로 표현할 방법이 전혀 없다.

### 제안 - PostgreSQL TOAST 의 MAIN 에 대응하는 힌트

이 이슈는 PostgreSQL TOAST 의 `ALTER TABLE ... SET STORAGE MAIN`(가능한 한 인라인 유지)에 대응하는 컬럼 옵션을 추가한다. 다만 PostgreSQL 의 `STORAGE` 에는 압축 의미가 함께 들어 있는데(CUBRID OOS 에는 압축 개념이 없다 — 압축은 타입 계층의 별도 기능이다), 그래서 PostgreSQL 의 네 값(PLAIN/EXTERNAL/EXTENDED/MAIN)을 그대로 가져오지 않고 OOS demote 우선순위에만 한정한 두 값으로 정의한다.

### 동작 정의 (전부 soft)

demote 는 레코드가 `DB_PAGESIZE/4` 를 넘을 때만 일어난다. `PREFER_INLINE` 은 "demote 를 할지 말지"가 아니라 "demote 한다면 어떤 컬럼부터 할지"의 순서만 바꾼다.

- `STORAGE DEFAULT`(또는 옵션 생략): 현행대로 크기 내림차순으로 처리한다.
- `STORAGE PREFER_INLINE`: 해당 컬럼을 후보 정렬의 맨 뒤로 보낸다. 다른 후보를 모두 OOS 로 보내고도 레코드가 `DB_PAGESIZE/4` 안에 안 들어오면, 그제야 마지막 수단으로 이 컬럼을 demote 한다.

이 방식이 soft 인 이유는 PREFER_INLINE 컬럼도 끝까지 후보로 남아 있기 때문이다. 덕분에 "레코드는 항상 페이지에 들어간다"는 기존 OOS 불변식이 깨지지 않는다.

### soft 방식의 한계 (의도된 범위)

PREFER_INLINE 은 순서만 바꾸므로, 다음 세 가지를 분명히 해 둔다.

- **떼어낼 다른 컬럼이 없으면 효과가 없다.** 큰 가변 컬럼이 하나뿐인 레코드에서 그 컬럼에 PREFER_INLINE 을 걸어도, 레코드가 `DB_PAGESIZE/4` 를 넘으면 결국 그 컬럼이 OOS 로 간다 — 대신 내보낼 컬럼이 없기 때문이다. 단일 hot 컬럼을 무슨 일이 있어도 인라인에 고정하려면 hard 강제가 필요한데, 이는 overflow page 와의 상호작용 검증이 따로 필요해 이번 범위에서 제외한다.
- **모든 가변 컬럼이 PREFER_INLINE 이면 DEFAULT 와 같다.** 후보가 전부 같은 우선순위(맨 뒤)에 모이면 그들끼리는 다시 크기순으로 정렬되므로, 결과가 현행 크기순과 동일해진다. 즉 힌트는 일부 컬럼만 PREFER_INLINE 이고 나머지는 DEFAULT 일 때에만 의미가 있다.
- **공짜 이득이 아니라 비용의 이동이다.** hot 컬럼을 보호하면 그만큼 다른 컬럼이 대신 OOS 로 가서, 그 컬럼을 읽을 때 `oos_read` I/O 가 그쪽으로 옮겨간다. 보호하려는 컬럼이 다른 컬럼보다 자주 읽힐 때에만 전체적으로 이득이다.

## Specification Changes

새 SQL 구문과 키워드가 추가되므로 QA 와 매뉴얼을 갱신해야 한다.

### 새 컬럼 옵션 구문

```sql
-- CREATE TABLE 컬럼 정의
CREATE TABLE t (
  id       INT,
  payload  VARCHAR(4096) STORAGE PREFER_INLINE,  -- OOS 후순위 (인라인 우선)
  logs     BIT VARYING   STORAGE DEFAULT          -- 현행 동작 (생략과 동일)
);

-- ALTER TABLE 로 변경 (MODIFY / CHANGE 모두 가능)
ALTER TABLE t MODIFY payload VARCHAR(4096) STORAGE DEFAULT;
ALTER TABLE t MODIFY logs    BIT VARYING   STORAGE PREFER_INLINE;
```

- 옵션을 생략하면 `STORAGE DEFAULT` 와 동일하다.
- `STORAGE` 와 `PREFER_INLINE` 은 새 비예약(non-reserved) 키워드로 추가한다. `storage` 를 이미 식별자(테이블/컬럼명)로 쓰던 스키마가 깨지지 않도록 `identifier` 규칙에 echo 항목을 넣는다. `DEFAULT` 는 이미 예약어라 그 토큰을 재사용한다.

### OOS 대상이 아닌 자리에서의 거부 (2026-06-18 결정)

힌트가 무의미한 자리에 붙는 것을 명시적으로 막는다. PostgreSQL 은 이 경우 조용히 무시하지만, CUBRID 는 에러를 낸다. 거부 기준은 "값이 OOS 로 빠질 수 있는 컬럼인가" 이고, 정확한 술어는 `pr_is_variable_type()` 이다(런타임 demote 가 보는 `OR_ATTRIBUTE.is_fixed` 와 같은 기준).

- **고정 타입 컬럼**: `INT`, `NUMERIC`, `DATE` 같은 진짜 고정 타입에 지정하면 거부한다. 단, `CHAR` 는 `CBRD-26663`(CHAR/VARCHAR 가변 길이 통합) 이후 가변 타입(`tp_Char.variable_p = 1`)이라 `VARCHAR`/`BIT VARYING`/`STRING` 과 함께 허용된다. 거부 대상을 손으로 나열하지 말고 `pr_is_variable_type()` 술어를 그대로 쓴다.
- **뷰(VCLASS) 컬럼**: 뷰는 heap/OOS 저장 자체가 없으므로 거부한다. `INVISIBLE` 이 뷰에서 `MSGCAT_SEMANTIC_VCLASS_ATT_CANT_SET_VISIBILITY` 로 막는 것과 같은 지점(`semantic_check.c:4894`, `:8722`)을 따른다.
- **미지원 STORAGE 값**: `STORAGE EXTENDED` 등 PostgreSQL 토큰은 지원하지 않는다. 맨몸 `syntax error` 대신 "`DEFAULT`/`PREFER_INLINE` 만 지원" 을 알려 주는 읽기 쉬운 에러가 바람직하다.

### ALTER 의 적용 시점 (사용자 가시 동작)

`ALTER ... STORAGE PREFER_INLINE` 은 **그 이후의 INSERT/UPDATE 부터** 적용된다. 이미 OOS 로 나가 있는 기존 값은 ALTER 만으로 인라인으로 돌아오지 않는다(PostgreSQL `SET STORAGE` 와 동일). 기존 데이터를 곧바로 재배치하려면 해당 행을 다시 쓰거나 테이블을 재구성해야 한다(소급 재배치는 후속 이슈).

`ALTER ... MODIFY` 에서 `STORAGE` 절을 **생략하면 기존 힌트가 그대로 보존된다**(DEFAULT 로 초기화되지 않는다). PT 계층은 3상태 enum(UNSET/DEFAULT/PREFER_INLINE)을 쓰고, UNSET(절 생략)일 때 기존 플래그를 유지한다. 보존은 `build_attr_change_map` 이 담당한다 — UNSET 을 `ATT_CHG_PROPERTY_UNCHANGED` 로 표시하면 `do_change_att_schema_only` 가 `found_att->flags` 의 기존 비트를 건드리지 않는다(`INVISIBLE` 과 같은 change-map 방식). 명시적으로 되돌리려면 `STORAGE DEFAULT` 를 적는다.

### 스키마 덤프 라운드트립

`SHOW CREATE TABLE` 과 unloaddb 스키마 덤프가 이 힌트를 다시 출력해 줘야 loaddb 재적재 시 보존된다. 따라서 `pt_print_attr_def` 반영은 선택이 아니라 필수다.

저장 계층은 단일 비트(`oos_prefer_inline`)만 쓰므로 `STORAGE DEFAULT` 와 "절 생략" 은 모두 비트 0 으로 같은 상태가 된다(의도된 동작 — 두 경우는 의미가 같다). 그래서 프린터는 비트가 1 일 때만 `STORAGE PREFER_INLINE` 을 출력하고, DEFAULT 나 생략은 아무것도 출력하지 않는다. 즉 사용자가 직접 적은 `STORAGE DEFAULT` 문구는 그대로 다시 나오지 않으며, 라운드트립으로 보존되는 대상은 PREFER_INLINE 뿐이다.

## Implementation

`INVISIBLE` 컬럼 옵션이 "PT 노드 -> `SM_ATTRIBUTE.flags` 비트 -> `OR_ATTRIBUTE` 비트필드" 라는 똑같은 경로를 이미 거치므로 그 선례를 따른다.

### 데이터 흐름

```
[파서]  STORAGE PREFER_INLINE
   csql_grammar.y: column_storage_def 규칙
      -> PT_ATTR_DEF.info.attr_def.attr_storage = PT_ATTR_STORAGE_PREFER_INLINE
[스키마] execute_schema.c (INVISIBLE 가 att->flags 를 세우는 자리, :8192 부근)
      -> att->flags |= SM_ATTFLAG_OOS_PREFER_INLINE        (storage_common.h, 0x1000)
[직렬화] transform_cl.c:2976 쓰기 / :3113 클라이언트 읽기 (기존 코드, 둘 다 수정 불필요)
[복원]   object_representation_sr.c:2505 부근 (서버측, heap 이 쓰는 경로)
      -> att->oos_prefer_inline = (flags & SM_ATTFLAG_OOS_PREFER_INLINE) ? 1 : 0
                                                            (OR_ATTRIBUTE 신규 비트필드)
[소비]   heap_file.c:12097 heap_attrinfo_determine_disk_layout
      (!) 후보 정렬 1차 키에 prefer_inline 추가 -> PREFER_INLINE 컬럼을 맨 뒤로
```

`(!)` 로 표시한 곳이 실제 정책이 바뀌는 유일한 지점이다. 나머지는 플래그를 끝까지 실어 나르는 배선일 뿐이다. 직렬화 라운드트립은 검증됐다: `transform_cl.c` 가 `or_put_int(buf, att->flags)` 로 `flags` 정수 전체를 쓰고 같은 방식으로 읽어, 0x1000 비트가 flush/재기동 후에도 살아남는다.

### 변경 파일 목록

| File | Change |
|------|--------|
| `src/parser/csql_grammar.y` | `%token <cptr> STORAGE` `%token <cptr> PREFER_INLINE` 추가. `COLUMN_CONSTRAINT_STORAGE (0x400)` define(현재 최대 `COLUMN_CONSTRAINT_INVISIBLE 0x200`). `column_constraint_and_comment_def`(:10110) 에 `column_storage_def` 추가. 규칙 모양은 `column_comment_def`(:10640), 플래그 배선은 `column_invisible_def`(:10596) 선례를 따른다. `identifier` 규칙에 `STORAGE`/`PREFER_INLINE` echo 추가(빠뜨리면 `storage` 식별자 스키마가 깨진다). `attr_def_one`(:9961) 중복-옵션 마스크 처리. |
| `src/parser/keyword.c` | `{STORAGE, "STORAGE", 1}`, `{PREFER_INLINE, "PREFER_INLINE", 1}` (세 번째 인자 1 = 비예약). `pt_is_reserved_word` 판정 테이블. |
| `src/parser/csql_lexer.l` | 키워드별 flex 규칙 추가(필수). 렉서의 일반 식별자 규칙은 무조건 `IdName` 을 반환하므로, `[sS][tT][oO][rR][aA][gG][eE] { ...; return STORAGE; }` 같은 규칙이 있어야 토큰이 생긴다. `INVISIBLE` 규칙을 본떠 추가하고, `<cptr>` 토큰이라 `csql_yylval.cptr = pt_makename(yytext)` 를 설정한다. 빠뜨리면 문법/keyword.c 가 맞아도 `STORAGE` 가 식별자로 렉싱되어 파싱이 실패한다. |
| `src/parser/parse_tree.h` | `PT_ATTR_STORAGE_SETTING` enum(UNSET/DEFAULT/PREFER_INLINE) 추가. `pt_attr_def_info`(:1927) 에 `attr_storage:2` 비트필드 추가(`attr_invisible:2` 와 동일 패턴, 기본 UNSET). |
| `src/parser/parse_tree_cl.c` | `pt_print_attr_def`(:6715, INVISIBLE 출력 블록 :6851 옆)에 PREFER_INLINE 출력 블록 추가(라운드트립 필수). |
| `src/parser/semantic_check.c` | 검증(신규 — 현재 미구현 갭): (a) 뷰(VCLASS) 컬럼 지정 거부, (b) `pr_is_variable_type()` 이 아닌 고정 타입 컬럼 지정 거부, (c) `STORAGE` 뒤에 `DEFAULT`/`PREFER_INLINE` 외 토큰이 올 때 읽기 쉬운 에러. `:4894`/`:8722` 는 `INVISIBLE` 의 VCLASS 거부 선례다(예전 표기 "UNSET 보존" 은 오기 — UNSET 보존은 `build_attr_change_map` 담당). |
| `src/storage/storage_common.h` | `SM_ATTFLAG_OOS_PREFER_INLINE = 4096` 추가(:1086 다음, 현재 최대 `SM_ATTFLAG_INVISIBLE_COLUMN = 2048`). |
| `src/query/execute_schema.c` | PT `attr_storage` 값을 `att->flags |= SM_ATTFLAG_OOS_PREFER_INLINE` 로 반영(INVISIBLE 의 :8192 / ALTER 경로 :11685-11689 패턴). |
| `src/object/class_object.c` | 필요 시 플래그 복사 경로 보강(INVISIBLE 의 :6614 패턴). |
| `src/base/object_representation_sr.h` | `OR_ATTRIBUTE`(:89) 에 `unsigned oos_prefer_inline:1;` 추가(`is_invisible:1` 옆). 생성자 memset 범위라 0 으로 자동 초기화. |
| `src/base/object_representation_sr.c` | `or_get_current_representation`(:2505 부근)에서 플래그 비트를 `oos_prefer_inline` 로 복원하는 한 줄. |

### 정렬 키 변경 (핵심)

현재 (`heap_file.c:12122`, `:12136`):

```cpp
std::vector<std::pair<int, int>> oos_candidates;  /* {column_size, attr index} */
...
std::sort (oos_candidates.begin (), oos_candidates.end (), std::greater<std::pair<int, int>> ());
```

변경 후 — 후보에 `prefer_inline` 플래그를 함께 담고 이를 1차 정렬 키로 쓴다:

```cpp
struct oos_cand { int prefer_inline; int size; int idx; };  /* prefer_inline: 0=일반, 1=후순위 */
std::vector<oos_cand> oos_candidates;
...
if (!attr_info->values[i].last_attrepr->is_fixed && column_size[i] > OR_OOS_INLINE_SIZE)
  {
    int pi = attr_info->values[i].last_attrepr->oos_prefer_inline ? 1 : 0;
    oos_candidates.push_back ({ pi, column_size[i], i });
  }
...
std::sort (oos_candidates.begin (), oos_candidates.end (),
           [](const oos_cand &a, const oos_cand &b) {
             if (a.prefer_inline != b.prefer_inline)
               return a.prefer_inline < b.prefer_inline;  /* 일반(0) 먼저, 후순위(1) 뒤로 */
             if (a.size != b.size)
               return a.size > b.size;                     /* 같은 등급 안에서는 큰 것 먼저 */
             return a.idx > b.idx;                          /* 크기 동률이면 idx 내림차순 */
           });
```

`idx` 내림차순 tiebreak 는 반드시 필요하다. 현재 코드의 `std::greater<std::pair<int,int>>` 는 `{크기, idx}` 쌍을 크기, idx 순으로 비교해 크기가 같아도 결정적 순서를 보장한다. 그런데 `std::sort` 는 stable 정렬이 아니어서 idx 키를 빼면 크기가 같은 두 컬럼의 demote 순서가 빌드/STL 버전에 따라 달라지고 회귀 테스트가 flaky 해진다. idx 키를 넣으면 PREFER_INLINE 미지정(DEFAULT) 컬럼만 있을 때의 정렬 순서가 현행과 비트 단위로 동일해진다(회귀 없음).

demote 루프(`:12140-12151`)와 후보 자격 필터(`:12129`)는 그대로 둔다. PREFER_INLINE 컬럼도 후보로 남으므로(soft), 다른 후보를 다 써버리고도 레코드가 안 맞으면 결국 이 컬럼도 demote 된다.

### 키워드 비예약 처리 주의

`STORAGE` 는 흔한 식별자라 비예약으로 등록하되 `identifier` 규칙에 echo 를 반드시 넣어야 한다. 빠뜨리면 `CREATE TABLE storage (...)` 같은 기존 스키마가 깨진다. `COMMENT` 와 `INVISIBLE` 도 같은 방식으로 식별자 충돌을 피한다.

## Acceptance Criteria

- [ ] `CREATE TABLE ... (col VARCHAR(N) STORAGE PREFER_INLINE)` 가 정상 파싱/생성되고, 같은 구문이 `ALTER TABLE ... MODIFY` 에서도 동작한다.
- [ ] `SHOW CREATE TABLE` 출력에 `STORAGE PREFER_INLINE` 이 다시 나타나고 덤프 후 재적재(loaddb)에도 보존된다(PREFER_INLINE 만 해당 — DEFAULT/생략은 출력되지 않는다. 위 라운드트립 절 참고).
- [ ] **값 정합성**: PREFER_INLINE 컬럼을 조회했을 때 원본 값과 일치한다(인라인이든 OOS 든 값은 같다). 압축 대상이 아닌 `BIT VARYING` 으로 검증한다:
  ```sql
  CREATE TABLE t (id INT, hot BIT VARYING STORAGE PREFER_INLINE, cold BIT VARYING);
  INSERT INTO t VALUES (1, CAST(REPEAT('AA', 1500) AS BIT VARYING),
                           CAST(REPEAT('BB', 1500) AS BIT VARYING));
  SELECT (hot = CAST(REPEAT('AA', 1500) AS BIT VARYING)) FROM t WHERE id = 1;  -- 1 기대
  ```
- [ ] **배치(placement) 확인 (discriminating test)**: PREFER_INLINE 가 demote 순서를 실제로 바꾸는지는, **더 큰** 컬럼을 PREFER_INLINE 으로 보호해 **더 작은** 컬럼이 대신 OOS 로 가도록 만들어 확인한다(크기순 기본 정책과 정반대 결과). `DISK_SIZE()` 는 논리적 값 크기만 돌려줘 OOS 여부를 구분하지 못하므로, debug 빌드의 `$CUBRID/log/oos.log` 에 찍히는 `oos_insert ... src.size=` 로 어느 컬럼이 demote 됐는지 확인한다(release 빌드에는 컬럼별 OOS 가시성이 없다 — CBRD-26871):
  ```sql
  CREATE TABLE demo  (id INT, hot BIT VARYING STORAGE PREFER_INLINE, cold BIT VARYING);
  CREATE TABLE demo2 (id INT, hot BIT VARYING,                       cold BIT VARYING);
  INSERT INTO demo  VALUES (1, CAST(REPEAT('AA',3000) AS BIT VARYING), CAST(REPEAT('BB',2000) AS BIT VARYING));
  INSERT INTO demo2 VALUES (1, CAST(REPEAT('AA',3000) AS BIT VARYING), CAST(REPEAT('BB',2000) AS BIT VARYING));
  -- oos.log: demo 는 src.size~=2000 (작은 cold demote, hot 보호), demo2 는 src.size~=3000 (큰 hot demote, 크기순)
  ```
- [ ] **soft 불변식**: PREFER_INLINE 컬럼만 남아 레코드가 페이지에 안 맞으면, 그 컬럼도 결국 OOS 로 demote 되어 INSERT 가 실패하지 않는다.
- [ ] **회귀 없음**: 플래그 미설정(기존 테이블 / `STORAGE DEFAULT`) 시 demote 결과가 현행과 동일하다(크기가 같은 컬럼의 demote 순서까지 — 위 idx tiebreak 참고).
- [ ] **고정 타입 거부**: 진짜 고정 타입 컬럼(예: `INT`)에 지정하면 에러로 거부된다. `CHAR` 는 `CBRD-26663` 이후 가변 타입이라 허용된다(거부 기준 = `!pr_is_variable_type()`).
- [ ] **뷰 거부**: 뷰(VCLASS) 컬럼에 지정하면 `INVISIBLE` 과 같은 방식으로 거부된다.
- [ ] **미지원 STORAGE 값**: `STORAGE EXTENDED` 등은 맨몸 `syntax error` 가 아니라 "`DEFAULT`/`PREFER_INLINE` 만 지원" 을 알려 주는 읽기 쉬운 에러를 낸다.

## Definition of done

- [ ] 위 Acceptance Criteria 를 모두 충족한다.
- [ ] 기존 OOS 회귀 테스트(insert/select/update/delete, 크래시 복구, 복제)를 통과한다.
- [ ] QA 를 통과한다.
- [ ] SQL 매뉴얼에 `STORAGE` 컬럼 옵션과 ALTER 적용 시점 주의사항을 반영한다. 특히 PostgreSQL 과의 차이를 명시한다: CUBRID `STORAGE` 는 OOS demote 우선순위만 제어하며 PLAIN/EXTERNAL/EXTENDED/MAIN 이나 압축 의미는 없고 지원 값은 `DEFAULT`/`PREFER_INLINE` 뿐이다.

## Open Questions

1. **catalog `_db_attribute.flags` 노출 여부**: 런타임 기능에는 필요 없다. 사용자가 `_db_attribute` 에서 이 힌트를 조회하게 하려면 `catcls_filter_attflag`(`src/storage/catalog_class.c:5846`, INVISIBLE 매핑은 :5851)에 매핑을 추가하고 `DB_ATTRIBUTE_OPTION_TYPE`(`src/compat/dbtype_def.h:481-486`)에 `DB_ATTOPT_OOS_PREFER_INLINE` 멤버를 추가해야 한다. 플래그 기본값이 0 이라 기존 행과 DEFAULT 컬럼의 `_db_attribute.flags` 는 그대로 유지되므로 노출하지 않아도 회귀는 없다. **결정(2026-06-18): 이번 범위에서는 노출하지 않는다(defer).** `SHOW CREATE TABLE` 라운드트립으로 힌트가 보존되고, QA 의 배치 검증은 `oos.log` 를 쓰므로(CBRD-26871) 카탈로그 노출이 없어도 충분하다. 기본값 0 이라 나중에 무중단으로 추가 가능하다.

## 참고 코드

- `src/storage/heap_file.c:12097` - `heap_attrinfo_determine_disk_layout` (demote 정책, 유일한 정책 변경 지점)
- `src/base/object_representation.h:455` - `OR_OOS_INLINE_SIZE` (= `OR_OID_SIZE + OR_BIGINT_SIZE`, 16바이트)
- `src/base/object_representation_sr.h:89` - `OR_ATTRIBUTE` (런타임 컬럼 표현, 비트필드 `is_invisible` 등)
- `src/storage/storage_common.h:1072` - `SM_ATTRIBUTE_FLAG` (다음 빈 비트 0x1000)
- `src/parser/csql_grammar.y:10110` - `column_constraint_and_comment_def` (옵션 목록), `:10596` `column_invisible_def`(선례)
- `src/query/execute_schema.c:8192` - INVISIBLE 가 `att->flags` 를 세우는 선례
- `src/object/object_primitive.c` - `pr_is_variable_type` (가변/고정 타입 판정 — 거부 검증 기준)

## Remarks

- 후속 이슈로 분리: (a) hard 강제(`FORCE_INLINE` 등, 컬럼을 절대 OOS 로 안 보냄 — overflow page 상호작용 검증 필요), (b) ALTER 시 기존 데이터 소급 재배치, (c) 통계/접근 빈도 기반 자동 demote.
- 이슈 타입: Improve (Function/Performance). 대상 브랜치: `feat/oos` (11.5.x 베이스, OOS 기능 릴리스와 함께 반영, 정확한 Fix Version 미정).
- OOS-CONTEXT 문서의 옛 임계치(`DB_PAGESIZE/8`, 512B)는 폐기된 값이며, 실제 코드는 `DB_PAGESIZE/4` 와 `OR_OOS_INLINE_SIZE`(16B)를 쓴다.
