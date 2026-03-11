#### **Description**

문자열을 VECTOR 타입으로 변환하는 기능을 object_domain.c에 구현해야 합니다.

기존 DB_TYPE_SEQUENCE 타입의 구현 패턴을 참고하여:

1. 문자열을 파싱하여 float 배열로 변환
2. 빈 벡터 생성 (db_vec_create)
3. float 값들을 순차적으로 벡터에 삽입

#### **Spec Changes**

- tp_value_cast_internal 함수에서 DB_TYPE_VECTOR case 추가
- CHAR → VECTOR 타입 변환 로직 구현
- float 배열을 vector로 변환하는 helper 함수 구현 필요

#### **Implementation**

1. 입력 문자열 파싱 구현:

   - 문자열에서 float 값들을 추출하는 파서 구현
   - 추출된 값들을 float 배열로 저장

2. Vector 생성 및 데이터 삽입:

   ```c
   float *float_arr = parse_string_to_float_array(src);
   auto *vec = db_vec_create(NULL, NULL, 0);
   db_make_vector(target, vec);

   for (int i = 0; i < float_arr_size; ++i) {
       db_make_float(&e_val, float_arr[i]);
       db_seq_put(db_get_set(target), i, &e_val);
   }
   ```

이는 sequence 의 PT_NODE가 DB_VALUE로 변환되는 과정을 그대로 모방하였습니다.

위 내용은

```sql
INSERT INTO seq_table (seq) VALUES ({1.1, 2.2, 3.3});
```

쿼리를 수행할 때 실행되는 backtrace를 최대한 참고하여,

- pt_db_value_initialize: DB_VALUE의 기초 틀을 초기화하는 긴 switch-case 문
- pt_seq_value_to_db: Sequence의 파서 노드를 DB_VALUE로 변환

위 함수들의 Sequence 코드를 가져와 Vector에 맞게 변환했습니다.

#### **Acceptance Criteria**

- 문자열 "[1.1, 2.2, 3.3]"을 입력으로 받아서 정상적으로 VECTOR로 변환되어야 함
- 변환된 VECTOR의 각 요소가 올바른 float 값을 가지고 있어야 함

#### **Definition of Done**

- 모든 acceptance criteria를 만족하는 구현 완료
