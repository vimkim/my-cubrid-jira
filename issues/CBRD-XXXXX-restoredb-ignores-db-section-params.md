# [RESTOREDB] xboot_restart_from_backup이 db_name 없이 파라미터를 로드해 restoredb가 [@<db>] 섹션 설정을 무시한다

**한 줄 요약**: [CUBRID/cubrid PR #8721](https://github.com/CUBRID/cubrid/pull/8721)(CBRD-28142) 검증 프로브([리뷰 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-28142/pr8721-review.md))에서 `cubrid restoredb` 가 `cubrid.conf` 의 `[@<db>]` 섹션을 무시하고 `[common]` 만 읽는 현상이 확인되어, `xboot_restart_from_backup ()` 의 `sysprm_load_and_init (NULL, ...)` 호출이 의도된 동작인지 검토하고 DB별 설정 일관성 또는 명시적 동작 기준을 확립하는 이슈다.

## Issue Triage

**이슈 수행 목적**: `cubrid restoredb` 실행 시 `cubrid.conf` 의 `[@<db>]` 섹션 파라미터가 다른 DB 단위 유틸리티(`cub_server`, `createdb`, `backupdb -S`)와 일관되게 반영되거나, 의도적으로 제외되어야 하는 이유가 명확히 정의·검증된다.

**이슈 수행 이유**: PR #8721의 앞선 아카이브 누락 시나리오(`backupdb -C` 후 `restoredb`)를 debug 빌드로 검증하는 과정에서 확인했다. `cubrid.conf` 의 `[@pr8721p]` 에만 `vacuum_disable=yes` 를 두고 복원을 실행했을 때 `restoredb` 가 해당 설정을 적용하지 않아 vacuum이 활성 상태로 부팅되었고, 선행 아카이브가 빠진 백업 복원이 `ER_LOG_NOTIN_ARCHIVE` FATAL(종료 코드 254)로 실패했다. 동일한 설정을 `[common]` 에 넣자 복원은 정상 종료(종료 코드 0)되었다. 소스 확인 결과 `xboot_restart_from_backup ()` (`src/transaction/boot_sr.c:2874`)이 인자로 `db_name` 을 이미 받고 있음에도 `sysprm_load_and_init (NULL, NULL, SYSPRM_LOAD_ALL)` 을 호출하고 있었다.

**영향**: DB별로 `cubrid.conf` 의 `[@<db>]` 섹션에 설정한 파라미터가 서버(`cub_server`), `createdb`, `backupdb -S` 등에서는 적용되지만 `restoredb` 에서는 조용히 무시된다. 실제 관측된 사례에서는 `[@<db>]` 에만 `vacuum_disable=yes` 를 설정한 환경에서 선행 아카이브가 없는 백업을 `restoredb` 로 복원할 때 vacuum이 활성화되어 `vacuum_recover_lost_block_data ()` 가 누락된 아카이브의 페이지를 찾다가 FATAL(rc 254)로 중단되었다(이 FATAL 자체는 선행 아카이브가 삭제된 조건에서 발생했다). 그 외 버퍼 크기나 로그·압축 등 `[@<db>]` 에 지정된 다른 파라미터가 복원 중 어떤 영향을 받는지는 ANALYSIS에서 확인이 필요하다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

기준 소스 및 관측 빌드: `CUBRID/cubrid` PR #8721 head `5d6b8cc8fb9a547eba365f1ce217b5b4858b1dd6` (`CUBRID 11.5.0.3053-5d6b8cc`, 64bit debug build for Linux). 해당 동작은 PR #8721 변경과 무관한 기존 코드다.

### 1. 소스 코드 상의 원인 경로

- `src/executables/util_sa.c:1047-1136` (`restoredb ()`): 명령행에서 `database_name` 을 읽고(`:1059`), `<db>_restoredb.err` 로 `er_init ()` 을 호출한 뒤(`:1112-1113`), `boot_restart_from_backup (true, database_name, &restart_arg)` 를 호출한다(`:1136`).
- `src/communication/network_interface_cl.c:4529-4535` (`boot_restart_from_backup ()`): 전달받은 `db_name` 을 그대로 `xboot_restart_from_backup (NULL, print_restart, db_name, r_args)` 에 넘긴다.
- `src/transaction/boot_sr.c:2843, 2874, 2898` (`xboot_restart_from_backup ()`): 함수가 `const char *db_name` 을 인자로 받지만 `:2874` 에서 `sysprm_load_and_init (NULL, NULL, SYSPRM_LOAD_ALL)` 을 호출한다. 이후 `:2898` 에서 `boot_restart_server (..., db_name, ...)` 를 호출한다.
- `src/transaction/boot_sr.c:2027-2036` (`boot_restart_server ()`): 내부의 `sysprm_load_and_init (db_name, NULL, SYSPRM_LOAD_ALL)` 호출은 `#if defined(SERVER_MODE)` 로 감싸여 있어, `SA_MODE` 로 실행되는 `restoredb` 경로에서는 `db_name` 기준 파라미터가 다시 로드되지 않는다.
- `src/base/system_parameter.c:6570-6664, 7098-7131` (`sysprm_load_and_init_internal ()` / `prm_read_and_parse_ini_file ()`): `db_name == NULL` 이면 `[common]` (`:7114`), `SA_MODE` 의 `[standalone]` (`:7124`), `[service]` (`:7130`) 섹션만 읽고 `[@<db_name>]` 섹션(`:7115-7119`)은 건너뛴다.

### 2. 다른 SA 유틸리티와의 비교

- `createdb ()` (`src/executables/util_sa.c:476`): `sysprm_load_and_init (database_name, NULL, SYSPRM_LOAD_ALL)` 을 호출해 `[@<db>]` 를 읽는다.
- `db_restart ()` 를 타는 `SA_MODE` 유틸리티(예: `backupdb -S`, `src/executables/util_cs.c:288`): `boot_client_common ()` (`src/transaction/boot_cl.c:341`)에서 `sysprm_load_and_init_client (client_credential->get_db_name (), conf_file)` 을 호출해 `[@<db>]` 를 읽는다.
- `restoreslave ()` (`src/executables/util_sa.c:4940, 5026`): `boot_restart_from_backup ()` 호출 전에 `sysprm_load_and_init (NULL, NULL, SYSPRM_LOAD_ALL)` 을 호출해 `restoredb` 와 마찬가지로 `[@<db>]` 를 읽지 않는다.

### 3. ANALYSIS 확인 사항

1. **의도 여부 확인**: `boot_sr.c:2874` 에 `NULL` 이 전달된 이유(초기 커밋 `6522201dab` 이후 유지된 코드로 별도 주석 없음)를 확인한다. `boot_restart_server ()` 는 `db_name` 과 `databases.txt` 등록 항목을 필수로 요구하므로(`boot_sr.c:2038, 2065-2108`), 복원 시점에 DB 이름 컨텍스트 자체는 존재한다. 신규/다른 이름 복원이나 `databases.txt` 미등록 상태 등 의도된 예외가 있는지 확인이 필요하다.
2. **에러 로그 경로 부작용 확인**: `!CS_MODE` 에서 `sysprm_load_and_init_internal ()` 에 `db_name` 을 넘기면 `sysprm_set_er_log_file (base_db_name)` (`src/base/system_parameter.c:6619-6624, 6438-6475`)이 호출되어 `PRM_ID_ER_LOG_FILE` 미설정 시 `server/<db>_YYYYMMDD_HHMM.err` 로 설정된다. `restoredb ()` 가 앞서 `util_sa.c:1112-1113` 에서 연 `<db>_restoredb.err` 및 `[@<db>]` 의 `error_log` 설정과 충돌하지 않는지 확인이 필요하다.
3. **영향받는 다른 `[@<db>]` 파라미터 범위 및 섹션 우선순위**: `vacuum_disable` 외에 복원 경로가 참조하는 파라미터(예: `boot_sr.c:2253` 의 `enable_string_compression`, `data_buffer_size`, `log_buffer_size`, `dwb_*`, `er_log_*` 등)와 `[standalone]` 섹션의 덮어쓰기 순서(`system_parameter.c:7115-7126`)가 복원 동작에 미치는 영향을 확인한다.
4. **`restoreslave` 범위 포함 여부**: `src/executables/util_sa.c:4940` 의 `restoreslave` 에도 동일 기준을 적용할지 결정한다.

## Test Build

- **빌드**: `CUBRID 11.5.0 (11.5.0.3053-5d6b8cc) (64bit debug build for Linux)` (`CMAKE_BUILD_TYPE=Debug`, 커밋 `5d6b8cc8fb9a547eba365f1ce217b5b4858b1dd6`).

## Repro

1. `cubrid.conf` 에 `[common]` 이 아닌 `[@pr8721p]` 섹션에만 `vacuum_disable=yes` 를 설정한다(프로브에서는 `log_max_archives=1`, `force_remove_log_archives=yes`, `checkpoint_every_size=2M` 도 함께 `[@pr8721p]` 에 설정함).
2. `cubrid createdb --db-volume-size=64M --log-volume-size=20M pr8721p en_US.utf8` 후 `cubrid server start pr8721p` 로 기동하고, 테이블 생성 및 반복적인 insert/delete로 로그 아카이브(`pr8721p_lgar000`..`004`)를 생성한다.
3. 서버를 중지한 뒤 가장 오래된 아카이브 `pr8721p_lgar000` 을 삭제하고, 서버를 다시 기동해 `cubrid backupdb -C -l 0 -D <backup_dir> pr8721p` 로 레벨 0 온라인 백업을 수행한다(백업은 rc 0으로 완료되며 `lgar001`..`004` 포함).
4. **시도 1 (`vacuum_disable=yes` 를 `[@pr8721p]` 에만 유지)**: 빈 DB 디렉터리에서 `cubrid restoredb -B <backup_dir> pr8721p` 를 실행한다.
5. **시도 2 (`vacuum_disable=yes` 를 `[common]` 에도 추가)**: 동일한 `<backup_dir>` 로 빈 DB 디렉터리에서 `cubrid restoredb -B <backup_dir> pr8721p` 를 다시 실행한다.

## Expected Result

- `cubrid.conf` 의 `[@pr8721p]` 에 설정한 `vacuum_disable=yes` 를 `restoredb` 도 인식하거나, DB별 섹션을 지원하지 않는다면 그 제약이 명확한 사유·문서와 함께 관리된다.

## Actual Result

- **시도 1 (`[@pr8721p]` 만 설정)**: `restoredb` 가 `[@pr8721p]` 를 무시하고 vacuum이 활성화된 상태로 복원을 진행했다. `Log recovery is finished` 이후 `boot_restart_server ()` → `vacuum_boot ()` (`src/query/vacuum.c:1360`) → `vacuum_data_load_and_recover ()` → `vacuum_recover_lost_block_data ()` (`src/query/vacuum.c:6041`) → `logpb_fetch_page ()` → `logpb_fetch_from_archive ()` (`src/transaction/log_page_buffer.c:5810`) 경로에서 백업에 없는 `pr8721p_lgar000` (로그 페이지 1277)을 마운트하려다 실패해 `FATAL: Internal error: unable to find log page 1277 in log archives` / `LOG FATAL ERROR: log_fetch_from_archive` 를 남기고 종료 코드 `254` 로 종료했다.
- **시도 2 (`[common]` 에도 설정)**: 동일한 백업 볼륨에 대한 `cubrid restoredb -B <backup_dir> pr8721p` 가 종료 코드 `0` 으로 성공했고(`pr8721p_lgar001`..`004` 복원), 이어서 `cubrid server start pr8721p` 및 `select count(*) from t` 도 FATAL 없이 rc 0으로 완료되었다.

## Additional Information

- **출처**: [CUBRID/cubrid PR #8721](https://github.com/CUBRID/cubrid/pull/8721) 검증 프로브([리뷰 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-28142/pr8721-review.md)) 중 Addendum P2C에서 관측(PE-5).
- **중복 확인** (`cubrid-jira-dup candidate-find`, 2026-11-26, 인덱스 8,403건 완전 동기화): 중복 이슈 없음.
- **관련 이슈**:
  - [CBRD-28142](https://jira.cubrid.org/browse/CBRD-28142) (Develop): 본 동작 차이를 관측한 PR #8721 검증 프로브의 대상 이슈.

