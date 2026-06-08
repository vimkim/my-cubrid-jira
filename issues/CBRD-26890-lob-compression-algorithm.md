# [LOB] internal LOB(4GB) 압축을 위한 새 압축 알고리즘 검토 — LZ4 최대 입력 크기(약 2.11GB) 초과 대응

## 목적 (Purpose)

- internal LOB(최대 4GB)을 압축 저장하려면 현재 엔진이 쓰는 LZ4의 최대 입력 크기(약 2.11GB)를 초과한다 -> LZ4로는 압축 불가.
- 4GB 규모 데이터를 압축할 수 있는 새 압축 알고리즘/구조를 정한다.

## 배경 / 근거 (Background — AS-IS)

- 엔진의 압축은 전부 LZ4 단일이다. 공통 래퍼 `compressor.hpp`의 `cubcompress::compress`/`cubcompress::decompress`가 LZ4 전용(`static_assert`)이라, 입력 상한 `LZ4_MAX_INPUT_SIZE`(0x7E000000, 약 2.11GB)이 엔진 전체의 제약이다.
- LZ4 압축을 쓰는 경로는 세 곳이며, 각각 아래 "압축 코드 흐름"에 도식화한다.
  1. (A) 컬럼 값 압축 — VARCHAR/VARNCHAR 전용.
  2. (B) WAL 로그 레코드 압축 — undo/redo 로그 데이터(레코드 이미지)를 통째로 압축(컬럼 단위 아님).
  3. (C) 백업 압축 — 백업 페이지 단위.
- 컬럼 값 압축 대상인 VARCHAR/VARNCHAR의 최대 길이는 약 1 GiB(`DB_MAX_STRING_LENGTH` = 0x3fffffff)로 LZ4 한계 미만이라, 기존 타입은 한계에 도달하지 않아 문제가 없었다.
- internal LOB 도입(최대 4GB)으로 압축 대상이 처음으로 LZ4 한계를 초과한다. 한계 초과 시 압축을 스킵하고 원본 저장하므로 대형 LOB이 비압축 저장되어 공간 낭비가 발생한다.

## 압축 코드 흐름 (도식)

세 경로 모두 공통 래퍼 `cubcompress::compress<LZ4> / decompress<LZ4>`(`compressor.hpp`)로 수렴하며, `★` 지점이 `LZ4_MAX_INPUT_SIZE` 초과 시 압축이 불가능해지는 한계점이다.

### (A) VARCHAR / VARNCHAR — 컬럼 값 압축

```
[압축] 직렬화(DB_VALUE -> 디스크/RECDES)
 mr_data_writeval_string()                         object_primitive.c
   └ mr_writeval_string_internal()
       └ pr_get_size_and_write_string_to_buffer()
           ├ pr_do_db_value_string_compression()   // DB_VALUE에 LZ4 압축본 캐시(1회: DB_TRIED_COMPRESSION)
           │    └ cubcompress::compress<LZ4>()      compressor.hpp
           └ pr_write_compressed_string_to_buffer() // 디스크 기록: [0xFF][compressed_len][decompressed_len][data]
                (len<255 이면 pr_write_uncompressed_string_to_buffer())
 ★ 크기 게이트: or_put_varchar_internal() / pr_get_compression_length()
     charlen > LZ4_MAX_INPUT_SIZE  ->  압축 스킵, 원본 저장

[해제] 역직렬화(디스크/RECDES -> DB_VALUE)
 mr_data_readval_string()                          object_primitive.c
   └ mr_readval_string_internal()
       ├ or_get_varchar_compression_lengths()      // [compressed_len][decompressed_len] 헤더 파싱
       └ pr_get_compressed_data_from_buffer()
            └ cubcompress::decompress<LZ4>()        compressor.hpp
```

### (B) WAL 로그 레코드 압축 (레코드 이미지 전체)

```
[압축] 로그 append 시 undo/redo 데이터 압축
 prior_lsa_gen_undoredo_record_from_crumbs()       log_append.cpp
   ├ log_diff()                                     log_compress.c  // undo vs redo 차분
   └ log_zip()                                      log_compress.c  // LZ4 압축(레코드 payload 통째)
        └ cubcompress::compress<LZ4>()              compressor.hpp
 ★ log_zip(): length > LZ4_MAX_INPUT_SIZE  ->  압축 불가(false 반환)

[해제] 복구/롤백/복제/vacuum 시 로그 데이터 해제
 log_rv_get_unzip_and_diff_redo_log_data()         log_recovery.c   (복구)
 log_rollback_record() / log_get_undo_record()     log_manager.c    (롤백/undo)
 vacuum_process_log_record()                        vacuum.c         (vacuum)
   └ log_unzip()                                    log_compress.c
        └ cubcompress::decompress<LZ4>()            compressor.hpp
```

### (C) 백업 압축 (백업 페이지 단위)

```
[압축] 백업 수행
 fileio_backup_volume()                            file_io.c
   └ fileio_compress_backup_node()                 file_io.c        // 백업 페이지 LZ4 압축
        └ cubcompress::compress<LZ4>()             compressor.hpp
 ★ 페이지 크기 > LZ4_MAX_INPUT_SIZE 가정 차단(assert) — 실무상 페이지 단위라 미발생

[해제] 복원(restore) 수행
 fileio_decompress_restore_volume()                file_io.c
        └ cubcompress::decompress<LZ4>()           compressor.hpp
```

## 현황 조사 — 가변 타입별 최대 길이 / 압축 적용

| 가변 타입(variable type) | 최대 데이터 길이 | 압축 적용 |
|---|---|---|
| VARCHAR | 약 1 GiB (0x3fffffff byte) | O (LZ4, 컬럼 값) |
| VARNCHAR | 약 1 GiB (0x3fffffff, precision 기준) | O (LZ4, 컬럼 값) |
| VARBIT | 약 128 MiB (0x3fffffff bit) | X |
| CHAR / NCHAR | 2048 (고정) | X |
| BIT (고정) | 약 128 MiB (0x3fffffff bit) | X |
| JSON | 명시적 바이트 상한 미정의(레코드/오버플로 한계 내) (확인 필요) | X |
| SET / MULTISET / SEQUENCE | 컬렉션(요소 합), 단일 바이트 상한 미정의 (확인 필요) | X |
| internal LOB (신규) | 4 GB | 대상이나 현재 LZ4로는 불가 |

> **요지**: 컬럼 값 압축 대상(VARCHAR/VARNCHAR)은 최대 ~1 GiB로 LZ4 한계 안에 있어 지금까지 문제가 없었다. 4GB internal LOB 만이 한계를 넘어 새 압축 방안을 요구한다. (로그(B)·백업(C) 경로도 동일 LZ4 한계를 공유한다.)

## 기대 결과 (Expected Outcome)

- 4GB 규모 internal LOB을 압축 저장할 수 있게 된다 -> 대형 LOB의 공간 낭비 해소.
- 압축 알고리즘이 공통 계층(`compressor.hpp`)에서 확장 가능해져, 향후 다른 대형 데이터/경로에도 일관 적용할 수 있다.

## 상세 내용 (Details — 후보 비교)

권장 순서로 정리한다.

| 순위 | 후보 | 설명 (권장 이유 / 고려사항) |
|---|---|---|
| 1 | Zstandard(zstd) 도입 | 입력 크기를 `size_t`(64비트)로 다뤄 4GB+ 를 단일 호출로 처리 가능 -> 근본 해결. PostgreSQL/RocksDB/ZFS 등 DB·스토리지에서 검증된 채택률, 압축률·속도도 LZ4 대비 우수해 장기적으로 가장 안전. 다만 외부 의존성 추가(빌드·패키징·라이선스)와 디스크 포맷·해제 경로 신설이 필요. |
| 2 | LZ4 frame API 청킹 | 기존 LZ4 생태계를 유지하면서 큰 입력을 블록 단위로 분할 압축(`lz4frame`). 라이브러리 교체가 없어 도입 비용이 낮음. 프레임/청크 메타데이터와 부분(스트리밍) 해제 설계가 필요. |
| 3 | 자체 블록 분할 | 2GB 미만 청크로 나눠 현재 LZ4 블록 API를 그대로 반복 사용 후 이어붙임. 의존성·빌드 무변경이 장점이나, 청크 경계·길이 메타데이터를 직접 관리해야 해 frame API 대비 재구현 부담이 큼. |
| 4 | 비압축 정책 | 한계 초과 대형 LOB은 압축하지 않음으로 명시. 가장 단순·저위험이라 단기 baseline/fallback 으로 적합하나, 대형 LOB의 압축 이득을 포기. |

## 추가 검토 / 질의 (Open Questions)

- 적용 범위: 우선 internal LOB(컬럼 값)에 한정할지, 공통 압축 계층(`compressor.hpp`)을 확장해 로그(B)·백업(C)까지 포괄할지.
- 기존 LZ4와의 관계: 신규 알고리즘으로 통일할지, 대형 값에 한해 분기할지.
- 디스크 포맷/해제: 압축 방식 식별자, 해제 경로, 하위호환.
- 의존성/빌드: zstd 채택 시 third-party 추가·라이선스·플랫폼 빌드 영향.
- 성능·메모리: 4GB 단일 처리 시 메모리 사용, 부분 해제(스트리밍) 필요성.

## 관련 코드 (Reference)

- `compressor.hpp` (src/base): 공통 압축 래퍼 — LZ4 전용
- `object_primitive.c` (src/object): pr_do_db_value_string_compression, mr_writeval_string_internal, mr_readval_string_internal, pr_get_compressed_data_from_buffer, pr_get_compression_length
- `object_representation.c` (src/object): or_put_varchar_internal, or_get_varchar_compression_lengths
- `log_compress.c` (src/transaction): log_zip, log_unzip, log_diff — 호출 prior_lsa_gen_undoredo_record_from_crumbs (log_append.cpp), 해제 log_rv_get_unzip_and_diff_redo_log_data (log_recovery.c)
- `file_io.c` (src/storage): fileio_compress_backup_node, fileio_decompress_restore_volume
- `dbtype_def.h` (src/compat): DB_MAX_STRING_LENGTH / DB_MAX_BIT_LENGTH = 0x3fffffff
- `lz4.h` (win/3rdparty/lz4): LZ4_MAX_INPUT_SIZE = 0x7E000000
