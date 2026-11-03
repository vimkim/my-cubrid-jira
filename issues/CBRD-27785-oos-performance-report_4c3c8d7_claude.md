# [OOS] heap·overflow 경로의 CRUD 성능 저하 조사 및 개선

## Issue Triage

**이슈 수행 목적**: 개발4팀 박세훈 팀장님(shparkcubrid)이 [PR #7990](https://github.com/CUBRID/cubrid/pull/7990#issuecomment-6434778190)에서 보고한 OOS 통합 후 성능 저하를 조사·개선한다. 현재는 OOS 값이 없는 일반 테이블의 비교(AC-P1)와 현재 버전의 이득·손해 공개(AC-P3)를 우선하고, develop 대비 서버 instructions 증가 약 +2% 이내를 잠정 목표로 삼는다.

**이슈 수행 이유**: 보고에서 일반 테이블의 풀 스캔·조건 스캔·UPDATE가 develop 대비 +8.0%·+9.9%·+7.0%, 6KB 값 테이블의 큰 컬럼 스캔이 +40.6%, 작은 컬럼 UPDATE가 +73.7% 늘었다. 리뷰어는 [10/28 답변](https://github.com/CUBRID/cubrid/pull/7990#issuecomment-6461744209)에서 현재 성능으로는 머지가 어렵다고 판단하고 병합 전 기준 세 가지를 제시했다.

**영향**: 일반 테이블의 회귀는 OOS를 쓰지 않는 모든 테이블의 CRUD에 CPU 비용을 더한다. PR #8299의 개선으로 일반 테이블 증가는 develop 대비 +1.03~+1.84%(`fd8624c`, 중앙값)까지 줄었다. 그러나 UPDATE에서 +3.84%·+5.0158% 표본이 관측됐고, 현재 head `4c3c8d791`은 develop과 비교 측정하지 않았다.

**이슈 수행 방안**: PR #8299에서 일반 행 읽기·UPDATE의 OOS 준비 비용을 제거하고, 최종 head를 develop과 같은 조건(문자셋 포함)으로 재측정해 AC-P1을 판정한다. 기본 threshold의 4–16KB 전체 읽기(AC-P2)는 threshold를 기존 overflow 기준에 맞춘 뒤 후속으로 재측정한다.

---

## AI-Generated Context

> 아래는 PR 댓글, 측정 보고서, CI 기록을 대조해 정리한 내용이다. 각 수치에 **측정**(작성자 측 실측), **보고**(리뷰어 보고), **추론**, **미확인**을 구분한다. develop 대비 비교와 PR #8299 내부 revision 사이의 비교를 섞지 않는다.

### 한눈에 보기

| 단계 | 내용 | 자세히 |
| --- | --- | --- |
| 1. 보고 | 개발4팀 박세훈 팀장님이 PR #7990 댓글에서 develop 대비 서버 instructions 증가를 보고했다. 일반 테이블은 풀 스캔 +8.0%, 조건 스캔 +9.9%, UPDATE +7.0%였다. 6KB 값 테이블은 큰 컬럼 스캔 +40.6%, 작은 컬럼 UPDATE +73.7%였다 (보고) | Reviewer Report |
| 2. 재현 | 일반 테이블 회귀는 일반 테이블을 잰 모든 시도에서 재현했다(+5.03~+9.00%). 큰 값 스캔과 UPDATE의 원문 수치는 재현하지 못했다 (측정) | Reproduction |
| 3. 차이 | 수치를 바꾼 조건은 DB 문자셋과 UPDATE 시작 상태였다. 같은 develop에서 LENGTH 스캔이 UTF-8 294.1M, ISO-8859-1 188.6M였다(보고 186.1M). 작은 컬럼 UPDATE는 새 복제본 -5.90%, 같은 테이블 연속 +135~+176%였다 (측정). 리뷰어 환경의 문자셋은 미확인이다 | 보고와 재현의 차이 |
| 4. 원인과 해결 | 일반 행도 OOS 준비·dispatch를 거친 것과 일반 UPDATE의 선행 OOS 계획이 주요 비용이었다 (측정). PR #8299는 일반 값을 OOS 경로 밖에서 읽고, OOS 계획과 owner를 필요할 때만 만든다. 큰 값 비용(heap → OOS)과 OOS 값 재작성은 별도 범위다 | Cause and Fix |
| 5. 개선 후 | develop 대비 일반 테이블 +7.02%·+8.32%·+5.35%가 `fd8624c`에서 +1.03%·+1.84%·+1.77%로 줄었다(중앙값, 측정). 현재 head `4c3c8d791`은 develop 대비 미측정이고 AC-P1은 미완료다 | Results After Fixes |

### 현재 상태 (2026-11-03)

| 대상 | 상태 |
| --- | --- |
| [PR #8299](https://github.com/CUBRID/cubrid/pull/8299) | head `4c3c8d791`, draft, 미병합, base `feature/oos-merge`. [CI run 41485345491](https://github.com/CUBRID/cubrid/actions/runs/41485345491)에서 release·debug 빌드, shell, SQL, medium 성공 |
| `4c3c8d791` | CBRD-27057의 four-record OOS target(4,060B)을 옮겨 왔다. 이전 기준은 `DB_PAGESIZE / 4`(4,086B)였다. 성능은 측정하지 않았다 |
| [PR #7990](https://github.com/CUBRID/cubrid/pull/7990) | head `dcbf09e`, OPEN, CHANGES_REQUESTED, develop과 충돌 |
| 리뷰어 수락 | 받지 않았다. 잠정 +2% 목표도 리뷰어가 승인한 수치가 아니다 |

## Reviewer Report

개발4팀 박세훈 팀장님(shparkcubrid)이 PR #7990에 [10/27](https://github.com/CUBRID/cubrid/pull/7990#issuecomment-6434778190)과 [10/28](https://github.com/CUBRID/cubrid/pull/7990#issuecomment-6461744209) 두 번 성능 측정을 보고했다.

### 보고된 측정 조건

| 항목 | 리뷰어가 밝힌 조건 (보고) |
| --- | --- |
| 비교 | PR head `4408135c`와 develop merge-base `4781495f`, release 빌드, 같은 호스트·같은 conf, 서버 직렬 실행 |
| 지표 | `perf stat -e instructions:u -p <cub_server pid>`의 서버 user-space instructions 중간값. 공유 호스트라 wall-clock은 판정에 쓰지 않았다 |
| 반복 | 10/27: 2라운드. 10/28: 4라운드(이틀에 걸쳐 2라운드씩). 라운드마다 5회, 첫 1회는 warmup 제외 |
| 메모리 | `data_buffer_size=4G`, 데이터 전체가 buffer에 상주. I/O 절감 효과는 측정 범위 밖 |
| 테이블 | `w`: SHA2 연결 6KB 값 2만 행(PR에서 OOS), `m`: 2.5KB 값 2만 행(OOS 임계값 아래), `n`: 약 100B 행 20만 개(대조군) |
| 밝히지 않은 조건 | DB locale·charset, 10/28 표의 feature SHA, UPDATE 표본 사이 초기화 여부, compiler·호스트 |

### 보고된 결과 (develop 대비 instructions 변화, 보고)

| 작업 | `w` 6KB, OOS | `m` 2.5KB | `n` 작은 행 |
| --- | ---: | ---: | ---: |
| 적재 | +1% | +0% | +3% |
| 좁은 컬럼 풀 스캔 | **-23.1%** (43.6M → 33.6M) | +6% | **+8.0%** (252.7M → 272.9M) |
| 큰 컬럼 읽는 스캔 | **+40.6%** length, **+38.7%** substr. wall 2.5배 | +9% | **+9.9%** 조건 스캔 (476.8M → 524.1M) |
| PK 점조회 3000건 | +2% | +1% | +0% |
| 작은 컬럼 UPDATE | **+73.7%** (3,467.0M → 6,021.9M) | +3% | **+7.0%** (6,323.8M → 6,769.6M) |
| 큰 컬럼 UPDATE, 5000행 | **+34.6%** (1,789.8M → 2,408.7M) | +17% | 해당 없음 |

굵은 값은 10/28 4라운드 중간값이고, 나머지는 10/27의 반올림 값이다. `n` 열의 조건 스캔 +9.9%는 10/27 표의 같은 행(+10%)에 대응한다고 보았다(추론). 공간은 문제가 없었다고 보고했다. 5KB~40KB 값에서 heap과 OOS를 합한 페이지 수는 develop 이하였다.

### 리뷰어의 원인 추정과 병합 기준 (보고)

- 일반 행: 속성 디코드 비중이 9.3%에서 13.1%로 늘었다. 속성마다 header 검증과 offset 조회를 반복하고, `heap_attrvalue_read`가 호출마다 16KB stack 버퍼를 잡는다고 보았다.
- OOS 값 읽기: 값마다 페이지 고정 세 번(volume header, sector table, OOS page)과 복사 두 번이 붙는다고 보았다.
- UPDATE: 바뀌지 않은 OOS 값도 새로 쓰고 vacuum이 옛 값을 지운다([CBRD-27230](https://jira.cubrid.org/browse/CBRD-27230) 범위).
- 병합 기준은 세 가지다. ① OOS 값이 없는 테이블이 develop보다 느려지지 않을 것(측정 노이즈 제외), PR #8299 선반영. ② 기본 설정에서 4–16KB 행의 전체 읽기가 develop보다 느려지지 않을 것. ③ 현재 PR 버전의 이득과 손해를 CBRD-27788 결과와 함께 공유할 것.

## Reproduction

### 재현 시도와 결과

| 날짜 | 비교 (develop `4781495f` 대비) | 입력과 SQL | charset | 결과 (측정) | 판정 |
| --- | --- | --- | --- | --- | --- |
| 10-27 | feature `dcbf09e` | 재구성한 108B 행 20만 개, 좁은·여러 컬럼 스캔 2개 | 미기록 | +5.1249%, +8.8904% | 일반 테이블 회귀 **재현** (다른 SQL) |
| 10-28 | feature `dcbf09e`, 3-way | 원문 `n` DDL·SQL, 풀·조건 스캔, UPDATE(매번 새 복제본) | 미기록 | +7.02%, +8.32%, +5.35% | 일반 테이블 회귀 **재현** (보고 +8.0·+9.9·+7.0%와 근접) |
| 10-28 | feature(revision 식별 불충분), 단일 방향 pair, 표본 4개 | 원문 `w` SQL | 미기록 | LENGTH +26.21%, SUBSTR +15.27%. 작은 컬럼 UPDATE: 새 복제본 -5.90%, 연속 +135.49% | 큰 값 수치 **불일치** |
| 10-31 | feature `4408135c`, 4라운드 | 원문 DDL·8개 SQL 그대로, UPDATE 연속 20회 누적 | UTF-8 | LENGTH +28.32%, SUBSTR +15.83%, 작은 컬럼 UPDATE +176.31%, 일반 +7.01·+8.31·+5.79% | 일반은 재현, 큰 값은 **불일치** |
| 10-31 | 같음 | 같음, 새 DB | ISO-8859-1 | LENGTH +44.18%, SUBSTR +39.61%, 작은 컬럼 UPDATE +175.81%, 큰 컬럼 UPDATE +27.26%, 일반 +7.01·+9.00·+5.03% | 큰 값 스캔은 근접, UPDATE는 **불일치** |

결론적으로 일반 테이블 회귀(+5.03~+9.00%)는 일반 테이블을 잰 모든 시도에서 재현했다. 큰 값 스캔과 UPDATE의 원문 수치는 재현하지 못했다. `m` 테이블(2.5KB)은 DDL이 제공되지 않아 재현하지 않았다.

### 보고와 재현의 차이

| 항목 | 보고 | 재현 | 수치에 준 영향 |
| --- | --- | --- | --- |
| DB 문자셋 | 밝히지 않음 | UTF-8과 ISO-8859-1을 따로 측정 | 같은 develop의 LENGTH가 UTF-8 294.076M, ISO-8859-1 188.608M(보고 186.1M). 문자셋이 계수를 크게 바꾼다 (측정). 리뷰어의 locale은 **미확인** |
| UPDATE 시작 상태 | 밝히지 않음 | 새 복제본 또는 같은 테이블 연속 | 작은 컬럼 UPDATE가 새 복제본 -5.90%, 연속 +135.49~+176.31%. 누적 OOS 값과 vacuum 상태가 원인이라는 것은 **추론**이며 인과는 확정하지 않았다 |
| feature revision | 10/27은 `4408135c`, 10/28 표는 SHA 없음 | `4408135c`(10-31), `dcbf09e`(10-27·10-28) | 10/28 표가 어느 revision인지 **미확인** |
| 라운드·일정 | 4라운드, 이틀, 스캔 라운드 차 0.3%p 이내 | 4라운드 하루 연속 | ISO-8859-1 큰 컬럼 UPDATE의 라운드별 값이 +21.64~+65.72%로 흔들렸다 (측정) |
| 빌드·호스트 | release, compiler 미기재 | GCC 11.5.0, RelWithDebInfo `-O2 -DNDEBUG` | 영향 **미확인** |
| 병렬 scan | 원인 후보로 언급 | 측정 뒤 TRACE에서 feature의 `w` 스캔에만 parallel worker 표시가 없었다 | wall 2.5배와의 관계는 **미확인** |

## Cause and Fix

### 원인과 해결 한눈에 보기

| # | 원인 | 근거 | 해결 | 상태 |
| --- | --- | --- | --- | --- |
| 1 | 일반 행 읽기도 OOS 준비·dispatch를 거쳤다. 공통 reader에 16KB OOS scratch가 있어 stack 예약이 `0x4088`B(기준 `0x58`B)였다 | 진단 실험(좁은/여러 컬럼 스캔, develop 대비): 일반 행에 develop의 reader만 넣으면 +4.43%/+2.76%, loop까지 develop 형태로 바꾸면 +1.81%/+0.96%, 되돌리면 +5.14%/+8.90% (측정) | PR #8299: 고정·inline 가변 값은 OOS 준비 없이 읽고, 실제 OOS 필드만 별도 경로로 보낸다. `5c5f2a170`에서 Resolve를 noinline `heap_attrvalue_read_oos`로 분리해 읽기 함수 frame이 16.6~16.8KB에서 128~336B로 줄었다 | 반영(PR 미병합) |
| 2 | 가변 값 위치를 속성마다 다시 해석했다 | 리뷰어 perf: 디코드 비중 9.3% → 13.1% (보고) | 이미 구한 record layout으로 offset 두 개를 같은 폭으로 읽는다. 경계 검사는 공통 decoder로 유지한다 | 반영(PR 미병합) |
| 3 | 일반 UPDATE에도 OOS 계획과 추가 pending owner를 미리 만들고, writer가 컬럼마다 header를 다시 해석했다 | 3-way: UPDATE +5.35% → +1.66% (측정) | 크기·FORCE_OUTLINE 선택을 한 번에 계산하고, owner는 copy-area/workspace 입력일 때만 만든다 | 반영. 잔여 변동은 [CBRD-27816](https://jira.cubrid.org/browse/CBRD-27816) |
| 4 | 바뀌지 않은 OOS 값도 UPDATE마다 다시 쓴다 | 보고 +73.7%, 연속 UPDATE 재현 +175.81% (측정) | 값 재사용 최적화는 [CBRD-27230](https://jira.cubrid.org/browse/CBRD-27230). 기존 overflow도 record 전체를 다시 쓴다 | 본 이슈 범위 밖 |
| 5 | 기본 threshold에서 4–16KB 값이 heap에서 OOS로 옮겨진다(2번 경로). 값마다 별도 page fix·복사가 붙는다 | 보고 +40.6%, ISO-8859-1 재현 +44.18% (측정). CBRD-27788의 heap→OOS Q4 instructions +8.6% (측정) | threshold system parameter를 기존 overflow 기준에 맞춘 뒤 재측정(AC-P2) | 후속 이연 |
| 6 | 큰 값 조회의 파일 읽기 순서가 흩어진다 | CBRD-27788: OS 캐시 해제 요청 후 overflow→OOS Q4 +146.6% (측정) | 읽기 순서 조정·선행 읽기는 [CBRD-27791](https://jira.cubrid.org/browse/CBRD-27791) | 별도 이슈 |
| 7 | OOS target이 명세의 4,060B가 아니라 4,086B였다. 4,061~4,086B 행이 inline에 남아 page당 3개만 들어갔다 | CBRD-27057 계산과 서버 확인: 4,011B 값은 inline, 4,012B 이상은 OOS (측정) | `4c3c8d791`에서 `heap_oos_inline_target_size()` 적용 | 반영, 성능 영향 **미측정** |

## Results After Fixes

### develop 대비: 일반 테이블

분모는 develop `4781495f`의 서버 instructions다. 원문 `n` 테이블(200,000행, heap 1,429 pages, 평균 92B)이며 UPDATE는 매번 새 복제본에서 시작했다. 문자셋은 기록하지 않았다.

| revision | 측정일 | 풀 스캔 | 조건 스캔 | UPDATE | 비고 (측정) |
| --- | --- | ---: | ---: | ---: | --- |
| feature `dcbf09e` (수정 전) | 10-28 | +7.02% | +8.32% | +5.35% | 기준선 |
| `408d135` | 10-28 | +0.64% | +1.36% | +1.66% | 2라운드 정·역순. 같은 엔진 소스의 이전 별도 batch는 UPDATE **+5.0158%** |
| `fd8624c` | 10-29 | +1.03% | +1.84% | +1.77% | develop 대비 마지막 측정. UPDATE 높은 표본 **+3.84%** |
| `5837393ff`, `4c3c8d791` | - | 미측정 | 미측정 | 미측정 | - |

10-27의 재구성 스캔(108B 행)에서도 수정본(`bcb900d`와 같은 엔진)은 좁은 스캔 +1.106605%, 여러 컬럼 스캔 +1.362198%였고 역순도 같았다(측정).

### PR #8299 내부: `f8114e432` → 리뷰 수정본

develop이 아니라 PR의 이전 head가 분모다. 리뷰 수정(OOS scratch 분리 등)이 느려지게 했는지 확인한 비교다. 11-02는 `eec338aaa`(최종 head와 `heap_file.o` 기계어 동일), 11-03은 `5837393ff`를 측정했다. 11-03 측정은 조용한 시간대만 채택한 ABBA 12라운드이며 charset은 utf8/utf8_bin이다.

| 경우 | instructions 11-02 | instructions 11-03 | cycles 11-03 (서버 시작 단위 중앙값) |
| --- | ---: | ---: | ---: |
| narrow scan | -1.33% | -1.33% | +7.37% (p=0.011, 두 갈래) |
| wide scan | -1.78% | -1.78% | +1.50% |
| 일반 scan | -1.82% | -1.81% | +1.15% |
| 조건 scan | -0.82% | -0.81% | -0.67% |
| UPDATE | -0.47% | -0.46% | -0.25% |

- instructions는 다섯 경우 모두 줄었다. 원인을 분리하지 못했으므로 속도 개선이 아니라 회귀 없음으로 판정한다.
- cycles는 측정 전에 정한 회귀 기준(+2% 초과, p<0.01, 라운드 간 일관)을 충족하지 않는다.
- 다만 narrow scan은 서버 시작마다 빠른 상태와 느린 상태로 갈린다. 수정본은 22번 중 11번이 느렸고(+약 14%), 이전 head는 0번이었다(측정).
- 느린 시작도 instructions는 같고, 분기 예측 실패가 약 65배다. 그중 97.45%가 PR이 바꾸지 않은 [`px_scan_result_handler.cpp:2028`](https://github.com/CUBRID/cubrid/blob/5837393ffb9d69bccb93271d63b0e38b884e0ed4/src/query/parallel/px_scan/px_scan_result_handler.cpp#L2028)의 한 분기에서 났다. ASLR을 끄면 양쪽 3번 모두 빨랐다(측정).
- 코드 배치에 따른 분기 예측기 충돌로 해석한다(추론). 충돌 상대(`__tls_get_addr` 후보)는 **미확인**이다. 현재 head `4c3c8d791`은 코드 배치가 달라 느린 시작의 비율이 다를 수 있다(추론). 벤치마크 행은 92~108B라 4,060B target 변경의 저장 결과에는 영향이 없다.

### AC-P3 자료: OOS의 이득과 손해

[CBRD-27788](https://jira.cubrid.org/browse/CBRD-27788)이 feature `dcbf09e`와 develop을 비교한 자료다(측정). PR #8299 반영 전이며, 100,000행, `data_buffer_size=512M`, 서버 재시작 조건이다. 각 칸은 시간 변화 / instructions 변화다.

| 경로 | Q1 작은 컬럼만 | Q4 큰 값 하나 비교 | Q5 전체 컬럼 | Q4, OS 캐시 해제 요청 후 시간 |
| --- | ---: | ---: | ---: | ---: |
| 2번 heap → OOS | -48.6% / -42.0% | +25.9% / +8.6% | +21.3% / +7.4% | +33.6% |
| 3번 overflow → OOS | -72.1% / -69.3% | -16.8% / +1.4% | +13.2% / +6.6% | +146.6% |

같은 저장 정책의 3번에서도 Q5 instructions +6.6%는 잠정 +2% 목표를 넘는다. PR #8299 반영본으로는 다시 측정하지 않았다.

## Acceptance Criteria

### 현재 판정

| ID | 기준 | 상태 | 근거와 남은 일 |
| --- | --- | --- | --- |
| AC-P1 | 일반 테이블: PR #8299 선반영, 최종 통합 head가 develop 대비 잠정 약 +2% 이내 | **미완료** | `fd8624c`의 중앙값은 +1.03~+1.84%다. UPDATE 높은 표본 +3.84%와 이전 +5.0158%가 남았다. 최종 head `4c3c8d791` 미측정, PR 미병합 |
| AC-P2 | 기본 threshold의 4–16KB 전체 읽기 | **이번 수락 제외, 후속** | threshold parameter의 이름·지원 상태 확인 → 행이 페이지를 넘을 때만 OOS로 가도록 설정 → develop의 heap/overflow와 같은 저장 위치 확인 → 재측정. 기본값 결과와 구분한다 |
| AC-P3 | 현재 버전의 이득·손해와 CBRD-27788 결과 공유. heap→heap·overflow→OOS를 잠정 +2%로 평가 | **부분** | `dcbf09e` 자료는 있다. PR #8299 반영본 미측정. 3번 Q5 +6.6% |
| 공통 | 양쪽 SHA·빌드·conf·데이터·실제 저장 위치·DB locale과 charset·collation·UPDATE 시작 상태·반복별 원시값 기록 | 진행 중 | charset은 11-03 측정부터 기록했다. 문자셋이 다른 표본은 합치지 않는다 |

- [x] 1·2·3번을 실제 저장 위치로 구분하고 범위를 정했다.
- [x] 당시 범위인 일반 heap SELECT 두 건에서 회귀를 재현하고 +2% 이하로 줄였다. 이 결과를 현재 AC-P1 완료로 해석하지 않는다.
- [ ] AC-P1, AC-P3 판정과 리뷰어 수락 근거를 기록한다.
- [ ] 성능 regression TC의 시나리오·지표·판정 기준을 승인받고 performance 영역에 편입한다. 일반 SQL/shell/medium CI와 기본 PR CI의 자동 선택에는 넣지 않는다. 기능·저장 공간 TC는 [CBRD-26659](https://jira.cubrid.org/browse/CBRD-26659)에서 관리한다.

### 잠정 +2%의 위치

- +2%는 작성자 측의 잠정 목표다. 리뷰어의 기준은 "측정 노이즈 제외, develop보다 느려지지 않을 것"이며 +2%를 승인한 기록은 없다.
- PR #8299 본문은 관측된 약 +5% 수준을 수용해 먼저 통합하자고 제안한다. 이는 작성자의 제안이며 리뷰어 승인이나 AC-P1 충족이 아니다.
- 원문의 라운드 간 0.3%p는 관측된 변동이며 허용치가 아니다. CPU 시간·경과 시간·I/O에는 2%를 일괄 적용하지 않는다.

## Scope and Related Issues

### 저장 경로 구분

| 구분 | OOS 적용 전 → 후 | 해석 기준 | 본 이슈 |
| --- | --- | --- | --- |
| 1번 | heap → heap | 저장 위치가 같으므로 비용도 같아야 한다 | 포함 (AC-P1) |
| 2번 | heap → OOS | heap 집적도와 I/O 이득을 얻고 값 접근 비용을 내는 설계 trade-off | 기존 관측값만 보고. 수락 판정은 AC-P2 후속 |
| 3번 | overflow → OOS | 기존과 같거나 나아야 한다 | 포함 (AC-P3) |

선언 길이가 아니라 실제 heap·overflow·OOS 저장 상태로 분류한다. OOS는 heap record를 page당 네 개까지 담을 수 있는 크기(4,060B)로 줄이는 것이 목표다.

### 관련 이슈

| 이슈 | 역할 |
| --- | --- |
| [CBRD-26835](https://jira.cubrid.org/browse/CBRD-26835) | 상위 EPIC, OOS develop 병합 준비 |
| [CBRD-27788](https://jira.cubrid.org/browse/CBRD-27788) | OOS 작은 컬럼 이득과 큰 값 비용의 실측(AC-P3 자료) |
| [CBRD-27791](https://jira.cubrid.org/browse/CBRD-27791) | 큰 값 조회의 읽기 지역성 개선(batch read 등) |
| [CBRD-27816](https://jira.cubrid.org/browse/CBRD-27816) | 일반 UPDATE의 잔여 CPU 비용과 측정 변동 |
| [CBRD-27880](https://jira.cubrid.org/browse/CBRD-27880) | midxkey·copyarea·workspace 테스트 보강 |
| [CBRD-27057](https://jira.cubrid.org/browse/CBRD-27057) | four-record OOS target 4,060B. 수정이 PR #8299 `4c3c8d791`로 옮겨졌다 |
| [CBRD-27230](https://jira.cubrid.org/browse/CBRD-27230), [CBRD-27259](https://jira.cubrid.org/browse/CBRD-27259) | 바뀌지 않은 OOS 값의 UPDATE 재사용, `STORAGE FORCE_INLINE` |

## Evidence

- 리뷰어 보고: [10/27 성능 보고](https://github.com/CUBRID/cubrid/pull/7990#issuecomment-6434778190), [작성자 답변](https://github.com/CUBRID/cubrid/pull/7990#issuecomment-6441306406), [10/28 상세 보고와 재현 SQL](https://github.com/CUBRID/cubrid/pull/7990#issuecomment-6461744209)
- 재현: [원문 SQL 4라운드·문자셋 비교](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-reviewer-reproduction_4408135c_20261031_codex.md), [10-27 재구성 실험과 원인 진단](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-oos-read-performance_bcb900d_codex.md)
- 개선 후 develop 대비: [3-way 비교(`408d135`)](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-shared-read-update_408d135_codex.md), [`fd8624c` 측정](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-common-reader_067aae4_codex.md)
- PR 내부 비교: [리뷰 수정본 검증·측정](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-review-fixes_5837393_claude.md), [narrow scan cycles 원인](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr8299-cycles-layout_5837393_claude.md), [적대적 리뷰](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr8299-adversarial-review_f8114e432_claude.md)
- 수락 기준과 문자셋 조건: [성능 수락 기준](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr7990-performance-acceptance_dcbf09e_codex.md#charset-conditions)
- 이득·손해: [CBRD-27788 SELECT 실측](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-27788/CBRD-27788-oos-select-performance_dcbf09e_codex.md)
- CI: [`4c3c8d791` run 41485345491](https://github.com/CUBRID/cubrid/actions/runs/41485345491), [`5837393ff` run 41435647083](https://github.com/CUBRID/cubrid/actions/runs/41435647083)과 [재실행 41459706876](https://github.com/CUBRID/cubrid/actions/runs/41459706876)
- 전체 자료 목록: [cbrd-27785 README](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/README.md)

측정 하네스는 PR #8299의 `contrib/benchmarks/oos-performance/`(`bench.py`, `ordinary.py`)다. 지표는 `perf stat -e instructions:u,cycles:u -p <cub_server pid>`로 잰 서버 계수다.

## Triage Request

부모 CBRD-26835의 OOS 통합 검토를 위해 본 이슈에서 AC-P1·AC-P3의 판정 근거를 추적한다. 남은 일은 최종 head `4c3c8d791`의 develop 대비 재측정(문자셋 기록 포함), PR #8299 리뷰·병합, 리뷰어 수락 확인이다. AC-P2는 threshold 설정 후 재측정할 후속으로 둔다. 이 문서는 JIRA 유형·우선순위·담당자·상태를 바꾸지 않는다.
