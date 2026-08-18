# [PGBUF] [Survey] 복구 중 temp 볼륨 판정의 영향을 조사한다

## Issue Triage

**이슈 수행 목적**: 복구 구간에서 `pgbuf_is_temporary_volume` 이 항상 false 를 반환하는 현재 동작이 안전한지 판정하고, 안전하다면 그 판단 근거를 코드에 남긴다. 위험이 확인되면 별도 수정 이슈로 넘긴다.

**이슈 수행 이유**:

| 구분 | 내용 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | `pgbuf_is_temporary_volume`(`page_buffer.c:5493-5503`)은 `LOG_ISRESTARTED ()` 가 거짓인 동안 볼륨 목적을 조회하지 않고 무조건 false 를 반환한다(`:5498-5501`). 그 구간에서는 temp 볼륨의 page 가 일반 page 와 구별되지 않아 temp 전용 처리 경로를 하나도 타지 않는다. 함수에 달린 주석은 "I don't know why page buffer should care about temporary files ... it is really annoying" 이라, 이 동작이 의도인지 회피인지 판단할 근거가 남아 있지 않다. |
| **TO-BE (목표 상태 / 기대 동작)** | `TBD - 조사 결과에 따름`. 구간 안에서 temp 볼륨 page 접근이 없다고 확인되면 현재 동작을 그대로 두고, 왜 안전한지를 함수 주석으로 대체하는 것이 목표 상태다. 접근이 존재하고 non-temp 취급이 위험 측이면 판정 로직 수정을 후속 이슈로 분리한다. |
| **영향** | 설계 의도 훼손 가능성 — temp page 처리는 "복구 대상이 아니므로 로깅도 이중 쓰기도 필요 없다"는 전제로 만들어졌는데, 이 구간에서는 그 전제가 통째로 빠진다. 특히 TDE 를 켠 데이터베이스는 `is_temp` 가 데이터 키 선택을 바꾸므로(`tde.c:927-939`, `:979-988`), 같은 page 를 쓸 때와 읽을 때 판정이 갈리면 복호화가 어긋난다. |

**이슈 수행 방안**: 코드 수정 없이 조사부터 한다. 아래 Implementation 의 세 질문에 결론을 내고, 수정 여부와 범위는 그 결론으로 정한다. 결론이 "문제 없음" 으로 끝날 수 있는 조사이며, 그 경우에도 판정 근거를 코드 주석으로 남기는 것까지가 이 이슈의 완료 조건이다. 판정 함수를 손대는 수정은 이 이슈에서 하지 않고 별도 이슈로 등록한다.

------------------------------------------------------------------------

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **조사 범위**: `src/storage/page_buffer.c`(판정 함수와 11개 호출 지점), `src/transaction/log_manager.c`(`rcv_phase` 전이와 로깅 생략 판정), `src/transaction/boot_sr.c`(temp 볼륨 제거 시점), `src/storage/disk_manager.c`(`xdisk_get_purpose` 초기화 전 동작), `src/storage/tde.c`(키 선택), `src/storage/double_write_buffer.cpp`(복구 시 미마운트 볼륨 처리). 조사 산출물은 결론 문서와 코드 주석이며, 예상되는 코드 변경은 최소 주석 한 문단에서 최대 판정 함수 수정까지다. 아래 라인 번호는 별도 표기가 없으면 develop `e6ed61e87` 의 `page_buffer.c` 기준이다.
- **부모 EPIC / 결함 ID**: CBRD-27193 의 자식 이슈이며 결함 N7(복구 중 temp 볼륨 판정)을 소유한다.

------------------------------------------------------------------------

## Description

`pgbuf` (page buffer manager — 디스크 page 를 메모리 frame 에 캐시하고 fix, latch, 교체, flush 를 관리하는 모듈)는 temp page 를 특별하게 다룬다. temp page 는 재기동 후 살아남을 필요가 없으므로 `WAL` (Write-Ahead Logging — data page 보다 log 를 먼저 기록하는 규칙)을 적용하지 않고, `DWB` (Double Write Buffer — 원래 위치에 쓰기 전 별도 파일에 사본을 기록하는 torn-write 보호 장치)도 거치지 않으며, `LRU` (Least Recently Used — 최근 사용 시점 기준 page 교체 목록) 승격 대상에서도 빠진다.

문제는 "이 page 가 temp 인가" 를 판정하는 두 축 중 하나가 특정 구간에서 무력화된다는 점이다.

| 축 | 판정 함수 | 근거 | 위치 |
|---|---|---|---|
| 볼륨 목적 | `pgbuf_is_temporary_volume (volid)` | `xdisk_get_purpose` 결과가 `DB_TEMPORARY_DATA_PURPOSE` 인가 | `:5493-5503` |
| page LSA 마커 | `pgbuf_is_temp_lsa (lsa)` | page 의 `prv.lsa` 가 `PGBUF_TEMP_LSA` 인가 (`page_buffer.h:260` 의 `{-2, -2}`) | `:17260-17264` |

`pgbuf_is_lsa_temporary`(`:5470-5484`)는 두 축의 OR 이므로, 볼륨 축이 죽어도 마커 축이 남아 있으면 판정은 살아 있다. 반대로 볼륨 축만 보는 지점은 구간 안에서 판정이 완전히 뒤집힌다.

### 볼륨 축이 temp 로 보는 볼륨은 두 종류다

볼륨의 종류(voltype)와 용도(purpose)는 별개 축이다(`dbtype_def.h:198-209`). `pgbuf_is_temporary_volume` 은 용도만 보므로 아래 둘을 구별하지 않는다.

| 종류 | 만드는 방법 | 재기동 시 | 예시 |
|---|---|---|---|
| 임시 voltype + temp 용도 | 정렬·질의 임시 공간이 부족할 때 서버가 자동 생성 | `boot_remove_all_temp_volumes` 가 삭제 (`boot_sr.c:904-924`, `boot_Db_parm->temp_last_volid` 이상 범위만 대상) | `<db>_t32766` |
| 영구 voltype + temp 용도 | `cubrid addvoldb -p temp <db>` (`util_cs.c:463-465`, voltype 기본값이 perm) | 삭제되지 않고 그대로 남는다 | `<db>_x001` 형태의 확장 볼륨 |

"temp 볼륨은 재기동 때 재생성되므로 복구가 건드릴 일이 없다" 는 전제는 첫째 종류에만 성립한다. 둘째 종류는 재기동 후에도 계속 존재하고, 복구 구간에도 마운트된 상태다.

### 판정이 false 로 고정되는 구간

`LOG_ISRESTARTED ()` 는 `log_Gl.rcv_phase == LOG_RESTARTED` 다(`log_impl.h:193`). `LOG_RESTARTED` 는 enum 의 첫 값(0)이라 전역 변수 `log_Gl` 이 0 으로 초기화된 상태에서는 참이고, 로그 매니저가 복구를 시작하면서 거짓으로 바뀐다.

    부팅
      log_initialize_internal ()                              log_manager.c:1102
        rcv_phase = LOG_RECOVERY_ANALYSIS_PHASE               log_manager.c:1145
        └ logtb_define_trantable_log_latch ()
             └ pgbuf_initialize ()                            log_tran_table.c:494
        analysis -> redo -> undo -> finish 2PC                log_recovery.c:835-920
        rcv_phase = LOG_RESTARTED                             log_manager.c:1443
    ★ 여기까지가 판정 false 구간 — page buffer 의 첫 수명 전체가 이 안에 든다
      정상 운영 (볼륨 목적 조회가 실제로 동작)
    종료
      log_final ()                                            log_manager.c:1743
        rcv_phase = LOG_RECOVERY_ANALYSIS_PHASE               log_manager.c:1761
    ★ 여기서 판정 false 구간이 다시 열린다
        pgbuf_flush_all (NULL_VOLID)  <- 모든 dirty page flush log_manager.c:1835
        logtb_undefine_trantable () -> pgbuf_finalize ()       log_tran_table.c:591

즉 이 구간은 "crash recovery 중" 만이 아니다. page buffer 가 만들어진 직후부터 복구가 끝날 때까지, 그리고 종료 절차가 시작된 뒤 마지막 flush 까지가 모두 포함된다.

### 가드가 있는 이유로 보이는 것

`xdisk_get_purpose`(`disk_manager.c:5616`)는 disk 매니저가 초기화되기 전(`disk_Cache == NULL`)이면 `assert (volid == LOG_DBFIRST_VOLID)` 를 걸고 `DB_PERMANENT_DATA_PURPOSE` 를 반환한다(`:5618-5623`). 가드가 없으면 볼륨 정보가 아직 없는 시점의 page fix 가 debug 빌드에서 이 assert 를 때린다. 주석의 "annoying" 은 이 상황을 가리키는 것으로 보인다.

다만 정상 재기동 경로에서는 `disk_manager_init (thread_p, true)` 가 `log_initialize` 보다 먼저 실행되므로(`boot_sr.c:2372` 대 `:2428`), 복구 구간에는 disk 캐시가 이미 채워져 있다. 가드가 필요한 창보다 넓게 잡혀 있을 가능성이 있고, 이것도 조사 항목이다.

### 이미 확인한 완화 요인

- 로깅 생략 판정(`log_can_skip_undo_logging` `log_manager.c:4356`, `log_can_skip_redo_logging` `:4400`)은 `pgbuf_is_lsa_temporary` 를 쓰므로 마커 축으로도 성립한다. 디스크에서 읽어 온 temp page 는 이미 마커를 갖고 있어 이 경로는 구간 안에서도 보호된다.
- DWB 복구는 마운트되지 않은 볼륨의 slot 을 건너뛴다(`double_write_buffer.cpp:3123-3127`). 임시 voltype 볼륨의 page 가 DWB 에 들어간 뒤 그 볼륨이 삭제됐더라도 재기동 자체를 깨뜨리지는 않는다.
- 정상 종료 경로는 임시 voltype 볼륨을 `boot_remove_all_temp_volumes`(`boot_sr.c:3081`)로 먼저 제거한 뒤 `log_final`(`:3110`)을 호출한다. 그 종류에 한해서는 종료 구간이 다시 열릴 때 대상 볼륨이 이미 없다.

반대로 위험 쪽으로 기우는 사실도 있다. 재기동 경로의 임시 voltype 볼륨 제거(`boot_sr.c:2568`)는 복구가 끝난 뒤라, 복구 중에는 이전 실행의 볼륨이 아직 마운트되어 있다. 영구 voltype + temp 용도 볼륨은 애초에 삭제 대상이 아니어서 복구와 종료 구간 모두에서 계속 존재한다.

> **요지**: 마커 축이 살아 있어 로깅 계열은 대체로 보호된다. 남는 위험은 구간 안에서 처음 만들어져 마커를 못 받은 page, 볼륨 축만 보는 지점들, 그리고 재기동 후에도 삭제되지 않는 영구 voltype + temp 용도 볼륨이다.

## Specification Changes

없다(N/A). 조사 이슈이므로 사용자 노출 스펙 변경은 없다. 조사 결과 판정 로직을 바꾸기로 결정되면 그 이슈에서 스펙 변경을 다룬다.

## Implementation

조사 계획을 세 질문으로 나눈다.

### 1. 구간 안에서 temp 볼륨 page 접근이 실제로 발생하는가

임시 voltype 볼륨은 재기동 시 삭제되므로 복구가 그 page 를 건드릴 이유가 없어 보인다. 영구 voltype + temp 용도 볼륨은 그 논리가 통하지 않으니 두 종류를 나눠 확인한다.

- temp page 는 로깅되지 않으므로 redo/undo 대상이 될 수 없다는 점을 `log_can_skip_undo_logging` / `log_can_skip_redo_logging` 의 조건으로 확인한다. 특히 마커 없이 만들어진 temp 볼륨 page 가 로깅 대상이 될 수 있는지를 본다.
- 복구 중 호출되는 `pgbuf_flush_all (NULL_VOLID)`(`log_recovery.c:943`, `:4079`, `:5139`)이 temp 볼륨 BCB 를 만날 수 있는지 확인한다. `BCB` 는 frame 에 올라온 page 의 fix 수와 latch, dirty 상태를 보관하는 제어 블록이다.
- 종료 경로의 `pgbuf_flush_all`(`log_manager.c:1835`)과, temp 볼륨 제거를 거치지 않고 `log_final` 에 도달하는 오류 경로를 확인한다. 재기동 실패 정리 경로(`boot_restart_server`, `boot_sr.c:2783`)와 DB 생성 실패 정리 경로(`xboot_initialize_server`, `boot_sr.c:1922`)가 그 후보다.
- 재기동 중 temp 볼륨 page 를 fix 하는 호출자가 있는지 확인한다. temp 전용 latchless API `pgbuf_simple_fix` 는 진입부에 `assert (pgbuf_is_temporary_volume (vpid->volid))`(`:2659`)가 있어 구간 안에서 호출되면 debug 빌드가 즉시 멈춘다. 지금까지 확인된 호출부는 temp 파일 파괴(`file_manager.c:4101`, `:4309`)와 질의 결과 리스트 파일(`query_manager.c:2733`)이며, 둘 다 복구 구간 밖으로 보이지만 확정이 필요하다.
- 확인 방법: 판정 함수 `:5498-5501` 의 조기 반환 앞에 임시 계측을 넣는다. `!LOG_ISRESTARTED ()` 이면서 `xdisk_get_purpose (NULL, volid) == DB_TEMPORARY_DATA_PURPOSE` 인 경우에 volid 와 호출 스택을 `er_log_debug` 로 남기고, 아래 시나리오를 돌린다. 조기 반환 앞에서 조회하므로 계측 자체는 판정 결과를 바꾸지 않는다.

```bash
# 영구 voltype + temp 용도 볼륨이 있는 데이터베이스를 만든다
cubrid createdb --db-volume-size=100M --log-volume-size=100M tempchk en_US
cubrid server start tempchk
cubrid addvoldb -p temp --db-volume-size=100M tempchk
cubrid spacedb -p tempchk        # 볼륨 용도가 TEMPORARY 로 잡혔는지 확인

# temp 볼륨을 쓰는 정렬 부하를 걸고, 그 도중에 서버를 강제 종료해 crash recovery 를 만든다
csql -u dba -C tempchk -c "CREATE TABLE t1 (i INT, s VARCHAR(200));"
csql -u dba -C tempchk -c "INSERT INTO t1 SELECT ROWNUM, LPAD('x', 200, 'x') FROM db_class a, db_class b, db_class c;"
csql -u dba -C tempchk -c "SELECT COUNT(*) FROM (SELECT s FROM t1 ORDER BY s) t" &
sleep 2 && pkill -9 cub_server

# 재기동해 복구를 태운 뒤 계측 로그를 확인한다
cubrid server start tempchk
grep -n 'pgbuf_is_temporary_volume' $CUBRID/log/server/tempchk_*.err
```

임시 계측은 조사용이며 커밋 대상이 아니다.

### 2. 접근이 존재한다면 non-temp 취급이 안전 측인가 위험 측인가

볼륨 축만 보는 지점을 전부 열거하고 각각의 위험 방향을 채운다. 아래 표의 마지막 칸이 조사 산출물이다.

| # | 지점 | 위치 | temp 로 판정될 때의 동작 | 구간 안에서의 실제 동작 | 위험 방향 |
|---|---|---|---|---|---|
| 1 | 최초 read 후 temp LSA 스탬프 | `:8515-8521` | 마커가 없으면 `pgbuf_init_temp_page_lsa` + dirty 설정 | 스탬프하지 않음 | 조사 필요 |
| 2 | NEW_PAGE 초기화 | `:8554-8562` | temp 마커로 초기화 | `fileio_init_lsa_of_page` 로 일반 page 처럼 초기화 | 조사 필요 (마커 자체가 안 붙는 유일한 경로) |
| 3 | `pgbuf_set_lsa` 강제 복원 | `:4981-4988` | LSA 를 temp 마커로 되돌림 | 실제 LSA 를 그대로 기록 | 조사 필요 |
| 4 | LRU 승격 억제 (`PGBUF_SHOULD_IGNORE_UNFIX`, `:288-295`) | `:6705`, `:6734`, `:6769` | zone 1/2/3 에서 boost 와 private→shared 이동 생략 | 일반 page 와 동일하게 승격 | 성능만 (안전 측) |
| 5 | DWB 우회 | `:10688`, `:10743` | `uses_dwb = false` | DWB 경유 기록 | 쓰기 증폭 (안전 측으로 보임, 확인 필요) |
| 6 | WAL 미로깅 경고 억제 | `:10793` | 경고 침묵 | `er_log_debug` 경고 출력 | 로그 소음 |
| 7 | 체크포인트 flush 제외 | `pgbuf_flush_checkpoint` `:4204` | 후보에서 `continue` | 체크포인트 대상에 포함 | 조사 필요 |
| 8 | TDE 키 선택 | `:8498`(복호화), `:10688`+`:10751`(암호화) | `temp_key` + 카운터 nonce | `perm_key` + LSA nonce | 조사 필요 (아래 별항) |
| 9 | temp 전용 API assert | `:2659` | assert 통과 | debug 빌드에서 assert 실패 | 조사 필요 |
| 10 | snapshot 통계 분류 | `:17318` | `num_temp_pages` 로만 집계 | data/index/system 으로 분류 | 통계 표시만 |
| 11 | `pgbuf_is_lsa_temporary` 의 볼륨 축 | `:5477-5478` | 마커가 없어도 temp 로 판정 | 마커 축만 남음 | 마커 있는 page 는 보호됨 |

8번은 별도로 다룬다. `tde_encrypt_data_page`(`tde.c:913`)는 `is_temp` 로 데이터 키를 고르고(`:927-939`, temp 는 `temp_key` 와 원자적 카운터 nonce, perm 은 `perm_key` 와 page LSA nonce), `tde_decrypt_data_page`(`:966`)도 같은 인자로 키를 고른다(`:979-988`). nonce 는 page 헤더에 저장돼 되읽히지만 키는 매번 `is_temp` 로 다시 고르므로, 쓸 때와 읽을 때 판정이 다르면 복호화 결과가 깨진다. temp 파일도 TDE 대상이 될 수 있다는 점은 `file_manager.c:5533` 의 `pgbuf_set_tde_algorithm (..., FILE_IS_TEMPORARY (fhead))` 로 확인된다. 따라서 "구간 안에서 temp 볼륨 + TDE page 가 flush 되거나 read 되는 경우가 있는가" 가 이 조사에서 가장 먼저 답해야 할 질문이다.

### 3. 현재 동작을 유지한다면 근거를 어디에 남기는가

1번과 2번의 결론이 "구간 안에 temp 볼륨 page 접근이 없다" 로 모이면, 지금의 `TODO` 주석을 다음 내용으로 교체한다.

- 판정이 false 로 고정되는 구간의 정확한 경계(`log_manager.c:1145` ~ `:1443`, 그리고 `:1761` 이후)
- 그 구간에 temp 볼륨 page 가 존재할 수 없는 이유와 근거 코드 위치
- 가드가 필요한 근본 이유(`xdisk_get_purpose` 의 disk 캐시 미초기화 분기)
- 이 전제가 깨지면 무엇이 먼저 문제가 되는지(TDE 키 선택과 NEW_PAGE 마커 누락)

전제가 깨지는 것을 코드로 잡을 수 있으면 주석 대신 `assert` 를 넣는 쪽이 낫다. 어느 쪽을 택할지는 조사 결론과 함께 결정한다.

## Acceptance Criteria

- [ ] 판정이 false 로 고정되는 구간의 경계가 `rcv_phase` 전이 근거와 함께 정리되고, 복구 구간만이 아니라 종료 구간도 포함된다는 점이 명시된다.

- [ ] 구간 안에서 temp 용도 볼륨 page 접근이 발생하는지에 대해 "발생함" 또는 "발생하지 않음" 중 하나로 결론이 나고, 계측 또는 코드 경로 추적 근거가 붙는다. 임시 voltype 볼륨과 영구 voltype + temp 용도 볼륨을 각각 판정한다.

- [ ] 위 11개 지점 표의 위험 방향 칸이 전부 채워지고, 각 항목이 안전 측(성능·로그 소음만) 또는 위험 측(정합성)으로 분류된다.

- [ ] TDE 조합 판정이 결론에 포함된다 — temp 볼륨 page 가 구간 안에서 암호화되어 기록되거나 복호화될 수 있는지, 가능하다면 키 불일치가 실제로 성립하는지.

- [ ] 결론이 "문제 없음" 이면 판정 근거가 `pgbuf_is_temporary_volume` 주석으로 남고 기존 `TODO` 주석이 대체된다. 코드로 전제를 검사할 수 있으면 `assert` 추가 여부까지 판단한다.

- [ ] 위험이 확인되면 수정 범위와 방향을 정리해 별도 이슈로 등록하고 이 이슈에 링크한다.

## Definition of done

- [ ] 위 Acceptance Criteria 충족

- [ ] 조사에 쓴 임시 계측 코드가 커밋에 남지 않는다

- [ ] 주석 또는 `assert` 를 추가한 경우 release 와 debug 빌드가 통과하고 QA 회귀에 영향이 없음을 확인한다

- [ ] 결론과 후속 처리(현행 유지 또는 수정 이슈 번호)가 부모 EPIC 에 반영된다

## Open Questions

### 판정 로직을 바꾸는 쪽이 나은가

가드 조건을 `LOG_ISRESTARTED ()` 대신 disk 매니저 초기화 여부로 바꾸면, 복구 구간에서도 볼륨 목적을 정상 조회할 수 있다. `disk_manager_init` 이 `log_initialize` 앞에 있으므로(`boot_sr.c:2372` 대 `:2428`) 정상 재기동 경로에서는 성립하지만, SA 모드와 emergency 재기동, `log_recreate` 같은 다른 진입 경로에서 순서가 같은지 확인해야 한다. 이 방향을 택할지는 `TBD - 합의 미확인` 이며 조사 결론을 본 뒤 결정한다.

### 호출 빈도 문제를 여기서 다룰지

`pgbuf_is_temporary_volume` 은 `PGBUF_SHOULD_IGNORE_UNFIX`(`:291-292`)를 통해 모든 unfix 경로에서 호출되는데, 결과를 캐시하지 않고 매번 `xdisk_get_purpose` 를 부른다. 이것은 정합성이 아니라 성능 축의 별개 문제이므로 이 이슈에서는 다루지 않는 것을 제안한다. 판정 로직을 바꾸기로 하면 두 사안이 같은 함수에서 만나므로 그때 함께 볼 수 있다.

## 참고 코드

- `src/storage/page_buffer.c:5493-5503` — 판정 함수 본체
- `src/storage/page_buffer.c` 의 볼륨 축 호출 지점: `:288-295`, `:2659`, `:4204`, `:4981`, `:5477-5478`, `:8498`, `:8515`, `:8554`, `:10688`, `:10793`, `:17318`
- `src/transaction/log_manager.c:1145`, `:1443`, `:1761` — `rcv_phase` 전이
- `src/transaction/log_manager.c:4333-4360`, `:4385-4404` — 로깅 생략 판정
- `src/transaction/boot_sr.c:2372`, `:2428`, `:2568`, `:3081`, `:3110` — 부팅·종료 순서
- `src/storage/disk_manager.c:5616-5623` — disk 캐시 미초기화 시 동작
- `src/storage/tde.c:913-954`, `:966-1003` — `is_temp` 에 따른 키와 nonce 선택
- `src/storage/double_write_buffer.cpp:3123-3127` — 복구 시 미마운트 볼륨 slot 건너뛰기
- `src/compat/dbtype_def.h:198-209` — 볼륨 용도와 볼륨 종류 열거값
- `src/executables/util_cs.c:463-465`, `:488-520` — `addvoldb` 의 purpose 와 voltype 조합 처리
- `src/transaction/boot_sr.c:904-924`, `:1149-1187` — 임시 voltype 볼륨만 제거하는 범위
