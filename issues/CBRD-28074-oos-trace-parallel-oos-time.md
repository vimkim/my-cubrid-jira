# [OOS] 병렬 heap scan의 SQL trace에서 oos time이 scan time보다 크게 표시될 수 있는 문제를 확인한다

**한 줄 요약**: [PR #8491 코드 리뷰](https://github.com/CUBRID/cubrid/pull/8491#issuecomment-6819078503)에서 `gather: row by row` 병렬 heap scan의 `oos time` 이 scan의 `time` 보다 크게 표시될 수 있다는 구조적 위험(R-1)이 나와, 실제 발생 여부와 표시 방식을 후속 작업으로 확인한다.

## Issue Triage

**이슈 수행 목적**: 병렬 heap scan의 SQL trace에서도 OOS 읽기 시간이 scan 시간의 일부라는 의미가 지켜지거나, 지켜지지 않는 경우의 의미가 명확해진다.

**이슈 수행 이유**: [CBRD-28011](https://jira.cubrid.org/browse/CBRD-28011)의 PR #8491은 scan의 `fetch`, `ioread`, `time` 중 OOS 값 읽기에 쓴 몫을 `(oos time, fetch, ioread)` 로 함께 표시한다. 병렬 scan에서 `oos time` 은 worker 중 가장 긴 OOS 읽기 시간이고, scan의 `time` 은 leader가 scan 안에 머문 시간이다. 두 값의 기준 스레드가 달라, `row by row` gather에서는 `oos time` 이 scan `time` 을 넘는 것을 막는 구조가 없다.

**영향**: 쿼리를 튜닝하는 사용자가 trace에서 OOS 읽기 시간이 scan 전체 시간보다 큰 값을 보고 수치를 잘못 해석할 수 있다. trace 표시 문제이며 쿼리 결과, OOS `fetch`, `ioread` 에는 영향이 없다. 4번의 재현 시도에서 발생하지 않아 실제 발생 빈도는 확인되지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

SQL trace는 scan마다 읽은 페이지 수(`fetch`), 디스크 읽기 수(`ioread`), 걸린 시간(`time`)을 보여 준다. PR #8491은 OOS(큰 컬럼 값을 heap 행 밖의 별도 파일에 저장하는 방식) 값을 읽는 데 쓴 몫을 scan 줄 끝에 따로 표시하며, 이 값은 scan 합계에 포함된 일부로 설명된다.

병렬 heap scan에서 집계 방식은 다음과 같다.

- `trace_handler::merge_stats` 는 worker들의 OOS `fetch` 와 `ioread` 는 합산하고, OOS 시간은 가장 긴 worker의 값을 scan의 `oos time` 에 더한다([`px_scan_trace_handler.cpp:134`](https://github.com/CUBRID/cubrid/blob/a4fec6f8e26a36834c3dde4df0ed0af5ecc6d914/src/query/parallel/px_scan/px_scan_trace_handler.cpp#L134)). partition 경로도 같은 방식이다(같은 파일 216, 252, 288행).
- scan의 `time` 은 leader가 자신의 scan 구간 안에 머문 시간이다.
- `mergeable list` 와 `buildvalue` gather에서는 leader가 모든 worker가 끝날 때까지 scan 구간 안에서 기다리므로 `oos time` 이 scan `time` 을 넘지 않는다.
- `row by row` gather(`XASL_SNAPSHOT`)에서는 worker가 각자의 list file에 행을 미리 써 두고, leader는 준비된 행이 없을 때만 기다린다. leader가 scan 구간 밖에서 오래 일하는 동안 worker가 일찍 끝나면, leader의 scan 구간 시간이 가장 긴 worker의 OOS 읽기 시간보다 작을 수 있다.
- index scan은 `row by row` gather를 쓰지 않으므로 해당하지 않는다.

이 위험은 PR #8491 head `a4fec6f8e2` 리뷰에서 두 리뷰어가 독립적으로 소스만 보고 찾았다. 재현 시도 4번(행마다 leader에서 실행되는 PL/CSQL 함수로 `row by row` gather를 강제)에서 모두 `oos time` 이 scan `time` 이하였다. 가장 느린 시도에서도 leader의 scan 구간 안 list 읽기 시간(379 ms)이 worker 전체 실행 시간(82..119 ms)보다 컸다. 발생하려면 worker의 OOS 읽기 시간이 leader의 list 읽기 시간보다 커야 하며, 행마다 OOS chunk가 많고 출력 행은 작은 경우가 유력한 조건으로 추정된다. 이 조건은 아직 실행해 보지 않았다. 상세 근거는 [PR #8491 리뷰 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-28011/code-review.md)의 R-1에 있다.

[OOS TODO CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978)의 하위 작업으로 추적한다. PR #8491 병합을 막는 조건이 아니다.

## Analysis

- 다음 조건으로 `oos time` 이 scan `time` 을 넘는지 확인한다: 병렬 scan 대상이 되는 테이블, 행마다 약 200 KB의 OOS 값, select list에 `PARALLEL_ENABLE` 이 아닌 stored function. scan 줄의 `oos time` 과 `heap time` 을 비교한다.
- 병렬 scan에서 `oos time` 이 무엇을 뜻해야 하는지 정한다. 리뷰에서 나온 후보는 세 가지다.
  - scan 수준 `oos time` 을 scan `time` 이하로 자르는 방식. 표시는 일관되지만 worker의 실제 OOS 읽기 시간을 숨긴다.
  - worker 기준 OOS 시간을 `parallel workers` 줄에 범위로 표시하는 방식. 기준 스레드가 맞지만 출력 형식과 TC 정답이 바뀐다.
  - 병렬 scan의 `oos time` 은 가장 긴 worker의 시간이라고 문서에 밝히는 방식. 코드 변경이 없지만 "scan 합계의 일부"라는 설명과 어긋나는 경우가 남는다.

## Acceptance criteria

- `row by row` 병렬 heap scan에서 `oos time` 이 scan `time` 을 넘는지 재현 결과나 근거로 결론을 낸다.
- 병렬 scan에서 `oos time` 이 나타내는 의미가 trace 출력이나 문서에서 scan `time` 과의 관계와 함께 설명된다.
- 표시 방식을 바꾼다면 직렬 scan과 `mergeable list`, `buildvalue` gather의 기존 출력과 OOS `fetch`, `ioread` 합산은 바뀌지 않는다.
