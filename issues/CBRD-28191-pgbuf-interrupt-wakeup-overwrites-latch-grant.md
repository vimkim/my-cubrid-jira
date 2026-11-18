# [PGBUF] interrupt wakeup이 이미 넘겨받은 page latch를 덮어써서 주인 없는 fix count가 남는다

**한 줄 요약**: CBRD-27739 수정 PR #8611 리뷰에서 같은 증상(주인 없는 fix count)을 내는 세 번째 경로를 찾았다. latch를 넘겨받은 대기 스레드를 서버 종료나 deadlock 희생자 처리가 interrupt로 다시 깨우면, 대기 스레드는 latch를 받지 못했다고 판단해 오류로 돌아가고 페이지의 fix count는 서버 재시작 전까지 풀리지 않는다. 이 이슈는 그 경로를 닫는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: page latch를 기다리던 스레드가 latch를 넘겨받았다면, 그 뒤에 어떤 interrupt wakeup이 와도 latch의 소유가 사라지지 않게 한다. 결과는 둘 중 하나여야 한다. 스레드가 latch를 갖고 돌아가거나, latch를 받지 않은 채 오류로 돌아간다.

**이슈 수행 이유**: `thread_wakeup_internal ()`은 대상 스레드의 `resume_status`를 확인하지 않고 덮어쓴다. 이 함수를 쓰는 외부 wakeup 경로 두 곳이 page latch 대기자도 깨운다. latch를 넘겨주는 쪽(granter)이 fix count를 더하고 `THREAD_PGBUF_RESUMED`를 기록한 직후에 이 경로가 `THREAD_RESUME_DUE_TO_INTERRUPT`로 덮어쓰면, 대기자는 interrupt로 처리하고 fix count를 되돌리지 않는다. 코드를 읽어 develop과 release/11.4에서 interleaving이 가능함을 확인했다. 재현은 하지 않았다. PR #8611은 이 경로를 바꾸지 않는다.

**영향**: CBRD-27739와 같은 상태가 남는다. 해당 페이지에 주인 없는 latch가 서버 재시작 전까지 남는다. CBRD-27739에서는 이 상태에서 그 페이지를 쓰는 UPDATE와 SELECT가 latch timeout으로 실패했고 `cubrid server stop`이 끝나지 않았다. 이 이슈의 경로로 같은 결과가 나는지는 재현하지 않았다. 발생 조건은 CBRD-27739보다 좁다. 서버 종료 중이거나, 같은 트랜잭션의 다른 스레드가 deadlock 희생자 처리를 하는 순간에 대기자가 latch를 막 넘겨받아야 한다. 실제 발생 빈도는 측정하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 배경: page latch를 넘겨주는 규칙

- 페이지에 latch를 걸지 못한 스레드(대기자 W)는 BCB의 대기 queue에 들어가 `pgbuf_timed_sleep ()`에서 잠든다. 이때 `resume_status = THREAD_PGBUF_SUSPENDED`이다.
- latch를 놓는 스레드(granter G)는 `pgbuf_wakeup_reader_writer ()`에서 W의 thread entry lock을 잡고, latch word에 W의 fix count를 더한 뒤(`fcnt += request_fix_count`), W를 queue에서 빼고 `pgbuf_wakeup ()`으로 `resume_status = THREAD_PGBUF_RESUMED`를 기록한다. 이 순간부터 latch는 W의 것이다.
- W는 깨어난 뒤 entry lock을 잡고 `resume_status == THREAD_PGBUF_RESUMED`인지로 latch를 받았는지 판단한다. 아니면 `request_latch_mode = PGBUF_NO_LATCH`를 기록하고 오류로 돌아간다. 이때 W는 이미 더해진 fix count를 되돌리지 않는다. 받지 않았다고 판단했기 때문이다.

즉 "latch를 받았다"는 사실은 `resume_status` 하나에만 기록된다. 이 필드를 다른 코드가 덮어쓰면 소유 정보가 사라진다.

### 문제: 무조건 덮어쓰는 외부 wakeup

`thread_wakeup_internal ()`(src/thread/thread_entry.cpp:756-769)은 현재 값을 보지 않고 `resume_status = resume_reason`을 기록한다. page latch 대기자를 이 함수로 깨울 수 있는 외부 경로는 다음 두 곳이다.

| 경로 | 호출 조건 | `RESUMED` 확인 여부 |
|---|---|---|
| `css_stop_non_log_writer ()` (src/connection/server_support.c:2262-2270) | 서버 종료 시 `css_stop_all_workers ()`가 50 ms마다 모든 worker에 반복 호출함 | 없음. entry lock 안에서 `m_status == TS_WAIT`, `lockwait == NULL`, `check_interrupt`만 확인함 |
| `logtb_wakeup_thread_with_tran_index ()` (src/transaction/log_tran_table.c:6439-6449) | deadlock 희생자가 된 스레드가 `LOCK_RESUMED_ABORTED_FIRST` 처리 중, 같은 트랜잭션의 다른 worker가 끝날 때까지 10 ms마다 반복 호출함 (src/transaction/lock_manager.c:2516-2529) | 없음. `m_status`도 확인하지 않음 |

대조군으로, 클라이언트 interrupt 경로(src/communication/network_sr.c:1029-1081)는 entry lock 안에서 `resume_status`가 `*_SUSPENDED`일 때만 깨우고 `THREAD_PGBUF_RESUMED`는 건너뛴다. 위 두 경로에는 이 확인이 없다.

`css_stop_non_log_writer ()`의 `m_status == TS_WAIT` 확인은 이 경쟁을 막지 못한다. W의 `m_status`는 `pthread_cond_timedwait ()`가 entry lock을 다시 얻고 `thread_prepare_resumption ()`을 실행할 때까지 `TS_WAIT`로 남는다. G가 signal을 보낸 뒤 W가 lock을 다시 얻기 전에 외부 wakeup 스레드가 lock을 먼저 잡을 수 있다.

### interleaving

W: 페이지 X에서 latch를 기다리는 스레드. G: X의 latch를 놓으면서 W에게 넘겨주는 스레드. I: 외부 wakeup을 보내는 스레드(서버 종료 스레드 또는 같은 트랜잭션의 deadlock 희생자 스레드).

```
W (X에서 대기)                          G (granter, BCB mutex 보유)          I (interrupter)
pthread_cond_timedwait 안에서 대기
(resume_status = PGBUF_SUSPENDED,
 m_status = TS_WAIT)
                                        lock(W)
                                        fcnt += 1, W를 queue에서 제거
                                        resume_status = PGBUF_RESUMED
                                        signal, unlock(W)
                                                                             lock(W)
                                                                             m_status == TS_WAIT 확인
                                                                             resume_status = RESUME_DUE_TO_INTERRUPT
                                                                             signal, unlock(W)
entry lock 재획득. 상태가 SUSPENDED가 아니므로
대기 루프를 빠져나옴 (r = NO_ERROR)
interrupt 분기: lock(W), RESUMED 아님
request_latch_mode = NO_LATCH, unlock(W)
pgbuf_timed_sleep_error_handling: W는 이미
queue에 없으므로 아무것도 되돌리지 않음
ER_INTERRUPTED 반환                     -> G가 더한 fix count 1의 주인이 없음
```

- W가 timeout으로 깨어나는 경우도 같다. PR #8611의 새 timeout 분기는 entry lock을 잡고 `RESUMED`를 확인하지만, I가 그 전에 덮어썼다면 timeout으로 처리하고 같은 누수가 생긴다.
- `logtb_wakeup_thread_with_tran_index ()`는 `m_status`를 보지 않으므로 창이 더 넓다. `thread_suspend_timeout_wakeup_and_unlock_entry ()`가 entry lock을 놓고 돌아온 뒤, `pgbuf_timed_sleep ()`이 lock을 다시 잡기 전까지의 구간에서도 덮어쓸 수 있다.
- W가 WRITE latch를 기다렸다면 주인 없는 WRITE latch가 남는다. 이 경우에는 읽기 요청도 막힐 것으로 추정한다(코드 읽기 기반, 미확인).

### 확인한 버전과 근거

| 버전 | 기준 revision | 결과 |
|---|---|---|
| develop | `cf9ef28881` (2026-11-18 기준 `origin/develop`, PR #8611의 base) | 코드 읽기로 확인함. `thread_wakeup_internal ()` 무조건 덮어쓰기, 두 외부 경로, `pgbuf_timed_sleep ()` interrupt 분기(page_buffer.c:7990-8005), granter(page_buffer.c:8132-8255, fix count 증가 8212), `pgbuf_wakeup ()`(page_buffer.c:12453-12480) |
| PR #8611 head | `50d4a9a3c2` | 변경 없음. PR은 page_buffer.c의 timeout 분기와 `pgbuf_timed_sleep_error_handling ()` case 3만 고친다. 외부 wakeup 경로와 interrupt 분기는 그대로다. case 3도 `pgbuf_wakeup ()`으로 넘겨주므로 같은 덮어쓰기의 대상이 된다 |
| release/11.4 | `77df7f6185` | 코드 읽기로 확인함. `thread_wakeup_internal ()`, `css_stop_non_log_writer ()`(server_support.c:2966-2976), `logtb_wakeup_thread_with_tran_index ()`(log_tran_table.c:5952), deadlock 경로(lock_manager.c:2278-2279)가 같다. 11.4의 `pgbuf_timed_sleep ()`은 대기 중 `check_interrupt = true`를 직접 설정하므로 종료 경로의 조건도 충족된다. 대기 루프가 없어 signal 뒤 바로 `r = NO_ERROR`로 interrupt 분기에 들어간다 |
| release/10.2 ~ 11.3 | 각 branch tip | `thread_wakeup_internal ()`의 무조건 덮어쓰기는 같다. 나머지 경로는 확인하지 않았다 |

다른 page buffer 대기(`pgbuf_sleep ()`의 buffer lock 대기, `pgbuf_wakeup_uncond ()`의 flush 대기)는 깨울 때 fix count를 넘겨주지 않는다. 그래서 덮어써도 누수는 없고, 대기가 일찍 끝날 뿐이다.

### 재현

- 실행하지 않았다. 두 스레드가 같은 entry lock을 연달아 잡는 좁은 창이라 일반 부하로는 재현이 어렵다.
- 제안: debug build에서 `pgbuf_wakeup ()`이 entry lock을 놓은 직후 대기자 쪽 재획득을 늦추는 지연을 넣고, 같은 시점에 서버 종료(`cubrid server stop`)를 걸어 확인한다. 기대 결과는 W가 latch를 갖고 돌아가거나, fix count가 남지 않는 것이다.

### ANALYSIS 확인 사항

- deadlock 경로의 실제 발생 조건. `css_count_transaction_worker_threads ()`는 request worker pool만 세지만, `logtb_find_thread_by_tran_index_except_me ()`는 모든 thread entry에서 같은 `tran_index`를 가진 첫 스레드를 찾는다. develop의 parallel query worker는 부모의 `tran_index`를 물려받는다(src/query/parallel/px_scan/px_scan_task.cpp:102). 그래서 깨우는 대상이 parallel worker일 수 있다. 한 트랜잭션에 request worker가 둘 이상 생기는 workload가 무엇인지는 확인하지 않았다.
- 종료 경로의 실제 영향. 종료 중 누수가 이후 flush나 종료 절차를 멈추게 하는지는 확인하지 않았다.

## Options for Analysis

아래는 후보이며, 선택은 ANALYSIS에서 한다.

| 후보 방안 | 기대 효과와 장점 | 한계·단점과 실패 조건 | 비용·위험·호환성 | 근거와 ANALYSIS 확인 사항 |
|---|---|---|---|---|
| (a) 조건부 wakeup: 외부 interrupt 경로가 대상이 `*_SUSPENDED`일 때만 깨운다 | network_sr.c와 같은 규칙으로 맞춘다. page buffer 외 다른 대기(lock, critical section 등)에서 같은 종류의 덮어쓰기도 함께 막는다 | 외부 wakeup을 부르는 곳마다 규칙을 지켜야 한다. 새 호출 지점이 생기면 다시 깨질 수 있다. `thread_wakeup_internal ()` 자체를 바꾸면 모든 wakeup 사용처가 영향을 받는다 | 수정 지점은 두 곳이지만, 무엇을 깨우고 무엇을 건너뛸지 대기 종류별로 정해야 한다. 공개된 `thread_check_suspend_reason_and_wakeup ()`은 entry lock을 스스로 잡으므로, lock을 이미 쥔 `css_stop_non_log_writer ()`에는 그대로 쓸 수 없다 | 두 경로가 interrupt를 건너뛰어도 종료나 deadlock 처리가 진행되는지. 트랜잭션 interrupt 플래그가 이미 설정되므로 W가 다음 확인 지점에서 멈출 것으로 추정한다 |
| (b) pgbuf가 소유하는 grant 표시: `pgbuf_wakeup ()`이 entry lock 안에서 별도 필드에 "넘겨줌"을 기록하고, 대기자는 `resume_status` 대신 이 필드로 판단한다 | page buffer 안에서 닫힌다. 외부 wakeup 경로가 무엇을 하든 소유 판단이 바뀌지 않는다 | interrupt를 받은 순간 W는 latch를 갖고 정상 반환한다. interrupt는 이후 확인 지점에서 처리된다. `pgbuf_wakeup_uncond ()`, `pgbuf_sleep ()` 등 다른 page buffer 대기와 규칙을 맞춰야 한다 | thread entry에 필드가 하나 늘거나 기존 필드의 의미가 바뀐다. 범위가 page_buffer.c 위주라 위험이 작다 | 대기 시작 시 표시를 초기화하는 지점과, 모든 grant 경로(`pgbuf_wakeup_reader_writer ()`, case 3)가 같은 lock 구간에서 표시를 남기는지 |

- (a)는 원인(덮어쓰기)을 호출하는 쪽에서 막고, 다른 대기 종류까지 정리한다. 대신 호출 지점 규칙에 의존한다.
- (b)는 소유 판단을 덮어쓸 수 없는 곳으로 옮겨 page buffer 쪽 불변식을 스스로 지킨다. 대신 다른 대기 종류의 덮어쓰기는 그대로 남는다.
- 다른 대기 종류(lock, critical section)에서도 덮어쓰기가 실제 문제를 일으키는지 확인되면 (a)가, page buffer만 문제라면 (b)가 유리하다. 둘을 함께 적용할 수도 있다.

### 관련 이슈

- CBRD-27739: 같은 증상. page latch timeout 처리의 두 경쟁 때문에 주인 없는 latch(READ, 그리고 2026-11-18 코멘트에 따르면 WRITE)가 남는다. 원인은 timeout 처리 순서이고, 외부 interrupt wakeup은 다루지 않는다. PR #8611(https://github.com/CUBRID/cubrid/pull/8611)이 그 두 경쟁을 닫는다. 이 이슈는 PR #8611 리뷰에서 범위 밖으로 남긴 세 번째 경로다.
- CBRD-28163: 같은 함수의 timeout 처리에서 `waiter_exists` 표시가 남는 결함이다. 그 PR #8587(https://github.com/CUBRID/cubrid/pull/8587, head `76a68499eb`)도 timeout 분기에서 entry lock을 다시 잡도록 고친다. 이 PR도 page_buffer.c만 바꾸고 외부 wakeup 경로는 건드리지 않으므로, 이 이슈의 경로는 두 PR이 모두 병합된 뒤에도 남는다(코드 읽기).
