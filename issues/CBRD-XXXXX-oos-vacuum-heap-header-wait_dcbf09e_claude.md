# [OOS] vacuum과 새 힙 페이지 할당이 서로의 페이지 래치를 기다려 INSERT가 300초 동안 멈춘 뒤 실패한다

## Issue Triage

**이슈 수행 목적**: OOS 값이 있는 행을 vacuum하는 중에 같은 테이블에 새 힙 페이지가 필요한 INSERT가 들어와도, 두 작업이 서로를 기다리지 않고 끝나게 한다.

**이슈 수행 이유**: vacuum은 OOS 파일을 찾으려고 힙 헤더를 기다리는 동안 처리 중인 힙 페이지를 놓지 않는다. 새 힙 페이지를 할당하는 INSERT는 힙 헤더를 먼저 잡고 마지막 힙 페이지를 기다린다. vacuum이 쥔 페이지가 마지막 페이지이면 둘은 서로를 기다리고, 페이지 래치에는 교착 탐지가 없다. PR 7990의 hornetmj 리뷰(R2)에서 보고됐고, 실제 vacuum worker를 쓰는 단위 테스트로 독립 재현했다.

**영향**: INSERT는 페이지 래치 대기 한도(기본 300초) 동안 멈춘 뒤 실패한다. 이번 재현에서 힙 페이지 할당이 약 316초 막힌 뒤 `ER_PAGE_LATCH_TIMEDOUT`을 받았고, debug 빌드는 그 시점의 assertion으로 종료됐다. 리뷰어는 release에서 INSERT가 306~311초 뒤 강제 abort되어 행 1건이 저장되지 않고, 같은 헤더를 기다리던 vacuum worker 2개도 함께 멈춘 것을 관찰했다. 지연 주입이나 테스트 순서 조정 없이 실제로 얼마나 자주 생기는지는 측정하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

OOS(행 밖에 저장한 큰 컬럼 값)를 가진 테이블은 힙 파일마다 OOS 파일을 하나 둔다. 그 OOS 파일의 ID(VFID)는 힙 헤더 페이지에 저장된다. vacuum이 OOS 값을 가진 행을 처리하려면 먼저 이 ID를 읽어야 한다.

분석 기준은 PR 7990의 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`이다. [`vacuum_heap_prepare_record`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/query/vacuum.c#L2009-L2263)는 `REC_HOME` 행이면 home 페이지를, `REC_RELOCATION` 행이면 home과 forward 페이지를 WRITE로 쥔 채 [`vacuum_oos_find_vfid_for_heap_record`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/query/vacuum_oos.cpp#L389-L424)를 부른다. 이 함수가 부르는 [`heap_oos_find_vfid`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/heap_file.c#L13229-L13353)는 힙 헤더를 무조건 대기(`PGBUF_UNCONDITIONAL_LATCH`)로 고정한다.

반대로 [`heap_alloc_new_pages`](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/heap_file.c#L28554-L28640)는 힙 헤더를 WRITE로 잡은 채 `heap_get_last_page`에서 마지막 힙 페이지를 WRITE로 기다린다. INSERT가 쓸 빈 페이지가 없으면 bestspace가 이 함수를 불러 새 페이지를 만든다. 힙 페이지의 순서 고정 래치(`pgbuf_ordered_fix`)도 헤더를 데이터 페이지보다 먼저 잡는 순서를 따른다.

vacuum이 쥔 home이나 forward 페이지가 마지막 힙 페이지이면 다음 순환이 생긴다.

```text
vacuum worker                              INSERT (새 힙 페이지 필요)
마지막 힙 페이지 WRITE 보유                heap_alloc_new_pages
                                             힙 헤더 WRITE 보유
                                             heap_get_last_page -> 마지막 페이지 대기
heap_oos_find_vfid -> 힙 헤더 READ 대기
```

같은 함수의 `REC_BIGONE` 처리는 overflow 파일 ID를 찾을 때 이미 이 순서를 피한다. 헤더를 [조건부로 시도](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/query/vacuum.c#L2162-L2189)하고, 실패하면 home의 변경을 로그에 남기고 페이지를 놓은 뒤 헤더를 기다린다. 그 뒤 home을 다시 잡고 slot부터 다시 읽는다. OOS 파일 조회에는 이 처리가 없다.

develop `ef4e7e812`의 vacuum에는 OOS 파일 조회가 없고 `REC_BIGONE`의 조건부 처리만 있다. 따라서 이 대기 순서는 PR 7990이 추가한 경로에서 생긴다. `heap_oos_find_vfid`의 다른 호출자(insert, 복제, TDE, 통계, 삭제, vacuum의 forward walk)는 힙 데이터 페이지를 쥔 채 헤더를 기다리지 않는다.

### 왜 문제인가

사용자는 큰 컬럼을 가진 테이블에 행을 넣으면서 다른 행을 갱신하거나 지운다. INSERT는 보통 밀리초 안에 끝나기를 기대한다. 이 결함에서는 마지막 페이지가 차서 새 페이지가 필요한 INSERT가 vacuum과 서로를 기다리며 페이지 래치 대기 한도(`page_latch_timeout_in_msecs`, 기본 300,000 ms)까지 멈춘다. 한도가 지나면 INSERT가 실패하고 그 행은 저장되지 않는다. 응용은 5분 가까이 응답을 받지 못한 뒤 오류를 받고 재시도해야 한다.

멈추는 범위는 INSERT 하나에 그치지 않는다. 같은 테이블의 헤더가 필요한 다른 작업도 그동안 기다린다. 리뷰어는 같은 헤더를 기다리던 다른 vacuum worker 2개가 함께 멈춘 것을 관찰했다. 멈춘 worker가 맡은 정리 작업도 그동안 밀릴 것으로 예상하지만, 그 규모는 측정하지 않았다. debug 빌드에서는 래치 대기 시간 초과 경로의 `assert (0)`(`pgbuf_timed_sleep`)으로 서버가 종료되므로, debug 빌드로 돌리는 QA 실행이 중단될 수 있다.

발생 조건은 두 가지가 겹치는 것이다. vacuum이 OOS 값을 가진 행을 마지막 힙 페이지에서 처리하고 있어야 하고, 그 사이 같은 테이블의 INSERT가 새 페이지를 할당해야 한다. 최근 INSERT와 갱신이 몰리는 곳이 마지막 페이지이고 vacuum 작업도 최근 변경을 따라가므로, 두 조건은 같은 페이지에서 만날 수 있다. 다만 실제 부하에서의 빈도는 측정하지 않았다. 리뷰어의 재현은 vacuum에 지연을 주입했고, 이번 재현은 테스트가 헤더를 먼저 잡는 순서를 만들었다.

### 왜 해결해야 하는가

이 대기 순서는 OOS 도입 PR이 추가한 vacuum 경로에서 생기며, develop에 반영되면 OOS 테이블의 INSERT가 5분 동안 멈춘 뒤 실패할 수 있다. 사용자나 운영자가 쓸 수 있는 우회책이 없다. vacuum의 실행 시점과 INSERT가 받을 페이지를 사용자가 제어할 수 없다. `page_latch_timeout_in_msecs`는 숨겨진 파라미터이며, 줄여도 INSERT가 더 빨리 실패할 뿐 순환은 그대로다.

리뷰 원문은 [PR 8235](https://github.com/CUBRID/cubrid/pull/8235)가 고쳤을 수 있다고 물었다. PR 8235의 merge `9b93263d07cab80edf02217e8d6c4f0fcf2fd9ac`는 기준 소스의 조상이 아니며, 병렬 힙 스캔·통계 sampling·병렬 index build의 페이지 순회와 `heap_remove_page_on_vacuum`의 대기자 처리를 바꾼다. 대응 티켓은 [CBRD-27723](https://jira.cubrid.org/browse/CBRD-27723)이다. OOS 파일 조회와 힙 페이지 할당은 바꾸지 않으므로 이 결함을 해결하지 않는다.

2026-10-31 JIRA에서 CBRD-26583의 하위 작업과 최근 14일의 vacuum·OOS·deadlock 관련 이슈를 검색했다. 이 결함의 별도 티켓은 찾지 못했다.

## Test Build

- CUBRID 소스는 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`에 아래의 단위 테스트를 더한 것이다. 테스트는 엔진 코드를 바꾸지 않는다.
- CUBRID `11.5.0.2781-dcbf09e`, 64-bit debug, GCC 11.5.0, Linux `5.14.0-570.30.1.el9_6.x86_64`에서 실행했다.
- DB는 CTest fixture `oos_setup_db`가 만드는 `unittestdb`이다. 20MB 데이터 볼륨과 20MB 로그 볼륨, `en_US.utf8`이며, fixture가 `[@unittestdb]`에 `vacuum_log_block_pages=4`를 더한다. 나머지 파라미터는 기본값이다.
- release 빌드, SQL로 실행하는 종단 재현, `REC_RELOCATION` 행의 경합은 실행하지 않았다.

## Repro

테스트는 서버를 같은 프로세스에서 SERVER_MODE로 띄우고 실제 vacuum worker를 쓴다. 테스트 스레드가 헤더를 먼저 잡는 할당자 역할을 한다.

1. 분석 기준 소스를 독립 checkout에서 받고 아래 diff를 `r2-repro-test.patch`로 저장해 적용한다. 빌드 의존성은 프로젝트의 `docs/install_build_requirements.md`를 따른다. preset이 `CUBRID`를 설치 경로로 쓰고 CTest가 구성 시점의 값을 기록하므로, 구성 전에 `CUBRID`와 `CUBRID_DATABASES`(DB registry 디렉터리)를 정한다. 다른 인스턴스와 겹치지 않는 경로를 쓴다.

```sh
git checkout --detach dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67
git apply r2-repro-test.patch
export CUBRID="$HOME/cubrid-r2/install" CUBRID_DATABASES="$HOME/cubrid-r2/databases"
mkdir -p "$CUBRID_DATABASES"
cmake --preset debug -DUNIT_TEST_OOS=ON
cmake --build build_preset_debug
cmake --install build_preset_debug
```

2. 설치본의 라이브러리를 쓰도록 환경을 맞추고 이 테스트만 실행한다. fixture가 `unittestdb`를 만들고 끝나면 지운다.

```sh
export PATH="$CUBRID/bin:$PATH" LD_LIBRARY_PATH="$CUBRID/lib:$LD_LIBRARY_PATH"
GTEST_FILTER=OosRealVacuum.VacuumWaitsForHeapHeaderWithoutHoldingLastPage \
  ctest --test-dir build_preset_debug --output-on-failure \
  -R '^(oos_setup_db|test_oos_real_vacuum_server|oos_cleanup_db)$'
```

테스트는 다음 순서로 실행한다.

1. `heap_alloc_new_pages`로 마지막 힙 페이지를 만들고, OOS 값을 참조하는 행을 그 페이지에 넣은 뒤 commit한다.
2. 그 행의 로그 블록이 닫히기 전에 힙 헤더를 WRITE로 잡는다.
3. OOS insert와 로그 flush로 블록을 닫는다. 페이지를 쥔 채 트랜잭션을 끝낼 수 없으므로 commit 대신 이 방법을 쓴다.
4. vacuum worker가 헤더 대기열에 들어오면 마지막 페이지를 조건부 WRITE로 요청한다. 성공하면 실제 `heap_alloc_new_pages`를 불러 끝나는지 확인한다. 조건부 요청이므로 결함이 있어도 300초를 기다리지 않는다.
5. 헤더를 놓은 뒤 vacuum이 그 행의 insert MVCCID를 지우고 OOS 값이 남아 있는지 확인한다.

```diff
diff --git a/unit_tests/oos/CMakeLists.txt b/unit_tests/oos/CMakeLists.txt
index 2fb17c113..8b309b2a8 100644
--- a/unit_tests/oos/CMakeLists.txt
+++ b/unit_tests/oos/CMakeLists.txt
@@ -257,11 +257,11 @@ set_tests_properties(
   PROPERTIES FIXTURES_REQUIRED OOS_DB RUN_SERIAL TRUE TIMEOUT 60
 )
 
-# Ten real-vacuum cases each allow up to 60 seconds for asynchronous reclamation.
-# Cover those deadlines plus setup, teardown, and Debug diagnostic overhead.
+# Ten real-vacuum cases each allow up to 60 seconds for asynchronous reclamation, and the heap header
+# latch case allows 60 seconds twice. Cover those deadlines plus setup, teardown, and Debug diagnostic overhead.
 set_tests_properties(
   test_oos_real_vacuum_server
-  PROPERTIES FIXTURES_REQUIRED OOS_DB RUN_SERIAL TRUE TIMEOUT 720
+  PROPERTIES FIXTURES_REQUIRED OOS_DB RUN_SERIAL TRUE TIMEOUT 840
 )
 
 # Note: add_test vs. gtest_discover_tests
diff --git a/unit_tests/oos/test_oos_real_vacuum_server.cpp b/unit_tests/oos/test_oos_real_vacuum_server.cpp
index 3549f084a..c0c4ec0b1 100644
--- a/unit_tests/oos/test_oos_real_vacuum_server.cpp
+++ b/unit_tests/oos/test_oos_real_vacuum_server.cpp
@@ -862,6 +862,122 @@ TEST_F (OosRealVacuum, ReVacuumAfterDrainIsIdempotent)
   expect_oos_gone (oos_oid, "drained OOS after re-vacuum");
 }
 
+static bool
+insert_id_vacuumed (const OID &oid)
+{
+  VPID vpid;
+  VPID_GET_FROM_OID (&vpid, &oid);
+  PAGE_PTR page = pgbuf_fix (thread_p, &vpid, OLD_PAGE, PGBUF_LATCH_READ, PGBUF_UNCONDITIONAL_LATCH);
+  if (page == NULL)
+    {
+      er_clear ();
+      return false;
+    }
+  RECDES rec {};
+  MVCC_REC_HEADER mvcc_header;
+  bool vacuumed = spage_get_record (thread_p, page, oid.slotid, &rec, PEEK) == S_SUCCESS
+		  && or_mvcc_get_header (&rec, &mvcc_header) == NO_ERROR
+		  && !MVCC_IS_FLAG_SET (&mvcc_header, OR_MVCC_FLAG_VALID_INSID);
+  pgbuf_unfix_and_init (thread_p, page);
+  return vacuumed;
+}
+
+// ============================================================================
+// TC-R11: Vacuum waits for the heap header without holding the last heap page
+//
+// heap_alloc_new_pages holds the heap header and then latches the last heap page. Page latches have
+// no deadlock detection, so a vacuum worker that holds the last page while it waits for the header
+// stalls both sides until the latch timeout. The test thread plays the allocator: it holds the header
+// until the vacuum worker queues on it, then checks that the last page is free and that the real
+// allocator finishes.
+// ============================================================================
+TEST_F (OosRealVacuum, VacuumWaitsForHeapHeaderWithoutHoldingLastPage)
+{
+  RECDES oos_rec {};
+  ASSERT_EQ (test_oos_utils::from_string_into_recdes (test_oos_utils::make_repeated_pattern_string (4096), oos_rec),
+	     NO_ERROR);
+  test_oos_utils::auto_freed_recdes_ptr defer_oos (&oos_rec, recdes_free_data_area);
+  OID oos_oid = OID_INITIALIZER;
+  ASSERT_EQ (test_oos_utils::oos_insert_from_recdes (thread_p, oos_vfid, oos_rec, oos_oid), NO_ERROR);
+
+  RECDES heap_rec {};
+  ASSERT_EQ (build_heap_recdes_with_oos ({oos_oid}, { (INT64) oos_rec.length}, heap_rec), NO_ERROR);
+  test_oos_utils::auto_freed_recdes_ptr defer_heap (&heap_rec, recdes_free_data_area);
+
+  VPID last_vpid = VPID_INITIALIZER;
+  PGBUF_WATCHER last_watcher;
+  ASSERT_EQ (heap_alloc_new_pages (thread_p, &hfid, 1, &last_vpid, &last_watcher), NO_ERROR);
+  HEAP_OPERATION_CONTEXT insert_ctx;
+  heap_create_insert_context (&insert_ctx, &hfid, &class_oid, &heap_rec, &scan_cache);
+  ASSERT_EQ (heap_insert_logical (thread_p, &insert_ctx, &last_watcher), NO_ERROR);
+  const OID heap_oid = insert_ctx.res_oid;
+  ASSERT_EQ (heap_oid.pageid, last_vpid.pageid);
+  ASSERT_EQ (heap_oid.volid, last_vpid.volid);
+  VACUUM_LOG_BLOCKID insert_block = current_log_blockid ();
+  commit_current_tran ();
+
+  /* Take the header before the insert's log block closes, so vacuum cannot reach the row first. */
+  VPID header_vpid;
+  header_vpid.volid = hfid.vfid.volid;
+  header_vpid.pageid = hfid.hpgid;
+  PGBUF_WATCHER header_watcher;
+  PGBUF_INIT_WATCHER (&header_watcher, PGBUF_ORDERED_HEAP_HDR, &hfid);
+  ASSERT_EQ (pgbuf_ordered_fix (thread_p, &header_vpid, OLD_PAGE, PGBUF_LATCH_WRITE, &header_watcher), NO_ERROR);
+
+  /* Ending a transaction requires that it hold no pages, so close the insert's log block with OOS
+   * inserts, which are not MVCC operations, and with the log flush a commit would do. Vacuum skips
+   * blocks near the end of the flushed log. */
+  bool log_advanced = true;
+  for (int guard = 0; log_advanced && current_log_blockid () <= insert_block + 1; guard++)
+    {
+      OID filler_oid = OID_INITIALIZER;
+      log_advanced = guard < 20000
+		     && test_oos_utils::oos_insert_from_recdes (thread_p, oos_vfid, oos_rec, filler_oid) == NO_ERROR;
+    }
+  if (log_advanced)
+    {
+      LOG_LSA flush_lsa = log_Gl.prior_info.prior_lsa;
+      logpb_flush_pages (thread_p, &flush_lsa);
+    }
+
+  const bool vacuum_waits_for_header = log_advanced
+				       && wait_for_vacuum ([&header_watcher] { return pgbuf_has_any_waiters (header_watcher.pgptr); }, 60);
+  bool last_page_free = false;
+  bool allocation_finished = false;
+  if (vacuum_waits_for_header)
+    {
+      PAGE_PTR last_page = pgbuf_fix (thread_p, &last_vpid, OLD_PAGE, PGBUF_LATCH_WRITE, PGBUF_CONDITIONAL_LATCH);
+      last_page_free = last_page != NULL;
+      if (last_page_free)
+	{
+	  pgbuf_unfix_and_init (thread_p, last_page);
+
+	  /* Only now is the allocator safe to run: with the last page held by vacuum it would block. */
+	  VPID next_vpid = VPID_INITIALIZER;
+	  PGBUF_WATCHER next_watcher;
+	  allocation_finished = heap_alloc_new_pages (thread_p, &hfid, 1, &next_vpid, &next_watcher) == NO_ERROR;
+	  if (allocation_finished)
+	    {
+	      pgbuf_ordered_unfix (thread_p, &next_watcher);
+	    }
+	}
+      er_clear ();
+    }
+  pgbuf_ordered_unfix (thread_p, &header_watcher);
+  commit_current_tran ();
+
+  ASSERT_TRUE (log_advanced) << "OOS filler failed to close the insert's log block";
+  ASSERT_TRUE (vacuum_waits_for_header) << "vacuum never queued on the heap header";
+  EXPECT_TRUE (last_page_free)
+      << "vacuum held the last heap page while it waited for the heap header; an allocator holding the header "
+      "would wait for that page until the latch timeout";
+  EXPECT_TRUE (!last_page_free || allocation_finished) << "heap_alloc_new_pages failed while vacuum waited";
+
+  EXPECT_TRUE (wait_for_vacuum ([&heap_oid] { return insert_id_vacuumed (heap_oid); }, 60))
+      << "vacuum did not finish the row after the header was released";
+  EXPECT_FALSE (oos_unreadable (oos_oid)) << "vacuum of a live row lost its OOS value";
+}
+
 int
 main (int argc, char **argv)
 {
```

## Expected Result

vacuum worker가 헤더를 기다리는 동안 마지막 힙 페이지를 쥐지 않는다. 헤더를 쥔 할당자가 마지막 페이지를 바로 잡고 `heap_alloc_new_pages`를 마친다. 헤더를 놓으면 vacuum이 그 행을 다시 읽어 처리하고, 행의 OOS 값은 그대로 남는다.

## Actual Result

수정 전 소스에서 vacuum worker는 테스트가 쥔 헤더를 기다리는 동안 마지막 힙 페이지를 쥐고 있었다. 테스트는 1.31초에 실패했다.

```text
test_oos_real_vacuum_server.cpp:971: Failure
Value of: last_page_free
  Actual: false
Expected: true
vacuum held the last heap page while it waited for the heap header; an allocator holding the header would wait for that page until the latch timeout
```

같은 순서에서 조건부 요청 대신 실제 `heap_alloc_new_pages`를 부르는 일회성 실험을 했다. 할당은 마지막 페이지를 약 316초 기다린 뒤 `ER_PAGE_LATCH_TIMEDOUT`을 받았고, debug 빌드는 다음 assertion으로 종료됐다. 이 실험 코드는 테스트에 남기지 않았다.

```text
test_oos_real_vacuum_server: .../src/storage/page_buffer.c:7365: int pgbuf_timed_sleep(THREAD_ENTRY*, PGBUF_BCB*): Assertion `0' failed.
```

계측으로 확인한 사실은 다음과 같다. vacuum worker가 헤더 대기열에 있는 동안 마지막 페이지는 READ로도 잡을 수 없었다. 헤더를 놓자 테스트가 commit하기 전에 vacuum이 그 행을 처리했다. 따라서 vacuum을 막은 것은 헤더였다.

## Additional Information

- 로컬 후보 수정은 `REC_BIGONE`의 방식을 OOS 파일 조회에 적용한다. 헤더를 기다리지 않는 `heap_oos_find_vfid_nowait`로 먼저 시도하고, 헤더가 바쁘면 forward와 home 페이지를 놓은 뒤 헤더를 기다려 조회한다. 그 뒤 home을 다시 잡고 slot부터 다시 읽는다. 재시작은 레코드당 한 번이며, 기다린 조회의 답을 최종으로 쓴다. `heap_oos_find_vfid`의 서명과 "false는 실제 오류" 계약은 유지한다. `vacuum.c`, `heap_file.c`, `heap_file.h` 세 파일이 바뀌며, 팀 리뷰 전 후보이다.
- 후보 수정에서 같은 테스트가 215 ms에 통과했다. vacuum worker가 헤더를 기다리는 동안 마지막 페이지가 비어 있었고, 실제 `heap_alloc_new_pages`가 끝났으며, 헤더를 놓은 뒤 vacuum이 행을 처리했다.
- 후보 수정의 debug 빌드에서 구성된 CTest 44개가 모두 통과했다. 같은 리뷰의 R5 수정(CBRD-27858)을 함께 적용한 빌드에서도 44개가 모두 통과했다. R5는 실행 단계에서 forward 페이지를 sysop 끝까지 쥐고, 이 후보는 sysop 전 준비 단계만 바꾼다.
- home이나 forward가 힙 헤더 페이지 자체이면 같은 스레드의 재고정이 허용되므로 후보 수정의 해제 경로를 타지 않는다. 리뷰어가 관찰한 이 경우의 29초 대기는 교착이 아니며, 후보 수정이 이 대기를 줄인다고 주장하지 않는다.
- 관련 원본은 [PR 7990](https://github.com/CUBRID/cubrid/pull/7990), [리뷰 원문](https://github.com/CUBRID/cubrid/pull/7990#discussion_r4399323155), 상위 작업 [CBRD-26583](https://jira.cubrid.org/browse/CBRD-26583)이다.

## Triage Request

OOS vacuum과 새 힙 페이지 할당의 래치 순환으로 INSERT가 300초 동안 멈춘 뒤 실패하는 문제를 확인하고, OOS 담당 작성자 측의 ANALYSIS 배정을 요청한다. 분석에서는 다음을 확인한다.

- 조건부 조회와 페이지 해제 후 재시작이라는 로컬 후보가 `REC_HOME`과 `REC_RELOCATION`의 재시작 계약을 지키는가.
- `REC_RELOCATION` 행의 경합, release 빌드, SQL로 실행하는 INSERT·DELETE·vacuum 부하에 추가 검증이 필요한가.
- 경합이 없는 경우 재시작이 생기지 않아 vacuum 비용이 늘지 않는가.

독립 회사 PR의 리뷰와 CI를 받은 뒤 반영한다.
