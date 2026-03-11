### Description

CUBRID의 `set` 내부 구조는 `setobj`로 구성되어 있습니다.
기존의 `create_sequence` 함수는 사실상 `create_set`에 `DB_TYPE_SEQUENCE`를 명시하는 것과 동일한 방식으로 동작합니다. 이를 확장하여 `DB_TYPE_VECTOR`를 사용할 수 있도록 하고, 기존에 `TP_DOMAIN`과 관련된 타입 검사를 막아둔 제약을 해제하여, `VECTOR` 타입의 데이터 생성과 관리가 가능하도록 구현했습니다.
이는 기존 구조를 활용해 코드 중복을 줄이고, 새로운 데이터 타입을 추가하는 데 있어 기존의 안정성과 일관성을 유지하는 것이 목표입니다.

---

### Spec Changes

- 새로운 데이터 타입 `DB_TYPE_VECTOR` 추가.
- `tp_Vector_domain`을 정의하여 도메인 관리 지원.
- `TP_IS_SET_TYPE` 매크로에 `DB_TYPE_VECTOR`를 추가하여 유효한 `set` 타입으로 간주.
- VECTOR 타입의 DB_COLLECTION 생성 함수(`set_create_vector`) 구현.

---

### Implementation

1. **`DB_TYPE_VECTOR` 타입 추가**

   - 새로운 타입인 `DB_TYPE_VECTOR`를 정의하고 이를 `db_value_domain_init` 함수에 추가했습니다.
     이를 통해 `DB_VALUE` 구조체를 `DB_TYPE_VECTOR` 타입으로 초기화할 수 있습니다.

   ```c
   case DB_TYPE_VECTOR:
       // VECTOR 타입 초기화 처리
       break;
   ```

2. **도메인 정의 및 확장**

   - `tp_Vector_domain`을 정의하여 VECTOR 타입에 대해 도메인을 관리할 수 있도록 했습니다.
     또한, `TP_IS_SET_TYPE` 매크로를 확장하여 VECTOR 타입도 유효한 `set` 타입으로 간주합니다.

   ```c
   TP_DOMAIN tp_Vector_domain = { NULL, NULL, &tp_Vector, DOMAIN_INIT3 };

   #define TP_IS_SET_TYPE(typenum) \
       ((((typenum) == DB_TYPE_SET) || ((typenum) == DB_TYPE_MULTISET) || \
         ((typenum) == DB_TYPE_SEQUENCE) || ((typenum) == DB_TYPE_VECTOR)) \
        ? true : false)
   ```

3. **VECTOR 데이터 생성 함수 구현**

   - `set_create` 함수에 `DB_TYPE_VECTOR`를 추가하여 VECTOR 데이터 생성이 가능하도록 했습니다.
     내부적으로 `set_create_vector` 함수는 기존의 `set_create`를 호출하되, `DB_TYPE_VECTOR`를 명시적으로 전달합니다.

   ```c
   DB_COLLECTION *
   set_create_vector (int size)
   {
       return set_create (DB_TYPE_VECTOR, size);
   }
   ```

4. **기존 구조와의 통합**

   - `set_object.c` 및 `set_object.h`에서 VECTOR를 다룰 수 있도록 관련 로직을 통합했습니다.
     예를 들어, `col_new` 함수에서 `DB_TYPE_VECTOR`를 처리하고, 이를 `tp_Vector_domain`과 연결했습니다.

   ```c
   case DB_TYPE_VECTOR:
       col->domain = &tp_Vector_domain;
       break;
   ```

5. **tp_Vector_domain 생성**

`tp_Vector_domain`은 VECTOR 타입의 도메인을 관리하기 위해 정의되었으며, 기존 도메인 관리 방식과 일관성을 유지합니다.

```c
TP_DOMAIN tp_Vector_domain = { NULL, NULL, &tp_Vector, DOMAIN_INIT3 };
```

6. **`db_make_vector` 함수 구현**

   - VECTOR 타입의 DB_SET을 DB_VALUE로 변환하는 함수를 구현했습니다.
   - 입력받은 DB_SET이 유효한 VECTOR 타입인지 검증하고, 이를 DB_VALUE로 변환합니다.

   ```c
   int
   db_make_vector (DB_VALUE * value, DB_SET * set)
   {
       // DB_VALUE의 타입을 DB_TYPE_VECTOR로 설정
       value->domain.general_info.type = DB_TYPE_VECTOR;
       value->data.set = set;

       if (set)
       {
           // VECTOR 타입이거나 disk_set인 경우 정상 처리
           if ((set->set && setobj_type (set->set) == DB_TYPE_VECTOR)

               ...
   }
   ```

---

### Acceptance Criteria

1. **VECTOR 타입 생성 및 관리 가능**

   - `set_create_vector`를 호출하여 VECTOR 타입의 데이터가 정상적으로 생성되는지 확인.
   - VECTOR 타입의 데이터를 도메인과 연결하여 처리할 수 있는지 검증.

2. **기존 기능과의 호환성 유지**

   - 기존의 `set` 관련 함수(`set_create`, `col_new` 등)가 정상적으로 동작하는지 확인.
   - 기존 도메인 관리 로직에 영향을 주지 않는지 확인.

---

### Definition of Done

AC 통과
