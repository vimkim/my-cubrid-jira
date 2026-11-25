[~sjkim] bug_3627 확인과 커밋 범위 좁히기 감사합니다. 말씀하신 두 증상은 원인이 달라 이슈를 나눠 처리하겠습니다.

1. **insert 단계 성능 저하** → CBRD-NNNNN (OOS TODO epic CBRD-26978의 하위 작업)
    - 첨부해 주신 QA 서버 로그에서 FATAL 직전에 page flush daemon이 `Flush victim candidates of page buffer finished (count: 0)` 를 반복합니다. 버퍼 풀에서 내보낼 페이지를 찾지 못해, 빈 버퍼를 기다리는 스레드가 300초 뒤 -1123(`pthread_cond_timedwait() timed out`)으로 끝난 것입니다. 클라이언트의 예외도 같은 오류입니다.
    - 동시 OOS INSERT에서 버퍼가 왜 고갈되는지는 이 이슈에서 분석합니다.
2. **vacuum의 OOS 회수 FATAL** → [CBRD-28377](https://jira.cubrid.org/browse/CBRD-28377)
    - -1123은 위의 버퍼 대기 시간 초과입니다. vacuum이 UPDATE가 버린 chain을 회수하는 경로는 오류가 나면 그 log block을 나중에 다시 처리할 수 있는데, 지금은 일시적 오류도 fail-stop으로 서버를 멈춥니다. 1번이 고쳐져도 남는 문제라 따로 올렸습니다.
