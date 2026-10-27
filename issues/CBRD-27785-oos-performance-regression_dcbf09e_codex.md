# [OOS] 일반 테이블과 OOS 사용 워크로드의 성능 회귀 조사 및 개선

## Issue Triage

**이슈 수행 목적**: OOS 통합 전후의 성능 차이를 반복 가능한 벤치마크로 확인하고, 확인된 회귀의 원인과 개선 범위를 결정한다. 먼저 OOS 값을 갖지 않는 일반 테이블의 스캔 CPU 비용 증가를 조사한다.

**이슈 수행 이유**: PR #7990 리뷰에서 일반 테이블의 스캔 instructions 8~10% 증가, OOS 행의 작은 컬럼 UPDATE 72% 증가, 큰 OOS 값을 읽는 스캔의 instructions 40% 증가와 경과 시간 2.5배가 보고되었다. 일반 테이블도 영향을 받는다는 보고이므로 OOS를 사용하는 특정 쿼리만의 비용으로 볼 수 없다. 이 수치는 리뷰어의 측정이며 본 이슈 담당자의 독립 재현 결과와 구분한다.

**영향**: 기존 일반 테이블을 조회하는 사용자와 큰 가변 컬럼을 읽거나 갱신하는 사용자가 CPU 비용 또는 응답 시간 증가를 겪을 수 있다. 운영 환경의 발생 빈도와 크기는 확인되지 않았다. 변경 없는 OOS 값의 UPDATE 재적재는 기존 CBRD-27230과 연결하고, 중복 구현하지 않는다.

**이슈 수행 방안**: 재현과 원인 분석 후 수정 범위, 성능 판정 기준, spec과 구현 티켓을 확정한다. 구체적인 최적화와 OOS 비활성화 설정은 ANALYSIS 단계에서 결정한다.

---

## AI-Generated Context

> 아래는 제공된 리뷰와 확인한 작업 상태를 바탕으로 작성한 맥락이다. 보고된 측정값, 독립 재현 결과, 미확인 원인을 구분한다.

## Description

### 무엇이 문제인가

OOS는 큰 가변 값을 행 밖에 저장하여 작은 컬럼만 읽는 쿼리의 읽기 비용을 줄이는 기능이다. PR #7990은 이를 develop에 통합하는 변경이다. 리뷰어 shparkcubrid는 2026-10-27에 OOS를 사용하지 않는 작은 행에서도 통합 전보다 스캔 비용이 증가한다고 보고했다.

리뷰어는 `4408135c0833ec959da3590f12c14efa69610c7e`와 merge-base `4781495f01523a3ecc5891e3377ad62cf876a1cd`를 같은 호스트에서 release로 빌드했다. 같은 설정에서 서버를 하나씩 실행했고, 2라운드에 라운드당 5회 측정하여 첫 회를 버렸다. 공유 호스트의 경과 시간 변동 때문에 cub_server의 user-space instructions를 주 판정 지표로 사용했다. `data_buffer_size=4G`이며 데이터가 모두 메모리에 들어가는 조건이었다.

| 워크로드 | w: 6KB 값, 2만 행, OOS | m: 2.5KB 값, 2만 행 | n: 약 100B 행, 20만 행 |
| --- | --- | --- | --- |
| 적재 | +1% | +0% | +3% |
| 좁은 컬럼 전체 스캔 | -23% | +6% | +8% |
| 큰 컬럼을 읽는 전체 스캔 | +40%, 경과 시간 2.5배 | +9% | +10% |
| PK 점조회 3,000건 | +2% | +1% | +0% |
| 작은 컬럼 UPDATE, 전체 행 | +72% | +3% | +7% |
| 큰 컬럼 UPDATE, 5,000행 | +34% | +17% | 해당 없음 |

표는 리뷰어의 결과를 옮긴 것이며 독립 재현 결과가 아니다. 원본 DDL, SQL, 측정 스크립트와 전체 설정은 댓글에 없다. 사용자는 보고된 조건을 바탕으로 가능한 한 유사한 하네스를 재구성하도록 지시했다. 따라서 동일한 비율의 재측정을 보장하거나 원본 하네스를 실행했다고 표현하지 않는다.

리뷰어는 일반 테이블의 속성 디코드 비용, 변경 없는 OOS 값의 UPDATE 재적재, 큰 값 스캔의 지연 원인을 확인해 달라고 요청했다. OOS 비활성화 수단과 buffer보다 큰 데이터에서의 이득 검증도 요청했다. 속성 디코드와 스캔 병렬성에 대한 설명은 검증할 가설이며 현재 이슈에서 확인한 원인이 아니다.

### 왜 문제인가

사용자는 기존 일반 테이블의 쿼리가 OOS 통합 후에도 비슷한 CPU 비용으로 실행되기를 기대한다. OOS 값을 갖지 않는 행의 스캔까지 비싸지면, 큰 컬럼을 행 밖으로 옮기는 이득을 얻지 못하는 워크로드에서도 서버 처리 자원을 더 사용한다. 고정된 CPU 자원에서 처리량이나 여유 용량이 줄 수 있지만, 이 보고만으로 운영 처리량 감소율을 단정할 수는 없다.

큰 컬럼을 가진 행에서 상태 값 하나를 갱신하는 경우에는, 변경하지 않은 값까지 다시 저장하면 쓰기·로그·vacuum 작업이 늘어날 수 있다. 이 문제는 CBRD-27230의 기존 범위다. 재사용을 단순히 추가하면 되는지와 정리·복구·복제까지 필요한 변경은 기존 설계와 현재 구현을 대조하여 판단해야 한다.

큰 값 스캔에서 instructions와 경과 시간의 증가율이 다른 것만으로 대기, 병렬성 또는 페이지 고정 중 하나를 원인으로 확정할 수 없다. 호스트 간섭, CPU cycles, 실행 계획과 buffer 상태를 함께 확인해야 한다.

### 왜 해결해야 하는가

부모 이슈 CBRD-26835의 OOS 통합 판단에는 이득과 비용을 비교할 근거가 필요하다. 일반 테이블의 회귀를 재현하고 최소화하면 개선할 공통 경로와 회귀 테스트 범위를 정할 수 있다. 이후 OOS 사용 워크로드의 비용과 메모리 밖 데이터에서의 이득을 같은 하네스로 평가할 수 있다.

비활성화 설정 추가와 최적화는 서로 다른 결정을 요구한다. 우선 설정을 추가하는 것으로 회귀 원인 조사를 대체하지 않으며, 재현 없이 특정 함수 수정이나 최종 성능 기준을 확정하지 않는다. 긴급도와 최종 머지 조건은 측정 결과를 보고 결정한다.

## Investigation Scope

1. 약 100B 일반 행 20만 개의 좁은 컬럼 및 여러 컬럼 스캔 CPU 회귀를 먼저 재현한다.
2. 보고 당시 두 커밋과 현재 `feature/oos-merge`의 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`를 비교한다.
3. 재현한 차이를 최소화하고 원인을 통제 실험으로 확인한다.
4. 큰 OOS 값의 스캔과 buffer보다 큰 데이터의 이득을 후속 측정 범위로 구체화한다.
5. UPDATE 재사용은 CBRD-27230, rollback 및 vacuum 안전성은 CBRD-27237 등 관련 이슈와 연결하여 중복과 의존성을 확인한다.
6. OOS 비활성화·임계값 설정은 별도 정책 결정이 필요한 항목으로 남긴다.

## Reproduction

재구성 하네스는 엔진 작업 브랜치의 `contrib/benchmarks/oos-performance/`에 준비한다. `n` 테이블은 정수 두 개와 80바이트 가변 컬럼으로 구성한다. 좁은 스캔은 인덱스가 없는 정수 컬럼을 집계하고, 여러 컬럼 스캔은 두 정수와 가변 컬럼 길이를 집계한다. 매 실행의 결과와 문장 수를 확인한다.

각 빌드에서 새 DB를 독립 생성하고 release compiler 설정과 주요 서버 설정을 맞춘다. 서버 한 개씩 측정하며 query result cache를 끈다. 각 라운드·쿼리의 첫 실행을 버리고 서버 instructions와 cycles, 경과 시간을 보존한다. 실행 계획과 warm scan의 I/O는 별도의 trace로 확인한다.

재현 검출용 임시 기준은 instructions 증가 5%, 유지 표본의 범위 2% 이내다. 이 기준은 보고된 8~10% 증상을 검출하기 위한 것이며 최종 개선 완료 기준으로 합의한 값이 아니다. 불완전한 실행이나 사용할 수 없는 counter는 통과로 판정하지 않는다.

## Independent Evidence

2026-10-27 dev2에서 다음 결과를 얻었다. 아래 수치는 재구성한 일반 테이블 하네스의 독립 측정이며, 리뷰어의 원본 SQL을 재실행한 결과가 아니다.

| 비교 | 실행 순서 | 좁은 컬럼 instructions 증가 | 여러 컬럼 instructions 증가 |
| --- | --- | --- | --- |
| 보고 당시 head / 기준 | base, report, current | +5.1273% | +8.8904% |
| 현재 head / 기준 | base, report, current | +5.1249% | +8.8904% |
| 보고 당시 head / 기준 | current, report, base | +5.1275% | +8.8878% |
| 현재 head / 기준 | current, report, base | +5.1270% | +8.8870% |
| 현재 head / 기준, 실행당 스캔 1회 | base, report, current | +5.1152% | +8.8770% |

20회 스캔 조건에서 유지한 표본의 instructions 범위는 모든 빌드와 쿼리에서 중앙값의 0.01% 미만이었다. 모든 실행의 집계값과 문장 수가 일치했다. 세 빌드 모두 TABLE SCAN, 병렬 worker 4개, heap fetch 1,654회와 200,000행을 보였다. 여러 컬럼 스캔의 trace에서 I/O read는 0이었다. 좁은 스캔은 그보다 먼저 페이지를 읽고, 별도의 버리는 실행도 수행했다. 실행 순서와 스캔 반복 횟수를 바꾸어도 같은 방향의 차이가 유지되었다.

좁은 스캔의 현재 head 중앙값은 실행당 약 72.2035억 instructions, 기준은 약 68.6835억이었다. 여러 컬럼 스캔은 각각 약 140.7207억과 129.2315억이었다. 각 실행은 200,000행을 20회 스캔했다. 경과 시간은 주 판정 지표로 사용하지 않았다.

### 빌드와 설정

- OS: Linux x86_64, GCC 11.5.0, RelWithDebInfo, `-O2 -ggdb3 -DNDEBUG -finline-functions`. 세 빌드의 compiler 및 최적화 cache 설정이 일치한다.
- commit과 설치 파일 hash는 `builds.json`에 보존했다. 비교한 엔진은 앞의 세 full SHA다. 측정 중 엔진 소스를 수정하지 않았다.
- 각 빌드에서 새 DB `oos27785`를 독립 생성했다. 설치, registry, master port, TMP를 분리했고 benchmark 서버를 직렬 실행했다.
- `data_buffer_size=4G`, `log_buffer_size=16M`, `max_clients=20`, `max_query_cache_entries=0`, `query_cache_size_in_pages=0`. 독립 할당된 master port를 제외한 설정이 일치한다.
- 서버는 같은 NUMA node의 서로 다른 physical core 16~19, 측정 CSQL은 core 12에 배치했다. CPU 배치는 전용 자원 예약이 아니며 다른 사용자의 작업은 중단하지 않았다.
- primary counter는 서버 프로세스의 `instructions:u`다. `cycles:u`, task-clock, 경과 시간도 저장했다. hardware event running 비율은 100%였다.

### 실행 명령과 근거

다음 명령을 실제로 실행했고 각각 종료 코드 1, 즉 재현 검출 결과를 얻었다.

```sh
python3 /mnt/nvme/data-5/tmp/CBRD-27785-20261027/reproduce.py --name forward
python3 /mnt/nvme/data-5/tmp/CBRD-27785-20261027/reproduce.py --name reverse --order current report base
python3 /mnt/nvme/data-5/tmp/CBRD-27785-20261027/reproduce.py --name minimal --scans 1 --rounds 2 --runs 5
```

같은 이름의 결과 디렉터리가 있으면 보존하고 거부한다. 재실행은 새로운 `--name`을 사용한다. 이 호스트용 launcher는 미리 만든 세 작업 환경을 선택하고 각 서버를 시작·측정·중단한다. 다른 호스트에서는 하네스 README에 따라 독립 DB와 native 환경을 먼저 준비한다. 하네스는 CSQL과 perf만 사용하며 DB를 삭제하지 않는다.

raw artifact root: `/mnt/nvme/data-5/tmp/CBRD-27785-20261027`. SQL, 원시 counter, stdout/stderr, 검증 결과, script, server identity, 설정, build hash를 보존했다. 측정 후 작업 소유 서버와 master를 중단했고 DB 및 로그는 남겼다.

- [첫 비교: 현재 head](https://dev2.baboon-rudd.ts.net:8443/mnt/nvme/data-5/tmp/CBRD-27785-20261027/forward-base-vs-current.json)
- [역순 비교: 현재 head](https://dev2.baboon-rudd.ts.net:8443/mnt/nvme/data-5/tmp/CBRD-27785-20261027/reverse-base-vs-current.json)
- [실행당 1회 스캔 비교](https://dev2.baboon-rudd.ts.net:8443/mnt/nvme/data-5/tmp/CBRD-27785-20261027/minimal-base-vs-current.json)

### 원인 분석의 현재 경계

추가 CPU 비용이 속성 디코드 경로에 있다는 가설을 우선 검토한다. 별도 cycles sampling에서 기준에 없던 `heap_recdes_get_var_offset_entry`, `heap_attrvalue_point_variable`, 분리된 `heap_attrvalue_transform_to_dbvalue` 등의 비용이 관찰되었다. 그러나 sampling 비중은 instructions 증가량과 동일한 지표가 아니며, 그 비중만으로 원인을 확정하지 않는다.

현재 소스에는 이미 `HEAP_REC_LAYOUT`을 행당 한 번 만드는 구조와 HAS_OOS 검사에 따른 분기가 있다. 다만 HAS_OOS가 없는 경우에도 OOS 대응 `heap_attrvalue_read`를 호출하며, 이 함수는 고정 속성 읽기에서도 OOS scratch를 포함한 큰 stack frame을 갖는다. 실제 release assembly의 stack 예약은 기준 `0x58`바이트, 현재 `0x4088`바이트였다. 이는 heap allocation이나 16KB 전체 초기화를 의미하지 않는다. 가변 속성의 offset entry helper는 header 검증과 offset 정보를 다시 조회한다.

따라서 기존에 있는 layout cache를 새로 추가하는 방식으로 문제를 설명하지 않는다. 다음 두 진단용 통제 실험을 실제로 수행했다.

| 경로 | 좁은 컬럼 / 기준 | 여러 컬럼 / 기준 |
| --- | --- | --- |
| 수정 전 feature | +5.12% | +8.89% |
| 비 OOS 행에서 기준의 속성 reader를 사용, 기존 OOS prefetch 분기 유지 | +4.43% | +2.76% |
| 비 OOS 행에서 기준의 행별 loop와 속성 reader를 직접 사용 | +1.81% | +0.96% |

두 번째 실험은 첫 실험에 비해 행별 prefetch/dispatch 호출 경로를 우회한다. 원래 SQL과 입력의 결과·문장 수는 계속 일치했고 instructions 표본도 안정적이었다. 비 OOS 읽기의 OOS 대응 행 분기 및 속성 reader 비용이 관찰한 회귀의 주요 부분을 설명한다. 다만 개별 함수, scratch 크기, inlining과 코드 배치 각각의 기여분을 이 두 실험만으로 분해하지 않는다.

실험은 기준 reader를 복사한 진단용 코드다. malformed 입력, 모든 type·schema 표현, OOS/pending·MVCC 경로를 검증한 제품 패치가 아니다. 패치와 소스·설치 파일 hash를 artifact root에 보존하고, 실험 후 원래 소스로 복원하여 다시 빌드·설치했다. 복원 후 1회 스캔 비교에서 증가분이 +5.14% / +8.90%로 돌아온 것도 확인했다. 진단용 코드는 작업 브랜치와 설치에 남아 있지 않다. 실제 구현은 중복 코드를 그대로 채택하지 않고 기존 검증·소유권 계약을 보존해야 한다. 제품용 성능 개선과 정확성 검증은 아직 완료하지 않았다.

- [직접 inline 읽기 통제 실험](https://dev2.baboon-rudd.ts.net:8443/mnt/nvme/data-5/tmp/CBRD-27785-20261027/diagnostic-outer-vs-base.json)
- 진단 패치: `diagnostic-inline-reader.patch`, `diagnostic-outer-inline.patch`.
- 소스·설치 파일 fingerprint: `diagnostic-source.json`, `diagnostic-outer-source.json`.

## First Implementation Spec

사용자는 첫 구현 범위를 일반 테이블 읽기 경로 회귀와 SQL 기반 성능·정확성 검증으로 승인했다. 원인 분석 결과를 반영한 첫 spec은 엔진 작업 checkout의 `.scratch/oos-performance/spec.md`이며, 고정 컬럼 읽기와 가변 컬럼 읽기를 순서대로 완성하는 두 티켓을 검토한다. 각 티켓에 정확성 검사와 성능 검증을 포함한다. 최종 instructions 증가 2% 이하를 제안하며 티켓 분할과 함께 검토한다.

CBRD-27230의 UPDATE 재사용, OOS 설정과 대용량 I/O 검증은 후속 범위로 남긴다. 티켓 분할 승인 전에는 구현 티켓 발행이나 implement-spec을 시작하지 않는다.

## Acceptance Criteria

- [x] 한 명령으로 동일한 입력과 쿼리의 일반 테이블 스캔 차이를 반복 측정할 수 있다.
- [x] 보고 당시 head, merge-base, 현재 head의 비교 결과와 정확성 검사 결과가 보존된다.
- [x] 재현 여부, 원인 확인 여부, 호스트 간섭과 측정 한계가 구분된다.
- [x] 재현한 회귀의 원인과 수정 범위 또는 다음 분석에 필요한 근거가 기록된다.
- [ ] 최종 성능 기준과 정확성 검증 범위를 합의한 후 spec과 의존성을 가진 구현 티켓을 작성한다.

## Definition of done

재현·분석 근거, 수정 범위와 측정 판정 기준을 검토하고, 승인된 구현 범위의 개선 및 회귀 검증을 완료한다. 일반 테이블 스캔만의 개선을 OOS UPDATE, HA, 복구 또는 전체 성능 검증 완료로 확대 해석하지 않는다.

## Triage Request

기존 담당자 측에서 이 성능 회귀 보고의 재현과 ANALYSIS를 진행한다. 우선 일반 테이블의 스캔 CPU 비용 차이를 확인하고, 확인된 원인·수정 범위·검증 기준을 검토한다. 기존 이슈의 유형, 우선순위, 담당자와 상태는 이 문서 작성으로 변경하지 않는다.

## References

- [PR #7990 성능 비교 댓글](https://github.com/CUBRID/cubrid/pull/7990#issuecomment-6434778190)
- [CBRD-27785](http://jira.cubrid.org/browse/CBRD-27785), 부모 [CBRD-26835](http://jira.cubrid.org/browse/CBRD-26835)
- [CBRD-27230: 변경 없는 OOS 값 중복 적재 방지](http://jira.cubrid.org/browse/CBRD-27230)
- [CBRD-27237: rollback 및 vacuum 정리 문제](http://jira.cubrid.org/browse/CBRD-27237)
