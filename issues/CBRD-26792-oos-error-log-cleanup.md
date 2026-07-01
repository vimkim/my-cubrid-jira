# [OOS] release 오류 경로를 CUBRID 에러 시스템에 맞춘다

## Issue Triage

**이슈 수행 목적**: OOS 의 release 빌드 오류가 CUBRID 표준 에러 경로(`er_set`, 서버 에러 로그, client-visible error id)를 통해 보고되도록 한다. 단기적으로 개발 추적용 `oos.log` 는 유지한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `oos_log.hpp` 는 `oos_error`/`oos_warn` 을 release 에서도 활성화하지만, `oos_file.cpp` 와 `heap_oos.cpp` 의 여러 OOS 무결성 실패는 여전히 `ER_GENERIC_ERROR` 또는 `ER_FAILED` 로 접힌다. `vacuum_oos.cpp` 에는 develop merge 전 제거해야 할 임시 `abort()` 경로도 남아 있다.
- **영향**: 기술 부채 - release 빌드에서 OOS record/chunk/inline header 손상이 발생해도 표준 에러 코드만으로 원인을 구분하기 어렵고, `oos.log` 를 모르는 QA/CS 경로에서는 실패가 일반 엔진 오류처럼 보인다.

**이슈 수행 방안**: 사용자 인용: "current debugging the same (oos.log) for a while" 이므로 `oos.log` 는 auxiliary debug sink 로 유지한다. 사용자 인용: "for release mode, I want the critical errors and stuff be aligned with CUBRID's own error logging" 이므로 critical OOS 오류는 `oos_error` 매크로에 의존하지 않고 명시적인 `er_set`/전용 error id/메시지로 정리한다. 세부 error id 분류와 client-facing 복제 범위는 `TBD - ANALYSIS 단계에서 결정` 으로 둔다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/oos_log.hpp`, `src/storage/oos_file.cpp`, `src/storage/heap_oos.cpp`, `src/storage/heap_file.c`, `src/query/vacuum_oos.cpp`, `src/base/error_code.h`, `src/compat/dbi_compat.h`, `msg/en_US.utf8/cubrid.msg`, `msg/ko_KR.utf8/cubrid.msg`, 필요 시 `cubrid-cci/src/cci/base_error_code.h`, `unit_tests/oos/`.

---

## Description

OOS (Out-of-row Storage - heap 의 큰 가변 컬럼을 외부 페이지로 분리하는 저장 방식) 오류 처리는 지금 두 성격이 섞여 있다. 하나는 개발자가 `oos.log` 로 삽입/삭제/읽기 흐름을 추적하는 용도다. 다른 하나는 release 빌드에서 DB 동작을 중단시키거나 사용자에게 반환해야 하는 실제 엔진 오류다.

첫 번째 성격은 당분간 유지하는 편이 맞다. OOS 는 아직 `spacedb`/`diagdb` 로 물리 배치를 충분히 확인하기 어려워, largest-first demotion 이나 OOS page 재사용을 확인할 때 `oos.log` 가 실질적인 관찰 도구로 쓰인다. `oos_debug`/`oos_trace` 가 debug 빌드 전용으로 남아 있는 현재 구조는 이 용도와 맞는다.

문제는 두 번째 성격이다. OOS record chain 손상, inline OOS header 손상, HAS_OOS flag 와 OOS VFID 불일치 같은 경우는 단순 개발 로그가 아니라 저장소 무결성 문제다. 이런 경로가 `ER_GENERIC_ERROR` 나 `ER_FAILED` 로 반환되면 server error log 와 client error id 에 OOS 맥락이 남지 않는다. 반대로 `oos_error` 가 직접 `er_set` 을 대신하게 만들면, 이미 callee 가 설정한 `pgbuf_fix`, `file_create`, `spage_*` 오류를 덮어쓸 수 있고 message catalog/locale 규칙도 우회한다.

따라서 `oos_error` 는 보조 파일 로그로만 둔다. 실제 오류 상태는 각 실패 지점에서 `er_set` 또는 기존 callee error propagation 으로 명시한다.

## Specification Changes

### 오류 출력 정책

| 분류 | release 동작 | debug 동작 | 기준 |
|------|--------------|------------|------|
| 개발 추적 로그 | `oos.log` 에 `oos_warn`/`oos_error` 만 남길 수 있다. 표준 오류 상태를 만들지는 않는다. | `oos_trace`/`oos_debug`/`oos_info` 도 `oos.log` 에 남긴다. | 배치 확인, 성능 조사, QA 재현 보조 |
| callee 가 이미 `er_set` 한 오류 | 기존 error id 를 보존하고 `ASSERT_ERROR_AND_SET` 또는 `er_errid()` 로 반환한다. | debug 에서는 `ASSERT_ERROR` 로 누락을 잡는다. | `file_create`, `file_alloc`, `pgbuf_fix`, allocation 계열 |
| OOS 무결성 오류 | OOS 전용 error id 로 `er_set` 한다. | 필요 시 `assert_release_error` 로 즉시 잡되, release 에서도 같은 error id 를 남긴다. | inline OOS slot, OOS chain header, length mismatch, missing OOS VFID |
| 임시 hard crash | release 경로에서 제거한다. | 필요한 경우 debug-only assertion 으로 둔다. | `vacuum_oos.cpp` 의 develop merge 전 임시 `abort()` |

### 에러 코드 정리 후보

| 후보 | 적용 대상 | 비고 |
|------|-----------|------|
| `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` | OOS demotion 후에도 record 가 `heap_Maxslotted_reclength` 를 넘는 사용자 입력 오류 | 이미 존재한다. user-visible 이므로 client-visible copy 를 점검한다. |
| `ER_HEAP_OOS_BAD_INLINE_HEADER` | heap record 안의 16B inline OOS stub (`OID` + `full_length`) 이 깨진 경우 | 이미 존재하지만 `heap_oos.cpp`/`heap_recdes_get_oos_oids` 쪽 generic 경로까지 확대 적용할지 검토한다. |
| `ER_HEAP_OOS_RECORD_CORRUPTED` | OOS page 의 chunk header, chain index, total length, final length 가 맞지 않는 경우 | 신규 후보. `oos_read_within_page`, `oos_read_across_pages`, `oos_delete_chain` 의 corruption 경로에 맞다. |
| `ER_HEAP_OOS_FILE_MISSING` | record 는 `OR_MVCC_FLAG_HAS_OOS` 를 갖지만 heap header 에 OOS VFID 가 없는 경우 | 신규 후보. vacuum/eager cleanup 에서 release hard crash 대신 남길 error id 로 적합하다. |

> **요지**: `oos_error` 를 똑똑하게 만드는 방향보다, `oos_error` 를 debug sink 로 한정하고 오류 지점에서 CUBRID error id 를 명시하는 방향이 안전하다. 그래야 callee error 를 덮어쓰지 않고 message catalog/locale/client 전달 규칙을 지킨다.

## Implementation

### 1. `oos_log.hpp` 역할을 명확히 고정한다

`oos_log.hpp` 는 파일 로그만 담당한다. `oos_error` 이름 때문에 표준 에러 설정 함수처럼 보이지만, 실제로는 `$CUBRID/log/oos.log` 에 문자열을 쓰는 helper 다.

권장 변경은 이름 변경이 아니라 contract 주석 정리다. 지금 호출부가 많으므로 merge 전 rename 은 비용 대비 이득이 작다. 대신 header 주석에 "이 함수는 `er_set` 하지 않는다. release-visible 오류는 호출부에서 별도 `er_set` 해야 한다" 는 규칙을 둔다.

### 2. `ER_GENERIC_ERROR` 경로를 OOS 전용 error id 로 분류한다

우선순위는 사용자/QA 가 보는 실패 경로다.

```
[read/expand 경로]
heap_record_replace_oos_oids()             heap_oos.cpp
  -> heap_oos_parse_vot()
  -> heap_oos_read_blobs()
       -> oos_read()
            -> oos_read_within_page()
            -> oos_read_across_pages()
★ inline OOS stub, VOT, OOS chunk chain 손상은 OOS 전용 error id 로 보고
```

`heap_oos.cpp` 의 VOT/inline stub 검증 실패는 `ER_HEAP_OOS_BAD_INLINE_HEADER` 또는 그 후속 error id 로 맞춘다. `oos_file.cpp` 의 chunk header/chain 검증 실패는 `ER_HEAP_OOS_RECORD_CORRUPTED` 같은 별도 id 가 더 읽기 좋다.

### 3. callee 오류는 덮어쓰지 않는다

`file_create`, `file_alloc`, `pgbuf_fix`, `recdes_allocate_data_area` 처럼 callee 가 이미 `er_set` 하는 경로는 새 OOS generic error 로 덮어쓰지 않는다. 호출부는 다음 형태로 통일한다.

```c
error_code = callee (...);
if (error_code != NO_ERROR)
  {
    ASSERT_ERROR_AND_SET (error_code);
    oos_error ("context ...");
    return error_code;
  }
```

`oos.log` 에는 context 를 보조로 남기되, server/client 의 대표 오류는 callee 가 설정한 error id 를 유지한다.

### 4. vacuum 임시 crash 경로를 release 정책으로 바꾼다

`vacuum_oos.cpp` 의 `abort()` 는 "develop merge 전 임시 CI crash" 라는 주석을 달고 있다. release 정책은 다음 중 하나로 확정해야 한다.

| 후보 | 동작 | 권장 |
|------|------|------|
| A | `ER_HEAP_OOS_FILE_MISSING` 을 `er_set`, `vacuum_er_log_error`, 해당 record 의 OOS cleanup skip | 권장. vacuum block 진행성과 release 진단을 동시에 만족한다. |
| B | fatal severity 로 block/transaction abort | 무결성 문제를 강하게 드러내지만 vacuum 재시도 spin 위험이 있다. |
| C | debug assert 후 release 에서는 조용히 skip | 진단성이 약해 CBRD-26792 목적과 맞지 않는다. |

### 5. error code 파일 동기화를 merge gate 로 둔다

OOS error id 가 client 로 반환될 수 있으면 다음 파일을 함께 갱신한다.

- `src/base/error_code.h`
- `src/compat/dbi_compat.h`
- `msg/en_US.utf8/cubrid.msg`
- `msg/ko_KR.utf8/cubrid.msg`
- `ER_LAST_ERROR`
- `cubrid-cci/src/cci/base_error_code.h` (`csql`/CCI 경로 노출 여부 확인 후 적용)

현재 검색 기준으로 `ER_HEAP_OOS_BAD_INLINE_HEADER`/`ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` 는 engine error catalog 에 있으나 `src/compat/dbi_compat.h` 와 CCI copy 에서 확인되지 않는다. 이 상태로는 user-visible OOS 오류가 client-facing catalog 동기화 규칙을 만족하지 못할 수 있다.

## Acceptance Criteria

- [ ] `oos_debug`/`oos_trace` 기반 `oos.log` 디버깅은 debug 빌드에서 유지된다.
- [ ] release 빌드에서 OOS 무결성 오류는 `ER_GENERIC_ERROR`/`ER_FAILED` 가 아니라 OOS 맥락을 가진 error id 또는 기존 callee error id 로 보고된다.
- [ ] `vacuum_oos.cpp` 의 develop merge 전 임시 `abort()`/hard crash 경로가 release 정책으로 대체된다.
- [ ] OOS error id 는 `error_code.h`, `dbi_compat.h`, 양쪽 `cubrid.msg`, `ER_LAST_ERROR`, 필요 시 CCI copy 까지 동기화된다.
- [ ] corruption/error-path unit test 가 debug/release 빌드에서 모두 같은 error id contract 를 확인한다.
- [ ] `rg -n "abort \\(|fprintf \\(stderr|ER_GENERIC_ERROR|return ER_FAILED" src/storage/oos_file.cpp src/storage/heap_oos.cpp src/query/vacuum_oos.cpp` 결과가 의도한 예외만 남는다.

## Definition of done

- [ ] 위 A/C 충족
- [ ] debug/release OOS unit test 통과
- [ ] OOS SQL smoke test 통과
- [ ] QA 가 release build server error log 만 보고 OOS 오류 종류를 구분할 수 있음

## Open Questions

- OOS corruption 계열을 `ER_ERROR_SEVERITY` 로 둘지, recovery/redo 중 발견되는 일부 경로를 `ER_FATAL_ERROR_SEVERITY` 로 올릴지 결정해야 한다.
- `ER_HEAP_OOS_BAD_INLINE_HEADER` 의 이름을 실제 메시지 범위에 맞게 유지할지, develop merge 전이라도 더 일반적인 이름으로 바꿀지 결정해야 한다.
- CCI copy 갱신 범위는 실제 client 반환 경로를 확인한 뒤 확정한다.
