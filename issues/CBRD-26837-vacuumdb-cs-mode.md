# [VACUUM] 서버 가동 중(CS 모드)에서 vacuumdb 유틸리티로 vacuum 트리거 지원

> CBRD-26720 의 후속 / 자매 이슈. JIRA 등록: [CBRD-26837](http://jira.cubrid.org/browse/CBRD-26837) (2026-05-22, 'Relates' 링크 연결됨).

## Issue Triage

**이슈 수행 목적**: `vacuumdb` 유틸리티가 서버 가동 중(CS 모드)에서도 vacuum 을 트리거할 수 있도록 CS 모드 경로를 확장한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `vacuumdb` 의 vacuum 트리거 경로는 `src/executables/util_cs.c:3803` 의 `#if defined(SA_MODE)` 분기 아래에만 구현되어 있다. `#else` 분기(`util_cs.c:3859` 이하, CS 모드 빌드)에서는 `--dump` 옵션만 처리하고, 비-dump 호출에 대해서는 `VACUUMDB_MSG_CLIENT_SERVER_NOT_AVAILABLE` 메시지(`util_cs.c:3888-3890`)를 출력한 뒤 `EXIT_SUCCESS` 로 반환한다. 즉 운영자가 서버가 떠 있는 상태에서 `cubrid vacuumdb <db>` 를 호출해도 vacuum 은 일어나지 않는다. `util_admin.c:1005` 의 `{VACUUMDB, SA_CS, ...}` 등록 플래그는 양 모드 동작을 상정한 슬롯이지만, 비-dump CS 경로는 미구현 상태로 남아 있다.
- **영향**: 운영 중 vacuum 을 표준 유틸리티 표면에서 명시적으로 트리거할 수단이 없다. 결과적으로 운영자는 (1) 서버를 멈추고 SA 모드 `vacuumdb` 로 정리하거나, (2) 비공식 우회 경로(예: CBRD-26720 에서 추가한 csql 세션 명령 `;vacuum`)에 의존해야 한다. 후자는 2026-05-21 주간 회의에서 develop 머지 제외(테스트 전용 유지) 가 결정되었으므로, develop 라인에서는 ad-hoc vacuum 트리거 수단이 부재한 상태가 된다.

**이슈 수행 방안**:

- 2026-05-21 주간 회의 합의(사용자 인용: "develop에 vacuumdb를 cs 모드로 지원하는 유틸리티를 검토해보는 방향으로 잡았습니다"): CS 모드 클라이언트 유틸리티로 `vacuumdb` 의 vacuum 트리거 경로를 확장하는 방향을 채택한다.
- CBRD-26720 의 csql 세션 명령(`;vacuum`, `;oos_stats`) 접근은 테스트용으로만 유지하고 develop 머지에서 제외한다. 본 이슈가 그 대체 수단의 정식 트랙이다.
- 세부 설계는 본 이슈의 ANALYSIS 단계에서 결정한다. 의도된 결정 슬롯:
  - CS 프로토콜 경로: `TBD - ANALYSIS 단계에서 결정` (CBRD-26720 의 `NET_SERVER_VACUUM` + `vacuum_wakeup_master_daemon` 재활용 여부 포함)
  - 권한 모델: `TBD - ANALYSIS 단계에서 결정` (DBA 그룹 한정 vs. `--sysadm` 강제 vs. 기존 SA 모드의 `AU_DISABLE_PASSWORDS` 패턴과의 정합성)
  - SA 모드 옵션 패리티: `TBD - ANALYSIS 단계에서 결정` (`--dump`, `--output-file` 등 기존 SA 모드 옵션이 CS 모드에서도 동일하게 동작해야 하는지)
  - dry-run / 진행 보고: `TBD - 합의 미확인`
  - auto-vacuum 마스터 데몬과의 상호작용: `TBD - ANALYSIS 단계에서 결정` (수동 트리거가 데몬을 깨우는지, 별도 path 로 동기 vacuum 을 도는지)
  - `VACUUMDB_MSG_CLIENT_SERVER_NOT_AVAILABLE` 메시지 / `util_admin.c` 의 `SA_CS` 플래그 처리: `TBD - ANALYSIS 단계에서 결정`

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료입니다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 ANALYSIS / 구현 단계에서 참고하시면 됩니다.

### Summary

- **문제 / 목적**: `vacuumdb` 유틸리티가 CS 모드(서버 가동 중)에서 vacuum 트리거를 지원하지 않아, 운영자가 라이브 서버에 vacuum 을 거는 표준 경로가 없다. CBRD-26720 의 csql 세션 명령이 임시 대체 수단이었으나 develop 머지에서 제외되었다.
- **원인 / 배경**: `util_cs.c:vacuumdb()` 가 `#if defined(SA_MODE)` 로 양분되어 있고 CS 분기는 `--dump` 만 처리한다. 비-dump CS 호출은 무동작 + 안내 메시지로 끝난다.
- **제안 / 변경**: CS 모드 `vacuumdb` 에 vacuum 트리거 경로를 추가한다. 세부 설계(프로토콜, 권한, 옵션 패리티, 데몬 상호작용)는 본 이슈 ANALYSIS 단계에서 결정한다.
- **영향 범위**: `src/executables/util_cs.c`, 통신 계층(필요 시 신규 또는 재사용 RPC), `src/query/vacuum.{c,h}`, 권한 검증 코드. SA 모드 동작은 무변경 유지.

---

## Description

### 배경

CBRD-26720(PR [#TBD]) 에서는 vacuum 검증/디버깅 편의를 위해 csql 세션 명령 `;vacuum`, `;oos_stats <class>` 를 도입했다. 이 PR 은 OOS vacuum 정리 동작(CBRD-26668)을 csql 에서 직접 확인하기 위한 도구로 작성되었다.

2026-05-21 주간 회의에서 두 가지가 결정되었다.

1. CBRD-26720 의 csql 세션 명령은 **테스트 용도로만 유지** 한다. develop 머지에서는 제외한다.
2. 같은 운영 요구(라이브 서버에서 vacuum 을 트리거하고 싶음)는, csql 세션 명령이 아니라 **`vacuumdb` 유틸리티의 CS 모드 지원** 으로 충족하는 방향을 검토한다.

본 이슈는 (2) 의 정식 트랙이다.

### 현재 `vacuumdb` 의 모드별 동작

`src/executables/util_cs.c:3757` 의 `vacuumdb()` 본체는 `#if defined(SA_MODE)` 로 갈린다.

| 호출 | SA 모드 빌드 | CS 모드 빌드 |
|---|---|---|
| `cubrid vacuumdb <db>` | `db_restart` -> `cvacuum()` 호출 (`util_cs.c:3819, 3834`) | `VACUUMDB_MSG_CLIENT_SERVER_NOT_AVAILABLE` 출력 후 `EXIT_SUCCESS` (`util_cs.c:3888-3890`) |
| `cubrid vacuumdb --dump <db>` | `db_restart` -> `vacuum_dump(outfp)` | `db_restart` -> `vacuum_dump(outfp)` (양 모드 동일 동작) |

`util_admin.c:1005` 의 등록 항목은 `{VACUUMDB, SA_CS, 1, UTIL_OPTION_VACUUMDB, ...}` 로, `SA_CS` 슬롯은 양 모드 등록을 의미한다. 즉 인자 파싱/디스패치 단계에서는 양 모드가 모두 받아들여지지만, 실제 vacuum 트리거는 SA 모드 분기에만 구현되어 있다.

CBRD-26720 의 `;vacuum` 구현은 CS 모드에서 `NET_SERVER_VACUUM` -> `svacuum` -> `vacuum_wakeup_master_daemon()` 경로를 새로 깔아두었으므로, ANALYSIS 단계에서 그 경로의 재활용 가능성을 검토할 수 있다.

### CBRD-26720 과의 관계 (자매 이슈, 중복 아님)

| 항목 | CBRD-26720 | 본 이슈 |
|---|---|---|
| 표면 | csql 세션 명령 (`;vacuum`, `;oos_stats`) | `cubrid vacuumdb` 유틸리티 (CS 모드) |
| 대상 사용자 | OOS 개발자 / QA (디버깅·검증) | 운영자 / DBA (운영 vacuum) |
| develop 머지 | 제외 (테스트 전용 유지) | 본 이슈로 정식 트랙 진행 |
| 서버측 구현 | `NET_SERVER_VACUUM`, `vacuum_wakeup_master_daemon` 신설 | ANALYSIS 에서 결정 (CBRD-26720 의 서버측 자산 재활용 검토 가능) |

본 이슈는 CBRD-26720 의 대체가 아니다. 양 이슈의 표면(csql 명령 vs. CLI 유틸리티)·대상 사용자·생명주기가 다르다.

---

## Specification Changes

본 이슈는 **의도 캡처** 단계이며, 최종 스펙은 ANALYSIS 산출물로 확정한다. 본 섹션은 ANALYSIS 가 결정해야 할 항목의 목록이다.

| 항목 | 결정 필요 |
|---|---|
| `cubrid vacuumdb <db>` (CS 모드, 비-dump) 가 vacuum 을 트리거하는지 | Y/N (의도상 Y, 확정 필요) |
| 옵션 패리티 (`--dump`, `--output-file`, 기타 향후 추가될 옵션) | SA == CS 인지, 일부 옵션은 CS 미지원인지 |
| 권한 모델 | DBA 그룹 / `--sysadm` / `AU_DISABLE_PASSWORDS` 패턴 — 어느 것을 채택할지 |
| 호출 결과 종료 코드 | vacuum 실패 시 `EXIT_FAILURE` 로 정렬할지, 데몬 깨우기만 성공해도 `EXIT_SUCCESS` 인지 |
| `VACUUMDB_MSG_CLIENT_SERVER_NOT_AVAILABLE` 메시지 | 삭제 / 다른 미지원 경로(예: SA 전용 옵션의 CS 호출)로 재배치 |
| auto-vacuum 데몬과의 상호작용 | 수동 트리거가 데몬 깨우기인지, 별도 동기 경로인지 |

---

## Implementation

본 이슈는 의도 캡처 단계이며, 구현 세부는 ANALYSIS 결정 이후의 후속 작업으로 둔다. 현재 시점에서 식별 가능한 영향 영역만 적는다.

- `src/executables/util_cs.c:3859` 이하의 CS 모드 분기: 비-dump 호출에 대한 vacuum 트리거 경로 신설.
- 통신 계층: 신규 RPC vs. CBRD-26720 의 `NET_SERVER_VACUUM` 자산 재활용 결정에 따라 `src/communication/network_interface_{cl,sr}.{c,cpp}` 가 영향받는다.
- 서버측 vacuum 진입점: `src/query/vacuum.c` 의 `xvacuum`(현재 CS 모드에서 `ER_VACUUM_CS_NOT_AVAILABLE` 즉시 반환) 분기 정책 재검토.
- 권한 검증: 채택될 권한 모델에 따라 `db_set_client_type(...)`, `AU_DISABLE_PASSWORDS()`, DBA 그룹 체크 위치가 달라진다.

세부 흐름은 ANALYSIS 산출물 또는 후속 이슈에서 확정한다.

---

## Acceptance Criteria

본 이슈의 종결 조건은 "구현 완료" 가 아니라 "**ANALYSIS 산출물 확정**" 이다. 실제 구현은 ANALYSIS 결정 후 분리 이슈로 진행하거나 본 이슈 내에서 이어진다.

- [ ] ANALYSIS 문서가 작성되어 위 Specification Changes 표의 모든 항목이 Y/N 또는 구체 선택지로 채워진다
- [ ] CS 프로토콜 경로 결정 (신규 RPC vs. CBRD-26720 의 `NET_SERVER_VACUUM` 재활용)
- [ ] 권한 모델 결정 및 SA 모드 기존 동작(`AU_DISABLE_PASSWORDS`)과의 정합성 확인
- [ ] SA 모드 옵션과의 패리티 매트릭스 확정 (어떤 옵션이 CS 에서 동작/미동작인지)
- [ ] auto-vacuum 데몬과의 상호작용 정책 결정
- [ ] CBRD-26720 의 자산(서버측 `vacuum_wakeup_master_daemon` 등) 재활용 여부 결정
- [ ] 구현 단계로 넘어갈 때의 후속 이슈 목록(또는 본 이슈에서 이어 진행 시 PR 분할 계획) 확정

## Definition of done

- [ ] 위 A/C 충족
- [ ] ANALYSIS 결정이 본 이슈 본문에 반영(또는 별도 설계 문서로 링크)
- [ ] 후속 구현 이슈/PR 링크가 본 이슈 Remarks 에 추가
- [ ] QA 통과 (구현 이슈 단계에서)
- [ ] 매뉴얼 반영 (구현 이슈 단계에서, CS 모드 `vacuumdb` 동작 명시)

---

## Remarks

### 참고 코드

- `src/executables/util_cs.c:3757` - `vacuumdb()` 본체
- `src/executables/util_cs.c:3803` - `#if defined(SA_MODE)` 분기 시작
- `src/executables/util_cs.c:3859` - `#else` (CS 모드) 분기 시작
- `src/executables/util_cs.c:3888-3890` - 비-dump CS 호출 시 `VACUUMDB_MSG_CLIENT_SERVER_NOT_AVAILABLE` 출력
- `src/executables/util_admin.c:1005` - `{VACUUMDB, SA_CS, 1, ...}` 등록
- `src/executables/utility.h:703` - `VACUUMDB_MSG_CLIENT_SERVER_NOT_AVAILABLE = 20`
- `src/query/vacuum.c` - `xvacuum`(CS 모드 즉시 반환 경로 포함)
- CBRD-26720 issue: `issues/CBRD-26720-oos-vacuum-session-cmd.md` (csql 세션 명령 접근, 테스트 전용 유지 결정)

### 관련 이슈

| 티켓 | 관계 | 비고 |
|---|---|---|
| CBRD-26720 | 자매 이슈 | csql 세션 명령 접근. 테스트 전용 유지, develop 머지 제외. 본 이슈가 운영 표면의 정식 트랙. |
| CBRD-26668 | 배경 | OOS vacuum 정리(`oos_delete`) 연동. CBRD-26720 의 직접적 동기. |

### 범위 외 (out of scope)

- 본 이슈는 의도 캡처이므로, 구현 PR / 코드 변경은 본 이슈 머지의 전제가 아니다. ANALYSIS 산출물이 종결 조건이다.
- 실제 구현은 ANALYSIS 후 후속 이슈로 분리하거나 본 이슈에서 이어 진행한다 (분할 여부 자체가 ANALYSIS 결정 사항).
- SA 모드 `vacuumdb` 동작은 무변경 유지.
