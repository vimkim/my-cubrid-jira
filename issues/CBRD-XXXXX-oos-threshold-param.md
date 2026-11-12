# [OOS] [TODO] 행의 값을 OOS로 보내는 기준을 조절하는 시스템 파라미터 추가

**한 줄 요약**: PR #7990 리뷰어가 제시한 병합 기준 2(기본 설정에서 4~16KB 행의 전체 읽기가 develop보다 느려지지 않을 것)를 CBRD-27788에서 재측정했더니 고정 OOS 임계값(약 4KB)에서는 −2.8%~−69.5%였다. 이에 대응하여 OOS 임계값을 "한 페이지를 넘을 때만"과 "OOS를 쓰지 않음"으로 바꿀 수 있는 시스템 파라미터를 다루는 후속 이슈다.

## Issue Triage

**이슈 수행 목적**: 운영자가 서버 설정으로 행의 값을 OOS로 보내는 기준을 고를 수 있게 한다. 최소한 두 설정을 지원한다. 하나는 행이 한 페이지(develop의 overflow 경계, 약 16KB)를 넘을 때만 OOS를 쓰는 설정이고, 다른 하나는 OOS를 전혀 쓰지 않고 큰 행을 develop처럼 overflow로 저장하는 설정이다.

**이슈 수행 이유**: `feature/oos-merge` `67220b7e2`에는 임계값 파라미터가 없다. 임계값은 한 페이지에 행 4개가 들어가는 고정 크기(16KiB 페이지에서 약 4KB)다. 그래서 develop에서 heap 안에 저장되던 4~16KB 행이 OOS로 옮겨지고, 이 행들의 전체 읽기가 develop보다 CPU 명령어를 2.8%~69.5% 더 쓴다(CBRD-27788, 측정). 임계값을 overflow 경계로 올린 측정 전용 빌드에서는 같은 경우가 −0.24%~+0.08%였다(측정). 리뷰어 기준을 맞추거나 사용자가 이 손해를 피할 방법이 현재는 없다.

**영향**: 4~16KB 행을 전체로 읽는 사용자는 OOS 통합 뒤 같은 질의에 CPU를 더 쓴다. 값이 작을수록 손해가 크고, 6KB 값은 −14%~−33%다(명령어 수, 메모리에 다 올라간 상태). 반대로 같은 행에서 작은 컬럼만 읽는 질의는 OOS 덕분에 빨라지므로, 임계값을 올리면 그 이득도 사라진다(측정 전용 빌드에서 확인). 어느 쪽이 나은지는 workload마다 다르다. PR #7990 병합 검토에서는 기준 2를 맞출 수단이 없다는 점이 병합을 막는다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다. 파라미터 형태, 이름, 기본값, 컬럼 STORAGE 힌트와의 우선순위는 아래 "Open Decisions"에 후보와 근거를 정리했다.

---

## AI-Generated Context

> 아래는 2026-11-12에 `feature/oos-merge` `67220b7e2`의 코드, CBRD-27788 재측정 결과, PR #8416(미병합) 설명을 읽고 정리한 맥락이다. 코드에서 확인한 사실, 측정값, 추정을 구분한다. CUBRID 코드는 바꾸지 않았다.

## Description

### 용어

- **OOS(Out-of-row Overflow Storage)**: 행이 커지면 큰 가변 길이 값을 heap 행 밖의 별도 파일에 저장하고, 행에는 위치(stub)만 남기는 기능이다.
- **overflow(`REC_BIGONE`)**: develop에서 한 페이지를 넘는 행 전체를 여러 overflow 페이지에 나눠 저장하는 기존 방식이다. 경계는 `heap_Maxslotted_reclength`다.
- **OOS 임계값**: heap 행 크기가 이 값을 넘으면 가장 큰 가변 길이 컬럼부터 OOS로 옮기는 기준이다.

### 현재 동작 (코드, `67220b7e2`)

- 임계값은 [`heap_oos_inline_target_size()`](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L13746)가 계산한다. 행 4개와 slot이 한 페이지에 들어가는 크기(`HEAP_OOS_MIN_RECS_PER_PAGE 4`)이며, 설정으로 바꿀 수 없다. 16KiB 페이지에서 OOS 적용 뒤 heap 행은 4,012B였다(CBRD-27788 측정).
- [`heap_attrinfo_determine_disk_layout()`](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L13780)이 OOS로 보낼 컬럼을 고른다. 순서는 다음과 같다.
  1. `STORAGE FORCE_OUTLINE` 컬럼의 값이 stub보다 크면 행 크기와 관계없이 OOS로 보낸다([L13817](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L13817)). 임계값을 보지 않는다.
  2. 헤더 + payload + MVCC 여유분(`OR_MVCC_MAX_HEADER_SIZE − OR_MVCC_INSERT_HEADER_SIZE` = 16B)이 임계값을 넘으면, 남은 가변 길이 컬럼을 큰 것부터 OOS로 보낸다. `STORAGE PREFER_INLINE` 컬럼은 맨 뒤로 미룬다([L13841](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L13841)).
- OOS로 보낸 뒤에도 행이 overflow 경계를 넘으면 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE`로 쓰기를 거부한다. OOS 값과 `REC_BIGONE`이 한 행에 같이 있을 수 없기 때문이다([L14939](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L14939)). OOS 값이 없는 행은 지금 `REC_BIGONE`으로 저장된다.
- 클라이언트가 만든 레코드(copy area)도 서버가 [`heap_oos_needs_record_preparation()`](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_oos.cpp#L119)에서 같은 임계값으로 다시 배치할지 정한다([L129](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_oos.cpp#L129)). 파라미터를 넣으면 이 판정도 같은 값을 써야 한다.

### 측정 근거 (CBRD-27788, 2026-11-11~12)

서버 `instructions:u` 중앙값, 변화율 = (develop − 비교 대상) / develop이다. +가 좋아짐이다. 상세는 [CBRD-27788 "후속 측정 결과 (2026-11-12)"](https://jira.cubrid.org/browse/CBRD-27788)와 [재측정 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-27788/CBRD-27788-ac-p2-p3-remeasure_67220b7_claude.md)에 있다.

| 조건 | 4.6~13.8KB 값 전체 읽기 12개 경우 | 비고 |
| --- | --- | --- |
| 기본 임계값(약 4KB) | −2.8% ~ −69.5% | 6KB는 −14% ~ −33%. 잠정 2% 목표 밖 |
| 임계값 = `heap_Maxslotted_reclength`인 측정 전용 빌드 | −0.24% ~ +0.08% | 값이 develop처럼 heap에 남는다. 작은 컬럼 조회의 OOS 이득은 사라진다 |

측정 전용 빌드는 `heap_oos_inline_target_size()`가 `heap_Maxslotted_reclength`를 반환하게 한 한 줄 변경이며, push하지 않았다. "OOS를 쓰지 않음" 설정은 아직 측정하지 않았다.

### "16KB"와 "never"는 한 페이지를 넘는 행에서만 다르다

임계값을 `heap_Maxslotted_reclength`로 두면, 한 페이지에 들어가는 행은 develop처럼 heap에 남는다. 한 페이지를 넘는 행은 여전히 큰 컬럼이 OOS로 가고 heap에는 stub이 든 행이 남는다(코드 읽기). develop은 이 행을 `REC_BIGONE`으로 저장하므로 저장 위치가 다르다. CBRD-27788의 overflow→OOS 모든 컬럼 읽기(Q5)가 −6.05%인 경로가 이것이다. "never"는 이 행까지 develop처럼 overflow로 보내는 설정이다.

경계 근처에서는 작은 차이가 남을 수 있다. OOS 판정은 MVCC 여유분 16B를 더해 비교하므로, overflow 경계에서 16B 안쪽인 행은 develop에서는 heap에 남지만 "16KB" 설정에서는 OOS로 갈 수 있다(추정, 미확인). develop의 overflow 판정이 같은 여유분을 쓰는지 ANALYSIS에서 확인한다.

### 기존 데이터와 설정 변경 (코드 읽기, 테스트로 확인 필요)

- **이미 OOS에 있는 값은 그대로 읽힌다.** 읽기 경로는 각 행의 가변 offset 항목에 있는 OOS flag(`OR_IS_OOS`)로 OOS 여부를 판단한다([`heap_attrvalue_point_variable` L11655](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L11655)). 임계값을 보지 않는다.
- **설정 변경은 새 INSERT와 UPDATE에만 적용된다.** 임계값을 쓰는 곳은 배치 계산([L13841](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L13841))과 copy area 재배치 판정([heap_oos.cpp L129](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_oos.cpp#L129)) 두 곳뿐이다.
- **OOS 값이 있는 행을 UPDATE하면 행 전체를 다시 배치한다.** [`heap_attrinfo_transform_to_disk_internal`](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L14877)은 바뀌지 않은 컬럼 값까지 읽어 온 뒤([L14901](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L14901)) 모든 컬럼으로 배치를 다시 계산한다([L14913](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L14913)). 따라서 임계값을 올린 뒤 UPDATE된 행은 OOS 값이 heap으로 돌아올 수 있다. 작은 컬럼만 바꾸는 UPDATE도 이 비용을 낸다. 실제 동작은 ANALYSIS에서 테스트로 확인한다.
- 한 테이블 안에 heap 값, OOS 값, `REC_BIGONE` 행이 섞일 수 있다. 읽기는 행마다 판단하므로 섞여도 읽을 수 있어야 한다(추정). unloaddb → loaddb 시 새 설정으로 다시 배치된다(추정).

### HA, loaddb, CS/SA 모드

- **HA**: replica는 master의 레코드를 다시 배치하지 않고 받은 대로 저장한다([`xlocator_repl_force` L7740](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/transaction/locator_sr.c#L7740), PR #8416 설명도 같다). 그래서 정상 상태의 저장 위치는 master 설정이 정한다(코드 읽기). failover 뒤에는 새 master의 설정이 적용되므로, 노드마다 설정이 다르면 failover 전후 새 행의 배치가 달라진다. 실제 HA 환경에서는 확인하지 않았다.
- **loaddb**: CS 모드 loaddb는 서버의 `locator_insert_force`/`locator_multi_insert_force`로 행을 쓰므로 서버 설정을 따른다(코드 읽기). SA 모드 loaddb와 compactdb 같은 SA 도구는 같은 프로세스의 파라미터를 읽으므로, SA 실행 시 설정 파일의 어느 절에서 값을 읽는지 정해야 한다.
- 선례로 heap 페이지 정책 파라미터 `unfill_factor`는 `PRM_FOR_SERVER | PRM_USER_CHANGE`다([system_parameter.c L1240](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/base/system_parameter.c#L1240)).

## Open Decisions

아래는 제품 결정이 필요한 항목이다. 후보는 ANALYSIS 입력이며, 아직 어느 것도 선택하지 않았다.

### 1. 파라미터 형태

| 후보 | 장점 | 단점 | 근거와 확인 사항 |
| --- | --- | --- | --- |
| A. 바이트 임계값 + "never" sentinel (예: 정수, `-1` 또는 `0` = OOS 쓰지 않음) | 4KB, 8KB, 16KB 같은 중간값도 실험할 수 있다. 현재 코드가 임계값 하나로 동작하므로 바꿀 곳이 적다 | 범위 검증이 필요하다. 하한은 stub 크기와 4행 기준, 상한은 `heap_Maxslotted_reclength`이며 페이지 크기마다 다르다. sentinel 의미를 문서로 따로 알려야 한다 | 측정 전용 빌드가 이 형태의 한 지점(상한)을 이미 측정했다 |
| B. enum (예: `quarter_page` 현재 동작 / `page` / `never`) | 지원하는 설정이 셋뿐이라 테스트 조합이 작다. 페이지 크기와 무관하게 의미가 같다 | 중간값을 실험할 수 없다. 나중에 값을 늘리면 enum이 바뀐다 | 리뷰어 기준과 이 이슈의 두 설정은 enum으로 충분하다 |
| C. boolean 두 개 (예: OOS 사용 여부, 페이지 초과 시에만 사용) | 이름만으로 의미가 분명하다 | 현재 동작까지 셋을 표현하려면 두 값의 조합 규칙이 필요하다. 의미 없는 조합이 생긴다 | B보다 나은 점이 확인되지 않았다 |

각 후보마다 다음을 정해야 한다.

- **이름**: 기존 이름 규칙(`unfill_factor` 등)을 따른다. 예시 이름은 확정이 아니다.
- **기본값**: 현재 동작(약 4KB) 유지, "16KB", "never" 중 하나다. 이 이슈 범위 밖의 제품 결정이다(아래 Out of Scope).
- **범위**: A는 바이트 하한·상한과 페이지 크기별 의미, B는 허용 값 목록이다.
- **적용 시점**: 서버 재시작이 필요한 static인지, 실행 중 바꿀 수 있는 dynamic인지 정한다. 읽기는 행마다 flag로 판단하므로 dynamic이어도 읽기 정합성 문제는 보이지 않는다(코드 읽기). 다만 같은 트랜잭션 안에서 행마다 배치가 달라질 수 있다.

### 2. 컬럼 STORAGE 힌트와의 우선순위

| 힌트 | 현재 동작 | 결정할 것 |
| --- | --- | --- |
| `STORAGE FORCE_OUTLINE` | 임계값과 관계없이 OOS로 보낸다 | "never"에서도 OOS로 보낼지, 파라미터가 힌트를 이길지 정한다. 힌트를 따르면 "never"여도 OOS 파일이 생긴다. 힌트를 무시하면 사용자가 명시한 DDL이 조용히 무시된다 |
| `STORAGE PREFER_INLINE` | 임계값을 넘으면 맨 마지막에 OOS로 보낸다 | 임계값만 바뀌므로 그대로 둬도 의미가 유지된다(추정). "never"에서는 의미가 없어진다 |
| `STORAGE FORCE_INLINE` (PR #8416, 미병합) | 그 컬럼은 OOS로 보내지 않는다 | 파라미터와 충돌하지 않는다(추정). 다만 아래 3번의 `REC_BIGONE` 거부와 함께 봐야 한다 |

### 3. "never"와 PR #8416의 `REC_BIGONE` 거부

[PR #8416](https://github.com/CUBRID/cubrid/pull/8416)(CBRD-27259, 미병합)은 시스템 클래스가 아닌 행이 `REC_BIGONE`이 될 크기면 OOS 값 유무와 관계없이 쓰기를 거부한다(PR 설명). 이 PR이 들어오면 "never" 설정에서 한 페이지를 넘는 행은 develop처럼 overflow로 저장되지 않고 거부된다. 그러면 "never"의 목표("develop과 같은 overflow 경로")를 달성할 수 없다. [CBRD-27924](https://jira.cubrid.org/browse/CBRD-27924)(SA compact 재작성)의 수행 방안도 "OOS로 옮길 값이 없어도 한 페이지를 넘는 행은 `REC_BIGONE`으로 쓰지 않는다"로 같은 방향이다. 두 변경 중 무엇을 먼저 넣을지, "never"일 때는 `REC_BIGONE`을 허용할지 정해야 한다.

### 4. HA, loaddb, CS/SA 모드의 설정 일치

모든 HA 노드에 같은 값을 요구할지, SA 도구가 어느 설정을 읽을지 정한다. 서로 다른 설정은 데이터 손상이 아니라 배치 차이만 만든다(추정). 그래도 운영 문서에 같은 값을 권장할지 정한다.

## Acceptance Criteria

- 지원하기로 한 각 설정(최소 "16KB"와 "never")에서 4~16KB 행이 develop과 같은 저장 위치(heap)에 있다. `SHOW HEAP CAPACITY`·`SHOW HEAP OOS`로 확인한다.
- 각 설정에서 CBRD-27788 AC-P2(4.6~13.8KB 값 전체 읽기 12개 경우)를 다시 측정한다. 기본값 결과와 파라미터를 설정한 결과를 따로 보고한다.
- "never"에서 한 페이지를 넘는 행의 저장 방식이 3번 결정과 일치한다(overflow 저장 또는 정해진 오류).
- 설정을 바꾸기 전에 OOS에 저장된 값이 설정 변경 뒤에도 읽힌다. 그 행을 UPDATE한 뒤의 배치가 새 설정을 따른다.
- `STORAGE FORCE_OUTLINE`·`PREFER_INLINE` 컬럼이 2번 결정대로 동작한다.
- 설정이 CS 모드, SA 모드, loaddb에서 정해진 대로 적용된다.

## Out of Scope

- 큰 행(overflow→OOS)의 모든 컬럼 읽기 Q5 −6.05% 비용 개선.
- 파일 캐시를 비운 뒤 큰 값 읽기 지연([CBRD-27791](https://jira.cubrid.org/browse/CBRD-27791)).
- 새 기본값 선택. 기본값은 제품 결정이며, PR #7990 병합 기준 2는 "기본 설정"을 말하므로 기준 2의 최종 판정은 이 결정에 달려 있다.

## Related

- 상위: [CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978) `[OOS] [EPIC] TODO`
- 측정: [CBRD-27788](https://jira.cubrid.org/browse/CBRD-27788), AC-P2 경위: [CBRD-27785](https://jira.cubrid.org/browse/CBRD-27785)
- 리뷰어 병합 기준: [PR #7990 10/28 댓글](https://github.com/CUBRID/cubrid/pull/7990#issuecomment-6461744209)
- 관련 PR: [PR #8416](https://github.com/CUBRID/cubrid/pull/8416) `STORAGE FORCE_INLINE`(CBRD-27259, 미병합)
- 현재 4행 기준 임계값을 정한 이슈: [CBRD-27057](https://jira.cubrid.org/browse/CBRD-27057)
- OOS + `REC_BIGONE` 거부: [CBRD-26937](https://jira.cubrid.org/browse/CBRD-26937), SA compact 배치 정책: [CBRD-27924](https://jira.cubrid.org/browse/CBRD-27924)
