# [OOS] OOS 값 압축 메커니즘 분석 — 타입별 자동 압축 여부 정리

## Description

### 배경

OOS(Out-of-row Overflow Storage)에는 길이가 큰 가변(variable) 컬럼 값이 저장된다.
기능 요구사항 중 하나로 **"OOS 값을 자체적으로 압축해서 저장하는 메커니즘이 필요한가"** 가
제기되었다.

CUBRID 는 이미 일부 가변 타입에 대해 LZ4 기반 자동 압축을 수행하고 있으므로,
OOS 경로에서 별도 압축을 추가하기 전에 **현재 어떤 타입이 압축되고 어떤 타입이
압축되지 않는지** 를 코드로 확인할 필요가 있다.

### 목적

- OOS 에 적재되는 값이 자동 압축되는 경로를 코드로 입증한다.
- 현재 압축이 적용되는 타입과 적용되지 않는 타입을 분리하여 정리한다.
- 향후 OOS 전용 압축 도입 여부 판단의 근거 자료로 활용한다.

### 조사 결론

#### 한 줄 결론

> **모든 OOS 적재 대상 가변 타입에 대해, OOS 에 넣기 직전에 한 번 압축을 시도한다.**
> (= PostgreSQL TOAST 의 `EXTENDED` 정책을 OOS 레이어에서 그대로 구현)

#### 결정 (2026-05-08 OOS 회의)

- **방향**: PostgreSQL TOAST 의 `EXTENDED` 스펙을 따른다 (P사 스펙 채택).
- **구현 위치**: 타입별 직렬화 단계가 아니라 **OOS 진입 직전의 공통 단계** 에 압축을 둔다.
- **동작 순서**: `압축 시도 -> (그래도 크면) OOS 저장` 의 2 단계.
  - PG `EXTENDED` 의 "압축 후에도 임계값을 넘으면 TOAST 로 외부화" 와 동일 구조.
  - 본 문서에서 말하는 **"OOS 저장"** = PG 문서의 "외부(out-of-line) 저장" 에 해당하는 CUBRID 측 용어.
- **결과**: 현재는 `VARCHAR` 만 압축되지만, 변경 후에는 OOS 로 가는 **모든 가변 타입** (`VARCHAR`, `VARNCHAR`, `VARBIT`, `JSON`, `SET`, `MULTISET`, `SEQUENCE`) 이 동일하게 압축 혜택을 받는다.
- **출처**: [CBRD-26592](http://jira.cubrid.org/browse/CBRD-26592) Compression Behavior 표.

#### 왜 이렇게 결정했는가 (현재 코드 상태 요약)

본 조사로 확인한 현재 CUBRID 의 압축 동작은 타입별로 불균일하다.

| 타입 분류 | 대상 타입 | 현재 동작 | PG TOAST 용어로 표현하면 |
|---|---|---|---|
| 압축됨 | `VARCHAR` | `tp_String` 직렬화 시 LZ4 압축 후 OOS 페이지에 기록 | `EXTENDED` 와 동등 |
| 압축 안 됨 | `VARNCHAR`, `VARBIT`, `JSON`, `SET`, `MULTISET`, `SEQUENCE` | 직렬화 시 압축 없이 OOS 페이지에 기록 | `EXTERNAL` 과 동등 |
| 대상 외 | `BLOB`, `CLOB` | 본문은 외부 ES 에 저장, OOS 인라인은 locator 뿐 | OOS 압축 정책의 범주 외 |

즉 **타입에 따라 압축 혜택을 받기도 하고 못 받기도 하는 현재 상태** 를 통일하기 위해, 타입별 경로가 아니라 **OOS 공통 진입점에서 압축** 하기로 정한 것이다.

#### 후속 구현 시 고려사항 (본 티켓 범위 외, 별도 후속 티켓에서 다룸)

1. **공통 압축 단계 신설 위치**: OOS 인서트 경로의 공통 지점 (예: `heap_attrinfo_insert_to_oos` 직전 또는 내부 공통 함수).
2. **알고리즘 / 임계값 선정**: LZ4 / pglz / 기타. PG 의 `pglz` 는 `min_comp_rate >= 25%` 등 압축 효과가 부족하면 원본 유지. CUBRID 도 유사 정책 필요.
3. **이중 압축 회피**: `VARCHAR` 는 이미 `tp_String` 단계에서 LZ4 압축되므로 그대로 다시 압축하면 손해다. 다음 중 하나 선택 필요.
   - case A: type-layer 압축을 OOS 진입 시 해제 -> OOS-layer 에서 재압축
   - case B: type-layer 결과를 그대로 통과 (OOS-layer 에서 skip)
   - case C: `VARCHAR` 에 한해 OOS-layer 압축을 skip
4. **메타 인코딩**: 압축 알고리즘 ID, 원본 크기 등을 OOS 레코드 헤더 또는 인라인 포인터에 적재할 필드 필요. PG `va_extinfo` 에 해당하는 슬롯이 현재 CUBRID OOS 에는 없음 (참조: CBRD-26592 Inline Reference 표).
5. **토글 정책**: 전역 토글 `pr_Enable_string_compression` 을 OOS 압축에도 재사용할지, 별도 파라미터를 둘지 결정.

---

## Analysis

### OOS 진입 조건

`heap_attrinfo_determine_disk_layout()` (`src/storage/heap_file.c:12166-12206`) 에서
컬럼이 OOS 로 가는지 결정한다. 핵심 조건은 다음과 같다.

```c
/* 전체 레코드 크기가 페이지의 1/8 을 초과하면 OOS 후보 분리 */
if (header_size + payload_size + mvcc_extra > DB_PAGESIZE / 8)
  {
    for (i = 0; i < attr_info->num_values; i++)
      {
        /* only variable value can be oos column */
        (*oos_columns)[i] = !attr_info->values[i].last_attrepr->is_fixed
                            && column_size[i] > 512 /* 512 B */;
        ...
      }
  }
```

즉 **고정 길이가 아닌(variable) 타입** 이고 **컬럼 단일 크기가 512 바이트 초과** 인
경우에만 OOS 로 분리된다.

### OOS 직렬화 경로

`heap_attrinfo_insert_to_oos()` -> `heap_attrinfo_dbvalue_to_recdes()`
-> `pr_type->data_writeval(&buf, dbvalue)` (`src/storage/heap_file.c:12359`)

OOS 로 들어가는 데이터는 결국 일반 heap 직렬화와 동일하게 각 타입의
`data_writeval` 콜백을 거쳐 디스크 포맷으로 직렬화된 후 OOS 페이지에 기록된다.
별도의 OOS 전용 직렬화 경로는 없다.

따라서 **각 타입의 `data_writeval` 안에서 압축이 일어나면 OOS 도 자동으로 압축된
바이트를 받게 된다.**

### 자동 압축 메커니즘 (LZ4)

압축 진입점은 `pr_do_db_value_string_compression()` (`src/object/object_primitive.c:14260`).

```c
int
pr_do_db_value_string_compression (DB_VALUE * value)
{
  DB_TYPE db_type;
  ...
  db_type = DB_VALUE_DOMAIN_TYPE (value);

  /* Make sure we clear only for VARCHAR type. */
  if (db_type != DB_TYPE_VARCHAR)
    {
      return rc;		/* do nothing */
    }
  ...
  if (!pr_Enable_string_compression || !OR_IS_STRING_LENGTH_COMPRESSABLE (src_size))
    {
      value->data.ch.medium.compressed_size = DB_UNCOMPRESSABLE;
      return rc;
    }
  ...
  rc = pr_data_compress_string (string, src_size, compressed_string, compressed_size,
                                &compressed_length);
  ...
}
```

압축이 실제로 수행되는 두 가지 게이트:

1. `db_type == DB_TYPE_VARCHAR` 여야 한다.
2. 길이가 `OR_MINIMUM_STRING_LENGTH_FOR_COMPRESSION` 이상이고 `LZ4_MAX_INPUT_SIZE`
   이하여야 한다 (`src/base/object_representation.h:1410-1413`).

```c
#define OR_MINIMUM_STRING_LENGTH_FOR_COMPRESSION 255

#define OR_IS_STRING_LENGTH_COMPRESSABLE(str_length) \
  ((str_length) >= OR_MINIMUM_STRING_LENGTH_FOR_COMPRESSION \
   && (str_length) <= LZ4_MAX_INPUT_SIZE)
```

호출 위치는 두 곳뿐이며 모두 `tp_String` 의 직렬화 경로에 있다
(`src/object/object_primitive.c`).

| 위치 | 함수 | 역할 |
|---|---|---|
| 10531 | `mr_lengthval_string_internal` | 길이 계산 시 한 번 압축 시도 |
| 10603 | `mr_writeval_string_internal` | 디스크 직렬화 시 압축 결과 사용 |

`tp_Char`, `tp_Bit`, `tp_VarBit`, `tp_Json`, `tp_Set`, `tp_Multiset`,
`tp_Sequence`, `tp_Blob`, `tp_Clob` 의 `data_writeval` 콜백에는 위 호출이
존재하지 않는다 (grep 결과 동일: 호출 사이트 2곳뿐).

### 타입과 압축 적용 여부 매핑

`tp_*` 자료구조는 `src/object/object_primitive.c` 에 정의되어 있고,
`variable_p` 필드(세 번째 인자)가 1 이면 가변 타입이다.

| DB_TYPE | PR_TYPE | variable_p | OOS 적재 가능 | data_writeval 내부 압축 |
|---|---|---|---|---|
| `DB_TYPE_VARCHAR` (= `DB_TYPE_STRING`) | `tp_String` | 1 | Yes | **Yes** (LZ4, 길이 >= 255) |
| `DB_TYPE_VARNCHAR` | `tp_String` (alias) | 1 | Yes | No (deprecated; `pr_do_db_value_string_compression` 내부에서 `db_type != DB_TYPE_VARCHAR` 로 차단) |
| `DB_TYPE_CHAR` | `tp_Char` | 0 | No (고정 타입) | N/A |
| `DB_TYPE_NCHAR` | `tp_Char` (alias) | 0 | No (고정 타입) | N/A |
| `DB_TYPE_VARBIT` | `tp_VarBit` | 1 | Yes | No |
| `DB_TYPE_BIT` | `tp_Bit` | 0 | No (고정 타입) | N/A |
| `DB_TYPE_JSON` | `tp_Json` | 1 | Yes | No (`db_json_serialize` 만 수행) |
| `DB_TYPE_BLOB` | `tp_Blob` | 1 | (locator 만 인라인, 데이터는 외부 ES) | N/A (외부 저장) |
| `DB_TYPE_CLOB` | `tp_Clob` | 1 | (locator 만 인라인, 데이터는 외부 ES) | N/A (외부 저장) |
| `DB_TYPE_SET` | `tp_Set` | 1 | Yes | No |
| `DB_TYPE_MULTISET` | `tp_Multiset` | 1 | Yes | No |
| `DB_TYPE_SEQUENCE` | `tp_Sequence` | 1 | Yes | No |
| `DB_TYPE_MIDXKEY` | `tp_Midxkey` | 1 | (인덱스 내부 키, 사용자 컬럼 아님) | N/A |
| `DB_TYPE_VARIABLE` / `DB_TYPE_SUB` / `DB_TYPE_VOBJ` | 내부 전용 | 1 | (사용자 컬럼 아님) | N/A |

### 압축이 OOS 단계 이전에 수행됨에 대한 근거

`heap_attrinfo_dbvalue_to_recdes()` 가 `pr_type->data_writeval` 을 호출하기 전에
`pr_type->get_disk_size_of_value(dbvalue)` 로 디스크 크기를 산출한다
(`src/storage/heap_file.c:12350`).

`tp_String` 의 길이 계산기인 `mr_lengthval_string_internal`
(`src/object/object_primitive.c:10498`) 은 **이 단계에서 이미
`pr_do_db_value_string_compression` 을 호출** 하여 `DB_VALUE` 내부에
`compressed_buf` / `compressed_size` 를 채운다. 이후의 `data_writeval` 은
캐시된 압축 결과를 그대로 기록한다(`DB_TRIED_COMPRESSION` 가드).

따라서 OOS 인서트 이전에 VARCHAR 값은 이미 압축 상태(`compressed_size > 0`)이며,
`oos_insert()` 가 받는 `recdes` 는 압축된 바이트열이다.

### 압축 미적용 타입 정리 (사용자 컬럼 한정)

OOS 진입 가능(가변 길이, 사이즈 > 512B) 하지만 **현재 LZ4 자동 압축이 일어나지
않는** 타입은 다음과 같다.

| 타입 | PR_TYPE / 직렬화 함수 | 비고 |
|---|---|---|
| `DB_TYPE_VARNCHAR` | `tp_String` -> `mr_writeval_string_internal` | 직렬화 함수는 같지만 `pr_do_db_value_string_compression` 의 `if (db_type != DB_TYPE_VARCHAR)` 분기에서 즉시 반환. 단 NCHAR/VARNCHAR 는 deprecate 됨 |
| `DB_TYPE_VARBIT` | `tp_VarBit` -> `mr_writeval_varbit_internal` | LZ4 호출 없음. bit 길이 그대로 기록 |
| `DB_TYPE_JSON` | `tp_Json` -> `mr_data_writeval_json` -> `db_json_serialize` | 직렬화만 수행, 압축 없음 |
| `DB_TYPE_SET` / `DB_TYPE_MULTISET` / `DB_TYPE_SEQUENCE` | `tp_Set` / `tp_Multiset` / `tp_Sequence` -> `mr_data_writeval_set` | 콜렉션 직렬화만 수행, 압축 없음 |

`DB_TYPE_BLOB` / `DB_TYPE_CLOB` 는 LOB 본문이 외부 스토리지(`src/storage/es.c`)에
저장되고 heap/OOS 인라인에는 locator + meta_data 문자열만 들어가므로
"OOS 압축" 의 대상이 아니다.

---

## Findings

### 현재 상태 요약 (조사 결과)

- **LZ4 자동 압축은 `DB_TYPE_VARCHAR` 1종에만 적용** (임계값 255 바이트 이상).
- OOS 적재 가능한 나머지 가변 타입(`VARNCHAR`/`VARBIT`/`JSON`/`SET`/`MULTISET`/`SEQUENCE`)은 현재 직렬화 단계에서 압축되지 않음.
- `BLOB`/`CLOB` 본문은 외부 ES 저장이므로 OOS 압축 정책 범주 외.
- 위 현황은 [상단 "조사 결론"](#조사-결론) 의 EXTENDED-at-OOS 구현 시 기준점 자료로 활용한다.

### OOS 대상 타입별 확인 이력 (compression path)

각 PR_TYPE 의 `data_writeval` 콜백을 직접 열람하여 `pr_do_db_value_string_compression`
또는 다른 압축 호출의 존재 여부를 확인함.

| 타입 | 콜백 함수 | 위치 | LZ4 호출 | 비고 |
|---|---|---|---|---|
| `DB_TYPE_VARCHAR` (`tp_String`) | `mr_writeval_string_internal` -> `pr_do_db_value_string_compression` | `object_primitive.c:10577`, `:10603` | Yes | `mr_lengthval_string_internal:10531` 에서도 호출, 캐시 후 재사용 |
| `DB_TYPE_VARNCHAR` (`tp_String` alias, `:1684`) | 동일 (`mr_writeval_string_internal`) | 동일 | No | `pr_do_db_value_string_compression:14277` 의 `if (db_type != DB_TYPE_VARCHAR)` 분기에서 즉시 반환. NCHAR/VARNCHAR 는 deprecated (`:1714`) |
| `DB_TYPE_VARBIT` (`tp_VarBit`) | `mr_writeval_varbit_internal` | `object_primitive.c:13219-13242` | No | `or_packed_put_varbit` / `or_put_varbit` 만 호출 |
| `DB_TYPE_JSON` (`tp_Json`) | `mr_data_writeval_json` | `object_primitive.c:14629-14655` | No | `db_json_serialize` 만 호출, 압축 없음 |
| `DB_TYPE_SET` / `DB_TYPE_MULTISET` / `DB_TYPE_SEQUENCE` (`tp_Set`/`tp_Multiset`/`tp_Sequence`) | `mr_data_writeval_set` | `object_primitive.c:7019-` | No | `or_put_set` / 디스크 이미지 `memcpy` 만 수행 |
| `DB_TYPE_BLOB` / `DB_TYPE_CLOB` (`tp_Blob`/`tp_Clob`) | `mr_data_writeval_elo` -> `mr_data_writemem_elo` | `object_primitive.c:5803-5839`, `:5958-` | No | 본문은 외부 ES 저장. heap/OOS 인라인은 size + locator + meta_data + type 만 |
| `DB_TYPE_MIDXKEY` (`tp_Midxkey`) | (인덱스 전용) | — | N/A | 사용자 컬럼 아님, OOS 대상 아님 |
| `DB_TYPE_VARIABLE` / `DB_TYPE_SUB` / `DB_TYPE_VOBJ` | (내부 전용) | — | N/A | 사용자 컬럼 아님 |

전역 grep 으로 `pr_do_db_value_string_compression` 호출처는 `mr_lengthval_string_internal:10531` 과
`mr_writeval_string_internal:10603` 두 곳뿐임을 재확인 (다른 가변 타입 직렬화 경로에는 호출 없음).

---

## 참고 코드

| 구성 요소 | 파일 | 행 | 용도 |
|---|---|---|---|
| `heap_attrinfo_determine_disk_layout` | `src/storage/heap_file.c` | 12166-12206 | OOS 컬럼 결정 (가변 타입 + size > 512) |
| `heap_attrinfo_insert_to_oos` | `src/storage/heap_file.c` | 12367-12440 | OOS 인서트 진입점 |
| `heap_attrinfo_dbvalue_to_recdes` | `src/storage/heap_file.c` | 12289-12363 | `pr_type->data_writeval` 호출로 직렬화 |
| `pr_do_db_value_string_compression` | `src/object/object_primitive.c` | 14260-14337 | LZ4 압축 진입 (VARCHAR 한정) |
| `mr_lengthval_string_internal` | `src/object/object_primitive.c` | 10498-10570 | 길이 계산 시 압축 시도 |
| `mr_writeval_string_internal` | `src/object/object_primitive.c` | 10577- | 직렬화 시 압축 결과 사용 |
| `mr_writeval_char_internal` | `src/object/object_primitive.c` | 11623- | CHAR 직렬화, 압축 없음 |
| `mr_writeval_varbit_internal` | `src/object/object_primitive.c` | 13219- | VARBIT 직렬화, 압축 없음 |
| `mr_data_writeval_json` | `src/object/object_primitive.c` | 14629- | JSON 직렬화, 압축 없음 |
| `OR_MINIMUM_STRING_LENGTH_FOR_COMPRESSION` | `src/base/object_representation.h` | 1410 | 압축 임계값 = 255 바이트 |
| `OR_IS_STRING_LENGTH_COMPRESSABLE` | `src/base/object_representation.h` | 1412-1413 | 압축 가능 길이 매크로 |
| `pr_Enable_string_compression` | `src/object/object_primitive.c` | 882 | 전역 압축 토글 (default true) |

---

## Acceptance Criteria

- [x] OOS 적재 경로(`heap_attrinfo_insert_to_oos` -> `data_writeval`) 가
      일반 heap 직렬화 경로와 동일하게 `data_writeval` 콜백을 호출함을 확인한다.
- [x] `pr_do_db_value_string_compression` 이 `DB_TYPE_VARCHAR` 에만 동작하고,
      `OR_MINIMUM_STRING_LENGTH_FOR_COMPRESSION = 255` 임계값을 가짐을 확인한다.
- [x] `tp_String` 외 가변 타입의 `data_writeval` 콜백에 LZ4 호출이 없음을
      확인한다 (`mr_writeval_char_internal`, `mr_writeval_varbit_internal`,
      `mr_data_writeval_json`, `mr_data_writeval_set`).
- [x] OOS 진입 가능하지만 압축이 미적용인 타입 목록을 정리한다
      (VARNCHAR/VARBIT/JSON/SET/MULTISET/SEQUENCE).
- [x] OOS 압축 정책 방향을 의사결정한다 → 2026-05-08 OOS 회의에서
      "P사(PG) `EXTENDED` 스펙을 OOS 레이어 자체에서 구현" 으로 확정
      (상단 [조사 결론](#조사-결론) 참조).
- [ ] EXTENDED-at-OOS 구현 (알고리즘 선정, 이중 압축 회피, 메타 인코딩,
      토글 정책) 을 별도 후속 티켓에서 진행한다.

---

## Remarks

본 섹션의 결정 요약은 상단 [조사 결론](#조사-결론) 으로 이동됨. 아래는 보조
관찰 사항.

- VARCHAR 가 `tp_String` 경로에서 이미 LZ4 압축되는 사실 자체는 EXTENDED-at-OOS
  구현 시 **이중 압축 회피** 분기 설계의 입력이 된다 (조사 결론의 "고려사항"
  참조).
- 압축률 측면에서 가장 효과가 클 후보는 **JSON 과 콜렉션
  타입(SET/MULTISET/SEQUENCE)** 이다. JSON 은 텍스트 기반 직렬화 결과가 그대로
  저장되므로 일반적으로 압축률이 높다.
- VARNCHAR/NCHAR 는 deprecated 명시 주석이 존재
  (`src/object/object_primitive.c:1714` 부근, "DB_TYPE_NCHAR and DB_TYPE_VARNCHAR
  will no longer be used"). 신규 압축 검토 대상에서 제외 가능.
- 전역 토글 `pr_Enable_string_compression` 이 false 가 되면 VARCHAR 도 압축되지
  않는다. OOS 측 압축 토글을 별도로 둘지, 위 변수를 공유할지 후속 설계에서
  결정한다.
- 본 분석은 코드 정적 분석 기반이며, 실제 OOS 페이지 dump 로 압축 여부를
  재확인하는 검증 작업은 별도로 수행 가능하다.

---

## 설계 옵션 비교 (전무님 구두 피드백 사항, 2026-05-19 추가)

### 비교 대상

| ID | 명칭 | 한 줄 요약 |
|---|---|---|
| **A** | OOS 진입 직전 공통 압축 | 현 VARCHAR 압축은 그대로 두고, OOS 적재 직전에 (선택적으로 비-VARCHAR 가변 타입까지) LZ4 로 한 번 감싼다 |
| **B** | `data_writeval` / `pr_do_db_value_string_compression` 일반화 | 현 VARCHAR 와 동일한 시점·동일한 메커니즘을, 다른 가변 타입에도 확장. OOS-layer 는 추가 압축 안 함 |
| **C** | VARCHAR 압축 제거 + OOS-layer 로 단일화 | `pr_do_db_value_string_compression` / `or_put_varchar_internal` 의 압축 분기 제거, 압축은 오직 OOS 레이어 |

### 현재 압축 메커니즘이 박혀 있는 코드 면적 (영향 범위의 기준선)

조사 시점의 grep 집계 (`~`/`.orig` 백업 파일 제외). 사용한 명령:

```bash
# or_put_varchar 류 (6 파일 / 40 hits)
grep -rn --include="*.c" --include="*.cpp" --include="*.h" --include="*.hpp" \
  -E "or_put_varchar|or_packed_varchar_length|or_get_varchar" src/ \
  | grep -v -E '\.orig|\.c~'

# compressed_* (12 파일 / 165 hits, .i 포함)
grep -rn --include="*.c" --include="*.cpp" --include="*.h" --include="*.hpp" --include="*.i" \
  -E "compressed_size|compressed_buf|DB_TRIED_COMPRESSION|DB_UNCOMPRESSABLE" src/ \
  | grep -v -E '\.orig|\.c~'
```

| 식별자 | 정의 위치 | 호출/참조 파일 수 | 총 라인 hit |
|---|---|---|---|
| `pr_do_db_value_string_compression` | `object_primitive.c:14260` | 1 파일 (object_primitive.c 내부 2 호출) | 2 |
| `or_put_varchar_internal` 의 `compressable` 분기 | `object_representation.c:788-900` | 1 정의 | ~110 |
| `or_get_varchar_compression_lengths` | `object_representation.h:2149` (STATIC_INLINE) | 5 파일 | 14 호출 |
| `or_put_varchar` / `or_packed_varchar_length` / `or_get_varchar*` 류 | `object_representation.{c,h}` | **6 파일** (object_primitive.c · object_representation.{c,h} · object_representation_sr.c · network_interface_sr.cpp · query_executor.c) | **40 hits** |
| `compressed_size` / `compressed_buf` / `DB_TRIED_COMPRESSION` / `DB_UNCOMPRESSABLE` (DB_VALUE 필드) | `dbtype_def.h` | **12 파일** (object_representation.h · compressor.hpp · network_interface_sr.cpp · db_macro.c · dbtype_function.{h,i} · dbtype_def.h · dbtype.h · load_sa_loader.cpp · object_primitive.{h,c} · parse_evaluate.c) | **약 165 hits** |
| `pr_Enable_string_compression` 토글 | `object_primitive.c:882` | 2 파일 (`object_primitive.c`, `object_representation.c`) | 4 |

핵심 관찰:

- **압축은 사실상 OR-buf 레이어 (`or_put_varchar_internal`) 에서 이미 일어난다.** `pr_do_db_value_string_compression` 은 `DB_VALUE` 에 결과를 캐시해 두기 위한 사전 호출이며, 디스크 바이트열 자체는 OR helper 가 그 자리에서 `cubcompress::compress<LZ4>` 를 돌린다 (`object_representation.c:840-870`).
- 이 결과는 length prefix 가 `[byte=charlen ≤ 254] | [byte=255 sentinel + int compressed_len + int decompressed_len + bytes]` 두 모드로 나뉘며, **모든 reader (heap, btree, HA log, network, recovery)** 가 `or_get_varchar_compression_lengths` 한 곳을 거쳐 이 layout 을 해석한다.
- 따라서 VARCHAR 압축은 **변경 시 디스크 포맷·WAL 포맷·HA wire 포맷 동시 변경** 이며, 옵션 B/C 가 비싼 진짜 이유는 LOC 가 아니라 이 호환성 면이다.

### A. OOS 진입 직전 공통 압축

#### 개요

- **쓰기 hook**: `heap_attrinfo_insert_to_oos` (`heap_file.c:12485`) — `oos_insert (...)` 호출 직전에 `recdes.data` 를 LZ4 로 감싸고 작은 헤더 (`algo:1B + orig_size:4B`) 를 prepend.
- **읽기 hook 후보 (모두 OOS 페이로드를 다시 가져옴)**:
  - (live) `heap_attrvalue_read_oos_inline` (`heap_file.c:10601-10645`) — `oos_read` 직후 헤더 검사 → 압축 표식이면 LZ4 decompress. 인라인-OOS attr value 읽기의 단일 entry.
  - (dead) `heap_record_replace_oos_oids_with_values_if_exists` (`heap_file.c:7962`) — `heap_file.c:7931, 7953` 두 호출처 (REC_RELOCATION, REC_HOME)에서 진입하지만 함수 첫 줄 `return S_SUCCESS;` (`heap_file.c:7966-7968`) 로 차단되어 있음. 주석: "HOTFIX! todo: this function is buggy. by doing this, we give up unloaddb."
- **Option A 적용 가능성**: HOTFIX 가 살아 있는 동안에는 hook 을 `heap_attrvalue_read_oos_inline` 하나에만 두면 충분. **HOTFIX 가 해제되어 `heap_record_replace_oos_oids_with_values_if_exists` 가 실제로 OOS 를 재읽기 시작하면, 같은 decompress hook 을 두 번째 entry 에도 반드시 복제해야 한다.** 후속 티켓에서 HOTFIX 상태와 묶어 추적한다.
- **이중 압축 회피**: VARCHAR 는 OR-buf 단계에서 이미 LZ4 결과가 들어 있으므로 OOS-layer 압축을 unconditionally skip. (case C: 가장 단순하고 안전).
- **OOS 헤더 변경**: 현 `OOS_RECORD_HEADER` (`oos_file.hpp:26-31`) 는 `total_data_length / chunk_index / next_chunk_oid` 세 필드만 보유. **버전 / 알고리즘 ID 슬롯 없음.** 따라서 압축 메타 식별은 다음 둘 중 하나로 결정해야 한다.
  - (a) `OOS_RECORD_HEADER` 에 `uint8_t version` / `uint8_t algo` 필드 추가 (포맷 break — feat/oos 가 unreleased 이므로 이번 release 안에서만 흡수 가능).
  - (b) 페이로드 prefix 에 magic/sentinel 바이트 (예: `0xC0 0xMP` + algo:1B + orig_size:4B) 를 두고 OOS_RECORD_HEADER 는 그대로 유지 — 비압축 페이로드와 magic 충돌 가능성은 압축 토글 OFF 인 페이로드에서만 발생하므로, 압축 토글 ON 인 OOS 페이로드는 항상 magic 으로 시작한다고 invariant 를 둔다.

#### Pros

- **변경 면적 최소.** OOS 경로 2~3 함수에 국한 (HOTFIX 해제 후에는 3 함수). type 시스템·OR helper·btree·HA·recovery 무관.
- **VARCHAR 디스크 포맷 변경 0** → 기존 데이터 무손실, 인라인 (non-OOS) 행에 한해 롤링 업그레이드 가능. **feat/oos 가 아직 release 되지 않았으므로 OOS 페이지 자체에는 호환성 부채가 없다** (released DB 에 OOS 페이지가 존재하지 않음).
- 토글 한 줄로 OFF 시 원래 거동 회귀.
- 압축 효과가 큰 JSON / SET / MULTISET / SEQUENCE / VARBIT 가 즉시 혜택.
- 향후 알고리즘 교체 (zstd 등) 가 OOS 레이어 안에서 self-contained.

#### Cons / Side-effect

- **압축 정책이 두 곳에 공존** (VARCHAR 는 OR-layer, 나머지는 OOS-layer). 유지보수자가 "이 타입은 어디서 압축되나" 추적 필요. → docs 로 1쪽 짜리 가이드로 완화 가능.
- **이중 압축 회피 분기가 정확해야 함.** VARCHAR 의 OR 결과를 다시 LZ4 에 넣으면 거의 안 줄고 헤더만 늘어남.
- **OOS 헤더 또는 payload prefix 의 식별자 슬롯 신설 필요** → 옵션 (a) 면 `OOS_RECORD_HEADER` 한 번 break, 옵션 (b) 면 magic invariant 문서화 필요.
- **HOTFIX 해제 시 hook 누락 위험.** `heap_record_replace_oos_oids_with_values_if_exists` 가 부활하면 동일 decompress 분기를 빠뜨리지 않도록 후속 PR 에서 같이 들어가야 한다.
- **non-VARCHAR 가변 컬럼 (VARBIT/JSON/SET/MULTISET/SEQUENCE) 의 인라인 ↔ OOS 비대칭.** 인라인 (≤ 512B) 은 비압축, OOS (> 512B) 는 압축으로 같은 컬럼이 행 크기에 따라 압축 여부가 달라진다. VARCHAR 는 인라인에서도 ≥ 255B 면 이미 LZ4 압축되므로 비대칭 영향 없음. JSON/SET 류는 OOS 진입 임계 자체가 512B 이므로 영향 범위가 "큰 행" 으로 한정.
- **카탈로그 컬럼 영향.** 시스템 카탈로그 뷰 (`schema_system_catalog_install_query_spec.cpp` 기준 `VARCHAR(255)` 37 컬럼 + 일부 query_spec 컬럼이 `VARCHAR(1073741823)` 의 클래스 컬럼을 참조) 가 OOS 로 분기되는 경우 압축 페이로드가 카탈로그 reader 에 전달된다. 카탈로그 row 는 일반 heap row 와 같은 경로를 타므로 Option A 의 hook 두 곳을 거치면 자동으로 decompress 된다 → **카탈로그 전용 추가 작업은 불필요**, 단 OOS 진입 카탈로그 row 가 실제로 발생하는지 (현 catalog 가 large blob 컬럼을 가진 경우) 는 단위 테스트로 한 번 더 확인 필요.

#### 예상 LOC (테스트 제외)

| 위치 | 추정 라인 |
|---|---|
| `heap_file.c`: insert hook + read hook + 이중-압축 skip 분기 | 80 |
| `oos_file.{hpp,cpp}`: 헤더 슬롯 + 페이로드 wrapper 헬퍼 | 60 |
| 신규 `oos_compress.{hpp,cpp}` (LZ4 wrapper) | 100 |
| `system_parameter`: 토글 추가 | 20 |
| 단위 + SQL/Shell 테스트 | 200 |
| **합계** | **약 400~500 LOC** |

### B. `data_writeval` / `pr_do_db_value_string_compression` 일반화

#### 개요

- `pr_do_db_value_string_compression` 의 `if (db_type != DB_TYPE_VARCHAR)` 가드 해제 + VARBIT / JSON / SET / MULTISET / SEQUENCE 의 `lengthval`·`writeval`·`readval` 콜백에 동일한 압축 분기 복제.
- 각 타입에 평행한 `or_put_<type>_compressed` / `or_get_<type>_compression_lengths` OR helper 신설.
- 압축 메타 (compressed_length / decompressed_length / sentinel byte) 가 디스크 포맷·인덱스 키 포맷에 동시 진입.

#### Pros

- 압축 정책이 타입 직렬화 콜백 안 한 곳에 모인다 ("타입이 자기 압축을 책임진다").
- OOS 경로 외에도, 인라인 가변 컬럼 (≤ 512B) 까지 압축 혜택 가능.
- 향후 새 가변 타입이 추가되어도 같은 패턴을 따르면 됨.

#### Cons / Side-effect

- **🚨 B-Tree 인덱스 키 포맷 변경.** btree 는 동일한 `data_writeval`/`data_readval` 콜백을 호출하므로, VARBIT/JSON 등이 인덱스 키로 쓰이는 경우 인덱스 페이지 포맷이 바뀐다. 옵션:
  - (b1) 기존 인덱스 호환성을 깬다 → 마이그레이션 강제.
  - (b2) btree 진입 경로에서만 압축 skip 분기 → 호출처 분기 폭증 + per-type 의 lengthval/writeval pair 가 caller 별 동작 분기 (heap-vs-btree).
  - (b3) **btree 인덱스 빌드 시 핫패스 영향.** `btree_load.c:2513` (sort 단계 key 직렬화), `btree_load.c:4065, 4071` (중복 키 비교) 가 `data_readval` 을 직접 호출하므로, 압축 키를 다시 매번 decompress 해야 비교 가능. 인덱스 빌드/리오그 성능 저하가 마이그레이션 비용과 별개로 발생.
- **🚨 HA replication / WAL 포맷 변경.** WAL 의 heap insert/delete redo 레코드가 raw recdes 바이트를 그대로 적재한다. 근거:
  - `heap_file.c:22412`, `heap_file.c:22421` — `log_append_undoredo_recdes (thread_p, RVHF_INSERT, &log_addr, NULL, recdes_p);` (insert).
  - `heap_file.c:23608, 23613` — `log_append_undoredo_recdes (thread_p, RVHF_DELETE, &log_addr, &temp_recdes, NULL);` (delete).
  - `heap_file.c:20825` — `log_append_undoredo_recdes (thread_p, RVHF_MVCC_DELETE_MODIFY_HOME, ...)` (mvcc delete-modify).
  - 즉 `data_writeval` 결과가 그대로 recdes 페이로드가 되어 WAL 에 박힌다. 타입별 압축이 데이터 바이트 layout 을 바꾸면 동일한 RVHF_* recovery handler 가 새/구 양쪽을 디코드할 수 있어야 하며, HA replication 도 동일 페이로드를 슬레이브에 그대로 전달하므로 master/slave 동시 업그레이드가 필수. 롤링 업그레이드 불가.
- **🚨 카탈로그 영향.** system catalog 컬럼이 VARCHAR 외에 JSON 으로 확장된 경우 (없는 경우라도 향후 추가 시) 카탈로그 포맷이 새 DB 와 호환 안 됨.
- `or_get_varchar_compression_lengths` 호출처 14곳을 타입별로 곱하면 신규 helper 호출처가 30~40 곳으로 증가.
- `lengthval` ↔ `writeval` ↔ `readval` triple 의 invariant 가 깨지지 않도록 5 종 타입에 동일한 케어 필요.

#### 예상 LOC

각 행의 근거를 명시한다. 출처 없는 행은 "조사 필요" 로 표기.

| 위치 | 추정 라인 | 근거 |
|---|---|---|
| `object_primitive.c`: VARBIT/JSON/SET/MULTISET/SEQUENCE 의 length/write/read × 5 종 | 600 | 현 `mr_lengthval_string_internal`/`mr_writeval_string_internal` (`object_primitive.c:10498-10650`) 가 약 150 LOC 라인 → 5 종 복제 시 대략 600~750 |
| `object_representation.{c,h}`: 신규 OR helper (5 종) | 400 | `or_put_varchar_internal`/`or_get_varchar*` (`object_representation.c:788-900`) 약 80~110 LOC → 5 종 복제 |
| btree 경로 보정 (인덱스 키 포맷 호환) | 조사 필요 | `btree_load.c:2513, 4065, 4071` + 검색·삽입 경로 모두 영향, 정확한 분기 수는 별도 조사 |
| HA replication / WAL path (recovery handler + replication writer) | 조사 필요 | `log_append_undoredo_recdes` 호출 8 곳 (`heap_file.c:20825, 22412, 22417, 22421, 23104, 23608, 23613, 24497`) 의 새/구 포맷 분기. 단, replication.c / log_manager.c 자체에는 `or_put_varchar`/`compressed_*` 직접 참조 없음 (grep 결과 0 hit) — 영향은 recdes 페이로드 의미론을 거쳐 간접적임 |
| 테스트 (SQL regression, btree key 비교, HA replay) | 500 | 5 종 타입 × insert/read/index/HA 4 시나리오 |
| **합계** | **약 1,500~2,000 LOC + 인덱스/HA 호환성 부채** | 일부 행은 조사 필요로 표시했으므로 상한은 더 커질 수 있음 |

### C. VARCHAR 압축 제거 + OOS-layer 로 단일화

#### 개요

- `pr_do_db_value_string_compression`, `or_put_varchar_internal` 의 `compressable` 분기, `or_get_varchar_compression_lengths`, DB_VALUE 의 `compressed_*` 필드, `DB_TRIED_COMPRESSION`/`DB_UNCOMPRESSABLE` 상태 등 일체 제거.
- 압축 정책은 OOS-layer 단일 위치.

#### Pros

- 코드 중복 제거. 압축 관련 grep 패턴이 `pr_data_compress_string` 한 함수로 줄어든다 (현재 직접 호출 1 사이트 + `pr_do_db_value_string_compression` 경유 2 사이트 → OOS-layer 한 사이트).
- DB_VALUE 라이프사이클이 단순해진다 (`compressed_*` 참조 12 파일 약 165 hits 제거 대상).
- 미래의 유지보수자가 압축 동작을 한 곳에서 이해 가능.

#### Cons / Side-effect

- **🚨🚨 기존 데이터베이스 비호환.** VARCHAR ≥ 255B 가 들어 있는 모든 페이지 (heap + 카탈로그 + btree 인덱스 키) 가 현 `or_get_varchar_compression_lengths` 로 디코드된다. 이 함수 제거 시 기존 페이지 read 불가 → **dump/restore 마이그레이션 강제.**
- **🚨🚨 WAL 비호환.** 기존 WAL 의 heap insert/update redo 레코드 (`log_append_undoredo_recdes (thread_p, RVHF_INSERT, ...)` — `heap_file.c:22412, 22421`) 가 압축 VARCHAR 를 담은 raw recdes 바이트열을 그대로 적재한다. recovery 시 동일 recdes 가 `data_readval` 로 풀리므로, VARCHAR 압축 분기를 제거하면 기존 WAL redo 가 디코드 불가 → 재기동 실패.
- **🚨🚨 HA replication 비호환.** 마스터-슬레이브 동시 변경 필수, 누적 replication log 도 호환 reader 필요. (replication 도 동일한 recdes 페이로드를 전달하므로 WAL 호환성과 운명이 같다.)
- 결과적으로 **"permanent backward-compat reader" 유지가 필수** 이므로 코드 제거 효과의 절반 이상이 상쇄.
- 단순 grep 으로 "VARCHAR 압축이 박힌 곳" 만 12 파일 약 165 hits 이며, 그 중 다수가 매크로/타입 라이프사이클이라 일괄 grep-replace 불가.

#### 예상 LOC

| 작업 | 추정 라인 |
|---|---|
| 제거: `object_primitive.c` (~150) + `object_representation.c` (~80) + `dbtype*.{h,i}` (~30) + `db_macro.c` (~30) + `query_executor.c` (~20) + `network_interface_sr.cpp` (~40) | **−350** |
| 신설: legacy compressed-varchar 디코드 유지 reader (WAL redo · 기존 heap/btree 페이지 read 경로용) | +200 |
| DB version gate + 마이그레이션 도구 (unloaddb/loaddb 확장) | +300 |
| 테스트 (기존 회귀 + 신규 백워드 호환) | +400 |
| **합계** | **약 1,200~1,500 LOC** (단, 비기능 비용 — 마이그레이션 검증·회귀·문서·고객 영향이 LOC 비례 이상) |

> 주: 이전 견적에 포함됐던 `replication.c` / `log_manager.c` 제거 행은 삭제했다. 두 파일에서 `or_put_varchar` / `compressed_*` 직접 참조를 grep 한 결과 0 hit 으로, 해당 파일은 압축 코드 자체를 갖지 않고 recdes 페이로드를 그대로 통과시키기만 한다. WAL/HA 호환 부담은 "신설: legacy reader" 행에 흡수했다.

### 권장안 및 근거

근거:

1. **본 작업의 목적은 다음 측정 가능한 비대칭을 메우는 것이다**: JSON / VARBIT / SET / MULTISET / SEQUENCE 컬럼이 OOS 진입 임계 (> 512B) 를 넘긴 행에서 OOS 페이지 압축 후 크기 / 원본 크기 비율 ≤ 0.7 (LZ4 기준) 을 달성. Option A 단일 변경으로 이 목적이 충족된다.
2. **현 VARCHAR 압축은 production 안정 단계.** CBRD-20158 (`b049ba5ee`, 2018) 에서 처음 도입된 후 CBRD-21558 (`cd36742df`, inline 함수화), CBRD-22638 / CBRD-22993 (NCHAR varying / VARNCHAR 보정), CBRD-23703 / CBRD-26324 (LZ4 라이브러리 교체 및 `cubcompress::compress<LZ4>` API 정착) 까지 7년에 걸친 다수 패치로 안정화되었다. 디스크 / WAL / HA 포맷에 같은 기간 박혀 있으며, B / C 는 LOC 가 아니라 호환성 측면에서 비싸다.
3. **C 가 "너무 breaking 한가?" 의 답: 예, 너무 breaking 합니다.** 단순 LOC 만 보면 1,200~1,500 이지만 disk + WAL + HA 포맷이 동시에 바뀐다. 정량 비교:
   - **호환 부담 차원 수**: A = 1 (OOS payload prefix), B = 3 (인덱스 + WAL + HA wire), C = 4 (heap + WAL + HA + 카탈로그).
   - **마이그레이션 강제 여부**: A = 없음, B = 인덱스 키 포맷에 따라 있음, C = 필수 (dump/restore).
   - **롤링 업그레이드 가능**: A = 가능 (non-OOS 인라인 행 한정, OOS 자체는 unreleased), B = 불가, C = 불가.
   - 즉 같은 1.0~1.5K LOC 라도 A 대비 B/C 의 실제 비용은 검증 surface 와 고객 영향까지 합쳐 수배 (concrete multiplier 는 별도 산정 필요하나 위 차원 수만으로도 단일 자릿수 multiple).
4. A 안은 변경이 **OOS 레이어 + `system_parameter` 토글 한 곳으로 국한** 된다. 후속 알고리즘 교체 (LZ4 → zstd) 도 같은 layer 안에서 self-contained.

이중 압축 회피는 **case C (VARCHAR 일 때 OOS-layer 압축 skip)** 권장. skip 술어를 명시:

```
skip_oos_compression(value) :=
  DB_VALUE_DOMAIN_TYPE(value) == DB_TYPE_VARCHAR
  && charlen >= OR_MINIMUM_STRING_LENGTH_FOR_COMPRESSION  // 255
```

이는 현 `pr_do_db_value_string_compression` (`object_primitive.c:14260`) 의 게이트와 동일 조건이므로, OR-layer 가 압축을 시도한 경우 ↔ OOS-layer 가 skip 하는 경우가 정확히 일치한다 (false-positive/negative 0). **VARNCHAR / VARBIT / JSON / SET / MULTISET / SEQUENCE 는 OR-layer 에서 압축되지 않으므로 모두 OOS-layer 압축 대상.** VARCHAR < 255B 가 OOS 로 들어가는 경우 (즉 인라인 임계 512B 와 압축 임계 255B 사이) 는 OR-layer 가 압축을 안 한 상태이므로 OOS-layer 가 그대로 압축한다.

**권장안: Option A 채택.**

> 후속 티켓 (예: CBRD-26757) 에서 다음을 다룬다:
> - `OOS_RECORD_HEADER` 버전 필드 추가 vs payload prefix magic — 둘 중 어느 방식으로 압축 메타를 식별할지 확정 (`oos_file.hpp:26-31` 의 헤더에 현재 version slot 없음).
> - HOTFIX (`heap_file.c:7966-7968`) 해제 시 `heap_record_replace_oos_oids_with_values_if_exists` 에도 동일 decompress hook 적용.
> - 알고리즘 (LZ4 vs zstd) / 임계값 / `pr_Enable_string_compression` 토글 재사용 여부.
> - 단위 / SQL / shell 테스트 계획:
>   - (i) 압축 대상 6 타입 (VARCHAR / VARNCHAR / VARBIT / JSON / SET / MULTISET / SEQUENCE — VARCHAR 는 skip 술어 검증) 각각에 대한 OOS round-trip (insert → flush → read → compare).
>   - (ii) 알고리즘 ID dispatch — 향후 zstd 도입을 가정해 reader 가 algo 필드를 보고 분기하는 골격 테스트.
>   - (iii) 이중 압축 회피 — VARCHAR ≥ 255B 가 OOS 로 들어갈 때 OOS payload 가 OR-layer 결과를 그대로 통과 (재압축 0 회) 함을 확인.
>   - (iv) 토글 OFF 회귀 — `pr_Enable_string_compression` 또는 신규 OOS 압축 토글 OFF 시 모든 타입이 비압축 페이로드로 저장되며 read 도 정상.
