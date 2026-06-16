# [OOS] 컬럼별 OOS 회피 우선순위 SQL 지정 (STORAGE PREFER_INLINE)

## Issue Triage

**이슈 수행 목적**: 사용자가 CREATE TABLE / ALTER TABLE 에서 특정 컬럼에 `STORAGE PREFER_INLINE` 을 지정해, 그 컬럼이 OOS(Out-of-row Storage - heap 레코드의 큰 가변 컬럼을 별도 OOS 파일로 분리하는 저장 방식) 로 빠지는 우선순위를 낮추고 될 수 있으면 heap 레코드 안에 인라인으로 유지하도록 한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: heap 레코드를 디스크 레이아웃으로 굳히는 `heap_attrinfo_determine_disk_layout` (`heap_file.c:12097`) 은, 레코드 총 길이가 `DB_PAGESIZE/4` (16KB 페이지 기준 4KB) 를 넘으면 OOS 후보 가변 컬럼을 크기 내림차순으로만 정렬(`heap_file.c:12136`, `std::greater`)해 큰 것부터 하나씩 OOS 로 demote 한다. 즉 컬럼 선택 기준이 오직 "크기" 뿐이고, 어떤 컬럼을 인라인에 붙잡아 두라고 사용자가 표현할 수단이 전혀 없다.
- **영향**: 설계 의도 한계 - 자주 읽는 컬럼이라도 단지 상대적으로 크다는 이유만으로 가장 먼저 OOS 로 빠지고, 그 컬럼을 읽을 때마다 `oos_read` 추가 I/O 가 발생한다. PostgreSQL TOAST 의 `SET STORAGE MAIN` 같은 "이 컬럼은 인라인 우선" 제어가 없어, 사용자가 핫(hot) 컬럼을 OOS 로부터 보호할 방법이 없다.

**이슈 수행 방안**:

- 컬럼 옵션 `STORAGE PREFER_INLINE | DEFAULT` 를 추가한다. 절을 생략하면 `DEFAULT` 와 동일(현행 크기순 동작). CREATE TABLE 컬럼 정의와 ALTER TABLE MODIFY/CHANGE 에 동일하게 적용된다 (둘 다 `attr_def_one` 규칙 공유).
- 강도는 전부 soft 다. `PREFER_INLINE` 컬럼을 demote 후보 정렬의 맨 뒤로 보내, 다른 컬럼을 모두 OOS 로 보내도 레코드가 `DB_PAGESIZE/4` 를 못 맞출 때만 마지막 수단으로 demote 한다. 레코드가 항상 페이지에 들어가는 기존 불변식을 깨지 않는다.
- 저장은 `INVISIBLE` 컬럼 선례와 동일한 플래그 비트 경로를 그대로 쓴다: `SM_ATTRIBUTE.flags` 신규 비트 `SM_ATTFLAG_OOS_PREFER_INLINE` (0x1000) -> 기존대로 통째 직렬화(transform 계층 변경 불필요) -> `OR_ATTRIBUTE` 신규 비트필드 `oos_prefer_inline:1` -> `heap_file.c` demote 정렬에서 소비. 카탈로그 테이블 스키마 변경은 없다.
- 범위 밖 (별도 후속 이슈): hard 강제(절대 OOS 금지 / 작아도 무조건 OOS). hard 는 OOS 후보에서 컬럼을 완전히 빼므로 레코드가 페이지를 넘으면 기존 overflow page 경로로 떨어진다 - overflow x OOS 동시 동작 검증이 필요해 분리한다. 사용자 인용: "DEFAULT == OOS 인 것으로 하자. PREFER_INLINE / DEFAULT (OOS)", "될 수 있으면 안 보내겠다는 의지를 표명할 수 있어야 해".

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료입니다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하시면 됩니다.

### Summary

- **문제 / 목적**: OOS demotion 이 크기순으로만 컬럼을 고르므로, 사용자가 특정 컬럼을 인라인에 유지하라고 지정할 수단이 없다. 컬럼 단위 SQL 힌트를 추가한다.
- **원인 / 배경**: `heap_attrinfo_determine_disk_layout` 의 후보 정렬이 `{크기, attr index}` 단일 키(`heap_file.c:12136`)라, 워크로드 의도가 반영될 여지가 없다.
- **제안 / 변경**: `STORAGE PREFER_INLINE` 컬럼 옵션 추가. 정렬에 우선순위 1차 키를 더해 PREFER_INLINE 컬럼을 후보 맨 뒤로 보낸다(soft). 플래그 1비트로 저장.
- **영향 범위**: 파서(`csql_grammar.y`, `keyword.c`, `parse_tree*.c`), 스키마(`storage_common.h`, `execute_schema.c`, `class_object.c`), 디스크 표현(`object_representation_sr.*`), heap demotion(`heap_file.c`). 카탈로그 disk 포맷/시스템 테이블 컬럼 변경 없음. 기존 테이블/데이터와 하위 호환(플래그 미설정 = 현행 동작).

---

## Description

CUBRID OOS 는 heap 레코드가 커지면 큰 가변 컬럼을 OOS 파일로 분리해, 작은 컬럼만 읽을 때 불필요한 디스크 I/O 를 줄인다. 어떤 컬럼을 분리할지는 `heap_attrinfo_determine_disk_layout` 가 정한다.

현재 정책은 단순하다. 레코드 총 길이(`header + payload + mvcc_extra`)가 `DB_PAGESIZE/4` 를 넘으면, OOS 후보(가변이면서 값 크기 > `OR_OOS_INLINE_SIZE` = 16바이트)를 모아 **크기 내림차순**으로 정렬한 뒤, 레코드가 `DB_PAGESIZE/4` 이하가 될 때까지 큰 것부터 하나씩 OOS 로 보낸다.

문제는 이 선택이 오직 크기에만 의존한다는 점이다. 예를 들어 자주 조회하는 4KB 프로파일 컬럼과 거의 안 읽는 3KB 로그 컬럼이 한 레코드에 있으면, 더 큰 프로파일 컬럼이 먼저 OOS 로 빠져 매 조회마다 `oos_read` 비용을 문다. 사용자는 "이 컬럼은 될 수 있으면 인라인에 둬라" 는 의사를 SQL 로 전혀 표현할 수 없다.

이 이슈는 PostgreSQL TOAST 의 `ALTER TABLE ... SET STORAGE MAIN`(가능한 한 인라인 유지) 에 대응하는 컬럼 옵션을 CUBRID SQL 에 추가한다. 단, CUBRID OOS 에는 PostgreSQL STORAGE 가 함께 표현하는 압축 의미가 없으므로(압축은 타입 계층의 별도 기능), PostgreSQL 의 4값(PLAIN/EXTERNAL/EXTENDED/MAIN) 을 그대로 옮기지 않고 OOS demotion 우선순위에만 한정한 2값으로 정의한다.

### 동작 정의 (전부 soft)

demotion 은 레코드가 `DB_PAGESIZE/4` 를 넘을 때만 일어난다. `PREFER_INLINE` 은 "demote 할지 말지" 가 아니라 "demote 한다면 어떤 컬럼부터" 의 순서만 바꾼다.

- `STORAGE DEFAULT` (또는 절 생략): 현행 그대로. 크기 내림차순.
- `STORAGE PREFER_INLINE`: 해당 컬럼을 후보 정렬의 맨 뒤로 보낸다. 다른 모든 후보를 OOS 로 보내도 레코드가 `DB_PAGESIZE/4` 를 못 맞추면, 그때 마지막 수단으로만 이 컬럼을 demote 한다.

soft 이므로 "레코드는 항상 페이지에 들어간다" 는 기존 OOS 불변식이 유지된다. PREFER_INLINE 컬럼도 끝까지 후보로 남기 때문이다.

### soft-only 의 한계 (의도된 범위)

PREFER_INLINE 은 순서만 바꾸므로, **demote 할 다른 컬럼이 없으면 효과가 없다.** 큰 가변 컬럼이 하나뿐인 레코드에서 그 컬럼을 PREFER_INLINE 으로 지정해도, 레코드가 `DB_PAGESIZE/4` 를 넘으면 결국 그 컬럼이 OOS 로 간다(대신 뺄 컬럼이 없으므로). 단일 핫 컬럼을 절대 인라인에 고정하려면 hard 강제가 필요하지만, hard 는 overflow page 와의 상호작용 검증이 필요해 이 이슈 범위 밖이다.

또한 이것은 워크로드 힌트이지 공짜 이득이 아니다. 핫 컬럼을 보호하면 그만큼 다른 컬럼 조회에 `oos_read` I/O 가 옮겨간다. 보호 대상이 다른 컬럼보다 자주 읽힐 때만 순이득이다.

## Specification Changes

QA/매뉴얼 갱신 필요. 새 SQL 구문과 키워드가 추가된다.

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

- 절을 생략하면 `STORAGE DEFAULT` 와 동일하다.
- `STORAGE` 와 `PREFER_INLINE` 은 신규 비예약(non-reserved) 키워드로 추가한다. 기존에 `storage` 를 식별자(테이블/컬럼명)로 쓰던 스키마가 깨지지 않도록 `identifier` 규칙에 echo 항목을 넣는다. `DEFAULT` 는 이미 예약어라 토큰을 재사용한다.
- 고정 길이 컬럼(예: `CHAR`, `INT`)에 지정해도 OOS 대상이 아니라 효과가 없다. 에러 없이 허용하고 플래그만 저장한다(PostgreSQL 의 무시 의미와 동일). demotion 후보는 가변 컬럼뿐이라 저장된 플래그가 소비되지 않으며, 이후 ALTER 로 가변 타입이 되면 자연히 적용된다.

### ALTER 의 적용 시점 (중요 - 사용자 가시 동작)

`ALTER ... STORAGE PREFER_INLINE` 은 **이후의 INSERT/UPDATE 부터** 적용된다. 이미 OOS 로 나간 기존 값은 ALTER 만으로 인라인으로 되돌아오지 않는다. 이는 PostgreSQL `SET STORAGE` 와 동일한 의미이며, 기존 데이터를 즉시 재배치하려면 해당 행을 다시 쓰거나 테이블을 재구성해야 한다. (소급 재배치는 후속 이슈.)

`ALTER ... MODIFY` 에서 `STORAGE` 절을 **생략하면 기존 힌트가 보존된다** (DEFAULT 로 리셋되지 않음). PT 계층은 3상태 enum(UNSET/DEFAULT/PREFER_INLINE)을 써서, UNSET(절 생략)일 때 기존 플래그를 유지한다 - `INVISIBLE` 의 UNSET 보존 처리(`semantic_check.c:4894`, `:8722`)와 동일. 명시적으로 되돌리려면 `STORAGE DEFAULT` 를 적는다.

### 스키마 덤프 라운드트립

`SHOW CREATE TABLE` 과 unloaddb 스키마 덤프가 이 힌트를 다시 출력해야 loaddb 재적재 시 보존된다. 따라서 `pt_print_attr_def` 반영은 선택이 아니라 필수다.

저장 계층은 단일 비트(`oos_prefer_inline`)라, `STORAGE DEFAULT` 와 "절 생략" 은 모두 비트 0 으로 같은 상태가 된다(의도된 동작 - 둘은 의미상 동일). 따라서 프린터는 비트 1 일 때만 `STORAGE PREFER_INLINE` 을 출력하고, DEFAULT/생략은 아무것도 출력하지 않는다. 즉 사용자가 적은 `STORAGE DEFAULT` 리터럴은 그대로 라운드트립되지 않으며, 라운드트립 보존 대상은 PREFER_INLINE 뿐이다.

## Implementation

`INVISIBLE` 컬럼 옵션이 동일한 "PT 노드 -> SM_ATTRIBUTE.flags 비트 -> OR_ATTRIBUTE 비트필드" 경로를 이미 밟고 있으므로, 그 선례를 그대로 따른다.

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

`(!)` 표시가 실제 정책이 바뀌는 유일한 지점이다. 나머지는 플래그를 끝까지 운반하는 배선이다.

### 변경 파일 목록

| 파일 | 변경 내용 |
|------|-----------|
| `src/parser/csql_grammar.y` | `%token <cptr> STORAGE` `%token <cptr> PREFER_INLINE` 추가. `COLUMN_CONSTRAINT_STORAGE (0x400)` define(현재 최대 `COLUMN_CONSTRAINT_INVISIBLE 0x200`). `column_constraint_and_comment_def`(:10110) 에 `column_storage_def` 추가. 새 규칙은 키워드+값 형태라 규칙 모양은 `column_comment_def`(:10640, `COMMENT comment_value`) 를 따르고, 플래그 배선은 `column_invisible_def`(:10596) 선례를 따른다. `identifier` 규칙(:20663 부근) 에 `STORAGE`/`PREFER_INLINE` echo 항목 추가(누락 시 `storage` 식별자 사용 스키마가 깨짐). `attr_def_one`(:9961) 의 중복-옵션 마스크 처리. |
| `src/parser/keyword.c` | `{STORAGE, "STORAGE", 1}`, `{PREFER_INLINE, "PREFER_INLINE", 1}` (세 번째 인자 1 = 비예약). 예약어 판정(`pt_is_reserved_word`)용 테이블이다. |
| `src/parser/csql_lexer.l` | **필수**: 키워드 토큰화 규칙 추가. 렉서의 일반 식별자 규칙은 무조건 `IdName` 을 반환하므로, 키워드는 키워드별 flex 규칙(`[sS][tT][oO][rR][aA][gG][eE] { ...; return STORAGE; }`)이 있어야 토큰이 발생한다. `INVISIBLE` 규칙(`[iI][nN][vV]...`)을 본떠 `STORAGE`/`PREFER_INLINE` 규칙 추가, `<cptr>` 토큰이라 `csql_yylval.cptr = pt_makename(yytext)` 설정. 이 규칙을 빠뜨리면 문법/keyword.c 가 맞아도 `STORAGE` 가 식별자로 렉싱돼 파싱이 실패한다. |
| `src/parser/parse_tree.h` | `PT_ATTR_STORAGE_SETTING` enum (UNSET/DEFAULT/PREFER_INLINE) 추가. `pt_attr_def_info`(:1927) 에 `attr_storage:2` 비트필드 추가 (`attr_invisible:2` (:1938) 와 동일 패턴, UNSET 기본). |
| `src/parser/parse_tree_cl.c` | `pt_print_attr_def`(함수 시작 :6715, INVISIBLE 출력 블록 :6851 옆) 에 PREFER_INLINE 출력 블록 추가 (라운드트립 필수). |
| `src/parser/semantic_check.c` | 검증 + MODIFY/CHANGE 시 UNSET 보존 처리 (`attr_invisible` 의 :4894 / :8722 UNSET 처리 패턴 따름). |
| `src/storage/storage_common.h` | `SM_ATTFLAG_OOS_PREFER_INLINE = 4096` 추가 (:1086 다음, 현재 최대 `SM_ATTFLAG_INVISIBLE_COLUMN = 2048`). |
| `src/query/execute_schema.c` | PT `attr_storage` 값을 `att->flags |= SM_ATTFLAG_OOS_PREFER_INLINE` 로 반영 (INVISIBLE 의 :8192 / ALTER 경로 :11685-11689 패턴). |
| `src/object/class_object.c` | 필요 시 플래그 복사 경로 보강 (INVISIBLE 의 :6614 패턴). |
| `src/base/object_representation_sr.h` | `OR_ATTRIBUTE`(:89) 에 `unsigned oos_prefer_inline:1;` 추가 (`is_invisible:1` (:117) 옆). 생성자 memset 범위 안이라 자동 0 초기화. |
| `src/base/object_representation_sr.c` | `or_get_attributes` (:2505 부근) 에서 플래그 비트 -> `oos_prefer_inline` 복원 한 줄. |

### 정렬 키 변경 (핵심)

현재 (`heap_file.c:12122`, `:12136`):

```cpp
std::vector<std::pair<int, int>> oos_candidates;  /* {column_size, attr index} */
...
std::sort (oos_candidates.begin (), oos_candidates.end (), std::greater<std::pair<int, int>> ());
```

변경 후 - 후보에 `prefer_inline` 플래그를 함께 담고, 1차 키로 정렬한다:

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

`idx` 내림차순 tiebreak 는 필수다. 현재 코드의 `std::greater<std::pair<int,int>>` 는 `{크기, idx}` 쌍을 크기 -> idx 순으로 비교해 동률에서도 결정적(deterministic) 순서를 보장하는데, `std::sort` 는 stable 이 아니므로 idx 키를 빼면 동일 크기 컬럼 2개의 demote 순서가 빌드/STL 버전마다 달라져 회귀 테스트가 flaky 해진다. idx 키를 넣으면 PREFER_INLINE 미지정(DEFAULT) 컬럼만 있는 경우의 정렬 순서가 현행과 비트 단위로 동일하다(회귀 없음).

demote 루프(`:12140-12151`)와 후보 자격 필터(`:12129`)는 그대로 둔다. PREFER_INLINE 컬럼도 여전히 후보이므로(soft), 다른 후보를 모두 소진하고도 레코드가 안 맞으면 자연히 demote 된다.

### 키워드 비예약 처리 주의

`STORAGE` 는 흔한 식별자라, 비예약으로 등록하되 `identifier` 규칙에 echo 를 반드시 넣어야 한다. 누락 시 `CREATE TABLE storage (...)` 같은 기존 스키마가 깨진다. `COMMENT`/`INVISIBLE` 이 동일 메커니즘으로 식별자 충돌을 피한다.

## Acceptance Criteria

- [ ] `CREATE TABLE ... (col VARCHAR(N) STORAGE PREFER_INLINE)` 파싱/생성 성공, 동일 구문이 `ALTER TABLE ... MODIFY` 에서도 동작.
- [ ] `SHOW CREATE TABLE` 출력에 `STORAGE PREFER_INLINE` 이 다시 나타나고, 덤프 -> 재적재(loaddb) 후에도 보존됨 (PREFER_INLINE 한정 - DEFAULT/생략은 출력 없음, 위 라운드트립 절 참고).
- [ ] **값 정합성**: 위 테이블에서 PREFER_INLINE 컬럼을 조회해도 원본 값과 일치(인라인이든 OOS 든 값은 동일). 검증 패턴은 압축 비대상 `BIT VARYING` 사용:
  ```sql
  CREATE TABLE t (id INT, hot BIT VARYING STORAGE PREFER_INLINE, cold BIT VARYING);
  INSERT INTO t VALUES (1, CAST(REPEAT('AA', 1500) AS BIT VARYING),
                           CAST(REPEAT('BB', 1500) AS BIT VARYING));
  SELECT (hot = CAST(REPEAT('AA', 1500) AS BIT VARYING)) FROM t WHERE id = 1;  -- 1 기대
  ```
- [ ] **배치(placement) 확인 (discriminating test)**: PREFER_INLINE 가 demote 순서를 실제로 바꾸는지는, **더 큰** 컬럼을 PREFER_INLINE 으로 보호해 **더 작은** 컬럼이 대신 OOS 로 가게 만들어 검증한다(크기순 기본 정책의 정반대). `DISK_SIZE()` 는 논리적 값 크기만 돌려줘 OOS 여부를 구분하지 못하므로, debug 빌드의 `$CUBRID/log/oos.log` 에 찍히는 `oos_insert ... src.size=` 값으로 어느 컬럼이 demote 됐는지 확인한다(release 빌드엔 컬럼별 OOS 가시성 없음 - CBRD-26871):
  ```sql
  CREATE TABLE demo  (id INT, hot BIT VARYING STORAGE PREFER_INLINE, cold BIT VARYING);
  CREATE TABLE demo2 (id INT, hot BIT VARYING,                       cold BIT VARYING);
  INSERT INTO demo  VALUES (1, CAST(REPEAT('AA',3000) AS BIT VARYING), CAST(REPEAT('BB',2000) AS BIT VARYING));
  INSERT INTO demo2 VALUES (1, CAST(REPEAT('AA',3000) AS BIT VARYING), CAST(REPEAT('BB',2000) AS BIT VARYING));
  -- oos.log: demo 는 src.size~=2000 (작은 cold demote, hot 보호), demo2 는 src.size~=3000 (큰 hot demote, 크기순)
  ```
- [ ] **soft 불변식**: PREFER_INLINE 컬럼만 남아 레코드가 페이지를 못 맞추면 그 컬럼도 결국 OOS 로 demote 되어 INSERT 가 실패하지 않는다.
- [ ] **회귀 없음**: 플래그 미설정(기존 테이블 / `STORAGE DEFAULT`) 시 demotion 결과가 현행과 동일(동일 크기 컬럼의 demote 순서 포함 - idx tiebreak 참고).
- [ ] 고정 길이 컬럼에 `STORAGE PREFER_INLINE` 지정 시 에러 없이 허용되며, 플래그는 저장되나 demotion 에 영향 없음.

## Definition of done

- [ ] 위 Acceptance Criteria 충족
- [ ] 기존 OOS 회귀 테스트(insert/select/update/delete, 크래시 복구, 복제) 통과
- [ ] QA 통과
- [ ] SQL 매뉴얼에 `STORAGE` 컬럼 옵션 및 ALTER 적용 시점 주의 반영

## Open Questions

1. **catalog `_db_attribute.flags` 노출 여부**: 런타임 기능에는 불필요하나, 사용자가 `_db_attribute` 에서 힌트를 조회하게 하려면 `catcls_filter_attflag`(`src/storage/catalog_class.c:5846`, INVISIBLE 매핑은 :5851) 에 새 매핑을, `DB_ATTRIBUTE_OPTION_TYPE`(`src/compat/dbtype_def.h:481-486`) 에 `DB_ATTOPT_OOS_PREFER_INLINE` 멤버를 추가해야 한다. 플래그 기본값이 0 이라 기존 행과 DEFAULT 컬럼은 `_db_attribute.flags` 가 그대로이므로(QA 카탈로그 단언 작성 시 참고), 노출하지 않아도 회귀는 없다. 선택 사항. `TBD - 합의 미확인`.

## 참고 코드

- `src/storage/heap_file.c:12097` - `heap_attrinfo_determine_disk_layout` (demotion 정책, 유일한 정책 변경 지점)
- `src/base/object_representation.h:455` - `OR_OOS_INLINE_SIZE` (= `OR_OID_SIZE + OR_BIGINT_SIZE`, 16바이트)
- `src/base/object_representation_sr.h:89` - `OR_ATTRIBUTE` (런타임 컬럼 표현, 비트필드 `is_invisible` 등)
- `src/storage/storage_common.h:1072` - `SM_ATTRIBUTE_FLAG` (다음 빈 비트 0x1000)
- `src/parser/csql_grammar.y:10110` - `column_constraint_and_comment_def` (옵션 목록), `:10596` `column_invisible_def`(선례)
- `src/query/execute_schema.c:8192` - INVISIBLE 가 `att->flags` 를 세우는 선례

## Remarks

- 후속 분리: (a) hard 강제(`FORCE_INLINE` 등, 절대 OOS 금지 - overflow page 상호작용 검증 필요), (b) ALTER 시 기존 데이터 소급 재배치, (c) 통계/접근빈도 기반 자동 demotion.
- 이슈 타입: Improve (Function/Performance). 대상 브랜치: `feat/oos` (11.5.x 베이스, OOS 기능 릴리스와 함께 반영, 정확한 Fix Version 미정).
- 본 이슈는 OOS feat 브랜치(`feat/oos`) 기준. OOS-CONTEXT 문서의 임계치(`DB_PAGESIZE/8`, 512B)는 stale 이며, 실제 코드는 `DB_PAGESIZE/4` + `OR_OOS_INLINE_SIZE`(16B) 를 사용한다.
