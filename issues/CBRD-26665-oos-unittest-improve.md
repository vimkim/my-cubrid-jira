# [OOS] OOS unit test 추가 및 CI 자동 실행 환경 구성

## Description

### 배경

OOS 기능에 대한 기존 unit test는 low-level storage API(`oos_file_create`, `oos_write`, `oos_read` 등)만 검증하고 있었다.
SQL 파이프라인(parser -> optimizer -> executor)을 통한 end-to-end 검증이 부재하여, 실제 사용 시나리오에서의 동작을 보장하기 어려웠다.

또한 unit test가 CI에서 자동 실행되지 않아 다음과 같은 문제가 있었다:

1. **CI에서 unit test 미실행**: `build.sh` 에 ctest 실행 단계가 없어 빌드만 검증하고 테스트는 수동으로 확인해야 했음
2. **UNIT_TESTS 기본 비활성화**: `CMakeLists.txt` 에서 `option(UNIT_TESTS ... OFF)` 로 설정되어 명시적으로 `-DUNIT_TESTS=ON` 을 전달해야만 테스트가 빌드됨
3. **with_unit_tests() 호출 순서 버그**: `with_unit_tests()` 함수가 `option()` 선언보다 앞에 호출되어, 기본값 `ON` 으로 변경해도 감지되지 않는 문제가 있었음
4. **테스트 DB 미생성**: OOS unit test는 SA_MODE에서 `db_restart()` 로 DB를 열기 때문에 사전에 `cubrid createdb` 로 DB가 생성되어 있어야 하나, 이를 자동화하는 단계가 없었음

### 목적

- SQL 레벨 integration test를 추가하여 OOS의 CRUD, DDL, DELETE, UPDATE, 트랜잭션, 경계값 시나리오를 검증한다.
- CI에서 unit test가 자동으로 빌드 및 실행되도록 `build.sh` 와 `CMakeLists.txt` 를 수정한다.
- 테스트 전용 DB(`unittestdb`)를 자동 생성하여 테스트 환경 설정을 자동화한다.

---

## Implementation

### 1. SQL 레벨 integration test 추가 (`unit_tests/oos/sql/`)

기존 low-level API 테스트와 별도로, SA_MODE에서 `db_compile_and_execute_local()` 을 통해 실제 SQL을 실행하는 테스트를 추가했다.

| 파일 | 검증 내용 |
|------|-----------|
| `test_oos_sql_crud.cpp` | INSERT/SELECT, 소형 레코드(OOS 미발생), 다중 OOS 컬럼, multi-chunk |
| `test_oos_sql_ddl.cpp` | DROP/CREATE 반복, 스키마 변경 후 재생성 |
| `test_oos_sql_delete.cpp` | single-chunk/multi-chunk DELETE, 선택적 DELETE |
| `test_oos_sql_update_delete.cpp` | UPDATE(OOS 값 교체), DELETE 후 재삽입 |
| `test_oos_sql_boundary.cpp` | OOS 임계값 경계 조건 |
| `test_oos_sql_txn.cpp` | 커밋/롤백 시나리오 |
| `test_oos_sql_common.hpp` | 공통 헬퍼(exec_sql, fetch_single_int, SqlServerEnv) |

### 2. `CMakeLists.txt` 수정

- `option(UNIT_TESTS "Unit tests" OFF)` → `ON` 으로 변경하여 기본 빌드 시 unit test 포함
- `with_unit_tests(AT_LEAST_ONE_UNIT_TEST)` 호출을 `option()` 선언 이후로 이동하여, 기본값이 정상적으로 감지되도록 수정

### 3. `build.sh` — `build_test()` 함수 추가

`build_build()` 완료 후 `UNIT_TESTS=ON` 이 감지되면 자동으로 `build_test()` 를 호출한다.

```
build_build()
  → build_configure && build_compile && build_install
  → UNIT_TESTS:BOOL=ON 감지 시 build_test() 호출

build_test()
  → $CUBRID, $CUBRID_DATABASES, $PATH 환경 설정
  → cubrid createdb unittestdb (미존재 시)
  → ctest --test-dir $build_dir --output-on-failure
```

### 4. 테스트 DB명 변경: `testdb` → `unittestdb`

개발자의 기존 `testdb` 와 충돌을 방지하기 위해 unit test 전용 DB명을 `unittestdb` 로 변경했다.

- `unit_tests/oos/test_oos_common.hpp`
- `unit_tests/oos/sql/test_oos_sql_common.hpp`

---

## Acceptance Criteria

- [ ] `./build.sh -m debug clean build` 실행 시 unit test가 자동으로 빌드 및 실행됨
- [ ] 9개 OOS unit test 전체 통과 (기존 3개 + SQL 레벨 6개)
- [ ] `unittestdb` 가 자동 생성되어 별도 DB 설정 불필요
- [ ] 기존 `testdb` 를 사용하는 개발 환경에 영향 없음

---

## Remarks

- 기존 monolithic `test_oos_sql.cpp` 파일은 `sql/` 디렉토리의 분리된 테스트와 중복이므로 별도 정리 필요
- parent issue: [CBRD-26583](http://jira.cubrid.org/browse/CBRD-26583)
