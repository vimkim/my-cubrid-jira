## Description

### 기능 분석 및 배경

**`insert into vt values ('[1, 2, 3]');`** 문장을 지원하기 위해, 파서(Parser)는 다음 단계를 수행해야 합니다:

1. 테이블 **`vt`**의 컬럼 타입과 삽입하려는 값(`'[1, 2, 3]'`)의 타입이 호환되는지 확인해야 합니다.
2. 이를 위해 **테이블 컬럼의 저장된 타입**을 조회해야 하며, 이 경우 타입은 `DB_TYPE_VECTOR`로 저장되어 있습니다.
3. **시맨틱 체킹(Semantic Check)** 단계에서 **`DB_TYPE_VECTOR`를 내부적으로 사용하는 `PT_TYPE_ENUM` 타입으로 변환**해야 합니다.

이 변환을 담당하는 함수는 `pt_db_to_type_enum`입니다.

---

## Spec Changes

현재 **`pt_db_to_type_enum`** 함수에는 `DB_TYPE_VECTOR` 타입에 대한 처리 로직이 구현되지 않았습니다.

코드의 관련 부분은 다음과 같습니다:

```c
    default:
      /* 모든 타입이 여기서 처리되어야 합니다! */
      assert (false);
```

- **`DB_TYPE_VECTOR`** 타입이 정의되어 있지 않기 때문에, 해당 블록이 실행되면서 프로그램이 **비정상 종료(SIGABRT)** 됩니다.

---

## Implementation

`DB_TYPE_VECTOR`를 `PT_TYPE_VECTOR`로 변환하기 위해 **`pt_db_to_type_enum`** 함수에 새로운 로직을 추가합니다.

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
2. 변환 후 **`insert` 문장이 성공적으로 처리**된다.

---

## Definition of Done

위 수용 기준을 만족하면 해당 기능이 구현 완료된 것으로 간주합니다.
