#### **Description**

vector 타입을 지원하기 위해 INSERT 문을 처리하는 과정에서 다음과 같은 세 가지 함수에 vector에 대한 처리가 필요합니다:

1. **pt_node_to_db_domain**
   - parse_tree에서 DB 도메인을 생성하는 함수로, vector 관련 처리를 추가해야 합니다.
2. **pt_data_type_to_db_domain**
   - 데이터 타입을 DB 도메인으로 변환하는 함수입니다.
3. **pt_dbval_to_value**
   - DB 값에서 내부 값으로 변환하는 함수입니다.

위 함수들은 insert 구문의 mq_translate 의 과정에서 사용되는데, 이때 DB_TYPE_VECTOR를 통해 tp_Vector_domain 을 얻어오는데에 사용됩니다.
그러나 현재 구현되어 있지 않아, DB_TYPE_SEQUENCE 를 모방하여 동일한 연산을 할 수 있도록 vector에 대한 switch case 문을 추가합니다.

---

#### **Spec Changes**

1. pt_node_to_db_domain
   - vector 타입 변환 로직을 추가.
2. pt_data_type_to_db_domain
   - vector 타입 변환 로직을 추가.
3. pt_dbval_to_value
   - vector 값 변환 로직 추가.

---

#### **Implementation**

1. pt_node_to_db_domain
   - 기존 case문에 `DB_TYPE_VECTOR`를 추가하여 vector 타입 도메인을 처리.

```c
case DB_TYPE_SEQUENCE:
case DB_TYPE_VECTOR:
  dt = node->data_type;
```

2. pt_data_type_to_db_domain
   - vector 타입을 처리할 수 있도록 case문에 `DB_TYPE_VECTOR` 추가.

```c
case DB_TYPE_SEQUENCE:
case DB_TYPE_VECTOR:
  return pt_node_to_db_domain (parser, dt, class_name);
```

3. pt_dbval_to_value
   - vector 데이터 값 변환을 위해 case문에 `DB_TYPE_VECTOR` 추가.
   - set 타입과 유사하게 vector 데이터를 변환하고 데이터 타입을 설정.

```c
case DB_TYPE_SEQUENCE:
  result->info.value.data_value.set = pt_set_elements_to_value (parser, val);
  pt_add_type_to_set (parser, result->info.value.data_value.set, &result->data_type);
  break;
case DB_TYPE_VECTOR:
  result->info.value.data_value.set = pt_set_elements_to_value (parser, val);
  pt_add_type_to_set (parser, result->info.value.data_value.set, &result->data_type);
  break;
```

---

#### **Acceptance Criteria**

1. vector 타입이 pt_node_to_db_domain, pt_data_type_to_db_domain, pt_dbval_to_value에서 처리될 수 있어야 합니다.

---

#### **Definition of Done**

A/C
