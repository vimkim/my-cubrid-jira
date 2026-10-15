# [CBRD-27640] 세션 통계 반복 조회 시 페이지 래치 승격 통계가 누적 확대됨

## Issue Triage

**이슈 수행 목적**: 세션 통계를 반복 조회해도 페이지 래치 승격 성공·실패 통계가 실제 작업량에 맞게 유지되도록 한다.

**이슈 수행 이유**: PR #7157 리뷰에서 기존 결함이 보고됐다. 세션 통계 조회가 실시간 통계 배열의 계산 결과를 다시 입력으로 사용해, 추가 작업 없이 조회만 반복해도 승격 통계가 확대된다.

**영향**: CSQL 세션 통계에서 페이지 래치 승격 횟수를 신뢰하기 어려워 성능 분석을 왜곡한다. 같은 계산 경로를 사용하는 다른 기능의 영향 범위는 추가 확인이 필요하다. 데이터 손상은 확인되지 않았다.

**이슈 수행 방안**: CBRD-26500 / PR #7157과 분리해 처리한다. 매 계산 시 승격 결과를 새로 산출하거나 복사본에서 계산하는 방안을 검토한다. 최종 수정 방식은 TBD - 합의 미확인이다. 반복 조회와 성공·실패 통계의 회귀 검증이 필요하다.

---

## AI-Generated Context

> 아래는 AI가 코드와 맥락을 분석해 작성한 상세 자료다.

## Description

페이지 래치 승격은 읽기 래치를 쓰기 래치로 바꾸는 작업이다. 성능 통계는 승격 성공·실패의 세부 카운터를 모아 `Data_page_total_promote_success`와 `Data_page_total_promote_fail`로 제공한다. 원시 카운터가 그대로라면 통계를 다시 조회해도 계산 결과는 같아야 한다.

`perfmon_server_calc_stats()`는 결과 저장 칸인 `PSTAT_PB_PAGE_PROMOTE_SUCCESS`와 `PSTAT_PB_PAGE_PROMOTE_FAILED`를 초기화하지 않는다. 기존 값에 세부 카운터를 `+=`로 더하고, 출력 형식의 배율을 적용하려고 `*= 100`을 수행한다.

세션 통계 조회의 `xperfmon_server_copy_stats()`는 트랜잭션별 실시간 배열을 이 함수에 직접 전달한 뒤 결과를 복사한다. 따라서 다음 조회는 이전 계산 결과가 남은 배열을 다시 계산한다. 원시 승격 합계가 `n`으로 일정해도 내부 계산 값은 다음처럼 커진다.

```text
1회: (0 + n) * 100
2회: ((0 + n) * 100 + n) * 100
3회: (((0 + n) * 100 + n) * 100 + n) * 100
```

두 결과 칸에 동일한 패턴이 있어 성공·실패 통계 모두 수정 검토 대상이다. 리뷰어의 실제 측정 예시는 성공 통계에 해당한다. `xperfmon_server_copy_global_stats()`는 전역 원시 통계를 출력용 배열에 먼저 복사하고 그 복사본을 계산하므로, 같은 실시간 배열을 반복 변경하는 이 원인에서는 제외된다.

이번 세션에서는 PR head의 호출 순서와 누적 연산을 소스로 확인했다. 아래 실행 결과는 리뷰어가 보고한 값이며 독립 실행 재현은 수행하지 않았다.

## Test Build

- 리뷰어 보고 환경: PR #7157 브랜치의 debug 빌드다. 정확한 전체 버전 문자열과 OS는 TBD다.
- 소스 확인 기준: `f3be52d2f74c01cd64b926b91068051b5b750821`이다.

## Repro

테스트 전용 DB를 서버 모드로 시작하고 CSQL 클라이언트/서버 세션에 접속한다. 승격 세부 카운터가 수집되는 환경에서 다음 명령을 같은 세션에 순서대로 실행한다. 같은 이름의 테이블이 없는 DB를 사용한다.

```sh
csql -C -u dba <테스트_DB>
```

```sql
;.hist on
create table tp (id int primary key, v int, index iv (v));
insert into tp
select rownum, rownum % 97
from db_class a, db_class b, db_class c
limit 200000;
delete from tp where id % 3 = 0;
commit;
;.dump_hist
;.dump_hist
;.dump_hist
```

세 번의 조회 사이에는 추가 SQL 작업을 수행하지 않는다. 각 출력의 `Data_page_total_promote_success`, `Data_page_total_promote_fail` 및 `Num_data_page_fetches`를 비교한다. 세부 카운터의 수집 설정과 입력 카운터 유지 여부는 독립 재현 시 함께 기록해야 한다.

## Expected Result

원시 승격 카운터가 같으면 조회 횟수와 관계없이 성공·실패 계산 결과가 같아야 한다. 이미 출력 배율을 적용한 결과가 다음 계산의 입력에 누적되면 안 된다.

## Actual Result

리뷰어가 보고한 연속 조회 결과는 다음과 같다. 같은 동안 `Num_data_page_fetches`는 `9262840`으로 유지됐다. 마지막 출력의 세부 자릿수는 표시 형식의 영향을 받을 수 있으므로 원문 값을 그대로 기록한다.

| 조회 | Data_page_total_promote_success |
|---|---:|
| 1회 | 195940.00 |
| 2회 | 19595940.00 |
| 3회 | 1959595904.00 |

실패 통계의 실측값은 보고되지 않았다. 실패 결과 칸에도 같은 누적·배율 연산이 있음을 소스로 확인했다.

## Additional Information

- 발견 경위와 재현 원문: [PR #7157 리뷰 코멘트](https://github.com/CUBRID/cubrid/pull/7157#discussion_r4266846538)다.
- 관련 이슈: [CBRD-26500](http://jira.cubrid.org/browse/CBRD-26500)이다. 해당 이슈는 hit ratio 등의 부호 없는 정수 뺄셈 언더플로우를 다룬다. 본 결함은 별도로 처리하라는 리뷰 요청에 따라 분리한다. 두 이슈는 `Relates`로 연결한다.
- 수정 검토 시 성공·실패 카운터가 0인 경우와 0이 아닌 경우, 반복 세션 조회, 전역 통계 조회에 대한 회귀 영향을 확인해야 한다.
- 계산 결과의 초기화 또는 지역 합계 변수 사용, 복사 후 계산 중 어떤 방식을 택할지는 추가 분석에서 결정한다.

## Code References

- [세션 배열에서 계산 후 복사하는 경로](https://github.com/CUBRID/cubrid/blob/f3be52d2f74c01cd64b926b91068051b5b750821/src/base/perf_monitor.c#L1031)다.
- [전역 배열을 복사한 뒤 계산하는 경로](https://github.com/CUBRID/cubrid/blob/f3be52d2f74c01cd64b926b91068051b5b750821/src/base/perf_monitor.c#L1050)다.
- [승격 결과 누적 연산](https://github.com/CUBRID/cubrid/blob/f3be52d2f74c01cd64b926b91068051b5b750821/src/base/perf_monitor.c#L1951)과 [출력 배율 적용](https://github.com/CUBRID/cubrid/blob/f3be52d2f74c01cd64b926b91068051b5b750821/src/base/perf_monitor.c#L1987)이다.
