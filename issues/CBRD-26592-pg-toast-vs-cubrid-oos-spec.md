# [OOS] PostgreSQL TOAST vs CUBRID OOS 스펙 비교

> **TL;DR**: 본 문서는 PostgreSQL TOAST와 CUBRID OOS의 사양을 동일 축(트리거, 정지 조건, 압축, 저장 백엔드, 외부 참조, 갱신, WAL/recovery, MVCC, 한계, 관측성)에서 1:1 비교한 레퍼런스 표다. CUBRID OOS 스펙 변경 의사결정의 근거 문서이며, edge case TC 도출 시의 체크리스트로 활용한다.

## User-Level Summary

본 표는 QA 담당자 등 사용자 수준 독자가 PG TOAST와 CUBRID OOS의 차이를 빠르게 파악할 수 있도록 코드 수준 세부사항을 제거하고 사용자 관점에서 정리한 것이다. 코드 라인 단위 비교는 아래 ## Trigger Conditions 이하 표를 참조한다.

| 항목 | PostgreSQL TOAST | CUBRID OOS | QA 관점 시사점 |
|---|---|---|---|
| 외부 저장 트리거 조건 | 행 전체 크기가 페이지의 1/4를 초과하면 큰 컬럼부터 단계적으로 외부화 | 레코드 추정 크기가 페이지의 1/8을 넘는 시점에서, 그 시점에 한해 512바이트 초과 가변 길이 컬럼을 모두 외부화 (두 단계 게이팅: 레코드 임계 + 컬럼 임계). **추후 변경 가능** | 기본 빌드(PG 8KB 페이지, CUBRID 16KB 페이지)에서 두 임계 절댓값은 ~2KB로 거의 같음 (PG ~2040 B, CUBRID 2048 B). 임계 근처 (~2040 B for PG, 2048 B for CUBRID) 와 컬럼 단독 임계 (CUBRID 512 B) 부근의 boundary TC 필수. 단, CUBRID 임계 정책은 추후 변경 가능성이 있어 임계값을 하드코드하지 않고 스펙 갱신 시 따라가도록 TC 설계 권장 |
| 외부화 진행 방식 | 가장 큰 컬럼부터 한 라운드씩 처리하다가 임계 아래로 떨어지면 즉시 멈춤 (잔여 큰 컬럼이 행 안에 남을 수 있음) | 조건이 만족되면 적격 컬럼을 단일 패스로 일괄 외부화 (잔여 인라인된 큰 가변 컬럼 없음. 단, 고정 길이 컬럼은 크기와 무관하게 항상 인라인) | CUBRID는 가변 컬럼에 대해 더 공격적으로 외부화함. "외부 저장된 컬럼 수"를 검증하는 TC에서 동일 입력에 대해 두 제품 결과가 다르게 나오는 것은 사양상 정상 |
| 압축 사용 가능 여부 | 기본 활성, 알고리즘 2종(pglz/lz4) 지원, 외부 저장 시에도 압축 상태 유지 | 미지원 (압축 단계 자체 부재) | 동일 데이터셋 INSERT 후 디스크 사용량 차이의 상당 부분이 압축에서 기인하므로, CUBRID-PG 디스크 사용량 비교 TC는 PG 측 압축 끄기 (`SET COMPRESSION pglz` 무력화 또는 `EXTERNAL` storage option) 조건도 함께 측정해야 fair comparison |
| 컬럼별 사용자 정책 (DDL 옵션) | `ALTER TABLE ... ALTER COLUMN ... SET STORAGE` 4종 옵션, `SET COMPRESSION` 으로 알고리즘 지정 가능 | DDL 옵션 없음. 가변 길이 컬럼이면 자동 분류 | DDL 기반 컬럼 정책 시나리오는 CUBRID 대상으로는 작성 불가. CUBRID TC는 자동 분류 기준(가변 길이 + 크기) 검증에 집중 |
| 단일 외부값 최대 크기 | 약 1GB | 약 2GB (실효 상한은 청크 수·슬롯 페이지·OID 공간 결합으로 더 작을 수 있음 — 미검증, Open Question 4) | 거대 LOB-like 값 경계 TC 한계가 다름. CUBRID는 더 큰 값을 받을 수 있으나 실효 상한이 미검증이므로 거대 값 TC 설계 시 Open Question 4의 결합 한계를 함께 검증 필요 |
| UPDATE 시 외부값 재사용 | 변경되지 않은 컬럼은 기존 외부 저장값을 그대로 재참조하여 재기록 비용 절약 | 현재 미지원 (변경되지 않은 외부 컬럼도 UPDATE 시 재기록됨) | 거대 외부 컬럼이 포함된 행에 대해 무관 컬럼만 UPDATE하는 시나리오에서 CUBRID는 외부 데이터 재기록 비용이 발생함이 사양. 회귀 TC: 동일 행에 대한 무관 컬럼 UPDATE N회 후 디스크 사용량/실행 시간 측정 (CUBRID 자체의 회귀 검출이 목적이며, PG와의 절대 비교가 아님) |
| 백업/롤백/복구 동작 | 외부 데이터도 일반 행과 동일한 트랜잭션 단위로 자동 롤백/복구 | 청크 단위 개별 undo 기록을 역순으로 재생하여 복구. 트랜잭션 단위 일관성은 보장되지만 메커니즘이 다름 | 둘 다 ACID 보장. 다만 CUBRID는 청크 수에 선형 비례하는 undo 로그가 발생 (예: 1 GB 값 = 약 500개 청크 분량 undo 레코드). 거대 값 ROLLBACK TC에서 WAL 사이즈/log volume 모니터링 권장 |
| 동시성/MVCC 관점 동작 | 외부 데이터 자체가 MVCC 가시성 평가 대상 (자체 버전 보유) | 외부 청크는 별도 가시성 슬롯이 없고 메인 행 가시성을 따라간다고 가정 (Open Question 2) | 사용자 관점 기대치는 동일한 결과지만, CUBRID 측 가시성 상속 메커니즘은 코드 trace 미완 (Open Question 2) — 격리 수준별 multi-session TC가 사양 검증 자체의 핵심 (미검증) |
| 사용자 가시 카탈로그 | `pg_class.reltoastrelid` 컬럼으로 외부 저장 테이블 OID가 노출 (테이블당 1개) | 현재 미지원 (사용자에게 노출되는 카탈로그 컬럼/뷰 없음) | "이 테이블이 외부 저장을 사용하고 있는가"를 SQL로 확인하는 시나리오는 CUBRID에서는 현재 사용자에게 제공되는 경로가 없음. 관측성 관련 기능 요청 사항으로 트래킹 |

상세 메커니즘, 코드 라인 단위 출처, 페이지 크기·헤더 크기 등 정확한 수치는 아래 ## Trigger Conditions 부터의 축별 비교표와 ## Differences Summary 절을 참고한다.

## Summary

- 문제/목적: CUBRID OOS와 PG TOAST의 동작 차이를 한 페이지 매트릭스로 압축해 의사결정 회의와 QA TC 설계를 지원한다.
- 배경: OOS는 PG TOAST에서 영감을 받았으나 진입 임계, 정지 동작, 압축 유무, 저장 백엔드, MVCC 통합 방식이 동일하지 않다.
- 비교 결과 핵심: (1) PG는 투플 단위 임계 + 컬럼별 라운드형 진행, CUBRID는 레코드 추정치 임계 + 단일 패스 일괄 외부화 (2) PG는 압축 내장, CUBRID는 미구현 (3) PG는 별도 힙 테이블, CUBRID는 전용 `FILE_OOS` 슬롯 페이지.
- 영향 범위: 압축 도입 검토(CBRD-26536), 부분 fetch/슬라이스, undo 데이터 비대화, vacuum 정책, 온라인 업그레이드 호환성.

---

## Description

본 문서는 다음 두 목적을 위해 작성되었다.

1. **스펙 변경 검토 근거**: 향후 OOS에 압축, 부분 fetch, 컬럼별 storage 옵션 등을 추가할 때 PG TOAST와의 차이를 명확히 인지한 상태에서 의사결정한다. 단순히 "PG처럼 만든다"가 아니라 어떤 축에서 어떻게 다른지를 기준으로 trade-off를 평가한다.
2. **TC 도출 체크리스트**: 비교표의 각 행은 잠재적 edge case를 시사한다. QA가 OOS 통합 테스트를 설계할 때 본 표를 검토하면서 미커버 시나리오를 식별한다.

비교는 모두 코드 라인 또는 PG 공식 문서에 그라운딩되어 있다. CUBRID 측은 `oos_file.cpp`/`oos_file.hpp`/`heap_file.c`/`object_representation.h` 코드 라인을 1차 출처로 사용한다. PG 측은 survey 문서를 1차 출처로 사용하며 본 비교표는 survey의 인용을 그대로 따른다(검증 책임은 survey에 위임). 추측은 "확인필요(근거 부재)"로 표시한다.

---

## Trigger Conditions

| 축 | PostgreSQL TOAST | CUBRID OOS | 차이 요약 | 출처 |
|---|---|---|---|---|
| 트리거 평가 시점 | `heap_insert()` / `heap_update()` 직후 `heap_toast_insert_or_update()` 진입 시 | `heap_attrinfo_determine_disk_layout()` 단계에서 디스크 레이아웃 산정 시 | PG는 투플 구성 후 평가, CUBRID는 디스크 변환 산정 단계에서 평가 | survey §1.2; `heap_file.c:12187` |
| 1차 트리거 단위 | 투플 전체 크기 | 레코드 추정 크기 (`header_size + payload_size + mvcc_extra`) | PG=투플, CUBRID=레코드+MVCC 헤더 보정 포함 | `heaptoast.h:80-82`; `heap_file.c:12187` |
| 1차 트리거 임계값 | `TOAST_TUPLE_THRESHOLD` = `MaximumBytesPerTuple(TOAST_TUPLES_PER_PAGE=4)` ~= 2040 B (BLCKSZ=8192) | `DB_PAGESIZE / 8` = 2048 B (DB_PAGESIZE=16384) | PG=`BLCKSZ/4`~=2040 B, CUBRID=`DB_PAGESIZE/8`=2048 B. 분모는 다르나 기본 빌드값에서는 거의 동일 절댓값으로 수렴. 페이지 크기 변경 시 관계가 달라짐 | `heaptoast.h:80-82`; `heap_file.c:12187` |
| 임계 비교 단위 | 투플 상대값 (`maxDataLen` ~= 2040 B). 투플 전체가 임계를 넘으면 외부화 라운드 시작 | 컬럼 절댓값 (가변 컬럼 단일값 > 512 B). 레코드 임계와 별도로 컬럼 단일값 절댓값 적용 | 트리거 진입 분모가 다름: PG는 투플 상대(`maxDataLen`), CUBRID는 컬럼 절댓값 + 레코드 추정치 | survey §1.2; `heap_file.c:12193` |
| 컬럼 단위 진입 결정 | 라운드별 `toast_tuple_find_biggest_attribute()` 로 가장 큰 컬럼부터 처리 | 트리거 발화 시 모든 컬럼 1회 스캔 | PG=가장 큰 컬럼부터 점진적, CUBRID=일괄 분류 | `heaptoast.c:185-219`; `heap_file.c:12190-12200` |
| 컬럼 단위 임계값 | 투플 단위 `maxDataLen` 임계만 존재 (컬럼 단독 임계 부재). 단일 컬럼이 `maxDataLen`(~2040 B) 단독 초과 시 즉시 외부화 (survey §1.2 round 1) | `column_size[i] > 512` 바이트 (가변 컬럼 한정), 절댓값 컬럼 임계가 추가로 존재 | PG는 컬럼 단독 임계 부재(투플 임계만), CUBRID는 컬럼 단독 절댓값 임계가 추가 | survey §1.2; `heap_file.c:12193` |
| 컬럼 자격 | `attstorage` 옵션 (`PLAIN`/`EXTENDED`/`EXTERNAL`/`MAIN`) 기반. PLAIN은 `TOASTCOL_IGNORE` 로 완전 배제 | 가변 컬럼 (`!is_fixed`) 한정. 컬럼별 옵션 DDL 없음 | PG=컬럼별 storage 옵션 4종, CUBRID=옵션 없이 가변 자동 | survey §2; `heap_file.c:12193` |
| MVCC 헤더 고려 | 투플 헤더 24 B + null bitmap 포함, 별도 가산 없음 (검증 필요) | `mvcc_extra = OR_MVCC_MAX_HEADER_SIZE - OR_MVCC_INSERT_HEADER_SIZE` 명시적으로 가산 | CUBRID는 MVCC 헤더 확장분을 트리거에 선반영 | `heap_file.c:12183` |

---

## Stop Conditions

| 축 | PostgreSQL TOAST | CUBRID OOS | 차이 요약 | 출처 |
|---|---|---|---|---|
| 정지 의미론 | 목표(`maxDataLen`) 충족 시 즉시 종료. 잔여 큰 컬럼은 인라인 유지 | 조건 만족 시 512B 초과 가변 컬럼 전부 외부화. 잔여 인라인 컬럼 없음 (모든 적격 컬럼이 1회 스캔에서 분류) | PG=목표 충족하면 멈춤(잔여 인라인 허용), CUBRID=조건 만족 시 적격 컬럼 전부 일괄 외부화 | survey §1.2; `heap_file.c:12190-12200` |
| 정지 평가 방식 | 라운드 루프마다 `heap_compute_data_size(...) > maxDataLen` 재계산 | 임계 초과 시 단일 if-블록 내부 1회 스캔; 루프 종료 조건 없음 | PG=동적 재평가, CUBRID=정적 일괄 처리 | survey §1.2; `heap_file.c:12187-12200` |
| 임계 이하로 떨어지면 | 다음 라운드를 건너뛰고 즉시 종료 (남은 큰 컬럼은 인라인 유지) | 해당 동작 없음. 임계 초과 시 512B 초과 가변 컬럼 전부 OOS로 분류 | PG=목표 달성하면 멈춤, CUBRID=한 번에 다 외부화 | survey §1.2; `heap_file.c:12190-12200` |
| 라운드 구성 | 4 라운드: (1) EXTENDED 압축+외부화, (2) EXTENDED/EXTERNAL 외부화, (3) MAIN 압축, (4) MAIN 외부화. 각 라운드 진입 전 임계 재평가 | 라운드 개념 없음. 한 번의 컬럼 스캔으로 결정 | PG=4단계 점진, CUBRID=1패스 | survey §1.2 |
| 잔여 인라인 가능성 | 매우 큰 컬럼 1개만 외부화로 임계 충족 시 나머지 큰 컬럼들은 인라인에 남음 | 512B 초과 가변 컬럼은 무조건 OOS로 이동 | PG는 "필요한 만큼만", CUBRID는 "기준 넘으면 다" | survey §1.2; `heap_file.c:12193` |
| MAIN 컬럼 처리 | 1차 임계로 안 풀리면 `TOAST_TUPLE_TARGET_MAIN` = `MaximumBytesPerTuple(1)` ~= 8096 B (BLCKSZ=8192 minus 페이지 오버헤드) 완화 임계로 라운드 3,4 추가 진행 | MAIN 대응 분기 없음. 가변 컬럼 <=512B에 대한 cleanup pass 부재 | PG는 큰 투플에 대한 2-tier 임계(per-page=4 vs per-page=1), CUBRID는 단일 임계만 | `heaptoast.c:238-270`; `heaptoast.h:80-82` |

> 코드 검증 절차: `heap_file.c:12187-12200` 의 if-블록은 단일 for 루프(라인 12190-12200)만 포함하며 `>512` 바이트인 가변 컬럼을 모두 `oos_columns[i]=true` 로 표시한다. break/임계 재계산이 존재하지 않는다. 대조: PG `heaptoast.c:185-219` 는 `while (heap_compute_data_size(...) > maxDataLen)` 루프 안에서 가장 큰 컬럼 1개씩 처리하고 라운드마다 임계를 재평가한다.

---

## Compression

| 축 | PostgreSQL TOAST | CUBRID OOS | 차이 요약 | 출처 |
|---|---|---|---|---|
| 압축 지원 여부 | 지원 (기본 활성) | 미구현 | CUBRID는 OOS 도입 시 압축 단계 부재 | survey §3; `oos_file.cpp` 전반 |
| 압축 알고리즘 | `pglz` (기본), `lz4` (`USE_LZ4` 빌드) | 해당 없음 | 알고리즘 선택 매커니즘 자체가 CUBRID에 없음 | `toast_compression.c:26` |
| 압축 적용 시점 | 외부화보다 먼저 (Round 1: EXTENDED 압축 시도 -> 그래도 크면 외부화). EXTERNAL 컬럼은 압축 생략 | 해당 없음 | PG는 "압축 후 외부화" 순서 | `heaptoast.c:185-219` |
| 압축 적용 단위 | per-varlena attribute (varlena 단위) | 해당 없음 (압축 단계 자체 부재) | PG는 varlena 단위, CUBRID는 단계 자체 부재 | `toast_internals.c:46` |
| 압축 성공 기준 | (1) `pglz` `min_comp_rate >= 25%` AND (2) `VARSIZE(compressed) < valsize - 2` 양쪽 통과 | 해당 없음 | 두 단계 게이트 | `pg_lzcompress.c:223-235`, `toast_internals.c:91` |
| 압축 최소 입력 | `pglz` `min_input_size = 32` B | 해당 없음 | 32B 미만은 시도조차 안 함 | `pg_lzcompress.c:223-235` |
| 실패 폴백 | 2단계 게이트: (1) `pglz` 내부 `min_comp_rate >= 25%` 미달 시 비압축 반환, (2) `toast_compress_datum` 이 `VARSIZE < valsize-2` 로 재게이트. 둘 다 실패 시 비압축 원본으로 외부화 라운드 진입 | 해당 없음 | PG는 폴백 자동 (2단계 게이트) | `pg_lzcompress.c:228`; `toast_internals.c:91` |
| 외부 저장 시 압축 상태 보존 | 압축된 varlena를 그대로 청크 분할해 저장. `va_extinfo` 에 압축 방법 인코딩 | 해당 없음 (raw record) | PG는 외부에도 압축 상태로 누움 | `toast_internals.c:173-198` |
| 컬럼별 압축 옵션 | `ALTER TABLE t ALTER COLUMN c SET COMPRESSION lz4` 지원 | 해당 없음 | DDL 레벨 컬럼 옵션 부재 | `toast_helper.c:58` |

---

## Storage Backend

| 축 | PostgreSQL TOAST | CUBRID OOS | 차이 요약 | 출처 |
|---|---|---|---|---|
| 저장 단위 | 별도 힙 테이블 `pg_toast_<oid>` (테이블당 1개 생성) | 전용 OOS 파일 타입 `FILE_OOS` (테이블당 1개, `heap_hdr->oos_vfid` 로 참조; `heap_oos_find_vfid()` 가 lazy 생성) | PG=일반 힙 재사용, CUBRID=전용 파일 타입 | survey §5.1; `file_manager.h:53`; `heap_file.c:12246-12273` |
| 저장 행/슬롯 형식 | TOAST 테이블 행 스키마: `chunk_id OID`, `chunk_seq INT`, `chunk_data BYTEA` | slotted page 슬롯에 `OOS_RECORD_HEADER {total_size, chunk_index, next_chunk_oid}` + 데이터 | PG=정형 컬럼 행, CUBRID=헤더+데이터 직렬화 | survey §5.1; `oos_file.hpp:25-30` |
| 청크 헤더 크기 | TOAST 테이블 행 헤더(투플 헤더 + 3 컬럼 메타) | 16 bytes (`OOS_RECORD_HEADER_SIZE`) | CUBRID 헤더는 고정 16B | `oos_file.hpp:33` |
| 청크 최대 크기 | `TOAST_MAX_CHUNK_SIZE` (`heaptoast.h:84`, 빌드 시 ~1996 B at BLCKSZ=8192) | `oos_get_max_chunk_size_within_page()` = `DB_ALIGN_BELOW(spage_max_record_size(), OOS_ALIGNMENT) - sizeof(OOS_RECORD_HEADER)` (런타임 결정) | PG=빌드 상수, CUBRID=런타임 함수 | `heaptoast.h:80-84`; `oos_file.cpp:1768` |
| 청크 정렬 | 해당 없음 (테이블 행) | `OOS_ALIGNMENT = MAX_ALIGNMENT` 정렬 | CUBRID는 명시적 정렬 | `oos_file.cpp:78` |
| 다중 청크 분할 임계 | 값이 청크 최대 크기 초과 시 | `recdes.length > oos_get_max_chunk_size_within_page()` 시 `oos_insert_across_pages()` 분기 | 동일 개념, 임계값 다름 | `oos_file.cpp:1084-1097` |
| 청크 연결 방식 | `chunk_seq` 컬럼으로 행 단위 정렬 (인덱스 스캔으로 재조합) | `next_chunk_oid` 단일 연결 리스트 (포워드 링크) | PG=인덱스 기반 재조합, CUBRID=링크드 리스트 | survey §5.1; `oos_file.hpp:29` |
| 다중 청크 삽입 순서 | 청크 순서대로 (`chunk_seq` 기준) | **역순** 삽입 (마지막 청크부터 head 방향) — `next_chunk_oid` 를 알기 위함 | CUBRID는 역순 (`next_chunk_oid` 사전 결정 위해 채택) | `oos_file.cpp:1116` |
| 인덱스 | `pg_toast_<oid>_index` (chunk_id, chunk_seq) on TOAST 테이블 | 없음. OID로 직접 접근 | PG=B-tree 보조, CUBRID=직접 OID | survey §5.1 |
| Bestspace/free space 관리 | TOAST 테이블에 PG의 일반 FSM 적용 | OOS 전용 bestspace 캐시 (`OOS_BESTSPACE_CACHE_CAPACITY = 1000`, `oos_Bestspace` 싱글톤) | 별도 캐시 구조 | `oos_file.cpp:80-82`; `oos_file.cpp:108-110` |

---

## External Reference Pointer

| 축 | PostgreSQL TOAST | CUBRID OOS | 차이 요약 | 출처 |
|---|---|---|---|---|
| 인라인 포인터 구조 | `varatt_external` (`va_rawsize`, `va_extinfo`, `va_valueid`, `va_toastrelid`) ~= 18 B | `{OID(8 B), length BIGINT(8 B)}` 합계 16 B (`OR_OOS_INLINE_SIZE = OR_OID_SIZE + OR_BIGINT_SIZE`) | PG ~18 B vs CUBRID 16 B. PG=확장 메타 다수, CUBRID=OID + length만 | survey §3.4; `object_representation.h:455` |
| 인라인 표식 비트 | `VARATT_IS_EXTERNAL_ONDISK`, `VARATT_IS_COMPRESSED` 플래그 | `OR_VAR_BIT_OOS = 0x1` (bit 0) flag bit, `OR_VAR_FLAG_MASK = 0x3` | PG=varlena 헤더 비트, CUBRID=variable offset 마스크 비트 | `object_representation.h:441-443` |
| 외부 데이터 식별자 | `va_valueid` (TOAST 테이블 행의 `chunk_id`) + `va_toastrelid` | 첫 청크 OID (`{volid, pageid, slotid}`) (인라인 16B 중 OID 부분 8B) | PG=테이블 OID + 행 OID, CUBRID=직접 OID | survey §5.1; `object_representation.h:455` |
| 원본 크기 저장 | `va_rawsize` 별도 필드 (인라인 한 곳) | 인라인 BIGINT(8 B) + 모든 청크 헤더의 `total_size`(int 4 B) — N-청크 기록 시 N배 중복 저장 (`oos_file.cpp:1132` + TODO `oos_file.cpp:1127-1131`) | PG=인라인 1회, CUBRID=인라인 + 청크 헤더 N회 (chunk-per-header 중복) | `object_representation.h:455`; `oos_file.hpp:27`; `oos_file.cpp:1127-1132` |
| 압축 정보 인코딩 | `va_extinfo` 에 실제 저장 크기 + 압축 방법 ID | 해당 없음 (압축 미구현) | CUBRID 측 필드 자체 부재 | `toast_internals.c:173-198` |
| 인라인 길이 | 약 18 B (`varatt_external` 포인터 구조 크기) | 16 B = `OR_OID_SIZE`(8) + `OR_BIGINT_SIZE`(8) | PG ~18 B vs CUBRID 16 B | `object_representation.h:455` |

---

## Update / Vacuum Semantics

| 축 | PostgreSQL TOAST | CUBRID OOS | 차이 요약 | 출처 |
|---|---|---|---|---|
| UPDATE 시 외부값 처리 | 컬럼이 변경되지 않으면 기존 TOAST 행 재참조 (포인터 복사). 변경되면 새 chunk_id로 재삽입, 구버전은 vacuum 대상 | 매 INSERT마다 OOS 청크 재생성. UPDATE 시 변경되지 않은 외부 컬럼도 재기록됨 (재참조 최적화 미지원) | PG=불변 컬럼 재참조 최적화 보유, CUBRID=현재 미지원 — 동일 행에 대한 무관 컬럼 UPDATE 반복 시 외부 데이터 재기록 비용이 누적됨 | survey §1.1 |
| 삭제 가시성 | TOAST 행은 일반 MVCC 가시성 (`xmin`/`xmax`) 적용. main heap dead tuple 후 vacuum이 TOAST 행도 회수 | OOS는 별도 MVCC 헤더 없음. main heap row 삭제 시 OOS chunk를 동기 삭제하는 forward walk 채택 | PG=MVCC 가시성으로 lazy 회수, CUBRID=동기 cleanup 또는 vacuum forward walk | `oos_file.cpp:1758-1763`; `vacuum.c:2417-2447` (`vacuum_heap_oos_delete`); CBRD-26668 |
| Vacuum 책임 | `VACUUM` (autovacuum 포함)이 main과 TOAST 테이블 모두 처리 | OOS 전용 vacuum 경로 (forward walk OOS cleanup) — `vacuum_heap_oos_delete()` 가 helper의 `oos_oids` 벡터를 순회하며 `oos_delete()` 호출 | PG=공통 vacuum, CUBRID=OOS 전용 path | `vacuum.c:2410-2447`; `vacuum.c:2538-2602`; CBRD-26668 |
| 빈 페이지 회수 | TOAST 테이블 vacuum truncation | `oos_delete()` 는 페이지 회수 안 함; vacuum이 빈 페이지 회수 | 둘 다 vacuum이 회수 | `oos_file.cpp:1754-1755` |
| 롤백 시 외부값 복원 | TOAST 행도 일반 WAL 트랜잭션의 일부로 자동 롤백 | `RVOOS_INSERT`/`RVOOS_DELETE` undo 레코드를 역순 재생; 청크 별 개별 로깅 | PG=일반 행, CUBRID=전용 redo dispatch | `oos_file.cpp:1611-1641` |
| 부분 청크 롤백 안전성 | TOAST 테이블 행은 트랜잭션 단위로 일관 | 청크 별 개별 undo가 있어 mid-chain error에서도 abort로 복구. 에러 후 commit 금지 명시 | CUBRID는 mid-chain 에러 처리 명문화 | `oos_file.cpp:1738-1755` |

---

## WAL & Recovery

| 축 | PostgreSQL TOAST | CUBRID OOS | 차이 요약 | 출처 |
|---|---|---|---|---|
| WAL 기록 경로 | 일반 `heap_insert()`/`heap_update()` 경로 — TOAST 테이블도 동일 WAL 스트림 | 전용 redo 코드 `RVOOS_INSERT`/`RVOOS_DELETE` | PG=공통, CUBRID=전용 | survey §5.4; `oos_file.cpp:1621, 1640` |
| WAL 페이로드 | 압축이라면 압축 상태 그대로, 비압축이라면 raw bytes | 청크 별 full record (헤더 포함). undo 데이터는 record 전체 | CUBRID undo 데이터가 raw record 전체로 큼 | `toast_internals.c:173-198`; `oos_file.cpp:1621` |
| Redo handler | 일반 heap redo (`heap_xlog_insert` 등) | `oos_rv_redo_insert` (`spage_insert_for_recovery` 호출) | CUBRID 전용 함수 | `oos_file.cpp:1799-1828` |
| Undo handler | MVCC `xmax` 표식 (실제 행은 그대로 두고 가시성 차단) | `oos_rv_redo_delete` (undo가 redo handler 역방향 재사용) | PG=가시성 기반, CUBRID=물리 삭제 redo | `oos_file.cpp:1776-1797`; `recovery.c:845-857` |
| Recovery dispatch 표 | 해당 없음 (heap WAL 일반 dispatch) | `RVOOS_INSERT.undo=oos_rv_redo_delete`, `RVOOS_INSERT.redo=oos_rv_redo_insert`, `RVOOS_DELETE.undo=oos_rv_redo_insert`, `RVOOS_DELETE.redo=oos_rv_redo_delete` | CUBRID는 명시적 4-셀 dispatch | `recovery.c:845-857` |
| 압축 해제 시점 | redo는 압축 상태로 페이지 복원, 읽기 시점에 `detoast_attr()` 이 해제 | 해당 없음 (압축 미구현) | CUBRID는 추후 도입 시 읽기 경로(`heap_file.c:10652`)에 분기 추가 필요 | survey §5.4 |
| 멀티 청크 일관성 | 트랜잭션 단위 ACID로 보장 (TOAST 행 = 일반 행) | 청크 별 individual undo, abort 시 역순 재생으로 복원 | 둘 다 트랜잭션 단위 일관, 메커니즘 다름 | `oos_file.cpp:1736-1763` |

---

## Concurrency & MVCC

| 축 | PostgreSQL TOAST | CUBRID OOS | 차이 요약 | 출처 |
|---|---|---|---|---|
| MVCC 헤더 | TOAST 테이블 행에 `xmin`/`xmax`/`cmin`/`cmax` 등 일반 MVCC 슬롯 존재 | OOS 슬롯에 별도 MVCC 헤더 없음 (`OOS_RECORD_HEADER` 는 `total_size`/`chunk_index`/`next_chunk_oid` 3 필드만 보유) | CUBRID OOS는 자체 MVCC 슬롯 미보유. main heap MVCC 상속 가정은 추정 — 가시성 판정 코드 경로 미인용 (Open Question 2) | survey §5.4; `oos_file.hpp:25-30` |
| 가시성 평가 | TOAST 행 자체가 MVCC 스냅샷 평가 대상 | OOS chunk는 가시성 평가 대상 아님; main row가 보이면 OOS도 따라 보이는 구조로 추정. `heap_file.c:10642-10652` 에서 `OR_IS_OOS(offset)` 분기 후 `oos_read()` 직접 호출 (스냅샷 재평가 없음) | PG=독립 평가, CUBRID=상속 가시성 (가시성 판정 코드 경로 정밀 trace는 Open Question 2) | `oos_file.hpp:25-30`; `heap_file.c:10642-10652` |
| 외부 행 락 | TOAST 테이블 행에 일반 행 락 적용 가능 | 명시적 OOS 행 락 없음. `oos_delete_chain()` 은 caller가 row-level lock 보유 가정 | CUBRID는 caller 책임 명시 | `oos_file.cpp:1643-1644` |
| 동시 INSERT | TOAST 테이블 페이지 잠금 | OOS 페이지 latch (`PGBUF_LATCH_WRITE`) + bestspace cache mutex | 페이지 latch + bestspace mutex | `oos_file.cpp:105`, `1417-1418` |
| 동시 DELETE 보호 | MVCC `xmax` | caller-supplied X-LOCK 가정 (행 락) | CUBRID는 외부 행 락에 의존 | `oos_file.cpp:1643-1644` |
| Multi-version 가시성 | 같은 TOAST 데이터에 여러 버전 공존 가능 (snapshot isolation) | OOS 청크는 단일 물리 인스턴스. main row 신규 버전마다 OOS chunk가 새로 생성됨 (재참조 최적화 미지원) | PG는 multi-version 자연스럽고 동일 외부값을 다수 버전이 공유. CUBRID는 재참조 최적화가 없으므로 신규 버전마다 OOS chunk 중복 발생 | survey §1.1 |

---

## Limits

| 축 | PostgreSQL TOAST | CUBRID OOS | 차이 요약 | 출처 |
|---|---|---|---|---|
| 단일 외부값 최대 크기 | 1 GB - 1 (varlena `VARSIZE` 32-bit, 실제 1 GB - 8K 정도) | `recdes.length`/`total_size` 모두 `int`(2^31-1) 한계. 인라인 길이 필드는 BIGINT(8 B, 2^63-1)이지만 실효 상한은 `int` 한계가 결정. 슬롯 페이지·청크 수 결합 한계는 미확인 | PG 1 GB - 1 vs CUBRID 약 2 GB - 1 | `object_representation.h:455`; `oos_file.hpp:27`; PG `varlena` 정의 |
| 청크 최대 크기 | `TOAST_MAX_CHUNK_SIZE` (`heaptoast.h:84`, 빌드 시 ~1996 B at BLCKSZ=8192) | 런타임 `spage_max_record_size() - sizeof(OOS_RECORD_HEADER) - alignment` (DB_PAGESIZE=16384 시 더 큼) | CUBRID는 페이지 크기에 비례, PG는 BLCKSZ 의존 | `heaptoast.h:80-84`; `oos_file.cpp:1768` |
| 페이지당 청크 수 | `EXTERN_TUPLES_PER_PAGE = 4` | slotted page slot 수 제한에 의해 결정 (런타임 페이지 사용량 의존). 정확한 비율은 `spage_max_record_size() / OOS_RECORD_HEADER_SIZE` 등으로 산출 가능 | PG=빌드 상수, CUBRID=런타임 페이지 사용량 의존 | `heaptoast.h:80-82`; `oos_file.cpp:1768` |
| 컬럼 외부화 임계 | 컬럼 자체 임계 없음 (투플 단위 임계만) | 512 B (가변 컬럼) | CUBRID는 고정 컬럼 임계 추가 | survey §1.2; `heap_file.c:12193` |
| 페이지 크기 의존성 | `BLCKSZ` 빌드 시 결정 (기본 8192) | `DB_PAGESIZE` 빌드 시 결정 (기본 16384). `spage_max_record_size()` 런타임 호출 | 둘 다 빌드 상수지만 CUBRID는 함수 호출 | `heaptoast.h:80-82`; `oos_file.cpp:1771` |
| 인라인 포인터 크기 | `varatt_external` ~= 18 B | `OR_OOS_INLINE_SIZE` = 16 B = `OR_OID_SIZE`(8) + `OR_BIGINT_SIZE`(8) | PG ~18 B vs CUBRID 16 B | `object_representation.h:455` |
| 컬럼당 storage 옵션 수 | 4종 (`PLAIN`/`EXTENDED`/`EXTERNAL`/`MAIN`) | 0 (옵션 없음) | CUBRID는 DDL 옵션 부재 | survey §2 |

---

## Observability

| 축 | PostgreSQL TOAST | CUBRID OOS | 차이 요약 | 출처 |
|---|---|---|---|---|
| TOAST 테이블 조회 | `pg_class.reltoastrelid` 로 전용 테이블 OID 노출 | OOS VFID는 `heap_hdr->oos_vfid` 내부 필드. 사용자에게 노출되는 카탈로그 컬럼/뷰 없음 (현재 미지원) | PG는 카탈로그로 노출, CUBRID는 사용자 노출 경로 부재 — 관측성 기능 요청 후보 | `heap_file.c:12246-12273` |
| 통계 뷰 | `pg_statistic` (TOAST 컬럼 포함), `pg_stat_user_tables` 등 | OOS 전용 통계 미확인 (확인필요(근거 부재)) | PG는 표준 통계 통합 | survey 미인용 |
| 로깅/디버그 | `log_min_duration_statement` 등 일반 로깅 | `oos_error`/`oos_warn` 항상 활성, `oos_trace`/`oos_debug`/`oos_info` 는 debug 빌드 한정 (release no-op) | CUBRID 전용 로깅 매크로 (severity별 활성 조건 분리) | `oos_log.hpp:143-148` (always-active error/warn), `oos_log.hpp:152`, `oos_log.hpp:155`, `oos_log.hpp:158`, `oos_log.hpp:162-166` |
| 페이지 검사 도구 | `pageinspect` extension의 `heap_page_items` 등 | 확인필요(근거 부재) — OOS 페이지 검사 유틸리티 존재 여부 미확인 | PG는 확장 모듈 존재 | survey 미인용 |
| 통계 캐시 노출 | TOAST 테이블 통계 자동 갱신 | `OOS_HDR_STATS` 헤더 페이지 내장; bestspace cache는 메모리 전용 | CUBRID는 헤더 + 메모리 캐시 이중 구조 | `oos_file.hpp:49-72` |

---

## Differences Summary

회의 결정용으로 가장 중요한 차이만 추린다.

1. **트리거 단위와 분모** (see ## Trigger Conditions): PG는 투플 전체 vs 임계, CUBRID는 레코드 추정치 vs `DB_PAGESIZE/8`. 분모(4 vs 8)와 단위가 모두 다르므로 "동일 임계"가 아니다.
2. **정지 의미론** (see ## Stop Conditions): PG는 라운드형 점진 외부화로 임계 충족 즉시 멈춰 인라인을 최대화한다. CUBRID는 단일 패스로 512B 초과 가변 컬럼을 모두 외부화하여 더 공격적이다. PG는 1 GB - 1, CUBRID는 약 2 GB - 1로 외부값 최대 크기 자체도 약 2배 차이가 있다 (실 워크로드 영향은 별도 평가 필요).
3. **압축 부재** (see ## Compression): CUBRID OOS는 압축 단계 자체가 없다. PG는 컬럼별 알고리즘 선택 + 외부저장 시 상태 보존 + 폴백까지 포함한 완성 파이프라인이다.
4. **저장 백엔드** (see ## Storage Backend): PG는 `pg_toast_<oid>` 일반 힙 + B-tree 인덱스, CUBRID는 전용 `FILE_OOS` slotted page + `next_chunk_oid` 링크드 리스트. PG는 인덱스 비용 + 일관 vacuum, CUBRID는 직접 접근 + 전용 cleanup 경로.
5. **MVCC 통합** (see ## Concurrency & MVCC): PG TOAST 행은 자체 MVCC 슬롯을 가져 독립 가시성 평가; CUBRID OOS chunk는 MVCC 헤더가 없고 main heap row의 가시성을 상속한다고 가정 (UPDATE 시 미변경 OOS 컬럼 재참조 최적화는 현재 미지원이므로 신규 버전마다 OOS chunk 중복 발생; 가시성 판정 코드 path 정밀 trace — Open Question 2).
6. **컬럼 옵션** (see ## Trigger Conditions, ## Limits): PG는 `attstorage` 4종 + `SET COMPRESSION` DDL을 제공해 사용자가 컬럼 단위로 정책 결정. CUBRID는 사용자 옵션이 없고 자동 분류 (`!is_fixed && >512B`)에 고정.
7. **다중 청크 삽입 순서** (see ## Storage Backend): CUBRID는 `next_chunk_oid` 를 알기 위해 마지막 청크부터 역순 삽입(`oos_file.cpp:1116`). PG는 `toast_save_datum()` 이 chunk_seq=0부터 순방향으로 INSERT (`toast_internals.c:119`).
8. **인라인 포인터의 메타데이터와 N배 길이 중복** (see ## External Reference Pointer): PG `varatt_external` ~= 18 B에 `va_rawsize`, `va_extinfo`(압축 정보 포함), `va_toastrelid` 등 다수 포함. CUBRID는 16 B(OID 8 B + BIGINT length 8 B)로 압축/메타 확장 여지가 적다. 추가로 N-청크 기록 시 N개 청크 헤더 모두에 `total_size`(int 4 B)가 중복 저장되며 (`oos_file.cpp:1132` + TODO 1127-1131), 헤더 슬림화는 spec 변경 후보다.

---

## Open Questions

1. **CUBRID 페이지 검사 도구**: PG `pageinspect` 같은 OOS 페이지 디버깅 유틸리티 존재 여부 확인필요.
2. **OOS 가시성 평가 메커니즘 정확성**: 본 문서는 "main heap row의 MVCC를 상속"이라 정리했으나, 정확한 코드 경로(예: `heap_get_visible_version` 호출 경로 안에서 `OR_IS_OOS` 분기와 `oos_read()` 가 어떤 스냅샷 조건 하에서 호출되는지)는 정밀 trace 미완료. `heap_file.c:10642-10652` 분기 상위 호출 path 확인 필요.
3. **`spage_max_record_size()` 캐시 가능성**: `oos_file.cpp:1765-1771` 의 TODO 주석(라인 1765 캐시화, 라인 1770 `spage_max_record_size` 버그)대로 빌드 상수화 가능 여부와 스레드 안전성 검토 필요.
4. **CUBRID 단일 OOS 값 실효 상한**: `total_size`(int)/`recdes.length`(int)/인라인 BIGINT(8 B) 중 가장 작은 한계는 `int` 2 GB - 1. 페이지당 청크 수 한계와 결합한 실효 상한(슬롯 페이지 수, OID 공간, 헤더 페이지 통계 한계 등)은 확인필요.

> 본 절은 추후 검증이 필요한 항목만 남긴다. **UPDATE 시 미변경 외부 컬럼 재참조 최적화**(과거 OQ1)와 **사용자 노출 카탈로그 컬럼/뷰**(과거 OQ2)는 현재 미지원으로 확정되어 본 절에서 제외했고, 해당 사실은 ## User-Level Summary, ## Update / Vacuum Semantics, ## Concurrency & MVCC, ## Observability, ## Differences Summary 의 본문에 반영되어 있다.

---

## 참고 코드

### Sources

- Survey (PG TOAST 1차 출처): `/home/vimkim/gh/cb/oos-vacuum/docs/research/pg-toast-compression-survey.md`. PG 측 인용은 본 survey 문서를 그대로 따른다(검증 책임은 survey에 위임).
- CUBRID 측: 아래 파일/라인 참조는 모두 `/home/vimkim/gh/cb/oos-vacuum/src/storage` 및 `/home/vimkim/gh/cb/oos-vacuum/src/transaction` 트리 기준.

CUBRID 측:
- `object_representation.h:441-443` — `OR_VAR_BIT_OOS = 0x1`, `OR_VAR_FLAG_MASK = 0x3` (인라인 표식 비트)
- `object_representation.h:451` — `OR_IS_OOS(length)` 매크로
- `object_representation.h:455` — `OR_OOS_INLINE_SIZE = OR_OID_SIZE + OR_BIGINT_SIZE` (= 16 B)
- `file_manager.h:53` — `FILE_OOS` enum 정의
- `oos_log.hpp:143-148` — `oos_error` (line 145) / `oos_warn` (line 148) — 항상 활성 (release 포함)
- `oos_log.hpp:152` — `oos_trace` 매크로 정의 (debug 빌드)
- `oos_log.hpp:155` — `oos_debug` 매크로 정의 (debug 빌드)
- `oos_log.hpp:158` — `oos_info` 매크로 정의 (debug 빌드)
- `oos_log.hpp:162-166` — `oos_trace`/`oos_debug`/`oos_info` no-op (release 빌드)
- `oos_file.hpp:25-30` — `OOS_RECORD_HEADER {total_size, chunk_index, next_chunk_oid}` (16 bytes, MVCC 슬롯 미보유)
- `oos_file.hpp:33` — `OOS_RECORD_HEADER_SIZE` 매크로
- `oos_file.cpp:78` — `OOS_ALIGNMENT = MAX_ALIGNMENT`
- `oos_file.cpp:80-82` — `OOS_BESTSPACE_CACHE_CAPACITY=1000`, `OOS_DROP_FREE_SPACE`, `OOS_BESTSPACE_SYNC_THRESHOLD` (line 83 `BEST_PAGE_SEARCH_MAX_COUNT` 는 무관 상수)
- `oos_file.cpp:108-110` — `oos_Bestspace` 캐시 싱글톤 정의
- `oos_file.cpp:1071-1097` — `oos_insert()` 진입, 청크 분할 분기 (`recdes.length <= max_chunk_size` 인라인, 초과 시 `oos_insert_across_pages()`)
- `oos_file.cpp:1100-1154` — `oos_insert_across_pages()` 역순 삽입 루프 (`oos_file.cpp:1116` "reverse order" 주석, line 1132 `OOS_RECORD_HEADER header{total_size, i, next_chunk_oid}` — N-chunk × `total_size` 중복; TODO 1127-1131 헤더 분리 검토)
- `oos_file.cpp:1158-1217` — `oos_insert_within_page()` (slotted page 삽입 + 로깅)
- `oos_file.cpp:1221-1295` — `oos_read_across_pages()` 청크 재조합
- `oos_file.cpp:1336-1387` — `oos_read()` 단일/다중 청크 분기
- `oos_file.cpp:1611-1641` — `oos_log_insert_physical()`, `oos_log_delete_physical()` (RVOOS_INSERT/DELETE)
- `oos_file.cpp:1659-1725` — `oos_delete_chain()` 포워드 워크 + 청크별 undo
- `oos_file.cpp:1758-1763` — `oos_delete()` 진입
- `oos_file.cpp:1767-1774` — `oos_get_max_chunk_size_within_page()` 런타임 결정
- `oos_file.cpp:1776-1828` — `oos_rv_redo_delete()` / `oos_rv_redo_insert()` recovery handler
- `heap_file.c:10642-10652` — `OR_IS_OOS(offset)` 분기 + `oos_read()` 직접 호출 (가시성 상속 추정 경로)
- `heap_file.c:12166-12207` — `heap_attrinfo_determine_disk_layout()` 트리거 결정
- `heap_file.c:12187` — 1차 트리거 `header_size + payload_size + mvcc_extra > DB_PAGESIZE / 8`
- `heap_file.c:12193` — 컬럼 임계 `!is_fixed && column_size[i] > 512`
- `heap_file.c:12197` — `OR_OOS_INLINE_SIZE` 사용 (인라인 포인터 길이 보정)
- `heap_file.c:12246-12273` — `heap_oos_find_vfid()` (VFID 캐시/생성)
- `heap_file.c:12368-12441` — `heap_attrinfo_insert_to_oos()` 압축 훅 후보 위치
- `vacuum.c:2380-2407` — `vacuum_ensure_oos_vfid_for_heap_record()` (lazy VFID 캐시)
- `vacuum.c:2410-2447` — `vacuum_heap_oos_delete()` (forward walk OOS cleanup)
- `vacuum.c:2538-2602` — vacuum sysop 내부 OOS cleanup 진입 지점
- `recovery.c:845-857` — RVOOS_INSERT/DELETE recovery dispatch 표

PostgreSQL 측 (Sources 항목의 survey 문서 인용 그대로):
- `src/include/access/heaptoast.h:80-82` — `TOAST_TUPLES_PER_PAGE`, `TOAST_TUPLE_THRESHOLD`, `TOAST_TUPLE_TARGET_MAIN`
- `src/include/access/heaptoast.h:84` — `TOAST_MAX_CHUNK_SIZE`
- `src/include/catalog/pg_type.h:307-310` — `attstorage` 옵션 4종
- `src/backend/access/heap/heaptoast.c:96` — `heap_toast_insert_or_update()` 진입
- `src/backend/access/heap/heaptoast.c:185-219` — Round 1 압축+외부화 분기
- `src/backend/access/heap/heaptoast.c:204` — EXTERNAL 컬럼 INCOMPRESSIBLE 설정
- `src/backend/access/heap/heaptoast.c:238-270` — MAIN 컬럼 처리
- `src/backend/access/heap/toast_helper.c:42` — `toast_tuple_init()`
- `src/backend/access/heap/toast_helper.c:58` — `tai_compression = att->attcompression`
- `src/backend/access/heap/toast_helper.c:127` — PLAIN 컬럼 IGNORE 설정
- `src/backend/access/common/toast_compression.c:26` — pglz/lz4 식별자
- `src/backend/access/common/toast_internals.c:46` — `toast_compress_datum()`
- `src/backend/access/common/toast_internals.c:91` — 압축 수락 기준 `VARSIZE < valsize-2`
- `src/backend/access/common/toast_internals.c:119` — `toast_save_datum()`
- `src/backend/access/common/toast_internals.c:173-198` — `va_extinfo` 인코딩
- `src/common/pg_lzcompress.c:223-235` — `PGLZ_strategy_default` (min_input_size=32, min_comp_rate=25%)
- `src/backend/access/common/detoast.c:45` — `detoast_external_attr()`
- `src/backend/access/common/detoast.c:116-133` — `detoast_attr()` 압축 해제 분기
- `src/backend/access/common/detoast.c:205-256` — `detoast_attr_slice()` 부분 fetch
