# [OOS] [EPIC] [POC-1] Sidecar: 큰 컬럼 값을 테이블별 store heap의 일반 MVCC 레코드로 분리

**한 줄 요약**: OOS(CBRD-26357)를 대체할 수 있는 대안 설계 후보인 Sidecar의 POC 진행 상황, 측정 결과, 남은 일을 한곳에서 추적하는 epic이다.

## Issue Triage

**이슈 수행 목적**: Sidecar 설계가 OOS의 요구 조건(기능 미사용 시 약 5% 이내 비용, 작은 컬럼만 읽는 scan의 페이지 읽기 감소, recovery·MVCC·vacuum·HA·TDE 정상 동작, 회귀 테스트 통과)을 만족하는지 POC로 확인하고, OOS와 비교할 근거를 남긴다.

**이슈 수행 이유**: OOS는 큰 값마다 별도 주소와 별도 생명주기 프로토콜을 두었고, 그 프로토콜에서 슬롯 재사용·undo·vacuum 관련 결함(CBRD-27858, CBRD-27781, CBRD-27237, CBRD-26950 등)이 반복해서 나왔다. Sidecar는 큰 값에 별도 주소는 주되 생명주기는 heap이 이미 가진 MVCC 레코드 프로토콜을 그대로 쓰는 방식이 이 결함 부류를 없앨 수 있는지 검증한다. POC가 P0~P3 대부분을 끝내 비교할 측정값이 생겼으므로 JIRA에서 추적한다.

**영향**: 엔진 개발팀이 OOS 병합 이후의 방향(OOS 유지·보완 또는 대안 설계 채택)을 판단할 때 이 결과를 근거로 쓸 수 있다. POC는 `develop`에 병합되지 않은 브랜치이며, OOS 작업(CBRD-26357)의 진행이나 병합을 막지 않는다.

**이슈 수행 방안**: Gate 1(2026-11-04)에서 승인된 설계와 단계별 계획(P0~P4)을 따른다. P0~P3을 먼저 끝내고 결과를 검토한 뒤(checkpoint 2) P4 HA 복제로 넘어간다. 세부 설계는 아래 설계 문서에 있다.

---

## AI-Generated Context

## Description

### 목표

큰 가변 길이 컬럼 값을 heap 레코드 밖에 저장하는 기능을 OOS와 독립적으로 처음부터 설계하고, POC로 다음 수락 조건을 확인한다.

- A1: 기능을 쓰지 않는 테이블(모든 행이 inline)에서 instructions 중앙값 증가 2% 이하, wall time 중앙값 증가 5% 이하.
- A2: 작은 컬럼만 읽는 scan(`SELECT SUM(id)`)의 page fetch가 `develop` 대비 크게 줄어든다(1 KB/4 KB/16 KB에서 각각 9.6배/41배/376배 이상).
- A3: `kill -9` 후 recovery에서 커밋된 값이 모두 남고, 고아 store 레코드와 끊긴 참조가 없다.
- A4: MVCC snapshot과 vacuum이 동시에 돌 때 읽는 쪽이 항상 올바른 커밋 값을 본다.
- A5: HA 복제(같은 호스트의 master/replica, `checksumdb` 검증).
- A6: `test_sql`, `test_medium`, `test_shell`에서 `develop`에 없는 실패가 없다.
- A7: TLA+ 모델 검사(설계 수준과 코드 수준).

### 설계 요약

- 각 행의 작은 컬럼은 기존 heap 레코드(hot record)에 남고, 큰 값은 heap마다 하나씩 있는 **store** 파일의 레코드(store record)로 옮긴다. store는 일반 `FILE_HEAP`이고 store record는 일반 MVCC heap 레코드다.
- hot record는 값 자리에 16바이트 참조(ref)를 두고, 레코드 끝의 짧은 trailer에 ref를 가진 슬롯을 적고, MVCC flag `0x08`을 켠다.
- store record의 insert, delete, undo, redo, vacuum은 기존 heap 코드가 그대로 처리한다. 새 page type, 새 file type, 새 vacuum 로직은 없다. 새 recovery index는 heap header의 링크 12바이트를 위한 `RVHF_SIDECAR_LINK` 하나다.
- 생명주기 규칙: store 값은 행을 쓰는 트랜잭션이 hot record보다 먼저 insert한다. 그 값을 더 이상 가리키지 않는 첫 hot 버전을 쓰는 트랜잭션이 DELID를 찍는다. 제거는 기존 vacuum이 store record 자신의 header를 보고 한다. vacuum은 제거한 store 슬롯을 `REC_MARKDELETED`로 남겨 store OID가 store의 수명 동안 한 값만 가리키게 한다.
- 쓰기 hook은 `heap_insert_logical`, `heap_update_logical`, `heap_delete_logical` 안에 있으므로 DML, client flush, server `loaddb`, HA applier, SA `compactdb`, partition 이동이 모두 지난다. 읽기 hook은 heap fetch 함수의 출구에 있어, Sidecar를 모르는 호출자도 inline 레코드를 받는다.
- 정책은 AUTO(4,060 B를 넘는 행에서 가장 큰 값부터 밖으로 옮김)이고, 열 단위 `STORAGE INLINE`/`STORAGE EXTERNAL`을 override로 둔다. POC에서는 DDL 대신 파라미터로 대신한다.
- store를 처음 만드는 sysop에서 log header의 단방향 호환 레벨을 올려, 이전 binary는 Sidecar DB를 거부한다.

### 진행 상황과 측정 결과

브랜치 `sidecar`는 `develop` `e64a04a79`에서 시작했다. 처음 세 커밋은 설계 검토 중 `develop`에서 찾은 결함의 수정이다(CBRD-27937, CBRD-27935, CBRD-27936). Sidecar가 heap의 슬롯 보호를 그대로 물려받으므로 이 수정이 전제 조건이다.

| 단계 | 상태 | 결과 |
|---|---|---|
| P0 inert hook과 비용 gate | 완료 | A1 run 1 통과. 처음 scan wall +6.4%가 나왔고, 원인은 코드 배치 변화로 인한 JCC erratum DSB miss였다. flag 검사를 기존 all-visible mask에 합쳐 scan200 cycles +0.57%, wall +1.10%로 낮췄다. |
| P1 쓰기·읽기 경로 | 완료 | INSERT/UPDATE/DELETE, rollback, `loaddb`, `compactdb`, partition 이동, TDE store, 지연 읽기용 한 페이지 store cursor, `SHOW HEAP SIDECAR OF t`, 검증기 `sidecar_verify_class`. 전체 하네스 452/452 통과. A1 run 2 통과: instructions 최대 +0.69%(UPDATE), wall은 모든 경우 중앙값 기준 통과. |
| P2 IO | 완료 | A2 10개 기준 모두 통과. `develop` 대비 narrow scan fetch 비율 10.9배/47.4배/426배(1 KB/4 KB/16 KB), 파일 캐시를 비운 상태의 OS `read_bytes` 비율 2.9배/11.5배/102배. |
| P3 정확성 | 진행 중 | 아래 표 참고. |
| P4 HA 복제 | 시작 전 | checkpoint 2 검토 후 진행한다. 그때까지 HA가 켜진 DB에서는 값을 밖으로 옮기지 않는다. |

P3 수락 결과:

| 항목 | 상태 | 결과 |
|---|---|---|
| A3 recovery | 통과 | 7개 kill 지점 × 20회, 총 140회 kill에서 hash 불일치·미커밋 행·손실 행·고아·끊긴 참조 0건. CBRD-27936 수정을 되돌린 negative control에서는 restart가 UNDO 단계에서 멈춰, 이 테스트가 해당 창을 실제로 지나는 것을 확인했다. |
| A4 MVCC·vacuum | 시나리오 통과, 24시간 stress 미실행 | 6,000 B 10회, 20 KB 3회 모두 통과. REPEATABLE READ 읽기는 항상 첫 값을 보고, committed snapshot 읽기의 retry와 lock fallback이 실제로 일어났으며 모두 커밋된 값을 돌려주었다. retry를 끈 negative control에서는 살아 있는 행을 67회 중 9회 놓쳤다. |
| A6 회귀 | 일부 | `test_sql` 1,740개를 off/on으로 실행해 1개만 달랐고, 원인은 parallel scan 여부가 바뀌는 레이아웃 효과였다. `test_shell` 279개 off/on 비교에서 12개가 달랐다(TDE 파일 dump에 store 파일이 추가되는 경우, SHOW HEAP HEADER 레이아웃 등). `develop` 대조와 `test_medium`은 진행 중이다. |
| A7 모델 검사 | 발견 2건, 수정은 별도 브랜치 | 설계 모델(lifecycle 44회, recovery 38회)과 heap slot undo 검사는 통과. 코드 수준 Sidecar 검사에서 store 읽기 결함 2건을 찾았다(재배치된 store 레코드 읽기 중 forward 슬롯 재사용으로 같은 길이의 다른 값을 읽는 경우, 재읽기 한도 초과로 보호된 읽기가 실패하는 경우). 수정은 store 슬롯을 재사용하지 않게 하고 재읽기 한도를 없앴으며, 브랜치 `sidecar-storeread`에 있고 아직 `sidecar`에 합치지 않았다. |

### 남은 일

- A7 수정(`sidecar-storeread`)을 `sidecar`에 합치고 A3, A4를 다시 확인한다.
- A4 24시간 stress(공격적 vacuum, 긴 읽기, 보호되지 않은 읽기, 무작위 rollback, `kill -9`).
- A6: `test_shell`, `test_medium`의 off/on 결과를 `develop`과 대조하고 차이를 분류한다. 전체 corpus는 CI에서 실행한다.
- checkpoint 2: A1, A2, A3, A4, A6, A7 결과 검토.
- P4: HA 복제(A5).

### 알려진 한계

- POC 범위 밖: CDC와 flashback(`supplemental_log > 0`이면 밖으로 옮기지 않음), `STORAGE` DDL 절, 기존 store의 `ALTER ... ENCRYPT`, store 슬롯 재사용과 주소 회수, extent 정책, ref를 아는 page-batch 경로, index scan의 store cursor 유지.
- store 슬롯을 재사용하지 않으므로, 교체된 값마다 `REC_MARKDELETED` 슬롯이 하나씩 남는다.
- 16 KB, 64 KB 값의 wide scan은 page fix가 `develop`의 1.67배, 1.33배다. BIGONE 값마다 map page fix 2회와 header 읽기가 따로 들기 때문이다(buffer hit이며 IO는 아님).
- OOS 성능 측정의 W4 테이블(1,300 B 값 3개와 약 5 KB 값 2개)에서는 AUTO가 5 KB 값 두 개만 옮기고 1,300 B 값은 inline에 남긴다. 그 결과 파일 캐시를 비운 narrow scan에서 OOS와 마찬가지로 `develop`보다 4.4% 더 읽는다. 이 형태에서 이득을 보려면 extent 정책이나 열 단위 `EXTERNAL` 지정이 필요하다.
- `test_shell` TDE 케이스 일부는 테이블 파일 dump에 store 파일이 추가되어 답이 달라진다. 기대 결과를 바꿀지는 아직 정하지 않았다.

### 관련 자료

- 설계 문서: [my-cubrid-docs/sidecar](https://github.com/vimkim/my-cubrid-docs/tree/main/sidecar) (`design.md` 설계와 수락 조건·계획, `grounding.md` 기존 엔진 사실, `decisions.tsv` 결정 기록, `model/` TLA+ 모델)
- OOS EPIC: [CBRD-26357](https://jira.cubrid.org/browse/CBRD-26357)
- 전제 수정: [CBRD-27937](https://jira.cubrid.org/browse/CBRD-27937), [CBRD-27935](https://jira.cubrid.org/browse/CBRD-27935), [CBRD-27936](https://jira.cubrid.org/browse/CBRD-27936)
- 같은 목표의 다른 대안 설계: [CBRD-28054](https://jira.cubrid.org/browse/CBRD-28054) POC-2 Inner Table
- Draft PR: 생성 후 추가
