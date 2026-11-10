# [OOS] relocation 행 vacuum이 OOS 삭제가 끝날 때까지 힙 헤더 페이지를 쥐고 있어, 같은 테이블의 INSERT가 vacuum을 기다린다

**한 줄 요약**: [PR #8348](https://github.com/CUBRID/cubrid/pull/8348)(CBRD-27858)의 [리뷰 댓글](https://github.com/CUBRID/cubrid/pull/8348#discussion_r4489753744)을 반영해 검증하던 중 확인한 별도 문제로, vacuum이 relocation 행의 home 페이지를 쥔 채 OOS 삭제를 하는데 그 home 페이지가 힙 헤더 페이지이면 헤더가 필요한 INSERT가 vacuum이 끝날 때까지 기다리는 문제를 다룬다.

## Issue Triage

**이슈 수행 목적**: OOS 값이 있는 relocation 행을 vacuum하는 동안에도, 같은 테이블에 행을 넣는 INSERT가 vacuum의 OOS 삭제 시간만큼 기다리지 않게 한다.

**이슈 수행 이유**: vacuum은 `REC_RELOCATION` 행을 지울 때 home 페이지를 쥔 채 내부 작업(sysop)을 시작하고, 그 안에서 OOS 레코드를 지운 뒤 sysop을 commit한다. 행의 home 페이지가 힙 헤더 페이지이면 이 시간 동안 헤더에도 다른 스레드가 쓰기 래치를 걸 수 없다. INSERT는 새 힙 페이지를 할당할 때와 30초마다 bestspace를 동기화할 때 헤더에 조건 없이 쓰기 래치를 건다. 따라서 그때의 INSERT는 vacuum이 끝날 때까지 기다린다. PR #8348의 검증 중 debug 빌드에서 재현했고, PR #8348 이전부터 있던 동작이라 그 PR과 분리한다.

**영향**: vacuum의 OOS 삭제가 오래 걸리면 같은 테이블의 INSERT 응답 시간이 그만큼 늘어난다. 재현에서는 vacuum을 인위로 최대 약 120초 멈췄고, INSERT가 63~123초를 기다렸다. 실제 OOS 삭제가 얼마나 걸리는지, 운영 환경에서 얼마나 자주 겹치는지는 측정하지 않았다. 교착은 아니며, vacuum이 끝나면 INSERT도 끝난다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 어디서 기다리는가

분석 기준은 PR #8348 head `225375922881fb0f61cc311458078264961eef79`이다.

- vacuum: [`vacuum_heap_record`](https://github.com/CUBRID/cubrid/blob/225375922881fb0f61cc311458078264961eef79/src/query/vacuum.c#L2636-L2702)는 `REC_RELOCATION` 행에서 `log_sysop_start` 뒤 forward 슬롯을 비우고, `vacuum_heap_oos_delete_within_sysop`으로 OOS 레코드를 지운 다음 `log_sysop_commit`을 한다. 이 동안 호출자는 home 페이지를 쥐고 있다.
- INSERT, 새 페이지 할당: [`heap_alloc_new_pages`](https://github.com/CUBRID/cubrid/blob/225375922881fb0f61cc311458078264961eef79/src/storage/heap_file.c#L29232)는 힙 헤더를 `PGBUF_LATCH_WRITE`로 고정한다. 맞는 후보 페이지가 없을 때 bestspace가 이 함수를 부른다.
- INSERT, bestspace 동기화: [`heap_find_bestpage`](https://github.com/CUBRID/cubrid/blob/225375922881fb0f61cc311458078264961eef79/src/storage/heap_file.c#L4786-L4788)는 `bestspace::updatable()`이 참이면, 즉 마지막 동기화 후 30초가 지나면 [`heap_update_bestspace`](https://github.com/CUBRID/cubrid/blob/225375922881fb0f61cc311458078264961eef79/src/storage/heap_file.c#L4386)를 부르고, 이 함수가 헤더를 쓰기 래치로 고정한다.

OOS가 없는 `develop`의 relocation vacuum은 sysop 안에서 OOS 삭제를 하지 않는다. 그래서 헤더를 쥐는 시간이 짧다. OOS 삭제가 sysop 안으로 들어오면서 이 대기가 길어질 수 있게 됐다고 본다(소스 읽기에서 추론).

### 재현에서 확인한 것

debug 빌드에 로컬 전용 hook을 넣어 OOS 삭제 직전에 vacuum을 최대 약 120초 멈추고, 그동안 INSERT를 보냈다. 대기 위치는 gdb로 스레드 스택을 떠서 확인했다. hook은 공개 브랜치에 없으므로, 아래 결과를 다른 사람이 그대로 다시 실행할 수는 없다.

| 조건 | 실행 수 | INSERT 대기 | 대기한 페이지와 위치 |
| --- | --- | --- | --- |
| 미리 채운 행 없음(새 페이지 할당) | 3 | 109.0초, 122.8초, 122.7초 | 힙 헤더(= 피해 행의 home 페이지), `heap_alloc_new_pages` |
| 미리 채운 행 있음, vacuum이 멈추고 60초 뒤 INSERT | 2 | 63.2초, 66.0초 | 힙 헤더, `heap_update_bestspace` |
| 미리 채운 행 있음, vacuum이 멈추자마자 INSERT | 20 | 19회 0.03~0.17초, 1회 90.4초 | 대기 없음. 1회는 INSERT가 약 55초 늦게 시작돼 30초 동기화와 겹친 것으로 추정 |

시도한 모든 배치에서 피해 행의 home 페이지가 힙 헤더 페이지였다. home 페이지가 헤더가 아닐 때에도 같은 대기가 생기는지는 확인하지 않았다.

### 소스에서만 확인한 관련 경로

`heap_alloc_new_pages`는 헤더 다음에 마지막 힙 페이지도 조건 없이 쓰기 래치로 고정한다([L29282](https://github.com/CUBRID/cubrid/blob/225375922881fb0f61cc311458078264961eef79/src/storage/heap_file.c#L29282)). vacuum이 쥔 home 또는 forward 페이지가 마지막 페이지이면, 새 페이지를 할당하는 INSERT가 같은 방식으로 기다릴 수 있다. 재현하지 않았다.

### 관련 이슈와의 경계

- CBRD-27860: vacuum이 데이터 페이지를 쥔 채 헤더를 기다리고, INSERT는 헤더를 쥔 채 마지막 페이지를 기다리는 **교착**이다. 이 이슈는 교착이 아니고, vacuum이 헤더 자체를 쥐고 있어 생기는 **긴 대기**이다.
- CBRD-27858 / PR #8348: forward 페이지를 sysop이 끝날 때까지 쥐도록 바꾸고, bestspace 공개를 sysop commit 뒤로 옮겼다. 이 이슈의 대기는 그 PR 전에도 있었다.

## Acceptance Criteria

- vacuum이 relocation 행의 OOS 삭제를 하는 동안 같은 테이블에 INSERT를 보내도, INSERT가 그 삭제 시간만큼 기다리지 않는다. 허용할 대기 기준은 ANALYSIS에서 정한다.
- vacuum 중단, OOS 삭제 실패, 서버 강제 종료 뒤 재시작에서 commit된 행이 남아 있고 `checkdb`가 통과한다. CBRD-27858이 지키는 slot 재사용 보호를 깨지 않는다.

## ANALYSIS 질문

- 실제 워크로드에서 OOS 삭제가 sysop 안에서 얼마나 걸리는가. 긴 OOS 체인에서 얼마나 길어지는가.
- home 페이지가 헤더가 아닌 경우와 마지막 페이지인 경우에도 같은 대기가 생기는가.
- 헤더를 쥐는 시간을 줄이는 것, INSERT가 헤더를 조건부로 잡고 다른 경로로 가는 것 중 무엇이 CBRD-27858의 보호와 맞는가.
