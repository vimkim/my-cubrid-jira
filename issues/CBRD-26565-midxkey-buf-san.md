### Description

실패한 TC:
`sql/_16_index_enhancement/_12_descending_index_scan/cases/_05_overflow.sql`

#### 문제 분석

`heap_attrinfo_get_key()` 와 `heap_attrinfo_generate_key()` 함수 내부에서 `midxkey` 를 생성하는 과정에서 **stack overflow** 가 발생한다.

현재 구현에서는 다음과 같은 방식으로 버퍼를 사용한다.

* `midxkey.length < 4096` 인 경우
  → `midxkey.buf` 는 **stack 변수 `buf`** 를 사용
* `midxkey.length >= 4096` 인 경우
  → 별도의 메모리를 **heap allocation** 으로 할당

문제는 **OOS(Overflow Object Storage) 값 ** 을 처리할 때 발생한다.

OOS 값의 실제 크기가 4096보다 훨씬 클 수 있음에도 불구하고, `midxkey.length` 계산 과정에서 이를 제대로 반영하지 못해 여전히 **stack buffer를 사용하게 된다.**

예를 들어 길이가 **10000 bytes 이상인 OOS 값 ** 이 `midxkey` 에 저장되는 경우,

```
memcpy(buf, oos_value, 10000)
```

과 같이 **4096 크기의 stack buffer에 10000 bytes 이상의 데이터를 복사 ** 하게 되며, 그 결과 **stack 영역이 overwrite되는 stack overflow** 가 발생한다.

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

### Spec Change

N/A

---

### Implementation

OOS 값을 읽어온 이후, `is_oos` 인 경우 실제 필요한 `midxkey` 의 크기를 다시 계산하도록 한다.

이후 재계산된 크기에 맞게 `db_private_alloc()` 을 통해 heap 메모리를 할당하여 `midxkey.buf` 에 저장한다.

즉,

1. OOS 값을 읽어옴
2. `is_oos == true` 인 경우 실제 key 크기 재계산
3. 필요한 크기에 맞게 `db_private_alloc()` 수행
4. 해당 버퍼에 `midxkey` 데이터를 저장

이를 통해 stack buffer를 사용하는 경로를 피하고, 실제 데이터 크기에 맞는 메모리를 확보하여 stack overflow를 방지한다.

---

### A/C

* 모든 `test_sql` 테스트 통과 (임시 patch 적용 시 정상 동작 확인)

---

### Remarks

분석 결과, core dump의 stack 정보가 정상적으로 출력되지 않는 이유는 **stack overflow로 인해 stack 자체가 손상되었기 때문 ** 이다.

또한 다음과 같은 현상이 관찰되었다.

* `unlink_chunk` 는 매크로
* `free` 대상

  ```
  temp == char_medium_buf == 'aaa...'
  ```
* `db_type = DB_TYPE_STRING`
* `sort_args` 변수가 문자열 값으로 덮어쓰여짐

이는 **buffer overflow 발생 가능성을 시사 ** 하며, 최종적으로 stack overflow가 root cause임을 확인하였다.

---

### 재현 SQL

`enable_string_compression = no` 설정 시 아래 SQL에서 문제가 발생한다.

* **develop 브랜치:** 정상 동작
* **oos 브랜치:** core dump 발생

```
create table test_overflow(id int auto_increment(1, 2), vc varchar(16384));

insert into test_overflow(vc) values ('very long string ...');

create index i_test_overflow_id_vc on test_overflow(id, vc);
```

다음 두 경우 모두 core dump가 발생한다.

1. **create index 수행 후 insert 수행 **
2. **insert 수행 후 create index 수행 **
