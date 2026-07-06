# [OOS] [M2] [Regression] FILE_OOS 단순 assert 오류

## Issue Triage

**이슈 수행 목적**: OOS 파일이 포함된 DB 에서 `diagdb`, `spacedb`, `checkdb` 계열 진단 유틸리티가 `FILE_OOS` 를 만나도 assertion 없이 정상 종료되도록 한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | `FILE_OOS` 는 OOS 가 큰 가변 컬럼 값을 별도 파일에 저장할 때 생기는 정상 파일 타입이지만, file manager 의 일부 utility switch 는 해당 case 를 `assert (false)` 또는 `assert_release (false)` 로 남겨 둔 상태다. |
| **TO-BE (목표 상태 / 기대 동작)** | 읽기 전용 진단 경로는 OOS 파일을 출력, 순회, 집계 대상으로 처리하고, OOS 전용 소유자 메타데이터가 없는 부분은 추정하지 않는다. |
| **영향** | QA 실패 — OOS 회귀 테스트가 실제 데이터 검증 전에 진단 유틸리티 assertion 으로 중단될 수 있어, TDE/backup/diagdb/checkdb 계열 테스트 결과를 분리 판단하기 어렵다. |

**이슈 수행 방안**: `FILE_OOS` 단순 assert 를 제거하고, 현재 파일 포맷 안에서 가능한 최소 처리만 추가한다. Descriptor dump 는 `OOS file` 로 표시하고, file tracker 의 읽기 전용 순회는 OOS VFID 를 class lock 없이 반환하며, `spacedb` 는 새 출력 행을 만들지 않고 OOS 페이지를 기존 heap totals 에 포함한다. `SPACEDB_OOS_FILE` 신설과 OOS owner descriptor 저장은 output/protocol 변경이므로 후속 이슈로 분리한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/file_manager.c` 의 utility-facing `FILE_OOS` 처리만 해당한다. 디스크 포맷, OOS record layout, OOS read/write, `SPACEDB_FILE_COUNT`, client/server packing, message catalog 는 변경하지 않는다.

---

## Description

OOS (Out-of-row Overflow Storage — heap 의 큰 가변 컬럼 값을 OOS file 로 분리 저장하는 방식)는 table 마다 `FILE_OOS` 파일을 만들 수 있다. 이 파일은 정상적인 영구 파일이지만, 기존 file manager 유틸리티 코드는 heap, btree, overflow, system 파일 중심으로 작성돼 있었다.

문제는 파일 타입별 switch 에서 `FILE_OOS` case 가 "아직 구현되지 않은 경로"처럼 남아 있다는 점이다. Generic file dump 는 descriptor 를 출력하려다 멈추고, file tracker iteration 은 OOS 항목을 보호할 class OID 를 얻으려다 멈추며, `spacedb` 집계는 OOS 공간을 어느 카테고리에 넣을지 정하기 전에 `assert_release (false)` 를 실행한다.

OOS 파일에는 아직 owner class OID 가 들어 있지 않다. 따라서 이번 수정은 OOS 파일을 특정 class 로 귀속시키려 하지 않는다. 읽기 전용 utility 에서는 OOS VFID 자체를 순회 대상으로 인정하고, `spacedb` 는 출력 형식을 유지하기 위해 OOS 를 heap totals 에 합산한다.

## Test Build

- 발견 대상: `feat/oos` 계열 debug/assert-enabled build.
- 수정 검증: debug GCC preset, commit `6046d348a3d4c3c834b6cc87dd6edf8934378129`.
- OS / package label: TBD - 정확한 패키지 빌드 번호 미확인.

## Repro

```bash
db=oos_assert
cubrid deletedb "$db" || true
cubrid createdb "$db"

csql -u dba -S "$db" <<'SQL'
CREATE TABLE t (id INT PRIMARY KEY, v BIT VARYING);
INSERT INTO t VALUES (1, CAST(REPEAT('AA', 5000) AS BIT VARYING));
COMMIT;
SQL

cubrid diagdb -d 1 "$db"
cubrid diagdb -d 2 "$db"
cubrid spacedb --file "$db"
cubrid checkdb "$db"
```

## Expected Result

각 유틸리티가 `FILE_OOS` 를 정상 파일 타입으로 처리하고 종료한다.

## Actual Result

debug/assert-enabled build 에서는 OOS 파일을 만나는 유틸리티 경로가 다음 assertion 지점에서 중단될 수 있다.

- `file_header_dump_descriptor()` 의 `FILE_OOS` case: descriptor dump 중 `assert (false)`.
- `file_tracker_get_and_protect()` 의 desired type / protected item / class OID extraction switch: tracker iteration 중 `assert (false)`.
- `file_tracker_item_spacedb()` 의 `FILE_OOS` case: `spacedb` 집계 중 `assert_release (false)`.

## Additional Information

수정 방향은 다음과 같다.

```
FILE_OOS utility path
├─ descriptor dump
│  └─ "OOS file" 출력
├─ file tracker iteration
│  └─ OOS VFID 반환, class_oid 는 null 유지
└─ spacedb accounting
   └─ SPACEDB_HEAP_FILE totals 에 합산
```

검증 기록:

- `git diff --check` 통과.
- debug GCC preset 빌드 성공.
- OOS 행이 있는 DB 에서 `diagdb` file table/capacity 출력, `spacedb` file accounting, `checkdb` file tracker iteration 이 `FILE_OOS` assertion 없이 완료됨.
- targeted CTP `utility_19` 성공.
- `cbrd_26527`, `tbl_enc_14` 는 아직 실패하지만 실패 원인은 `FILE_OOS` assertion/fatal 이 아니라 별도 expected-output 가정 차이로 분류됨.

관련 이슈:

- 부모 epic: CBRD-26835

## Code References

- `src/storage/file_manager.c:1431` - `file_header_dump_descriptor()` 의 기존 `FILE_OOS` assert.
- `src/storage/file_manager.c:10903`, `src/storage/file_manager.c:10931`, `src/storage/file_manager.c:10975` - `file_tracker_get_and_protect()` 의 기존 `FILE_OOS` assert.
- `src/storage/file_manager.c:12236` - `file_tracker_item_spacedb()` 의 기존 `assert_release (false)`.
