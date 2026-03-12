### Description

실패한 TC:
`sql/_16_index_enhancement/_12_descending_index_scan/cases/_05_overflow.sql`

---

## 문제 분석

`heap_attrinfo_get_key()` 와 `heap_attrinfo_generate_key()` 함수 내부에서 `midxkey` 를 생성하는 과정에서 **stack overflow** 가 발생한다.

현재 구현에서는 다음과 같은 방식으로 버퍼를 사용한다.

* `midxkey.length < 4096` 인 경우
  → `midxkey.buf` 는 **stack 변수 `buf`** 를 사용
* `midxkey.length >= 4096` 인 경우
  → 별도의 메모리를 **heap allocation** 으로 할당

문제는 **OOS(Overflow Object Storage) 값** 을 처리할 때 발생한다.

OOS 값의 실제 크기가 4096보다 훨씬 클 수 있음에도 불구하고, `midxkey.length` 계산 과정에서 이를 제대로 반영하지 못해 여전히 **stack buffer를 사용하게 된다.**

예를 들어 길이가 **10000 bytes 이상인 OOS 값** 이 `midxkey` 에 저장되는 경우,

```
memcpy(buf, oos_value, 10000)
```

과 같이 **4096 크기의 stack buffer에 10000 bytes 이상의 데이터를 복사** 하게 되며, 그 결과 **stack 영역이 overwrite되는 stack overflow** 가 발생한다.

이로 인해 다음과 같은 문제가 발생한다.

* stack 영역이 손상됨
* call stack 정보가 변조됨
* core dump에서 정상적인 stack trace 확인 불가

임시로 다음과 같이 `midxkey.length` 를 매우 큰 값으로 설정하면 문제가 발생하지 않는다.

```
midxkey.length = 100000
```

이 경우 stack buffer 대신 heap allocation 경로가 사용되기 때문이다.
하지만 이는 근본적인 해결 방법이 아니다.

---

# 원인 분석

`midxkey` 에 데이터를 저장하는 `buf` 의 크기는 다음과 같이 결정된다.

```c
// heap_attrinfo_generate_key()
int midxkey_size = recdes->length;
...
/* Allocate storage for the buf of midxkey */
if (midxkey_size > DBVAL_BUFSIZE) // 4096
  {
    midxkey.buf = (char *) db_private_alloc (thread_p, midxkey_size);
    if (midxkey.buf == NULL)
      {
        return NULL;
      }
  }
else
  {
    midxkey.buf = buf;
  }
```

즉, 예상되는 `midxkey_size` (`= recdes->length`) 가 `4096` 이하이면 별도 heap allocation 을 하지 않고 stack buffer 를 사용한다.

이 경로는 최종적으로 `btree_sort_get_next()` 의 로컬 버퍼를 사용하게 된다.

```c
static SORT_STATUS
btree_sort_get_next (THREAD_ENTRY * thread_p, RECDES * temp_recdes, void *arg)
{
  SCAN_CODE scan_result;
  DB_VALUE dbvalue;
  DB_VALUE *dbvalue_ptr;
  int key_len;
  OID prev_oid;
  SORT_ARGS *sort_args;
  int value_has_null;
  char midxkey_buf[DBVAL_BUFSIZE + MAX_ALIGNMENT], *aligned_midxkey_buf;
```

여기서 `midxkey.buf` 는 결국 `aligned_midxkey_buf` 를 바라보게 되며, 이는 함수의 **로컬 stack 변수 영역** 이다.

기존에는

```
midxkey 최대 크기 = recdes->length
```

이라는 전제가 성립했기 때문에 해당 로직이 문제되지 않았다.

하지만 **OOS(Overflow Object Storage)** 가 도입되면서 이 전제가 더 이상 성립하지 않게 되었다.

`recdes->length` 는 작게 계산되더라도 실제 OOS value 는 훨씬 큰 데이터를 가질 수 있다.

이후 index key 를 기록하는 과정에서 실제 value 크기만큼 그대로 write 가 수행된다.

```c
att->domain->type->index_writeval (&buf, &value);
```

이 과정에서 내부적으로 큰 OOS value 에 대해 `memcpy` 가 수행되며, `buf` 가 stack buffer 를 가리키고 있는 경우 **stack 영역 전체를 덮어쓰게 된다.**

결과적으로 다음과 같은 문제가 발생한다.

* stack local variable overwrite
* call stack/frame pointer 손상
* core dump 상에서 정상적인 call stack 확인 불가

core dump 분석 결과에서도 이러한 현상이 확인되었다.

* `unlink_chunk` 는 매크로
* `free` 대상

```
temp == char_medium_buf == 'aaa...'
```

* `db_type = DB_TYPE_STRING`
* `sort_args` 변수가 문자열 값으로 덮어쓰여짐

또한 함수 콜스택 영역이 `'aaaabbbb...'` 와 같은 문자열 데이터로 덮어씌워져 있었으며, 이는 large string 이 stack buffer 로 복사되면서 stack 메모리가 손상되었음을 의미한다.

즉, **OOS 도입 이후에도 midxkey 크기 판단 기준이 여전히 `recdes->length` 에 의존하고 있다는 점이 근본 원인이다.**

---

# Spec Change

N/A

---

# Implementation

OOS 값을 읽어온 이후, `IS_OOS` 인 경우 실제 필요한 `midxkey` 의 크기를 다시 계산하도록 한다.

이후 재계산된 크기에 맞게 `db_private_alloc()` 을 통해 heap 메모리를 할당하여 `midxkey.buf` 에 저장한다.

즉,

1. OOS 값을 읽어옴
2. `IS_OOS == true` 인 경우 실제 key 크기 재계산
3. 필요한 크기에 맞게 `db_private_alloc()` 수행
4. heap buffer 를 `midxkey.buf` 로 설정한 뒤 key 데이터 저장

정리하면 **`IS_OOS` 인 경우 `midxkey.buf = db_private_alloc(...)` 로 처리하는 로직을 도입하여 stack buffer 사용 경로를 차단한다.**

이를 통해 실제 데이터 크기에 맞는 메모리를 확보하고, large OOS value 처리 시 발생하던 stack overflow 를 방지한다.

---

# A/C

* 모든 `test_sql` 테스트 통과 (임시 patch 적용 시 정상 동작 확인)

---

# Remarks

core dump 의 stack 정보가 정상적으로 출력되지 않는 이유는 **stack overflow 로 인해 stack 자체가 손상되었기 때문** 이다.

---

# 재현 SQL

`enable_string_compression = no` 설정 시 아래 SQL에서 문제가 발생한다.

* **develop 브랜치:** 정상 동작
* **oos 브랜치:** core dump 발생

```sql
create table test_overflow(id int auto_increment(1, 2), vc varchar(16384));

insert into test_overflow(vc) values ('very long string ...');

create index i_test_overflow_id_vc on test_overflow(id, vc);
```

다음 두 경우 모두 core dump가 발생한다.

1. **create index 수행 후 insert 수행**
2. **insert 수행 후 create index 수행**

