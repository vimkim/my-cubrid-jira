# [OOS] unloaddb/compactdb 의 OOS 컬럼 값 손실 (#7093 expand opt-in 회귀)

## Issue Triage

**이슈 수행 목적**: OOS 컬럼(큰 가변 컬럼)을 가진 행을 `unloaddb` 로 내보내거나 `compactdb` 오프라인 정리로 다룰 때, #6766 에서 넣었다가 #7093 에서 빠진 OOS 값 펼침(expand)을 복구해 값이 손실되지 않도록 한다.

**이슈 수행 이유**:

`OOS` (Out-of-row Storage. heap 레코드의 큰 가변 컬럼을 별도 페이지로 분리하고, heap 안에는 그 위치(8바이트 OID)와 길이(8바이트)로 이루어진 16바이트 인라인 스텁(`OR_OOS_INLINE_SIZE`)만 남기는 저장 방식)에서, `unloaddb` 가 큰 컬럼 값을 통째로 잃는 회귀가 있다.

- **현재 동작 / 배경**: #6766 (CBRD-26458, `OOS supports unloaddb`) 은 fetch 공통 경로 `heap_get_record_data_when_all_ready` 에서 OOS 를 **무조건** 펼치게 만들어, `unloaddb` 가 값을 받도록 고쳤다. 이후 #7093 (CBRD-26729) 이 펼침을 opt-in 으로 바꾸면서(`if (!context->expand_oos) return`, `heap_oos.cpp:342`) 호출자들을 `heap_get_visible_version_expand_oos` 로 전환했는데, 형제 경로 `xlocator_lock_and_fetch_all` (`locator_sr.c:12125` 부근)은 전환됐지만 `unloaddb` 가 실제로 쓰는 대량 인스턴스 경로 `xlocator_fetch_all` (`heap_next` 사용, `locator_sr.c:2906`)은 누락됐다. 받는 쪽 디코더 `desc_disk_to_obj` -> `get_desc_current` (`src/loaddb/load_object.c`) 는 OOS 를 전혀 모르므로(이 파일에 `oos` 코드 0줄) 펼치지 않은 스텁을 값으로 해석하지 못한다.
- **영향**: 데이터 손실(회귀). 실측 결과 OOS 컬럼(`DISK_SIZE` 50008바이트)을 가진 행을 `unloaddb` 하면 그 컬럼이 빈 값 `X''` 로 나온다. 같은 테이블의 비-OOS 행은 정상이라, 백업/이행 시 큰 컬럼만 조용히 통째로 사라진다.

**이슈 수행 방안**:

`unloaddb` 의 fetch 경로가 OOS 를 다시 펼치도록 복구하되, #7093 의 opt-in 설계는 유지한다 (전체 무조건 펼침으로 되돌리지 않는다).

| 수준 | 경로 | 조치 |
|------|------|------|
| 값(value) | `unloaddb` 의 `xlocator_fetch_all`, `compactdb` 오프라인 참조정리의 `locator_fetch_all` | 형제 `xlocator_lock_and_fetch_all` 처럼 OOS 를 펼쳐서(expand) 클라이언트에 보낸다 |
| 물리(physical) | heap 페이지 압축 `spage_compact` (`heap_compact_pages`) | 이 경로를 타지 않으며 OOS 스텁을 그대로 둬야 한다. 변경 금지, 검증 테스트만 |

`compactdb` 오프라인 참조정리는 `unloaddb` 와 같은 `locator_fetch_all` + `desc_disk_to_obj` 경로라 같은 회귀를 공유한다(코드 경로 동일 기반 추론, 별도 실측은 후속). 다시 저장(`disk_update_instance`)까지 하므로 깨진 값이 영구 기록될 수 있어 더 위험하다. 다만 compactdb 는 재저장 의미 때문에 단순 server expand 가 맞는지 자체가 ANALYSIS 대상이다(`unloaddb` 와 수정 방식이 다를 수 있다). 단일 객체 fetch `xlocator_fetch` -> 워크스페이스 디코드 `tf_disk_to_mem` 도 같은 노출 가능성이 있어 확인 후 결정. 정확한 수정 위치 선택은 `TBD - ANALYSIS 단계에서 결정`.

사용자 인용: "unloaddb focuses on reading the values ... so OOS OIDs must disappear before network send, while compactdb tries to compact the heap page so it must know the exact size of recdes, without OOS OIDs replaced to value".

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/git 이력/실측을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **문제 / 목적**: `unloaddb` 가 OOS 컬럼 값을 빈 값으로 내보내는 회귀를 고친다.
- **원인 / 배경**: #7093 이 OOS 펼침을 opt-in 으로 바꾸며 `xlocator_fetch_all`(unloaddb 경로)을 `_expand_oos` 로 전환하지 못해, #6766 이 넣은 펼침이 무력화됐다.
- **제안 / 변경**: value 소비자 경로에서 서버가 다시 펼쳐 보낸다. physical 압축은 그대로 둔다.
- **영향 범위**: `unloaddb`, `compactdb` 오프라인 정리, 클라이언트 디코더 `load_object.c`. OOS 컬럼을 가진 테이블만 해당. 출시 전 `feat/oos` 기능.

---

## Description

비유로 먼저 보면 이렇다. heap 레코드는 "상자"이고, 큰 컬럼 값은 너무 커서 상자 밖 창고에 두고 상자 안에는 "창고 위치 메모(16바이트 인라인 스텁: 8바이트 OID + 8바이트 길이)" 만 넣어 둔다. `unloaddb` 는 상자 내용을 베껴 파일로 내보내는데, 받는 쪽 디코더가 이 메모를 해석하지 못해 그 컬럼을 빈 값으로 떨어뜨린다. 결국 내보낸 파일에는 창고 안의 진짜 물건이 통째로 빠진다.

핵심은 같은 heap 레코드를 두 방식으로 쓴다는 점이다.

- **값(value) 으로 해석하는 소비자** (`SELECT`, `unloaddb`): 컬럼의 실제 값이 필요하므로, 서버가 인라인 스텁을 실제 값으로 펼쳐서 줘야 한다.
- **물리(physical) 구조로 다루는 소비자** (heap 페이지 압축): 디스크에 적힌 레코드 바이트 그 자체를 옮기므로, 16바이트 스텁이 그대로 있어야 한다. 펼쳐서 값으로 바꾸면 레코드가 슬롯보다 커져 페이지가 깨진다.

`SELECT` 가 멀쩡한 이유는, 질의 결과는 OOS 를 아는 속성 계층(`heap_attrinfo_read_dbvalues`)을 거쳐 펼쳐진 값 튜플로 나오기 때문이다. `unloaddb` 는 그 계층을 거치지 않고 `recdes` (heap 레코드 디스크립터. 디스크에 적힌 레코드 바이트와 길이를 담는 구조체) 바이트를 직접 해석하므로, 서버가 미리 펼쳐 주지 않으면 값을 잃는다.

### 회귀 이력 (git)

```
a8a192f33  #6766 [CBRD-26458] OOS supports unloaddb: client receives OOS values instead of raw OOS OIDs
            -> heap_get_record_data_when_all_ready 에서 OOS 를 무조건 펼침 (커밋 의도상 unloaddb 가 값을 받게 됨; a8a192f33 시점 실측은 미수행).

4a6805e37  #7093 [CBRD-26729] Re-enable OOS OID replacement without class repr
            -> 펼침을 opt-in 으로 변경 (heap_oos.cpp: if (!context->expand_oos) return).
            -> locator_sr.c 의 8개 호출자를 _expand_oos 로 전환 (xlocator_lock_and_fetch_all 포함).
            [!] xlocator_fetch_all (unloaddb 대량 경로, heap_next) 는 전환에서 누락 -> 회귀 발생.
```

### 코드 흐름

```
[unloaddb 경로 = 값 해석: OOS 를 펼쳐야 하는데 #7093 이후 안 펼친다]

 unload_object.c:1535  locator_fetch_all
   -> 서버 xlocator_fetch_all (locator_sr.c:2775, 내부 heap_next at 2906)
        [!] expand_oos=false 라 heap_record_replace_oos_oids 가 그냥 반환 -> 스텁이 recdes 에 그대로
   -> 클라이언트 desc_disk_to_obj (load_object.c:914) -> get_desc_current
        [!] OOS 를 모름 -> 스텁을 해석 못 하고 컬럼을 빈 값으로 떨어뜨림

[heap 압축 경로 = 물리 구조: 그대로 둬야 하고, 실제로 그대로 둔다 (정상)]

 xboot_heap_compact (boot_sr.c:5851) -> heap_compact_pages (heap_file.c:18339)
        -> spage_compact (heap_file.c:18419)
           [ok] 페이지 안에서 레코드 바이트를 통째로 옮김. 값 해석 안 함, OOS 파일 안 건드림
```

### Test Build

`feat/oos` 브랜치 (`origin/feat/oos`, debug 빌드). 출시 전 기능이라 정식 릴리스 버전은 없다. 회귀 도입 커밋은 `4a6805e37` (#7093).

### Repro

```sql
-- 1) 비-OOS 대조행(id=1)과 OOS 행(id=2) 삽입. id=2 는 demotion 임계치(heap_file.c:12206 의 DB_PAGESIZE/4, 기본 16K 페이지 기준 4096바이트)를 넘겨 OOS 로 분리된다.
csql -S -c "CREATE TABLE t (id INT PRIMARY KEY, big BIT VARYING); INSERT INTO t VALUES (1, REPEAT(X'CD', 10)); INSERT INTO t VALUES (2, REPEAT(X'AB', 50000)); COMMIT;" testdb

-- 2) 저장 크기 확인: id=2 의 DISK_SIZE 가 임계치를 크게 넘는다 (실측 50008바이트)
csql -S -c "SELECT id, DISK_SIZE(big) FROM t ORDER BY id;" testdb
```

```bash
# 3) 서버를 띄운 뒤 unloaddb (클라이언트가 네트워크로 recdes 를 받는 경로)
cubrid server start testdb
cubrid unloaddb testdb
cubrid server stop testdb

# 4) 생성된 데이터 파일 확인
cat testdb_objects
```

### Expected Result

`testdb_objects` 에서 id=2 의 `big` 값이 INSERT 한 `REPEAT(X'AB', 50000)` 전체로 나온다 (긴 `X'abab...'`).

### Actual Result

id=2 의 `big` 이 빈 값으로 나온다. 대조행 id=1(비-OOS)은 정상이라, OOS 컬럼만 손실된다.

```
%id [public].[t] 74
%class [public].[t] ([id] [big])
1 X'cdcdcdcdcdcdcdcdcdcd'   <- 비-OOS, 정상
2 X''                       <- OOS, 값 손실
```

CS 모드(서버 기동)와 SA 모드(`cubrid unloaddb --SA-mode`) 모두에서 동일하게 재현된다.

### Additional Information

- **형제 경로는 #7093 에서 전환됐다.** `xlocator_lock_and_fetch_all` (`locator_sr.c:12125` 부근)은 `_expand_oos` 로 바뀌었지만 대량 인스턴스 경로 `xlocator_fetch_all` 만 누락됐다.
- **compactdb 는 두 갈래다.** 오프라인 참조정리(`compactdb.c:442` 의 `desc_disk_to_obj`)는 `unloaddb` 와 같은 경로라 같은 회귀를 공유하며, `disk_update_instance` 로 다시 저장하므로 영구 손상 위험이 있다. 물리 페이지 압축(`spage_compact`)은 이 경로를 타지 않고 OOS 스텁을 그대로 옮기므로 정상이며, 건드리면 안 된다.
- **단일 객체 fetch 경로**: `xlocator_fetch` -> 워크스페이스 디코드 `tf_disk_to_mem` 도 OOS 를 모를 가능성이 있다. SQL `SELECT` 는 안전(결과는 이미 펼쳐진 값 튜플). 확인 후 별도 처리 여부 결정.
- **관련 이슈**: CBRD-26458(#6766, unloaddb expand 최초 도입), CBRD-26729(#7093, opt-in 전환 및 회귀 도입), CBRD-26847(opt-in 호출자 전수조사 후속), 부모 CBRD-26583(OOS M2).

## Remarks

후속 분리 검토: (A) `xlocator_fetch_all`/`compactdb` 오프라인 경로의 서버측 OOS expand 복구, (B) 물리 압축이 OOS 레코드를 보존하는지 검증 테스트 추가, (C) `xlocator_fetch` 단일 객체 경로의 OOS 노출 확인.
