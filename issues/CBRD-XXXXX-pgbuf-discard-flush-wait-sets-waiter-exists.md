# pgbuf_discard_page 가 flush 대기 전에 waiter_exists 를 세워, 대기자가 없는 BCB에 표시가 남을 수 있다

**한 줄 요약**: 지운 파일의 페이지를 버퍼에서 버리는 `pgbuf_discard_page ()` 는 flush가 진행 중이면 flush 대기자로 BCB 대기열에 들어간다. 들어가기 전에 "대기자 있음" 표시(`waiter_exists`)를 세운다. 그러나 flush 대기자는 이 표시를 쓰지 않는 것이 page buffer의 규칙이다. flush가 끝나 대기자를 깨우는 `pgbuf_wake_flush_waiters ()` 도 표시를 지우지 않는다. 이 이슈는 이 경로가 표시를 남기지 않게 정리하는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: flush 대기는 `waiter_exists` 를 바꾸지 않는다. latch를 기다리는 스레드가 없는 BCB에는 표시가 남지 않는다.

**이슈 수행 이유**: CBRD-28379 리뷰(F7)에서 찾았다. 다른 flush 대기 경로는 표시를 세우지 않는다. `pgbuf_block_bcb ()` 의 assert 주석은 "a flush waiter does not set waiter_exists" 라고 적고 있고, `pgbuf_bcb_safe_flush_internal ()` 의 동기 flush 대기도 같다. 이 규칙은 CBRD-27971(flush 대기자가 줄을 선 latch 없는 페이지를 fix하면 BCB mutex를 쥔 채 무한 반복)의 수정에서 생겼다. 그 수정은 `2b1db6ca29`(CBRD-27970과 같은 PR, 2026-11-09)이다. 같은 날 먼저 병합된 CBRD-27151(`063d84e537`)의 `pgbuf_discard_page ()` 는 표시를 세우는 줄을 따로 가지고 있었다. 그래서 그 수정에서 빠졌다.

**영향**: 보통은 영향이 없다. flush가 끝나면 이 함수는 다시 시도하고 `pgbuf_invalidate_bcb ()` 로 BCB를 비운다. 이때 latch 값이 초기화된다. 하지만 함수 주석이 적은 대로 `pgbuf_invalidate_bcb ()` 는 드문 일시 상태에서는 포기할 수 있다. 그러면 latch가 없는(`PGBUF_NO_LATCH`) BCB에 표시만 남는다. 그다음 누군가 그 BCB를 fix하면, 대기열이 비어 있을 때 `pgbuf_latch_bcb_upon_fix ()` 의 안전장치가 표시를 지운다. 안전장치는 debug 빌드에서 `assert (false)` 로 멈춘다. 대기열에 다른 flush 대기자가 남아 있으면 안전장치가 동작하지 않는다. 이때 idle grant CAS는 `waiter_exists == false` 를 기대하므로 BCB mutex를 쥔 채로 계속 실패할 수 있다(코드 읽기로만 확인, 재현 안 함). 호출자 계약상 지우는 파일의 페이지를 동시에 fix하면 안 되므로, 실제로 일어날 가능성은 낮다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 정한다. 후보는 표시를 세우는 줄을 지우는 것이다. `pgbuf_block_bcb ()` 의 assert는 flush 대기에 표시를 요구하지 않는다.

---

## AI-Generated Context

## Description

- 코드 위치 (develop `ca39c2c6a4`): [page_buffer.c:3650-3663](https://github.com/CUBRID/cubrid/blob/ca39c2c6a48df0bbc689c4d8b8d640113bb87d3e/src/storage/page_buffer.c#L3650-L3663) 의 `set_waiter_exists (&bufptr->atomic_latch, true)` 다음에 `pgbuf_block_bcb (..., PGBUF_LATCH_FLUSH, ...)` 를 호출한다.
- 표시 규칙: `pgbuf_block_bcb ()` 의 assert는 READ/WRITE 대기자에게만 표시를 요구한다([L7726-L7727](https://github.com/CUBRID/cubrid/blob/ca39c2c6a48df0bbc689c4d8b8d640113bb87d3e/src/storage/page_buffer.c#L7726-L7727)). `pgbuf_bcb_safe_flush_internal ()` 의 주석도 flush 대기자는 표시를 세우지 않는다고 적는다([L9649](https://github.com/CUBRID/cubrid/blob/ca39c2c6a48df0bbc689c4d8b8d640113bb87d3e/src/storage/page_buffer.c#L9649)).
- `pgbuf_wake_flush_waiters ()` 는 flush 대기자를 대기열에서 빼고 깨운다. `waiter_exists` 는 지우지 않는다.
- 안전장치: [L6995-L7007](https://github.com/CUBRID/cubrid/blob/ca39c2c6a48df0bbc689c4d8b8d640113bb87d3e/src/storage/page_buffer.c#L6995-L7007).

## Test Build

- 코드 읽기로 찾았다. 재현하지 않았다.

## Expected Result

- flush를 기다리는 스레드는 `waiter_exists` 를 바꾸지 않는다.

## Actual Result

- `pgbuf_discard_page ()` 의 flush 대기는 `waiter_exists` 를 세우고, 이를 지우는 경로가 없다.

## Additional Information

- **중복 확인** (`cubrid-jira-dup candidate-find`, 2026-11-25): 같은 경로를 다루는 이슈는 없다. 가장 가까운 것은 CBRD-27971(Resolved)이다. 결함 유형이 같지만 동기 flush 경로를 고쳤고, 이 경로는 빠졌다. CBRD-27084(Resolved)도 flush 대기 뒤 남는 표시를 다뤘지만 대기열이 빈 경우였다.
- **관련**: CBRD-27971(같은 결함 유형), CBRD-27151(이 코드를 넣은 변경), CBRD-28379(조건부 latch 거절이 남기는 `waiter_exists`, 이 문제를 찾은 리뷰), CBRD-28163(포기한 대기자가 남기는 `waiter_exists`), CBRD-27084.
