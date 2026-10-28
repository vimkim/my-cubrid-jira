# [OOS] 개발자 회귀 테스트 보완·분류 및 검증·리뷰 전달

## Issue Triage

**이슈 수행 목적**: OOS의 저장·조회·수정·삭제·복구 동작을 확인하는 자동화 테스트를 작성한다.

**이슈 수행 이유**: OOS는 큰 값을 별도 파일에 저장한다. 기능을 변경할 때마다 값이 손상되지 않는지, 장애 후에도 복구되는지, 사용이 끝난 저장 공간이 정리되는지 자동으로 검사할 테스트가 필요하다.

---

## AI-Generated Context

> 아래는 기존 이슈, 테스트 문서와 2026-10-28(Asia/Seoul) 확인한 PR·CI 근거를 바탕으로 정리한 진행 기록이다. 과거 검증 결과와 최신 PR의 상태를 구분한다.

## Description

이 이슈는 [CBRD-26357](https://jira.cubrid.org/browse/CBRD-26357)의 개발자 회귀 테스트 하위 작업이다. OOS(Out-of-row Overflow Storage)의 전체 값 보존뿐 아니라 실제 저장 레코드의 `HAS_OOS` 설정·해제, 파일·청크 소유권, 트랜잭션·복구와 정리 동작을 검증 대상으로 삼는다.

초기 전달 이후 피드백을 여섯 검증 영역으로 정리하고 테스트를 보완하여 두 TC PR에 게시했다. 이후 실제 두 노드 HA 복제 TC와 HA 장애 전환 TC를 추가했다. **현재 두 TC PR은 OPEN, Ready for review다. 동일 입력 최신 전체 CI(run40557885817)는 build·SQL·shell·medium 모두 PASS이고, 장애 전환 TC를 추가한 뒤의 shell CI(run40594246823)도 PASS다.** 테스트 작성·게시, 활성 선택의 통과와 요구사항 전체의 검증 완료는 각각 구분한다.

| 산출물 | 전체 보유 수 | 정규 실행 활성 | 비활성 또는 검증 한계 |
| --- | ---: | ---: | --- |
| 공개 SQL/answer | 28쌍 | 25쌍 | 실패 3쌍을 원래 기대값과 함께 보존한다. |
| 비공개 OOS shell 진입점 | 133개 | 69개 | 실패 또는 60초 초과 64개를 보존한다. FAIL 61개와 장시간 8개 중 5개가 중복된다. |
| C++ 보완 테스트 함수 | 14개 | 위 SQL/shell 집계와 별도 | 기존 내부 계약 유지와 보완 함수 수다. 최신 리비전의 PASS 수를 뜻하지 않는다. |

위 수는 기존 TC를 포함한 2026-10-27 스냅샷의 보유 수이며, 이번에 새로 추가한 수가 아니다. 그 뒤 비공개 shell에 HA 진입점 2개(`cbrd_26659_ha_replication`, `cbrd_26659_ha_failover`)를 추가했고, 두 진입점은 정규 실행에 포함된다. 별칭 `SH-001`–`SH-133`에는 들어 있지 않다. Shell helper 자체는 TC 수에 포함하지 않는다.

## Implementation

### 여섯 검증 분류와 대표 TC 별칭

`SQL-01`–`SQL-28`, `SH-001`–`SH-133`, `UT-01`–`UT-14`는 [피드백별 TC 대응 보고서][coverage]에서 정의한 조회용 별칭이다. CI의 전역 TC 번호나 구현 티켓 번호가 아니다. 아래에는 대표 별칭만 기재한다. 하나의 TC가 여러 분류에 대응할 수 있으므로 분류별 수를 합산하지 않는다.

| 분류 | 작성·보완한 검증 | 대표 TC 별칭 |
| --- | --- | --- |
| 1. 정책 구문·의미·SHOW·유틸리티 | STORAGE 정책의 정상·오류 구문과 문맥, SHOW 대상·권한, unload/load·compact·backup/restore의 정책·값·소유권 보존 | `SQL-08`, `SQL-27`; `SH-072`, `SH-097`, `SH-115`–`SH-116`, `SH-124`–`SH-132` |
| 2. 사용자 연산과 OOS 상태 | 읽기·복사·DML·MERGE/REPLACE/중복 키 UPDATE, 제약·트리거·트랜잭션, 스키마·파티션·LOB. 실제 저장 레코드의 `HAS_OOS` set/clear와 전체 행 모델을 연결 | `SQL-01`–`SQL-03`, `SQL-12`, `SQL-19`; `SH-019`, `SH-084`, `SH-099`–`SH-100` |
| 3. C++ 내부 계약 | SQL 결과만으로 대체하기 어려운 stored/Expand 읽기, 호출자 버퍼 수명·재시도, identity·소유권, system-worker undo와 기존 OOS 파일의 TDE 계약 | `UT-10`–`UT-14`; 기존 read/Expand·identity·rollback·reclaim 모듈 유지 |
| 4. 경계와 limit+1 | 직렬화 이득, chunk·VOT, stub·buffer의 exact/short capacity, 길이 guard, 물리 record target·bigone·key-overflow 경계 | `SQL-04`, `SQL-28`; `SH-101`–`SH-106`, `SH-114`; `UT-01`–`UT-09`, `UT-11` |
| 5. 저장 효율·회수·불리한 시나리오 | 반복 INSERT/UPDATE/DELETE, abort/retry, snapshot, crash/restart, notification·whole-stub 보존, 페이지 회수·재사용과 survivor 검증 | `SH-012`–`SH-017`, `SH-075`–`SH-078`, `SH-117`–`SH-118`, `SH-133`; `UT-12`–`UT-13` |
| 6. 큰 OOS PK/UNIQUE·FK | 실제 indexed attribute의 OOS 상태, 단일·복합 키, build/maintenance, 중복·NULL·FK action·rollback 및 index 경로 | `SQL-25`–`SQL-26`; `SH-004`, `SH-027`–`SH-040`, `SH-073` |

**전체 별칭→원본 경로·검사 내용·활성 여부·관측 결과는 [상세 Markdown 보고서][coverage]의 분류별 설명과 부록 A–C에서 확인한다.** 해당 보고서의 2026-10-27 스냅샷을 별칭 기준으로 사용하며, 최신 CI 상태는 아래에 별도로 기록한다.

### 공통 검증과 실행 지원

- 독립적인 전체 값·행·트랜잭션 모델을 기대값으로 사용하고, 실제 저장 레코드와 값·행 ID를 연결하는 관측 helper를 보완했다. 별도 SQL 실행의 논리 결과와 shell fixture의 물리 증거를 같은 실행의 증거로 합치지 않는다.
- Shell의 OOS helper는 C++17·Bash/jq를 사용한다. 사례별 DB·등록·파일·프로세스의 소유권, 명령 제한 시간과 정리 결과를 확인한다.
- 실패·장시간 사례는 정규 발견 경로 밖에 보존하고 원본 경로·리비전·hash·실행 결과·비활성 사유를 기록한다. 비활성화를 위해 본문·assertion·expected answer를 바꾸지 않았으며, 실패를 통과 커버리지로 계산하지 않는다.
- C++는 동등한 대체 assertion을 확인하지 못한 내부 계약을 유지하고 14개 함수를 보완했다. 기존 302개 GTest의 과거 PASS는 해당 리비전의 증거로 유지하며 최신 엔진의 전체 PASS로 확대하지 않는다.

### 두 노드 HA 복제와 장애 전환

- `shell/_40_guava/cbrd_26659_ha_replication`은 shell case 하나 안에서 격리된 HA 노드 두 개(active, standby)를 구성한다. 노드마다 UTS·network·PID·IPC·mount namespace를 두고 veth로 연결한다. 그래서 별도 HA job, 두 번째 컨테이너나 SSH 없이 PR CI의 shell suite에서 실행된다. 공통 구성은 `oos_common/oos_ha_pair.sh`, `oos_common/oos_veth_pair.pl`과 검사 함수 `oos_common/oos_ha_checks.sh`이다.
- 쓰기는 master에서만 한다. standby에는 copylogdb·applylogdb 복제로만 변경이 도달한다. 단계마다 master의 barrier 행을 갱신하고, standby에서 그 값이 보일 때까지 최대 120초 polling한다. 고정 sleep은 쓰지 않는다.
- 각 노드를 TC에 적은 독립 기대값과 따로 비교한다. 두 노드를 서로 비교하지 않는다. 노드마다 전체 값 equality와 `octet_length`, 행별 `HAS_OOS`(`SELECT_RECORD_INFO`의 `t_flags`), `SHOW HEAP OOS`의 chunk 수와 바이트를 검사한다. OOS OID는 노드마다 다를 수 있으므로 비교하지 않는다.
- 검사 범위: INSERT, UPDATE(할당·미할당·inline에서 OOS로), rollback, DELETE; DEFAULT·`PREFER_INLINE`·`FORCE_OUTLINE` 정책; OOS `bit varying` PK와 `ON DELETE CASCADE` FK; inline `varchar` 키 대조군.
- standby의 applylogdb를 정지한 변형 실행에서 barrier 시간 초과로 NOK가 되는 것을 확인했다.
- `shell/_40_guava/cbrd_26659_ha_failover`는 같은 구성에서 master 역할을 두 번 옮긴다.
  - 장애 전환: A의 모든 process를 SIGKILL로 한꺼번에 종료한다. 이때 DML을 마치고 commit하지 않은 transaction 하나와, barrier 없이 직전에 commit한 transaction 하나가 있다. 승격한 B에는 commit한 OOS 값만 있어야 한다. `sync` 모드에서 commit은 slave가 log를 저장한 뒤 끝나고, 승격하는 server는 모든 applier가 끝난 뒤 active가 되기 때문이다.
  - 재합류: B가 master로 insert, OOS 값 update, 태그만 update, delete를 한다. A를 재기동하면 recovery 뒤 slave로 합류하고 B의 변경을 받는다.
  - 수동 failback: 매뉴얼 절차대로 B를 `cubrid heartbeat stop`으로 내려 A를 master로 되돌리고, B를 slave로 다시 합류시킨다. 그 뒤 A가 B가 쓴 chain을 다시 고친다.
  - 역할이 바뀔 때마다 살아 있는 각 노드를 위와 같은 방식으로 검사한다. chunk 수는 첫 UPDATE 전에만 검사한다. 그 뒤로는 vacuum 시점에 따라 노드가 가진 이전 chain 수가 달라진다.
  - 장애 직전 commit 앞에서 B의 applylogdb를 정지한 변형 실행에서는 B가 `to-be-active`에 머물러 NOK가 되는 것을 확인했다.
- 범위 밖: `async` 복제 모드(`sync`만 실행. 매뉴얼상 `semisync`는 deprecated이며 `sync`와 같다); 대량·동시 쓰기의 queue alignment와 쓰기 중 장애 전환; server process만의 장애; 네트워크 지연·단절, OS·디스크 장애(노드 장애는 같은 kernel 위의 process 종료로 재현); 장애 전환 뒤 이전 chain의 회수. 실행 기록과 근거는 [HA 복제 증거 문서][ha]와 [HA 장애 전환 증거 문서][ha-failover]에 있다.

## Validation

### 최신 PR과 전체 CI

2026-10-28 확인한 세 PR의 base는 모두 `feature/oos-merge`다. 두 TC PR의 head branch는 `tc/pr-8128`이다. 두 TC branch는 각 저장소의 최신 `feature/oos-merge`를 포함한다.

| 대상 | 현재 head | 현재 상태 |
| --- | --- | --- |
| [Engine PR #8128](https://github.com/CUBRID/cubrid/pull/8128) | `e3589ae42d42b04eb020e1ae43e165b01d31b12a` | OPEN, draft |
| [SQL TC PR #3688](https://github.com/CUBRID/cubrid-testcases/pull/3688) | `45e21ad799d82ebadc04a93c7d2f69517d53bf39` | OPEN, Ready for review |
| [Shell TC PR #4365](https://github.com/CUBRID/cubrid-testcases-private-ex/pull/4365) | `c0400c8f2222262dbeffca99b4ee66a7d2165444` | OPEN, Ready for review |

Shell TC PR에는 이전 기록의 `98723aa` 이후 세 커밋이 추가됐다. `5a3c7d8ff`는 native helper가 OOS page를 page type 14로 읽도록 고쳤다. Engine `1e8701b4f`가 OOS page를 type 8 대신 14로 저장하기 때문이다. `3bba57e1f`는 HA 복제 진입점을 추가했다. `c0400c8f2`는 HA 장애 전환 진입점을 추가하고, HA 복제 진입점의 검사 함수를 공용 파일로 옮겼다.

**[최신 전체 CI run40557885817](https://github.com/CUBRID/cubrid/actions/runs/40557885817)는 build·SQL·shell·medium 모두 PASS다.** 입력은 engine `e3589ae`, public TC `45e21ad`, private TC `3bba57e1f`다. 재실행 없이 첫 시도에서 통과했다. 이 run 직후에는 head `e3589ae`의 `gha-ci` context 다섯 개가 모두 이 run을 가리켰다.

- SQL: shard 10개의 CTP summary 합계가 17,653건 성공, 실패 0건이다.
- Shell: shard 50개에서 3,530건 OK, NOK 0건, skip 30건이다. 활성 OOS shell 진입점 69개와 HA 복제 진입점 `cbrd_26659_ha_replication`(shard 05)을 합한 70개가 모두 OK다.
- Medium: shard 1개가 PASS했다.

이전 run에서 실패한 OOS 외 두 건(`cbrd_23280_auth`, `_enhance_1008`)도 이 run에서는 OK다.

**그 뒤 private `c0400c8f2`로 shell만 다시 실행한 [run40594246823](https://github.com/CUBRID/cubrid/actions/runs/40594246823)도 PASS다.** Engine은 같은 `e3589ae`이고, `3bba57e1f`와 `c0400c8f2`의 차이는 shell HA case와 `oos_common` 파일 4개뿐이다.

- Shell: shard 50개에서 3,531건 OK, NOK 0건, skip 30건이다. 늘어난 1건이 장애 전환 진입점이다. 활성 OOS shell 진입점 69개와 HA 진입점 2개를 합한 71개가 모두 OK다. `cbrd_26659_ha_failover`는 shard 10, `cbrd_26659_ha_replication`은 shard 49에서 실행됐다.
- 현재 head `e3589ae`의 `gha-ci` context 다섯 개가 모두 pass다. Build·shell은 run40594246823을, SQL·medium은 run40557885817을 가리킨다. 두 run의 private 입력이 다르므로, private `c0400c8f2` 기준의 동일 입력 전체 CI는 실행하지 않았다.

### 2026-10-27 PR #8128 CI 경과

| 실행 | 입력·결과 | 해석 |
| --- | --- | --- |
| [전체 run40472072791](https://github.com/CUBRID/cubrid/actions/runs/40472072791) | private `98723aa`. Build·SQL·medium PASS. Shell NOK 3건: `cbrd_26659_record_residual`, `cbrd_26659_record_layout`, `cbrd_26659_record_keys` | 세 건은 native helper의 page type 가정 때문에 실패했다. `5a3c7d8ff` 커밋 설명에 실패 메시지(`stopped page identity/type/encryption mismatch`)와 원인이 기록돼 있다. |
| [전체 run40499093799](https://github.com/CUBRID/cubrid/actions/runs/40499093799) | private `5a3c7d8ff`. Build·SQL·medium PASS. 활성 OOS shell 진입점 69개 모두 OK. Shell NOK 1건: `_35_cherry/issue_21654_server_side_loaddb/cbrd_23280_auth` | 위 세 건은 OK가 됐다. 남은 1건은 OOS TC가 아니다. |
| [shell run40507894187](https://github.com/CUBRID/cubrid/actions/runs/40507894187) | private `3bba57e1f`. HA 복제 진입점 OK(shard 18, 그 shard의 72건 모두 OK). Shell NOK 1건: `_35_cherry/issue_21654_server_side_loaddb/loaddb_CS/_01_utility/_17_loaddb/_enhance_1008` | 실패 1건은 OOS TC가 아니다. 직전 run에서는 OK였다. |
| [shell 재실행 run40552401255](https://github.com/CUBRID/cubrid/actions/runs/40552401255) | 위 run의 실패 case만 재실행. `_enhance_1008` OK | Head `e3589ae`의 `gha-ci` 필수 context 다섯 개가 모두 pass가 됐다. 그러나 SQL·medium은 private `5a3c7d8ff`, shell은 `3bba57e1f`로 입력이 달라 동일 입력 전체 PASS로 세지 않는다. |

OOS 외 실패 두 건(`cbrd_23280_auth`, `_enhance_1008`)은 같은 engine에서 서로 다른 run에서는 OK였다. 간헐 실패로 보이지만 원인은 분석하지 않았다.

### 상세 보고서가 보존하는 이전 실행 근거

| 실행 | 입력·결과 | 인정하는 범위 |
| --- | --- | --- |
| [Full CI run40324320840](https://github.com/CUBRID/cubrid/actions/runs/40324320840) | Engine `c4c4f5c5`, public `4f6557f`, private `10fb4b63f`. Build·SQL·medium PASS, shell 실패로 전체 FAIL | Shard09 한정 대조에서 활성 OOS SQL 25개는 각각 PASS다. 다른 SQL shard의 summary/JUnit 수 불일치로 전체 testcase 수집 검증은 미완료다. |
| [Shell-only CI run40335925801](https://github.com/CUBRID/cubrid/actions/runs/40335925801) | Engine `c4c4f5c5`, private `8486abd`. 전체 shell 3,523 PASS / 0 FAIL / 30 SKIP | 활성 OOS 69개는 모두 실행·PASS, skip 0이다. 비활성 64개는 실행하지 않았다. 이 결과는 최신 head의 전체 CI 통과를 뜻하지 않는다. |

두 이전 실행의 결과를 하나의 동일 입력 full run PASS로 합치지 않는다. 개별 티켓의 native 실행과 C++ 결과도 해당 source·TC·oracle·실행 phase의 범위에서 유지한다.

## Remaining Work

- 비활성 SQL 3개·shell 64개의 실패 원인·후속 수정 연결과 장시간 사례의 별도 실행 경로를 정리한다. 모든 실패를 엔진 결함으로 일괄 확정하지 않는다.
- 지원 연산별 적용 가능한 `HAS_OOS` 상태, 독립 기대값, 실제 실행 phase와 C++ 필수 선택을 [연산 요구 목록][operations] 및 [C++ 인벤토리][cpp]와 최종 대조한다. 파티션 소유권, 정책 roundtrip, 물리 target, notification·회수 등 남은 항목의 완료를 활성 선택 통과만으로 선언하지 않는다.
- 큰 키 종합 선택 `SH-073`은 과거 PASS 관측이 있지만 381.773초로 비활성이다. 기능 결과로 성능 저하가 없다고 판단하지 않으며 성능 비교는 계속 보류한다.
- HA는 `sync` 모드의 정상 복제와 master 장애 전환·재합류·수동 failback을 검증했다. `async` 모드, 대량·동시 쓰기의 queue alignment, server process만의 장애, 네트워크·OS·디스크 장애는 미검증이다. `async`와 queue alignment를 다음 범위로 할지는 정하지 않았다.
- QA·동료 리뷰에서 전달 범위와 잔여 공백을 확인한다. 두 TC PR이 OPEN이므로 TC Merge Gate의 두 TC PR 병합 또는 close 조건은 아직 충족하지 못했다. TC PR의 병합·close는 동료가 결정한다.

## Acceptance Criteria

- [x] 여섯 검증 분류별 SQL/shell/C++ 산출물을 작성·보완하고 관련 PR에 게시한다.
- [x] TC 별칭과 상세 Markdown, 실행 리비전·활성 여부·실패 및 장시간 사례의 근거를 연결한다.
- [x] 활성 선택의 실행 결과와 최신 전체 CI 상태를 구분하여 기록한다.
- [ ] 최신 CI 실패와 비활성·미실행 항목의 처리 또는 후속 추적·수락 범위를 확정한다.
- [ ] 필수 요구사항별 독립 검증, QA·동료 리뷰 및 TC Merge Gate 조건을 충족한다.

## References

- [피드백 6항목·TC 별칭·전체 파일 목록과 개별 결과][coverage]
- [CBRD-26659 문서 목록][index]
- [연산·상태별 요구사항과 후속 검증 지도][operations]
- [기존 C++ 내부 계약 유지·검증 범위][cpp]
- [두 노드 OOS HA 복제 TC와 PR CI 실행 기록][ha]
- [OOS HA 장애 전환·재합류·failback TC와 PR CI 실행 기록][ha-failover]

[coverage]: https://github.com/vimkim/my-cubrid-docs/blob/343344b44377fb62604d104a5eac84d07210c45a/cbrd-26659/CBRD-26659-feedback-testcase-coverage-report_20261027_codex.md
[index]: https://github.com/vimkim/my-cubrid-docs/blob/343344b44377fb62604d104a5eac84d07210c45a/cbrd-26659/README.md
[operations]: https://github.com/vimkim/my-cubrid-docs/blob/343344b44377fb62604d104a5eac84d07210c45a/cbrd-26659/supplement-operation-inventory-work456-20261021.md
[cpp]: https://github.com/vimkim/my-cubrid-docs/blob/343344b44377fb62604d104a5eac84d07210c45a/cbrd-26659/supplement-cpp-inventory-work456-20261021.md
[ha]: https://github.com/vimkim/my-cubrid-docs/blob/58a2b8d8a63f0126463d22dacb900cdc827bf778/cbrd-26659/ci-replan/ha-replication.md
[ha-failover]: https://github.com/vimkim/my-cubrid-docs/blob/58a2b8d8a63f0126463d22dacb900cdc827bf778/cbrd-26659/ci-replan/ha-failover.md
