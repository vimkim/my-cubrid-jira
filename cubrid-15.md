## Description

### 문제 상황 분석 및 원인

주어진 **`insert into vt values ('[1, 2, 3]');`** 문장을 실행할 때, **파서(Parser)** 는 다음과 같은 단계를 거칩니다.

1. **테이블 `vt`** 의 컬럼 타입과 삽입하려는 값(`'[1, 2, 3]'`)의 타입이 호환되는지 확인해야 합니다.
2. 이를 위해 **디비에 저장된 컬럼의 타입**을 조회하게 되는데, 여기서 컬럼 타입은 `DB_TYPE_VECTOR`로 저장되어 있습니다.
3. 파서는 **시맨틱 체킹(Semantic Check)** 단계에서 **`DB_TYPE_VECTOR`를 내부적으로 사용하는 `PT_TYPE_ENUM` 타입으로 변환**해야 합니다.
4. 이 변환을 담당하는 함수는 **`pt_db_to_type_enum`** 입니다.

---

### 발생한 문제

현재 **`pt_db_to_type_enum`** 함수에는 `DB_TYPE_VECTOR`에 대한 처리가 **아직 구현되지 않았습니다.**

코드의 해당 부분은 다음과 같습니다:

```c
    default:
      /* ALL TYPES MUST GET HANDLED HERE! */
      assert (false);
```

- **`DB_TYPE_VECTOR`** 타입을 처리하지 않았기 때문에, `default` 블록이 실행되면서 `assert(false)`가 발생합니다.
- 이는 프로그램이 **비정상 종료(SIGABRT)** 되는 원인이 됩니다.

---

### 해결 방법

`DB_TYPE_VECTOR` 타입이 주어지면, 이를 `PT_TYPE_VECTOR`로 변환하도록 처리 로직을 추가해야 합니다.

수정된 코드는 다음과 같습니다:

```c
@@ -2679,2 +2679,5 @@ pt_db_to_type_enum (const DB_TYPE t)
       break;
+    case DB_TYPE_VECTOR:
+      pt_type = PT_TYPE_VECTOR;
+      break;
```

여기서 추가된 부분:

- **`case DB_TYPE_VECTOR:`**: `DB_TYPE_VECTOR`에 대한 처리를 추가합니다.
- **`pt_type = PT_TYPE_VECTOR;`**: `PT_TYPE_VECTOR`로 변환을 수행합니다.

---

### 정리

1. 파서는 시맨틱 체킹을 위해 **DB 타입**을 **PT 타입**으로 변환합니다.
2. `DB_TYPE_VECTOR`를 변환해야 하는 상황에서 변환 로직이 없었기 때문에 **`assert(false)`**가 발생했습니다.
3. 이를 해결하기 위해 `DB_TYPE_VECTOR`를 **`PT_TYPE_VECTOR`**로 변환하는 처리를 **`pt_db_to_type_enum`** 함수에 추가했습니다.

## Implementation

`DB_TYPE_VECTOR`를 `PT_TYPE_VECTOR`로 변환하는 로직을 **`pt_db_to_type_enum`** 함수에 추가합니다.

- **변경 코드:**

  ```c
  @@ -2679,2 +2679,5 @@ pt_db_to_type_enum (const DB_TYPE t)
        break;
  +    case DB_TYPE_VECTOR:
  +      pt_type = PT_TYPE_VECTOR;
  +      break;
  ```

- **변경 위치:**  
  `src/parser/parse_dbi.c` 파일 내 `pt_db_to_type_enum` 함수.

---

## Acceptance Criteria

1. **DB_TYPE_VECTOR**가 **PT_TYPE_VECTOR**로 변환된다.

---

### Definition of Done

1. **코드 구현**: `DB_TYPE_VECTOR`를 `PT_TYPE_VECTOR`로 변환하는 로직이 추가되었다.
2. **빌드 성공**: 변경된 코드로 빌드가 성공적으로 수행된다.
