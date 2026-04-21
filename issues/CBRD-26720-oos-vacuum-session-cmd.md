# [OOS] [M2] vacuum 검증용 csql 세션 명령 추가

## Description

### 배경

PR [#6986](https://github.com/CUBRID/cubrid/pull/6986)([CBRD-26668](http://jira.cubrid.org/browse/CBRD-26668))에서
vacuum 경로에 OOS 레코드 정리(`oos_delete`)를 연동하였으나, 개발자가
vacuum이 실제로 OOS 를 정리하는지를 **csql 에서 직접 확인할 수 있는 수단** 이 없다.

현재 OOS 상태를 관찰하려면 `oos_file.cpp` 내부 디버그 로그(`oos_trace`)나 unit test 에 의존해야 하고, vacuum 은 백그라운드 데몬 일정에 의해 비동기로 동작하므로 타이밍 재현도 어렵다.

| 현황 | 한계 |
|---|---|
| `oos_trace` debug log | 서버 로그를 열어 파싱해야 하며, 집계가 불편 |
| unit test (`test_oos_vacuum_server`) | CI 용도로만 동작, 실제 DB 에 접속해 확인 불가 |
| vacuum 데몬 | 주기적으로만 실행, 즉시 트리거 불가 |

### 목적

개발/디버깅 편의를 위해 아래 세 가지 csql 세션 명령을 추가한다.

| 명령 | 기능 |
|---|---|
| `;vacuum` | vacuum 즉시 실행 또는 master daemon 깨우기 |
| `;oos_stats <class>` | 해당 class 의 OOS 파일 물리/논리 크기 집계 출력 |

`;oos_stats` 는 vacuum 전/후 비교를 통해 "deleted but not yet vacuumed" OOS 레코드의 **누적 여부** 와 **정리 여부** 를 바로 확인할 수 있게 한다.

---

## Spec Change

### 신규 세션 명령

| 명령 | 동작 | 권한 |
|---|---|---|
| `;vacuum` | CS mode: `vacuum_Master_daemon->wakeup()` / SA mode: `xvacuum()` 직접 호출 | `--sysadm` + DBA group |
| `;oos_stats <class_name>` | 해당 class 의 OOS 파일 통계 출력 | 연결된 일반 유저 |

### `;oos_stats` 출력 필드

```
OOS statistics for class '<class_name>':
  OOS VFID            : (volid=N, fileid=N)
  Physical pages      : <num_user_pages>
  Page size           : <DB_PAGESIZE>
  Actual disk size    : <num_user_pages * DB_PAGESIZE>  bytes
  Live OOS records    : <live slot 수>
  Logical data size   : <sum of live record bodies>     bytes
  Uncleaned (slack)   : <actual - logical>              bytes
```

- **Live OOS records / Logical data size**: OOS 파일 전체 페이지를 순회하며 `spage_collect_statistics` 로 집계. `OOS_HDR_STATS.estimates` 는 bestspace 추정치(lazy sync)이므로 실시간 정확성을 위해 on-demand 로 재계산한다.
- **Uncleaned (slack)**: `actual - logical` = OOS 파일이 차지하는 디스크 중 실제 레코드 데이터가 아닌 부분. vacuum 이 slot 을 물리 삭제한 뒤에도 페이지 dealloc 이 아직 scope out 이므로 slack 은 0 으로 수렴하지 않지만, `DELETE + ;vacuum` 후 Live OOS records 감소 여부로 vacuum 동작을 검증할 수 있다.

### 신규 함수

| 함수 | 파일 | 설명 |
|---|---|---|
| `db_vacuum` | `src/compat/db_admin.c` | `cvacuum` 래퍼 (checkpoint 패턴 모사) |
| `db_oos_stats` | `src/compat/db_admin.c` | class_name → OID 해결 후 서버 호출 |
| `oos_get_stats_by_class_oid` | `src/communication/network_interface_cl.{c,h}` | client RPC 래퍼 |
| `soos_stats` | `src/communication/network_interface_sr.{cpp,h}` | server 핸들러 |
| `xoos_get_stats_by_class_oid` | `src/storage/oos_file.{cpp,hpp}` | server worker |
| `vacuum_wakeup_master_daemon` | `src/query/vacuum.{c,h}` | CS mode 에서 master daemon wake |

### 신규 네트워크 요청

`NET_SERVER_OOS_STATS` (`src/communication/network.h`).

| 방향 | 페이로드 |
|---|---|
| Request | `OID class_oid` (OR_OID_SIZE) |
| Reply | `int err` + `int has_oos_file` + `int vfid.volid` + `int vfid.fileid` + `int num_user_pages` + `int page_size` + `int num_recs` + `INT64 recs_sumlen` |

### 신규 구조체 (`dbi.h`)

```c
typedef struct db_oos_stats DB_OOS_STATS;
struct db_oos_stats
{
  int has_oos_file;      /* 0 if class has no OOS file */
  int oos_vfid_volid;
  int oos_vfid_fileid;
  int num_user_pages;
  int page_size;
  int num_recs;
  INT64 recs_sumlen;
};
```

서버측 대응 구조체 `OOS_STATS_INFO` (`oos_file.hpp`) 는 `VFID` 를 그대로 가진다.

---

## Implementation

### 동작 흐름 — `;oos_stats <class>`

```
csql.c (S_CMD_OOS_STATS)
  └─ db_oos_stats(class_name, &stats)                  [compat/db_admin.c]
       ├─ db_find_class(class_name)                    ← 클라이언트 사이드 이름 해결
       │    (dba.t 자동 자격화, 대소문자 정규화)
       ├─ ws_identifier(class_op) → class_oid
       └─ oos_get_stats_by_class_oid(class_oid, &stats) [communication/network_interface_cl.c]
            └─ NET_SERVER_OOS_STATS (OID 전송)
                 └─ soos_stats                          [communication/network_interface_sr.cpp]
                      └─ xoos_get_stats_by_class_oid    [storage/oos_file.cpp]
                           ├─ heap_get_class_info → HFID
                           ├─ heap_oos_find_vfid → OOS VFID
                           ├─ file_get_num_user_pages
                           └─ 전 페이지 순회:
                                file_numerable_find_nth → pgbuf_fix (CONDITIONAL READ)
                                → spage_collect_statistics → 집계
```

**설계 포인트**:

- **클라이언트 사이드 이름 해결**: 서버에서 `xlocator_find_class_oid(class_name, ...)` 를 쓰면 `dba.t` 와 같은 사용자 자격화/대소문자 정규화가 누락되어 초기 테스트에서 "Unknown class 't'" 오류가 발생했다. `db_find_class` 는 CUBRID 클라이언트 측 이름 해석 체인을 그대로 재사용하므로 이 문제를 깔끔히 회피한다.
- **on-demand 페이지 스캔**: `OOS_HDR_STATS.estimates.num_recs` 는 `oos_stats_sync_bestspace` 에서 bestspace 계산 목적으로만 갱신되므로 `oos_insert/oos_delete` 후에 실시간 값과 어긋난다. 정확한 관측을 위해 매 호출마다 전 페이지를 `CONDITIONAL_LATCH` 로 스캔한다. busy page 는 skip 하여 약간의 undercount 를 허용한다 (dev/debug 용도이므로 허용 가능).

### 동작 흐름 — `;vacuum`

```
csql.c (S_CMD_VACUUM, sysadm + DBA only)
  └─ db_vacuum()                                   [compat/db_admin.c]
       └─ cvacuum()                                [communication/network_interface_cl.c]
            ├─ CS_MODE : NET_SERVER_VACUUM
            │               └─ svacuum            [communication/network_interface_sr.cpp]
            │                    └─ vacuum_wakeup_master_daemon()   ← 신규
            └─ SA_MODE : xvacuum(thread_p)        ← standalone 에서 즉시 실행
```

**CS mode 에서 `xvacuum` 을 우회하는 이유**: 기존 `xvacuum` 은 `SERVER_MODE` 에서
`ER_VACUUM_CS_NOT_AVAILABLE` 을 즉시 반환하도록 되어 있다 (`vacuum.c:977`).
CS mode 에서는 vacuum master daemon 을 깨우는 것이 정규 경로이므로,
`svacuum` 핸들러에서 `vacuum_wakeup_master_daemon()` 을 직접 호출한다.
SA mode 에는 데몬이 없으므로 `xvacuum` 의 standalone 경로가 그대로 동작한다.

### 세션 명령 등록

| 파일 | 변경 |
|---|---|
| `src/executables/csql.h` | `S_CMD_VACUUM`, `S_CMD_OOS_STATS` enum 추가 |
| `src/executables/csql_session.c` | `csql_Session_cmd_table` 에 `"vacuum"`, `"oos_stats"` 항목 추가 (CMD_CHECK_CONNECT) |
| `src/executables/csql.c` | `case S_CMD_VACUUM:`, `case S_CMD_OOS_STATS:` 구현 (`;checkpoint` 패턴 모사) |

---

## Acceptance Criteria

- [ ] `;vacuum` 이 sysadm + DBA group 조건을 만족하는 csql 세션에서 `NO_ERROR` 로 반환한다
- [ ] `;vacuum` 이 일반 유저(미-sysadm) 세션에서 권한 오류 메시지를 출력한다
- [ ] `;oos_stats <class>` 가 OOS 파일이 없는 클래스에 대해 `Class '<name>' has no OOS file.` 을 출력한다
- [ ] `;oos_stats <class>` 가 OOS 파일이 있는 클래스에 대해 `Physical pages`, `Actual disk size`, `Live OOS records`, `Logical data size`, `Uncleaned` 필드를 모두 출력한다
- [ ] CS/SA 모드 모두에서 위 두 명령이 동작한다
- [ ] 존재하지 않는 클래스에 대해서는 `ER_LC_UNKNOWN_CLASSNAME` 오류를 반환한다
- [ ] 기존 OOS unit test 18/18 통과 (regression 없음)

---

## Remarks

### PR

draft PR 로 링크 예정: `[CBRD-26720] Add csql session commands for OOS vacuum verification`

### 범위 외 (follow-up)

| 항목 | 비고 |
|---|---|
| `;oos_stats` 전역 집계 (클래스 arg 없이 모든 OOS 파일) | 현재는 per-class 만. 후속에서 `_db_class` 스캔으로 확장 가능 |
| 누적 insert/delete 카운터 | 현재는 snapshot 만. 누적값이 필요하면 `perf_monitor` 통합 검토 |
| Reachable from heap vs. in OOS file 대조 | heap 을 스캔해 HAS_OOS 레코드의 OID 수를 세어 "referenced" 수와 `num_recs` 를 대조하는 기능. 정확한 누수 감지에 유용하지만 복잡도가 커 후속 이슈로 분리 |
| OOS 페이지 dealloc | PR #6986 Remarks 에 명시된 scope out. dealloc 구현 전까지 `Uncleaned (slack)` 은 0 으로 수렴하지 않음 |

### 참고 코드

- `src/executables/csql.c:1220` — `S_CMD_CHECKPOINT` 가 패턴 모델
- `src/query/vacuum.c:974` — `xvacuum` CS/SA 분기
- `src/storage/oos_file.cpp:628` — `oos_stats_sync_bestspace` (페이지 스캔 패턴 참고)
- `src/storage/oos_file.hpp:49` — `OOS_HDR_STATS` (bestspace 힌트의 lazy 특성)
