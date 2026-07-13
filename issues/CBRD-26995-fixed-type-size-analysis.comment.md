## Fixed attribute 타입의 디스크 크기 분석

분석 기준은 `develop` 의 `e3b1bf014ac37fcf3b72b9816a245ff23d9a5e1f` (2026-07-08) 이다.

여기서 **fixed 타입**은 SQL 의미상 고정 길이인 타입이 아니라, `PR_TYPE.variable_p == 0` 이라 class representation 의 fixed attribute 영역에 배치되는 타입을 뜻한다. OOS 후보 여부는 이 물리 분류를 기준으로 판단해야 한다.

### 사용자 컬럼에 사용되는 fixed attribute 타입

| 타입 | fixed payload / column | alignment | 근거 |
|---|---:|---:|---|
| `SMALLINT` (`SHORT`) | 2 bytes | 2 | `tp_Short` |
| `ENUM` | 2 bytes | 2 | enum 문자열이 아니라 `unsigned short` index 만 저장 |
| `INTEGER` | 4 bytes | 4 | `tp_Integer` |
| `FLOAT` | 4 bytes | 4 | `tp_Float` |
| `DATE` | 4 bytes | 4 | `OR_DATE_SIZE` |
| `TIME` | 4 bytes | 4 | `OR_TIME_SIZE` |
| `TIMESTAMP` | 4 bytes | 4 | `OR_UTIME_SIZE` |
| `TIMESTAMPLTZ` | 4 bytes | 4 | `TIMESTAMP` 와 동일한 저장 표현 |
| `BIGINT` | 8 bytes | 4 | `DB_BIGINT` (`int64_t`) |
| `DOUBLE` | 8 bytes | 4 | `tp_Double` |
| `TIMESTAMPTZ` | 8 bytes | 4 | timestamp 4 bytes + `TZ_ID` 4 bytes |
| `DATETIME` | 8 bytes | 4 | date 4 bytes + time 4 bytes |
| `DATETIMELTZ` | 8 bytes | 4 | `DATETIME` 과 동일한 저장 표현 |
| object reference / `OID` | 8 bytes | 4 | `OR_OID_SIZE` |
| `DATETIMETZ` | 12 bytes | 4 | datetime 8 bytes + `TZ_ID` 4 bytes |
| `MONETARY` | 12 bytes | 4 | currency type 4 bytes + amount 8 bytes |
| `BIT(n)` | `ceil(n / 8)` bytes | 1 | domain precision 으로 크기를 계산 |

`tp_Bit` 정의의 `size`/`disksize` 가 `0` 인 것은 payload 가 0 byte 라는 의미가 아니다. `BIT` 은 `mr_data_lengthmem_bit()` 이 `STR_SIZE(precision, RAW_BITS)`, 즉 `(precision + 7) / 8` 을 반환하는 domain-dependent fixed 타입이다.

`DB_MAX_BIT_LENGTH` 는 `0x3fffffff` = 1,073,741,823 bit 이므로, `BIT(n)` 의 선언 가능한 fixed payload 최대 크기는 다음과 같다.

```
ceil(1,073,741,823 / 8)
= 134,217,728 bytes
= 128 MiB
```

`BIT` 을 precision 없이 선언하면 `BIT(1)` 이므로 payload 는 1 byte 이다. 실제 값이 `NULL` 이어도 fixed attribute slot 은 domain 크기만큼 유지되고, NULL 여부는 별도의 bound-bit 영역에 기록된다.

### row 의 fixed 영역 크기

class representation 은 fixed attribute 를 alignment 내림차순으로 정렬한 뒤 각 `tp_domain_disk_size()` 를 합산하고, 마지막 합계를 4-byte boundary 로 올림하여 `fixed_length` 로 저장한다.

```
fixed_length = align4(sum(each fixed column payload))
```

이 값 외에 fixed column 의 NULL 상태를 위한 bound-bit 영역이 `4 * ceil(n_fixed / 32)` bytes 만큼 존재하며, MVCC header 와 variable offset table 은 별도이다. 따라서 위 표는 전체 row 크기가 아니라 **컬럼별 fixed payload** 크기이다.

### OOS 관점의 결론

1. `BIT(n)` 을 제외한 fixed attribute 타입은 컬럼당 최대 12 bytes 이다. 모두 `OR_OOS_INLINE_SIZE` 인 16-byte OOS OID 보다 작으므로, 개별 값을 OOS 로 이관하면 row 가 줄지 않는다.
2. 작은 fixed 컬럼이 매우 많이 모여 큰 row 를 만들 수는 있지만, OOS 는 column 단위 이관이므로 이 타입들을 variable 로 바꾸는 것으로 해결할 수 없다.
3. `BIT(n)` 만 사용자 지정 precision 에 따라 16 bytes 를 크게 초과하여 최대 128 MiB 까지 커질 수 있다. 따라서 현재 fixed attribute 타입 중 `BIT(n)` 이 OOS 대상 전환의 실질적인 유일 후보이다.
4. `CHAR(n)` 은 SQL 의미상 fixed-length 타입이지만 현재 `develop` 에서는 `tp_Char.variable_p == 1` 이므로 이미 variable attribute 영역에 배치된다. `NUMERIC` 도 `tp_Numeric.variable_p == 1` 이다. 이 둘은 이 분석의 fixed attribute 목록에 포함되지 않는다.

주요 코드 근거:

- `src/object/object_primitive.c`: 각 `tp_*` 의 `variable_p`, `disksize`, `alignment`; `tp_Bit`; `mr_data_lengthmem_bit`
- `src/object/object_domain.c`: `tp_domain_disk_size`
- `src/object/schema_manager.c`: `variable_p` 에 따른 fixed/variable 분류 및 fixed attribute 정렬
- `src/base/object_representation_sr.c`: fixed payload 합산 및 `fixed_length` 4-byte 정렬
- `src/base/object_representation_constants.h`: 날짜/시간/OID/MONETARY 디스크 크기
- `src/compat/dbtype_def.h`: `DB_MAX_BIT_LENGTH`, `DB_BIGINT`, `TZ_ID`
- `src/storage/heap_file.c`: NULL fixed attribute 도 domain 크기만큼 padding 하고 bound bit 로 표시

