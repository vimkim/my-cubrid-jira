# [OOS] OOS 페이지 탐색이 헤더 페이지 접근 실패와 인터럽트를 버리고 새 페이지 할당으로 넘어간다

**한 줄 요약**: CBRD-27881 OOS 코드 조사에서 찾은 결함 후보(DF-04)로, `oos_find_best_page` 앞쪽의 헤더 접근 실패 경로가 오류를 확인하지 않고 새 페이지 할당으로 넘어가 `ER_INTERRUPTED` 까지 무시하는 문제를 별도로 추적한다.

## Issue Triage

**이슈 수행 목적**: OOS INSERT가 빈 공간을 찾는 도중 헤더 페이지를 읽지 못하면, 사용자 인터럽트는 즉시 호출자에게 전달되고 그 밖의 오류도 일관된 규칙으로 처리되게 한다.

**이슈 수행 이유**: `oos_find_best_page` 는 bestspace 힌트를 보려고 OOS 파일의 헤더 페이지를 먼저 연다. 이 단계의 세 실패 경로가 오류를 확인하지 않고 `oos_alloc_page_with_reclaim`(새 페이지 할당)으로 넘어간다. 같은 함수 뒤쪽에서 헤더를 다시 latch하는 경로는 `ER_INTERRUPTED` 이면 `nullptr` 을 반환하므로, 같은 상황을 두 곳이 다르게 처리한다.

**영향**: 사용자가 큰 값을 넣는 INSERT를 중단해도 OOS 쪽은 멈추지 않고 빈 페이지 회수나 `file_alloc` 을 더 진행할 수 있다. 오류가 지워지지 않은 채 다음 단계로 넘어가므로, 뒤에서 오류를 판단하는 코드가 이 오류를 보게 될 수도 있다. 데이터 손상은 아니다. 둘 다 소스에서 유도한 추론이며 실행으로 확인하지 않았다. 발생 빈도도 측정하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

OOS는 큰 컬럼 값을 heap 행 밖의 전용 파일에 저장하는 방식이다. OOS 값을 쓸 때 `oos_find_best_page` 가 값을 넣을 페이지를 고른다. 먼저 OOS 파일의 헤더 페이지에 있는 bestspace 힌트(여유 공간이 있는 페이지 목록)를 본다. 맞는 페이지가 없으면 `oos_alloc_page_with_reclaim` 을 호출한다. 이 함수는 회수할 수 있는 빈 페이지를 먼저 확인하고, 없으면 `file_alloc` 으로 파일을 키운다.

아래 행 번호는 `feature/oos-merge` 의 `50619ce53` 기준이다.

### 오류를 확인하지 않는 세 경로

[헤더 접근 단계](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/storage/oos_file.cpp#L3013-L3034)에서 다음 세 경우 모두 바로 `oos_alloc_page_with_reclaim` 을 반환한다.

| 행 | 실패 조건 | 처리 |
|---|---|---|
| 3015-3020 | `file_get_sticky_first_page` 가 오류를 반환하거나 헤더 VPID가 NULL | 오류 코드를 보지 않고 새 페이지 할당으로 간다 |
| 3022-3027 | 헤더 페이지 `pgbuf_fix` 가 NULL 반환 | `er_errid ()` 를 보지 않고 새 페이지 할당으로 간다 |
| 3029-3034 | 헤더 stats 포인터가 NULL | 헤더를 놓고 새 페이지 할당으로 간다 |

헤더 페이지는 무조건 latch(`PGBUF_UNCONDITIONAL_LATCH`)로 fix한다. 따라서 `pgbuf_fix` 가 NULL을 반환하는 경우는 latch 대기 시간 초과, 인터럽트, I/O 오류 같은 실제 오류다. 오류 영역(`er_errid ()`)에는 그 오류가 남아 있다.

### 같은 함수 안의 다른 처리

bestspace 동기화를 위해 헤더 latch를 놓았다가 [다시 fix하는 경로](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/storage/oos_file.cpp#L3091-L3101)는 `er_errid () == ER_INTERRUPTED` 이면 `nullptr` 을 반환한다. 그 밖의 오류는 여기서도 새 페이지 할당으로 넘어간다. [bestspace 탐색 자체가 오류를 낸 경우](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/storage/oos_file.cpp#L3052-L3057)는 헤더를 놓고 `nullptr` 을 반환한다.

즉 같은 헤더 fix 실패라도 앞쪽 경로는 인터럽트를 무시하고, 뒤쪽 경로는 인터럽트를 전달한다.

### 관련 작업

- [CBRD-27213](https://jira.cubrid.org/browse/CBRD-27213)은 OOS bestspace 동기화를 재설계하는 이슈다. 이 이슈는 그 재설계와 독립적으로, 현재 탐색 함수의 오류 처리만 다룬다.
- CBRD-27881 리팩토링 후보 R-22(`oos_find_best_page` 의 fallback 정리)는 이 이슈의 오류 처리 규칙이 정해진 뒤에 진행하는 것이 맞다.

### ANALYSIS에서 확인할 것

- 헤더 접근이 실패했을 때 새 페이지 할당으로 넘어가는 것이 의도된 성능상 fallback인지, 오류를 전달해야 하는 경우인지. 인터럽트 외의 오류(latch 시간 초과, I/O 오류)를 어떻게 다룰지가 핵심이다.
- fallback으로 할당에 성공했을 때 오류 영역에 남은 오류를 지워야 하는지, 호출자가 이를 오류로 오인하는 경로가 있는지.
- `oos_alloc_page_with_reclaim` 과 `file_alloc` 이 인터럽트를 스스로 확인하는지. 확인한다면 실제 영향은 회수 한 단계 정도로 작아진다.
- 재현 방법. 헤더 fix 실패를 확정적으로 만들려면 fault injection이나 디버거가 필요할 것으로 보인다(추정).

## Expected Result

헤더 페이지 접근이 `ER_INTERRUPTED` 로 실패하면 `oos_find_best_page` 가 새 페이지를 할당하지 않고 오류를 호출자에게 전달한다. 다른 오류도 함수 안의 모든 헤더 접근 경로에서 같은 규칙으로 처리된다.

## Actual Result

앞쪽 세 경로는 오류 종류와 관계없이 새 페이지 할당으로 넘어간다(소스 확인, 실행 미확인).
