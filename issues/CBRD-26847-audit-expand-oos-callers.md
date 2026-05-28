# [OOS] heap_get_visible_version_expand_oos 호출처 전수 조사

## Issue Triage

**이슈 수행 목적** (필수): `heap_get_visible_version_expand_oos` 의 20여 개 호출처를 전수 조사하여, OOS 최적화 (필요한 컬럼만 선택적 읽기) 를 추가로 활용할 수 있는 호출처를 식별한다.

**이슈 수행 이유** (필수):

- **현재 동작 / 배경**: OOS (Out-of-row Storage -- heap 의 큰 가변 컬럼을 외부 페이지로 분리하는 저장 방식) 는 레코드 조회 시 모든 바이트를 읽지 않고 필요한 컬럼만 선택적으로 읽기 위해 도입했다. 이 최적화를 쓰려면 호출자가 `heap_attrinfo` (레코드 해석에 필요한 스키마 정보) 를 알아야 하므로, 현재는 scan manager 와 query executor 에서만 OOS 최적화를 적용했다. 그 외 모든 호출처(`locator_sr.c`, `serial.c`, `catalog_class.c`, `lock_manager.c` 등 20여 곳)에서는 보수적으로 `heap_get_visible_version_expand_oos` 를 사용해 OOS OID 를 자동으로 원본 값으로 치환한 완성본 `recdes` (레코드 디스크립터) 를 만들어 반환한다 -- OOS 의 존재를 전혀 몰라도 기존 로직이 그대로 동작하도록 하기 위해서다.
- **영향**: 성능 저하 -- 보수적 자동 치환 덕분에 정확성은 보장되지만, `heap_attrinfo` 를 이미 갖고 있거나 가변 컬럼 데이터가 아예 불필요한 호출처에서도 `oos_read` I/O 가 발생한다. 전수 조사로 이런 호출처를 찾으면 OOS 최적화 범위를 넓힐 수 있다.

**이슈 수행 방안**:

- 각 호출처에서 반환된 `recdes` 의 실제 사용 범위를 추적하여, 세 가지로 분류한다:
  - (A) `heap_attrinfo` 를 이미 갖고 있어 OOS-aware 읽기가 가능한 호출처 -- OOS 최적화 적용 대상
  - (B) `recdes` 를 NULL 로 넘기거나 헤더/고정 컬럼만 사용하는 호출처 -- expand 자체가 불필요, `heap_get_visible_version` 으로 전환
  - (C) 가변 컬럼 전체가 필요하되 `heap_attrinfo` 없는 호출처 -- 현행 유지 (`expand_oos`)
- hgryoo 와 구두 합의: "heap_get_visible_version_expand_oos 함수를 유지하되, 해당 함수가 expand_oos 할 필요성이 있는지 전수 조사"
- scan manager, query executor 는 이미 OOS 최적화 적용 완료 -- 본 이슈 범위 밖

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **문제 / 목적**: OOS 최적화를 scan manager/query executor 외 호출처로 확대할 수 있는지 조사
- **원인 / 배경**: OOS 도입 시 보수적으로 대부분의 호출처에서 자동 expand 적용
- **제안 / 변경**: 호출처별 recdes 사용 범위 추적 후 분류 (A/B/C)
- **영향 범위**: `locator_sr.c`, `serial.c`, `catalog_class.c`, `lock_manager.c`, `compactdb.c`, `sp_code.cpp`, `load_server_loader.cpp`, `heap_file.c` 등

---

## Description

### 배경

OOS 는 heap 레코드에서 큰 가변 컬럼을 외부 페이지로 분리하는 저장 방식이다. 핵심 이점은 레코드 조회 시 모든 바이트를 읽지 않고 필요한 컬럼만 선택적으로 읽을 수 있다는 점이다.

이 선택적 읽기를 활용하려면 호출자가 `heap_attrinfo` (클래스 표현 정보, 어떤 컬럼이 어디에 있는지 아는 구조체) 를 갖고 있어야 한다. 현재 이 조건을 충족하는 코드 경로는 scan manager 와 query executor 뿐이므로, 이 두 곳에서만 OOS 최적화를 적용해 두었다.

나머지 20여 개 호출처는 OOS 에 대해 전혀 알 필요 없이 기존 로직이 그대로 동작하도록, `heap_get_visible_version_expand_oos` 를 통해 OOS 인라인 슬롯을 자동으로 원본 가변 컬럼 값으로 치환한 완성본 `recdes` 를 반환하게 했다. 이는 정확성을 보장하는 보수적 전략이다.

### 두 함수의 차이

`heap_get_visible_version` 과 `heap_get_visible_version_expand_oos` 는 `context.expand_oos = true` 한 줄만 다르다 (`heap_file.c:26167`). expand_oos 가 켜지면 `heap_record_replace_oos_oids` (`heap_oos.cpp`) 가 레코드 내 OOS 인라인 슬롯마다 외부 페이지에서 blob 을 읽어 원본 레코드를 복원한다.

### 현재 호출처 현황

| 파일 | 호출 횟수 | 비고 |
|------|-----------|------|
| `locator_sr.c` | 7 | lock 획득, force update, replication |
| `serial.c` | 3 | serial 값 읽기 |
| `catalog_class.c` | 3 | catalog 레코드 읽기 |
| `heap_file.c` (내부) | 3 | heap scan 내부 |
| `lock_manager.c` | 1 | lock escalation 시 유효성 확인 |
| `compactdb.c` / `compactdb_sr.c` | 2 | compact 대상 레코드 확인 |
| `sp_code.cpp` | 1 | stored procedure 코드 읽기 |
| `load_server_loader.cpp` | 1 | loaddb 시 레코드 읽기 |

## Specification Changes

N/A -- 외부 동작 변경 없음. 내부 최적화.

## Implementation

각 호출처에 대해 다음 절차를 수행한다:

1. 호출 후 반환된 `recdes` 가 어떤 코드 경로로 전달되는지 추적
2. 세 가지로 분류:
   - **(A) OOS-aware 전환 가능**: `heap_attrinfo` 를 이미 갖고 있거나 확보 가능한 경우. expand 없이 OOS 인라인 슬롯을 유지한 채 필요한 컬럼만 선택적으로 읽도록 변경
   - **(B) expand 불필요**: `recdes` 가 NULL 이거나 헤더/OID 만 확인하는 경우. `heap_get_visible_version` 으로 전환
   - **(C) 현행 유지**: 가변 컬럼 전체가 필요하면서 `heap_attrinfo` 가 없는 경우. `expand_oos` 유지
3. 분류 결과를 표로 정리하여 리뷰 요청

## Acceptance Criteria

- [ ] 모든 호출처를 A/B/C 분류표로 정리
- [ ] 분류 (B) 호출처를 `heap_get_visible_version` 으로 전환
- [ ] 분류 (A) 호출처 중 우선순위 높은 곳에 OOS 최적화 적용 (별도 이슈 분리 가능)
- [ ] OOS 적용 테이블에 대한 기존 SQL/shell 테스트 통과

## Definition of done

- [ ] 위 A/C 충족
- [ ] QA 통과
- [ ] 문서/매뉴얼 반영: N/A (내부 최적화)

## 참고 코드

- `heap_get_visible_version_expand_oos`: `src/storage/heap_file.c:26162`
- `heap_get_visible_version`: `src/storage/heap_file.c:26144`
- `heap_record_replace_oos_oids`: `src/storage/heap_oos.cpp`
- TODO 마커: `heap_file.c:26161` (`TODO (CBRD-26847)`)
- parent: CBRD-26583 (OOS)
