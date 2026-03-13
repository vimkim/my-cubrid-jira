### Description

**Replication** 및 **Recovery** 기능을 지원하기 위해, heap record 내 **Out-Of-Storage(OOS)** 컬럼을 처리할 수 있는 기능이 필요하다.

`vacuum` 또는 `replication` 과정에서는 `heap recdes` 를 검사하여 `HAS_OOS` flag를 통해 해당 레코드에 **OOS 컬럼이 존재하는지 여부** 를 판단한다. OOS 컬럼이 존재하는 경우, 해당 컬럼에 대한 별도의 처리가 수행되어야 한다.

하지만 현재 구조에서는 **`recdes` 정보만으로 OOS OID를 추출하는 방법이 없으며**, 이를 위해 `classrepr` 정보가 필요하다.
Replication 또는 recovery 과정에서는 `classrepr` 이 항상 보장되지 않기 때문에, **`recdes`만을 기반으로 OOS OID를 추출할 수 있는 기능이 필요하다.**

이를 위해 다음 API를 새롭게 구현한다.

```
heap_recdes_get_oos_oids (const RECDES *recdes)
```

이 API는 **classrepr 없이 `RECDES` 데이터만을 이용하여 OOS OID 배열을 추출** 해야 한다.

---

### Spec Change

Variable Offset Table(VOT)에 **마지막 variable element를 식별할 수 있는 정보** 를 추가한다.

기존에는 VOT의 각 offset이 단순히 컬럼 위치만을 의미했기 때문에, **recdes만으로 variable column의 끝을 판단할 수 없었다.**

이를 해결하기 위해 **마지막 variable element의 offset에 flag를 기록하여 해당 컬럼이 레코드 내에서 물리적으로 마지막 variable column임을 표시한다.**

이 정보를 활용하여 OOS OID 수집 과정은 다음과 같이 수행된다.

1. `HAS_OOS` flag가 설정된 경우에만 OOS OID 수집을 수행한다.
2. VOT의 시작 지점부터 순회한다.
3. 각 offset entry에 대해 다음을 검사한다.

   * `IS_OOS` flag 여부 확인
   * OOS 컬럼일 경우 해당 offset 위치로 이동하여 OOS OID를 읽는다.
4. `LAST_ELEMENT` flag를 가진 VOT entry를 만나면 순회를 종료한다.

이를 통해 **classrepr 없이 recdes만으로 variable column 범위를 판단할 수 있다.**

---

### Implementation

다음 flag 및 매크로를 추가한다.

```c
#define OR_VAR_BIT_LAST_ELEMENT 0x2
#define OR_VAR_FALG_MASK 0x3

#define OR_SET_VAR_OOS(length) ((int) (length) | OR_VAR_BIT_OOS)
#define OR_SET_VAR_LAST_ELEMENT(length) ((int) (length) | OR_VAR_BIT_LAST_ELEMENT)

#define OR_GET_VAR_FLAG(length) ((int) (length) & OR_VAR_FALG_MASK)
#define OR_GET_VAR_LENGTH(length) ((int) (length) & (~OR_VAR_FALG_MASK))

#define OR_IS_OOS(length) (OR_GET_VAR_FLAG (length) & OR_VAR_BIT_OOS)
#define OR_IS_LAST_ELEMENT(length) (OR_GET_VAR_FLAG (length) & OR_VAR_BIT_LAST_ELEMENT)
```

OOS 컬럼을 발견한 경우 OID 추출 방식은 다음과 같다.

```c
if (OR_IS_OOS (offset))
{
  buf.ptr = ((char *) recdes->data + OR_VAR_OFFSET (recdes->data, index));
  buf.endptr = buf.ptr + OR_OID_SIZE;

  or_get_oid (&buf, &oid);
  oos_oids.emplace_back (oid);
}
```

---

### Acceptance Criteria

다음 조건을 만족해야 한다.

**1. API 구현**

```
heap_recdes_get_oos_oids (const RECDES *recdes)
```

* `RECDES` 로부터 OOS OID 배열을 정확하게 추출해야 한다.
* `classrepr` 없이 **recdes만을 이용하여 동작** 해야 한다.

**2. Validation Scenario 통과**

다음과 같은 variable column 변화 상황에서도 정상 동작해야 한다.

**Case 1 — Column 증가**

```
recdes header | VOT | fixed | varchar A | varchar B
recdes header | VOT | fixed | varchar A | varchar B | varchar C
```

**Case 2 — Column 감소**

```
recdes header | VOT | fixed | varchar A | varchar B | varchar C
recdes header | VOT | fixed | varchar A | varchar B
```

위 두 가지 시나리오에서 **정상적으로 OOS OID 추출이 가능해야 한다.**

---

### Definition of Done

* `heap_recdes_get_oos_oids()` API 구현 완료
* recdes 기반 OOS OID 추출 기능 동작 확인
* classrepr 의존성 제거
* Validation scenario 통과
* 코드 리뷰 및 PR merge 완료


