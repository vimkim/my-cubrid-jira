# [PGBUF] debug 빌드 전용 결함 2건을 수정한다

## Issue Triage

**이슈 수행 목적**: `CUBRID_DEBUG` 를 정의한 빌드가 `page_buffer.c` 에서 깨지지 않게 하고, 페이지 dealloc 보상 복구가 debug 로그에 쓰레기 값을 남기지 않게 한다.

**이슈 수행 이유**:

- **AS-IS (현재 동작 / 배경)**: `CUBRID_DEBUG` (진단용 검증·덤프 코드를 켜는 컴파일 스위치로, 빌드 스크립트와 CI 어디에서도 정의하지 않는다) 를 정의하면 `page_buffer.c` 컴파일이 오류 13건으로 실패한다. 원인은 `pgbuf_dump` (`:11302-11384`) 가 2017년 volume info 제거(`b634bb442`, CBRD-20897)와 2026년 BCB latch 원자화(`58cef8e01`, CBRD-26425) 이후 사라진 필드 (`pgbuf_Pool.volinfo_mutex`, `bufptr->fcnt`, `bufptr->zone` 등) 를 계속 참조하고, 오타 `consistenet_str` 가 `:3284` 와 `:11370` 두 곳에 남아 있기 때문이다. 별개로 `pgbuf_rv_dealloc_undo_compensate` (`:15252`) 는 대입 한 번 없는 지역 변수 `VPID vpid` (`:15255`) 를 `:15271` 의 TDE 디버그 로그 인자로 읽는다.
- **TO-BE (목표 상태 / 기대 동작)**: `CUBRID_DEBUG` 정의 빌드가 통과해 `pgbuf_finalize` 의 fix 잔존 진단(`pgbuf_dump_if_any_fixed`)이 다시 살아나고, 보상 복구 로그가 실제 대상 페이지의 VPID (Volume and Page IDentifier — 볼륨 번호와 페이지 번호의 쌍) 를 출력한다.
- **영향**: 기술 부채 — 버퍼 누수와 페이지 내용 불일치를 잡기 위해 만들어 둔 진단 경로가 9년 넘게 사용 불가 상태다. `pgbuf_finalize` 종료 시점의 미해제 fix 점검(`:1888-1890`)과 unfix 시점의 내용 일관성 점검(`:3156-3179`)이 둘 다 이 스위치에 걸려 있어서, 실제로 의심 상황이 생겼을 때 켜려면 먼저 컴파일 오류부터 고쳐야 한다. VPID 쪽은 debug 빌드에서 `er_log_tde` 를 켠 경우에 한해 잘못된 위치를 가리키는 로그가 남아 분석을 오도한다.

**이슈 수행 방안**:

| 대상 | 처리 |
|---|---|
| `pgbuf_dump` 의 없어진 pool 필드 참조 (`:11320-11338`) | volume info 캐시는 disk cache 로 이관돼 되살릴 대상이 아니므로 해당 덤프 블록을 삭제한다 |
| `bufptr->fcnt`, `bufptr->zone` (`:11349`, `:11369`) | 현행 접근자 `get_fcnt (&bufptr->atomic_latch)` (`:1467`) 와 `pgbuf_zone_str (pgbuf_bcb_get_zone (bufptr))` (`:14921`, `:15933`) 로 바꾼다. `pgbuf_unfix_all` 의 `:3278-3279` 가 같은 정보를 이미 이 형태로 출력하고 있어 그대로 따르면 된다 |
| 오타 `consistenet_str` (`:3284`, `:11370`) | 선언된 이름 `consistent_str` 로 정정한다 |
| `pgbuf_is_consistent` 의 const 위반 (`:11444`, `:11468`) | `pgbuf_is_consistent` 는 `const PGBUF_BCB *` 를 받는데(`:11406`) `get_fcnt` 는 비-const 포인터를 요구한다. `get_fcnt` 계열에 const 오버로드를 추가하는 안과 `pgbuf_is_consistent` 의 매개변수 const 를 떼는 안이 있고, 선택은 `TBD - 합의 미확인` |
| 미초기화 `VPID vpid` (`:15255`) | `pgbuf_get_vpid (rcv->pgptr, &vpid)` 로 채운다. `rcv->pgptr` 은 진입부 assert (`:15258`) 가 non-NULL 을 보장한다 |
| `CUBRID_DEBUG` 빌드의 회귀 방지 | 이 스위치를 CI 컴파일 검사에 넣을지는 이 이슈의 범위 밖이며 `TBD - 합의 미확인` |

------------------------------------------------------------------------

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: 수정 대상은 `src/storage/page_buffer.c` 뿐이다. 두 결함 모두 조건부 컴파일 구획 안에 있어 출시 빌드의 기계어에는 흔적이 없다 — `pgbuf_dump` 쪽은 `#if defined(CUBRID_DEBUG)`, VPID 쪽은 `#if !defined(NDEBUG)` (assert 를 켠 debug 빌드) 이며 `er_log_tde` (`PRM_ID_ER_LOG_TDE`, hidden, 기본 false) 를 켠 경우에만 실행된다. `get_fcnt` 에 const 오버로드를 추가하기로 하면 그 접근자를 쓰는 다른 지점들이 함께 재컴파일 대상이 되므로, 서명 변경 범위는 리뷰에서 확정해야 한다.

------------------------------------------------------------------------

## Description

부모 EPIC 은 CBRD-27193 이고, 이 이슈가 소유한 결함은 그 본문의 N4 와 N5 다.

### N4 — pgbuf_dump 가 두 차례 리팩터링을 따라가지 못했다

`pgbuf` (page buffer manager — 디스크 page 를 메모리 frame 에 캐시하고 fix, latch, 교체, flush 를 관리하는 모듈) 에는 BCB (Buffer Control Block — frame 에 올라온 page 의 fix 수, latch, dirty 상태를 담은 제어 블록) 전체를 표 형태로 찍는 `pgbuf_dump` 가 있다. 호출자는 두 곳이다.

```
pgbuf_finalize                                                    :1881
  └ #if defined(CUBRID_DEBUG) pgbuf_dump_if_any_fixed             :1888-1890
       ├ fcnt > 0 인 BCB 발견 -> pgbuf_dump                       :11273-11279
       └ 내용 불일치 발견     -> pgbuf_dump                       :11290-11293

pgbuf_unfix                                                       :3026
  └ #if defined(CUBRID_DEBUG) 페이지 내용 검증 블록               :3156-3179
       └ PGBUF_CONTENT_BAD -> pgbuf_dump                          :3178
```

두 진단은 "요청이 끝났는데 fix 가 남아 있다" 와 "dirty 로 표시된 페이지 내용이 디스크와 같다" 처럼 상위 모듈의 버그를 잡는 용도다. 그런데 이 스위치를 켜면 컴파일 자체가 되지 않는다. 오류 13건은 네 갈래다.

| 갈래 | 위치 | 원인 |
|---|---|---|
| `pgbuf_Pool.volinfo_mutex`, `last_perm_volid`, `num_permvols_tmparea`, `permvols_tmparea_volids` | `:11321`, `:11322`, `:11323`, `:11325`, `:11328`, `:11334`, `:11338` (7건) | `b634bb442` (2017-01-27, CBRD-20897) 가 pgbuf 의 volume info 캐시를 걷어내고 disk cache 에 위임했다. 같은 커밋이 다른 사용처는 모두 지웠지만 `CUBRID_DEBUG` 안쪽은 컴파일되지 않아 남았다 |
| `bufptr->fcnt`, `bufptr->zone` | `:11349`, `:11369` (2건) | `58cef8e01` (2026-01-14, CBRD-26425) 이 fix 수와 latch mode 를 하나의 원자 워드 `atomic_latch` 로 옮겼고, zone 은 그 전부터 `flags` 워드에 인코딩돼 있다. 현행 구조체(`:513-545`)에는 두 필드가 없다 |
| 오타 `consistenet_str` | `:3284` (`pgbuf_unfix_all`), `:11370` (2건) | 선언은 `consistent_str` (`:3251`, `:11310`) 이다. 두 곳 모두 `CUBRID_DEBUG` 안쪽이라 일반 빌드에서는 드러나지 않는다 |
| `const PGBUF_ATOMIC_LATCH *` -> `PGBUF_ATOMIC_LATCH *` 변환 | `:11444`, `:11468` (2건) | `pgbuf_is_consistent` 는 `const PGBUF_BCB *` 를 받는데(`:11406`) `get_fcnt` 의 인자는 비-const 다(`:1467`) |

한 함수 안에 정답과 오답이 같이 있다는 점이 이 결함의 성격을 잘 보여준다. `pgbuf_dump` 는 `:11361` 과 `:11368` 에서는 `get_fcnt (&bufptr->atomic_latch)` 와 `get_latch (&bufptr->atomic_latch)` 를 제대로 쓰면서, 바로 위 `:11349` 와 옆줄 `:11369` 에서는 옛 필드를 그대로 둔다. `:11369` 는 zone 값을 latch mode 문자열 변환 함수 `pgbuf_latch_mode_str` 에 넘기고 있어서, 필드가 존재하더라도 잘못된 문자열을 찍는다 — zone 전용 변환 함수 `pgbuf_zone_str` (`:14921`) 가 따로 있다.

### N5 — 보상 복구가 대입되지 않은 VPID 를 로그에 찍는다

페이지 dealloc 의 undo 는 논리적 undo 라서 두 단계로 나뉜다. `pgbuf_rv_dealloc_undo` (`:15202`) 가 페이지를 다시 fix 해 page type 과 pflag (페이지 헤더의 플래그 바이트로, TDE 암호화 여부 비트를 포함) 를 복원하고 보상 로그 `RVPGBUF_COMPENSATE_DEALLOC` 을 기록한다(`:15236`). 그 보상 레코드를 재기동 복구가 다시 적용할 때 실행되는 함수가 `pgbuf_rv_dealloc_undo_compensate` 다 (등록은 `src/transaction/recovery.c:802-807`, 적용은 재기동 복구의 redo 단계 `src/transaction/log_recovery.c:3760`).

```
[트랜잭션 rollback]
  pgbuf_rv_dealloc_undo                                            :15202
    vpid = { udata->pageid, udata->volid }                          :15209-15210
    pgbuf_fix (&vpid, OLD_PAGE_DEALLOCATED, WRITE)                  :15216
    iopage->prv.pflag = udata->pflag                                :15226
    tde_er_log (... VPID_AS_ARGS (&vpid) ...)   <- 정상             :15231-15232
    log_append_compensate_with_undo_nxlsa (RVPGBUF_COMPENSATE_DEALLOC)
                                                                    :15236
[재기동 복구 redo]
  pgbuf_rv_dealloc_undo_compensate                                 :15252
    VPID vpid;                 <- 선언만, 대입 없음                 :15255
    iopage->prv.pflag = udata->pflag                                :15265
    tde_er_log (... VPID_AS_ARGS (&vpid) ...)                       :15271
      ★ 스택 쓰레기 값을 volid|pageid 로 출력
```

`pgbuf_rv_dealloc_undo` 에서 복사해 오면서 VPID 를 채우는 두 줄(`:15209-15210`)만 빠진 형태다. 이쪽 함수는 복구 프레임워크가 페이지를 미리 fix 해 주므로(`:15258` 의 `assert (rcv->pgptr != NULL)`) `pgbuf_get_vpid (rcv->pgptr, &vpid)` 한 줄이면 실제 대상 페이지의 값을 얻는다. 보상 레코드의 `rcv->data` 에도 `pageid`/`volid` 가 실려 있어(`PGBUF_DEALLOC_UNDO_DATA`, `:989-995`) `pgbuf_rv_dealloc_undo` 와 같은 방식으로 채워도 결과는 같다.

발현 조건은 세 개가 모두 겹칠 때다 — assert 를 켠 빌드(`!NDEBUG`), 대상 페이지가 TDE (Transparent Data Encryption — data page 암호화) 로 암호화됨, `er_log_tde` 활성. 로그 오염에 그치고 페이지 데이터에는 영향이 없지만, 하필 복구 중 TDE 페이지를 추적할 때 나오는 로그라 잘못된 위치로 조사를 끌고 갈 수 있다.

## Test Build

`CUBRID develop e6ed61e87` (소스 빌드). Fedora 44 / GCC 16.1.1, `cmake --preset debug` 로 생성한 debug 빌드 트리에서 확인했다.

## Repro

### N4 — CUBRID_DEBUG 컴파일 실패

`page_buffer.c` 하나만 검사하면 되므로, debug 빌드의 실제 컴파일 명령에 `-DCUBRID_DEBUG` 를 더해 문법 검사만 돌린다. CUBRID 소스 최상위에서 실행한다.

```bash
# 1) debug 빌드 트리를 준비한다 (compile_commands.json 이 생성된다)
cmake --preset debug
cmake --build build_preset_debug --target cub_server

# 2) 최상위에 compile_commands.json 을 노출한다
ln -sf build_preset_debug/compile_commands.json compile_commands.json

# 3) 서버 빌드 변형(SERVER_MODE)의 컴파일 명령에 -DCUBRID_DEBUG 만 추가해 문법 검사
python3 - <<'EOF' | sh
import json, shlex
cc = json.load (open ("compile_commands.json"))
e = [x for x in cc if x["file"].endswith ("src/storage/page_buffer.c") and "SERVER_MODE" in x["command"]][0]
args, out, skip = shlex.split (e["command"]), [], False
for a in args:
    if a == "-o" or skip:
        skip = not skip
        continue
    out.append (a)
out.insert (1, "-DCUBRID_DEBUG")
out.append ("-fsyntax-only")
print ("cd", shlex.quote (e["directory"]), "&&", shlex.join (out))
EOF
```

standalone (SA_MODE) 변형도 같은 방식으로 확인할 수 있다 — 위 3 단계에서 `"SERVER_MODE"` 를 `"SA_MODE"` 로 바꾼다.

### N5 — 미초기화 VPID 출력

```bash
# 1) 대입 지점이 없음을 확인한다 (선언 :15255, 사용 :15271 사이에 vpid 대입이 없다)
sed -n '15252,15276p' src/storage/page_buffer.c

# 2) 같은 일을 하는 정상 함수와 대조한다 (:15209-15210 에 대입이 있다)
sed -n '15202,15216p' src/storage/page_buffer.c
```

```bash
# 3) 런타임 관측: TDE 볼륨을 쓰는 debug 빌드에서 로그를 켠다
#    cubrid.conf 의 [common] 아래 er_log_tde=yes 를 넣고 서버를 재기동한 뒤,
#    TDE 테이블에 페이지 dealloc 이 일어나는 트랜잭션을 rollback 하고
#    체크포인트 전에 서버를 kill -9 한 다음 재기동해 복구 redo 를 유발한다.
grep -n 'reset tde bit in pflag' $CUBRID/log/server/*_*.err
```

## Expected Result

- N4: 3 단계 문법 검사가 오류 없이 끝나고, `CUBRID_DEBUG` 를 정의한 빌드로 `pgbuf_dump_if_any_fixed` 진단을 쓸 수 있다.
- N5: 3 단계 로그의 `VPID = %d|%d` 가 실제로 dealloc 이 취소된 페이지의 volid|pageid 와 일치한다. `pgbuf_rv_dealloc_undo` 가 남긴 같은 문구의 로그와 값이 같아야 한다.

## Actual Result

N4 의 3 단계는 오류 13건으로 실패한다 (GCC 16.1.1, SERVER_MODE 변형). SA_MODE 변형은 11건인데, 비-SERVER_MODE 에서 `pthread_mutex_lock(a)` 이 `0` 으로, `pthread_mutex_unlock(a)` 이 빈 문자열로 치환되면서(`:100-101`) 인자가 평가되지 않아 `volinfo_mutex` 관련 2건이 빠지는 차이뿐이다.

```
page_buffer.c:3284:11: error: 'consistenet_str' was not declared in this scope; did you mean 'consistent_str'?
page_buffer.c:11321:40: error: 'PGBUF_BUFFER_POOL' {aka 'struct pgbuf_buffer_pool'} has no member named 'volinfo_mutex'
page_buffer.c:11322:93: error: 'PGBUF_BUFFER_POOL' ... has no member named 'last_perm_volid'
page_buffer.c:11323:30: error: 'PGBUF_BUFFER_POOL' ... has no member named 'num_permvols_tmparea'
page_buffer.c:11325:18: error: 'PGBUF_BUFFER_POOL' ... has no member named 'permvols_tmparea_volids'
page_buffer.c:11328:34: error: 'PGBUF_BUFFER_POOL' ... has no member named 'num_permvols_tmparea'
page_buffer.c:11334:52: error: 'PGBUF_BUFFER_POOL' ... has no member named 'permvols_tmparea_volids'
page_buffer.c:11338:37: error: 'PGBUF_BUFFER_POOL' ... has no member named 'volinfo_mutex'
page_buffer.c:11349:19: error: 'PGBUF_BCB' {aka 'struct pgbuf_bcb'} has no member named 'fcnt'
page_buffer.c:11369:52: error: 'PGBUF_BCB' {aka 'struct pgbuf_bcb'} has no member named 'zone'
page_buffer.c:11370:11: error: 'consistenet_str' was not declared in this scope; did you mean 'consistent_str'?
page_buffer.c:11444:64: error: invalid conversion from 'const PGBUF_ATOMIC_LATCH*' to 'PGBUF_ATOMIC_LATCH*' [-fpermissive]
page_buffer.c:11468:21: error: invalid conversion from 'const PGBUF_ATOMIC_LATCH*' to 'PGBUF_ATOMIC_LATCH*' [-fpermissive]
```

N5 는 `:15255` 와 `:15271` 사이에 `vpid` 를 대입하는 코드가 없어, 조건이 맞으면 스택에 남아 있던 값이 그대로 `VPID = %d|%d` 로 찍힌다. `pgbuf_rv_dealloc_undo` 가 같은 문구로 남긴 로그와 볼륨·페이지 번호가 어긋난다.

## Additional Information

- 두 결함은 발현 조건과 파일 위치가 다르지만, 둘 다 debug 전용 코드가 리팩터링·복사 과정에서 검증 없이 방치된 사례이고 수정 규모가 작아 하나의 PR 로 묶는다. 리뷰에서 분리를 요구하면 N4 와 N5 로 나눈다.
- `pgbuf_dump` 의 출력 헤더(`:11341-11342`)는 `Fcnt LatchMode D A F Zone Lsa consistent` 순서인데 현재 코드가 그 순서로 인자를 넘기고 있어, 필드 접근만 고치면 열과 값의 대응은 유지된다.
- 부모 EPIC: CBRD-27193 (page buffer 안정성 개선). 이 이슈는 그 표의 A5 항목이다.
- `CUBRID_DEBUG` 는 `src/` 안 67개 파일에서 참조되며, 이 이슈는 `page_buffer.c` 만 다룬다. 다른 파일도 같은 상태인지는 확인하지 않았다.

### 참고 코드

| 위치 | 내용 |
|---|---|
| `page_buffer.c:11302-11384` | `pgbuf_dump` — 컴파일 오류 10건이 모인 함수 |
| `page_buffer.c:11258-11294` | `pgbuf_dump_if_any_fixed` — 현행 접근자를 올바르게 쓰는 호출자 |
| `page_buffer.c:3278-3279` | `pgbuf_unfix_all` — latch/zone 문자열 출력의 정답 형태 |
| `page_buffer.c:11406-11487` | `pgbuf_is_consistent` — const 위반 2건 |
| `page_buffer.c:15252-15276` | `pgbuf_rv_dealloc_undo_compensate` — 미초기화 VPID |
| `page_buffer.c:15202-15241` | `pgbuf_rv_dealloc_undo` — VPID 를 채우는 원본 |
| `src/transaction/recovery.c:802-807` | `RVPGBUF_COMPENSATE_DEALLOC` 복구 함수 등록 |
