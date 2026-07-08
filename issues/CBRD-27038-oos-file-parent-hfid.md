# [OOS] [M2] OOS 파일에 소유 테이블 정보 저장 및 online checkdb 보호

> JIRA: CBRD-27038 / 부모 epic: CBRD-26583 / 발단: CBRD-26871(OOS 병합 QA 검증 시나리오)의 툴링 선행과제 T2

## Issue Triage

**이슈 수행 목적**: OOS 파일(`FILE_OOS`)이 어느 테이블에 속하는지 파일 descriptor 에 저장한다. 그러면 `diagdb`, `spacedb`, online `checkdb` 가 OOS 파일을 안전하게 다룰 수 있다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | OOS 파일은 생성될 때 부모 heap 파일 정보와 class OID 를 `FILE_DESCRIPTORS` 에 저장하지 않는다. 그래서 `diagdb` 는 OOS 파일이 어느 테이블의 파일인지 출력하지 못하고, online `checkdb` 는 OOS 파일을 class lock 으로 보호할 수 없다. |
| **TO-BE (목표 상태 / 기대 동작)** | OOS 파일 descriptor 에 부모 HFID(테이블 heap 파일 식별자)와 class OID 를 저장한다. `diagdb` 는 부모 HFID 를 출력하고, online `checkdb` 는 class lock 을 잡은 뒤 OOS file table 을 검사한다. |
| **영향** | 진단/QA 곤란. OOS 공간이 어느 테이블에서 생겼는지 알 수 없고, online `checkdb` 는 현재 OOS file table 손상을 검사하지 못한다. |

**이슈 수행 방안**: OOS 파일 생성 시 `FILE_DESCRIPTORS` 의 기존 `heap_overflow` 영역을 재사용해 부모 HFID 와 class OID 를 채운다. 기존 heap overflow 파일도 같은 descriptor 영역에 부모 정보를 저장하고 있다. 그 뒤 `FILE_OOS` 를 heap overflow 파일과 같은 방식으로 dump 하고, online `checkdb` 의 tracker 순회에서도 class lock 으로 보호한 뒤 반환한다. 기존 OOS 파일의 빈 descriptor 처리 정책은 `TBD - 합의 미확인`.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/oos_file.cpp`, `src/storage/file_manager.c`, `src/storage/file_manager.h` 가 주 대상이다.
- **사용자-visible 변화**: `cubrid diagdb` 출력에 OOS 파일의 부모 HFID 가 보일 수 있다. `spacedb` 의 테이블별 OOS 공간 표시와도 이어진다.
- **호환성**: `FILE_DESCRIPTORS` 는 64 바이트 union 이다. 기존 `heap_overflow` descriptor 모양을 재사용하면 descriptor 크기 변경은 필요 없다.
- **남은 결정**: 이미 만들어진 OOS 파일에 부모 정보가 없을 때 어떻게 처리할지 정해야 한다.

## Description

OOS(Out-of-row Overflow Storage)는 큰 가변 컬럼 값을 heap 레코드 밖의 OOS 파일에 저장하는 기능이다. OOS 파일은 테이블 heap 파일과 1:1 로 대응한다. 하지만 지금 OOS 파일 자체에는 “내가 어느 heap 파일의 OOS 파일이다”라는 정보가 없다.

이 정보가 없으면 진단 도구가 OOS 파일을 테이블에 연결하지 못한다.

```
현재 구조

heap file
  └─ heap header 안에 oos_vfid 저장
       └─ OOS file

역방향 정보 없음

OOS file
  └─ 부모 HFID/class OID 없음
```

`file_header_dump_descriptor()` 는 파일 descriptor 를 보고 파일 설명을 출력한다. `FILE_MULTIPAGE_OBJECT_HEAP` 는 `descriptor.heap_overflow.hfid` 로 부모 HFID 를 출력한다. 반면 `FILE_OOS` 는 부모 정보가 없어서 같은 방식으로 출력할 수 없다.

online `checkdb` 에도 같은 문제가 있다. online `checkdb` 는 실행 중인 서버에서 돈다. 따라서 `DROP TABLE` 같은 DDL 과 동시에 실행될 수 있다. 이런 상황에서 file tracker 가 mutable file 을 caller 에게 넘기려면, 그 파일의 class lock 을 잡아 파일이 사라지지 않게 보호해야 한다.

하지만 OOS 파일 descriptor 에 class OID 가 없으면 lock 을 잡을 대상이 없다. 그래서 CBRD-27028 / PR #7415 는 online tracker 에서 `FILE_OOS` 를 조용히 건너뛰도록 했다. 이 선택은 assert 를 피하기 위한 안정화로는 맞지만, online `checkdb` 가 OOS file table 을 검사하지 못하는 제한을 남긴다.

이 이슈는 그 제한을 없애기 위한 후속 작업이다.

## Specification Changes

- 새로 생성되는 OOS 파일의 descriptor 에 부모 HFID 와 class OID 를 저장한다.
- `cubrid diagdb` 는 OOS 파일에 대해 부모 HFID 를 출력한다.
- online `checkdb` 는 `FILE_OOS` 를 더 이상 무조건 건너뛰지 않는다. class lock 을 잡을 수 있으면 OOS file table 을 검사한다.
- 기존 OOS 파일에 부모 정보가 없는 경우의 정책은 `TBD - 합의 미확인`.

## Implementation

### Descriptor 저장

`FILE_DESCRIPTORS` 에는 이미 heap overflow 파일용 구조가 있다.

```c
typedef struct file_ovf_heap_des FILE_OVF_HEAP_DES;
struct file_ovf_heap_des
{
  HFID hfid;
  OID class_oid;
};
```

OOS 파일도 테이블 heap 에 딸린 파일이므로 이 구조를 재사용할 수 있다. 새 멤버를 추가하지 않아도 된다. 기존 heap overflow 파일도 같은 descriptor 영역에 부모 정보를 저장하고 있다.

근거 코드: `heap_ovf_find_vfid()` 는 heap overflow 파일을 만들 때 같은 `heap_overflow` descriptor 에 부모 HFID 와 class OID 를 채운다.

```c
/* src/storage/heap_file.c */
memset (&des, 0, sizeof (des));
HFID_COPY (&des.heap_overflow.hfid, hfid);
des.heap_overflow.class_oid = heap_hdr->class_oid;
if (file_create_with_npages (thread_p, FILE_MULTIPAGE_OBJECT_HEAP, 1, &des, ovf_vfid) != NO_ERROR)
```

```
oos_create_file()
  └─ FILE_DESCRIPTORS des 초기화
       ├─ des.heap_overflow.hfid = 부모 HFID
       └─ des.heap_overflow.class_oid = 부모 class OID
  └─ file_create(FILE_OOS, ..., &des, ...)
```

### 생성 경로 변경

`oos_create_file()` 은 현재 부모 정보를 받지 않는다. 시그니처를 바꿔 부모 HFID 와 class OID 를 받도록 한다.

호출부는 `heap_oos_find_vfid()` 가 핵심이다. 이 함수는 heap header 를 읽고 있으며, 그 안에 class OID 가 있다. 따라서 OOS 파일을 만들기 전에 필요한 부모 정보를 채울 수 있다.

### dump 출력

`file_header_dump_descriptor()` 의 `FILE_OOS` case 는 빈 설명 대신 부모 HFID 를 출력한다.

예상 형태:

```text
OOS for HFID: <volid>|<fileid>|<hpgid>
```

문구는 기존 `Overflow for HFID: ...` 와 맞춰 최종 결정한다.

### online checkdb 보호

`file_tracker_get_and_protect()` 에서 `FILE_OOS` skip 을 제거한다. 이후 흐름은 heap overflow 와 같게 둔다.

```
FILE_OOS tracker item
  └─ file header fix
      └─ descriptor.heap_overflow.class_oid 읽기
          ├─ class lock 성공 -> VFID 반환, file_table_check 실행
          └─ class lock 실패 -> 해당 파일만 건너뜀
```

기존 heap overflow 파일은 이미 같은 흐름으로 online `checkdb` 보호를 받는다.

1. checkdb 의 heap overflow 검사는 `CHECKDB_FILE_TRACKER_CHECK` 경로에서 수행된다.
2. `file_tracker_interruptable_iterate(FILE_UNKNOWN_TYPE)` 가 `FILE_MULTIPAGE_OBJECT_HEAP` 항목을 만난다.
3. `file_tracker_get_and_protect()` 가 `descriptor.heap_overflow.class_oid` 를 읽고 class 에 `SCH_S_LOCK` 을 조건부로 건다.
4. lock 성공 시 overflow VFID 를 반환하고, `file_table_check()` 가 overflow 파일 테이블과 할당 sector 유효성을 검사한다.
5. 즉 overflow 레코드 내용을 heap 처럼 의미적으로 스캔하는 것이 아니라, DROP 과 겹치지 않게 보호한 뒤 파일 테이블 무결성을 검사한다.

기존 파일처럼 class OID 가 비어 있으면 보호할 수 없다. 이 경우는 기존 OOS 파일 처리 정책에 맞춰 skip 하거나 보정한다. 정책은 아직 미정이다.

## Acceptance Criteria

- [ ] 새로 생성되는 OOS 파일 descriptor 에 부모 HFID 와 class OID 가 저장된다.
- [ ] `cubrid diagdb` 가 OOS 파일의 부모 HFID 를 출력한다.
- [ ] online `checkdb` 가 class lock 으로 보호한 뒤 OOS file table 을 검사한다.
- [ ] online `checkdb` 와 `DROP TABLE` 이 겹쳐도 assert 나 잘못된 corruption 판정 없이 동작한다.
- [ ] 기존 OOS 파일에 부모 정보가 없는 경우의 동작이 정해진다.
- [ ] 필요한 QA answer 또는 문서가 갱신된다.

## Definition of done

- [ ] 위 Acceptance Criteria 충족
- [ ] QA 통과
- [ ] 문서/매뉴얼 반영

---

## 참고 코드

- `src/storage/oos_file.cpp:910` - `oos_create_file`, 현재 부모 HFID/class OID 인자 없음
- `src/storage/oos_file.cpp:924` - `file_create(FILE_OOS, ...)`
- `src/storage/heap_file.c:12277` - `heap_oos_find_vfid()`, OOS 파일 lazy create 경로
- `src/storage/file_manager.c:1424` - `file_header_dump_descriptor()`
- `src/storage/file_manager.c:1431` - `FILE_OOS` dump case
- `src/storage/file_manager.c:1446` - heap overflow 의 부모 HFID 출력 패턴
- `src/storage/file_manager.c:10931` - `file_tracker_get_and_protect()` 의 `FILE_OOS` skip
- `src/storage/file_manager.h:90` - `FILE_OVF_HEAP_DES`
- `src/storage/file_manager.h:129` - `FILE_DESCRIPTORS_SIZE` 64 바이트 고정

## Remarks

- 관련: CBRD-26583, CBRD-26871
- 관련: CBRD-27028 / PR #7415. 해당 PR 은 `FILE_OOS` 때문에 utility 가 assert 로 죽지 않게 하는 안정화 작업이다.
- 관련 후속: `SPACEDB_OOS_FILE` 카테고리를 추가하면 `spacedb` 에서 OOS 공간을 heap 과 분리해 보여 줄 수 있다.
