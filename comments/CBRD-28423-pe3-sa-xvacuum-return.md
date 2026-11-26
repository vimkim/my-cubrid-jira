## 관련 위험 추가: SA 부팅이 `xvacuum ()` 실패를 무시한다 (PE-3)

[PR #8721 리뷰 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-28142/pr8721-review.md)의 Pre-existing 항목 PE-3을 함께 기록한다. 이 이슈의 경합과 같은 갈래, 곧 "백업의 아카이브 선택이 vacuum이 실제로 필요로 하는 로그와 어긋나는 문제"에 속한다. 코드 분석만으로 확인했고 재현하지 않았다.

- 기준 소스: `CUBRID/cubrid` PR #8721 head `5d6b8cc8fb9a547eba365f1ce217b5b4858b1dd6` (vacuum 활성화 경로는 `develop` `af6f1df42b`와 같다)
- `src/transaction/boot_sr.c:2670-2677`: SA 모드 부팅은 복원 중이 아니고 `skip_vacuum`이 아니면 `xvacuum (thread_p)`를 호출해 데이터베이스 전체를 vacuum한다. `xvacuum ()`는 `int`를 반환하지만(`src/query/vacuum.c:990-991`) 반환값을 확인하지 않는다.
- SA vacuum이 성공하면 `vacuum_Data.is_vacuum_complete`가 참이 되고(`vacuum.c:1123`), `vacuum_min_log_pageid_to_keep ()`은 `NULL_PAGEID`를 돌려준다. 그래서 vacuum을 켠 `backupdb -S`가 아카이브를 담지 않아도 문제가 없다.
- 실패하면 `is_vacuum_complete`가 거짓으로 남는다. 그런데 `logpb_backup ()`에서 vacuum을 켠 상태의 아카이브 선택(`else` 갈래)은 `SERVER_MODE` 전용이라, SA 백업은 vacuum이 아직 읽어야 할 로그가 든 아카이브를 담지 않는다. 그 백업으로 복원한 뒤 vacuum이 남은 블록을 읽을 때 `unable to find log page N in log archives`가 날 수 있다.
- 발생 조건: SA 부팅 중 `vacuum_sa_run_job` 등이 실패해야 하므로 드물다. 실패 시 `xvacuum ()`의 오류가 그대로 지워지는지(`er_clear ()` 뒤 호출) 등은 ANALYSIS에서 확인한다.

ANALYSIS 질문:

1. SA 부팅에서 `xvacuum ()` 실패를 오류로 다룰지(부팅 실패나 경고), 아니면 `is_vacuum_complete`가 거짓일 때 SA 백업도 vacuum이 필요로 하는 아카이브부터 담을지.
2. 본 이슈의 수정(백업에서 keep 값을 읽는 시점)과 함께 다룰지, 따로 나눌지.
