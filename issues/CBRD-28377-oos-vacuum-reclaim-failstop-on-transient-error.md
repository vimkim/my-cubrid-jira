# [OOS] vacuum이 OOS chain을 회수하다 일시적 오류(-1123)를 만나면 블록을 다시 처리하지 않고 서버를 FATAL로 종료한다

**한 줄 요약**: QA shell_long `bug_3627`(11.5.0.2997-de4bb11)에서 vacuum이 UPDATE가 버린 OOS chain을 회수하던 중 빈 버퍼 프레임을 300초 동안 얻지 못해 -1123(`ER_CSS_PTHREAD_COND_TIMEDOUT`)을 받았고, OOS 회수의 fail-stop 정책이 이 일시적 오류를 서버 FATAL 종료로 바꿨다. 이 경로는 블록을 다시 처리하면 되므로 서버를 멈출 필요가 없다. 이 이슈는 일시적 오류에서 서버를 멈추지 않게 하는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: vacuum이 OOS chain을 회수하다 일시적 오류(버퍼 대기 시간 초과, 페이지 latch 시간 초과 등)를 만나면 서버를 멈추지 않고 그 log block을 나중에 다시 처리한다. chain은 새지 않는다.

**이슈 수행 이유**: OOS 회수는 실패하면 서버를 멈추는 fail-stop 정책을 따른다(OOS-ADR-0008). 회수 표시를 남긴 채 성공으로 처리하면 chain이 영원히 새기 때문이다. 그런데 vacuum이 `RVOOS_NOTIFY_VACUUM`(UPDATE가 버린 chain의 회수 요청)을 처리하는 경로는 오류를 돌려주기만 해도 그 블록이 완료로 표시되지 않고, vacuum이 나중에 다시 처리한다. 회수기는 다시 실행해도 안전하게 설계되었다(OOS-ADR-0008). 그런데도 이 경로는 `ER_INTERRUPTED` 와 영구 오류(손상된 chain)만 따로 처리하고, 나머지 오류는 모두 fail-stop한다. QA에서는 -1123이 그대로 서버 종료로 이어졌다.

**영향**: OOS 테이블을 UPDATE하는 사용자의 서버가, 빈 버퍼 프레임이나 페이지 latch를 기다리는 시간이 한계(기본 300초)를 넘는 것만으로 FATAL로 종료되고 core를 남긴다. 재시작 복구가 끝나야 서비스가 돌아오고, HA에서는 failover가 일어난다. QA에서 1회 관찰했다. 이번 QA 사례에서 버퍼가 고갈된 원인(동시 OOS INSERT 중 flush daemon이 victim 후보를 찾지 못함)은 별도 이슈로 다룬다. 원인이 고쳐져도 버퍼나 latch 대기 시간 초과는 다른 부하에서 다시 생길 수 있으므로, 이 경로가 서버를 멈추는 문제는 따로 남는다. 운영 환경에서의 발생 빈도는 알 수 없다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### QA에서 관찰한 내용

- 빌드: 11.5.0.2997-de4bb11, shell_long `longcase/shell/other/bug_3627`(CBRD-26357 댓글, 2026-11-25). 같은 실행에서 insert 단계도 크게 느려졌다(별도 이슈).
- 서버 오류 로그(`pdb_20261123_2057.err`) 끝부분:

```text
Flush victim candidates of page buffer finished (count: 0).
Flush victim candidates of page buffer started.
OOS [ERROR](oos_reclaim_fail_stop): OOS reclaim of committed intent failed (error -1123) for file 1|4736 chain oid={vol=2,page=1424,slot=0} stamp 13835|10816; stopping so restart recovery reruns it
...
LOG FATAL ERROR: oos_reclaim: committed reclaim failed with error -1123
[09] oos_reclaim_notified_chains (...) at src/storage/oos_file.cpp:4380
[08] vacuum_oos_reclaim_notified_chains (...) at src/query/vacuum_oos.cpp:243
[07] vacuum_process_log_block (...) at src/query/vacuum.c:3878
```

- -1123은 `ER_CSS_PTHREAD_COND_TIMEDOUT` 이다. `pgbuf_allocate_bcb ()` 는 빈 버퍼 프레임(BCB)이 없으면 `page_latch_timeout_in_msecs`(기본 300초)까지 기다리고, 시간이 지나면 이 오류를 낸다([page_buffer.c:8955](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/page_buffer.c#L8955), [9041-9050](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/page_buffer.c#L9041-L9050)). 바로 앞의 `count: 0` 은 flush daemon이 내보낼 victim 후보를 하나도 찾지 못했다는 뜻이다. vacuum 스레드는 우선순위가 높은 대기자로 분류되지만 300초 안에 프레임을 받지 못했다.

### 원인 (develop `bfb59bdd13` 기준, `de4bb11` 과 이 경로의 코드가 같다)

- `oos_reclaim_notified_chains ()` 는 chain마다 `oos_delete ()` 를 부르고, 오류가 `ER_INTERRUPTED` 면 그대로 돌려주어 블록을 다음에 다시 처리하게 한다. 영구 오류(`ER_HEAP_OOS_CORRUPTED_RECORD`, `ER_HEAP_OOS_INVALID_ARGUMENT`)는 보고하고 건너뛴다. 그 밖의 오류는 모두 `oos_reclaim_fail_stop ()` → `logpb_fatal_error ()` 로 서버를 멈춘다([oos_file.cpp:4365-4384](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/oos_file.cpp#L4365-L4384)). 주석은 그 이유를 "블록을 완료하면 회수 요청이 끝난 것으로 표시되어 chunk가 영원히 샌다"고 적고 있다.
- 그런데 오류를 돌려주면 블록은 완료되지 않는다. vacuum은 블록 처리 중 오류가 나면 `vacuum_finished_block_vacuum (..., false)` 로 블록을 interrupted로 표시하고([vacuum.c:4087-4135](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/query/vacuum.c#L4087-L4135)), 서버 실행 중에 다시 처리한다(`VACUUM_RETRY_INTERRUPTED_INTERVAL`, [vacuum.c:8805-8838](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/query/vacuum.c#L8805-L8838)). 같은 함수의 OOS 파일 조회 실패는 이미 이 방식으로 처리한다(CBRD-27933, [vacuum_oos.cpp:245-260](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/query/vacuum_oos.cpp#L245-L260)).
- 다시 처리할 때 회수기는 이미 지운 chain이나 일부만 지운 chain을 만나도 남은 부분만 지운다(OOS-ADR-0008: tail부터 redo-only로 지우고, 재실행은 남은 연결 부분을 끝낸다). 그래서 이 경로에서는 일시적 오류를 블록 재처리로 넘겨도 chunk가 새지 않는다고 본다. 이 판단은 코드와 ADR에 근거한 것이며, 실행으로 확인하지 않았다.

### 같은 오류가 닿는 다른 회수 경로 (ANALYSIS 확인 사항)

- 커밋된 회수 의도를 postpone으로 실행하는 `oos_rv_reclaim_on_postpone ()`(vacuum REMOVE sysop 커밋, SA eager 삭제)은 페이지 latch를 시간 제한 없이 기다리게 하지만(`pgbuf_force_latch_wait ()`, [oos_file.cpp:4132-4136](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/oos_file.cpp#L4132-L4136)), 빈 버퍼 프레임 대기는 여전히 300초 뒤 -1123으로 끝난다. 이 경로는 postpone을 미룰 수 없으므로 블록 재처리 방식을 그대로 쓸 수 없다. 일시적 오류를 그 자리에서 다시 시도할지, fail-stop을 유지할지 ANALYSIS에서 정한다.
- vacuum worker의 페이지 latch 대기가 시간 초과(-836, -72)로 끝날 수 있는지는 확인하지 않았다. 끝날 수 있다면 같은 방식으로 fail-stop한다.

### 다른 이슈와의 관계

- [CBRD-28276](https://jira.cubrid.org/browse/CBRD-28276): vacuum 재시도와 fail-stop이 **영구** 오류를 만났을 때의 무한 반복과 재시작 실패를 다룬다. 이 이슈는 **일시적** 오류가 실행 중인 서버를 멈추는 문제로, 범위가 다르다. 다만 블록 재처리로 넘기면 CBRD-28276의 1초 주기 재시도에 들어가므로, 재시도 상한이나 back-off 결정은 CBRD-28276과 함께 본다.
- 이번 QA 사례의 버퍼 고갈과 insert 단계 저하는 별도 이슈로 올린다.

## Test Build

- QA: 11.5.0.2997-de4bb11 release, shell_long `bug_3627`. 로컬에서 FATAL을 재현하지는 않았다.

## Expected Result

- vacuum의 `RVOOS_NOTIFY_VACUUM` 처리 중 일시적 오류가 나면 서버는 계속 돌고, 그 블록은 나중에 다시 처리되어 chain이 회수된다.

## Actual Result

- 서버가 `LOG FATAL ERROR: oos_reclaim: committed reclaim failed with error -1123` 으로 종료되고 core를 남긴다.

## Definition of done

- fault injection으로 `oos_delete ()` 에 일시적 오류(-1123 등)를 내는 시험에서, 서버가 멈추지 않고 블록이 다시 처리되어 chain이 회수된다.
- postpone 경로(`oos_rv_reclaim_on_postpone ()`)의 일시적 오류 처리 방침이 정해지고, 바꾸기로 했다면 같은 방식으로 시험한다.
