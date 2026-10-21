# [PGBUF] 저활동 구간의 direct victim 예비 배정 경로가 실행되지 않는 오류를 처리한다

## Issue Triage

**이슈 수행 목적**: 일반 공급 경로의 활동이 줄어도 재사용 가능한 페이지 버퍼가 있는 조건에서 direct victim 대기자가 잊히지 않고 진행하도록, 실행되지 않는 예비 배정 경로를 처리한다.

**이슈 수행 이유**: 현재 기준 소스의 유지보수 순회 두 곳은 초기 인덱스와 종료 조건이 모순되어 본문을 실행하지 않는다. 같은 긴급 배정 함수의 다른 호출도 LRU에서 제거한 BCB의 NULL 이웃 포인터를 전달한다. 저활동 또는 무활동 구간의 대기자를 구제한다는 코드의 목적과 실제 동작이 어긋난다.

**영향**: 새 페이지를 올릴 버퍼를 기다리는 서버 스레드는 이 예비 경로의 도움을 받을 수 없다. 다른 공급이 계속 없으면 할당 대기가 길어지고 timeout 처리에 이를 가능성이 있다. 현재 엔진에서 해당 상황을 재현하지 않았으며, 실제 지연·고객 장애·영향 릴리스는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

이 이슈는 [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)의 하위 작업이며, direct victim의 예비 공급 경로를 다룬다. 페이지 버퍼는 디스크 페이지를 메모리에 보관한다. 새 페이지를 올릴 자리가 없으면 재사용할 버퍼 슬롯인 victim을 찾는다. BCB(Buffer Control Block)는 각 슬롯의 fix 수, page latch, dirty 상태 등을 담는 제어 정보다. fix/unfix는 페이지 사용과 상주 관리를 위한 회계이며, page latch는 메모리 안의 페이지 접근을 조정한다.

`pgbuf_allocate_bcb`는 invalid 목록과 LRU(최근 사용 이력에 따른 교체 목록)에서 슬롯을 찾지 못하면, flush 데몬을 사용할 수 있는 서버 모드에서 대기 큐에 등록한다. 다른 경로가 BCB를 직접 배정하고 깨우는 방식이 direct victim이다. 대기자는 flush 데몬을 깨운 뒤 기다리며, flush 완료 BCB를 배정하는 경로 외에 unfix나 LRU 조정 중의 배정 경로도 있다. 따라서 이번 결함을 direct victim 전체가 동작하지 않는 문제로 확대할 수 없다. [할당과 대기 등록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8168-L8271), [flush 완료 배정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L15446-L15506), [unfix 배정 예](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L6775-L6788), [LRU 조정 중 배정 예](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10030-L10049).

`pgbuf_direct_victims_maintenance`의 주석은 시스템 활동이 적거나 없어 BCB가 대기자에게 공급되지 않는 상황을 위한 예비 계획이라고 설명한다. `pgbuf-maintain` 데몬은 100ms 주기로 구성되어 있으며, flush 데몬을 사용할 수 있는 상태에서 quota 조정 후 이 함수를 호출한다. 그러나 다음 두 경로 모두 긴급 배정을 수행할 수 없다. [예비 경로의 목적과 순회](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9561-L9602), [데몬 실행 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16974-L16990), [100ms 구성](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L17126-L17142).

| 경로 | 소스에서 확인한 제어 흐름 | 확인되는 결과 |
|---|---|---|
| 유지보수 함수의 private/shared 순회 | 각각 `index = prv_index`, `index = shr_index`로 시작하고 첫 조건에서 각각 `index != prv_index`, `index != shr_index`를 요구한다. | 대기자와 배정 예산이 있어도 본문은 0회다. 증감식도 실행되지 않아 다음 시작 인덱스가 그대로다. |
| 일반 LRU victim 탐색 중의 긴급 배정 호출 | `pgbuf_remove_from_lru_list`가 `prev_BCB`를 NULL로 지운 뒤, 호출자가 그 값을 긴급 배정의 시작점으로 전달한다. | 해당 호출에 도달해도 긴급 배정 함수는 NULL 검사에서 0을 반환한다. |

첫 행의 근거는 [두 순회의 초기화와 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9578-L9599)이다. 앞쪽 대기자 검사 함수는 큐가 비었는지만 확인한다. 이 검사가 참이어도 인덱스 비교는 거짓이다. 둘째 행은 [제거 후 호출](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9403-L9417), [이웃 포인터 초기화](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10346-L10366), [NULL 시작점 검사](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9503-L9516)로 확인한다. [대기자 존재 검사](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L15604-L15614)도 함께 확인했다.

### 왜 문제인가

저활동 구간에서는 unfix, LRU 조정, flush 완료처럼 다른 배정 계기를 만드는 작업도 줄어들 수 있다. 그때 일반 공급자가 대기자를 구제하지 못하면 이 예비 순회가 맡도록 적혀 있는 역할이 필요하지만, 현재는 victim 후보가 남아 있어도 이 경로에서 후보를 검사하거나 배정하지 못한다. 이는 단순한 통계나 주석 문제가 아니라, 대기자의 진행을 돕는 별도 공급 계기가 빠진 상태다. 다만 실제 부하에서 다른 경로가 모두 공급하지 못하면서 사용 가능한 후보는 남는 실행 순서는 아직 확인하지 않았다. [할당 경로의 저활동 대기 우려](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8173-L8187), [예비 배정의 후보 검사](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9521-L9556).

할당 대기는 `page_latch_timeout_in_msecs`에서 읽은 값을 사용한다. 기준 소스의 기본값은 300,000ms다. 다른 배정이나 중단 없이 이 대기가 실제로 만료되면 timeout 오류를 설정하는 경로가 있고, assert가 활성인 빌드는 그 처리 앞에서 `assert (r != ER_CSS_PTHREAD_COND_TIMEDOUT)`에 걸린다. 이는 조건부 소스 경로이며, 이번 조사에서 5분 대기나 서버 중단을 재현한 결과가 아니다. 이 설정을 함께 쓴다는 이유로 direct victim 할당 대기를 transaction lock 대기와 동일시하지 않는다. [설정 읽기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L1646-L1649), [기본값](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L5414-L5425), [대기 기한 생성](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8211-L8218), [timeout 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8302-L8314).

`Num_victim_assign_direct_panic`의 증가 지점은 이 긴급 배정 함수 안에만 있다. 확인한 호출 관계에서는 그 지점에 도달하지 못한다. 그러나 이 카운터는 victimization 성능 추적이 활성일 때만 증가하므로, 0이라는 관측만으로 공급 부족의 발생 횟수나 장애 빈도를 알 수 없다. 기존의 통계가 유용하지 않다는 주석도 경로 제거의 성능 근거로 사용할 수 없다. [카운터 증가 조건과 주석](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9511-L9553), [통계 이름](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/perf_monitor.c#L518-L523).

### 왜 해결해야 하는가

현재 코드를 그대로 두면 저활동 대기자를 위한 예비 공급이 있다는 전제로 진행성을 판단하거나 수정 효과를 검증할 수 없다. 일반 flush 경로가 존재하고 대기자가 그 데몬을 깨운다는 사실만으로 예비 경로가 불필요하다고 결론 내릴 수도 없다. 코드의 의도와 실행 사이의 차이를 확인하고, 대기자와 재사용 가능한 후보가 함께 남은 조건에서 어떤 경로가 진행을 책임질지 결정해야 한다. 운영상 우회책과 긴급성은 확인되지 않았다.

복원과 제거 중 합의된 설계는 없다. 제거는 같은 저활동 조건에서 대기자의 진행을 맡는 대체 경로가 충분하다는 근거와 함께 평가해야 하며, 실행되지 않는 코드를 삭제하는 것만으로 이 문제의 해결을 인정할 수 없다. 복원 역시 순회 조건 한 곳만 바꿨다는 사실로 완료할 수 없다. 후보 유효성, 시작점 수명, 순회량, mutex 보유 시간, 대기자의 배정 후 진행을 확인해야 한다. 100ms는 데몬 구성 주기이며, 후보의 존재나 잠금 획득, 스케줄링과 무관하게 100ms 내 배정을 보장하는 수치가 아니다.

## Test Build

- 정적 확인 기준: CUBRID `f6cac312310f39f46711693da157a08f0e725693`의 소스다. 2026-10-21에 고정한 분석 기준이며, 모든 릴리스나 원격 최신 버전의 영향 범위를 뜻하지 않는다.
- 이번 확인: 순회와 호출 관계를 직접 읽고, 시작점 0과 3에 대한 분리 조건 모형을 실행했다. 엔진 빌드, 서버 부하, statdump 측정은 수행하지 않았다. 따라서 현재 엔진의 재현 OS와 실행 설정은 TBD다.
- 과거 이력: [기존 보고서](https://github.com/vimkim/my-cubrid-jira/blob/da39b0f3ee0bc1c55d2063588c3969a808a95687/issues/CBRD-27264-pgbuf-direct-victim-dead-paths_e6ed61e_claude.md)는 `e6ed61e87`, Fedora 44, GCC 16.1.1과 분리 C 모형을 기재한다. 이를 이번 기준의 엔진 장애 재현으로 취급하지 않는다. [2026-10-19 검토 자료](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/CBRD-27193/triage-2026-10-19.html#L100-L111)도 현재 엔진의 지연과 고객 장애가 미확인임을 명시한다.

## Repro

다음은 해당 커밋의 CUBRID 소스 최상위에서 수행하는 정적 확인 절차다. DB를 실행하거나 timeout을 재현하는 절차가 아니다.

```sh
sed -n '9580,9599p' src/storage/page_buffer.c
sed -n '9403,9417p' src/storage/page_buffer.c
sed -n '10346,10366p' src/storage/page_buffer.c
sed -n '9511,9516p' src/storage/page_buffer.c
rg -n 'pgbuf_lfcq_assign_direct_victims|pgbuf_panic_assign_direct_victims_from_lru|PSTAT_PB_VICTIM_ASSIGN_DIRECT_PANIC' src
```

첫 출력에서 private/shared 각각의 초기 인덱스와 첫 비교값이 같음을 확인한다. 다음 출력에서 제거, NULL 초기화, 그 값의 전달, 즉시 반환의 연결을 확인한다. 마지막 검색은 선언·정의와 호출부를 구분하여 다른 긴급 배정 호출이나 카운터 증가가 있는지 확인한다.

실행한 분리 모형의 결과는 private/shared 모두 시작점 0과 3에서 본문 0회, 다음 시작점 동일이었다. 이 결과는 첫 조건의 모순을 확인하며, 실제 엔진의 동시 실행이나 지연을 검증하지 않는다.

## Expected Result

대기자가 있고 재사용 가능한 후보가 남아 있는 저활동 조건에서 예비 공급을 포함한 담당 경로가 후보를 검사하고 대기자의 진행을 지원해야 한다. 필요한 공급 경로와 진척 판정 기준은 ANALYSIS에서 확정한다. 후보가 모두 사용 중이거나 재사용 불가능한 상태에서도 배정 성공을 보장하는 요구는 아니다.

## Actual Result

기준 소스에서 유지보수 순회 본문 두 곳은 실행되지 않고, 다른 긴급 배정 호출은 NULL 시작점으로 바로 반환한다. 그 결과 이 함수의 성공 배정과 전용 통계 증가에 도달하는 호출 경로가 없다. 현재 엔진의 starvation, timeout, assert 중단 여부와 빈도는 TBD다.

## Acceptance Criteria

- 저활동 상태에서 대기자와 유효한 victim 후보가 함께 남는 조건을 만들거나, 해당 조건의 도달성에 대한 분석 근거를 남긴다. 후보가 없는 경우와 다른 경로가 먼저 배정한 경우를 구분한다.
- 선택한 방안에서 대기자의 후보 탐색·배정·재개 결과를 확인한다. 경로를 제거한다면 같은 조건의 진행을 맡는 대체 경로와 검증 결과를 함께 남긴다.
- 무대기자, 유효 후보 부재, private/shared 후보, 배정 중 후보가 다시 사용되는 경우를 구분해 결과를 확인한다. 대기 해소만을 위해 사용 중인 페이지를 재사용하지 않는다.
- 순회량과 mutex 보유 시간, 할당 대기와 기존 배정 경로의 동작을 비교한다. 허용 기준과 debug/release 검증 범위는 ANALYSIS에서 정한다. 통계를 판정에 쓰면 추적 활성 여부를 기록한다.

## Additional Information

### ANALYSIS에서 확인할 사항

- 저활동 대기 상황의 실제 도달 조건, 일반 공급 경로가 멈추거나 충분하지 않은 이유, 사용 가능한 후보가 생기는 시점을 확인한다. 실제 영향 릴리스와 운영 증상도 별도로 확인한다.
- private/shared 시작점과 순회 예산이 보장해야 할 범위 및 반복 호출 간 진척을 정한다. 기존 보고서의 부분 순회와 전체 순회 조건 예시는 구현 후보이며, 원래 의도나 선택된 설계로 확정하지 않는다.
- 긴급 경로는 현재 `SERVER_MODE`에 속한다. 실제 수정 파일, 공통 통계 정의와 출력의 호환성, SA 빌드 확인 범위는 선택한 방안에 따라 정한다. 수정 범위를 한 파일로 고정하거나 영향이 없다고 보장하지 않는다.

### 관련 이슈와 중복 범위

- [CBRD-27211](https://jira.cubrid.org/browse/CBRD-27211)은 공급된 victim을 받을 대기자의 우선 선택 주기(`my_count % 4`)를 조사한다. 이번 예비 공급 경로와 구분하여 선택 정책의 영향을 평가한다. [현재 선택 함수](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L15509-L15539).
- [CBRD-27267](https://jira.cubrid.org/browse/CBRD-27267)은 big private victim 큐의 생산·소비 정책을 다룬다. 이 유지보수 함수는 private/shared LRU 인덱스를 직접 넘기며, `pgbuf_lfcq_assign_direct_victims`는 해당 목록을 조회한다. 큐의 생산 여부와 이번 순회 조건의 모순을 혼동하지 않는다. [목록 조회와 배정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L9613-L9645).
- [CBRD-27269](https://jira.cubrid.org/browse/CBRD-27269)은 의도한 동작을 유지하는 정리 작업이다. `monitor.victim_rich`와 낡은 주석의 정리는 그쪽에서 검토하며, 이 예비 경로를 복원하거나 제거할 정책 결정을 정리 작업에 넘기지 않는다.
- 현재 JIRA에는 [CBRD-24029](https://jira.cubrid.org/browse/CBRD-24029)(`pgbuf_page_maintenance daemon doesn't handle direct victims`)를 중복 대상으로 가리키는 링크가 있다. 해당 이슈는 `11.1.0.0358-079730c`에서 같은 순회 모순을 소스 분석으로 보고했으며, 보조 경로의 성능 효과는 확실하지 않다고 적었다. 이 이력은 현재 엔진의 장애 재현이나 성능 개선 측정이 아니다. 2026-10-21 조회에서 기존 이슈는 Develop이고 담당자가 있으므로, 기존 담당자와 단일 수정 담당 및 완료 결과를 어느 이슈에 기록할지 조정해야 한다. 이번 하위 이슈를 별도 수정 승인으로 취급하지 않는다.

## Triage Request

저활동 대기자를 위한 예비 배정이 현재 소스에서 실행되지 않는 문제를 확인하고, 작성자 측에 ANALYSIS를 배정할 것을 요청한다. CBRD-24029의 기존 담당자와 중복 범위, 단일 수정 담당 및 완료 결과의 기록 방식을 먼저 조정한 뒤, 실제 대기·후보 조건과 다른 공급 경로의 한계를 확인하고 필요한 진행 보장 결과를 정한다. 복원 또는 근거 있는 대체 방안의 선택, 구현 범위와 우선순위는 triage 및 ANALYSIS에서 결정한다.
