# [PGBUF] 실제 구현과 다른 주석과 사용되지 않는 코드를 정리한다

## Issue Triage

**이슈 수행 목적**: 페이지 버퍼의 victim 탐색, LRU 구성과 통계 인터페이스를 실제 코드대로 이해할 수 있도록 낡은 설명과 소비처 없는 코드를 정리한다. 의도한 외부 동작의 보존을 변경 범위의 제약으로 삼는다.

**이슈 수행 이유**: 기준 소스에서도 `victim_rich`에 따라 탐색을 반복한다는 주석, 존재하지 않는 garbage LRU 구획 설명, 정의 없는 fix 인터페이스와 `pgbuf_peek_stats`의 잘못된 인자명이 남아 있다. 후속 분석에서 존재하지 않는 정책이나 출력 의미를 전제로 판단할 수 있으므로 정리 대상과 보존 조건을 확인할 필요가 있다.

**영향**: 페이지 버퍼 코드를 읽고 수정하는 개발자와 리뷰어가 영향을 받는다. 예를 들어 통계 헤더의 13번째 출력 인자는 대기 스레드 수처럼 보이지만 실제 값은 direct victim 배정을 기다리는 BCB 수이다. 현재 확인은 소스 분석이며, 고객 장애, 발생 빈도, 성능 손실이나 영향받는 릴리스는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

페이지 버퍼는 디스크 페이지를 메모리 슬롯에 보관하고 사용, 교체와 flush를 관리한다. BCB(Buffer Control Block)는 슬롯의 페이지 식별자, 사용 수와 상태를 관리하는 제어 정보이다. LRU(Least Recently Used) 목록은 교체 후보를 관리하며 shared 목록과 private 목록으로 나뉜다. victim은 재사용할 슬롯의 BCB이며, direct victim은 사용 가능한 BCB를 기다리는 스레드에 직접 넘기는 기존 배정 방식이다.

이 이슈는 [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)의 정리 하위 작업이다. 기존 본문이 제시한 9개 항목군을 CUBRID 커밋 `f6cac312310f39f46711693da157a08f0e725693`에서 다시 확인했다. 해당 커밋은 분석 기준이며 모든 릴리스나 원격 최신 소스를 뜻하지 않는다. 현재 JIRA에는 별도 댓글이 없다.

가장 직접적인 불일치는 `pgbuf_get_victim`의 주석이다. 주석은 자기 private, 다른 private, shared 목록 탐색을 `monitor.victim_rich`가 참인 동안 반복한다고 설명한다. 실제 반복문은 shared 목록 탐색만 감싸며, flush 데몬 부재, 큐의 비어 있지 않음, 소비 커서 진행량과 반복 횟수로 계속 여부를 정한다. `victim_rich` 자체는 선언과 대입만 있고 읽는 코드가 없다. 이는 기존 정책을 설명하는 주석과 현재 제어 흐름이 다르다는 소스 근거이지, 주석대로 정책을 복구해야 한다는 요구는 아니다. [탐색 설명](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9047-L9067), [실제 shared 반복과 마지막 private 탐색 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9140-L9204)

### 왜 문제인가

victim 공급 경로를 분석할 때 주석을 따르면 `victim_rich`를 바꿔 재시도 횟수를 조절할 수 있다고 오해하거나, 세 탐색이 모두 반복되는 전제로 경합과 실패 경로를 해석할 수 있다. 실제 코드를 추적하면 바로잡을 수 있지만, 그때마다 해당 필드의 모든 참조와 반복문 범위를 다시 확인해야 한다. garbage LRU 설명 역시 배열의 private 목록 시작 위치를 잘못 이해하게 한다. 실제 배열은 shared와 private 개수의 합으로 할당하며 private 인덱스는 shared 개수만큼 이동한다. [배열 설명](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L745-L751), [인덱스 정의](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L1025-L1033), [배열 할당](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L5723-L5735)

통계 인터페이스도 구체적인 오독 가능성이 있다. `pgbuf_peek_stats`의 12번째 인자는 헤더와 정의 모두 `alloc_bcb_waiter_med`이지만 서버에서는 low priority 대기 큐의 크기를 채운다. 13번째 인자는 헤더에서 `alloc_bcb_waiter_low`이지만 정의에서는 `flushed_bcbs_waiting_direct_assign`이며, 실제로 flush 후 배정을 기다리는 BCB 큐의 크기를 채운다. 두 출력은 스레드 수와 BCB 수로 대상이 다르다. 모든 인자 타입이 `UINT64 *`이므로 인자명만 보고 새 호출부를 작성하거나 통계를 해석하면 컴파일러가 이 의미의 혼동을 검출하지 못한다. 현재 호출부는 두 값을 각각 올바른 perfmon 슬롯에 전달하므로, 이 이름 불일치만으로 현재 통계 값이 뒤바뀌었다고 주장하지 않는다. [헤더](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.h#L456-L461), [정의와 값](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14698-L14702), [대입](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14773-L14781), [현재 호출부](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/perf_monitor.c#L1949-L1967)

호출되지 않는 AOUT 함수와 정의 없는 fix 선언은 제공되는 기능의 범위를 읽기 어렵게 한다. 특히 `pgbuf_fix_without_validation`은 구현된 우회 API처럼 보이지만, 기준 저장소에는 이를 뒷받침하는 함수 정의나 호출부가 없다. 이 인터페이스를 새로 사용하려는 작업은 구현 유무와 빌드 분기를 별도로 조사해야 한다. 다만 미사용 코드의 바이너리 영향이 전혀 없거나, 정리하면 성능이 좋아진다는 측정 근거는 없다.

### 왜 해결해야 하는가

페이지 버퍼의 교체 경로와 통계 의미를 검토하는 후속 작업에는 현재 코드와 일치하는 설명이 필요하다. 주석을 무시하고 매번 구현을 재추적하는 방법은 가능하지만, 잘못된 설명과 현재 인터페이스가 계속 함께 남는다. 확인된 불일치를 정리하면 후속 변경을 검토할 때 재시도 정책, 목록 경계와 통계 출력의 의미를 다시 구분해야 하는 비용을 줄일 수 있다. 유지보수 시간 절감의 크기나 긴급성을 수치로 확인한 상태는 아니다.

정리 결과가 의도한 외부 동작을 보존해야 한다는 것이 이 작업의 범위이다. 아직 수정본을 만들거나 실행 비교를 하지 않았으므로 무영향을 검증한 결과로 표현하지 않는다. 실제 정책 변경이 필요하다고 판단되는 항목은 이 정리의 삭제 대상으로 자동 확장하지 않고 해당 기능 문제와 분리해 판단한다.

## Evidence

### 기존 9개 항목군의 현재 확인 결과

아래는 정리 후보의 사실 확인이다. 삭제 여부, 설명 문구와 커밋 단위는 확정 구현안이 아니며 ANALYSIS에서 정한다. 검색은 기준 커밋의 저장소 전체를 대상으로 수행했다. 외부 소비자나 별도 패치의 사용 여부까지 증명하지는 않는다.

| 항목 | 현재 확인한 상태 | 근거 |
|---|---|---|
| 1. `monitor.victim_rich` | 필드 선언, 초기화 3회와 quota 조정 시 대입 1회가 있으며 읽는 표현식은 없다. 계산에 쓰는 `total_victims`도 선언, 합산과 이 대입의 입력 외에는 쓰이지 않는다. | [필드](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L690-L692), [초기화](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L1603-L1612), [monitor 초기화](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14012-L14064), [합산](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14322-L14324), [최종 대입](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14456-L14460) |
| 2. victim 탐색 주석 | `victim_rich`로 세 탐색을 반복한다는 설명이 실제 shared 반복문과 다르다. 마지막 자기 private 탐색도 무조건 재시도가 아니라 `!searched_own` 조건이 있다. | [주석](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9051-L9066), [반복과 후속 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9155-L9190) |
| 3. `pgbuf_remove_private_from_aout_list` | static 선언과 정의 및 함수 설명만 있다. 저장소 전체에서 호출이나 주소 참조를 찾지 못했다. SERVER/SA와 debug/release 분기를 함께 검색했다. AOUT 전체 제거의 근거로 확대하지 않는다. | [선언](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L1134-L1137), [정의](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10586-L10669) |
| 4. `UINT16MAX` | 저장소 전체에서 이 매크로는 정의 한 곳뿐이다. | [정의](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L298-L302) |
| 5. garbage LRU 설명 | `buf_LRU_list`의 3구획 설명과 `avoid_shared_lru_idx`의 garbage 예시가 남아 있다. 실제 인덱스와 할당은 shared + private 구성이며 `num_garbage_LRU_list`는 주석 한 곳에만 있다. | [두 주석](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L705-L751), [인덱스](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L1025-L1033) |
| 6. AOUT 설명 | 교체 알고리즘을 LRU + AOUT로 설명하지만 `data_aout_ratio` 기본값은 0이다. SERVER/SA의 parameter tuning도 값을 0으로 설정하며, 초기화는 ratio가 0 이하이면 목록 용량을 0으로 두고 반환한다. 이 기동 경로와 다른 실행 조건을 모두 포괄해 항상 비어 있다고 단정하지 않는다. | [설명](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L614-L618), [기본값](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L3506-L3517), [tuning 분기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L10200-L10204), [비활성 설정과 관련 이슈 주석](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L10235-L10246), [초기화](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L5774-L5788) |
| 7. `goto copy_unflushed_lsa` | DWB 슬롯을 받은 분기에서 `iopage = NULL` 뒤에 이동한다. 분기를 빠져나와도 다음 실행문이 동일한 레이블의 `LSA_COPY`이다. 단순 이동문 후보와 flush 오류 상태 복구는 구분해야 한다. | [분기와 목적지](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10768-L10785) |
| 8. `pgbuf_peek_stats` 인자명 | 6번째의 `vict_candidates`/`victim_candidates` 표기가 다르고, 12번째 `med`는 low priority 큐를 뜻한다. 13번째 헤더 이름은 실제 BCB 출력과 다르다. SERVER_MODE의 단일 호출부는 기존 출력 순서대로 올바른 슬롯을 전달한다. SA 분기는 11~13번째 출력에 0을 채운다. | [헤더](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.h#L456-L461), [정의](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14698-L14702), [대입](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14766-L14781), [호출](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/perf_monitor.c#L1949-L1967) |
| 9. `pgbuf_fix_without_validation` | `NDEBUG` 분기에만 매크로와 `pgbuf_fix_without_validation_release` 선언이 있고, 저장소 전체에 정의와 호출이 없다. 비-`NDEBUG` 분기에는 대응 매크로가 없다. 현재 API가 빌드별로 완성되어 있다는 오해를 줄여야 한다. 실제 호출을 추가한 빌드 실험은 하지 않았다. | [분기 시작](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.h#L281-L287), [NDEBUG 선언](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.h#L325-L336) |

### 검색과 빌드 조건

기준 커밋의 소스 루트에서 다음 검색으로 선언, 정의, 대입, 호출과 주석을 대조했다. 검색 결과가 없다는 판단은 이 저장소의 내용에 한정한다.

```sh
rg -n -uuu 'victim_rich|total_victims|pgbuf_remove_private_from_aout_list|UINT16MAX|fix_without_validation|num_garbage_LRU_list|pgbuf_peek_stats' .
rg -n 'copy_unflushed_lsa|garbage|PGBUF_TOTAL_LRU_COUNT' src/storage/page_buffer.c
```

`page_buffer.c`는 서버와 SA 대상의 소스 목록에 포함된다. Linux CMake 설정에는 release 계열과 나머지 빌드 모두 `-Wno-unused`가 있지만, 이 사실은 모든 플랫폼과 모든 경고가 같다는 보장이 아니다. 주석의 의미나 같은 포인터 타입 사이의 출력 의미는 이 경고 옵션으로 검증되지 않는다. 이 보고서에서는 새로 빌드하거나 실행하지 않았다. [서버 소스 목록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/cubrid/CMakeLists.txt#L539-L544), [SA 소스 목록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/sa/CMakeLists.txt#L541-L546), [Linux 경고 설정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/CMakeLists.txt#L605-L618)

## Specification Changes

의도한 외부 동작, 기존 통계의 의미와 출력 순서, 시스템 파라미터 정책과 디스크 형식을 보존하는 정리를 목표로 한다. 최종 변경 범위에 따른 호환성과 문서 영향은 ANALYSIS에서 확인한다.

기존 본문의 `SHOW PAGE BUFFER STATUS` 검증 전제는 갱신해야 한다. 현재 결과는 19개 컬럼을 유지하지만 그중 9개 카운터 컬럼은 deprecated 상태로 `NULL`을 반환한다. 19개를 모두 유효한 수치로 비교하거나 이 정리에서 폐기 카운터를 되살리는 검증을 요구하지 않는다. 변경 전후 동시 실행의 통계 값이 정확히 일치해야 한다는 기준도 사용하지 않고, 기존 의미와 활성 조건, `NULL` 계약의 보존을 확인한다. [현재 SHOW 계약과 컬럼](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/parser/show_meta.c#L694-L723), [현재 값 생성](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L17422-L17488)

## Implementation

TBD - ANALYSIS 단계에서 결정한다.

9개 항목군에 대해 삭제, 이름 정정, 설명 갱신 또는 근거 있는 유지 중 처리 방식을 정한다. 의도한 동작 보존을 검토할 수 있도록 소비처 검색과 빌드 조건을 기록한다. 정리와 기능 오류 수정을 분리하는 단위도 이때 정하며, 이 문서의 소스 불일치 확인을 삭제안의 사전 승인으로 해석하지 않는다.

## Acceptance Criteria

- [ ] 기존 9개 항목군 각각의 최종 처리와 근거가 기록되고, 미사용으로 판단한 코드에는 대상 빌드 분기를 포함한 참조 확인이 남는다.
- [ ] 남는 victim 탐색, LRU 배열과 AOUT 설명이 실제 제어 흐름, 인덱스와 기동 정책을 설명한다. 기존 주석을 근거로 미선정 정책을 구현하지 않는다.
- [ ] `pgbuf_peek_stats`의 선언과 정의의 출력 이름이 일치하고, 대기 스레드 수와 배정 대기 BCB 수를 구분한다. 기존 호출부의 출력 순서와 대상 통계 의미가 보존된다.
- [ ] 정리 변경의 의도한 외부 동작 보존을 검토·검증하고, 통계의 활성 조건과 기존 `NULL` 계약, 파라미터 정책과 디스크 형식에 의도하지 않은 변경이 없음을 확인한다. 확인하지 못한 범위는 남긴다.

## Definition of done

- [ ] ANALYSIS에서 항목별 범위와 보존 조건을 확정하고 Acceptance Criteria의 확인 근거를 남긴다.
- [ ] 변경한 선언, 구조체와 조건부 코드에 맞춰 서버/SA 및 debug/release의 빌드·링크를 확인한다. 재현 가능한 프로젝트 빌드 명령과 결과를 기록한다.
- [ ] 실제 diff에 비례하는 페이지 버퍼 동작 및 통계 검증을 수행한다. 기능 변경이 발견되면 범위와 관련 이슈를 다시 판단하며, 최종 회귀 범위는 ANALYSIS에서 정한다.
- [ ] 코드 주석·개발 문서·사용자 문서의 반영 필요성을 확인하고 결과를 기록한다.

## Related Issues

- [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193): 상위 페이지 버퍼 작업이다.
- [CBRD-27262](https://jira.cubrid.org/browse/CBRD-27262): 같은 flush 함수의 오류 복구를 다룬다. 항목 7과 수정 위치가 가까워 변경 내용 조율이 필요할 수 있다. 먼저 병합해야만 정리가 가능하다는 기능 의존성은 확인되지 않았다.
- [CBRD-27264](https://jira.cubrid.org/browse/CBRD-27264): 실행되지 않는 direct victim 긴급 배정 경로의 유지·복구·제거 정책은 해당 이슈에서 판단한다. 이 정리의 삭제 대상으로 자동 편입하지 않는다.
- [CBRD-27267](https://jira.cubrid.org/browse/CBRD-27267): big private victim queue의 생산·소비와 사용 정책은 해당 이슈에서 다룬다. 이를 소비자 없는 죽은 코드로 분류해 이 정리에서 제거하지 않는다.
- [CBRD-27266](https://jira.cubrid.org/browse/CBRD-27266): 통계 의미와 관측성의 변경을 다룬다. `pgbuf_peek_stats`의 private 큐 출력은 포인터가 `NULL`이면 대입하지 않는 현재 분기가 있으나, 출력 초기화 계약의 변경은 이 이슈의 인자명 정리와 분리해 조율한다. [조건부 출력](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14709-L14717), [private 큐 출력 분기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14783-L14793)
- [CBRD-20741](https://jira.cubrid.org/browse/CBRD-20741): 현재 소스가 AOUT 비활성 이유로 참조하는 이슈이다. AOUT의 활성화, 전체 제거와 교체 정책 변경은 이 정리의 범위 밖이다.

기존 TODO의 필요성이나 정확성을 검증하지 않고 지우는 작업도 포함하지 않는다. 유지/수정 판단이 필요한 알고리즘과 오류 처리 문제는 별도로 분석한다.

## Triage Request

현재 코드와 다른 설명 및 소비처 없는 항목의 정리 필요성을 확인하고, 제안 작성자 측에 ANALYSIS를 배정해 줄 것을 요청한다. 항목별 처리, 외부 소비자 확인 범위, 빌드 조합과 동작 보존 검증을 정한 뒤 구현 범위를 확정한다. 우선순위와 담당자 확정은 triage 판단으로 남긴다.
