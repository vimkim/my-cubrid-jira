# [OOS] [M2] 재시작이나 삭제 뒤 새 OOS 페이지를 할당하는 INSERT가 파일 크기에 비례해 느려진다

## Issue Triage

**이슈 수행 목적**: 새 OOS 페이지를 할당하는 INSERT 한 건이 하는 빈 페이지 회수 검사의 양을 OOS 파일 크기와 무관한 상한 안에 둔다. vacuum이 이미 회수를 마친 삭제가 불필요한 검사를 시작하지 않게 한다. 완전히 빈 OOS 페이지가 결국 파일 관리자로 반환된다는 CBRD-26786의 보장은 유지한다.

**이슈 수행 이유**: 성장 게이트 sweep은 서버 재시작 뒤 파일별 첫 새 페이지 할당과, OOS 체인 삭제가 한 건이라도 있은 뒤의 새 페이지 할당에서 실행된다. 회수할 빈 페이지가 없으면 할당 한 번이 파일의 모든 데이터 페이지를 고정해 검사한다. PR #7990의 hornetmj 리뷰(R3)는 OOS 페이지 약 2만 개 파일에서 재시작 직후 첫 INSERT 0.23~0.25초, 1행 삭제와 vacuum 뒤 INSERT 약 12ms(삭제가 없으면 약 1.4ms)를 보고했다. 이 동작은 CBRD-26786에서 완료한 설계이고 OOS 명세의 빈 페이지 회수 불변식을 따른다. 따라서 바꾸려면 불변식도 함께 결정해야 한다.

**영향**: 큰 값을 OOS에 저장하는 테이블에 INSERT하는 응용은 재시작 직후와 삭제가 이어지는 동안 일부 INSERT의 지연이 파일 크기에 비례해 늘어난다. 같은 파일에 새 페이지가 필요한 다른 INSERT는 진행 중인 검사가 끝날 때까지 기다린다. 보고된 영향은 지연이며, 공간 사용이나 결과 정확성의 문제는 보고되지 않았다. 큰 파일에서의 실제 지연, 동시 쓰기 부하에서의 발생 빈도, 오래 열린 쓰기 트랜잭션이 있을 때의 반복 검사 비용은 측정되지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다. 리뷰어가 제안한 발동 조건 축소와 할당당 검사 페이지 상한은 검토할 후보다.

---

## AI-Generated Context

> 아래는 PR #7990 리뷰, CBRD-26786, OOS 명세, `feature/oos-merge`의 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67` 소스를 바탕으로 작성한 상세 맥락이다. 리뷰어 수치는 리뷰어의 보고이며 이 이슈를 쓰면서 재현하지 않았다. 소스 추론과 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

OOS(행 밖에 저장하는 큰 컬럼 값)는 힙 파일마다 둔 OOS 파일의 페이지에 저장된다. 값을 지우면 OOS 페이지가 완전히 빌 수 있다. CBRD-26786은 빈 페이지를 파일 관리자에 돌려주어 OOS 파일이 불필요하게 커지지 않게 했다. 회수 경로는 둘이다.

- vacuum fast path는 OOS 삭제 배치를 커밋한 직후 그 배치가 비운 페이지만 회수한다([`vacuum_oos.cpp`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/query/vacuum_oos.cpp#L182-L194), [`oos_reclaim_empty_pages`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/oos_file.cpp#L1730-L1782)).
- 성장 게이트 sweep은 OOS 파일에 새 페이지가 필요할 때 실행된다. 새 페이지 할당은 모두 [`oos_alloc_page_with_reclaim`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/oos_file.cpp#L2019-L2034)을 지나고, 이 함수는 `file_alloc` 전에 `oos_reclaim_sweep_step`을 부른다. sweep은 fast path가 놓친 빈 페이지를 sector bitmap에서 다시 찾는다.

sweep의 발동 조건은 `pending_deletes > 0 || !swept_this_boot`다([`oos_file.cpp:1868`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/oos_file.cpp#L1868)). 두 값은 파일별 메모리 상태이고 디스크에 남지 않는다.

- [`oos_delete`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/oos_file.cpp#L3534-L3537)는 체인을 지울 때마다 호출자와 무관하게 `pending_deletes`를 올린다. vacuum이 지운 체인도 카운터를 올리고, fast path가 그 페이지를 곧바로 회수해도 카운터는 남는다.
- 재시작하면 메모리 상태가 비어, 파일별 첫 할당이 [boot rule](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/oos_file.cpp#L1840-L1849)로 sweep을 실행한다. 이번 부팅에 만든 파일은 [예외](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/oos_file.cpp#L1395-L1418)다.

sweep 한 번은 파일의 sector 표 전체를 복사해 정렬한 뒤([`oos_file.cpp:1912-1933`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/oos_file.cpp#L1912-L1933)), 저장된 cursor 다음 페이지부터 할당된 데이터 페이지를 차례로 조건부 고정해 검사한다([`oos_file.cpp:1938-1996`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/oos_file.cpp#L1938-L1996)). 첫 페이지를 회수하면 그 자리에서 멈추고, 다음 `file_alloc`이 그 페이지를 다시 쓴다. 회수할 페이지가 없으면 할당 한 번 안에서 파일 한 바퀴(lap)를 모두 검사한 뒤에야 끝나고 cursor는 그대로 남는다. 조건부 고정은 래치 대기만 피하므로, 버퍼에 없는 페이지는 디스크에서 읽는다.

리뷰어는 이 lap이 회수할 것이 없는 상황에서 반복된다고 지적했다([리뷰 원문](https://github.com/CUBRID/cubrid/pull/7990#discussion_r4399899312)). 리뷰어의 측정 조건은 release 빌드, OOS 페이지 약 2만 개(320MB), 버퍼 256MB다.

| 경우 | 발동 이유 | 결과 |
| --- | --- | --- |
| 재시작 뒤 파일별로 새 페이지가 필요한 첫 INSERT | boot rule | 리뷰어 보고. 0.23~0.25초, 이 INSERT가 페이지 20,524개를 검사했다. 다음 INSERT는 1.4~2.7ms다 |
| 체인 삭제 뒤 새 페이지가 필요한 INSERT | `pending_deletes` | 리뷰어 보고. 1행 DELETE와 vacuum 뒤 약 12ms, DELETE가 없으면 약 1.4ms다 |
| LSA 게이트가 빈 페이지를 보류하는 동안의 새 페이지 할당 | 정산 뒤에도 남는 카운터 | 소스 추론. 활성 쓰기 트랜잭션 때문에 보류된 페이지 수가 lap 정산 뒤 카운터에 다시 더해진다([`oos_file.cpp:1802`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/oos_file.cpp#L1802)). 그 트랜잭션이 끝날 때까지 새 페이지 할당마다 lap 전체를 다시 돈다. 측정하지 않았다 |

세 번째 경우는 CBRD-26786 Remarks가 "장수 트랜잭션이 페이지를 계속 defer 시키는 동안의 반복 lap은 후속 최적화 후보"로 적은 것과 같다.

필요한 상태는 새 페이지 할당 한 번이 하는 회수 검사량이 파일 크기와 무관하게 제한되고, 이미 회수가 끝난 삭제가 검사를 시작하지 않는 것이다. 빈 페이지가 결국 반환된다는 보장은 그대로 지켜야 한다.

### 왜 문제인가

큰 값을 OOS에 저장하는 테이블에 행을 넣는 응용은 INSERT 응답 시간이 테이블 크기와 무관하게 일정하기를 기대한다. 운영자는 정기 재시작이나 장애 뒤 재시작을 한 뒤에도 같은 응답 시간을 기대한다.

지금은 재시작 직후 OOS 파일마다 새 OOS 페이지가 필요한 첫 INSERT가 파일 전체를 검사하는 비용을 떠안는다. 같은 파일에 새 페이지가 필요한 다른 INSERT는 그 검사가 끝날 때까지 [기다린다](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/oos_file.cpp#L1850-L1867). UPDATE나 DELETE가 이어져 vacuum이 OOS 체인을 계속 지우는 테이블에서는, 삭제 뒤 새 페이지를 할당할 때마다 회수할 것이 없는 검사가 반복될 수 있다. 검사 비용은 파일 크기에 비례하므로 데이터가 커질수록 지연도 커진다.

확인된 영향은 리뷰어의 단일 세션 측정이다. 리뷰어는 페이지 100만 개 파일이면 재시작 뒤 첫 INSERT가 수 초 이상 걸리고, 삭제가 이어지는 테이블은 할당마다 수백 ms가 든다고 추정했다. 이 값은 측정값을 파일 크기에 비례해 늘린 추정이다. 동시 쓰기 부하에서의 발생 빈도, 오래 열린 쓰기 트랜잭션이 있을 때의 반복 검사 비용, 검사가 버퍼 풀의 다른 페이지를 밀어내는 영향은 측정되지 않았다.

운영자가 이 지연을 다른 원인과 구분하기도 어렵다. sweep 실행과 검사 페이지 수를 남기는 `oos_trace`는 debug 빌드 전용이고([`oos_log.hpp`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/oos_log.hpp#L161-L173)), sweep 전용 통계는 없다.

### 왜 해결해야 하는가

방치하면 OOS 테이블이 클수록 재시작 직후와 삭제가 많은 구간의 INSERT 지연이 커진다. 사용자가 쓸 우회책은 없다. sweep을 끄거나 검사량을 조절하는 설정이 없고, 재시작은 운영에서 피할 수 없다.

현재 동작은 [OOS 명세 §4 빈 페이지 회수 불변식](https://github.com/vimkim/cubrid-oos-context/blob/3462a7f69a7ec0de8a0b97ad8da32b463ecf0e8c/OOS-CONTEXT.md#empty-page-reclaim-invariant-cbrd-26786-accepted-2026-08-28)을 그대로 따른다. 따라서 이 문제는 결함 수정이 아니라 승인된 설계를 바꾸는 성능 개선이다. 명세 결정, 테스트 갱신, 측정을 한 작업 단위로 추적해야 한다.

CBRD-26786은 Resolved이고 PR #7617로 병합됐다. 그 이슈를 다시 열면 완료한 회수 보장과 새 성능 변경이 한 기록에 섞인다. CBRD-26786 Remarks는 sweep과 관련된 후속 후보 두 가지를 남겼다. 하나는 위 세 번째 경우인 LSA 보류 중의 반복 lap이다. 다른 하나는 PR #7617 리뷰 항목 M2의 bitmap 컬렉터 상한과 iterator이며, 그 가운데 sweep이 쓰는 컬렉터 부분이 이 문제와 관련된다. 2026-11-02 JIRA 검색에서 두 후보를 맡은 이슈는 없었다. 같은 형태의 문제를 별도 이슈로 고친 전례도 있다. CBRD-26824는 매 INSERT가 헛된 bestspace sync를 돌아 파일이 커질수록 느려지던 문제였다.

다른 성능 이슈와도 겹치지 않는다. CBRD-27785와 CBRD-27816은 reclaim을 범위에서 명시적으로 뺐다. CBRD-27816 본문은 "OOS reclaim tail은 독립 재현·정합성 검증이 필요한 별도 작업"이라고 적었지만, 그 말이 이 문제를 가리키는지는 본문에 정의가 없어 확인하지 못했다.

sweep 상태는 메모리 전용이므로 이 개선에는 디스크나 로그 형식 변경이 필요 없다. PR #7990 병합 전후 어느 시점에 고쳐도 데이터 호환성 부담은 생기지 않는다. 처리 시점은 아직 정하지 않았다. R3 원댓글에는 병합 전 처리를 요구하는 표현이 없고, 2026-11-02 기준 리뷰 thread에 답글이 없다. 오래 열린 쓰기 트랜잭션이 있을 때의 반복 검사 비용이 크다면 처리 시점을 앞당길 근거가 된다.

## Scope

이 이슈는 OOS 운영 품질(M2, [CBRD-26583](https://jira.cubrid.org/browse/CBRD-26583))의 하위 작업이다. 출처는 [PR #7990 리뷰 R3](https://github.com/CUBRID/cubrid/pull/7990#discussion_r4399899312)다.

이 이슈는 성장 게이트 sweep의 계약을 맡는다.

- sweep의 발동 조건. 리뷰어의 첫 번째 요구다.
- 새 페이지 할당 한 번의 회수 검사량 상한. 리뷰어의 두 번째 요구다.
- 두 결정에 따른 OOS 명세 §4의 불변식과 sweep 규칙 갱신, `unit_tests/oos/test_oos_growth_sweep.cpp` 갱신.
- CBRD-26786 Remarks의 sweep 쪽 후속 후보. LSA 보류 중의 반복 lap과, sweep 실행마다 sector 표 전체를 복사하고 정렬하는 비용이다.

다음은 이 이슈 범위가 아니다.

- 재시작 뒤 부분 여유 페이지의 재사용([PR #7990 리뷰 R4](https://github.com/CUBRID/cubrid/pull/7990#discussion_r4409283403)). [CBRD-27213](https://jira.cubrid.org/browse/CBRD-27213)이 맡는다.
- CBRD-27213이 새로 도입하는 재발견 순회의 비용. CBRD-27213이 맡는다. 그 순회와 성장 게이트 sweep이 같은 sector bitmap을 중복 순회하는 문제는 이 이슈가 정하는 sweep 계약을 따른다.
- PR #7617 리뷰 항목 M2 가운데 3단계 bestspace sync의 VPID 목록 생성 비용. sweep 경로가 아니다.

관련 이슈는 [CBRD-26786](https://jira.cubrid.org/browse/CBRD-26786)(원 설계와 후속 후보의 출처)과 CBRD-27213(R4와 재발견 순회)이다.

## Specification Changes

사용자에게 보이는 SQL 동작은 바뀌지 않는다.

OOS 명세 §4는 "An OOS file reserves a new sector only when no safely reclaimable empty page exists **right now**"를 불변식으로 정한다. sweep 규칙도 같은 절에 있다. 미정산 삭제가 하나라도 있거나 boot rule이 적용되면 sweep을 실행하고, 회수 없는 lap이 끝나야 카운터를 정산한다.

리뷰어의 두 요구는 이 명세를 바꾼다. 할당당 검사량을 제한하면 아직 검사하지 않은 위치에 빈 페이지가 남은 채 파일이 커질 수 있다. 리뷰어도 "순간적으로 페이지가 조금 늘어나는 정도의 차이"라고 이 결과를 인정했다. 발동 조건을 줄이면 fast path가 회수하지 못한 경우를 모두 따로 찾아 sweep을 다시 켜야 한다. ANALYSIS는 불변식을 제한된 형태로 고칠지, 불변식을 유지하는 다른 설계를 고를지 결정하고 명세에 기록한다.

## Implementation

TBD - ANALYSIS 단계에서 결정한다.

## Options for Analysis

아래는 비교를 위한 후보이며 선택한 설계가 아니다.

| 후보 방안 | 기대 효과와 장점 | 한계·단점과 실패 조건 | 비용·위험·호환성 | 근거와 ANALYSIS 확인 사항 |
|---|---|---|---|---|
| 현재 동작 | 회수할 수 있는 빈 페이지가 있으면 sector를 예약하지 않는다 | 회수할 것이 없을 때 할당 한 번이 파일 전체를 검사한다 | 변경 없음 | 리뷰어 측정 |
| A. 발동 조건 축소 (리뷰어 개선안 1) | fast path가 모두 회수한 삭제 뒤의 헛된 lap을 없앤다 | 재시작 뒤 첫 할당과 LSA 보류 중의 반복 lap은 그대로다. 동시 쓰기 부하에서 fast path의 보류가 잦으면 효과가 작다 | fast path가 회수하지 못한 경우를 모두 따로 무장해야 한다. 하나라도 빠지면 빈 페이지가 다음 부팅까지 남는다 | 동시 부하에서 fast path의 회수와 보류 비율. 무장 경로 목록(아래 Acceptance Criteria) |
| B. 할당당 검사 상한과 cursor 이어 가기 (리뷰어 개선안 2) | 세 경우 모두 할당 한 번의 지연을 제한한다 | 빈 페이지가 남은 채 파일이 일시적으로 커질 수 있다. 실행마다 sector 표 전체를 다시 복사하면 sector 수에 비례하는 비용이 남는다 | lap 정산을 여러 할당에 걸쳐 다시 설계해야 한다. 명세 불변식을 완화해야 한다 | 상한 크기, 일시 증가량, sector 표 수집 비용 |
| C. sector 예약이 필요할 때만 sweep | 기존 sector에 빈 비트가 남은 동안([`file_perm_alloc`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/file_manager.c#L5197-L5206)의 `n_page_free > 0`)에는 sweep을 생략한다. 명세 불변식의 문장과 맞는다 | sweep이 실행되는 순간의 비용은 그대로다. 확인과 `file_alloc` 사이에 다른 스레드가 빈 비트를 쓰면 검사 없이 파일이 커질 수 있다 | 파일 헤더 조회가 추가된다. boot rule lap이 늦게 돌므로, CBRD-27213이 sweep에 힌트 복원을 붙이는 안을 고르면 그 복원도 늦어진다 | 확장 조건의 경합 처리. CBRD-27213과의 순서 |
| D. LSA 보류 페이지의 backoff | horizon이 움직이기 전의 반복 lap을 생략한다 | 다른 두 경우에는 효과가 없다 | horizon 전진을 감지해야 한다 | CBRD-26786 Remarks의 후속 후보 |

할당 한 번의 지연 상한을 직접 보장하는 후보는 B뿐이다. A, C, D는 lap 횟수를 줄이지만 lap 한 번의 비용은 그대로 둔다. 그래서 B를 중심에 두고 A나 D를 더해 헛된 lap까지 줄이는 조합이 가장 유력한 후보다. 다만 B를 채택할지는 명세가 일시적인 파일 증가를 받아들이는지에 달려 있다.

리뷰어는 A와 B를 함께 넣은 빌드(상한 64페이지)만 측정했다. 그 빌드에서 재시작 직후 첫 INSERT는 14~33ms였다. 한 세션이 400행을 지운 뒤 다시 넣는 시험에서 OOS 페이지 수는 원래 코드와 같은 501개였다. A만의 효과는 분리하지 못했다. 동시 부하에서 fast path가 얼마나 자주 보류하는지 측정하면 A의 가치를 판별할 수 있다. 리뷰어의 프로토타입 코드는 공개되지 않아, A의 무장 경로를 어디까지 처리했는지는 확인하지 못했다.

## Acceptance Criteria

- 재시작 직후 새 페이지가 필요한 첫 INSERT가 검사하는 페이지 수가 ANALYSIS에서 정한 상한 이하다. 서로 다른 두 파일 크기에서 같은 상한이 유지됨을 계측으로 확인한다.
- vacuum fast path가 삭제 배치의 빈 페이지를 모두 회수했으면, 다음 새 페이지 할당은 회수 검사를 시작하지 않는다.
- 활성 쓰기 트랜잭션 때문에 빈 페이지가 LSA 게이트로 보류된 동안에도, 새 페이지 할당 한 번의 검사량이 같은 상한 이하다.
- 다음 경우에 남은 빈 페이지가 이후 할당 과정에서 회수된다.
  - LSA 보류의 원인이 된 트랜잭션이 끝난 경우
  - fast path가 페이지의 WRITE 고정을 얻지 못한 경우
  - fast path가 READ 경합으로 건너뛴 페이지
  - fast path의 오류와 중단([`vacuum_oos.cpp`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/query/vacuum_oos.cpp#L223-L245))
  - 후보 목록을 만들다 메모리가 부족한 경우([`oos_file.cpp`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/oos_file.cpp#L3397-L3411))
  - SA 모드와 MVCC를 쓰지 않는 클래스의 즉시 삭제([`heap_oos.cpp`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/heap_oos.cpp#L946-L948))
  - INSERT rollback과 복구 redo의 OOS 삭제([`oos_file.cpp`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/oos_file.cpp#L3693))
  - 이전 부팅에서 남은 빈 페이지
- `unit_tests/oos/test_oos_growth_sweep.cpp`의 기존 11개 TEST를 새 동작에 맞게 갱신하고, 위 경우 가운데 빠진 것을 추가한다.
- 리뷰어의 400행 삭제·재삽입 시나리오와 CBRD-26786의 반복 삭제·재삽입 절차에서 OOS 사용 페이지 수가 현재 코드와 같은 수준으로 수렴한다. 허용하는 일시 증가량은 ANALYSIS에서 정한다.
- 재시작 직후 첫 INSERT와 1행 삭제·vacuum 뒤 INSERT의 지연을, 현재 코드와 같은 release 빌드와 설정에서 반복 측정해 분포와 조건을 보고한다. 목표치는 ANALYSIS에서 정한다.
- OOS 명세 §4에 sweep 계약을 기록한다. 계약은 발동 조건, 할당당 검사 상한, cursor 진행 규칙, 불변식의 최종 문장을 포함한다. CBRD-27213의 재발견 순회는 이 계약을 참조한다.

## Definition of done

- `-DUNIT_TEST_OOS=ON`으로 구성한 빌드에서 `test_oos_growth_sweep`을 포함한 OOS 단위 테스트가 모두 통과한다.
- 지연 측정 보고서에 실행 횟수, 분산, 제한 요인을 적는다.
- OOS 명세 갱신이 반영된다.
- PR #7990 R3 리뷰 thread에 이 이슈와 처리 결과를 연결한다.

## Triage Request

새 OOS 페이지를 할당하는 INSERT가 파일 크기에 비례해 느려지는 문제를 확인하고, OOS 담당 작성자 측에 ANALYSIS 배정을 요청한다. 이 이슈는 CBRD-26583의 하위 작업이며, CBRD-26786과 CBRD-27213에 relates로 연결할 것을 제안한다. ANALYSIS에서는 다음을 확인한다.

- 처리 시점. PR #7990 병합 전에 처리할지 병합 뒤 후속으로 처리할지 정한다. R3 리뷰 thread에서 리뷰어의 의견을 받고, 아래 측정 결과를 함께 근거로 쓴다.
- 오래 열린 쓰기 트랜잭션이 있을 때 새 페이지 할당마다의 검사량과 지연. 한 세션이 쓰기 트랜잭션을 연 채, 다른 세션이 삭제와 vacuum 뒤 새 페이지가 필요한 INSERT를 반복하는 조건을 두 파일 크기에서 잰다.
- 동시 쓰기 부하에서 fast path의 회수와 보류 비율, lap 발생 빈도.
- 명세 §4 불변식을 고칠지와, 허용하는 일시적인 파일 증가량.
- 할당당 상한의 크기와, sweep 실행마다 sector 표 전체를 복사하는 비용의 처리.
- CBRD-27213의 재발견 순회와 sweep 계약을 맞추는 방법, 두 순회가 같은 순회 코드를 쓸지 여부.
- lap이 버퍼 풀의 다른 페이지를 밀어내는 영향.
- 리뷰어 프로토타입이 발동 조건 축소에서 무장 경로를 어디까지 처리했는지. 리뷰어에게 diff를 요청한다.
- CBRD-27816이 범위에서 뺀 "OOS reclaim tail"이 이 문제를 가리키는지. 가리킨다면 두 이슈를 연결한다.
