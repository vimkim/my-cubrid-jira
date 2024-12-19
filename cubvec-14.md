### Description

`csql -u dba testdb -S -c 'desc vt;'` 명령어를 실행할 때 **VECTOR** 필드의 데이터 타입이 **OBJECT**로 잘못 출력되는 문제가 확인되었습니다. 이는 `VECTOR` 데이터 타입이 데이터베이스 시스템 전반에 걸쳐 올바르게 정의되고 처리되지 않은 상태에서 발생한 현상입니다.

#### **문제 1: `pt_type_enum_to_db()` 함수의 VECTOR 처리 미비**

`pt_type_enum_to_db()` 함수는 **PT_TYPE_ENUM**과 **DB_TYPE** 간의 매핑을 수행합니다. 그러나 `PT_TYPE_VECTOR` 처리가 누락되어 변환 과정에서 예상치 못한 동작을 유발합니다.

#### **문제 2: `pt_type_enum_to_db_domain()` 함수의 VECTOR 처리 누락**

이 함수는 DB 타입과 도메인을 연결합니다. 하지만 `DB_TYPE_VECTOR` 처리가 빠져 있어 도메인 생성 시 오류가 발생할 가능성이 존재합니다.

#### **문제 3: `qexec_schema_get_type_name_from_id()` 함수의 VECTOR 처리 누락**

이 함수는 DB 타입 ID를 기반으로 데이터 타입 이름을 반환하는 역할을 합니다. `DB_TYPE_VECTOR`에 대한 처리가 없으므로 `desc` 명령에서 데이터 타입이 **UNKNOWN DATA_TYPE**으로 반환되었습니다.

#### **문제 4: `tp_Type_id_map` 배열의 VECTOR 타입 누락**

이 배열은 타입 ID와 PRIMITIVE 타입 간의 매핑을 수행합니다. `tp_Vector`가 배열에 정의되지 않아 시스템 내에서 VECTOR 타입의 등록이 정상적으로 이루어지지 않았습니다.

---

### Spec Changes

1. VECTOR 데이터 타입을 데이터베이스 시스템에 추가 및 등록.
2. VECTOR 데이터를 저장, 조회, 변환할 때 예상치 못한 오류가 없도록 보장.

---

### Implementation

#### **개선 1: `pt_type_enum_to_db()` 함수 수정**

VECTOR 데이터 타입을 처리하기 위해 `PT_TYPE_VECTOR`를 매핑하는 로직을 추가합니다.

```c
case PT_TYPE_VECTOR:
    db_type = DB_TYPE_VECTOR;
    break;
```

#### **개선 2: `pt_type_enum_to_db_domain()` 함수 수정**

VECTOR 데이터 타입의 도메인을 생성할 수 있도록 처리 로직을 보완합니다.

```c
case DB_TYPE_VECTOR:
    return tp_domain_construct (DB_TYPE_VECTOR, NULL, 0);
```

#### **개선 3: `qexec_schema_get_type_name_from_id()` 함수 수정**

VECTOR 데이터 타입의 이름을 반환하도록 로직을 추가합니다.

```c
case DB_TYPE_VECTOR:
    return "VECTOR";
```

#### **개선 4: `tp_Type_id_map` 배열 수정**

VECTOR 데이터 타입을 올바르게 매핑하도록 `tp_Vector`를 배열에 추가합니다.

```c
PR_TYPE *tp_Type_id_map[] = {
    ...
    &tp_Json,
    &tp_Vector,
};
```

또한, `tp_Vector`에 대한 정의를 추가하여 VECTOR 데이터 타입이 올바르게 시스템에 등록되도록 보완합니다.

```c
PR_TYPE tp_Vector = {
    "vector", DB_TYPE_VECTOR, 1, sizeof(SETOBJ *), 0, 4,
    NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL
};
```

---

---

### Acceptance Criteria

- `csql`의 `desc` 명령 실행 시 **VECTOR** 데이터 타입이 제대로 출력될 것.
- 데이터 타입 관련 작업에서 더 이상 예상치 못한 오류가 발생하지 않을 것.

---

### Definition of Done

1. 데이터베이스 환경에서 `VECTOR` 필드를 포함한 테이블을 생성합니다.
2. 아래 명령어를 실행하여 출력값을 확인합니다.

```bash
csql -u dba testdb -S -c 'desc vt;'
```

3. 출력된 데이터 타입이 **VECTOR**로 표시되는지 확인합니다.
4. 표시된다면 완료.
