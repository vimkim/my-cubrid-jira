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

### 결론

- **LZ4 자동 압축은 `DB_TYPE_VARCHAR` 1종에만 적용** (임계값 255 바이트 이상).
- OOS 적재 가능한 나머지 가변 타입은 현재 직렬화 단계에서 압축되지 않음.
- `BLOB`/`CLOB` 본문은 외부 ES 저장이므로 OOS 압축 범주 외.
- VARCHAR 단독으로는 OOS 전용 압축 추가 실익이 낮고, 압축 여지는 JSON/콜렉션 타입에 있음.

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
- [ ] 후속 작업으로 OOS 전용 압축(혹은 위 미적용 타입의 직렬화 경로 압축
      도입) 가치 평가를 별도 티켓에서 진행한다.

---

## Remarks

- 결론: **OOS 자체에 별도 압축 레이어를 추가할 실효성은 VARCHAR 에 대해서는
  낮다.** 이미 `tp_String` 경로에서 LZ4 가 적용되어 OOS 페이지에 압축된 바이트가
  저장되기 때문이다.
- 압축 여지가 큰 후보는 **JSON 과 콜렉션 타입(SET/MULTISET/SEQUENCE)** 이다.
  특히 JSON 은 텍스트 기반 직렬화 결과가 그대로 저장되며 일반적으로 압축률이
  높다. 향후 도입 시 진입점은 `mr_data_writeval_json` 또는 OOS 직전의
  공통 압축 단계가 될 수 있다.
- VARNCHAR/NCHAR 는 deprecated 명시 주석이 존재
  (`src/object/object_primitive.c:1714` 부근, "DB_TYPE_NCHAR and DB_TYPE_VARNCHAR
  will no longer be used"). 신규 압축 검토 대상에서 제외 가능.
- 전역 토글 `pr_Enable_string_compression` 이 false 가 되면 VARCHAR 도 압축되지
  않는다. 운영상 이 변수의 변경 가능성도 함께 고려해야 한다.
- 본 분석은 코드 정적 분석 기반이며, 실제 OOS 페이지 dump 로 압축 여부를
  재확인하는 검증 작업은 별도로 수행 가능하다.
