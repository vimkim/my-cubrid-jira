# [PL] pl_status_server가 new[]로 할당된 응답 버퍼를 free()로 해제해, ASan 빌드에서 cubrid pl status가 실행 중인 PL 서버를 "not running"으로 보고하는 문제

**한 줄 요약**: develop `e64a04a79a`의 AddressSanitizer(ASan) 빌드 실행에서 발견한 결함이다. `cub_pl status`(`src/executables/pl.cpp`의 `pl_status_server`)는 `operator new[]`로 할당된 PL 서버 응답 버퍼를 `free()`로 해제한다. ASan 빌드에서는 이 해제에서 프로세스가 중단되어 `cubrid pl status`가 살아 있는 PL 서버를 "not running"으로 보고한다. 일반 빌드에서는 C++ 표준상 정의되지 않은 동작(undefined behavior)이다. 할당과 해제의 짝을 맞춰야 한다.

## Issue Triage

**이슈 수행 목적**: `pl_status_server`가 PL 서버 응답 버퍼를 할당 방식에 맞게 해제해, ASan 빌드에서도 `cubrid pl status`가 PL 서버 상태를 올바르게 출력하고 일반 빌드의 정의되지 않은 동작을 없앤다.

**이슈 수행 이유**: 응답 버퍼는 `cubpl::connection::receive_buffer`가 `cubmem::extensible_block`의 기본 할당자(`cubmem::standard_alloc`, `new char[]`)로 만든다. `pl_status_server`는 이를 `free_and_init (buffer.ptr)`(`free()`)로 해제한다. ASan 빌드에서 `cubrid pl status`를 직접 실행해 같은 위치의 `alloc-dealloc-mismatch (operator new [] vs free)` 보고 10건과 "not running" 출력을 재현했다. 그동안 PL 서버 프로세스는 계속 살아 있었다.

**영향**: ASan 빌드로 CUBRID를 검증하는 개발자와 QA는 `cubrid pl status`의 결과를 믿을 수 없다. 출력이 "not running"이고 종료 코드가 1이므로, 이 명령을 쓰는 테스트는 PL 서버가 정상이어도 실패하고 ASan 보고가 10건씩 쌓인다. 실패 판정까지 1초 간격 재시도 10회를 거친다. 일반(release/debug) 빌드에서는 glibc가 이 짝을 검사하지 않아 증상이 드러나지 않을 것으로 보인다(추론, 일반 빌드에서 실행하지 않음). 그래도 정의되지 않은 동작이며, 할당자를 바꾸면 메모리 손상으로 이어질 수 있다. 고객 환경에서 관찰된 증상은 없다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

`cubrid pl status <db>`는 `src/executables/util_service.c`의 `process_pl_status`에서 처리한다. 이 함수는 먼저 `cub_pl ping <db>`로 PL 서버가 응답하는지 확인한다. 응답하면 `cub_pl status <db>`를 실행하고, 이 자식 프로세스가 0이 아닌 값으로 끝나면 1초 간격으로 다시 시도한다. 최대 `WAIT_TIMEOUT_CUB_PL`(10)회 시도한 뒤에도 실패하면 `++ cubrid pl '<db>' is not running.`을 출력한다.

`cub_pl status`는 `pl_status_server`를 실행한다. 이 함수는 PL 서버에 `SP_CODE_UTIL_STATUS` 요청을 보내고 응답을 `cubmem::block buffer`에 받는다.

```cpp
/* src/sp/pl_connection.cpp:390-411 (develop e64a04a79a), connection::receive_buffer */
    cubmem::extensible_block ext_blk;
    ext_blk.extend_to (res_size);
    ...
    cubmem::block blk (res_size, ext_blk.release_ptr());
    b = std::move (blk);
```

```cpp
/* src/base/mem_block.cpp:34-40, extensible_block의 기본 할당자 STANDARD_BLOCK_ALLOCATOR */
  standard_alloc (block &b, size_t size)
  {
    if (b.ptr == NULL || b.dim == 0)
      {
	b.ptr = new char[size];
```

```cpp
/* src/executables/pl.cpp:564-567, pl_status_server */
  if (buffer.ptr)
    {
      free_and_init (buffer.ptr);
    }
```

- `receive_buffer`가 넘겨 준 메모리는 `new char[]`로 할당되었다. 이 메모리의 짝은 `delete[]`다(`cubmem::block::freemem`, `cubmem::standard_dealloc`).
- `free_and_init`은 `free()`를 호출하므로 할당과 해제의 짝이 맞지 않는다.
- ASan은 이 해제에서 오류를 보고하고 `cub_pl`을 중단한다. `process_pl_status`는 비정상 종료를 실패로 처리하고 재시도한 뒤 "not running"을 출력한다.
- 상태 정보(`pl_dump_status`)는 해제 전에 stdout에 쓰인다. 이번 재현에서는 stdout을 파일로 받았고, 중단 때문에 버퍼가 비워지지 않아 상태 정보가 출력되지 않았다. 터미널에서 실행하면 줄 단위 버퍼링이므로 상태 정보가 시도마다 출력된 뒤 "not running"이 나올 수 있다(추론, 터미널에서 실행하지 않음).

### 도입 시점

[CBRD-25097](https://jira.cubrid.org/browse/CBRD-25097)(PL/CSQL phase-0 internal release, 커밋 `9abf046090`, 2024-04-17)에서 생겼다. 이 커밋 전에는 `javasp_status_server`(현재 `pl_status_server`)가 응답 버퍼를 `malloc`으로 직접 할당했고 `free_and_init`으로 해제했다. 이 커밋이 버퍼를 `cubmem::block`으로 바꾸고 `cubmethod::mcon_read_data_from_java`로 받게 했다. 이 함수는 이미 `extensible_block`(`new char[]`)으로 할당했지만, 해제 코드는 `free_and_init`으로 남았다. 이후 [CBRD-25184](https://jira.cubrid.org/browse/CBRD-25184)(`1ea4a86e0a`)가 수신 함수를 `cubpl::connection::receive_buffer`로 옮겼지만 할당 방식은 같다.

`9abf046090`은 `v11.4` 태그와 `release/11.4` 브랜치에 포함된다. 11.4 계열 소스에도 같은 코드가 있을 것으로 보이나, 11.4 빌드에서 실행하지 않았다.

### 같은 패턴 검사

`src/executables/pl.cpp`와 `src/sp/pl_*` 파일에서 `free`, `free_and_init`, `delete[]`, `freemem` 호출을 모두 확인했다. 할당과 해제의 짝이 맞지 않는 곳은 `pl.cpp:566` 하나다.

| 위치 | 해제 대상 | 판정 |
|---|---|---|
| `src/executables/pl.cpp:566` `pl_status_server` | `receive_buffer` 응답(`new char[]`)을 `free_and_init` | 불일치 (이 이슈) |
| `src/executables/pl.cpp:601` `pl_ping_server` | `receive_buffer` 응답을 `delete [] ping_blk.ptr` | 일치 |
| `src/sp/pl_sr.cpp:617`, `:647` | `receive_buffer` 응답을 `cubmem::block::freemem`(`delete[]`) | 일치 |
| `src/sp/pl_executor.cpp`, `pl_compile_handler.cpp`, `pl_execution_stack_context.cpp`, `pl_connection.hpp:146` | 수신 블록을 `freemem` | 일치 |
| `src/sp/pl_sr_jvm.cpp:279` | `malloc` 버퍼를 `free_and_init` | 일치 |
| `src/sp/pl_sr_jvm.cpp:563`, `:571` | `strdup` 결과를 `free` | 일치 |

같은 파일의 `pl_ping_server`는 같은 수신 결과를 `delete[]`로 해제한다. 관련 후보로 기록할 다른 위치는 찾지 못했다.

### Test Build

- 소스: CUBRID develop `e64a04a79a` (`CUBRID 11.5.0 (11.5.0.2802) (64 debug build)`).
- 빌드: GCC 11.5.0 (Linux x86_64), `CMAKE_BUILD_TYPE=Debug`. 컴파일 옵션 `-O1 -ggdb3 -fsanitize=address -fno-omit-frame-pointer -fno-optimize-sibling-calls`, 링크 옵션 `-fsanitize=address`. CUBRID에는 ASan 빌드 옵션이 없으므로 `CMAKE_C_FLAGS_DEBUG`, `CMAKE_CXX_FLAGS_DEBUG`, `CMAKE_EXE_LINKER_FLAGS`, `CMAKE_SHARED_LINKER_FLAGS`로 지정했다.
- `cubrid.conf`: 다른 인스턴스와 겹치지 않는 `cubrid_port_id`, `[service] service=server`. PL은 기본값(`stored_procedure=yes`, UDS 모드)이다.

### Repro

위 ASan 빌드를 설치한 `$CUBRID` 환경에서 실행한다. `ASAN_OPTIONS`의 `log_path`는 절대 경로로 둔다.

```sh
export ASAN_OPTIONS=log_path=$PWD/asanlog/asan:detect_leaks=0:symbolize=1:abort_on_error=0:disable_coredump=1
mkdir -p asanlog plstdb && cd plstdb
cubrid createdb --db-volume-size=20M --log-volume-size=20M plstdb en_US
cubrid server start plstdb
cubrid pl status plstdb >status.out 2>&1; echo "rc=$?"; cat status.out
ls ../asanlog
cubrid server stop plstdb
cubrid service stop
cubrid deletedb plstdb
```

### Expected Result

PL 서버가 실행 중이므로 상태 정보가 출력되고 종료 코드는 0이며, ASan 보고는 없다. 아래는 같은 빌드에서 `ASAN_OPTIONS`에 `alloc_dealloc_mismatch=0`만 추가해 이 검사를 끄고 실행한 결과다.

```text
@ cubrid pl status
Procedural Language Server (plstdb, pid 462476, UDS)
VM arguments :
 -------------------------------------------------
  -ea
  -XX:+HeapDumpOnOutOfMemoryError
  ...
 -------------------------------------------------
```

### Actual Result

stdout을 파일로 받아 실행했다. `cubrid pl status`는 종료 코드 1로 끝나며 다음을 출력한다. 이때 `cub_pl plstdb`(pid 462476)는 계속 실행 중이었다.

```text
@ cubrid pl status
++ cubrid pl 'plstdb' is not running.
```

ASan 보고 파일이 10개(재시도 횟수와 같음) 생기며 모두 같은 내용이다.

```text
==480554==ERROR: AddressSanitizer: alloc-dealloc-mismatch (operator new [] vs free) on 0x6120000013c0
    #0 0x7f99b18b46b7 in free (/lib64/libasan.so.6+0xb46b7)
    #1 0x5617db02e3f8 in pl_status_server src/executables/pl.cpp:566
    #2 0x5617db02f603 in main src/executables/pl.cpp:336

0x6120000013c0 is located 0 bytes inside of 284-byte region [0x6120000013c0,0x6120000014dc)
allocated by thread T0 here:
    #0 0x7f99b18b64d7 in operator new[](unsigned long) (/lib64/libasan.so.6+0xb64d7)
    #1 0x7f99af4c1db3 in cubmem::standard_alloc(cubmem::block&, unsigned long) src/base/mem_block.cpp:38
    ...
    #7 0x5617db02fdc0 in cubmem::extensible_block::extend_to(unsigned long)
    #8 0x7f99af656403 in cubpl::connection::receive_buffer(cubmem::block&, std::function<int ()> const*, int) src/sp/pl_connection.cpp:392
    #9 0x7f99af65669e in cubpl::connection::receive_buffer(cubmem::block&) src/sp/pl_connection.cpp:331
    #10 0x5617db02e686 in pl_status_server src/executables/pl.cpp:524
    #11 0x5617db02f603 in main src/executables/pl.cpp:336

SUMMARY: AddressSanitizer: alloc-dealloc-mismatch (/lib64/libasan.so.6+0xb46b7) in free
==480554==ABORTING
```

이 재현 전에 같은 빌드로 수행한 별도 ASan 실행 세션에서도 같은 스택의 보고가 20건 모였다.

### Additional Information

- 수정 후보: `pl_status_server`의 해제를 `delete[]` 또는 `buffer.freemem ()`으로 바꾸면 할당과 짝이 맞는다. `pl_ping_server`가 이미 `delete[]`를 쓴다. 최종 방법은 ANALYSIS에서 정한다.
- 관련 이슈: [CBRD-26773](https://jira.cubrid.org/browse/CBRD-26773)도 `cubrid pl status`가 실행 중인 PL 서버를 "not running"으로 보고한 문제였다. 그 원인은 다른 DB의 `stored_procedure=no` 설정이 다음 DB로 넘어가는 시스템 파라미터 처리였고, 이미 수정되었다. 이 이슈는 그 수정 이후에도 남은 별개의 원인이다.
- 관련 이슈: [CBRD-27507](https://jira.cubrid.org/browse/CBRD-27507)은 `cub_server`에서 전역 `operator new`/`operator delete` 교체가 비대칭이어서 생긴 valgrind `Mismatched free()` 보고를 다룬다. `cub_pl status`는 서버 모드 메모리 래퍼를 쓰지 않으며, 위 ASan 스택의 할당은 libasan의 `operator new[]`이다. 따라서 이 보고는 그 래퍼 문제가 아니라 `pl.cpp`의 해제 코드 문제다.
- ANALYSIS 확인 사항: ASan 빌드로 `cubrid pl status`를 호출하는 QA 시나리오가 있는지, 있다면 이 결함 때문에 실패로 판정된 적이 있는지 확인하지 않았다.
