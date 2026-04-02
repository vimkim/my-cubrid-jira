# [OOS] DROP TABLE / DELETE 시 OOS 자원 회수 구현

## Description

### 배경

Milestone 1에서 OOS 파일 생성(`oos_file_create`) 및 삽입/읽기 경로는 구현되었으나,
`DROP TABLE` 수행 시 해당 테이블과 연결된 OOS 파일을 회수하는 경로가 구현되어 있지 않았다.
또한 `DELETE` 수행 시 heap record에 포함된 OOS OID가 가리키는 OOS 레코드가 삭제되지 않아
디스크 공간이 영구히 잔존하는 문제가 있었다.

### 목적

- `DROP TABLE` 수행 시 해당 테이블의 OOS 파일을 함께 삭제하여 디스크 공간을 회수한다.
- `DELETE` 수행 시 heap record 삭제 전에 OOS 데이터를 먼저 정리한다.
- WAL 로깅을 통해 crash → recovery 시 정합성을 보장한다.
- 향후 vacuum 연동에서 사용할 `oos_remove_page`를 함께 구현한다.
- `RVOOS_NOTIFY_VACUUM` recovery handler를 등록하여 vacuum이 OOS 삭제를 인지할 수 있도록 한다.

---

## Spec Change

### 신규 함수

| 함수 | 파일 | 설명 |
|---|---|---|
| `oos_remove_file` | `src/storage/oos_file.cpp` | OOS 파일 전체 삭제 (`file_postpone_destroy` 사용) |
| `oos_remove_page` | `src/storage/oos_file.cpp` | OOS 페이지 단위 해제 (`file_dealloc` 사용, 향후 vacuum용) |
| `locator_delete_oos_force` | `src/transaction/locator_sr.c` | DELETE 경로에서 OOS 데이터 정리 |

### 변경 함수

| 함수 | 파일 | 설명 |
|---|---|---|
| `xheap_destroy` | `src/storage/heap_file.c` | OOS 파일 정리 블록 추가 |
| `xheap_destroy_newly_created` | `src/storage/heap_file.c` | OOS 파일 정리 블록 추가 |
| `locator_delete_force_internal` | `src/transaction/locator_sr.c` | `locator_delete_oos_force` 호출 추가 |
| `oos_delete_chain` | `src/storage/oos_file.cpp` | 에러 처리 개선 (`ASSERT_ERROR_AND_SET` 패턴) |
| `oos_find_best_page` | `src/storage/oos_file.cpp` | mutex 보호 추가 |
| `oos_insert_within_page` | `src/storage/oos_file.cpp` | mutex 보호 추가 |
| `oos_get_recently_inserted_oos_vpid` | `src/storage/oos_file.cpp` | mutex 보호 추가 |

### 헤더 변경

- `src/storage/oos_file.hpp`: `oos_remove_file`, `oos_remove_page` 선언 추가
- `src/transaction/recovery.h`: `RVOOS_NOTIFY_VACUUM` (134) 추가, `RV_LAST_LOGID` 갱신
- `src/transaction/mvcc.h`: `LOG_IS_MVCC_OPERATION` 매크로에 `RVOOS_NOTIFY_VACUUM` 추가

---

## Implementation

### 1. `oos_remove_file` 구현 (`oos_file.cpp`)

기존 `oos_file_destroy` TODO stub을 `oos_remove_file`로 이름 변경 후 구현하였다.

```cpp
int
oos_remove_file (THREAD_ENTRY *thread_p, const VFID &oos_vfid)
{
  {
    std::lock_guard<std::mutex> lock (oos_vpid_map_mutex);
    oos_recently_inserted_oos_vpid_map.erase (oos_vfid);
  }

  file_postpone_destroy (thread_p, &oos_vfid);

  return NO_ERROR;
}
```

- `file_postpone_destroy`는 overflow 파일 삭제와 동일한 패턴으로, 트랜잭션 커밋 시 실제 삭제가 수행된다.
- in-memory map 접근 시 `std::mutex`로 thread-safety를 보장한다.

### 2. `oos_remove_page` 구현 (`oos_file.cpp`)

페이지 단위 해제 함수로, 향후 vacuum 연동 시 빈 OOS 페이지를 파일에 반납하는 데 사용된다.

```cpp
int
oos_remove_page (THREAD_ENTRY *thread_p, const VFID &oos_vfid, const VPID &vpid)
{
  int err = file_dealloc (thread_p, &oos_vfid, &vpid, FILE_OOS);
  if (err != NO_ERROR)
    {
      oos_error ("file_dealloc failed for vpid={pageid=%d, volid=%d}", vpid.pageid, vpid.volid);
      return err;
    }

  return NO_ERROR;
}
```

### 3. Thread-safety: `std::mutex` 추가

`oos_recently_inserted_oos_vpid_map` 전역 맵에 대해 `oos_vpid_map_mutex`를 추가하여
모든 접근 경로(`oos_find_best_page`, `oos_insert_within_page`, `oos_get_recently_inserted_oos_vpid`, `oos_remove_file`)에서
`std::lock_guard`로 보호한다.

### 4. DROP TABLE 경로 (`heap_file.c`)

`xheap_destroy`와 `xheap_destroy_newly_created`에 overflow 파일 정리 블록 이후 OOS 파일 정리 블록을 추가하였다.

```c
/* OOS file cleanup */
{
  VFID oos_vfid;
  if (heap_oos_find_vfid (thread_p, hfid, &oos_vfid, false))
    {
      int error = oos_remove_file (thread_p, oos_vfid);
      if (error != NO_ERROR)
        {
          ASSERT_ERROR ();
          return error;
        }
    }
}
```

### 5. DELETE 경로 (`locator_sr.c`)

`locator_delete_oos_force` 함수를 신규 구현하여, `locator_delete_force_internal`에서 heap record 삭제 전에 호출한다.

- class attribute를 순회하며 variable attribute 중 OOS로 표시된 항목의 OOS OID를 추출
- `oos_delete`를 호출하여 OOS 레코드 체인 전체를 물리적으로 삭제
- bounds check (`OR_OID_SIZE`), `OID_ISNULL` 검증으로 안전성 확보
- `heap_recdes_contains_oos` 검사로 OOS가 없는 레코드는 early return

### 6. Recovery handler (`recovery.c`, `recovery.h`, `mvcc.h`)

- `RVOOS_NOTIFY_VACUUM` (134)을 `LOG_RCVINDEX`에 추가하고 `RV_fun[]`에 등록
- undo/redo 모두 `vacuum_rv_es_nop` 사용 (실제 삭제는 `oos_delete`에서 수행됨)
- `LOG_IS_MVCC_OPERATION` 매크로에 추가하여 MVCC 로그로 인식
- `LOG_IS_SYSOP_WITH_POSTPONE_RCVINDEX`에 추가

### 7. 에러 처리 개선 (`oos_file.cpp`)

`oos_delete_chain`에서 기존의 `assert(false)` + `er_set` + `return ER_FAILED` 패턴을
`ASSERT_ERROR_AND_SET` 매크로로 통일하고, record header 길이 검증에 `assert_release` + `er_set` 패턴을 적용하였다.

---

## Test

### 단위 테스트 (`unit_tests/oos/test_oos_remove_file.cpp`)

| 테스트 | 설명 |
|---|---|
| `OosFileDestroyBasic` | 파일 생성 후 삭제, `NO_ERROR` 반환 검증 |
| `OosFileDestroyWithData` | 데이터 삽입 후 파일 삭제 |
| `OosFileDestroyWithMultiChunkData` | multi-chunk 레코드 삽입 후 파일 삭제 |
| `OosFileDestroyMapCleared` | 삭제 후 in-memory map 항목 제거 검증 |
| `OosPageDestroyBasic` | 페이지 단위 해제 (`oos_remove_page`) |
| `OosFileDestroyMultipleFiles` | 하나만 삭제해도 다른 파일에 영향 없음 검증 |

### 통합 테스트

- Shell 테스트 통과: https://github.com/CUBRID/cubrid-testcases-private-ex/pull/3056

---

## Acceptance Criteria

- [x] `DROP TABLE` 후 OOS 파일이 삭제되고 디스크 공간이 회수된다.
- [x] `DROP TABLE` 중 crash → recovery 후 orphan OOS 파일이 남지 않는다 (`file_postpone_destroy` 패턴).
- [x] OOS 파일이 없는 테이블에 대한 `DROP TABLE` 수행 시 기존 동작에 영향이 없다.
- [x] `DELETE` 수행 시 OOS 레코드가 물리적으로 삭제된다.
- [x] 기존 OOS insert / read / update 기능 regression 없음.
- [x] 전역 맵 접근 시 thread-safety 보장 (`std::mutex`).
- [x] 단위 테스트 6개 통과, Shell 테스트 통과.

---

## Remarks

- 함수 이름 변경: `oos_file_destroy` → `oos_remove_file`, `oos_page_destroy` → `oos_remove_page` (codebase 네이밍 컨벤션 `heap_remove_page` 등과 통일)
- `oos_remove_page`는 현재 vacuum에서 호출되지 않으며, 향후 OOS vacuum 구현 시 연동 예정
- PR: https://github.com/CUBRID/cubrid/pull/6919

## 참고 코드

- `src/storage/oos_file.cpp` — `oos_remove_file`, `oos_remove_page`, `oos_delete_chain`
- `src/storage/heap_file.c` — `xheap_destroy`, `xheap_destroy_newly_created`, `heap_oos_find_vfid`
- `src/transaction/locator_sr.c` — `locator_delete_oos_force`, `locator_delete_force_internal`
- `src/transaction/recovery.h` — `RVOOS_NOTIFY_VACUUM`
- `src/storage/file_manager.h` — `file_postpone_destroy`, `file_dealloc`
