# [OOS] [M2] [Regression] [HA] 매뉴얼 테스트 ha_shell / ha_repl 실패 분류 및 M2 머지 게이트 판정

## Issue Triage

**이슈 수행 목적**: OOS 빌드 (`11.5.0.2338-404b396`) 의 HA 매뉴얼 테스트 실패 95건 (`ha_shell` 9 + `ha_repl` 86) 을 분류해, develop 머지를 막을 수 있는 OOS 회귀 후보가 `cbrd_24983` 한 건뿐임을 보인다. 나머지 94건은 OOS 와 무관함을 근거와 함께 확정한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: 매뉴얼 테스트 통과는 OOS M2 의 develop 머지 필수 게이트다. 그런데 HA 카테고리 (`ha_shell` / `ha_repl`) 가 아직 분류되지 않았다 -- 선행 분석 (CBRD-26660 / 26817 / 26832) 은 단일 서버 `test_shell` 만 다뤘기 때문이다. 게다가 OOS 빌드의 HA 결과는 아직 qahome 에 등록되지 않아 (`showHa` 가 "결과 없음" 반환), 실패 목록 (`fail.txt`) 만 있고 실제 diff 가 없다.
- **영향**: 분류가 없으면 양방향으로 위험하다. (1) OOS 와 무관한 실패 94건이 6/17 머지를 괜히 막는다. (2) 반대로 유일한 진짜 OOS 후보 (`cbrd_24983`) 를 94건의 잡음 속에 놓친다.

**이슈 수행 방안**:

- **분류 기준 (한 줄)**: OOS 는 "레코드가 약 2KB (`DB_PAGESIZE/8`) 를 넘고 **그리고** 가변 컬럼이 512B 를 넘을 때" 만 동작한다. 이 조건을 못 넘는 테스트는 OOS 코드를 한 줄도 실행하지 않으므로 OOS 회귀일 수 없다 (코드 위치는 맨 아래 Reference).
- **분류 결과 (95건 -> 6 버킷)**:

  | 버킷 | 무엇 | 건수 | OOS 가 원인? | 머지 |
  |---|---|--:|---|---|
  | A | `cbrd_24983` -- 대형 컬럼이 OOS 로 빠진 뒤 slave 로 복제 | 1 | **가능 (유일 후보)** | **잠재 차단** |
  | B | `cbrd_26374_ha` -- 스크립트가 testcase 저장소에 없음 | 1 | 아니오 (테스트 인프라) | 비차단 |
  | C | 이미 알려진 버그로 verified | 2 | 아니오 | 비차단 |
  | D | failover / 카탈로그 / 출력포맷 (`ha_shell`) | 5 | 아니오 (임계 미달) | 비차단 |
  | E | PL/CSQL 스위트 (`ha_repl`) | 78 | 아니오 (임계 미달) | 비차단 |
  | F | 예전부터 실패하던 것 (`ha_repl`) | 8 | 아니오 (임계 미달) | 비차단 |

- **결론**: 머지를 막을 수 있는 건 **A 1건뿐**이고, 그마저 아직 "후보" 다. B~F 94건은 비차단. **A 를 로컬에서 한 번 재현하면 게이트 판정이 끝난다.**
- **미결정 (TBD)**:
  - `cbrd_24983` 이 실제로 slave 복제에 실패하는가 (slave `applyinfo` 의 Fail count, slave 행 수): `TBD -- 로컬 HA 재현 필요`. 실패로 확인되면 별도 버그로 분리.
  - E (PL/CSQL) 가 깨지는 정확한 원인 (slave 의 PL 엔진 미기동 / answer 불일치 등): `TBD -- 매뉴얼 run 로그 또는 로컬 재현 필요` (qahome 미등록).

---

## AI-Generated Context

> 아래는 AI 가 `fail.txt` 목록 + OOS 소스 + 로컬 testcase 저장소를 대조해 만든 분류다. 빠른 판단은 위 **Issue Triage** 만 보면 된다. 상태: **v1.5** -- 자동 CI 와의 대조는 반영했고, 매뉴얼 run 의 실제 diff 는 아직 못 받았다 (qahome 미등록).

### Summary

- **한 줄 결론**: HA 실패 95건 중 OOS 머지 차단 후보는 `cbrd_24983` 1건뿐. 나머지 94건은 OOS 코드를 타지 않아 회귀가 불가능하다.
- **왜 그렇게 갈리나**: `ha_repl` 86건의 91% (78건) 가 PL/CSQL 스위트인데, 이들은 작은 스칼라 값만 다뤄 OOS 임계 근처도 안 간다.
- **추가 근거 (자동 CI 대조)**: 자동 CI 의 다른 빌드 run 에서 -- PL/CSQL 78건은 안 깨지고 (매뉴얼 run 특이), F 의 8건 중 7건은 똑같이 깨진다 (예전부터의 baseline).
- **남은 일**: `cbrd_24983` 로컬 재현 1건이면 머지 게이트 판정이 끝난다.

---

## Description

### 한눈에 보기

OOS 의 develop 머지 전, HA 매뉴얼 테스트 (`ha_shell` 9 + `ha_repl` 86 = 95건) 가 실패했다. 핵심 질문은 하나다 -- **"이 중 OOS 가 만든 회귀가 있는가?"**

판정은 단순하다. OOS 는 큰 가변 컬럼 (512B 초과) 이 2KB 넘는 레코드에 들어갈 때만 켜진다. 그 조건을 안 넘는 테스트는 OOS 코드를 실행조차 하지 않는다. 이 기준을 95건에 적용하면:

- **OOS 가 원인일 수 있는 건 단 1건** -- `cbrd_24983` (대형 컬럼을 복제). 그것도 아직 미확인.
- **나머지 94건은 OOS 코드를 안 탄다** -- 따라서 OOS 회귀가 아니다.

즉 **HA 실패는 6/17 머지를 막지 않는다.** 남은 확인은 `cbrd_24983` 로컬 재현 한 번뿐이다.

### 빌드 / 범위

- 빌드 `11.5.0.2338-404b396` (`feature/oos-m2`, HEAD `ca3e7d522`). 단일 서버 `test_shell` 분석인 CBRD-26832 와 같은 빌드의 HA 카테고리를 다룬다.
- run: `ha_shell` 2026-05-21 (368건 중 9 실패), `ha_repl` 2026-05-22 (16,289건 중 86 실패).
- 한 가지 신호: `ha_repl` 86건 중 85건이 "이번에 처음" 깨졌다. 한꺼번에 새로 깨지는 분포는 코드 회귀 86개보다 환경 / 범위 변화에 가깝다.

### 버킷별 정리

**A. `cbrd_24983` -- 유일한 OOS 후보 (머지 차단 가능)**
대형 `content` 컬럼 (수 KB) 을 가진 행을 적재하고, slave 로 제대로 복제됐는지 (`applyinfo` Fail count = 0, slave 행 = 2) 검사하는 테스트. 값이 크니 OOS 가 켜지고, 그 OOS 데이터가 slave 까지 가야 한다 (OOS 불변식 #1 WAL, #5 복제 로그). 복제가 깨졌으면 진짜 OOS 버그다. 캘린더의 read-side 회귀 `#29 / cbrd_25481` 과 write / 복제 짝일 수 있다. -> 로컬 재현으로 확정.

**B. `cbrd_26374_ha` -- 테스트 인프라 (제품 무관)**
이 스크립트가 testcase 저장소에 아예 없다 (`cbrd_26374_{dba,user,unknown}` 변형만 있고 git 이력에도 `_ha` 가 없음). 제품 버그가 아니라 누락된 테스트로 보인다. cbrd_26374 자체는 사용자 스키마 (권한) 관련이라 OOS 와 무관.

**C. 이미 알려진 버그 2건 (verified)**
`cbrd_22207` -> CBRD-26635, `cbrd_22705_03` -> CBRD-26576 (타이밍 의존 develop 버그). QA 가 이미 기존 버그로 확인. 추가 작업 없음.

**D. `ha_shell` 비-OOS 5건**
JDBC failover (`bug_bts_6198`), 100만 행 복제 지연 (`bug_bts_7638`), 권한 카탈로그 answer (`cbrd_24370`), csql 대화형 출력 (`cbrd_25837`), 동시성 정합성 (`bug_bts_12772_1`). 모두 대형 컬럼을 안 쓴다 -> 환경 / 타이밍 / answer 불일치로 추정. develop baseline 으로 확정.

**E. PL/CSQL 스위트 78건 (`ha_repl` 의 91%)**
`sql/_05_plcsql/...` 의 타입변환, 루프, case, 리터럴, 함수호출 -- PL/CSQL 기능 전 영역이 한꺼번에 깨졌다. 이들은 `cast(782346 as int)`, `DATE'2008-10-31'`, `'{"a":1}'` 같은 작은 값만 쓴다. OOS 임계 근처도 아니므로 **OOS 회귀가 불가능하다.** 깨지는 진짜 이유는 PL 엔진 (Java `cub_pl`) 의존으로 보인다: 모든 케이스가 `create function` + `dbms_output` 을 쓰는데, slave 에 PL 엔진이 안 떠 있거나 answer 가 어긋나면 스위트 전체가 한 번에 깨진다. 게다가 **자동 CI 의 같은 카테고리에선 이 78건이 안 깨진다** -> 매뉴얼 run 특이 (환경 / 범위) 이지 OOS 코드 문제가 아니다.

**F. 예전부터 실패하던 `ha_repl` 8건**
nchar / i18n, shared attribute, analytic 함수, width_bucket 등. 작은 값만 쓰고 오래전부터 실패해 온 항목들. **자동 CI (빌드 2220) 에서도 8건 중 7건이 똑같이 실패한다** -> OOS 도입이 아니라 예전부터의 baseline. 나머지 1건 (`1020.test`) 만 별도 확인.

### 남은 확인 (이것만 하면 끝)

1. **`cbrd_24983` 로컬 재현** -- HA master / slave 를 띄우고 데이터를 적재한 뒤 slave `applyinfo` 의 Fail count 와 행 수를 본다. 이상이 있으면 OOS 복제 버그로 별도 분리. 이 한 건이 머지 게이트의 실질 리스크다.
2. **E (PL/CSQL) 원인 확정** -- 매뉴얼 run 로그를 받거나 로컬에서 PL/CSQL 1건을 재현해, "slave PL 엔진 미기동" 인지 "answer 불일치" 인지 가른다. qahome 엔 미등록이라 직접 못 받는다.
3. **D + `1020.test` baseline 대조** -- develop HEAD 에서 다시 돌려 예전부터의 실패인지 확정.

---

## Reference

### 판정 기준: OOS 가 켜지는 조건

OOS 는 다음 두 조건을 **모두** 만족할 때만 동작한다.

1. 레코드 크기 > `DB_PAGESIZE / 8` (16KB 페이지에서 약 2KB) -- `src/storage/heap_file.c:12466`
2. 가변 컬럼이 `!is_fixed && column_size > 512` -- `src/storage/heap_file.c:12472`

복제 시 OOS OID 를 실제 값으로 치환하는 경로는 `heap_record_replace_oos_oids` (`heap_file.c:7932 / :7942 / :7961`). OOS OID inline 크기는 `OR_OOS_INLINE_SIZE` = 16B (`object_representation.h:455`).

### qahome 등록 상태 / 좌표 (재현용)

- OOS 빌드 (2338) 의 매뉴얼 HA 결과는 **미등록**: `RB-11.5.0-Manual` 의 build 2338 = `treeId=5196`, `showHa.nhn` 이 "There is no test result!" 를 반환한다. 그래서 `cbrd_24983` / PL/CSQL 의 실제 diff 를 qahome 에서 못 받는다.
- 대조에 쓴 자동 CI: `RB-11.5.0` = `treeId=4883`, `ha_repl` build `2220-598129e` `statid=5941` (9건 실패, PL/CSQL 0건). HA diff 는 `ha_repl_result_*.tar.gz` 아카이브로 저장되어 인라인 viewer 로는 안 보인다.

### 입력 / 산출 파일 (분석가 로컬 트리, PR 미포함)

- `~/gh/cb/oos-m2-ha-fail/ha_shell_fail.txt` (9건), `ha_repl_fail.txt` (86건) -- 원본 실패 목록.
- `~/gh/cb/oos-m2-ha-fail/ha-failure-triage.md` -- 상세 triage.
- 주의: `fail.txt` 의 테스트별 숫자 (예 "history 11~26") 는 "누적 실패 횟수" 로 추정해 인용한 것이며, qahome 원본 확인 후 확정한다.

---

## Remarks

- 부모 epic: CBRD-26583 (OOS M2).
- 별개 시리즈 (단일 서버 `test_shell` 분석): CBRD-26660 / CBRD-26817 / CBRD-26832. 본 이슈는 그 시리즈의 round-4 가 아니라, 같은 빌드의 HA 카테고리를 다루는 별개 분석이다 (CBRD-26832 가 HA 를 수집하지 않았다고 명시함).
- 관련 티켓: CBRD-26824 (OOS answer 업데이트), CBRD-26516, CBRD-26517.
- 본 이슈는 분석 / 추적용. A (`cbrd_24983`) 가 실제 OOS 복제 버그로 확정되면 fix 는 별도 child 버그에서 다룬다.
- 잔여 미확정 (manual run 로그 또는 로컬 재현 후 v2 확정): A 의 slave Fail count, E 의 정확한 실패 원인.
