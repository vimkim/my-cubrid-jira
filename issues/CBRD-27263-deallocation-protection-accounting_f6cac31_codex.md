# [PGBUF] 요청 페이지의 dealloc 보호 등록·해제를 fix 경로마다 일치시킨다

## Issue Triage

**이슈 수행 목적**: `OLD_PAGE_PREVENT_DEALLOC` 요청이 자신이 등록한 해제 방지 보호만 해제하고, 성공·실패·재정렬 경로에서 불필요한 감소나 등록 잔존을 만들지 않도록 한다.

**이슈 수행 이유**: 기준 소스에서 lock-free READ fix는 보호 등록을 건너뛰고 공통 해제를 실행한다. 일반 fix 실패와 ordered fix 재정렬 사이에도 실제 등록 여부를 전달하지 않는 경로와 요청 페이지의 잔여 보호를 정리하지 않는 출구가 있다. 카운터 원자 연산만으로는 이 소유권 불일치를 막을 수 없다.

**영향**: heap 체인 순회가 의존하는 vacuum 회수 방지 판단이 부정확해질 수 있다. 보호가 부족하면 페이지를 다시 얻는 작업의 오류나 debug assert로, 보호가 남으면 해당 BCB가 유지되는 동안 빈 페이지 회수 지연으로 이어질 가능성이 있다. 과거 계측 보고와 현재 소스의 제어 흐름은 확인했으나, 현재 기준 빌드의 최종 질의 실패·서버 중단·데이터 손상 및 고객 노출은 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

페이지 버퍼는 디스크 페이지를 메모리에 보관한다. BCB(Buffer Control Block)는 메모리 버퍼 슬롯의 제어 상태이고, VPID는 볼륨 번호와 페이지 번호로 된 페이지 식별자이다. fix/unfix는 사용 중인 페이지의 상주와 사용 수를 관리하며, page latch는 메모리 페이지 접근을 짧게 조정한다. 논리 데이터 접근을 조정하는 transaction lock과는 역할이 다르다.

`count_fix_and_avoid_dealloc`의 상위 16비트는 hot page 판정용 누적 fix 횟수이고, 하위 16비트는 페이지 해제(deallocation) 방지 수이다. 현재 사용 중인 fix 수와 latch 상태는 별도 `atomic_latch`에 있다. 이 이슈는 하위 보호 수의 등록·해제를 다룬다. [필드 정의](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L478-L517), [비트 구분](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L267-L269)

일반 `pgbuf_fix`는 `OLD_PAGE_PREVENT_DEALLOC`이면 latch 시도 전에 보호를 등록하고, latch를 얻은 뒤 해제한다. 반면 READ + 이 fetch mode + 무조건 latch 요청은 `pgbuf_lockfree_fix_ro`를 먼저 시도한다. 성공하면 `goto fast_path`로 등록을 건너뛰고 동일한 해제 지점에 도달한다. 빠른 경로 자체에는 이 보호를 등록하는 호출이 없다. [빠른 경로 진입과 점프](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2266-L2283), [일반 경로 등록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2377-L2393), [공통 해제](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2450-L2469), [빠른 경로 전체](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L7689-L7752)

빠른 경로의 CAS는 이미 READ latch가 있고 fix 수가 양수이며 대기자가 없는 BCB에서 fix 수를 늘린다. 따라서 이 요청이 별도 보호 등록 없이 READ latch를 얻는 것 자체와, 등록하지 않은 보호를 해제하는 것은 구분해야 한다. 문제는 후자이다. 해제 함수는 합계가 0이면 감소하지 않지만, 양수이면 소유자 확인 없이 CAS로 1을 줄인다. 이때 남아 있는 값이 다른 요청의 유효한 보호라면 그 보호를 줄일 수 있다. [성공 조건과 CAS](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L7703-L7715), [등록·해제 구현](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16217-L16264)

### 요청 페이지와 보유 페이지의 보호 소유권

`pgbuf_ordered_fix`는 여러 페이지의 latch 순서를 맞추기 위해 일부 보유 페이지를 unfix한 뒤 다시 fix한다. 최초 시도에는 원래 fetch mode를 전달한다. 다른 페이지를 보유하지 않거나 요청 페이지만 보유하면 무조건 latch를 선택하므로 위 빠른 경로와 겹칠 수 있다. [최초 시도](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L12286-L12304)

조건부 최초 시도가 실패한 뒤 재정렬에 들어가면 `has_dealloc_prevent_flag`를 설정하고 fetch mode를 `OLD_PAGE`로 바꾼다. 이 flag는 최초 `pgbuf_fix`가 실제로 등록했는지 확인한 결과가 아니다. 등록 이후의 조건부 latch 실패는 등록을 남기므로, 정상 재정렬에서는 그 보호를 ordered fix가 이어받아 요청 페이지를 다시 얻은 뒤 해제한다. 따라서 ordered fix의 두 해제 지점을 모두 불필요한 해제로 분류해서는 안 된다. [실패 분기와 flag 설정](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L12350-L12404), [등록 후 latch 실패 반환](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2377-L2415), [요청 페이지 해제 1](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L12689-L12731), [요청 페이지 해제 2](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L12851-L12860)

한편 재정렬하면서 놓는 **보유 페이지**에는 별도로 보호를 등록하고 `ordered_holders_info[i].prevent_dealloc`으로 추적한다. 재획득 성공과 `exit` 정리에서 이 등록을 해제한다. 요청 페이지의 flag와 별도 소유권이다. 이 대응 관계가 있다는 사실을 보유 페이지 보호의 모든 경합이 안전하다는 증명으로 확대하지 않는다. [보유 페이지 등록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L12633-L12652), [재획득 후 해제](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L12883-L12891), [exit 정리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L12954-L13008)

같은 BCB 상주 기간에 다른 요청의 증감과 교체가 개입하지 않는 조건에서 제어 흐름을 정리하면 다음과 같다. 아래는 소스 분석이며, 각 오류 경로의 실제 실행 빈도를 측정한 표가 아니다.

| 진입·종료 조건 | 요청 페이지 등록·해제 | 판단 |
| --- | --- | --- |
| 최초 lock-free READ 성공 | 등록 없음, 공통 해제 호출 | 양수이면 자기 등록 없는 감소가 가능하고, 0이면 방어가 감소를 막는다. 항상 -1이 되는 것은 아니다. |
| 최초 일반 경로 성공 | 등록 1회, 공통 해제 1회 | 등록·해제의 제어 흐름이 대응한다. |
| 등록 후 조건부 latch 실패, 재정렬 후 요청 페이지 획득 성공 | 최초 등록을 ordered fix가 해제 | 두 함수의 분담으로 대응한다. |
| 등록 전 최초 실패를 거쳐 재정렬 진행, 이후 요청 페이지 획득 성공 | 실제 등록 없이 flag에 따라 해제 가능 | BCB 확보 실패 등에서 이 분기로 이어질 수 있는 오류와 실행 조건은 ANALYSIS에서 확인한다. |
| 등록 후 요청 페이지 해제에 도달하기 전에 실패 | 등록에 대응하는 요청 페이지 정리가 없을 수 있음 | 재정렬 중 refix 실패뿐 아니라 최초 latch 실패 뒤 interrupt·zero-wait·무조건 latch 오류 출구도 점검한다. |

등록 전 실패는 BCB 확보 실패 반환 등에서 가능하고, ordered fix는 일부 오류와 zero-wait·무조건 latch 실패를 걸러낸 뒤 나머지 조건부 실패에 대해 재정렬을 계속한다. 반대로 최초 latch 실패 후 바로 종료하거나, 재정렬 중 요청 페이지를 얻기 전에 실패하면 요청 보호가 남을 수 있다. 최종 `exit` 루프는 보유 페이지의 `prevent_dealloc`만 확인한다. [등록 전 반환](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2317-L2379), [최초 실패 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L12350-L12404), [refix 실패](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L12794-L12837), [최종 정리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L12980-L13008)

### 왜 문제인가

이 보호는 vacuum의 빈 heap 페이지 회수 판단에 사용된다. vacuum은 재사용 가능한 빈 페이지에서 보호가 없는지 확인하고, 실제 heap 페이지 제거 함수는 필요한 latch를 얻은 뒤 다시 확인한다. 보호가 있으면 제거를 포기한다. 보호는 없는데 대기자가 있으면 별도의 debug assert와 오류 경로로 빠진다. [vacuum 진입 판단](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/query/vacuum.c#L1842-L1861), [latch 후 재확인](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/heap_file.c#L3431-L3465)

따라서 다른 요청의 보호를 먼저 줄이면, 그 요청이 페이지를 놓고 있는 동안 회수 방지가 약해질 수 있다. 빠른 경로가 READ latch를 보유한 동안에는 그 latch도 접근을 조정하므로, 해제 호출 한 번이 즉시 vacuum 회수를 뜻하지는 않는다. 이후 latch가 풀리고 실제 회수와 refix가 겹치는지를 별도로 확인해야 한다. 재정렬 refix에서 예상하지 않은 `ER_PB_BAD_PAGEID`를 만나면 debug assert와 오류 반환 경로가 존재한다. 이 연결은 소스에서 추론한 위험이며, 이 이슈로 운영 데이터 손상이 발생했다는 증거는 아니다. [예상하지 않은 페이지 소실 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L12804-L12837)

반대 방향으로 등록이 남으면 보호가 양수인 동안 vacuum이 빈 페이지 회수를 보류할 수 있다. 다만 보호는 디스크 페이지의 영구 속성이 아니다. 소스는 보호된 BCB도 교체될 수 있고 다시 로드하면 보호 수가 0일 수 있다고 설명하며, BCB 초기화·재사용 과정에서 카운터를 초기화한다. 따라서 “페이지가 영구히 회수되지 않는다”거나 “VPID별 로그 합계가 BCB의 영구 잔량이다”라고 단정하지 않는다. [교체에 대한 기존 주석과 0 방어](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16238-L16264), [카운터 초기화](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16281-L16300)

사용 경로는 heap 체인 순회를 포함한다. 기준 소스의 외부 `OLD_PAGE_PREVENT_DEALLOC` 호출 10곳은 watcher를 통해 또는 직접 ordered fix에 들어간다. 대표적으로 `heap_next_internal`은 이 mode로 다음 페이지를 얻다가 실패하면 스캔 오류를 반환한다. WRITE 요청도 이 mode를 사용하지만 lock-free READ 성공 경로에는 들어가지 않는다. 모든 호출에서 실제 피해가 동일하다고 가정하지 않고, 호출자별 오류 처리와 동시 vacuum 도달성을 분석한다. [스캔 호출과 오류 반환](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/heap_file.c#L7636-L7655), [watcher 경유](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/heap_file.c#L1019-L1040), [직접 READ 호출](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/heap_file.c#L9047-L9054), [WRITE 호출](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/locator_sr.c#L12751-L12755)

### 왜 해결해야 하는가

자기 등록 없는 해제와 등록 잔존은 같은 합계 카운터를 공유하는 다른 요청의 보호 판단에 영향을 줄 수 있다. 현재의 0 방어는 부족분을 음수로 만들지 않는 처리이며 소유권을 검증하지 않는다. CAS 갱신도 대응하지 않는 등록·해제를 바로잡지는 못한다. 호출자가 개별적으로 회피할 수 있는 설정은 확인하지 못했으며, 페이지 버퍼 내부 계약을 명확히 하고 회귀 검증을 가능하게 하는 작업이 필요하다.

0 방어로 감소하지 않은 호출도 진단 로그를 남길 수 있으므로, `er_log_debug`를 활성화한 환경에서는 불필요한 해제가 반복 로그로 나타날 수 있다. 로그 비용은 측정하지 않았다. [0 방어의 로그](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16242-L16261)

이 보호를 단순히 제거하거나 `OLD_PAGE_MAYBE_DEALLOCATED`로 바꾸는 것으로 대체할 수 있다고 보지 않는다. 현재 heap 체인 순회는 페이지 내부 링크와 watcher를 사용하고, 소실 가능한 페이지를 건너뛰는 순회와 처리 계약이 다르다. 해결은 필요한 보호 구간을 보존하면서 요청별 등록·해제를 맞추는 결과를 목표로 한다. 성능 비용, 보호 소유권 전달 방법, 기존 BCB 교체 제약의 처리 범위는 ANALYSIS에서 결정한다. 착수 근거는 현재 소스의 불일치이며, 긴급도와 릴리스 포함 여부는 별도 확인이 필요하다. [체인 순회와 소실 허용 순회의 구분](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/heap_file.c#L9611-L9629)

## Test Build

| 구분 | 확인 범위 |
| --- | --- |
| 현재 소스 분석 | CUBRID `f6cac312310f39f46711693da157a08f0e725693`. 2026-10-21 고정 기준이며 전체 릴리스의 영향 범위를 뜻하지 않는다. 이 보고서 작성에서는 엔진을 빌드하거나 SQL 부하를 재실행하지 않았다. |
| 과거 계측 보고 | develop `e6ed61e87d68baf1c38cee83ddd3bb4b2fa71b2e`, Linux x86_64 debug로 기록되어 있다. 문서는 별도 계측 커밋 `372b5cd8c`를 식별하지만, 전체 계측 커밋·원본 로그·OS 및 컴파일러 상세를 이번에 확보하지 못했다. |
| 출시 버전 | 테스트한 정식 릴리스는 없다. 과거 `e6ed61e87` 기준 분석은 `v11.4.5`·`release/11.4_hotfix` 미포함과 develop 빌드 태그 `v11.4.5.1898` 포함을 기록했다. 이 역사 기록을 현재 배포 상태나 고객 노출 부재로 일반화하지 않는다. |

과거 자료는 [고정 문서 리비전](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/pgbuf/e6ed61e_claude/10-CBRD-27263-repro-proof-and-solutions.md#L1-L4)에 보존되어 있다.

## Repro

### 현재 소스의 경로 확인

고정 커밋의 소스 루트에서 다음 읽기 명령으로 등록·점프·해제와 요청 flag의 위치를 확인한다. 이는 런타임 재현 명령이 아니다.

```sh
rg -n 'pgbuf_lockfree_fix_ro|goto fast_path|fast_path:|has_dealloc_prevent_flag|pgbuf_bcb_(register|unregister)_avoid_deallocation' src/storage/page_buffer.c
```

등록 지점에 도달하지 않은 lock-free 성공이 공통 해제로 합류하는지, 최초 실패 후 flag가 실제 등록 여부 없이 설정되는지, `exit`에서 요청 flag를 정리하는지 대조한다.

### 과거 부하와 추가 재현 계획

과거 문서는 `data_buffer_size=64M`, `er_log_debug=yes`, 100,000행 테이블, 순차 heap scan 10세션과 구간 UPDATE 4세션을 각 40회 실행했다고 기록한다. 등록·해제 직전과 빠른 경로 합류 지점에 로그를 추가한 진단 빌드이다. 별도 `impact-demo.sh`는 스캔 6세션과 배치 DELETE를 조합했으나 최종 assert는 관측하지 못했다고 기록한다. [부하 구성](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/pgbuf/e6ed61e_claude/10-CBRD-27263-repro-proof-and-solutions.md#L119-L136), [최종 충돌 미재현](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/pgbuf/e6ed61e_claude/10-CBRD-27263-repro-proof-and-solutions.md#L179-L184)

현재 기준의 검증은 **미실행 제안**이다. 동일 BCB의 상주 기간을 구분하고 요청 ID, 등록 여부, 실제 원자 갱신 성공, BCB 교체·초기화 이벤트를 함께 기록하는 집중 테스트를 준비한다. 먼저 한 요청의 보호를 유지한 상태에서 다른 요청의 lock-free READ 성공·unfix를 제어하여 원래 보호가 줄어드는지 판정한다. 이어 위 표의 일반 성공, 조건부 실패 후 재정렬 성공, 등록 전 실패, 등록 후 조기 종료·재정렬 실패를 각각 검증한다. 필요한 스레드 동기화와 오류 주입 지점은 ANALYSIS 산출물로 정하며, 주입 결과와 자연 발생 오류를 구분한다. 빌드는 프로젝트의 `./build.sh -m debug`와 `./build.sh -m release`를 사용할 수 있으나, 이것만으로 해당 집중 테스트가 실행되지는 않는다.

## Expected Result

요청이 등록하지 않은 보호를 감소시키지 않고, 등록한 보호는 필요한 latch 전·재정렬 구간 동안 유지한 뒤 해당 요청의 종료 경로에서 정리한다. 동일 BCB 상주 기간에서는 완료한 요청이 다른 요청의 보호 수를 바꾸거나 불필요한 등록을 남기지 않아야 한다. BCB 교체로 보호 값이 초기화되는 기존 제약은 별도로 식별하여, 교체 전후 VPID 합계를 소유권 판정으로 사용하지 않는다.

## Actual Result

현재 기준 소스에서는 lock-free 성공의 등록 없는 해제 호출과, 실제 등록 여부를 확인하지 않는 ordered fix flag 및 요청 페이지 정리가 빠진 출구를 확인한다. 오류 경로의 자연 발생 도달성과 최종 운영 영향은 아직 재현하지 않았다.

과거 `e6ed61e87` 계측 자료는 다음 수치를 **보고한다**. 이번 작성에서 원본 로그를 재집계한 결과는 아니다. [원래 수치](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/pgbuf/e6ed61e_claude/10-CBRD-27263-repro-proof-and-solutions.md#L153-L159)

| 보고 항목 | 과거 보고값 | 이번 보고서의 해석 |
| --- | --- | --- |
| `unreg-fix lockfree=1` | 40회 | 등록을 건너뛴 경로가 해제 호출에 도달한 관측으로 취급한다. 실행 빈도의 일반값으로 사용하지 않는다. |
| 그중 관측 시 `avoid >= 1` | 7회, VPID `0\|769`, `0\|4673` | 실제 감소와 다른 요청의 유효한 보호 소유권을 확정하려면 추가 계측이 필요하다. |
| VPID별 로그 집계 | `0\|769` net -1, `avoid=0` 해제 로그 39회 | 로그상의 집계로 취급한다. BCB 실값이 음수였거나 보호가 영구히 손실되었다는 뜻으로 해석하지 않는다. |

기존 이슈에는 UPDATE를 뺀 5,625행 변형에서 등록 없는 해제가 23회였다는 기록도 있다. 이 역시 과거 보고로 남기며 현재 빌드의 재현 결과로 대체하지 않는다. [당시 이슈 원문](https://github.com/vimkim/my-cubrid-jira/blob/da39b0f3ee0bc1c55d2063588c3969a808a95687/issues/CBRD-27263-pgbuf-lockfree-avoid-dealloc-asymmetry_e6ed61e_claude.md#L256-L256)

기존 계측은 원자 갱신 전에 카운터를 읽어 출력한다. 로그 출력과 실제 해제 함수의 읽기·CAS 사이에 다른 스레드의 증감이 가능하므로, 관측 양수 7회만으로 성공한 감소 7회나 특정 소유자의 보호 소실을 증명하지 못한다. 또한 요청 페이지와 보유 페이지의 로그를 합치고 BCB 교체·초기화를 구분하지 않은 VPID별 합계는 최종 상태의 증거로 충분하지 않다. [과거 계측 설명](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/pgbuf/e6ed61e_claude/10-CBRD-27263-repro-proof-and-solutions.md#L119-L127), [현재 해제의 실제 읽기와 CAS](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16230-L16264)

## Additional Information

빠른 경로는 [CBRD-26425 도입 커밋 `58cef8e01fcf121acbe3a35b7249deda54217532`](https://github.com/CUBRID/cubrid/commit/58cef8e01fcf121acbe3a35b7249deda54217532)에서 추가되었다. 이로부터 작성자의 실수나 설계 의도를 확정하지 않는다. CBRD-26242의 성능 목적과 관련된 과거 분석은 빠른 경로 단독의 성능 기여를 측정하지 않았다고 설명한다. 정식 릴리스 포함 여부와 외부 배포 여부는 별도 근거가 필요하다. [역사 분석](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/pgbuf/e6ed61e_claude/10-CBRD-27263-repro-proof-and-solutions.md#L186-L212)

부모는 [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)이다. 이 자식의 범위는 요청 페이지 dealloc 보호의 등록·해제와 그 검증이다. 보유 페이지 보호는 소유권을 혼동하지 않도록 함께 확인한다. 같은 점프가 건너뛰는 hot page 횟수 등록과 debug `had_holder` 추적은 별도 영향 평가가 필요하며, 이 이슈의 완료 조건에 자동으로 추가하지 않는다. [건너뛰는 일반 경로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2347-L2390)

일반 nested READ-to-WRITE fix의 BCB/holder fix 수 문제는 [CBRD-27370](https://jira.cubrid.org/browse/CBRD-27370), `pgbuf_simple_fix` 실패 후 loading 기록 정리는 [CBRD-27630](https://jira.cubrid.org/browse/CBRD-27630)의 범위이다. 이 보고서는 `pgbuf_fix`와 ordered fix의 보호 수를 다루며, 유사한 “fix 카운터” 표현만으로 문제를 합치지 않는다. timeout·zero-wait로 실패하는 경로의 보호 정리 결과는 [CBRD-27356](https://jira.cubrid.org/browse/CBRD-27356)과 공유하되, 그 정책 선택을 이 이슈의 선행 조건으로 두지 않는다.

## Options for Analysis

과거 자료의 후보를 분석 선택지로 보존한다. 채택 합의나 성능·위험 순위는 확인하지 않았다.

| 후보 | 기대 효과 | 한계·비용과 판별 사항 |
| --- | --- | --- |
| 현행 분담을 유지하고 등록 여부와 정리 출구를 명시 | 빠른 경로의 자기 등록 없는 해제와 실패 시 누락을 국소적으로 바로잡을 수 있다. | 두 함수의 소유권 분담이 남는다. 조건부 실패 때 보호를 넘기는 계약과 모든 조기 출구를 검증해야 한다. 빨라진다는 주장은 측정 전 확정하지 않는다. |
| 요청 보호의 소유권을 ordered fix 쪽으로 모음 | 한 요청의 보호 수명과 종료 처리를 한곳에서 추적하기 쉬워질 수 있다. | 등록을 늦추면 최초 latch 대기 중 보호가 빠질 수 있다. 앞당기면 BCB 미상주 처리와 추가 조회·원자 연산 비용을 검증해야 한다. |
| lock-free READ 빠른 경로를 비활성화하거나 되돌림 | 등록을 건너뛰는 진입을 제거할 수 있다. | 일반·재정렬 오류 출구 문제는 남는다. 공유 READ 부하의 성능 변화를 측정해야 하며 가장 안전하거나 일정상 필요한 선택이라고 단정하지 않는다. |

첫 후보는 기존 분담을 보존하는 대신 전달 계약을 남기고, 두 번째는 그 계약을 줄이는 대신 등록 시점과 BCB 수명 처리를 바꾼다. 세 번째는 빠른 경로 문제만 줄이므로 전체 오류 경로 검증을 대신하지 못한다. 유지할 보호 구간, 오류 도달성, 집중 테스트 결과와 공유 READ 성능 비교로 선택한다. 보호 기능 제거는 호출자 계약 검증 없이 택할 수 없으며, 카운터를 `atomic_latch` 워드에 합치는 것만으로 등록을 건너뛰는 제어 흐름이 해결되지는 않는다.

## Acceptance Criteria

- 동일 BCB 상주 기간에 유효한 보호를 유지한 요청이 다른 요청의 lock-free 성공·unfix 때문에 보호를 잃지 않음을 판정할 수 있다.
- 일반 성공, 조건부 실패 후 재정렬 성공, 등록 전 오류, 등록 후 최초 실패·재정렬 오류의 등록 여부와 정리 책임이 기록되고, 완료한 요청의 중복 해제·불필요한 등록 잔존이 없음을 확인한다.
- 요청 페이지 보호와 보유 페이지 보호를 구별하여, 필요한 최초 latch 대기와 ordered refix 구간의 보호 계약을 보존했음을 확인한다.
- 오류 주입 결과, 자연 발생 재현, BCB 교체에 의한 기존 제약을 구분하고, 최종 질의 오류·assert 도달 여부와 미재현 범위를 기록한다.

## Definition of done

선택한 해결 방안과 보호 소유권 계약을 리뷰하고, 실제 원자 갱신과 BCB 수명을 판정하는 집중 회귀 검증을 debug·release 구성에서 수행한다. 변경한 오류 경로와 동시 heap 순회·vacuum 동작을 검증하고, 빠른 경로의 처리량에 영향을 주는 변경이면 동일 조건의 공유 READ 비교 결과를 남긴다. 필요한 정확한 테스트 배치와 성능 허용 기준은 ANALYSIS에서 정한다. 출시 영향 범위는 실제 포함 커밋과 시험한 빌드를 기준으로 별도 기록한다.

## Triage Request

현재 소스에 남아 있는 요청 페이지 보호의 등록·해제 소유권 불일치를 확인하고, 이슈 작성자 측에 ANALYSIS 배정을 요청한다. 분석에서는 실패 출구의 실제 도달성, 같은 BCB에서 다른 유효 보호를 감소시키는 실행 순서, 교체 시 보호 계약, 기존 계측의 한계를 보완할 판정 방법과 해결 범위를 결정한다. 최종 우선순위와 배정은 triage에서 결정한다.
