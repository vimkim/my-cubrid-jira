# [OOS] `cubrid spacedb`에 OOS 전용 공간 집계 추가

## Issue Triage

**이슈 수행 목적**: `cubrid spacedb -p`에 OOS 전용 행을 추가하여, 데이터베이스 전체 OOS 파일 공간을 heap 본체와 분리해 확인할 수 있게 한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | `FILE_OOS`의 파일 수와 페이지 사용량은 누락되지 않지만 `SPACEDB_HEAP_FILE`에 합산된다. 따라서 `spacedb -p`의 `HEAP` 값만으로는 OOS 증가량과 heap 본체 증가량을 구분할 수 없다. |
| **TO-BE (목표 상태 / 기대 동작)** | `spacedb -p`가 `OOS` 행을 별도로 출력한다. 기존 `HEAP` 행에서는 OOS 수치를 제외하고, 화면에 `-`로 표시되는 전체 합계는 변경 전과 같게 유지한다. SA(standalone)/CS(client-server) 모드에서 같은 기준으로 집계한다. |
| **영향** | 운영 관측성 저하 - `FILE_OOS`는 독립 파일 타입인데 공간 집계에서는 `HEAP`으로 가려져, DBA가 운영 중인 데이터베이스의 OOS 파일 증가와 회수 추세를 별도 지표로 감시할 수 없다. |

**이슈 수행 방안**:

- `SPACEDB_FILE_TYPE`에 `SPACEDB_OOS_FILE`을 추가하고 `FILE_OOS`를 OOS 전용 집계 항목으로 집계한다.
- `SPACEDB_FILE_COUNT`에 의존하는 서버 직렬화/클라이언트 역직렬화, CLI 출력 라벨, QA 예상 결과 파일을 함께 갱신한다.
- `HEAP`에서 빠진 값이 `OOS`로 이동했을 뿐 각 열의 전체 합계(`SPACEDB_TOTAL_FILE`, 출력 라벨 `-`)는 보존되도록 검증한다.
- 기존 `SHOW HEAP OOS`, `diagdb` owner 출력, 온라인 `checkdb` 보호는 변경하지 않는다. 테이블별 OOS 보고도 범위에 포함하지 않는다.
- 서로 다른 CUBRID 버전의 client/server 사이에서 `SPACEDB_FILE_COUNT`가 다를 때의 호환 정책은 `TBD - 합의 미확인`이다.

---

## AI-Generated Context

> 아래는 AI가 코드와 맥락을 분석해 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현과 리뷰 단계에서 참고하면 된다.

### 변경 범위

| 영역 | 대상 | 영향 |
|------|------|------|
| 공간 집계 | `src/storage/storage_common.h`, `src/storage/file_manager.c` | 파일 분류와 `FILE_OOS` 매핑 변경 |
| C/S 응답 | `src/object/object_representation.c`, `src/communication/network_interface_sr.cpp`, `src/communication/network_interface_cl.c` | 집계 항목당 4개 정수의 응답 길이 변경 |
| 유틸리티 출력 | `src/executables/util_cs.c` | `OOS` 행 추가로 출력 행 수와 순서 변경 |
| 검증·문서 | utility QA answer, `cubrid-manual/{ko,en}/admin/admin_utils.rst` | SA/CS 값, 출력 예제, 합계 불변식 갱신 |

---

## Description

OOS(Out-of-row Storage, heap 레코드의 큰 가변 컬럼 값을 별도 파일에 저장하는 기능)는 테이블 heap마다 최대 하나의 `FILE_OOS` 파일을 사용한다. OOS 상태를 보는 기존 인터페이스는 목적이 서로 다르다.

| 인터페이스 | 범위 | 현재 제공 정보 |
|-----------|------|----------------|
| `SHOW HEAP OOS OF <class>` | 테이블별, 온라인 SQL | OOS 파일 존재 여부, VFID(파일 식별자), 할당된 사용자 페이지 수, 레코드/바이트 통계 |
| `diagdb -d2` | 데이터베이스 전체, 오프라인 | 파일별 페이지 수, class 이름, parent HFID(heap 파일 식별자) |
| `cubrid spacedb -p` | 데이터베이스 전체, SA/CS 유틸리티 | 파일 용도별 합계. OOS는 `HEAP`에 포함 |

관련 선행 작업은 이미 다음 범위를 완료했다.

| 이슈 | 완료된 범위 |
|------|-------------|
| CBRD-27028 | `FILE_OOS` 유틸리티 assertion 제거, OOS 공간을 `SPACEDB_HEAP_FILE`에 임시 합산 |
| CBRD-26972 | 릴리스 빌드에서 사용할 수 있는 `SHOW HEAP OOS` 진단 SQL 추가 |
| CBRD-27038 | OOS owner `HFID`/`class_oid`, `diagdb` 출력, class lock 기반 온라인 file-tracker 보호 추가 |

따라서 이 이슈는 owner metadata나 릴리스 관측 수단을 다시 만드는 작업이 아니다. CBRD-26786의 page reclaim A/C도 `SHOW HEAP OOS`의 `Has_oos_file`과 `Oos_num_user_pages`로 검증할 수 있어 이 이슈에 의존하지 않는다.

남은 제한은 데이터베이스 전체 집계의 구분 단위다. 현재 `SPACEDB_FILE_TYPE`은 `INDEX`, `HEAP`, `SYSTEM`, `TEMP`, `TOTAL`만 정의하고, `file_tracker_item_spacedb()`는 `FILE_OOS`를 명시적으로 `SPACEDB_HEAP_FILE`에 넣는다. 데이터베이스 총 공간 회계는 맞지만 OOS만 따로 추세화할 수 없다.

분석 기준 리비전은 CUBRID PR #7617 HEAD `bd0766dbb8e7e1d5f1f6f87824aa8819233991e9`이다. CBRD-27028, CBRD-26972, CBRD-27038은 모두 이 리비전에 포함되어 있다.

## Specification Changes

### 출력 행

`cubrid spacedb -p`의 파일 용도별 상세 출력을 다음처럼 변경한다.

| 구분 | 행 순서 |
|------|---------|
| AS-IS | `INDEX`, `HEAP`, `SYSTEM`, `TEMP`, `-` (전체 합계) |
| TO-BE | `INDEX`, `HEAP`, `OOS`, `SYSTEM`, `TEMP`, `-` (전체 합계) |

`OOS` 행은 기존 행과 같은 열을 사용한다.

```text
data_type  file_count  used_pages  file_table_pages  reserved_pages  total_pages
```

`--size-unit=M|G|T|H`에서는 기존 변환 규칙을 그대로 적용하여 페이지 대신 크기를 출력한다. OOS 파일이 없는 데이터베이스도 `OOS` 행을 출력하며 모든 값은 0이다.

### 집계 의미

| 행 | 포함할 파일 타입 |
|----|------------------|
| `INDEX` | `FILE_BTREE`, `FILE_BTREE_OVERFLOW_KEY` |
| `HEAP` | `FILE_HEAP`, `FILE_HEAP_REUSE_SLOTS`, `FILE_MULTIPAGE_OBJECT_HEAP` |
| `OOS` | `FILE_OOS` |
| `SYSTEM` | 위 분류와 temporary file에 속하지 않는 system file |
| `TEMP` | 기존 temporary file cache 통계 |
| `-` (내부 집계 항목: `SPACEDB_TOTAL_FILE`) | `INDEX + HEAP + OOS + SYSTEM + TEMP` |

`nfile`, `npage_user`, `npage_ftab`, `npage_reserved` 각각에 동일한 분류를 적용한다. 변경 전 `HEAP`에 포함되던 OOS 값만 새 행으로 이동하므로 각 열의 전체 합계(`SPACEDB_TOTAL_FILE`, 출력 라벨 `-`)는 변하지 않는다.

### 실행 모드와 기존 인터페이스

- `spacedb -S -p`와 `spacedb -C -p`는 쓰기 작업이 없는 같은 DB에 대해 같은 집계값을 반환한다.
- `SHOW HEAP OOS` 결과 schema와 `diagdb -d2` descriptor 출력은 변경하지 않는다.
- 테이블 이름이나 HFID별 행은 추가하지 않는다. 테이블별 진단은 `SHOW HEAP OOS`를 사용한다.

### 호환성

`SPACEDB_FILE_COUNT`는 C/S 응답의 집계 항목 개수로 직접 사용되지만 payload 안에는 별도 버전이나 개수가 없다. 구 client와 신 server 또는 신 client와 구 server 조합을 지원할지, 지원한다면 응답 버전을 어떻게 구분할지는 `TBD - 합의 미확인`이다.

## Implementation

### 호출 흐름

```text
cubrid spacedb -p
  -> netcl_spacedb()                         network_interface_cl.c
       -> NET_SERVER_SPACEDB
            -> netsr_spacedb()               network_interface_sr.cpp
                 -> file_spacedb()           file_manager.c
                      -> file_tracker_item_spacedb()
                           FILE_OOS -> SPACEDB_OOS_FILE
                 -> or_pack_spacedb()        object_representation.c
       -> or_unpack_spacedb()                object_representation.c
  -> file_type_strings[] 출력                util_cs.c
```

### 변경 지점

1. `storage_common.h`의 `SPACEDB_FILE_TYPE`에 `SPACEDB_OOS_FILE`을 `SPACEDB_HEAP_FILE` 다음에 추가한다. `SPACEDB_TOTAL_FILE`과 `SPACEDB_FILE_COUNT`는 새 배열 크기를 반영한다.
2. `file_tracker_item_spacedb()`의 `FILE_OOS` case를 `SPACEDB_OOS_FILE`로 변경한다. `file_spacedb()`의 기존 합계 loop는 `SPACEDB_TOTAL_FILE` 앞의 집계 항목을 모두 더하므로 새 OOS 집계 항목도 합계에 포함한다.
3. `or_packed_spacedb_size()`, `or_pack_spacedb()`, `or_unpack_spacedb()`는 모두 `SPACEDB_FILE_COUNT`를 사용한다. 양쪽 binary가 같은 count를 사용할 때 새 집계 항목의 4개 정수가 자동으로 왕복되는지 검증한다.
4. `util_cs.c`의 `file_type_strings[]`에 `OOS`를 enum 순서대로 추가한다. 기존 format string과 size-unit 변환은 재사용한다.
5. Utility QA 예상 결과와 CUBRID manual의 `spacedb -p` 출력 예제를 새 행에 맞춘다.

## Acceptance Criteria

- [ ] `cubrid spacedb -p --size-unit=page`가 `INDEX`, `HEAP`, `OOS`, `SYSTEM`, `TEMP`, `-` (전체 합계) 행을 출력한다.
- [ ] OOS 파일이 없는 데이터베이스에서 `OOS` 행의 `file_count`, `used_pages`, `file_table_pages`, `reserved_pages`, `total_pages`가 모두 0이다.
- [ ] OOS 저장을 실제로 발생시키는 크기의 속성 값을 삽입한 뒤 출력된 `OOS` 행의 `file_count` 열은 1 이상이고 `used_pages` 열은 0보다 크며, 해당 값은 더 이상 `HEAP`에 포함되지 않는다.
- [ ] 동일한 DB 이미지에 대해 기존 버전에서 얻은 `HEAP` 예상값은 변경 버전의 `HEAP + OOS`와 같고, 변경 버전의 각 열에서 `-` 합계 행은 다섯 세부 행의 합과 같다.
- [ ] 쓰기 작업이 없는 같은 DB에서 `spacedb -C -p` 결과를 수집한 뒤 서버를 종료하고 `spacedb -S -p` 결과를 수집했을 때 두 결과의 집계값이 같다.
- [ ] `PAGE`, `M`, `G`, `T`, `H` size unit에서 `OOS` 행이 기존 format과 같은 방식으로 출력된다.
- [ ] `or_packed_spacedb_size()`, `or_pack_spacedb()`, `or_unpack_spacedb()`의 동일 버전 간 직렬화/역직렬화 왕복이 새 집계 항목을 보존한다.
- [ ] 새 DB에 OOS 테이블 하나만 만든 뒤 insert -> delete/reclaim -> reinsert 작업을 수행했을 때 `OOS` 행의 `used_pages` 증감량과 `SHOW HEAP OOS OF <class>`의 `Oos_num_user_pages` 증감량이 서로 일치한다.
- [ ] 기존 `SHOW HEAP OOS` schema와 `diagdb -d2` owner 출력이 바뀌지 않는다.

## Definition of done

- [ ] 위 Acceptance Criteria를 모두 충족한다.
- [ ] 관련 unit test와 utility QA가 통과한다.
- [ ] Utility QA 예상 결과를 갱신한다.
- [ ] CUBRID manual의 한국어·영어 `spacedb -p` 설명과 출력 예제를 갱신한다.
- [ ] cross-version C/S 호환 정책을 결정하고 필요한 검증을 반영한다.

## Reference Code

- `src/storage/storage_common.h:579-589` - `SPACEDB_FILE_TYPE`
- `src/storage/file_manager.c:12226-12275` - `FILE_OOS -> SPACEDB_HEAP_FILE` mapping
- `src/storage/file_manager.c:7927-7956` - category 초기화와 `TOTAL` 계산
- `src/object/object_representation.c:6117-6277` - packed size, pack, unpack
- `src/communication/network_interface_sr.cpp:10775-10830` - server-side array와 response 생성
- `src/communication/network_interface_cl.c:10895-10939` - client-side response unpack
- `src/executables/util_cs.c:944-957,1140-1168` - output label과 detailed file section
- `cubrid-manual/ko/admin/admin_utils.rst:817-829` - 한국어 `spacedb -p` 설명과 현재 출력
- `cubrid-manual/en/admin/admin_utils.rst:822-834` - 영어 `spacedb -p` 설명과 현재 출력
