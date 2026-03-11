#### **Description**

Primitive Type의 정보와 연산을 정의하는 `PR_TYPE` 구조체를 기반으로 새로운 Primitive Type인 `tp_Vector`를 구현하고자 합니다.  
기존에 정의된 `tp_Sequence`를 참고하여 필요한 함수와 연산을 추가하며, 공통적으로 사용할 수 있는 set 관련 함수는 그대로 사용하고, 새롭게 정의해야 하는 함수들은 모두 sequence를 모방합니다.

---

#### **Spec Changes**

1. 기존 `tp_Sequence`의 기본 구조를 유지하면서, 미구현된 연산에 대한 추가 작업을 진행합니다.
2. `tp_Sequence`의 패턴을 따라 `vector` 전용 함수 포인터를 정의합니다:
   - 초기화 함수: `mr_initval_vector`
   - 메모리 접근 함수: `mr_getmem_vector`, `mr_setval_vector` 등등...
3. `vector`와 무관하거나 주요 연산과 관련 없는 함수(`freemem`, `cmpval`, `cmpdisk`) 구현은 생략합니다.

---

#### **Implementation**

- `tp_Vector` 정의를 `tp_Sequence`를 기반으로 확장합니다:
  - DB_COLLECTION 전반에 걸쳐 공통적으로 사용할 함수: `mr_initmem_set`, `mr_data_lengthmem_set`, `mr_data_lengthval_set` 등.
  - `vector` 전용 함수: `mr_initval_vector`, `mr_getmem_vector`, `mr_data_cmpdisk_vector` 등. (Sequence를 그대로 모방)
- 새롭게 구현할 함수:
- 최종적으로 `tp_Vector` 구조가 `tp_Sequence`와 동일한 수준으로 동작하도록 구현합니다.

---

#### **Acceptance Criteria**

1. `vector` 타입에 대해 다음 조건을 만족해야 합니다:
   - 삽입, 조회, 삭제와 같은 기본 연산이 정상적으로 동작할 것.
2. 다음과 같은 함수가 모두 정의되어야 합니다.
   - mr_initval_vector
   - mr_getmem_vector
   - mr_setval_vector

---

#### **Definition of Done**

A/C 만족
