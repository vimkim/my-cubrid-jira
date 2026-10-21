# [PGBUF] [Survey] 복구·종료 중 temp 볼륨 판정의 안전성을 확인한다

## Issue Triage

**이슈 수행 목적**: 복구·종료 중 `pgbuf_is_temporary_volume`이 false를 반환하는 구간에서 임시 용도 페이지의 실제 접근과 보호 조건을 확인하고, 현행 유지 또는 후속 조치의 근거를 확정한다.

**이슈 수행 이유**: 볼륨 목적에 따른 판정은 로그 복구 상태에 의해 차단되지만 페이지 LSA 마커에 따른 판정은 유지된다. 이 차이는 LSA 초기화, TDE 키 선택, DWB 사용 등에 연결된다. 기존 설명에는 임시 볼륨의 마운트 여부와 로그 상태 초기값에 대한 오류가 있어, 그 설명만으로 현행 동작의 안전성을 판단하기 어렵다.

**영향**: 페이지 버퍼와 복구 경로를 변경하는 개발자가 유지해야 할 조건이 불명확하다. 영구 형식의 임시 용도 볼륨은 부팅 중 헤더와 할당 맵 접근 경로가 확인된다. 암호화된 임시 데이터 페이지가 판정 구간을 넘어 기록·재독출되어 키 선택 불일치나 사용자 장애를 일으킨 실행 증거는 아직 없다. 발생 빈도와 영향 버전도 미확인이다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다. 조사 결과는 기능 결함 없음, 근거·주석 보완, 또는 별도 동작 수정의 필요성으로 정리할 수 있다. 판정 가드 변경이나 코드 변경을 완료 조건으로 미리 정하지 않는다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 소스에서 확인한 경로와 실행 검증이 필요한 사항을 구분한다.

## Description

### 무엇이 문제인가

페이지 버퍼는 디스크 페이지를 메모리 프레임에 보관하고 접근, 교체, 기록을 관리한다. `fix/unfix`는 페이지 사용과 상주 상태를 관리하며, 페이지 latch는 메모리 안의 접근을 조정한다. BCB는 프레임의 사용 수, latch, dirty 상태 등을 보관하는 제어 블록이고, VPID는 볼륨 번호와 페이지 번호의 쌍이다. 이 조사에서는 임시 페이지를 취급하는 두 판정 기준을 구분해야 한다.

- `pgbuf_is_temporary_volume(volid)`은 `LOG_ISRESTARTED()`가 거짓이면 볼륨 목적을 조회하지 않고 false를 반환한다. 참일 때만 `xdisk_get_purpose`로 `DB_TEMPORARY_DATA_PURPOSE`인지 확인한다. [판정 함수](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L5495-L5510)
- `pgbuf_is_lsa_temporary(pgptr)`는 페이지의 `PGBUF_TEMP_LSA` 마커와 위 볼륨 판정의 OR이다. 따라서 볼륨 판정이 false여도 마커가 있는 페이지의 임시 판정은 유지된다. 마커 설정 함수는 페이지 헤더와 끝의 watermark에 같은 값을 쓴다. [두 판정의 결합](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L5472-L5493), [마커 정의](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.h#L264-L267), [마커 기록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L17284-L17297)

문제는 false 반환 자체가 아니라, 그 구간에 접근하는 페이지와 각 호출부의 보호 조건을 연결한 안전성 근거가 부족하다는 점이다. 기존의 “temp 전용 처리를 전혀 받지 못한다”는 설명은 마커를 사용하는 경로까지 포함하므로 부정확하다. 반대로 마커가 유지된다는 사실만으로 볼륨 판정만 사용하는 TDE·DWB 경로까지 안전하다고 결론내릴 수도 없다.

### 왜 문제인가

TDE는 페이지 암호화 기능이며 `is_temp` 값으로 서로 다른 데이터 키를 선택한다. DWB는 페이지를 원래 위치에 쓰기 전에 사본을 보관하는 이중 쓰기 버퍼이다. 동일 페이지의 암호화·복호화 때 `is_temp`가 달라질 수 있다면 키 선택 일관성을 확인해야 한다. DWB 사용, 체크포인트 후보, LRU 교체 정책도 볼륨 판정에 의존하므로, 접근 대상과 초기화 순서를 확인하지 않은 가드 변경은 여러 동작을 동시에 바꾼다. 현재 자료는 이 연결을 보여 주지만 실제 데이터 손상이나 추가 쓰기량을 입증하지 않는다.

특히 “복구가 끝난 뒤 임시 볼륨을 삭제하므로 복구 중에도 마운트되어 있다”는 기존 추론은 성립하지 않는다. 자동 임시 볼륨과 영구 형식의 임시 용도 볼륨을 구분하지 않으면 도달하지 않는 경로를 결함으로 판단하거나, 실제로 접근하는 메타데이터를 놓칠 수 있다.

### 왜 해결해야 하는가

현행 가드의 전제와 예외를 확정해야 페이지 버퍼 초기화, 복구, flush 경로를 변경할 때 필요한 보호를 유지할 수 있다. 함수 주석의 TODO만으로는 그 근거를 알 수 없고, 볼륨 판정을 일찍 허용하는 우회도 disk 캐시 준비 전 조회를 유발할 수 있다. 따라서 먼저 도달성과 보호 조건을 조사할 필요가 있다. 조사 결과가 현행 동작 유지여도, 검증한 범위와 남은 한계가 있으면 독립적인 완료 결과가 된다. 현재 근거만으로 우선순위나 긴급도를 높이지 않는다.

## Evidence

### 분석 기준과 이력

현재 동작의 기준은 CUBRID `f6cac312310f39f46711693da157a08f0e725693`이다. 이 기준으로 소스를 확인했으며 엔진 실행, 빌드, 장애 재현은 수행하지 않았다. 특정 릴리스의 영향이나 원격 최신 소스까지 확인했다는 뜻은 아니다.

기존 이슈와 로컬 보고서는 `e6ed61e87` 분석을 바탕으로 두 판정 축과 영향 후보를 제시했다. [기존 기술 문서](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/pgbuf/e6ed61e_claude/06-misc-observability.md#L460-L536)는 조사 배경이며 현재 동작의 증명은 아래 고정 소스로 판단한다. 2026-10-21 조회 스냅샷에서 이슈는 Open인 Sub-task이며 댓글은 없다. 과거 [트리아지 자료](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/CBRD-27193/triage-presentation-2026-10-19.html#L64-L66)도 동작 변경 전에 도달성과 암호화 영향을 조사하는 미승인 제안으로 기록한다.

### false 반환 구간과 초기화 전제

`LOG_ISRESTARTED()`는 `log_Gl.rcv_phase == LOG_RESTARTED`이다. `LOG_RESTARTED`가 enum의 첫 값이라는 사실과 달리, 실제 `log_global` 생성자는 `rcv_phase`를 `LOG_RECOVERY_ANALYSIS_PHASE`로 명시적으로 초기화한다. 따라서 프로세스 초기 상태를 0으로 간주해 판정이 참이라고 설명하면 안 된다. [매크로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_impl.h#L190-L194), [생성자](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_global.c#L49-L64)

| 구간 | 확인한 현재 순서와 경계 |
|---|---|
| 재기동 준비 | `boot_restart_server`는 `logtb_define_trantable`로 페이지 버퍼를 먼저 준비하고, 볼륨 마운트와 `disk_manager_init`을 거쳐 `log_initialize`를 호출한다. 페이지 버퍼 초기화를 복구 함수 진입 뒤의 일로만 설명할 수 없다. [초기 준비](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/boot_sr.c#L2263-L2275), [페이지 버퍼 초기화](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_tran_table.c#L483-L504), [disk 초기화](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/boot_sr.c#L2362-L2376), [복구 진입](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/boot_sr.c#L2423-L2427) |
| 로그 초기화·복구 | 기존 boot 관리자 재사용 경로에서 `log_final`을 호출하고 분석 상태를 설정한다. crash recovery를 수행하는 분기와 수행하지 않는 분기가 모두 `LOG_RESTARTED` 설정에 합류한다. 그 설정 전까지 볼륨 판정은 false이다. [재사용·상태 설정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_manager.c#L1130-L1151), [복구 분기와 종료 상태](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_manager.c#L1411-L1473) |
| 정상 운영 | `LOG_RESTARTED`인 동안 볼륨 목적을 조회한다. 이 상태도 모든 진입 경로에서 disk 캐시와 volid가 유효하다는 계약이 필요하다. |
| 종료·정리 | `log_final`은 먼저 분석 상태로 되돌린다. 이후 도달하는 `pgbuf_flush_all(NULL_VOLID)`도 false 판정 구간이다. 함수는 초기화 상태에 따라 일찍 반환할 수 있으므로 모든 호출에서 flush가 실행되는 것은 아니다. [상태 전환과 조기 반환](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_manager.c#L1792-L1810), [flush와 해제](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_manager.c#L1864-L1899) |

`xdisk_get_purpose`는 disk 캐시가 없으면 첫 데이터 볼륨만 허용하는 assert와 영구 목적 반환을 사용한다. 캐시가 있어도 volid 유효성 검사가 있다. 따라서 단순히 캐시 포인터가 존재한다는 조건으로 가드를 대체할 수 있는지는 별도 분석이 필요하다. 이 코드로 초기화 전 조회 제약은 확인되지만, 과거 TODO 작성자의 의도까지 확정할 수는 없다. [조회 전제](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/disk_manager.c#L5631-L5658)

### 볼륨 종류·용도와 실제 접근

`DB_VOLTYPE`과 `DB_VOLPURPOSE`는 별개의 열거형이다. `addvoldb`는 `-p temp`를 임시 용도로 해석하며 voltype을 지정하지 않으면 영구 형식을 사용한다. [열거형](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/compat/dbtype_def.h#L197-L209), [용도·종류 해석](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/executables/util_cs.c#L463-L521)

| 조합 | 소스에서 확인한 도달성·수명 | 남은 질문 |
|---|---|---|
| 임시 voltype + 임시 용도 | 부팅의 `boot_find_rest_volumes`는 임시 voltype 볼륨을 마운트하지 않는다. 재기동 후 삭제 시점만으로 복구 중 마운트 상태를 추론할 수 없다. 정상 종료는 임시 볼륨 제거 후 `log_final`을 호출한다. [부팅 마운트 범위](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/boot_sr.c#L1039-L1049), [종료 제거](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/boot_sr.c#L3084-L3099), [종료 flush 진입](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/boot_sr.c#L3135-L3141) | 복구 도중 새로 생성되거나 오류 정리 경로에서 남는 임시 볼륨·페이지가 있는가. |
| 영구 voltype + 임시 용도 | 영구 볼륨 마운트 대상이며 부팅 중 메타데이터 접근이 존재한다. `boot_mount → xdisk_get_fullname → disk_get_volheader → pgbuf_fix`로 헤더를 읽고, `disk_volume_boot`는 임시 목적의 할당 맵을 재초기화한다. [마운트 호출](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/boot_sr.c#L1270-L1285), [헤더 조회](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/disk_manager.c#L5844-L5866), [fix](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/disk_manager.c#L3230-L3245), [맵 초기화](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/disk_manager.c#L2452-L2484) | 확인된 메타데이터와 암호화된 임시 데이터 페이지의 접근을 구분해야 한다. 후자의 복구·종료 중 접근은 아직 입증하지 않았다. |

할당 맵 초기화의 `NEW_PAGE` 경로는 볼륨 판정에만 의존하지 않는다. `disk_stab_init`은 헤더의 실제 purpose를 보고 `pgbuf_set_lsa_as_temporary`를 호출하며, `!LOG_ISRESTARTED()`이면 dirty 설정 후 명시적으로 flush한다. 이는 false 구간에도 임시 마커 설정과 페이지 기록 경로가 존재한다는 근거이다. 암호화된 임시 데이터 페이지의 접근이나 장애 증거로 확대할 수는 없다. [명시적 마커 설정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/disk_manager.c#L4942-L4959), [초기화·flush](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/disk_manager.c#L4990-L5006)

### 영향 후보와 보호 조건

아래는 false 판정일 때 달라지는 분기이다. 각 분기에 도달하는 페이지·설정을 확인해야 하며, 아직 모든 항목을 정합성 결함 또는 성능 영향만으로 단정하지 않는다.

| 지점 | 현재 소스에서 확인한 차이와 분석 필요 사항 |
|---|---|
| 읽은 페이지의 temp LSA 보정 | 볼륨 판정이 false이면 보정을 생략한다. 기존 마커가 있으면 유지된다. 읽은 모든 페이지에 마커가 있다고 가정할 수 없다. [읽기 후 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8526-L8534) |
| `NEW_PAGE` LSA 초기화 | false이면 일반 LSA 초기화를 선택한다. 다만 disk 할당 맵처럼 호출자가 명시적으로 마커를 설정하는 경로가 있으므로 최종 마커 누락과 동일하지 않다. [초기화 분기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8564-L8572) |
| `pgbuf_set_lsa` | 기존 temp 마커는 볼륨 판정과 독립적으로 변경을 거부한다. 마커가 없으면 볼륨 기반 보정도 생략될 수 있다. true 분기도 비활성 트랜잭션에서는 후속 LSA 설정으로 진행하므로 항상 마커로 고정된다는 설명은 부정확하다. [LSA 설정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L4937-L4960) |
| LRU 승격·이동 | SERVER_MODE의 zone별 조건에 영향을 준다. vacuum worker 조건과 단락 평가가 있으므로 모든 unfix마다 목적 조회를 한다고 일반화할 수 없다. 비용·교체 결과는 측정이 필요하다. [매크로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L281-L295), [zone별 분기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L6710-L6791) |
| DWB 사용 | `dwb_is_created() && !is_temp`이므로 false 판정만으로 DWB 경유가 보장되지는 않는다. DWB 준비 여부와 실제 flush 대상을 함께 확인한다. [사용 결정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10692-L10757) |
| 미로깅 flush 진단 | `oldest_unflush_lsa`가 없으면 non-temp 판정에서 진단을 남긴다. WAL 선행 기록 여부는 별도로 `oldest_unflush_lsa` 유무에 따라 결정한다. [WAL·진단 분기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10782-L10803) |
| 체크포인트 후보 | 임시 목적에 따른 제외 조건이 거짓이 된다. dirty·LSA 조건과 체크포인트 호출 도달성도 확인해야 실제 추가 flush를 말할 수 있다. [후보 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L4168-L4199) |
| TDE 키 선택 | 암호화 알고리즘이 NONE이 아닌 페이지에만 적용된다. 볼륨 판정이 암호화·복호화의 `is_temp` 인자가 되며, LSA 마커는 이 인자를 대신하지 않는다. [복호화 호출](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8504-L8517), [암호화 호출](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10749-L10762) |
| `pgbuf_simple_fix` | 일반 fix와 다른 임시 볼륨 전용 API이며 진입 assert가 볼륨 판정을 사용한다. false 구간에 호출되면 debug assert 조건을 만족하지 못하지만, 그런 엔진 실행 경로는 아직 확인하지 않았다. [API 진입](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2603-L2629) |
| snapshot 분류 | temp 페이지 집계 분기를 선택하지 않는다. snapshot 호출이 해당 구간에 가능한지는 별도 확인 사항이다. [분류 코드](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L17341-L17358) |
| `pgbuf_is_lsa_temporary`와 로깅 | 마커 축은 유지된다. 다만 undo/redo 생략 함수는 `RVDK_LINK_PERM_VOLEXT`를 먼저 예외 처리하며 undo의 임시 페이지 분기에는 assert도 있다. “temp이면 어떤 로그도 없으므로 복구가 접근하지 않는다”는 증명으로 사용할 수 없다. [로그 생략 예외](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_manager.c#L4366-L4442) |

TDE 암호화는 temp 키와 카운터 nonce 또는 perm 키와 페이지 LSA nonce를 선택하고, nonce를 페이지 헤더에 저장한다. 복호화는 저장된 nonce를 읽으면서 키는 다시 `is_temp`로 선택한다. 따라서 동일 암호문을 서로 다른 `is_temp`로 해석하는 경로가 있다면 키 일관성 문제가 된다. 임시 파일 페이지에 파일의 TDE 알고리즘을 설정하는 코드도 존재한다. 다만 임시 파일이라는 사실만으로 복구 중 그 암호문을 읽는다고 결론내리지 않는다. [암호화 키·nonce](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/tde.c#L973-L1003), [복호화 키·nonce](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/tde.c#L1025-L1052), [파일 알고리즘 설정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/file_manager.c#L5472-L5506)

DWB 복구가 미마운트 볼륨의 slot을 건너뛰는 것은 확인된다. 이는 특정 slot의 처리 조건이며 재기동 전체가 항상 안전하다는 보장은 아니다. 복구 과정에는 전체 dirty 페이지 flush도 존재하므로 실제 BCB 집합과 페이지 종류를 확인해야 한다. [미마운트 slot 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L3111-L3130), [복구 종료 flush](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_recovery.c#L932-L946)

## Investigation Scope

### 남은 분석 질문

1. 확인된 헤더·할당 맵 이외에 임시 파일 데이터 페이지가 false 구간에서 read, `NEW_PAGE`, flush되는가. 정상 재기동, crash recovery, 정상 종료, 초기화 실패 정리 경로를 구분한다. SA·emergency·DB 생성 진입도 같은 순서라고 가정하지 않는다.
2. 각 접근에서 purpose, voltype, LSA 마커, 페이지 종류, TDE 알고리즘, DWB 생성 상태가 무엇인가. TDE는 동일 페이지의 기록과 재독출을 연결해 키 선택 일관성을 판정한다.
3. 접근이 있어도 현행 보호 조건으로 안전한가. 안전하다면 확인한 전제와 범위를 문서화한다. 근거 보완 또는 동작 수정이 필요하면 범위와 후속 처리 위치를 제시한다. 가드 교체, assert 추가, 주석 변경 중 어느 것도 선결정하지 않는다.

확인한 `pgbuf_simple_fix` 호출부는 임시 파일 페이지 해제와 질의 결과 페이지의 latch 없는 읽기이다. 호출부의 용도는 확인했지만 각 진입에서 false 구간에 도달하지 않는다는 증명은 아직 없다. [임시 파일 사용자 페이지 해제](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/file_manager.c#L4036-L4078), [파일 테이블 페이지 해제](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/file_manager.c#L4272-L4293), [질의 결과 읽기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/query/query_manager.c#L2806-L2821)

### 제안하는 한정 검증

다음은 미실행 계획이다. 먼저 고정 소스에서 위 경로와 조건을 추적하고, 정적으로 판정하지 못한 구간만 격리된 테스트 데이터베이스로 검증한다. 전체 QA나 무작위 정렬 부하를 이 조사의 선행 조건으로 두지 않는다.

| 검증 묶음 | 준비·관찰 | 판별할 결과 |
|---|---|---|
| 부팅·정상 종료 | 영구 형식의 임시 용도 볼륨을 가진 DB와 자동 임시 볼륨을 쓰는 DB를 나눈다. phase, VPID, 페이지 종류, 실제 purpose/voltype, LSA 마커, TDE 알고리즘, 호출 스택을 기록한다. | 알려진 메타데이터 경로와 추가 임시 데이터 접근을 구분하고, 종료 전 제거·무효화가 어디까지 보장되는지 확인한다. |
| crash recovery | 앞의 자산으로 테스트 DB 서버 하나의 PID와 DB 이름을 검증한 뒤, 테스트 하네스에서 그 프로세스만 종료한다. 부하가 임시 디스크 페이지를 사용했다는 증거를 확보하고 재기동한다. | 복구 구간의 실제 read·flush 집합과 기존 마커의 보존 여부를 확인한다. 부하 실행만으로 임시 페이지 접근을 증명하지 않는다. |
| TDE·DWB | 먼저 TDE와 DWB를 켠 debug 구성에서 관찰하고, TDE를 끈 대조 구성과 필요한 DWB 비활성 구성을 비교한다. 암호화 페이지 접근이 확인되면 release 구성에서도 동일 VPID의 기록·재독출 결과를 확인한다. | TDE 호출 인자와 실제 키 선택의 일관성, DWB 경유 조건, debug assert와 release 동작을 구분한다. |
| 실패 정리·다른 진입 | 정적 추적에서 남은 초기화 실패, SA, emergency 진입을 좁혀 준비 상태와 해제 순서를 기록한다. 결론에 필요한 경우에만 해당 실패 지점을 제한적으로 주입한다. | 검증하지 않은 경로와 정적 근거로 제외한 경로를 분리한다. 오류 주입 결과를 일반 운영 발생 증거로 취급하지 않는다. |

계측은 기존 가드를 우회해 `xdisk_get_purpose`를 먼저 호출하면 안 된다. 조회가 안전한 시점의 유효한 볼륨 정보나 이미 읽은 volume header의 purpose/voltype을 사용하고, 캐시 준비 전에는 미확인으로 기록한다. 기존 시나리오의 시스템 전체 서버 이름 기반 강제 종료는 검증 절차로 사용하지 않는다. 테스트 자산, 설치 빌드 SHA, 설정, 대상 PID, 로그와 판정 근거를 함께 보관하며 조사용 계측과 채택할 검증 자산을 구분한다.

## Specification Changes

이 조사에서 사용자 노출 동작 변경은 아직 정하지 않는다. 조사 결론으로 현행 계약을 명확히 하며, 기능 변경이 필요하면 그 요구와 검증 범위를 별도로 확인한다.

## Implementation

TBD - ANALYSIS 단계에서 결정한다. 현행 유지, 문서·주석 보완, 동작 수정 필요성의 결론과 근거가 우선 산출물이다.

## Acceptance Criteria

- [ ] 프로세스 초기 상태, 재기동 준비, 로그 복구, 정상 운영, 종료·오류 정리의 판정 경계를 소스 전이와 함께 정리한다.
- [ ] 두 voltype/purpose 조합에 대해 확인된 메타데이터 접근과 임시 데이터 페이지 접근을 구분한다. “접근 없음”은 조사한 진입·설정 범위를 명시하고, 남은 경로는 미확인으로 남긴다.
- [ ] 위 영향 지점마다 도달 조건, 마커 등 보호 조건, 관찰한 차이와 남은 불확실성을 정리한다. TDE의 동일 페이지 기록·재독출과 DWB 준비 상태를 포함한다.
- [ ] 현행 유지, 근거 보완, 또는 후속 동작 수정 중 결론을 제시한다. 기능 결함이 확인되지 않는 결과도 허용하며, 후속 수정이 필요하면 근거와 경계를 부모 이슈에 연결한다.

## Definition of done

- [ ] 고정 소스 경로와 실행 검증 여부를 구분한 조사 결과를 검토한다. 실행했다면 빌드·설정·자산과 로그를 재현 가능한 형태로 남긴다.
- [ ] 조사용 계측의 처리 여부를 명시한다. 코드 변경을 채택하면 변경에 맞는 debug/release 빌드와 집중 검증을 수행하고 결과·한계를 남긴다. 문서만으로 완료하면 해당 근거를 기록한다.
- [ ] 결론과 후속 조치 여부를 [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)에 연결한다.

## Triage Request

[CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)의 자식 조사로 확인하고 작성자 측에 ANALYSIS를 배정해 줄 것을 요청한다. 범위는 복구·종료의 임시 목적 판정, 실제 페이지 접근과 안전성 근거이다. 임시 판정의 호출 비용 최적화, 일반 flush 오류 복구, `pgbuf_simple_fix` 실패 정리 결함은 각각 별도 과제이며 이 조사에서 수정 범위를 흡수하지 않는다. 조사 도중 확인한 공통 전제는 해당 이슈와 공유한다.
