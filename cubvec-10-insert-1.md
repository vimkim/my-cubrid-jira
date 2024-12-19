# 문제 배경

사용자는 SQL 쿼리에서 문자열 형태로 된 벡터( `'[1, 2, 3]'` )를 VECTOR 타입으로 처리할 수 있어야 합니다. 이 기능을 구현하기 위해 데이터베이스의 내부 구조와 관련된 많은 부분을 설계하고 구현해야 합니다.

## 주요 구현 과정

### 1. VARCHAR → VECTOR 변환

기본적으로, 문자열( CHAR ) 데이터를 벡터( VECTOR )로 변환해야 합니다. 이를 위해 데이터 타입 간의 호환성을 설정하는 코드( `src/object/object_domain.c` )를 추가합니다.

```c
case DB_TYPE_VECTOR:
  switch (original_type) {
    case DB_TYPE_CHAR:
      status = DOMAIN_COMPATIBLE;
      break;
    default:
      status = DOMAIN_INCOMPATIBLE;
      break;
  }
  break;
```

### 2. 데이터 초기화 로직 추가

데이터베이스가 VECTOR 타입을 초기화( `db_value_domain_init` )할 때, 처리 코드가 없어서 해당 로직을 추가해야 합니다.

- 해결: `DB_TYPE_VECTOR`에 대한 초기화 처리를 구현합니다.

### 3. 데이터 할당 로직 구현

INSERT한 데이터가 SELECT 시 NULL로 조회되지 않도록 벡터 데이터를 처리하는 내부 함수들을 정의해야 합니다.

- 해결: VECTOR에 맞는 함수(`mr_setval_vector`, `mr_data_lengthval_set`, `mr_data_cmpdisk_vector` 등)를 작성하고, 타입 정의 구조체 `tp_Vector`에 추가합니다.

```c
PR_TYPE tp_Vector = {
  "vector", DB_TYPE_VECTOR, 1, sizeof (SETOBJ *), 0, 4,
  mr_initmem_set,
  mr_initval_vector,
  ...
};
```

### 4. 벡터 생성 함수 추가

기존에 SEQUENCE를 생성하는 함수( `set_create_sequence` )처럼, VECTOR를 생성하는 함수도 설계하고 구현해야 합니다.

- 해결: 내부적으로 `DB_TYPE_VECTOR` 타입을 지원하도록 `setobj_create`에 추가합니다.

```c
#define TP_IS_SET_TYPE(typenum) \
  ((((typenum) == DB_TYPE_SET) || ((typenum) == DB_TYPE_MULTISET) || \
    ((typenum) == DB_TYPE_VECTOR) || \
    ((typenum) == DB_TYPE_SEQUENCE)) ? true : false)
```

### 5. 컬럼 정의 기능 추가

벡터 데이터를 처리하기 위해 컬럼 생성 함수( `col_new` )에 벡터 타입 처리를 추가합니다.

```c
case DB_TYPE_VECTOR:
  col->domain = &tp_Vector_domain;
  break;
```

### 6. 값 설정 기능 구현

데이터 값을 설정하는 함수( `setval_set_internal` )에 VECTOR 타입에 대한 로직을 추가합니다.

- 해결: 해당 함수에 VECTOR 처리를 구현합니다.

### 7. XASL 생성 로직 보완

쿼리 실행 계획(XASL) 생성 중, VECTOR 타입을 처리하기 위한 로직을 추가해야 합니다.

- 해결: VECTOR에 대한 도메인 변환 처리( `pt_node_to_db_domain` )를 추가합니다.

```c
case PT_TYPE_VECTOR:
  return tp_Vector_domain;
```

## 최종 결과

이러한 설계 및 구현 작업을 마친 뒤, 아래와 같은 결과를 얻을 수 있습니다.

### 테이블 정의

```sh
csql -u dba testdb -S -c 'desc vt;'
```

```
Field                 Type        Null        Key        Default        Extra
----------------------------------------------------------------------
vec                   VECTOR      YES                    NULL
```

### 데이터 삽입 및 조회

```sh
csql -u dba testdb -S -c "insert into vt values('[1, 2, 3]');"
csql -u dba testdb -S -c "select * from vt;"
```

```
vec
======================
<vector>
```

## 추가 작업 (출력 포맷팅)

SELECT 쿼리 결과에서 벡터 데이터를 NULL이 아닌 의미 있는 값으로 출력하려면 결과 포맷터를 설계하고 구현해야 합니다.

---

# Specification Change

## SQL 파서 변경

SQL 파서에서 VECTOR 타입을 인식할 수 있도록 변경합니다.

- 예: `INSERT INTO vt VALUES('[1, 2, 3]');`와 같은 벡터 리터럴이 허용되도록 처리.

## 도메인 처리 추가

- VECTOR 타입을 도메인 타입으로 추가.
- 기존 `DB_TYPE_CHAR`와의 타입 변환 호환성을 정의.

## 데이터 저장 구조 설계 및 구현

- 벡터 데이터를 적절히 저장하기 위해 `tp_Vector`를 정의.
- VECTOR 데이터를 메모리와 디스크에 저장/로드하는 로직 추가.

## 쿼리 실행 계획 (XASL) 생성 보완

- XASL 생성 과정에서 VECTOR 타입을 처리할 수 있도록 데이터 타입 변환 로직 보완.

## 출력 포맷 설계 및 구현

- SELECT 쿼리 결과에 벡터 데이터를 출력할 수 있도록 포맷터 수정.

---

# Implementation

## DB_TYPE_VECTOR 정의

VECTOR 타입의 구조체( `tp_Vector` ) 정의 및 함수 구현:

- 데이터 초기화, 설정, 비교, 데이터 길이 계산 함수(`mr_initmem_vector`, `mr_setval_vector`, `mr_cmpval_vector` 등).

## VECTOR 변환 로직 구현

- VARCHAR 데이터를 VECTOR로 변환하기 위한 도메인 호환 처리.
- `tp_value_cast`와 관련된 변환 함수 보완.

## 벡터 생성 및 데이터 처리 함수 추가

- `set_create_vector` 함수 구현.
- 컬럼 정의 및 생성 로직( `col_new` )에서 VECTOR 처리 추가.

## SELECT 및 INSERT 지원

- SELECT, INSERT 쿼리에서 VECTOR 타입을 처리하도록 쿼리 실행 로직 보완.
- 벡터 데이터의 SELECT 결과를 출력하는 포맷터 수정.

---

# Acceptance Criteria

- SQL에서 VECTOR 타입이 인식되고 사용할 수 있어야 합니다:

  - **테이블 생성 시 VECTOR 타입 지정 가능.**

    ```sql
    CREATE TABLE vt (vec VECTOR);
    ```

  - **INSERT 쿼리에서 벡터 데이터를 삽입할 수 있어야 함.**

    ```sql
    INSERT INTO vt VALUES('[1, 2, 3]');
    ```

  - **SELECT 쿼리 결과에서 VECTOR 데이터가 적절히 출력되어야 합니다:**

    ```
    vec
    ======================
    [1, 2, 3]
    ```

---

# Definition of Done

- **기능 구현 완료**
- 기존 데이터베이스 기능과 통합 시 문제 없음.
