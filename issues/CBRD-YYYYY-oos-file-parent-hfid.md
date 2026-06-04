# [OOS] OOS 파일 descriptor 에 parent HFID 저장

> 부모 epic: CBRD-26583 / 발단: CBRD-26871(OOS 병합 QA 검증 시나리오)의 툴링 선행과제 T2

## Issue Triage

**이슈 수행 목적**: OOS 파일(`FILE_OOS`)의 `FILE_DESCRIPTORS` 에 부모 heap 파일 식별자(HFID - Heap File ID, 테이블 heap 파일 식별자)를 저장해, `cubrid diagdb`/`spacedb` 가 OOS 파일을 소속 테이블에 귀속해 표시할 수 있게 한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: OOS 파일은 생성 시(`oos_create_file`, `oos_file.cpp:910` -> `file_create(FILE_OOS, ...)`, `:924`) `FILE_DESCRIPTORS` 에 부모 HFID 를 기록하지 않는다. 그래서 dump 함수 `file_header_dump_descriptor`(`file_manager.c:1424`)의 `FILE_OOS` case(`:1431`)가 `FILE_MULTIPAGE_OBJECT_HEAP` 처럼 "Overflow for HFID: ..." 행(`:1446`, `descriptor.heap_overflow.hfid`)을 출력하지 못하고 빈 줄로 종료한다(코드 주석 명시).
- **영향**: 진단/QA 곤란. OOS 파일이 어느 테이블에 속하는지 툴로 식별할 수 없다. T1(`SPACEDB_OOS_FILE`)으로 OOS 공간 총량을 보게 돼도, 어느 테이블의 OOS 가 공간을 점유하는지 분해할 수 없어 운영 진단과 QA 검증(특정 테이블 OOS 발동 확인)이 막힌다.

**이슈 수행 방안**:

- OOS 파일 생성 시 `FILE_DESCRIPTORS` 의 `descriptor.heap_overflow.hfid`(`file_manager.h:91`)를 재사용해 부모 HFID 기록(별도 멤버 불필요; dump 의 `:1446` 출력 패턴과 대칭). OOS 는 부모 heap 이 먼저 존재하므로 생성 전 `des` 에 HFID 를 직접 채운다(heap 의 생성 후 갱신 dance 불필요).
- `oos_create_file`(`oos_file.cpp:910`)에 부모 HFID(또는 `class_oid`) 인자 추가 후 모든 호출부 갱신.
- `file_header_dump_descriptor`(`file_manager.c:1431`)의 `FILE_OOS` dump case 에서 부모 HFID 출력(예: "OOS for HFID: ...").
- 기존(마이그레이션) OOS 파일 처리: 기존 파일은 HFID 미보유 - 재생성/무시/지연 채움 정책 `TBD - 합의 미확인`.

---

## AI-Generated Context

> 아래는 AI 가 코드를 분석해 작성한 상세 자료다. 빠른 triage 에는 위 블록으로 충분하다.

### Summary

- **목적**: OOS 파일을 소속 테이블(HFID)에 귀속 가능하게 함.
- **배경**: OOS 파일 descriptor 에 parent HFID 부재로 diagdb/spacedb 가 테이블 귀속 불가.
- **변경 사항**: OOS 파일 생성 시 descriptor 에 HFID 기록 + dump 출력. 기존 파일 마이그레이션 정책 결정 필요.
- **영향 범위**: `oos_file.cpp`(생성), `file_manager.c`(dump), 진단 출력. 기존 OOS 파일 호환성 검토 필요.

---

## Description

OOS 파일은 heap 파일과 1:1 로 대응한다(테이블당 하나). 그러나 OOS 파일 자체에는 부모 heap 파일을 가리키는 식별자가 없어, 역방향 귀속(OOS 파일 -> 테이블)이 불가능하다.

dump 함수 `file_header_dump_descriptor` 에서 `FILE_HEAP` 은 `descriptor.heap.class_oid` 로 클래스명을, `FILE_MULTIPAGE_OBJECT_HEAP`(heap overflow)은 `descriptor.heap_overflow.hfid` 로 부모 HFID 를 출력한다. `FILE_OOS` 만 descriptor 에 해당 정보가 없어 빈 줄로 끝난다. 이전에는 이 자리에 `assert(false)` 가 있어 debug 빌드에서 OOS 포함 DB 의 `cubrid diagdb` 가 abort 했고(코드 주석 `file_manager.c:1432-1436`), 현재는 빈 줄 출력으로 우회된 상태다.

---

## Specification Changes

- `cubrid diagdb`(및 T1 적용 시 `spacedb`)의 OOS 파일 출력에 부모 HFID 행이 추가된다. 매뉴얼/QA answer 갱신 필요.
- OOS 파일의 `FILE_DESCRIPTORS` 레이아웃에 HFID 필드가 추가된다(신규 OOS 파일 한정; 기존 파일 호환성은 아래 결정 사항).

---

## Implementation

1. `FILE_DESCRIPTORS` 의 `descriptor.heap_overflow.hfid`(`file_manager.h:91`, `FILE_OVF_HEAP_DES`) 재사용 - 새 멤버 불필요(union 은 `FILE_DESCRIPTORS_SIZE` 64B 고정).
2. `oos_create_file`(`oos_file.cpp:910`) 시그니처에 부모 HFID 인자 추가. 호출 전 `des.heap_overflow.hfid` 에 채워 `file_create(FILE_OOS, ...)`(`:924`)로 전달. 부모 heap 이 선존재하므로 생성 후 갱신 불필요.
3. `file_header_dump_descriptor`(`file_manager.c:1424`)의 `FILE_OOS` case(`:1431`)에서 빈 줄 대신 `fhead->descriptor.heap_overflow.hfid` 로 "OOS for HFID: ..." 출력.
4. `oos_create_file` 모든 호출부 갱신(HFID 전달).
5. 기존 OOS 파일 마이그레이션 정책 확정 후 처리.
6. 매뉴얼/QA answer 갱신.

## Acceptance Criteria

- [ ] 신규 생성 OOS 파일의 descriptor 에 부모 HFID 가 저장됨
- [ ] `cubrid diagdb`(및 T1 적용 시 `spacedb`)가 OOS 파일을 부모 HFID/테이블에 귀속해 출력
- [ ] 기존 OOS 파일에 대한 동작이 정의되고(마이그레이션/무시) abort 없이 처리됨
- [ ] 매뉴얼/QA answer 갱신

## Definition of done

- [ ] 위 Acceptance Criteria 충족
- [ ] QA 통과
- [ ] 문서/매뉴얼 반영

---

## 참고 코드

- `src/storage/oos_file.cpp:910` - `oos_create_file`(부모 HFID 인자 없음), `:924` `file_create(FILE_OOS, ...)`
- `src/storage/file_manager.c:1424` - `file_header_dump_descriptor`, `:1431` `FILE_OOS` case(빈 줄), `:1446` heap_overflow HFID 출력 패턴(모델)
- `src/storage/file_manager.h:90` - `FILE_OVF_HEAP_DES`(`{HFID hfid; OID class_oid;}`), `FILE_DESCRIPTORS` union(64B)

## Remarks

- 관련: CBRD-26583(epic), CBRD-26871(OOS 병합 QA 검증; 본 이슈는 그 T2 선행과제), CBRD-XXXXX(T1 - spacedb OOS 카테고리)
- T1 과 함께 적용하면 `cubrid spacedb`/`diagdb` 가 테이블별 OOS 공간을 보고 가능
