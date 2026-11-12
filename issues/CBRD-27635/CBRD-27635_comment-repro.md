develop 빌드에서 이 결함을 재현했습니다. backupdb 없이 온라인 인덱스 생성만으로도 발생합니다. CI 처럼 가끔이 아니라, 아래 순서로 데이터를 넣으면 나타납니다.

## 재현 환경

- develop e64a04a79, debug 빌드 (Linux 64bit)
- 재현에 쓴 cubrid.conf 설정: `enable_string_compression=no` (키가 overflow key 가 되도록)

## 재현 절차

```sql
create table t1 (a int primary key auto_increment, b int, c varchar(3500));

-- 짝수 a 를 먼저, 홀수 a 를 나중에 넣어 힙 순서가 키 순서와 다르게 만든다
insert into t1 (a, b, c)
  select case when level <= 30000 then 2 * level else 2 * (level - 30000) - 1 end,
         level - 1,
         rpad('CUBRID is an object-relational database management system (ORDBMS), which supports object-oriented concepts such as inheritance.', 3500, ' ')
  from db_root connect by level <= 60000;

create index idx on t1(b);
create index idx2 on t1(a,b,c) with online;
```

## 결과

- `create index ... with online` 은 성공(rc 0)하지만, 요청이 끝날 때 cub_server 가 `restrack_assert` 로 중단되고 core 가 생깁니다.
- 서버 에러 로그의 resource tracker 덤프에 `Virtual Memory amount = 28638` 이 남습니다.
- 같은 데이터를 오름차순이나 내림차순으로만 넣으면 누수가 없습니다. 기존 키 사이에 끼워 넣는 경우에만 발생합니다.

## 원인

`page_key_boundary::set_value (thread_p, dest, btid, page, rec)` (`btree.c`) 가 non-leaf 구분 키를 `PEEK_KEY_VALUE` 로 읽습니다. 그 키가 overflow key 이면 별도 버퍼에 읽히고 `clear_boundary_value` 가 true 가 됩니다. 함수는 이 값을 `dest` 로 복제한 뒤 원본을 해제하지 않습니다. 같은 이름의 다른 오버로드 `set_value (dest, src, clear)` 는 해제합니다.

gdb 로 이 지점에서 읽힌 버퍼 주소와 resource tracker 가 보고한 누수 주소를 비교했습니다. 두 집합이 정확히 일치했습니다. 호출 경로는 `btree_split_node_and_advance` → `btree_search_nonleaf_page` → `update_boundary_lt` 입니다.

## 수정안

```diff
@@ page_key_boundary::set_value (THREAD_ENTRY * thread_p, DB_VALUE &dest_value, ...
 					       BTREE_NON_LEAF_NODE, &clear_boundary_value, &offset,
 					       PEEK_KEY_VALUE) != NO_ERROR)
     {
+      btree_clear_key_value (&clear_boundary_value, &boundary_value);
       return ER_FAILED;
     }
 
   pr_clone_value (&boundary_value, &dest_value);
+  btree_clear_key_value (&clear_boundary_value, &boundary_value);
 
   return NO_ERROR;
 }
```

이 수정을 포함한 develop 기반 작업 브랜치 빌드에서 같은 절차를 돌리면 누수와 core 가 없었습니다. develop 에 이 수정만 얹은 빌드로는 아직 확인하지 않았습니다.
