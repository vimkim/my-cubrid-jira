PR #8632([CBRD-28062](https://jira.cubrid.org/browse/CBRD-28062), `oos_trigger_threshold` 파라미터) 리뷰(F1)에서 이 이슈의 `serial_update_serial_object` 경로가 실제로 실패하는 경우를 재현해 공유합니다. 설계 검토 댓글 3절에서 "꽉 찬 page에서는 `spage_is_updatable` assert가 유일한 방어선"이라고 적은 부분이, release 빌드에서는 재시작할 수 없는 DB로 이어질 수 있다는 내용입니다. 증거 수준은 항목마다 적었습니다(재현 = 실행, 에뮬레이션 = debug 빌드를 gdb로 조작, 소스 = 코드 판독).

**조건**

* PR #8632 head `44dab49185`(`feature/oos-merge` 대상)은 `oos_trigger_threshold` 로 OOS 기준을 자동 목표값(4K 988B, 8K 2012B)보다 높일 수 있습니다.
* `serial_update_serial_object` 는 NEXT VALUE마다 행 전체를 현재 기준으로 다시 인코딩합니다(`serial.c:1575`). 그래서 기준이 낮을 때 OOS로 옮겨진 comment가, 기준을 올린 뒤에는 inline으로 돌아와 행이 제자리에서 커집니다.
* 기준이 바뀌는 경우: 더 높은 값으로 서버 재시작, `[standalone]`/`[@db]`/환경 변수로 더 높은 값을 받은 SA 프로세스, 값이 다른 노드로의 failover.
* 4K·8K 페이지 DB에서만 해당합니다. 16K에서는 serial 행이 자동 목표값(4060B)을 넘지 않습니다.

**1. 재현 (실행, debug 빌드 11.5.0.3032)**

* 4K DB에 1000바이트 comment를 가진 serial 40개를 만들고(행 1138B), 기준 0(자동)에서 NEXT VALUE를 실행해 comment를 OOS로 보냅니다(행 150B).
* 짧은 serial 750개로 비워진 공간을 채웁니다.
* `CUBRID_OOS_TRIGGER_THRESHOLD=3948` 로 `select s1.next_value` 를 실행하면 `serial.c:1587: Assertion spage_is_updatable(...)` 로 프로세스가 abort합니다(rc=134). CS 모드에서는 `cub_server` 가 abort합니다.
* 대조: 기준 0에서는 모든 NEXT VALUE가 성공합니다.

**2. release 경로 (에뮬레이션: 같은 debug 바이너리를 gdb로 실행하며 debug 전용 assert만 건너뜀)**

* NEXT VALUE는 `ERROR: Cannot update serial object.` 로 실패합니다.
* 그런데 `RVHF_UPDATE` redo 레코드는 이미 로그에 들어갔습니다(`serial.c:1589` 의 `log_append_redo_recdes` 가 `serial.c:1592` 의 `spage_update` 보다 먼저 실행됨). 페이지는 실패한 레코드의 LSA를 갖지만 dirty가 아니어서, unfix 때 `page_buffer.c:7388` 의 debug 검사도 걸립니다.
* 뒤이은 커밋으로 로그가 flush된 뒤 shutdown checkpoint 전에 프로세스를 죽이고 DB를 다시 열면, recovery redo가 그 레코드를 적용하다 `heap_update_physical` 의 `spage_update` 에서 실패합니다(`heap_file.c:26324`). 4회 재현했습니다.
* 호출 경로: `heap_rv_undoredo_update` ← `heap_rv_redo_update` ← `log_rv_redo_record_sync`(`log_recovery_redo.hpp:664`) ← `log_recovery_redo` ← `log_recovery`

**3. release 빌드의 마지막 단계 (소스)**

* release 빌드에서는 `heap_update_physical`(`heap_file.c:26335`)과 `heap_rv_undoredo_update`(`heap_file.c:19730-19731`)가 `ER_FAILED` 를 돌려주고, `log_rv_redo_record_sync` 가 `logpb_fatal_error` 를 부릅니다(`log_recovery_redo.hpp:663-671`).
* 재시작할 때마다 같은 레코드를 다시 적용하므로 DB를 재시작할 수 없습니다.
* debug 바이너리로는 이 단계를 흉내 낼 수 없습니다. `assert (false)` 뒤 코드는 컴파일러가 없애므로, gdb로 건너뛰면 성공 경로로 갑니다. release 빌드로는 실행하지 않았습니다.

**CBRD-28062에서 하는 것과 이 이슈에 남는 것**

* PR #8632는 시스템 클래스 행에는 `oos_trigger_threshold` 를 적용하지 않고 계속 자동 목표값을 쓰기로 했습니다. 그러면 기준을 바꿔도 `_db_serial` 행의 배치가 바뀌지 않으므로, 이 PR이 새로 만드는 노출은 막힙니다.
* `serial_update_serial_object` 가 `spage_update` 성공 여부를 알기 전에 redo를 남기는 순서는 이 이슈의 문제로 남습니다. PR #8514 head `8d736ff51c` 에도 같은 순서가 있습니다(`serial.c:1588` assert, `1590` redo, `1593` `spage_update`). keep_form에서 inline 행이 커지는 경우(설계 검토 댓글 3절)에도, 커진 행이 page에 들어가지 않으면 같은 순서 때문에 같은 결과가 될 것으로 봅니다(소스, 재현하지 않음). 수정 후보: redo를 남기기 전에 `spage_is_updatable` 로 확인하고 로그 없이 실패하거나, 들어가지 않으면 `heap_update` 로 처리하기. 시험 후보: 4K DB에서 serial 행이 들어 있는 page를 채운 뒤 행이 커지는 NEXT VALUE.

**HA 반영 정지 (참고)**

같은 리뷰에서 "`_db_serial` 갱신의 복제 레코드가 OOS 참조를 담은 채 OOS 데이터 없이 전달되어 replica가 그 행을 반영하지 못한다"(`locator_sr.c:16121`, 소스)는 점도 찾았습니다. 앞 댓글(4778792)의 3번과 같은 문제라서 별도 이슈를 만들지 않았습니다.
