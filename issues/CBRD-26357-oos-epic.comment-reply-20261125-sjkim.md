[~sjkim] bug_3627 확인과 커밋 범위 좁히기 감사합니다. 원인을 찾았고, 두 증상을 이슈로 나눠 처리하겠습니다.

1. **insert 단계 성능 저하** → [CBRD-28378](https://jira.cubrid.org/browse/CBRD-28378)
    - OOS INSERT가 새 OOS 페이지를 채우기 전에 빈 페이지로 bestspace에 알리고, 다른 INSERT가 그 페이지를 조건부 latch로 잡으려다 거절됩니다. 이때 page buffer가 "대기자 있음" 표시를 남겨, 할당한 쪽이 페이지를 놓을 때 그 버퍼 프레임을 LRU 목록에 넣지 않습니다. 이런 프레임이 쌓여 버퍼 풀이 고갈되고, 빈 버퍼나 latch를 300초 기다리다 `pthread_cond_timedwait() timed out`(-1123)·`unilaterally aborted`(-72)로 끝납니다. QA 로그의 `Flush victim candidates ... (count: 0)` 반복이 이 상태입니다.
    - 로컬 release 빌드 비교(insert 단계): OOS 이전 develop `a7f220d` 375초·예외 0, develop `bfb59bd` 1188초·10개 세션 중 9개 예외. 멈춘 서버에서 버퍼 프레임 6400개 중 약 3000개가 어느 LRU 목록에도 없는 OOS 페이지였습니다. page buffer 표시만 고친 실험 빌드에서는 180초에 10개 모두 예외 없이 끝났습니다.
    - page buffer 쪽 표시 문제는 OOS와 무관하게 CBRD-26425부터 develop에 있어, [CBRD-28379](https://jira.cubrid.org/browse/CBRD-28379)로 따로 올렸습니다.
2. **vacuum의 OOS 회수 FATAL** → [CBRD-28377](https://jira.cubrid.org/browse/CBRD-28377)
    - -1123은 위의 빈 버퍼 대기 시간 초과입니다. vacuum이 UPDATE가 버린 chain을 회수하는 경로는 오류가 나면 그 log block을 나중에 다시 처리할 수 있는데, 지금은 이런 일시적 오류도 fail-stop으로 서버를 멈춥니다. 1번이 고쳐져도 남는 문제라 따로 올렸습니다.
