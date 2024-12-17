## Description

### **1. 문제 설명**

`csql -u dba testdb -S -c 'desc vt;'` 명령을 실행할 때, **VECTOR** 필드의 데이터 타입이 **OBJECT**로 잘못 출력되는 문제가 발생했습니다. 이 문제는 `VECTOR` 타입이 데이터베이스 시스템 전반에 걸쳐 제대로 정의되거나 처리되지 않았기 때문입니다.

---

### **2. 원인 분석**

#### **원인 1: `pt_type_enum_to_db()` 함수의 VECTOR 처리 누락**

`pt_type_enum_to_db()` 함수는 **PT_TYPE_ENUM**을 **DB_TYPE**으로 변환하는 역할을 합니다. 그러나 `PT_TYPE_VECTOR`가 이 함수의 `switch` 문에서 누락되어 있어 변환 과정에서 문제가 발생했습니다.

#### **원인 2: `pt_type_enum_to_db_domain()` 함수의 VECTOR 처리 누락**

`pt_type_enum_to_db_domain()` 함수는 데이터 타입 도메인을 매핑합니다. 여기에 `DB_TYPE_VECTOR`에 대한 처리가 빠져 있어 `NULL`을 반환하며 제대로 동작하지 않았습니다.

#### **원인 3: `qexec_schema_get_type_name_from_id()` 함수의 VECTOR 처리 누락**

`qexec_schema_get_type_name_from_id()` 함수는 타입 ID를 기반으로 이름을 반환합니다. `DB_TYPE_VECTOR`를 처리하지 않아, `desc` 명령 실행 시 데이터 타입이 **UNKNOWN DATA_TYPE**으로 출력되었습니다.

#### **원인 4: `tp_Type_id_map` 배열에 VECTOR 타입 누락**

`tp_Type_id_map` 배열은 타입 ID와 프리미티브 타입(PR_TYPE)을 연결하는 역할을 합니다. `tp_Vector`가 이 배열에 빠져 있어 오버플로우가 발생했습니다. 결과적으로 VECTOR 타입이 제대로 등록되지 않았습니다.

---

### **3. 해결 방법**

#### **1단계: `pt_type_enum_to_db()`에 VECTOR 처리 추가**

`parse_dbi.c` 파일의 `pt_type_enum_to_db()` 함수에 `PT_TYPE_VECTOR`에 대한 변환 로직을 추가합니다.

```c
case PT_TYPE_VECTOR:
    db_type = DB_TYPE_VECTOR;
    break;
```

#### **2단계: `pt_type_enum_to_db_domain()`에 VECTOR 처리 추가**

`pt_type_enum_to_db_domain()` 함수에서 `DB_TYPE_VECTOR`를 처리하도록 수정합니다.

```c
case DB_TYPE_VECTOR:
    return tp_domain_construct (DB_TYPE_VECTOR, NULL, 0);
```

#### **3단계: `qexec_schema_get_type_name_from_id()`에 VECTOR 타입 이름 반환 추가**

`query_executor.c` 파일의 `qexec_schema_get_type_name_from_id()` 함수에 `DB_TYPE_VECTOR` 핸들링을 추가합니다.

```c
case DB_TYPE_VECTOR:
    return "VECTOR";
```

#### **4단계: `tp_Type_id_map` 배열에 VECTOR 타입 추가**

`tp_Type_id_map` 배열에 `tp_Vector`를 추가합니다. 이를 통해 VECTOR 타입이 시스템에 올바르게 등록됩니다.

```c
PR_TYPE *tp_Type_id_map[] = {
    ...
    &tp_Json,
    &tp_Vector,
};
```

그리고 `tp_Vector`에 대한 정의를 추가합니다.

```c
PR_TYPE tp_Vector = {
    "vector", DB_TYPE_VECTOR, 1, sizeof(SETOBJ *), 0, 4,
    NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL
};
```

---

### **4. 테스트 및 검증**

해당 문제 해결 후, 다음 명령을 실행하여 정상적으로 동작하는지 검증합니다.

```bash
csql -u dba testdb -S -c 'desc vt;'
```

---

이제 `VECTOR` 데이터 타입이 시스템 전반에서 제대로 인식되고 출력되므로 문제는 해결되었습니다.

### **Specification Changes**

- 디스크에 `VECTOR` 데이터 타입을 올바르게 저장하도록 수정합니다.
- `desc` 명령 실행 시 `VECTOR` 타입이 **OBJECT**가 아닌 정확한 데이터 타입인 **VECTOR**로 출력되도록 개선합니다.

---

### **Implementation**

1. **`pt_type_enum_to_db()` 함수 수정**

   - `PT_TYPE_VECTOR`에 대한 핸들링 로직을 추가하여 `DB_TYPE_VECTOR`로 변환하도록 수정합니다.

2. **`pt_type_enum_to_db_domain()` 함수 수정**

   - `DB_TYPE_VECTOR` 처리를 추가하여 도메인 생성 시 오류가 발생하지 않도록 수정합니다.

3. **`qexec_schema_get_type_name_from_id()` 함수 수정**

   - `DB_TYPE_VECTOR`를 처리하고 반환값으로 `"VECTOR"` 문자열을 제공하도록 수정합니다.

4. **`tp_Type_id_map` 배열 수정**

   - `tp_Vector`를 배열에 추가하여 데이터 타입 ID와 프리미티브 타입(PR_TYPE) 매핑이 누락되지 않도록 보완합니다.

5. **`tp_Vector` 정의 추가**
   - `tp_Vector` 타입을 정의하여 VECTOR 데이터를 올바르게 시스템에 등록합니다.

---

### **Acceptance Criteria**

- [ ] `csql -u dba testdb -S -c 'desc vt;'` 명령 실행 시 `VECTOR` 타입이 올바르게 출력되는가?

---

### **Definition of Done**

- `desc` 명령 실행 시 `VECTOR` 데이터 타입이 정확하게 **VECTOR**로 출력됩니다.
