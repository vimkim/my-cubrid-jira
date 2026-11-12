# [OOS] [TODO] OOS로 보내는 trigger 임계값을 시스템 파라미터로 설정

**한 줄 요약**: PR #7990 리뷰어가 제시한 병합 기준 2(기본 설정에서 4~16KB 행의 전체 읽기가 develop보다 느려지지 않을 것)를 CBRD-27788에서 재측정했더니 고정 trigger 임계값(4,060B)에서는 −2.8%~−69.5%였다. 이에 대응하여 큰 값은 계속 OOS에 저장하되, OOS로 보내기 시작하는 임계값을 사용자가 시스템 파라미터로 정할 수 있게 하는 후속 이슈다.

## Issue Triage

**이슈 수행 목적**: 운영자가 서버 설정으로 OOS trigger 임계값을 정할 수 있게 한다. 상한으로 설정하면 한 페이지에 들어가는 행은 heap 안에 그대로 두고, 한 페이지를 넘는 행만 큰 값을 OOS로 보낸다.

**이슈 수행 이유**: OOS 스펙에서 일반 테이블의 행은 overflow(`REC_BIGONE`)로 저장하지 않는다. 한 페이지를 넘는 행은 큰 값을 OOS로 보내야 하고, 그래도 넘으면 쓰기를 거부한다. 그런데 OOS로 보내기 시작하는 임계값은 한 페이지에 행 4개가 들어가는 고정값(16KiB 페이지에서 4,060B)이고 바꿀 수 없다. 그래서 develop에서 heap 안에 저장되던 4~16KB 행도 OOS로 옮겨지고, 이 행들의 전체 읽기가 develop보다 CPU 명령어를 2.8%~69.5% 더 쓴다(CBRD-27788, 측정). 임계값을 한 페이지 크기로 올린 측정 전용 빌드에서는 같은 경우가 −0.24%~+0.08%였다(측정).

**영향**: 4~16KB 행을 전체로 읽는 사용자는 OOS 통합 뒤 같은 질의에 CPU를 더 쓴다. 값이 작을수록 손해가 크고, 6KB 값은 −14%~−33%다(명령어 수, 데이터가 모두 메모리에 있는 상태). 반대로 같은 행에서 작은 컬럼만 읽는 질의는 OOS 덕분에 빨라지므로, 임계값을 올리면 그 이득은 사라진다(측정 전용 빌드에서 확인). 어느 쪽이 나은지는 workload마다 다르지만, 지금은 사용자가 고를 수 없다. PR #7990 병합 기준 2를 맞출 설정 수단도 없다.

**이슈 수행 방안**: 담당자 결정(2026-11-12)으로 두 가지를 정했다. 기본값은 PostgreSQL 관례(`TOAST_TUPLES_PER_PAGE` = 4)를 따라 지금의 "한 페이지에 행 4개" 기준을 유지하고, 파라미터 값을 바꿔 가며 측정한 뒤 종합 성능이 가장 좋은 값으로 바꾼다. PR #8416을 먼저 병합하고 이 파라미터 PR을 그 뒤에 넣으며, 상한은 overflow 경계(`heap_Maxslotted_reclength`)로 둔다. 파라미터 형태, 이름, 하한, 적용 시점은 ANALYSIS 단계에서 정한다. 근거는 아래 "Decisions"와 "Open Decisions"에 있다.

---

## AI-Generated Context

> 아래는 2026-11-12에 OOS 스펙(`OOS-CONTEXT.md`), `feature/oos-merge` `67220b7e2`와 PR #8416 head `19e5d178c`의 코드, CBRD-27788 재측정 결과를 읽고 정리한 맥락이다. 코드에서 확인한 사실, 측정값, 추정을 구분한다. CUBRID 코드는 바꾸지 않았다.

## Description

### 용어

- **OOS(Out-of-row Overflow Storage)**: 큰 가변 길이 값을 heap 행 밖의 별도 파일에 저장하고, 행에는 위치 정보(stub, 24B)만 남기는 기능이다.
- **trigger 임계값**: heap 행 크기가 이 값을 넘으면 가장 큰 가변 길이 컬럼부터 하나씩 OOS로 보내고, 행이 이 값 이하가 되면 멈춘다. 스펙은 시작(trigger)과 멈춤(stop)에 같은 값을 쓰도록 정한다.
- **overflow(`REC_BIGONE`)**: develop에서 한 페이지를 넘는 행 전체를 여러 overflow 페이지에 나눠 저장하던 방식이다. 한 페이지에 들어가는 최대 행 크기는 `heap_Maxslotted_reclength`다.

### 스펙과 현재 동작

- **overflow 금지.** 스펙(2026-11-09 결정)은 시스템 클래스가 아닌 행이 `REC_BIGONE`이 필요하면 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE`로 쓰기를 거부한다. 판정에는 MVCC 헤더 최대치를 넣는다. 이 거부를 넓히는 변경은 [PR #8416](https://github.com/CUBRID/cubrid/pull/8416)(CBRD-27259, 미병합)에 있다. PR head `19e5d178c`는 OOS 값 유무와 관계없이 시스템 클래스가 아닌 행이 한 페이지를 넘으면 거부한다([heap_file.c L14939](https://github.com/CUBRID/cubrid/blob/19e5d178c6eea0fc8800775b5939c89bc18e2551/src/storage/heap_file.c#L14939)). `67220b7e2`는 아직 OOS 값이 있는 행만 거부한다([heap_file.c L14939](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L14939)).
- **고정 임계값.** [`heap_oos_inline_target_size()`](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L13746)가 `(heap_nonheader_page_capacity() − 4 × slot) / 4`를 내림 정렬해 계산한다(CBRD-27057). 16KiB 페이지에서 4,060B이며 설정으로 바꿀 수 없다.
- **임계값을 쓰는 곳은 두 곳이다.**
  - INSERT·UPDATE의 행 배치 계산([`heap_attrinfo_determine_disk_layout` L13841](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L13841)). 헤더 + payload + MVCC 여유분(16B)을 임계값과 비교한다.
  - 클라이언트가 만든 레코드(copy area)를 서버가 다시 배치할지 정하는 판정([`heap_oos_needs_record_preparation` L129](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_oos.cpp#L129)).

### 측정 근거 (CBRD-27788, 2026-11-11~12)

서버 `instructions:u` 중앙값, 변화율 = (develop − 비교 대상) / develop이다. +가 좋아짐이다. 상세는 [CBRD-27788 "후속 측정 결과 (2026-11-12)"](https://jira.cubrid.org/browse/CBRD-27788)와 [재측정 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-27788/CBRD-27788-ac-p2-p3-remeasure_67220b7_claude.md)에 있다.

| 조건 | 4.6~13.8KB 값 전체 읽기 12개 경우 | 비고 |
| --- | --- | --- |
| 고정 임계값(4,060B) | −2.8% ~ −69.5% | 6KB는 −14% ~ −33%. 잠정 2% 목표 밖 |
| 임계값 = `heap_Maxslotted_reclength`인 측정 전용 빌드 | −0.24% ~ +0.08% | 값이 develop처럼 heap에 남는다. 작은 컬럼 조회의 OOS 이득은 사라진다 |

측정 전용 빌드는 `heap_oos_inline_target_size()`가 `heap_Maxslotted_reclength`를 반환하게 한 한 줄 변경이며, push하지 않았다.

### 상한을 한 페이지로 두면 생기는 일

임계값이 `heap_Maxslotted_reclength`이면 배치 판정과 overflow 거부 판정이 같은 경계를 쓴다(코드 읽기). 배치 판정은 "헤더 + payload + 16B > 임계값"일 때 OOS로 보내고, 거부 판정은 OOS로 보낸 뒤 "헤더 + payload + 16B > `heap_Maxslotted_reclength`"일 때 거부한다. 그래서 OOS로 보낼 수 있는 값이 남아 있는 한, 배치가 끝난 행은 거부되지 않는다. 이보다 큰 임계값은 의미가 없다. 그 범위의 행은 OOS로 보내지 않은 채 overflow 거부에 걸리기 때문이다. PR #8416 head `19e5d178c`에서도 배치 판정([L13841](https://github.com/CUBRID/cubrid/blob/19e5d178c6eea0fc8800775b5939c89bc18e2551/src/storage/heap_file.c#L13841))과 거부 판정([L14939](https://github.com/CUBRID/cubrid/blob/19e5d178c6eea0fc8800775b5939c89bc18e2551/src/storage/heap_file.c#L14939))이 같은 16B 여유분을 쓰는 것을 확인했다(코드 읽기).

예외는 OOS로 보낼 값이 모자란 행이다. `FORCE_INLINE` 값, 큰 고정 길이 값, 24B 이하의 작은 값이 많은 행은 OOS로 보낸 뒤에도 한 페이지를 넘을 수 있고, 이 행은 임계값과 관계없이 거부된다. 또 MVCC 여유분 16B 때문에 한 페이지 경계에서 16B 안쪽인 행은 develop과 달리 OOS로 갈 수 있다(추정, 미측정).

이 설정에서 저장 위치는 다음과 같다.

- 한 페이지에 들어가는 행은 develop과 같이 heap 안에 남는다.
- 한 페이지를 넘는 행은 큰 값부터 OOS로 보내, 행이 한 페이지에 들어갈 때까지 줄인다. develop은 이 행을 overflow로 저장했지만, 스펙상 이 행은 OOS를 써야 한다. CBRD-27788의 overflow→OOS 모든 컬럼 읽기(Q5) −6.05%가 이 경로이며, 임계값으로는 바뀌지 않는다.

### 컬럼 STORAGE 정책과의 관계 (스펙)

임계값은 위 배치 판정 하나만 바꾼다. 컬럼 정책의 의미는 그대로다.

- `FORCE_OUTLINE` 값은 임계값을 보기 전에 OOS로 보낸다. 임계값을 올려도 계속 OOS로 간다.
- `PREFER_INLINE` 값은 임계값을 넘었을 때 맨 마지막 후보가 된다.
- `FORCE_INLINE`(PR #8416) 값은 OOS 후보가 아니다.

### 기존 데이터와 설정 변경 (코드 읽기, 테스트로 확인 필요)

- **이미 OOS에 있는 값은 그대로 읽힌다.** 읽기 경로는 행의 가변 offset 항목에 있는 OOS flag(`OR_IS_OOS`)로 판단하고 임계값을 보지 않는다([`heap_attrvalue_point_variable` L11655](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L11655)).
- **설정 변경은 새 INSERT와 UPDATE에만 적용된다.** 임계값을 쓰는 곳이 위 두 곳뿐이다.
- **UPDATE는 행 전체를 다시 배치한다.** [`heap_attrinfo_transform_to_disk_internal`](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L14877)은 바뀌지 않은 컬럼 값까지 읽어 온 뒤([L14901](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L14901)) 모든 컬럼으로 배치를 다시 계산한다([L14913](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L14913)). 그래서 임계값을 올린 뒤 UPDATE한 행은 OOS 값이 heap으로 돌아올 수 있고, 내린 뒤에는 heap 값이 OOS로 갈 수 있다. CBRD-27230의 UPDATE chain 재사용이 들어오면 이 동작을 다시 확인해야 한다.
- 한 테이블에 같은 크기인데 heap에 있는 값과 OOS에 있는 값이 섞일 수 있다. 읽기는 행마다 판단하므로 결과는 같아야 한다(추정). unloaddb → loaddb를 하면 새 설정으로 다시 배치된다(추정).

### HA, loaddb, CS/SA 모드 (코드 읽기)

- **HA**: replica는 master의 레코드를 다시 배치하지 않고 받은 그대로 저장한다([`xlocator_repl_force` L7740](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/transaction/locator_sr.c#L7740)). 그래서 정상 상태에서는 master 설정이 저장 위치를 정한다. failover 뒤에는 새 master의 설정이 적용되므로, 노드마다 값이 다르면 failover 전후 새 행의 배치가 달라진다. 실제 HA 환경에서는 확인하지 않았다.
- **loaddb**: CS 모드 loaddb는 서버의 `locator_insert_force`·`locator_multi_insert_force`로 행을 쓰므로 서버 설정을 따른다. SA 모드 loaddb와 compactdb는 자기 프로세스의 파라미터를 읽는다. SA compact가 배치 정책을 우회하는 문제는 [CBRD-27924](https://jira.cubrid.org/browse/CBRD-27924)에서 따로 다룬다.
- 선례로 heap 페이지 정책 파라미터 `unfill_factor`는 `PRM_FOR_SERVER | PRM_USER_CHANGE`다([system_parameter.c L1240](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/base/system_parameter.c#L1240)).

## Decisions

담당자가 2026-11-12에 정한 사항이다.

### 1. 기본값은 "한 페이지에 행 4개" 기준을 유지한다 (결정됨)

- **결정.** 기본값은 지금처럼 한 페이지에 행 4개가 들어가는 크기(16KiB 페이지에서 4,060B)로 둔다. 이후 파라미터 값을 바꿔 가며 측정하고, 종합 성능이 가장 좋은 값으로 기본값을 바꾼다.
- **근거.** PostgreSQL은 `TOAST_TUPLES_PER_PAGE` = 4로 한 페이지에 행 4개가 들어가도록 TOAST 대상 크기를 정한다. 현재 계산식(CBRD-27057)도 같은 관례를 따른다. 기본값을 바꾸려면 4~16KB 전체 읽기의 손해와 작은 컬럼 조회의 이득을 함께 비교해야 하는데, 지금 근거는 기본값과 상한 두 지점뿐이다.
- **영향.** 기본값을 유지하는 동안 PR #7990 병합 기준 2(기본 설정에서 4~16KB 전체 읽기)는 이 파라미터만으로는 충족되지 않는다. 기준 2의 판정은 sweep 측정 뒤 기본값 변경에 달려 있다.

### 2. PR #8416을 먼저 병합하고, 상한은 overflow 경계로 둔다 (결정됨)

- **결정.** PR #8416을 먼저 병합하고, 이 파라미터 PR은 그 뒤에 넣는다. "OOS를 쓰지 않음" 설정은 두지 않는다. 파라미터 상한은 `heap_Maxslotted_reclength`다. 한 페이지를 넘는 행은 상한에서도 큰 값을 OOS로 보낸다.
- **근거.** PR #8416 이후에는 일반 테이블에서 한 페이지를 넘는 행이 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE`로 거부된다(head `19e5d178c` [heap_file.c L14939](https://github.com/CUBRID/cubrid/blob/19e5d178c6eea0fc8800775b5939c89bc18e2551/src/storage/heap_file.c#L14939), 코드 확인). 그래서 OOS를 쓰지 않는 설정은 한 페이지를 넘는 행을 저장할 수 없다. 상한이 overflow 경계와 같으면 배치 판정과 거부 판정이 같은 경계를 써서, OOS로 보낼 값이 있는 행은 거부되지 않는다(위 "상한을 한 페이지로 두면 생기는 일").

## Open Decisions

아래 후보는 ANALYSIS 입력이며, 아직 어느 것도 선택하지 않았다.

### 1. 파라미터 형태와 범위

| 후보 | 장점 | 단점 | 근거와 확인 사항 |
| --- | --- | --- | --- |
| A. 바이트 값 | 4,060B와 한 페이지 사이의 아무 값이나 실험할 수 있다. 현재 함수가 바이트를 반환하므로 바꿀 곳이 적다 | 의미 있는 범위가 페이지 크기마다 다르다. 상한보다 큰 값과 stub(24B)보다 작은 값을 어떻게 처리할지(오류 또는 잘라내기) 정해야 한다 | 측정 전용 빌드가 상한 한 지점을 이미 측정했다 |
| B. 페이지당 행 수 (예: 1~4, 4가 현재 동작) | 페이지 크기와 관계없이 의미가 같다. 현재 계산식의 `4`를 바꾸는 형태라 스펙의 계산 방식을 유지한다 | 중간값을 고를 수 없어 sweep 측정의 해상도가 낮다. 1을 고르면 계산 결과가 결정된 상한(`heap_Maxslotted_reclength`)과 같은지 확인해야 한다 | 기본값(4)이 PostgreSQL 관례와 같은 단위로 표현된다 |

어느 후보든 다음을 정한다.

- **이름**: 기존 이름 규칙(`unfill_factor` 등)을 따른다.
- **하한**: 기본값(4,060B, 행 4개)보다 낮은 값을 허용할지 정한다. 낮추면 OOS로 가는 값이 늘어난다. 상한은 위에서 정했다.
- **적용 시점**: 서버 재시작이 필요한 static인지, 실행 중 바꿀 수 있는 dynamic인지 정한다. 읽기는 행마다 flag로 판단하므로 dynamic이어도 읽기 정합성 문제는 보이지 않는다(코드 읽기).

### 2. HA 노드와 SA 도구의 설정 일치

모든 HA 노드에 같은 값을 요구할지, SA 도구가 설정 파일의 어느 절에서 값을 읽을지 정한다. 값이 다르면 데이터 손상이 아니라 배치 차이가 생긴다(추정). 운영 문서에서 같은 값을 권장할지도 정한다.

## Acceptance Criteria

- 임계값을 상한으로 설정하면 한 페이지에 들어가는 4~16KB 행이 heap 안에 저장된다. `SHOW HEAP CAPACITY`·`SHOW HEAP OOS`로 확인한다.
- 같은 설정에서 한 페이지를 넘는 행은 큰 값이 OOS로 가고 `REC_BIGONE` 없이 저장된다.
- 상한 설정에서 CBRD-27788 AC-P2(4.6~13.8KB 값 전체 읽기 12개 경우)를 다시 측정한다. 기본값 결과와 따로 보고한다.
- 설정을 바꾸기 전에 OOS에 저장된 값이 설정 변경 뒤에도 읽힌다. 그 행을 UPDATE하면 새 설정에 따라 배치된다.
- `FORCE_OUTLINE`·`PREFER_INLINE`·`FORCE_INLINE` 컬럼이 설정과 관계없이 스펙대로 동작한다.
- 설정이 CS 모드, SA 모드, loaddb에서 정해진 대로 적용된다.
- 상한보다 큰 값은 받지 않는다. 기본값은 "한 페이지에 행 4개" 기준(16KiB 페이지에서 4,060B)이다.
- 이 파라미터 PR은 PR #8416이 `feature/oos-merge`에 병합된 뒤 그 위에서 검증한다.
- **sweep 측정.** 기본값부터 상한까지 파라미터 값을 여러 단계로 바꿔 가며 측정한다. 4~16KB 값 전체 읽기, 작은 컬럼 조회, UPDATE, INSERT, 저장 크기와 I/O를 함께 보고, 값마다 develop 대비 결과를 표로 남긴다. 측정은 CBRD-27788과 같은 조건과 판정 지표를 쓴다.
- OOS 스펙의 Trigger Conditions 절에 설정 가능한 임계값과 그 범위를 반영한다.

## Out of Scope

- 한 페이지를 넘는 행(overflow→OOS)의 모든 컬럼 읽기 Q5 −6.05% 비용 개선. 스펙상 이 행은 OOS를 써야 하므로 임계값으로는 바뀌지 않는다.
- 파일 캐시를 비운 뒤 큰 값 읽기 지연([CBRD-27791](https://jira.cubrid.org/browse/CBRD-27791)).
- 테이블별 설정. 이 이슈는 서버 전체 시스템 파라미터만 다룬다.

## Follow-up

- sweep 측정 결과로 종합 성능이 가장 좋은 값을 고르고, 그 값으로 기본값을 바꾼다. 기본값을 바꾸면 OOS 스펙의 Trigger Conditions 절과 PR #7990 병합 기준 2의 판정도 갱신한다.

## Related

- 상위: [CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978) `[OOS] [EPIC] TODO`
- 측정: [CBRD-27788](https://jira.cubrid.org/browse/CBRD-27788), AC-P2 경위: [CBRD-27785](https://jira.cubrid.org/browse/CBRD-27785)
- 리뷰어 병합 기준: [PR #7990 10/28 댓글](https://github.com/CUBRID/cubrid/pull/7990#issuecomment-6461744209)
- 현재 4행 기준 임계값: [CBRD-27057](https://jira.cubrid.org/browse/CBRD-27057)
- overflow 거부: [CBRD-26937](https://jira.cubrid.org/browse/CBRD-26937), [CBRD-27259](https://jira.cubrid.org/browse/CBRD-27259)([PR #8416](https://github.com/CUBRID/cubrid/pull/8416))
- SA compact 배치 정책: [CBRD-27924](https://jira.cubrid.org/browse/CBRD-27924)
