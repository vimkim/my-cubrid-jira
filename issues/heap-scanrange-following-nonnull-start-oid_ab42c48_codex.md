# [HEAP] heap_scanrange_to_following이 non-NULL start_oid에서 NULL OID를 조회하는 문제

## Issue Triage

**이슈 수행 목적**: `OID`(object identifier, heap 객체의 저장 위치 식별자)로 시작점을 지정하는
`heap_scanrange_to_following()`이 유효한 non-NULL `start_oid`를 받았을 때 올바른 heap 스캔 범위를 만들고
assertion을 일으키지 않도록 한다.

**이슈 수행 이유**:

| 구분 | 동작 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | 유효한 첫 heap 객체 OID를 non-NULL `start_oid`로 넘기면, 객체가 존재해도 scanrange 생성 중 assertion이 발생해 debug build가 종료된다. |
| **TO-BE (목표 상태 / 기대 동작)** | 유효한 non-NULL `start_oid`를 받으면 NULL OID를 조회하거나 assertion을 일으키지 않고 함수 계약에 맞는 결과를 반환한다. 삭제 객체와 현재 읽기 시점에 보이지 않는 객체의 처리 규칙은 `TBD - 합의 미확인`이다. |

**영향**: 설계 의도 훼손 — 문서화된 non-NULL 입력 계약과 실제 구현이 달라, 내부 API를 사용하는 새 경로가
debug build 프로세스를 즉시 종료할 수 있다.

**이슈 수행 방안**: 이 문제는 CBRD-26847 변경과 섞지 않고 별도 Correct Error로 분리한다.
정확한 OID 선택 방식, 삭제·비가시 객체 처리, 회귀 테스트 위치와 대상 버전은 `TBD - 합의 미확인`으로 둔다.

---

## AI-Generated Context

> 아래는 AI가 코드와 재현 결과를 분석해 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로
> 충분하며, 본문은 구현과 리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: 확인된 결함은 `src/storage/heap_file.c`의 내부 heap scanrange 경계 처리에 한정된다.
  공개 SQL 문법과 저장 형식에는 영향이 없다.

## Description

`HEAP_SCANRANGE`는 heap을 여러 범위로 나누어 순회할 때 첫 OID와 마지막 OID, page watcher(고정한 page와
해제 시점을 추적하는 구조)를 함께 보관하는 내부 cursor(현재 순회 위치를 담는 상태 구조)다.
`heap_scanrange_start()`는 두 경계 OID를 NULL로 초기화한다.

`heap_scanrange_to_following()`의 함수 주석은 non-NULL이면서 NULL_OID가 아닌 `start_oid`를 받으면 그 객체를
범위의 첫 객체로 사용한다고 명시한다. 구현도 먼저 `scan_range->first_oid = *start_oid`를 수행하지만, 바로 다음
visibility 조회에는 `&scan_range->last_oid`를 전달한다. 최초 범위에서는 `last_oid`가 NULL이므로 조회 대상이
요청 OID와 달라진다.

```
heap_scanrange_start()
  └ first_oid = NULL, last_oid = NULL

heap_scanrange_to_following(start_oid = valid_oid)
  ├ first_oid = valid_oid
  └ heap_get_visible_version(last_oid = NULL)
       └ heap_prepare_object_page(NULL OID)
            └ assertion failure: !OID_ISNULL (oid)
```

이 코드는 `heap_get_visible_version()`에 전달할 OID를 잘못 선택한 문제다.

## Test Build

- CUBRID `11.5.0.2461`, 64-bit debug build
- 소스 커밋: `ab42c48a25aa5c419f1a0647090d80af6f1c0cb0`
- 운영체제: Linux `5.14.0-570.30.1.el9_6.x86_64`, x86_64

## Repro

```bash
git apply <<'PATCH'
diff --git a/unit_tests/oos/sql/test_oos_sql_visible_version.cpp b/unit_tests/oos/sql/test_oos_sql_visible_version.cpp
index 2e98c2f1b..270c5745f 100644
--- a/unit_tests/oos/sql/test_oos_sql_visible_version.cpp
+++ b/unit_tests/oos/sql/test_oos_sql_visible_version.cpp
@@ -80,6 +80,50 @@ TEST_F (OosSqlVisibleVersion, ScanrangeBoundaryFetchDoesNotExpandWholeRecord)
   heap_scanrange_end (thread_p, &scan_range);
 }
 
+TEST_F (OosSqlVisibleVersion, NonNullStartOidUsesRequestedObject)
+{
+  int rc;
+
+  rc = exec_sql ("CREATE TABLE t_oos_visible_version (id INT PRIMARY KEY, payload BIT VARYING)");
+  ASSERT_GE (rc, 0);
+  rc = exec_sql ("INSERT INTO t_oos_visible_version VALUES (1, X'AA'), (2, X'BB')");
+  ASSERT_GE (rc, 0);
+  db_commit_transaction ();
+
+  THREAD_ENTRY *thread_p = thread_get_thread_entry_info ();
+  DB_OBJECT *class_object = db_find_class ("t_oos_visible_version");
+  ASSERT_NE (class_object, nullptr);
+
+  OID class_oid = *reinterpret_cast<OID *> (db_identifier (class_object));
+  HFID hfid;
+  FILE_TYPE file_type;
+  rc = heap_get_class_info (thread_p, &class_oid, &hfid, &file_type, nullptr);
+  ASSERT_EQ (rc, NO_ERROR);
+
+  MVCC_SNAPSHOT *snapshot = logtb_get_mvcc_snapshot (thread_p);
+  ASSERT_NE (snapshot, nullptr);
+
+  HEAP_SCANCACHE scan_cache;
+  rc = heap_scancache_start (thread_p, &scan_cache, &hfid, &class_oid, true, snapshot);
+  ASSERT_EQ (rc, NO_ERROR);
+
+  OID requested_oid;
+  RECDES recdes = RECDES_INITIALIZER;
+  SCAN_CODE scan = heap_first (thread_p, &hfid, &class_oid, &requested_oid, &recdes, &scan_cache, PEEK);
+  ASSERT_EQ (scan, S_SUCCESS);
+  ASSERT_EQ (heap_scancache_end (thread_p, &scan_cache), NO_ERROR);
+
+  HEAP_SCANRANGE scan_range;
+  rc = heap_scanrange_start (thread_p, &scan_range, &hfid, &class_oid, snapshot);
+  ASSERT_EQ (rc, NO_ERROR);
+
+  scan = heap_scanrange_to_following (thread_p, &scan_range, &requested_oid);
+  EXPECT_EQ (scan, S_SUCCESS);
+  EXPECT_TRUE (OID_EQ (&scan_range.first_oid, &requested_oid));
+
+  heap_scanrange_end (thread_p, &scan_range);
+}
+
 /*
  * The old record is much larger than the fixed fetch buffer when logically expanded. Updating only the indexed
  * integer must fetch the stored-form record and Resolve attributes through the attribute layer instead of eagerly
PATCH
```

```bash
./build.sh -m debug -c "-DUNIT_TESTS=ON"
ctest --test-dir build_x86_64_debug -R test_oos_sql_visible_version --output-on-failure
```

## Expected Result

`heap_scanrange_to_following()`이 `S_SUCCESS`를 반환하고 `scan_range.first_oid`가 `requested_oid`와 같아야 한다.

## Actual Result

테스트 프로세스가 다음 assertion에서 abort한다.

```text
src/storage/heap_file.c:26763: heap_prepare_object_page:
Assertion `oid != NULL && !OID_ISNULL (oid)' failed.
```

## Additional Information

- 함수 계약: `src/storage/heap_file.c:8378-8393`
- 잘못된 OID 인자: `src/storage/heap_file.c:8424-8428`
- 현재 제품 코드의 유일한 호출자: `src/query/scan_manager.c:5053`, `start_oid = NULL`
- 최초 발견 경로: CBRD-26847의 `RECDES` 소비 정책 감사
- 임시 재현 위치: storage API를 이미 사용하는 `unit_tests/oos/sql/test_oos_sql_visible_version.cpp`
- 재현용 임시 테스트는 결과 확인 후 source worktree에서 제거했다.
