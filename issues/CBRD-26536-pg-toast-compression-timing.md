# [OOS] PG TOAST 압축 시점 서베이 -- 임계값 초과 시에만 압축 (서베이)

> **TL;DR**: PostgreSQL 은 투플이 페이지 임계값(`TOAST_TUPLE_TARGET`, 기본 약 2 KB)을 초과할 때만 압축을 시도하며, 압축이 충분하지 않으면 외부 저장(externalize)으로 넘어간다. 작은 투플은 루프 자체에 진입하지 않아 압축 비용이 없다.

## Summary

- PG 는 `heaptoast.c:184` (루프 조건) 의 `while (heap_compute_data_size(...) > maxDataLen)` 에서 임계값 초과 여부를 먼저 확인한다. 초과하지 않으면 압축 시도 없음.
- 루프 진입 후 Round 1 압축 / Round 2 외부화 / Round 3 압축 / Round 4 외부화. 즉 압축은 외부화의 전 단계.
- 스토리지 옵션(PLAIN/EXTENDED/EXTERNAL/MAIN)별로 압축/외부화 동작이 다르다.
- OOS 에 압축 도입 시 쓰기 훅 위치, 읽기 경로 부재, 메타데이터 인코딩, 슬라이스 미지원 결합이 검토 대상이다.

## Description

PostgreSQL TOAST 는 heap record 가 페이지에 들어가지 않을 때만 활성화된다. 임계값은 `TOAST_TUPLE_TARGET = TOAST_TUPLE_THRESHOLD` 기준 기본 약 2032 bytes (BLCKSZ=8192, `MaximumBytesPerTuple(4)` -- 페이지에 최소 4 개 투플이 들어가도록 보장하는 매크로). 투플이 이 크기 이하이면 `heaptoast.c:184` 루프 조건이 처음부터 거짓이라 압축 코드가 전혀 실행되지 않는다.
근거 -- 임계값을 넘지 않으면 `while` 조건이 거짓이라 압축 코드는 실행되지 않는다:
*출처: `heaptoast.c:177-198`*
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
루프에 진입하면 4-라운드로 처리한다 (`heaptoast.c:179-271`):

| 라운드 | 대상 | 동작 |
|---|---|---|
| Round 1 | EXTENDED 컬럼 | 압축 시도. 단독으로도 크면 즉시 외부화. |
| Round 2 | EXTENDED/EXTERNAL 잔류 컬럼 | 외부화. |
| Round 3 | MAIN 컬럼 | 압축 시도 (완화된 임계값 적용). |
| Round 4 | MAIN 컬럼 | 외부화. Round 4 까지 외부화해도 임계값을 못 맞추면 그대로 삽입. |

근거 -- 위 표는 PG 자체 주석의 명명을 그대로 따른다. 원문 주석:
*출처: `heaptoast.c:160-167`*
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

스토리지 옵션 요약:

| `attstorage` | 압축 | 외부화 |
|---|---|---|
| PLAIN | 불가 | 불가 |
| EXTENDED | Round 1 에서 시도 | 압축 후에도 크면 시도 |
| EXTERNAL | 생략 | Round 1 즉시 가능 |
| MAIN | Round 3 에서 시도 | Round 4 에서 외부화 |

pglz 자체 임계값 (`pg_lzcompress.c:223`): 입력 32 B 미만이면 압축 생략, 압축 결과가 원본 대비 25% 미만 절약이면 압축을 포기한다. `toast_internals.c:91` 에서 최종 수락 조건 `VARSIZE(compressed) < valsize - 2` 재확인.
근거 -- pglz 의 기본 전략 구조체에 임계값이 직접 정의되어 있다:
*출처: `pg_lzcompress.c:223-227`*
```c
static const PGLZ_Strategy strategy_default_data = {
    32,        /* Data chunks less than 32 bytes are not compressed */
    INT_MAX,   /* No upper limit on what we'll try to compress */
    25,        /* Require 25% compression rate, or not worth it */
    /* ... 추가 파라미터 생략 */
};
```
WAL/Recovery 측면: `oos_rv_redo_insert()` 는 WAL raw bytes 를 `spage_insert_for_recovery()` 로 그대로 재삽입한다 (`oos_file.cpp:1798-1828`). 압축 상태로 WAL 에 기록하면 redo/undo 모두 압축 상태로 복원되어 정상 동작과 일치한다. 현재 구조상 압축은 WAL 경로에 추가 변경을 강제하지 않는 것으로 보이나, undo 경로와 recovery 비용은 별도 검토 필요.

## Notes -- CUBRID OOS 압축 도입 시 소규모 우려 사항

1. **쓰기 훅 삽입 위치**: OOS 로 전송하기 직전 `heap_file.c:12421` 부근 (`heap_attrinfo_dbvalue_to_recdes()` 호출 직후, `oos_insert()` 직전)이 자연스러운 삽입 지점으로 보인다. 이 위치에 압축 로직을 끼우는 것이 침습이 가장 작을 것으로 예상하나 검토 필요.

2. **읽기 경로 압축 해제 부재**: `oos_read()` (`oos_file.cpp:1348`) 및 그 상위 레이어에 현재 압축 해제 로직이 없다. 압축 도입 시 읽기 경로 구현이 선행 조건이다.

3. **압축 메타데이터 저장 위치**: `OR_VAR_FLAG_MASK = 0x3` (`object_representation.h:443`) 의 bit 2 이상을 확장하거나, `OOS_RECORD_HEADER` (현재 16 bytes) 를 확장하는 두 방안이 있다. OOS 는 아직 production 미배포 기능이라 포맷 변경 비용이 낮으나, 어느 방안이든 별도 검토가 필요하다.

4. **슬라이스 읽기 미지원과의 결합**: CUBRID OOS 는 현재 슬라이스 읽기를 지원하지 않아 항상 전체 chunk fetch 가 발생한다 (`oos_file.cpp:1348`). 압축을 도입하면 항상 전체 decompress 가 발생한다.

## Open Questions

1. 압축 알고리즘 (pglz vs lz4) 및 최소 임계값 수치 -- 워크로드 벤치마크 필요.
2. 압축 메타데이터 저장 위치 -- bit 2 확장 vs `OOS_RECORD_HEADER` 확장 결정.
3. 읽기 경로 압축 해제 구현 범위.
4. OOS vacuum 경로가 압축 도입의 영향을 받는가?
