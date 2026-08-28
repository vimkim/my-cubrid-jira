# [CBRD-27335] PGO build 도입

## Issue Triage

**이슈 수행 목적**: CUBRID release 빌드에 PGO(Profile-Guided Optimization) 빌드 변형을 도입해, 실측 profile 기반 최적화로 질의 성능을 개선하고 CBRD-26382에서 확인된 binary layout 민감성을 구조적으로 완화한다.

**이슈 수행 이유**:

- **AS-IS (현재 동작 / 배경)**: 현행 release 빌드는 `-O2` non-PGO라서 hot 함수의 배치가 소스·링크 순서의 우연에 좌우된다. CBRD-26382에서 QA가 보고한 +10.56% 회귀(17.58s -> 19.44s)의 원인 규명 과정에서, 링크 layout이 성능을 움직인다는 인과가 재현 실험으로 확인됐다. 재현 장비에서 확인된 layout 효과는 1%대 규모이며, QA 장비의 +10.56% 배율 전체가 layout 때문인지는 미확정이다.
- **TO-BE (목표 상태 / 기대 동작)**: 대표 workload로 훈련한 profile을 소비하는 `-fprofile-use` release 변형. develop `95b79e7ed` + GCC 11.5 PoC에서 동일 QA workload 기준 질의 시간 median -8.94%를 실측했다 (변형당 n=16, Mann-Whitney U=0, p < 1e-5).
- **영향**: 성능 저하 — 무관한 소스 변경이 링크 layout을 흔들어 재현 실험에서 1%대 회귀를 만들었고, QA 장비에서는 그보다 훨씬 큰 폭이 보고됐다(배율의 원인은 미확정, CBRD-26382). 도입하지 않으면 실측으로 확인된 약 9%의 개선 여지도 방치한다.

**이슈 수행 방안**:

PoC(하단 상세)로 빌드 파이프라인 동작을 확인했다. PoC 결과를 근거로 다음 순서를 제안한다.

| 단계 제안 (합의 미확인) | 내용 |
|------|------|
| 1. 재검증 | 전용 호스트에서 독립 rebuild로 개선 폭을 재확인하고 PGO matrix에 GCC 11 축으로 편입 |
| 2. 훈련 suite | 대표 훈련 workload를 정의하고 PGO 변형을 QA로 검증 |
| 3. 장기 후보 | instrumentation PGO(카운터를 심어 훈련하는 방식) 정착 후 sampling 기반 대안 검토 (하단 비교 표) |

훈련 workload 구성, 공식 release 적용 여부, profile 갱신 주기: TBD - 합의 미확인.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: 빌드 시스템과 CI·QA 매트릭스에 국한된다. 소스 코드, SQL 동작, 스토리지 포맷, 클라이언트 프로토콜 변화는 없다. 다만 codegen 전반이 바뀌므로 PGO 변형 바이너리는 별도 QA 대상이다.

---

## Description

### 배경: layout 운이 성능을 흔든다

CBRD-26382의 최종 분석(comment 4776011)은 scope_exit 리팩토링의 실행 비용이 아니라, PR이 우연히 바꾼 최종 링크 layout이 성능을 움직였다는 인과를 확인했다. 실행되지 않는 7 byte를 되돌리는 것만으로 hot 함수 주소와 시간·pipeline 상태가 함께 복원됐다. 같은 분석은 non-PGO 컴파일러가 실제 SQL의 hotness를 알 수 없으므로 compiler upgrade만으로는 해결되지 않으며, PGO matrix로 확인해야 한다고 끝난다. 본 이슈는 그 후속이다.

### PGO가 하는 일

PGO는 컴파일러의 추측을 실측으로 바꾸는 2-pass 컴파일 기법이다. 1차 pass(`-fprofile-generate`)는 모든 branch/call edge에 카운터를 심은 바이너리를 만들고, 그 바이너리로 대표 workload를 실행하면 프로세스 정상 종료 시 `.gcda` 파일(카운터 덤프)이 기록된다. 2차 pass(`-fprofile-use`)는 같은 소스를 다시 컴파일하면서 실측 빈도를 소비한다.

profile이 있으면 컴파일러는 실제로 자주 불리는 call site만 inlining하고, 자주 타는 branch 방향을 fall-through로 배치하며, 에러 처리 같은 cold block을 `.cold` clone으로 분리하고, hot 함수끼리 가깝게 재배치하며, 실행되지 않은 코드는 크기 위주로 최적화한다. 마지막 두 항목이 CBRD-26382가 앓았던 "우연한 배치"를 "실측 기반 배치"로 바꾸는 부분이다. hot 배치가 실측으로 고정되면, 무관한 cold 코드의 변화가 hot 코드의 phase를 흔드는 경로가 구조적으로 줄어든다.

## Specification Changes

- 사용자에게 보이는 SQL/API 스펙은 바뀌지 않는다.
- 빌드 옵션 신설(PoC branch `CBRD-27335-pgo-build`): 최상위 `CMakeLists.txt`에 `PGO`(`OFF`/`generate`/`use`, 기본 `OFF`)와 `PGO_PROFILE_DIR`(기본 `${CMAKE_BINARY_DIR}/pgo-profile-data`) cache 변수를 추가한다. `PGO=OFF`인 기존 빌드의 동작과 산출물은 그대로다.
- `PGO`를 켜면 GCC 전용이다. 다른 컴파일러로 configure하면 FATAL_ERROR로 중단한다.
- 빌드 절차 스펙: PGO 변형을 채택하면 release 빌드가 instrument -> train -> optimize의 2-pass 파이프라인(컴파일 2회 + 훈련 1회)이 된다. 빌드 산출물(패키지 구성, 설치 경로)은 동일하다.

## Implementation

### 실험 환경

| 항목 | 값 |
|------|------|
| Source | CUBRID develop `95b79e7ed`, worktree 신규 생성 |
| Compiler | GCC 11.5.0 (Red Hat 11.5.0-5), GNU ld, Rocky Linux 9.6 |
| Host | 2x Xeon Gold 5218R (Cascade Lake, 40C/80T). 공유 서버라 타 사용자 워크로드가 동시 실행 중이었다 |
| Baseline | RelWithDebInfo(최적화는 release 수준, 디버그 정보를 함께 남기는 CMake 빌드 타입). 프로젝트 기본 release flag `-O2 -DNDEBUG -finline-functions` + `-ggdb3`, GCC 11.5 경고에 대한 `-Wno-error=` 억제 몇 개 |
| PGO 변형 | 위 flag + 아래 2-pass flag. 그 외 조건 동일. ccache는 PGO 변형에서만 비활성화했다(컴파일 캐시라 codegen에는 영향이 없다) |

### 2-pass 빌드 절차

PoC branch `CBRD-27335-pgo-build`(commit `2adb33a37`)가 이 절차를 `-DPGO` 옵션으로 제공한다.

```
★ generate/use 두 pass는 같은 build 디렉터리를 공유해야 한다. GCC는 object 파일
  절대경로를 mangle한 이름으로 .gcda를 찾으므로 경로가 다르면 profile을 하나도
  못 찾는다. profile 기본 위치도 build 디렉터리 안이다(PGO_PROFILE_DIR).

[1. INSTRUMENT]
  cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX=<설치 경로> -DPGO=generate
  cmake --build build --target install
  ★ GCC 11.5로 develop을 빌드하면 PGO와 무관하게 -Werror에 걸리는 경고가 있어,
    이번 실험에서는 두 변형 모두 baseline flag에 동일한 -Wno-error= 억제를 포함해
    대칭을 유지했다.
        │
[2. TRAIN]
  createdb + 훈련 SQL 실행 (아래 workload)
  ★ 프로세스가 정상 종료해야 .gcda가 기록된다 — cub_server는 반드시
    "cubrid server stop"으로 내린다. kill -9는 profile을 유실한다.
        │
[3. OPTIMIZE]
  cmake -S . -B build -DPGO=use          # 같은 build 디렉터리를 다시 configure
  cmake --build build --target install
```

`PGO=generate`는 `-fprofile-generate`와 `-fprofile-update=atomic`을, `PGO=use`는 `-fprofile-use -fprofile-correction -Wno-missing-profile -Wno-error=coverage-mismatch -Wno-error=stringop-overflow=`를 컴파일·링크 flag에 추가한다. `-fprofile-update=atomic`은 multi-thread 프로세스(cub_server)에서 카운터 경쟁으로 profile이 깨지는 것을 막고, `-fprofile-correction`은 남은 불일치를 사용 단계에서 보정한다. `-Wno-missing-profile`과 `-Wno-error=coverage-mismatch`는 훈련에서 실행되지 않은 파일이나 살짝 낡은 profile 때문에 빌드가 중단되지 않게 하는 안전장치다. `-Wno-error=stringop-overflow=`가 필요한 이유는 아래 도입 비용 표에 있다.

### 훈련·측정 workload

CBRD-26382 QA 쿼리와 같은 규모의 5-way cartesian COUNT(*)를 사용했다. QA 환경의 `db_class`(클래스 목록을 담는 시스템 카탈로그)는 49행이었지만 develop의 `db_class`는 74행이라(74^5 = 약 22억 행) 그대로 쓰면 측정이 과도하게 길어져, 49행 사용자 테이블로 동일 규모(49^5 = 282,475,249행)를 재현했다.

```sql
CREATE TABLE qa49 (a INT);
-- 1..49를 INSERT
SELECT COUNT(*) FROM qa49 a, qa49 b, qa49 c, qa49 d, qa49 e;
```

훈련은 위 쿼리 3회. 측정 세션 하나는 server start -> csql(`;time on`, `SET TRACE OFF;`) 쿼리 2회 -> server stop이고, 세션당 2개 sample이 나온다. 변형당 8세션 = 16 sample을 세션 단위로 번갈아 실행(interleave)해 호스트 부하 드리프트가 양쪽에 같게 걸리게 했고, server와 csql 두 프로세스를 같은 socket의 물리 core에 고정(pinning)해 cross-socket 메모리 접근 편차를 없앴다.

### 결과: 질의 시간

| 변형 | n | median | mean | stdev | min | max |
|------|---|--------|------|-------|-----|-----|
| baseline | 16 | 38.927s | 39.036s | 0.544 | 38.230 | 39.861 |
| PGO | 16 | 35.447s | 35.320s | 0.723 | 33.373 | 36.268 |

PGO 최악값(36.27s)이 baseline 최선값(38.23s)보다 빨라 두 분포가 겹치지 않는다. 모든 sample의 COUNT 결과는 282,475,249로 정확했다.

> **요지**: 개선 폭이 QA 회귀 폭과 같은 자릿수라는 점은, 이 쿼리의 hot loop가 코드 배치와 front-end 효율에 민감하다는 방증이다(회귀 폭 전부가 layout 때문이라는 뜻은 아니다). PGO는 그 민감 구간을 실측으로 통제한다.

### 결과: CPU pipeline (perf stat, cub_server)

변형당 1세션(쿼리 2회) 측정이며, counter는 server 프로세스 시작부터 종료까지를 덮는다.

| counter | baseline | PGO | 변화 |
|---------|----------|-----|------|
| cycles | 248.21G | 225.20G | -9.3% |
| instructions | 673.00G | 624.24G | -7.2% |
| IPC (cycle당 처리 명령 수) | 2.71 | 2.77 | +2.2% |
| branch-misses | 115.57M (0.08%) | 41.59M (0.03%) | -64.0% |
| L1-icache-load-misses | 223.12M | 124.17M | -44.3% |
| iTLB-load-misses | 2.53M | 1.87M | -26.2% |
| idq.dsb_uops | 283.06G | 220.70G | -22.0% |
| idq.mite_uops | 360.44G | 373.36G | +3.6% |

DSB(µop cache) 공급이 줄고 MITE(legacy decode)가 늘었는데도 빨라졌다. 성능을 가른 것은 공급 경로의 종류가 아니라 일의 총량과 miss율이다. CBRD-26382 보고서가 DSB miss 단독 원인론을 기각한 것과 같은 결론이다.

### 결과: 배치 증거

CBRD-26382에서 hot으로 확인된 query executor 함수들의 시작 주소(`nm`, `libcubrid.so`):

| 함수 | baseline | PGO |
|------|----------|-----|
| qdata_evaluate_aggregate_list | 0x48e9f0 | 0x6092a0 |
| scan_next_scan | 0x4fa600 | 0x609ae0 |
| qexec_execute_query | 0x4d93e0 | 0x63e990 |
| qexec_execute_mainblock | 0x4cbbd0 | 0x63ec50 |
| scan_next_scan_block | 0x4f9690 | 0x642c20 |

baseline에서는 5개 함수가 링크 순서대로 약 441KB 구간에 흩어져 있고, PGO에서는 실측 hotness 기준으로 인접 재배치돼 구간이 약 236KB로 줄었다(aggregate_list와 scan_next_scan이 2KB 간격, execute_query와 execute_mainblock이 0.7KB 간격). `qexec_execute_query`, `scan_next_scan_block`에는 `.cold` clone이 새로 분리됐고, 실행되지 않은 코드가 크기 위주로 최적화되면서 `.text` 전체가 8.67MB에서 7.09MB로 18.2% 줄었다. hot working set 축소는 위 표의 L1I/iTLB miss 감소로 나타났다.

### 빌드에서 확인된 도입 비용

| 관찰 | 내용 |
|------|------|
| -Werror 실패 1건 | `-fprofile-use`가 바꾼 inlining 때문에 `src/broker/cas_cgw_odbc.c`에서 `-Wstringop-overflow=` 경고가 새로 발생해 빌드가 실패했다. PoC에서는 `-Wno-error=stringop-overflow=`로 우회했으나, 도입 시 해당 경고의 근본 수정이 선행돼야 한다 |
| 훈련 비용 | instrumented 실행이 baseline의 약 6.6배 (훈련 시점 단발 측정 기준 39.4s -> 약 258s/query). 상시 옵션이 아니라 훈련 전용 빌드가 필요하고, CI에 훈련 시간 예산이 필요하다 |
| 빌드 시간 | 파이프라인이 full rebuild 2회를 요구한다 (PoC 기준 instrumented full rebuild 약 7분/80코어, ccache 비활성) |
| profile 수명 | 소스가 바뀌면 profile이 낡는다(coverage mismatch). 갱신 주기 없이 방치하면 이득이 줄거나 역효과가 난다 |
| 재현성 | PGO 빌드는 profile 입력에 의존하므로, 빌드 재현성이 필요하면 `.gcda`(이번 PoC 기준 955개, 9.0MB)를 버전 관리되는 빌드 아티팩트로 고정해야 한다 |
| 디버깅 영향 | hot/cold 분리로 `.cold` clone이 생기고 inlining 구조가 달라져, release 바이너리의 core 덤프·gdb 분석 시 스택 해석이 지금과 달라진다 |
| 롤백 정책 | PGO 변형이 QA 후반에 실패할 경우 non-PGO 빌드로 release를 내는 절차가 필요하다 |

### 장기 후보 비교

| 순위 | 후보 | 권장 이유 / 고려사항 |
|------|------|---------------------|
| 1 | instrumentation PGO (본 이슈) | 이번 PoC로 파이프라인 검증 완료. 훈련 빌드와 훈련 시간이 필요 |
| 2 | AutoFDO | production 유사 환경에서 perf sampling으로 profile 수집 — 훈련 전용 빌드 불필요, 오버헤드 낮음. sample의 symbolization(build-id, ASLR 보정) 재현이 선행 과제 |
| 3 | BOLT | 링크 후 바이너리를 profile로 재배치하는 post-link optimizer. `-freorder-blocks-and-partition`과 비호환이고 shared object 지원이 최근 기능이라 별도 prototype 검증 후에만 고려 |

세 후보의 제약과 근거 문서는 [CBRD-26382 hot-function-alignment-options](https://github.com/vimkim/my-cubrid-docs/blob/c07802c210e19fd65c5085cb64cdf2b73cd413c6/cbrd-26382/CBRD-26382-hot-function-alignment-options_codex.md) 4장에 정리돼 있다.

### 이번 PoC의 한계

- 훈련 workload = 측정 workload인 best case다. 훈련에 없는 경로는 cold로 취급돼 오히려 느려질 수 있으며, `-fprofile-partial-training`(GCC 10+, 훈련되지 않은 코드를 크기 최적화 대신 일반 최적화로 두는 옵션)이 이 trade-off를 조절한다. 대표 훈련 suite 후보로는 QA sql/medium 부분집합 + OLTP mix를 검토할 수 있다.
- 훈련이 `cub_server` 경로만 덮었다. broker/CAS, utility, HA 코드는 profile이 비어 크기 위주로 최적화됐고, 이 PoC는 그 경로의 성능을 측정하지 않았다. 유일한 빌드 실패도 그 미훈련 영역(`src/broker/cas_cgw_odbc.c`)에서 나왔다.
- 공유 호스트 측정이다. interleave와 pinning으로 완화했지만 전용 호스트 재확인이 필요하다.
- GCC 11 단일 축이다. GCC 8, 최신 GCC/Clang 축은 미측정이다.
- develop의 이 빌드 구성에는 등록된 ctest가 없어 단위 테스트 게이트는 실행하지 못했다. DDL/DML/index/join smoke와 전 sample 결과값 정합만 확인했다.

## Acceptance Criteria

- [ ] 전용 호스트, 독립 rebuild 2회 이상에서 PGO 개선 폭 재확인 (매 rebuild에서 median 개선 5% 이상, Mann-Whitney p < 0.01)
- [ ] 대표 훈련 suite 정의 및 `-fprofile-partial-training` on/off 비교 결과 문서화
- [ ] 훈련에 포함되지 않은 workload(예: OLTP mix, DDL, utility, broker 경유 질의)에서 회귀 없음 확인
- [ ] `cas_cgw_odbc.c` stringop-overflow 경고를 포함한 PGO 유발 경고의 근본 수정
- [ ] PGO 변형에 대한 기능 QA(sql/medium/shell) 통과

## Definition of done

- [ ] 위 A/C 충족
- [ ] 2-pass 빌드 절차와 profile 관리 정책 문서화
- [ ] 공식 release 적용 여부 결정 기록

## Remarks

- PoC 구현 draft PR: [CUBRID/cubrid#7823](https://github.com/CUBRID/cubrid/pull/7823) (branch `CBRD-27335-pgo-build`, `-DPGO` 옵션)
- 발단: [CBRD-26382](http://jira.cubrid.org/browse/CBRD-26382) 및 [comment 4776011](http://jira.cubrid.org/browse/CBRD-26382?focusedCommentId=4776011&page=com.atlassian.jira.plugin.system.issuetabpanels:comment-tabpanel#comment-4776011)
- 실험 전체 보고서: [CBRD-26382-pgo-experiment_95b79e7ed_claude.md](https://github.com/vimkim/my-cubrid-docs/blob/c07802c210e19fd65c5085cb64cdf2b73cd413c6/cbrd-26382/CBRD-26382-pgo-experiment_95b79e7ed_claude.md)
- 재현 harness / 원시 데이터: [artifacts/pgo-gcc11](https://github.com/vimkim/my-cubrid-docs/tree/c07802c210e19fd65c5085cb64cdf2b73cd413c6/cbrd-26382/artifacts/pgo-gcc11) (timing CSV, perf stat 원문, 측정 스크립트)
