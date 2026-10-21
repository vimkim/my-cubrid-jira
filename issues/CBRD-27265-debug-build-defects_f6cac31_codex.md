# [PGBUF] 추가 진단 빌드와 TDE 복구 로그의 결함 2건을 수정한다

## Issue Triage

**이슈 수행 목적**: 페이지 버퍼의 추가 진단 코드를 현행 자료구조로 컴파일할 수 있게 하고, 페이지 할당 해제의 보상 복구 로그가 초기화된 실제 대상 VPID를 사용하게 한다.

**이슈 수행 이유**: `CUBRID_DEBUG`를 추가한 경우에만 컴파일되는 덤프·일관성 검사 경로에 삭제된 필드 참조, 식별자 오타, const 인자 불일치가 남아 있다. 별도로 `pgbuf_rv_dealloc_undo_compensate`는 `!NDEBUG` 빌드에서 복원한 페이지의 암호화 비트가 설정되어 있고 `er_log_tde`가 켜진 경우, 대입하지 않은 지역 `VPID`의 값을 로그 인자로 읽는다. 기준 소스에서 두 결함의 코드 조건을 확인하였다.

**영향**: 추가 진단 모드를 이용하려는 개발자·QA의 빌드와 복구 분석을 방해한다. 일반 Debug 빌드가 첫 결함 때문에 실패한다는 의미는 아니다. 두 번째 결함은 잘못된 페이지 식별 정보로 조사를 오도할 수 있는 미초기화 읽기이며, 현재 자료에는 실제 복구 로그·크래시·저장 데이터 손상의 재현 결과가 없다. 발생 빈도와 영향 릴리스는 미확인이다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 기존 보고와 기준 소스에서 확인한 근거를 바탕으로 작성한 상세 맥락이다. 과거 빌드 보고, 소스 확인 결과, 미실행 검증 계획을 구분한다.

## Description

### 무엇이 문제인가

부모 [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)의 페이지 버퍼 작업 중, 기존 보고서의 N4와 N5에 해당하는 두 진단 결함을 다룬다. 페이지 버퍼는 디스크 페이지를 메모리에 유지하며 fix/unfix로 사용 중인 페이지의 유지·사용 수를 관리한다. BCB(Buffer Control Block)는 버퍼 슬롯의 페이지 식별자, fix 수, 페이지 latch, dirty 상태 등을 관리하는 제어 정보이다. 페이지 latch는 메모리 페이지 접근을 조정하는 수단이며 트랜잭션 lock과 별개이다. VPID는 볼륨 번호와 페이지 번호의 쌍이다.

첫 결함은 `CUBRID_DEBUG`로 감싼 추가 진단 경로의 컴파일 불일치이다. 이 스위치는 `NDEBUG`와 독립적이다. 기준 소스의 GNU CMake Debug 설정은 `CUBRID_DEBUG`를 정의하지 않으며, Release 설정에는 `-DNDEBUG`가 있다. 따라서 CMake의 일반 Debug 설정, `CUBRID_DEBUG`를 따로 추가한 설정, `NDEBUG`를 정의한 설정을 구분해야 한다. 외부 빌드·패키지·모든 CI 환경의 실제 플래그는 별도 확인 대상이다. [기준 빌드 플래그](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/CMakeLists.txt#L219-L242)

| 확인한 불일치 | 기준 소스의 위치와 내용 |
|---|---|
| 없어진 pool 필드 | `pgbuf_dump`가 `volinfo_mutex`, `last_perm_volid`, `num_permvols_tmparea`, `permvols_tmparea_volids`를 계속 참조한다. 현행 `pgbuf_buffer_pool`에는 이 필드들이 없다. [덤프](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L11324-L11342), [pool 정의](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L733-L809) |
| 없어진 BCB 필드와 zone 변환 | `bufptr->fcnt`, `bufptr->zone`를 참조하고 zone에 latch 문자열 함수를 사용한다. 현행 코드는 fix 수를 `atomic_latch`에서 읽고 zone을 `flags`에서 얻는다. [덤프의 접근](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L11348-L11382), [현재 접근 예](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L3248-L3249) |
| 식별자 오타 두 곳 | 선언은 `consistent_str`인데 `pgbuf_unfix_all`과 `pgbuf_dump`가 `consistenet_str`에 대입한다. 앞의 오타는 `!NDEBUG`와 `CUBRID_DEBUG`가 함께 적용되는 분기이다. [unfix_all](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L3215-L3257), [dump](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L11314-L11374) |
| const 인자 불일치 두 곳 | `pgbuf_is_consistent(const PGBUF_BCB *)`가 `get_fcnt(PGBUF_ATOMIC_LATCH *)`를 호출한다. `&bufptr->atomic_latch`의 const를 제거할 수 없어 인자 형식이 맞지 않는다. [검사 함수](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L11409-L11473), [접근자](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L1441-L1447) |

두 번째 결함은 보상 복구의 TDE(Transparent Data Encryption, 데이터 페이지 암호화) 로그에 있다. `pgbuf_rv_dealloc_undo`는 할당 해제를 취소할 페이지를 fix하고 페이지 형식과 `pflag`를 복원한 뒤 `RVPGBUF_COMPENSATE_DEALLOC` 보상 로그를 남긴다. 이 함수는 로그 인자로 쓰는 `vpid`를 먼저 채운다. 반면 보상 적용 함수 `pgbuf_rv_dealloc_undo_compensate`는 `VPID vpid;`를 선언만 하고, `VPID_AS_ARGS(&vpid)`로 읽는다. `VPID`는 기본 초기화가 없는 정수 필드 구조체이며 이 매크로는 `volid`, `pageid`를 그대로 읽는다. [undo와 보상 함수](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L15214-L15287), [VPID 정의·매크로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/compat/dbtype_def.h#L956-L976)

이 읽기는 다음 조건이 모두 성립하고 해당 보상 함수에 도달할 때 발생한다.

1. `NDEBUG`가 정의되지 않아 로그 블록이 포함된다. `CUBRID_DEBUG`는 필요하지 않다. 따라서 이름이 Debug인 빌드에만 한정할 수 없고 실제 컴파일 플래그로 판단한다.
2. 보상 데이터에서 복원한 `pflag`에 `FILEIO_PAGE_FLAG_ENCRYPTED_MASK` 비트가 있다.
3. `er_log_tde`가 true여서 `tde_er_log` 매크로 내부의 `_er_log_debug` 호출과 그 인자 평가가 실행된다. 이 설정은 hidden이며 기본값은 false이다. [로그 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L15274-L15285), [TDE 로그 매크로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/tde.h#L139), [파라미터 정의](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L4608-L4618)

등록상 이 함수는 `RVPGBUF_COMPENSATE_DEALLOC`의 undo 함수 슬롯에 있다. 재기동 redo는 `LOG_COMPENSATE`를 처리할 때 그 undo 함수 슬롯을 선택하므로, 등록 이름만 보고 redo에서 호출되지 않는다고 판단할 수 없다. 다만 특정 SQL·장애 시나리오에서 해당 레코드가 실제 재적용되는지는 실행 증거가 필요하다. [복구 함수 등록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/recovery.c#L796-L807), [보상 레코드 redo 분기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_recovery.c#L3767-L3775), [undo 함수 선택](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_recovery_redo.hpp#L395-L400)

### 왜 문제인가

첫 결함은 버퍼 사용 잔존이나 페이지 내용 불일치를 조사하려고 추가 진단을 켜는 시점에 개발자·QA의 작업을 막는다. `pgbuf_finalize`는 `CUBRID_DEBUG`일 때 `pgbuf_dump_if_any_fixed`를 호출하고, 이 함수는 남은 fix 또는 일관성 검사 결과에 따라 `pgbuf_dump`를 호출한다. unfix의 추가 검증 분기도 검사 수준이 `PGBUF_DEBUG_PAGE_VALIDATION_ALL`이고 내용이 BAD일 때 덤프를 호출한다. 컴파일이 막히면 이 경로를 조사에 바로 쓸 수 없다. [종료 시 호출](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L1839-L1849), [잔존·일관성 검사](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L11251-L11298), [unfix 검사](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L3126-L3149)

이 진단의 결과도 무조건적인 손상 판정은 아니다. 소스는 `pgbuf_dump_if_any_fixed`의 다중 사용자 환경 해석에 주의를 요구하며, dirty 페이지의 메모리·디스크 내용이 같은 경우 `pgbuf_is_consistent`는 `PGBUF_CONTENT_LIKELY_BAD`를 반환한다. dirty는 수정·flush 관리 상태이지 commit이나 디스크 영속 완료와 같은 뜻이 아니다. [진단의 주의사항](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L11255-L11259), [일관성 검사 규칙과 판정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L11397-L11455)

두 번째 결함은 암호화 페이지 복구를 추적하는 로그의 대상 식별을 신뢰할 수 없게 한다. 다만 미초기화 정수 읽기는 C++에서 정의되지 않은 동작이므로, 항상 특정 스택 값이 출력되거나 반드시 undo 로그와 다른 값이 나온다고 보장할 수 없다. 눈에 보이는 로그 불일치를 얻지 못해도 초기화 누락이 해소되는 것은 아니다. 이 지역 `vpid`는 소스상 로그 인자로만 쓰이며 페이지 형식·플래그 복원은 `rcv->pgptr`과 `udata`를 사용한다. 따라서 이 읽기만으로 잘못된 저장 페이지를 선택했다거나 실제 데이터 손상이 발생했다고 결론내릴 근거는 없다. 반대로 실행 결과를 확인하지 않고 영향이 반드시 로그 오염에만 한정된다고 보장할 수도 없다. [보상 함수 전체](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L15264-L15287)

### 왜 해결해야 하는가

추가 진단을 사용할 때마다 현재 자료구조에 맞지 않는 코드를 먼저 고쳐야 하는 상태는 문제 조사 비용을 높인다. TDE 로그를 끄는 방법은 미초기화 인자 평가를 피하지만 복구 추적 정보도 잃는다. 따라서 빌드 가능한 진단 코드와 실제 복구 대상에 대응하는 초기화된 로그 인자가 필요하다. 현재 자료는 즉시성이나 고객 장애 빈도를 산정하기에 부족하지만, 두 결함의 위치와 실행 조건이 구체적이므로 확인과 수정 분석을 시작할 근거가 있다.

## Test Build

| 구분 | 확인 범위 |
|---|---|
| 이번 검토 | CUBRID `f6cac312310f39f46711693da157a08f0e725693`의 고정 소스를 정적으로 확인하였다. 컴파일·서버 실행·복구 재현은 수행하지 않았다. 이 커밋은 분석 기준이며 모든 릴리스의 영향 판정이 아니다. |
| 과거 빌드 보고 | 기존 보고서는 develop `e6ed61e87`, Fedora 44, GCC 16.1.1, Debug 빌드의 실제 컴파일 명령에 `-DCUBRID_DEBUG`를 추가한 문법 검사에서 SERVER_MODE 오류 13건, SA_MODE 오류 11건을 보고한다. 전체 커밋 ID·원시 빌드 산출물은 해당 보고에 제공되지 않는다. [고정된 과거 빌드·재현·진단 기록](https://github.com/vimkim/my-cubrid-jira/blob/da39b0f3ee0bc1c55d2063588c3969a808a95687/issues/CBRD-27265-pgbuf-debug-build-defects_e6ed61e_claude.md#L91-L171) |
| 릴리스·런타임 | 영향 릴리스, 지원 플랫폼별 결과, 두 번째 결함의 실제 복구 로그는 TBD이다. |

과거 오류 건수를 현재 커밋의 재실행 결과로 사용하지 않는다. 과거 SERVER_MODE 진단은 pool 필드 7건, BCB 필드 2건, 오타 2건, const 불일치 2건으로 제시된다. SA_MODE에서 mutex 관련 2건이 줄어드는 설명은 비-SERVER_MODE의 `pthread_mutex_lock(a)`·`unlock(a)` 매크로가 인자를 사용하지 않는 현행 코드와 부합한다. 정확한 진단 수와 문구는 현재 컴파일러·플래그로 다시 기록해야 한다. [과거 진단 원문](https://github.com/vimkim/my-cubrid-jira/blob/da39b0f3ee0bc1c55d2063588c3969a808a95687/issues/CBRD-27265-pgbuf-debug-build-defects_e6ed61e_claude.md#L151-L169), [SA 매크로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L96-L103)

## Repro

### 추가 진단 코드의 컴파일 확인

다음은 미실행 검증 절차이다. GCC/Clang 계열과 프로젝트 빌드 의존성·서브모듈을 갖춘 기준 커밋의 소스 루트에서 실행한다. 개인 preset이나 최상위 심볼릭 링크에 의존하지 않고 CMake가 생성한 실제 명령을 사용한다. 우선 일반 Debug의 빌드·생성 헤더를 준비한 뒤 `page_buffer.c`에만 `CUBRID_DEBUG`를 추가한다. 이 문법 검사는 전체 엔진을 이 스위치로 빌드하거나 실행한 결과를 대신하지 않는다.

```bash
cmake -S . -B build/cbrd-27265-debug \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
cmake --build build/cbrd-27265-debug --target cubrid cubridsa
python3 - <<'PY'
import json
from pathlib import Path
import shlex
import subprocess

entries = json.loads(Path("build/cbrd-27265-debug/compile_commands.json").read_text())
failed = False
for mode in ("SERVER_MODE", "SA_MODE"):
    matches = []
    for entry in entries:
        args = entry.get("arguments") or shlex.split(entry["command"])
        if Path(entry["file"]).name == "page_buffer.c" and any(
            arg == "-D" + mode or arg.startswith("-D" + mode + "=") for arg in args
        ):
            matches.append((entry, args))
    if len(matches) != 1:
        raise SystemExit(f"{mode}: expected one page_buffer.c command, got {len(matches)}")
    entry, args = matches[0]
    out = []
    skip = False
    for arg in args:
        if skip:
            skip = False
            continue
        if arg in ("-o", "-MF", "-MT", "-MQ"):
            skip = True
        elif arg not in ("-c", "-MD", "-MMD", "-MP"):
            out.append(arg)
    print(mode, flush=True)
    result = subprocess.run(out + ["-DCUBRID_DEBUG", "-fsyntax-only"], cwd=entry["directory"])
    failed |= result.returncode != 0
raise SystemExit(1 if failed else 0)
PY
```

일반 Debug 빌드의 실패와 추가 매크로 검사 실패를 구분해서 기록한다. 일반 빌드가 먼저 실패하면 환경·기준 빌드 문제를 해결한 뒤 추가 진단 검사를 진행한다. 결과에는 소스 전체 SHA, OS, 컴파일러 버전, 선택된 두 명령과 진단 출력을 남긴다.

### 보상 복구 로그의 확인

정적 확인은 다음 명령으로 비교할 수 있다.

```bash
sed -n '15214,15287p' src/storage/page_buffer.c
sed -n '956,976p' src/compat/dbtype_def.h
sed -n '139p' src/storage/tde.h
```

런타임 재현은 TBD이다. 기존 보고서의 "암호화 테이블의 할당 해제를 rollback한 뒤 체크포인트 전에 강제 종료·재기동" 절차에는 구체적인 SQL, 데이터·로그 flush 상태, 대상 보상 레코드의 재적용 증거가 없다. 따라서 완료된 재현으로 취급하지 않는다. ANALYSIS에서 격리된 테스트 DB와 `!NDEBUG`, `er_log_tde=yes` 조건을 정하고, 실제 `RVPGBUF_COMPENSATE_DEALLOC` 적용 여부 및 대상 `rcv->pgptr`·로그의 VPID를 함께 기록해야 한다. 정상 undo와 보상 적용 함수가 같은 로그 문구를 쓰므로 문자열 검색만으로 두 호출을 구별해서는 안 된다. [두 로그 위치](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L15240-L15285)

## Expected Result

- 지원하기로 정한 SERVER_MODE·SA_MODE의 `CUBRID_DEBUG` 설정에서 해당 페이지 버퍼 코드가 컴파일되고, 덤프의 fix 수·latch·zone·일관성 열이 현행 상태에 대응한다.
- 보상 복구 로그가 초기화된 값을 사용하며, 로그 VPID가 실제 복구 대상 페이지와 일치한다. 관련 없는 다른 undo 호출의 로그 값과 우연히 같다는 사실만으로 검증하지 않는다.
- 일반 Debug·Release 검증과 추가 진단 검증의 설정·판정을 구분해 기록한다. 추가 진단의 실행 가능성은 컴파일 성공 외에 관련 런타임 경로로 확인한다.

## Actual Result

기준 소스에는 위 표의 컴파일 불일치와 보상 함수의 초기화 누락이 남아 있다. 과거 문법 검사의 13건·11건 결과는 고정된 이전 보고의 결과이다. 이번 검토에서는 현재 빌드 오류 건수, 실제 잘못된 복구 로그, 크래시 또는 저장 데이터 손상을 관측하지 않았다.

## Additional Information

### 분석 범위와 진단 재활성화 조건

현재 확인한 결함은 `src/storage/page_buffer.c`에 모여 있다. 없어진 필드의 덤프 처리, 현행 접근자 사용, const 서명 처리, 실제 대상 VPID를 얻는 방식, CI 컴파일 검사 도입 여부는 ANALYSIS에서 정한다. 기존 보고의 구체 수정안과 하나의 PR로 묶는 제안은 구현 합의로 확인되지 않았다. `pgbuf_get_vpid`는 고정된 페이지의 BCB에서 VPID를 얻는 기존 수단이지만, `rcv->pgptr`에 대한 assert는 호출 계약을 검사하는 코드이며 페이지 유효성이나 런타임 재현을 스스로 증명하지는 않는다. [기존 접근자](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L5124-L5148)

또한 컴파일 결함을 고쳤다는 이유만으로 추가 진단 전체가 안전하게 복구되었다고 결론내리지 않는다. 기존 구조 분석은 `CUBRID_DEBUG`의 guard 위치와 페이지 끝 watermark가 겹치는 문제를 별도로 지적한다. 기준 소스에도 guard는 `page[DB_PAGESIZE]`에 있고, 페이지 크기는 reserved 영역과 watermark를 제외해 산정되며 watermark 위치는 I/O 페이지 끝에서 그 크기만큼 뺀 위치이다. 이는 진단 재활성화 시 함께 판정해야 할 정적 근거이지, 이 이슈의 미초기화 VPID가 데이터 손상을 일으켰다는 증거는 아니다. 이 추가 위험의 수정 포함 여부와 후속 이슈 경계도 ANALYSIS에서 정한다. [기존 구조 분석](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/pgbuf/e6ed61e_claude/01-structures.md#L260-L267), [guard 위치](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L144-L145), [페이지 크기 산정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/storage_common.c#L43-L48), [watermark 위치](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/file_io.h#L184-L198)

부모의 성능 분석·테스트 프레임워크 작업과 검증 방법을 공유할 수 있으나, 그 작업의 완료를 두 결함 분석의 선행 조건으로 두지는 않는다. 다른 파일의 `CUBRID_DEBUG` 경로 전체를 검증한 결과도 아니다.

## Triage Request

추가 진단 경로의 컴파일 불일치와 보상 복구 로그의 미초기화 읽기를 확인하고, 작성자 측에 ANALYSIS를 배정할 것을 요청한다. ANALYSIS에서는 현재 도구 체인의 두 빌드 모드 진단, 실제 보상 재적용 재현, 영향 릴리스, 진단 재활성화의 안전 조건과 검증 범위를 정한다. 우선순위·담당자·구현 방식은 triage와 ANALYSIS에서 결정한다.
