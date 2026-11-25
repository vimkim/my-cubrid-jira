[~soheejung] 집계 감사합니다. `cbrd_27780` 확인 2·4의 `S1HEAP=1` 은 [CBRD-28257](https://jira.cubrid.org/browse/CBRD-28257)(카탈로그 행의 NULL 고정 길이 필드에 서버 메모리의 이전 내용이 남는 결함)과 같은 문제로 보고, 새 이슈는 만들지 않고 CBRD-28257에서 처리하겠습니다. `force_inline` 값이 든 암호화 힙 페이지가 평문으로 쓰이는 문제는 아닙니다.

- **평문의 양**: `s1_heap` 의 값은 `lpad('S1HEAP' || rownum, 2000, 'S1HEAP')` 라 한 행에 `S1HEAP` 이 333번 들어 있습니다. 힙 페이지가 평문으로 쓰였다면 수백 개가 보여야 하는데, 실패는 늘 1개(가끔 2개)입니다. CBRD-28257이 설명하는 8~12바이트 조각과 맞습니다.
- **평문의 위치**: CBRD-28257의 OOS 재현(debug 1/14, optdebug 2/15)에서 조각은 모두 암호화되지 않는 `_db_index` 카탈로그 페이지(page 2502, `pflag=0`)의 NULL 필드 자리에 있었습니다.
- **로컬 확인**: develop `bfb59bdd13` release 빌드로 시나리오 1(적재 후 확인 2)을 165회 돌렸습니다. 매회 `s1_heap` 의 힙 페이지는 모두 AES 플래그가 붙어 있었고, 평문은 한 번도 나오지 않았습니다(이 결함은 메모리 재사용에 달려 있어 이 환경에서는 재현되지 않았습니다).
- **OOS 이후 빈도가 늘어난 이유**: OOS 이후 INSERT의 행 버퍼가 glibc `malloc`/`free` 로 바뀌어, 방금 쓴 2KB 평문 버퍼가 직후 `CREATE INDEX` 의 카탈로그 행 버퍼로 재사용되기 쉬워졌습니다(CBRD-28257 댓글, [CBRD-28312](https://jira.cubrid.org/browse/CBRD-28312)).

[~yjlee] CI 실패가 PR과 무관하게 계속 나오고 있어, CBRD-28257 처리 우선순위를 검토 부탁드립니다.
