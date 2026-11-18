`feature/oos-merge`에 hotfix를 반영했습니다(PR 없이 직접 반영).

- 엔진: `2c38bef05b` "[CBRD-28194] Stop marking the first log block after every restart as an interrupted vacuum job"
- 원인 커밋 `ff4dc0691a`가 추가한 `interrupted_partial_blockid` 장치(`vacuum_boot`, `xvacuum`, `vacuum_consume_buffer_log_blocks`)를 제거했습니다. 재시작 경로가 develop과 같아졌습니다. `src/query/vacuum.c`에서 15줄을 삭제했습니다.
- 유지: 같은 커밋의 SA_MODE `vacuum_sa_reflect_last_blockid` 보완과 `9c60e09ee`. 이 둘이 없으면 standalone 세션이 vacuum을 끝내지 못하고 종료할 때 남은 작업을 버립니다. develop에 있는 이 결함은 CBRD-28196으로 등록했습니다.
- TC: private `feature/oos-merge`·`tc/pr-7990` `ecbd54bbd`. `cbrd_27780`의 `s1_heap`을 `storage force_inline`으로 바꿔 heap 페이지 반납 검사(check 3)를 복원했습니다.

검증(debug):

- `cbrd_27780`: PASS(14/14). 수정 전 엔진에서는 check 3이 "201 -> 201"로 실패했습니다.
- 재시작 재현(4K 페이지, 200행, 재시작 후 DELETE): 수정 후 201 -> 2이고 develop과 같습니다. 수정 전 OOS 엔진은 201 -> 201이었습니다. filler 없이 실행한 변형에서 남는 11페이지는 같은 log block 안의 INSERT·DELETE로 UNKNOWN이 된 페이지이며, develop의 기존 규칙(CBRD-27331)에 따른 결과입니다.
- ctest 66/66 통과.
- 제거한 hint를 직접 검사하던 bounded check 4개는 의도대로 실패합니다. `9c60e09ee`의 standalone 오류 전파와 shutdown 검사는 모두 통과합니다.

PR #7990의 다음 CI에서 함께 검증합니다.
