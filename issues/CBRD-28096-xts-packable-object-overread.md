# [Query] xts_save_packable_object가 저장 프로시저 시그니처를 XASL 스트림에 복사할 때 원본 블록 뒤 4바이트를 더 읽는 문제

**한 줄 요약**: develop `e64a04a79a`를 AddressSanitizer(ASan) 디버그 빌드로 돌린 회귀 실행에서 발견한 결함이다. `xts_save_packable_object`는 4바이트 길이 머리를 포함한 `size`만큼 `memcpy`를 하므로, 저장 프로시저(Java SP, PL/CSQL)를 호출하는 질의를 XASL로 직렬화할 때마다 팩 버퍼 끝을 4바이트 넘어 읽는다. 복사 길이를 팩 결과 길이에 맞게 고쳐야 한다.

## Issue Triage

**이슈 수행 목적**: 저장 프로시저 시그니처를 XASL 스트림에 저장할 때 원본 팩 버퍼와 예약한 스트림 영역 안에서만 읽고 쓰게 한다.

**이슈 수행 이유**: `xts_save_packable_object`는 `size = 팩 길이 + OR_INT_SIZE`로 계산한 뒤, 길이 머리 4바이트를 쓰고 나서 다시 `size` 바이트를 복사한다. 원본 블록 크기는 팩 길이와 같으므로 매번 4바이트를 더 읽는다. ASan 빌드에서 Java SP 하나를 호출하는 `SELECT`만으로 `heap-buffer-overflow`가 재현되었고, csql이 그 자리에서 중단되었다. 이전 ASan 회귀 실행에서는 CAS도 같은 위치에서 중단되었다.

**영향**: ASan 빌드에서는 저장 프로시저 호출이 들어 있는 질의를 XASL로 직렬화할 때마다 클라이언트가 중단된다. 그래서 PL/CSQL과 Java SP 테스트를 ASan으로 돌릴 수 없고, 같은 실행에서 뒤따르는 다른 메모리 오류를 찾는 일도 막힌다. 일반 릴리스 빌드에서는 인접한 힙 바이트 4개를 읽어 스트림에 복사할 뿐이며, 코드상으로는 충돌이나 스트림 손상으로 이어지는 일반 경로를 찾지 못했다(아래 분석, 추론). 다만 정의되지 않은 동작이고, 시그니처가 아주 큰 경우에는 스트림 버퍼 끝을 넘어 쓸 수 있는지 ANALYSIS에서 확인해야 한다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

XASL은 클라이언트(csql, CAS)가 만든 질의 실행 계획이고, `xts_*` 함수는 이를 서버로 보낼 바이트 스트림으로 직렬화한다. 저장 프로시저 호출이 들어 있는 질의는 `xts_process_sp_type`이 시그니처(`PL_SIGNATURE_TYPE`)를 `xts_save_packable_object`로 스트림에 저장한다.

```c
/* src/query/xasl_to_stream.c:4215-4244 (develop e64a04a79a) */
static int
xts_save_packable_object (const cubpacking::packable_object & po)
{
  ...
  packing_packer packer;
  cubmem::extensible_block eb;
  packer.set_buffer_and_pack_all (eb, po);

  size = packer.get_current_size () + OR_INT_SIZE;

  offset = xts_reserve_location_in_stream (size);
  ...
  ptr = &xts_Stream_buffer[offset];
  ptr = or_pack_int (ptr, size);
  memcpy (ptr, eb.get_ptr (), size);

  return offset;
}
```

- `set_buffer_and_pack_all`은 `eb`를 팩 길이와 정확히 같은 크기로 할당한다(`src/base/packer.hpp:399-406`, `src/base/mem_block.cpp:38`의 `new char[size]`).
- `size`는 팩 길이에 길이 머리 4바이트를 더한 값이다. `memcpy`는 원본에서 `size` 바이트를 읽으므로 `eb` 끝을 4바이트 넘는다.
- 쓰기 쪽도 같은 오차가 있다. 예약 영역은 `size`를 8바이트로 올림한 크기인데, 실제로는 `4 + size` 바이트를 쓴다. 팩 길이를 8로 나눈 나머지가 1~4이면 예약 영역 뒤 1~4바이트를 더 쓴다(코드에서 계산한 추론, ASan은 먼저 걸린 읽기에서 멈추므로 관찰하지 못함). 재현 사례의 팩 길이 72는 나머지가 0이라 쓰기는 예약 영역(80바이트) 안에서 끝난다.
- 읽는 쪽 `stx_build_pl_sig`(`src/query/stream_to_xasl.c:3176-3185`)는 저장된 `size`를 `packing_unpacker`의 범위로만 쓰고 필요한 만큼만 언팩한다. 따라서 뒤에 붙은 4바이트는 읽히지 않는다(코드 확인에 따른 추론).
- 같은 함수는 메서드 호출 시그니처 배열(`src/query/xasl_to_stream.c:5669`)에도 쓰인다. 이 경로는 실행하지 않았다.

### 도입 시점

`git log -L`로 확인한 결과, 이 함수는 `1ea4a86e0a`([CBRD-25184] PL/CSQL phase-1 internal release, #5438, 2024-12-12)에서 현재 형태로 추가된 뒤 바뀌지 않았다. `v11.4`, `v11.4.5`, `v11.0.15` 태그에도 같은 `memcpy (ptr, eb.get_ptr (), size)` 줄이 있다(소스 확인만, 해당 버전 빌드로 실행하지 않음).

### 릴리스 빌드에 미치는 영향 (추론)

- 범위 밖 읽기: 원본 블록은 `operator new[]`로 할당되고, CUBRID는 이를 `malloc`으로 처리한다(`src/base/memory_wrapper.cpp:98`). 작은 블록 뒤 4바이트는 같은 힙 영역 안이라 매핑되지 않은 페이지를 읽지 않는다. 블록이 glibc의 mmap 임계값(기본 128KiB) 이상이고 끝이 페이지 경계와 맞을 때만 SIGSEGV 가능성이 있는데, 시그니처가 그만큼 커지는 경로는 찾지 못했다.
- 스트림 손상: 넘쳐 쓴 1~4바이트는 아직 예약하지 않은 스트림 공간에 들어가고, 이후 예약된 객체가 그 자리를 덮어쓴다. 예외는 `xts_reserve_location_in_stream`(`src/query/xasl_to_stream.c:9099`)이 정확히 필요한 만큼만 버퍼를 늘려 여유가 0이 되는 경우다. 이 경우 넘친 바이트가 `xts_Stream_buffer` 할당 범위 밖에 쓰인다. 이렇게 되려면 한 번에 필요한 확장량이 16KiB(`STREAM_EXPANSION_UNIT`)와 현재 스트림 크기의 절반보다 커야 하므로 시그니처가 16KiB 이상이어야 한다. 실제로 가능한지는 ANALYSIS 확인 사항이다.
- 스트림에는 원본 블록 뒤 힙 바이트 4개가 그대로 복사되어 들어간다. 이 바이트를 비교하거나 해시하는 소비자가 있는지는 확인하지 않았다.

### Test Build

- CUBRID 11.5.0.2802 (64bit debug build), develop `e64a04a79a`, 소스 변경 없음.
- GCC 11.5.0, Linux x86_64 (RHEL 9 계열).
- ASan 빌드 옵션: `CMAKE_C_FLAGS_DEBUG`, `CMAKE_CXX_FLAGS_DEBUG`에 `-O1 -ggdb3 -fsanitize=address -fno-omit-frame-pointer -fno-optimize-sibling-calls`, 링커 플래그에 `-fsanitize=address`.
- 설치본의 `cubrid.conf`에 `use_system_malloc=yes`가 있었다. 범위 밖으로 읽힌 블록은 `operator new[]`로 할당되며 이 파라미터의 영향을 받는 `db_private_alloc` 경로가 아니므로, 이 설정 없이도 같은 결과가 나올 것으로 본다(추론, 실행하지 않음).

### Repro

SA 모드 csql로 재현했다. 서버나 PL 서버는 필요 없다. Java 클래스가 없어도 되는데, 실행 전 XASL 직렬화 단계에서 오류가 나기 때문이다.

```sh
cmake -S . -B build_asan -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_FLAGS_DEBUG="-O1 -ggdb3 -fsanitize=address -fno-omit-frame-pointer -fno-optimize-sibling-calls" \
  -DCMAKE_CXX_FLAGS_DEBUG="-O1 -ggdb3 -fsanitize=address -fno-omit-frame-pointer -fno-optimize-sibling-calls" \
  -DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address -DCMAKE_SHARED_LINKER_FLAGS=-fsanitize=address \
  -DCMAKE_INSTALL_PREFIX="$CUBRID"
cmake --build build_asan --target install

export ASAN_OPTIONS=log_path=$PWD/asan:detect_leaks=0:symbolize=1
mkdir xtsdb && cd xtsdb
cubrid createdb --db-volume-size=64M --log-volume-size=64M xtsdb en_US

cat > repro.sql <<'EOF'
CREATE FUNCTION xts_f () RETURN INT AS LANGUAGE JAVA NAME 'Xts.f() return int';
SELECT xts_f ();
EOF
csql -S -u dba xtsdb -i repro.sql
cubrid deletedb xtsdb
```

### Expected Result

`SELECT xts_f ()`를 직렬화할 때 ASan 오류가 없다. 클래스가 없으므로 실행 단계의 SP 오류만 나야 한다.

### Actual Result

`CREATE FUNCTION`은 성공하고, `SELECT`에서 csql이 ASan 보고와 함께 종료된다(exit 1). 2026-11-13에 실행해 관찰했다.

```text
==467573==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x60700000b908 at pc 0x7f682d23a4d7 bp 0x7ffe9b5a9fe0 sp 0x7ffe9b5a9788
READ of size 76 at 0x60700000b908 thread T0
    #0 0x7f682d23a4d6 in __interceptor_memcpy (/lib64/libasan.so.6+0x3a4d6)
    #1 0x7f6828428b7e in xts_save_packable_object src/query/xasl_to_stream.c:4241
    #2 0x7f682842b7bb in xts_process_sp_type src/query/xasl_to_stream.c:6293
    #3 0x7f682842b948 in xts_save_sp_type src/query/xasl_to_stream.c:659
    #4 0x7f682842f279 in xts_pack_regu_variable_value src/query/xasl_to_stream.c:5888
    #5 0x7f682842b0de in xts_process_regu_variable src/query/xasl_to_stream.c:5829
    #6 0x7f682842b35d in xts_save_regu_variable src/query/xasl_to_stream.c:1408
    #7 0x7f682842b624 in xts_save_regu_variable_list src/query/xasl_to_stream.c:2751
    #8 0x7f682842ba8d in xts_process_outptr_list src/query/xasl_to_stream.c:4705
    #9 0x7f682842bc2e in xts_save_outptr_list src/query/xasl_to_stream.c:1204
    #10 0x7f6828429ad1 in xts_process_xasl_node src/query/xasl_to_stream.c:3109
    #11 0x7f682842ad9e in xts_save_xasl_node src/query/xasl_to_stream.c:1780
    #12 0x7f682843372b in xts_map_xasl_to_stream(xasl_node const*, xasl_stream*) src/query/xasl_to_stream.c:359
    #13 0x7f682807a71b in do_select_internal src/query/execute_statement.c:15213
    #14 0x7f682808d0cf in do_select(parser_context*, parser_node*) src/query/execute_statement.c:15102
    #15 0x7f68280b8046 in do_statement(parser_context*, parser_node*) src/query/execute_statement.c:3737
    #16 0x7f6827ab1ca0 in db_execute_and_keep_statement_local src/compat/db_vdb.c:3551
    #17 0x7f6827ab4208 in db_execute_statement_local(db_session*, int, db_query_result**) src/compat/db_vdb.c:5452
    #18 0x7f6827ab4366 in db_execute_statement src/compat/db_vdb.c:5488
    #19 0x7f682795a3ac in csql_execute_statements src/executables/csql.c:2355

0x60700000b908 is located 0 bytes to the right of 72-byte region [0x60700000b8c0,0x60700000b908)
allocated by thread T0 here:
    #0 0x7f682d2b64d7 in operator new[](unsigned long) (/lib64/libasan.so.6+0xb64d7)
    #1 0x7f6827ac1db3 in cubmem::standard_alloc(cubmem::block&, unsigned long) src/base/mem_block.cpp:38
    #6 0x7f68279a87d8 in cubmem::extensible_block::extend_by(unsigned long) src/base/mem_block.hpp:373
    #7 0x7f68279a8812 in cubmem::extensible_block::extend_to(unsigned long) src/base/mem_block.hpp:383
    #8 0x7f6828433fee in void cubpacking::packer::set_buffer_and_pack_all<cubmem::extensible_block, cubpacking::packable_object const&>(...) src/base/packer.hpp:402
    #9 0x7f6828428b1b in xts_save_packable_object src/query/xasl_to_stream.c:4229
    #10 0x7f682842b7bb in xts_process_sp_type src/query/xasl_to_stream.c:6293
```

팩 길이 72바이트 블록에서 76바이트(`size` = 72 + 4)를 읽어 블록 끝을 4바이트 넘었다. 경로는 빌드 디렉터리 기준으로 줄였고, 할당 스택의 `std::function` 내부 프레임(#2~#5)은 생략했다.

### Additional Information

- 같은 ASan 빌드로 SQL 회귀 `_05_plcsql/.../_05_bug_fix`(PL/CSQL)를 CS 모드로 돌렸을 때 CAS에서 같은 위치의 보고가 17번 나왔다. 이 실행은 별도로 했고, 이번 이슈에서 다시 돌리지는 않았다.
- 같은 실행에서 함께 나온 다른 ASan 보고는 [CBRD-27875](https://jira.cubrid.org/browse/CBRD-27875)(`do_prepare_delete`/`do_prepare_update`의 stack-use-after-scope), [CBRD-28084](https://jira.cubrid.org/browse/CBRD-28084)(`sm_count_tokens`)로 이미 등록되어 있으며 이 결함과는 위치와 원인이 다르다.
- 후보 수정 방향(원래 보고자의 제안, 결정 아님): 복사 길이를 `size - OR_INT_SIZE`(곧 `packer.get_current_size ()`)로 줄인다. 이 경우 읽기와 쓰기 오차가 함께 사라진다. 저장되는 길이 머리 값을 바꿀지는 `stx_build_pl_sig`와의 호환을 보고 ANALYSIS에서 정한다.

### ANALYSIS 확인 사항

- 16KiB 이상인 시그니처를 만들 수 있는가. 가능하면 스트림 버퍼 끝을 넘어 쓰는 경로가 실제로 열리는지 확인한다.
- 메서드 호출 경로(`xasl_to_stream.c:5669`)와 PL/CSQL 함수 호출도 같은 보고를 내는지 실행으로 확인한다.
