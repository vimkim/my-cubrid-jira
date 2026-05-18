# [OOS] PG TOAST 압축 시점 서베이 — 임계값 초과 시에만 압축

> **한 줄 요약**: PostgreSQL 은 record 가 페이지 임계값 (기본 약 2 KB) 을 넘을 때만 압축을 시도한다. 작은 record 는 압축 코드 자체를 거치지 않는다.

## 결론

**PG 의 EXTENDED 정책만 도입** 한다.

- 가져올 것: 임계값을 넘으면 가장 큰 가변 컬럼부터 한 개씩 외부화 (PG Round 1/2 의 외부화 부분).
- 가져오지 않을 것: pglz 압축 (Round 1 의 inline compress), MAIN 스토리지 옵션 (Round 3/4).
- 압축은 별도 후속 이슈에서 다룬다.

자세한 스펙 (임계값 `DB_PAGESIZE/4` 상향, 큰 컬럼부터 점진 demotion, AC, 다운스트림 영향) 은 [CBRD-26776](http://jira.cubrid.org/browse/CBRD-26776) 참고.

---

## 무엇을 조사했나

질문: PostgreSQL 은 *언제* TOAST 압축을 시도하나? 모든 INSERT 마다 시도하나, 아니면 조건부인가?

답: **조건부** 다. record 가 페이지 임계값을 넘지 않으면 압축 루프 자체에 들어가지 않는다.

## PG 가 어떻게 동작하나

### 1. 입구 조건 — 임계값 초과 검사

`heaptoast.c:177-198` 의 `while` 루프 조건이 곧 입구 검사다. record 크기가 `maxDataLen` 이하면 루프가 한 번도 돌지 않고, 그 결과 압축 코드도 외부화 코드도 실행되지 않는다.

```c
maxDataLen = RelationGetToastTupleTarget(rel, TOAST_TUPLE_TARGET) - hoff;

while (heap_compute_data_size(tupleDesc,
                              toast_values, toast_isnull) > maxDataLen)
{
    biggest_attno = toast_tuple_find_biggest_attribute(&ttc, true, false);
    if (biggest_attno < 0) break;

    if (TupleDescAttr(tupleDesc, biggest_attno)->attstorage == TYPSTORAGE_EXTENDED)
        toast_tuple_try_compression(&ttc, biggest_attno);
    else
        toast_attr[biggest_attno].tai_colflags |= TOASTCOL_INCOMPRESSIBLE;
}
```

임계값 (`TOAST_TUPLE_TARGET`) 은 BLCKSZ 8192 기준 약 2032 bytes 다. `MaximumBytesPerTuple(4)` — *페이지에 최소 4 개 투플이 들어가도록* 보장하는 매크로에서 나온 값이다.

### 2. 루프 안에서는 4 라운드

루프에 들어가면 PG 는 다음 순서로 record 를 줄인다. 각 라운드 끝마다 record 가 임계값 이하로 떨어졌는지 다시 본다.

| 라운드 | 대상 컬럼 | 동작 |
|---|---|---|
| 1 | EXTENDED | 인라인 압축. 압축 후에도 너무 크면 즉시 외부화. |
| 2 | EXTENDED / EXTERNAL 잔류 | 외부화. |
| 3 | MAIN | 인라인 압축 (완화된 임계값). |
| 4 | MAIN | 외부화. 여기까지 해도 임계값 미달이면 그대로 삽입. |

PG 원문 주석 (`heaptoast.c:160-167`) 그대로:

```c
/*
 *    1: Inline compress attributes with attstorage EXTENDED, and store very
 *       large attributes with attstorage EXTENDED or EXTERNAL external
 *       immediately
 *    2: Store attributes with attstorage EXTENDED or EXTERNAL external
 *    3: Inline compress attributes with attstorage MAIN
 *    4: Store attributes with attstorage MAIN external
 */
```

### 3. 스토리지 옵션별 동작

`attstorage` 는 컬럼 단위 속성으로, 압축/외부화 허용 여부를 정한다.

| `attstorage` | 압축 | 외부화 |
|---|---|---|
| PLAIN | 불가 | 불가 |
| EXTENDED | Round 1 에서 시도 | 압축 후에도 크면 시도 |
| EXTERNAL | 생략 | Round 1 즉시 가능 |
| MAIN | Round 3 에서 시도 | Round 4 에서 외부화 |

### 4. pglz 자체의 압축 임계값

루프 안에서 압축이 호출되더라도 pglz 가 한 번 더 거른다 (`pg_lzcompress.c:223-227`):

```c
static const PGLZ_Strategy strategy_default_data = {
    32,        /* Data chunks less than 32 bytes are not compressed */
    INT_MAX,   /* No upper limit on what we'll try to compress */
    25,        /* Require 25% compression rate, or not worth it */
    /* ... */
};
```

- 입력이 32 B 미만이면 압축 스킵.
- 압축 결과가 원본 대비 25% 이상 절약되지 않으면 압축 결과를 버린다.

최종 수락 조건은 `toast_internals.c:91` 의 `VARSIZE(compressed) < valsize - 2` 에서 한 번 더 확인한다.

### 5. WAL / Recovery 측면

`oos_rv_redo_insert()` 는 WAL raw bytes 를 `spage_insert_for_recovery()` 로 그대로 재삽입한다 (`oos_file.cpp:1798-1828`). 압축 상태로 WAL 에 기록하면 redo/undo 모두 압축 상태로 복원되어 정상 동작과 일치한다. 현재 구조상 압축은 WAL 경로에 추가 변경을 강제하지 않는 것으로 보이나, undo 경로와 recovery 비용은 별도 검토 필요.

---

## CUBRID OOS 에 압축 도입 시 검토할 점 (참고용)

본 이슈에서는 압축을 도입하지 않기로 결론지었으나, 후속 이슈를 대비해 검토 사항을 남긴다.

1. **쓰기 훅 위치**: `heap_file.c:12421` 부근 (`heap_attrinfo_dbvalue_to_recdes()` 호출 직후, `oos_insert()` 직전) 이 가장 침습이 작아 보인다.

2. **읽기 경로 압축 해제 부재**: `oos_read()` (`oos_file.cpp:1348`) 와 상위 레이어 모두 압축 해제 로직이 없다. 압축 도입 시 읽기 경로 구현이 선행 조건이다.

3. **압축 메타데이터 저장 위치**: 두 가지 선택지가 있다.
    - `OR_VAR_FLAG_MASK = 0x3` (`object_representation.h:443`) 의 bit 2 이상 확장.
    - `OOS_RECORD_HEADER` (현재 16 bytes) 확장.

   OOS 는 아직 production 미배포라 포맷 변경 비용은 낮다.

4. **슬라이스 읽기 미지원**: CUBRID OOS 는 현재 슬라이스 읽기를 지원하지 않아 항상 전체 chunk fetch 가 발생한다 (`oos_file.cpp:1348`). 압축을 도입하면 매 read 마다 전체 decompress 가 강제된다.

---

## 남은 질문 (후속 이슈에서 결정)

1. 압축 알고리즘 선택 — pglz vs lz4. 워크로드 벤치마크 필요.
2. 압축 메타데이터 저장 위치 — bit 2 확장 vs `OOS_RECORD_HEADER` 확장.
3. 읽기 경로 압축 해제 구현 범위.
4. OOS vacuum 경로가 압축의 영향을 받는가?
