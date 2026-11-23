# [OOS] 서버 측 INSERT·UPDATE가 행마다 레코드 버퍼와 OOS 부가 자료를 glibc malloc/free로 할당·해제한다

**한 줄 요약**: `cbrd_27780`(CBRD-28257) 실패 원인을 추적하다가, OOS(PR #7990)가 `locator_attribute_info_force ()` 의 copy area 풀 재사용을 스택 지역 `heap_pending_record` 로 바꾸면서 서버 측 INSERT·UPDATE가 행마다 레코드 버퍼를 glibc `malloc`/`free` 로 할당·해제하게 된 것을 확인했다. 이 이슈는 그 행 단위 할당 비용을 측정한 결과를 기록하고, 버퍼 재사용으로 줄일지 결정하는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: 서버 측 INSERT·UPDATE가 행마다 하는 레코드 버퍼와 OOS 부가 자료의 힙 할당을 측정 근거에 따라 없애거나 줄이고, 줄이지 않는다면 그 근거를 남긴다.

**이슈 수행 이유**: OOS 이전에는 `locator_attribute_info_force ()` 가 레코드를 `locator_Keep.copy_areas` 풀의 copy area에 만들었으므로 행마다 `malloc`/`free` 를 부르지 않았다. 지금은 행마다 `heap_pending_record` 를 만들고, 그 레코드 버퍼는 `cubmem::STANDARD_BLOCK_ALLOCATOR` 로 `new char[]`/`delete[]` 를 한 번씩 부른다. OOS 값이 있는 행은 값마다 payload `malloc` 과 `std::vector` 몇 개를 더 할당한다. 이 비용은 [CBRD-28278](https://jira.cubrid.org/browse/CBRD-28278)의 1\~8번 항목에 없다. release 빌드 A/B 측정에서 레코드 버퍼 할당을 없애면 서버 명령어 수가 행당 134\~151개(0.57\~0.68%) 줄었다.

**영향**: OOS를 쓰지 않는 테이블을 포함해 서버 측 INSERT·UPDATE를 대량으로 실행하는 사용자는 행마다 CPU 명령어를 조금 더 쓴다. 측정한 크기는 1M행 INSERT ... SELECT와 UPDATE에서 서버 명령어 수의 약 0.6%이고, 수행 시간(cycle·wall)의 차이는 측정 변동보다 작아 확인하지 못했다. OOS 행에서는 레코드 버퍼보다 행마다 할당하는 `std::vector` 들(0.6\~2.3%)이 더 크다. 동시 실행이 많은 환경에서 glibc arena 경합이 늘어나는지는 측정하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 배경: OOS 전후의 레코드 버퍼

- **OOS 이전** (`68a9c7766f^`): `locator_attribute_info_force ()` 는 `locator_allocate_copy_area_by_attr_info ()`(`locator_sr.c:8969`)로 레코드를 만들었다. 이 함수는 `locator_allocate_copy_area_by_length ()`(`locator.c:406`)에서 DB_PAGESIZE 크기의 copy area를 받고, `locator_free_copy_area ()`(`locator.c:533`)가 그 copy area를 `locator_Keep.copy_areas` 풀에 돌려준다. 그래서 행마다 glibc `malloc`/`free` 를 부르지 않았다. 대신 풀의 전역 mutex를 행마다 두 번 잡았다.
- **OOS 이후** (`origin/develop` `ed394047b5` 기준): `locator_attribute_info_force ()` 가 스택 지역 `heap_pending_record pending`(`locator_sr.c:9386`)을 만든다. 생성자는 `record_descriptor m_record (cubmem::STANDARD_BLOCK_ALLOCATOR)`(`heap_pending_record.cpp:36`)이고, `heap_attrinfo_transform_to_disk_internal ()` 의 `new_recdes->resize_buffer ()`(`heap_file.c:15502`)가 `cubmem::standard_alloc ()` 의 `new char[size]`(`mem_block.cpp:38`)를 부른다. 함수가 끝나면 `delete[]` 가 불린다. server 빌드에서 `new` 는 `cub_alloc ()` → glibc `malloc` 이다(`memory_wrapper.hpp`, `memory_cwrapper.h`).

### 행마다 하는 힙 할당

| 경로 | 행 종류 | 할당 | 위치 |
|---|---|---|---|
| 레코드 버퍼 | 모든 행 | `new char[]`/`delete[]` 1쌍 | `heap_pending_record.cpp:36`, `mem_block.cpp:38` |
| OOS payload | OOS 값마다 | `malloc`/`free` 1쌍 | `heap_attrinfo_dbvalue_to_recdes ()`, `heap_file.c:14617` |
| 보관한 payload 목록 | OOS 행 | `m_values` vector 확장 | `heap_pending_record::retain ()` |
| demotion 계획 | OOS 행 | `std::vector<heap_oos_column_plan>` | `heap_file.c:15391` |
| finalize | OOS 행 | `std::vector` 3개(`values`, `requests`, `reused`) | `heap_oos.cpp:231-239` |
| 컬럼 크기 | 컬럼이 8개를 넘는 행 | `std::vector<int>` | CBRD-28278 4번이 이미 다룬다 |

같은 `heap_pending_record` 를 행마다 만드는 다른 경로도 있다: loaddb(`load_server_loader.cpp:893`), REPLACE와 ON DUPLICATE KEY UPDATE(`query_executor.c:18047`, `:18278`), copy area로 받은 행(`locator_sr.c:6418`, `:6956`), 파티션 재분배(`locator_sr.c:14309`, `:14951`). 이번 측정은 `locator_attribute_info_force ()` 경로만 다뤘다.

### 측정

**조건**

- 소스: `origin/develop` `ed394047b5`. 로컬 `develop` `16325f31b6` 은 `e2bfdc3939`(CBRD-28188 첫 커밋)가 OOS 이전 매크로 이름을 써서 컴파일되지 않았고, `origin/develop` 의 `208ea37f11` 에서는 고쳐져 있다.
- 빌드: CMake RelWithDebInfo(`-O2 -DNDEBUG -fno-omit-frame-pointer`), unit test 옵션 모두 OFF, GCC 11.5.0, glibc 2.34.
- 변형 A: `ed394047b5` 그대로.
- 변형 B: A에서 레코드 버퍼만 page 크기 스택 버퍼로 바꾼 실험용 패치. 행 레코드가 한 page에 들어가면 힙 할당이 없다. OOS payload와 vector 할당은 그대로다. 측정용이며 제안하는 수정이 아니다.

```diff
--- a/src/transaction/locator_sr.c
+++ b/src/transaction/locator_sr.c
@@ locator_attribute_info_force
   /* *INDENT-OFF* */
+  cubmem::stack_block<(size_t) IO_MAX_PAGE_SIZE> pending_buf;
   heap_pending_record pending;
+  pending.record ().set_external_buffer (pending_buf.get_ptr (), pending_buf.SIZE);
   /* *INDENT-ON* */
--- a/src/storage/heap_file.c
+++ b/src/storage/heap_file.c
@@ heap_attrinfo_prepare_record
-  assert (record->get_recdes ().data == nullptr);
+  assert (record->get_recdes ().data == nullptr || record->get_recdes ().length == 0);
```

- 호스트: Xeon Gold 5218R 2소켓 80 thread, Linux 5.14(EL9). 다른 작업이 함께 도는 공유 장비(load average 약 7\~13)다.
- DB: 변형마다 별도 설치와 DB, CS 모드 서버 1개, 클라이언트 1개(`csql -C`). page 16KB, `data_buffer_size=4G`, `enable_string_compression=n`. 원본 테이블 `src (id int primary key)` 1,000,000행.
- 반복마다 `t_in`, `t_oos` 를 새로 만들고 아래 다섯 문장을 실행한다. 문장마다 서버가 쉬기를 기다린 뒤 `perf stat -e instructions:u,cycles:u -p <cub_server pid>` 로 서버 프로세스 전체를 센다. A·B 순서를 번갈아 10번 반복했다.

```sql
create table t_in (id int, s varchar(64), n int);
create table t_oos (id int, big varchar(10000), n int);
insert into t_in select id, 'val' || id, id from src;                                  -- ins_inline, 1,000,000행
update t_in set n = n + 1;                                                             -- upd_inline, 1,000,000행
insert into t_oos select id, id || repeat('x', 6000), id from src where id <= 100000;  -- ins_oos, 100,000행(행마다 OOS 값 1개)
update t_oos set n = n + 1;                                                            -- upd_oos_n, 100,000행(OOS stub 재사용)
update t_oos set big = big || 'y' where id <= 20000;                                   -- upd_oos_big, 20,000행(새 OOS 값)
```

**결과** (10회 중앙값, 괄호는 최소\~최대, 차이는 A 기준)

| 문장 | 서버 명령어 A | 서버 명령어 B | B−A | 행당 줄어든 명령어 |
|---|---|---|---|---|
| ins_inline | 19.699G (19.691\~19.715) | 19.565G (19.558\~19.575) | −0.68% | 134 |
| upd_inline | 26.619G (26.560\~26.779) | 26.468G (26.408\~26.538) | −0.57% | 151 |
| ins_oos | 7.904G (7.752\~7.934) | 7.906G (7.833\~7.931) | +0.02% | 구분 안 됨 |
| upd_oos_n | 3.586G (3.582\~3.634) | 3.580G (3.575\~3.625) | −0.17% | 구분 안 됨 |
| upd_oos_big | 2.408G (2.405\~2.481) | 2.407G (2.399\~2.466) | −0.04% | 구분 안 됨 |

- 인라인 두 문장은 A와 B의 범위가 겹치지 않는다.
- cycle과 wall time은 같은 변형 안에서도 최대 2배까지 흔들려(공유 장비, 백그라운드 vacuum) 차이를 판정할 수 없었다. 중앙값 차이는 ins_inline wall +2.3%, upd_inline wall −1.8%처럼 방향이 섞인다. 즉 수행 시간 개선은 확인하지 못했다.
- 비교 기준은 A(OOS 이후 develop)다. OOS 이전 develop은 다른 변경이 많아 이번 측정에서 빌드하지 않았다.

**할당 비용의 분포** (변형 A, `perf record -e instructions:u --call-graph lbr`, 서버 전체 표본 대비 비율)

glibc 할당 함수(`malloc`, `free`, `calloc`, `_int_*`, `malloc_consolidate` 등)에 떨어진 표본을 첫 호출자로 나눴다.

| 호출자 묶음 | ins_inline | upd_inline | ins_oos | upd_oos_n | upd_oos_big |
|---|---|---|---|---|---|
| 레코드 버퍼(`cubmem::standard_*`, `record_descriptor`) | 0.52% | 0.67% | 0.10% | 0.12% | 0.11% |
| OOS payload(`heap_attrinfo_dbvalue_to_recdes` 등) | --- | --- | 0.46% | --- | 0.22% |
| OOS 계획·finalize·참조 vector(`heap_oos_*`, `oos_chain_ref` 등) | --- | --- | 0.62% | 2.34% | 1.82% |
| log prior list(`prior_lsa_alloc_and_copy_*`, `logpb_free_prior_node` 등) | 6.10% | 8.09% | 6.54% | 6.42% | 13.41% |
| 기타 | 0.58% | 3.67% | 6.52% | 10.22% | 4.85% |

- 레코드 버퍼 몫(0.5\~0.7%)은 A/B 차이(0.57\~0.68%)와 맞는다.
- OOS 행에서는 행마다 만드는 vector가 레코드 버퍼보다 크다(upd_oos_n 2.34%, 그중 `heap_oos_finalize_record ()` 1.03%, `std::vector<oos_chain_ref>` 확장 0.64%).
- 가장 큰 할당 비용은 log prior list 노드의 `malloc`/`free` 다(6\~13%). OOS 이전부터 있던 경로이고 이 이슈의 범위가 아니다. 별도 검토 대상으로 남긴다.
- "기타"의 큰 몫은 측정 방법 때문이다. 문장마다 새로 연결한 csql 세션의 `sysprm_unpack_session_parameters ()` → `calloc` 이 직전 문장이 해제한 chunk에 대해 `malloc_consolidate` 를 돌렸다(ins_oos 6.29%, upd_oos_n 9.87%). 문장당 한 번이고 A·B가 같다. upd_inline의 `spage_compact ()`(2.12%)와 `qsort_r`(1.51%)은 OOS와 무관하다.

### 관련 이슈와의 관계

- [CBRD-28278](https://jira.cubrid.org/browse/CBRD-28278)(PR #7990 최종 리뷰의 성능 후속 묶음): 4번이 컬럼이 8개를 넘을 때의 `std::vector<int>` 할당을 다룬다. 레코드 버퍼, OOS payload, finalize vector의 행 단위 할당은 1\~8번에 없다. 이 이슈의 결론은 CBRD-28278 4번의 수정 방식과 함께 정하는 것이 좋다.
- [CBRD-27816](https://jira.cubrid.org/browse/CBRD-27816)(Resolved): 일반 UPDATE의 잔여 비용을 나누면서 `heap_pending_record` 생성·소멸을 200,000행당 18.8M 명령어로 쟀고, 그 일부는 copy area 할당·해제를 대신하는 몫이라고 적었다. allocator 변경은 그 이슈의 범위에서 뺐다. 이 이슈가 그 남은 부분을 다룬다.
- [CBRD-28257](https://jira.cubrid.org/browse/CBRD-28257)(TDE 카탈로그 행 평문 기록): 근본 원인은 카탈로그 행 쓰기의 초기화 누락이다. 그 이슈의 댓글은 OOS 이후 행마다 glibc에 반납되는 레코드 버퍼가 `catcls_insert_instance ()` 의 `malloc` 에 재사용되면서 발생 빈도가 늘었다고 분석했다. 레코드 버퍼를 힙에서 빼면 이 증폭 경로가 줄 것으로 보지만 확인하지 않았다. 이 이슈의 수정은 CBRD-28257의 수정을 대신하지 않는다.

### ANALYSIS 확인 사항

1. 레코드 버퍼를 어디에 둘지: 위 B처럼 page 크기 스택 버퍼, thread별로 재사용하는 버퍼, `cubmem::PRIVATE_BLOCK_ALLOCATOR`(`db_private_alloc`), OOS 이전의 copy area 풀 중 무엇이 맞는가. `locator_attribute_info_force ()` 는 외래 키 cascade로 재귀할 수 있으므로 스택 16KB를 재귀 깊이만큼 쓰는 것이 괜찮은지 확인한다. loaddb처럼 pending record를 모아 두는 경로에는 스택 버퍼를 쓸 수 없다.
2. OOS 행의 vector 할당(`heap_oos_finalize_record ()` 의 3개, `oos_plan`, `oos_chain_ref`, `m_values`)을 작은 inline 저장소나 재사용으로 줄일지. upd_oos_n에서 2.34%로 레코드 버퍼보다 크다.
3. 위 다른 `heap_pending_record` 사용 경로(loaddb, REPLACE, ON DUPLICATE KEY UPDATE, copy area, 파티션 재분배)도 같은 방식으로 바꿀지.
4. 동시 DML이 많을 때 glibc arena 경합으로 수행 시간 차이가 커지는지. 이번 측정은 클라이언트 1개였다.

## Definition of done

- 선택한 방식으로 바꾼 뒤 위 다섯 문장을 release 빌드에서 다시 재고, 서버 명령어 수(와 가능하면 cycle)의 전후 결과를 남긴다. 바꾸지 않기로 하면 그 근거를 남긴다.
- 바꾼 경로의 결과가 develop과 같음을 기존 ctest와 OOS 관련 SQL·shell TC로 보인다.
