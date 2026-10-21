# [PGBUF] 초기화/종료 경로의 자원 수명을 바로잡는다

## Issue Triage

**이슈 수행 목적**: 페이지 버퍼의 정상 초기화, 중간 실패, 종료와 재초기화에서 실제로 확보하고 초기화한 자원만 정리하며, private LRU가 없는 설정을 크기 0 할당의 반환값에 의존하지 않고 처리한다.

**이슈 수행 이유**: 기준 소스에 대상과 다른 타입을 사용한 `direct_victims` 초기화 크기, AOUT 보조 함수와 공통 종료 함수의 중복 mutex 파괴, private LRU 개수가 0일 때의 무조건 할당과 NULL 실패 판정이 남아 있다. 호출자까지 보면 공통 종료 함수가 다시 호출되는 실패 경로도 있어, 세 지점의 수정과 함께 초기화 단계별 정리 책임을 확인해야 한다.

**영향**: 초기화 실패를 진단하는 개발자와 해당 설정·할당 동작을 사용하는 실행 환경에 영향을 줄 수 있다. 잘못된 자원 정리는 최초 실패에 정리 오류를 더할 수 있고, private LRU가 0개일 때 NULL을 돌려주는 할당 동작에서는 불필요하게 초기화를 실패시킨다. 현재 기준 빌드에서 크래시나 서비스 장애를 재현한 결과는 없으며, 발생 빈도와 지원 플랫폼별 영향은 미확인이다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

페이지 버퍼는 디스크 페이지를 메모리에 캐시하고 재사용할 버퍼 슬롯과 관련 제어 상태를 관리한다. BCB(Buffer Control Block)는 버퍼 슬롯의 제어 상태이며, direct victim은 슬롯이 필요한 스레드에 재사용 가능한 BCB를 직접 넘기는 기존 장치다. 이 이슈는 부모 [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)의 초기화·종료 자원 수명과 부분 실패 정리를 담당한다.

분석 기준은 CUBRID 커밋 `f6cac312310f39f46711693da157a08f0e725693`이다. 아래 내용은 해당 소스의 정적 확인 결과이며, 모든 출시 버전에 대한 영향 판정은 아니다.

| 확인 지점 | 기준 소스의 상태 | 필요한 결과 |
|---|---|---|
| `pgbuf_initialize`의 `direct_victims` 초기화 | 대상은 포인터 3개를 가진 `PGBUF_DIRECT_VICTIM`인데 크기는 `PGBUF_VICTIM_CANDIDATE_LIST`를 사용한다. 서버 빌드 전용 구간이다. [타입 정의][S1], [초기화][S2] | 구조체의 실제 대상과 초기화 범위가 일치해야 한다. |
| `pgbuf_initialize_aout_list`의 실패 정리 | hash 포인터 배열 할당 또는 `mht_create` 실패 시 `Aout_mutex`를 파괴하고, 호출자의 오류 처리에서 `pgbuf_finalize`가 같은 mutex를 다시 파괴하는 경로가 있다. [AOUT 실패 처리][S3], [호출][S4], [공통 오류 처리][S19], [종료][S5] | 하나의 성공한 mutex 초기화에 대응하는 파괴가 중복되지 않아야 한다. |
| `pgbuf_initialize_page_quota`의 private 배열 | private LRU 수가 0이어도 `malloc(0)`을 호출하고 NULL이면 메모리 부족으로 반환한다. 같은 오류 메시지에는 실제 private 개수가 아닌 전체 LRU 개수를 사용한다. [개수 결정][S6], [할당과 진단][S7] | 빈 배열을 유효한 상태로 처리하고, 실패 진단의 크기가 실제 요청과 일치해야 한다. |

첫 번째 항목의 잘못된 타입 참조를 곧바로 현재 크래시로 해석할 수는 없다. `pgbuf_Pool`은 정적 전역이고, 종료 함수는 두 대기 큐 포인터를 삭제한 뒤 NULL로 되돌린다. 따라서 첫 초기화와 정상 종료를 거친 경로에는 완화 요인이 있다. 현재 소스만으로 재초기화 때 쓰레기 포인터가 삭제된다는 실행 결과는 확인하지 않았다. 필드 추가·배치 변경 시에도 초기화 의도를 유지하도록 대상과 크기의 불일치를 없앨 필요가 있다. [정적 전역][S22], [큐 정리][S8]

AOUT는 교체된 페이지 식별자(VPID: volume/page 식별자)의 짧은 이력을 보관하는 FIFO 목록이다. [AOUT 정의][S24] 두 번째 항목은 AOUT가 실제로 활성화되어 hash 초기화까지 진행하는 조건과 구분해야 한다. `data_aout_ratio`의 기본값은 0이며, 매개변수 로드 뒤 수행하는 `prm_tune_parameters`는 CBRD-20741 관련 주석과 함께 값을 0으로 설정한다. 그러므로 설정 파일에 `data_aout_ratio=0.1`만 추가하면 이 실패 경로를 재현할 수 있다는 기존 절차는 근거가 부족하다. AOUT 활성 경로를 확인하려면 초기화 직전의 유효값과 이를 만드는 지원 경로 또는 시험용 주입 조건을 먼저 기록해야 한다. AOUT 재활성화 정책은 이 이슈의 목표가 아니다. [기본값][S9], [로드 후 튜닝][S10], [강제 비활성화][S11]

전체 LRU 수는 shared와 private의 합이며, 유효한 초기화에서 shared 목록이 존재하므로 전체 LRU용 배열과 private 전용 배열의 빈 조건은 다르다. [개수 매크로][S25], [shared 목록 결정][S26] 세 번째 항목의 private LRU 수는 서버에서 `num_private_chains=0`이면 0이며, standalone(SA_MODE)에서도 0으로 설정한다. 따라서 크기 0 할당은 실패 주입 없이 정상 초기화에서도 도달하는 코드다. NULL이 반환되면 호출자가 초기화 실패로 처리한다는 것이 소스에서 확인한 조건이며, 특정 지원 플랫폼에서 실제로 그 반환값 때문에 기동에 실패했다는 실행 증거는 없다. 초기화 루프의 private 배열 접근은 private 인덱스에만 발생하고, 다른 사용처인 private LRU 배정·반납 함수에도 quota 또는 인덱스 조건이 있다. 다만 수정 후 NULL을 유효한 빈 배열 상태로 둘 때의 전체 사용 계약은 ANALYSIS에서 확인한다. [개수와 할당][S6], [초기화 루프][S7], [배정·반납][S12]

### 왜 문제인가

초기화 실패는 최초 원인을 남기고 이미 얻은 자원만 반환해야 한다. 메모리 부족 뒤 이미 파괴한 mutex를 다시 파괴하는 경로가 있으면, 오류 처리 자체의 유효성을 보장하기 어렵고 최초 실패와 정리 문제를 함께 조사해야 한다. 다만 이 경로가 현재 지원 기동 절차에서 어떤 빈도로 실행되며, 실제 진단 훼손·중단으로 이어지는지는 측정하지 않았다.

또한 공통 종료 함수를 호출한다는 사실만으로 정리 책임이 한곳에 모였다고 볼 수 없다. 초기화 보조 함수가 자체 정리를 수행하는 경우가 있고, 호출자도 다시 종료를 호출한다. 기준 소스에서 다음 확인 범위가 필요하다.

| 수명 경계 | 확인 사실과 남은 질문 |
|---|---|
| AOUT 초기화 전 실패 | BCB/hash/lock/LRU 초기화 실패도 공통 오류 처리로 간다. `invalid_mutex`와 `Aout_mutex`의 명시적 초기화는 뒤에 있는데 종료는 조건 없이 파괴한다. 바이트 0 초기화와 mutex의 유효한 수명을 동일시하지 않고, 초기화에 도달하지 않은 자원의 처리와 반환값을 확인해야 한다. [호출 순서][S4], [AOUT mutex 초기화][S13], [invalid mutex 초기화][S23], [종료][S5] |
| 보조 함수 내부 실패 | BCB 초기화는 I/O 페이지 배열 확보 실패 시 BCB 배열을 직접 해제하고 NULL로 만든다. AOUT도 배열·hash를 자체 정리한다. 따라서 공통 종료의 존재만으로 모든 보조 함수가 같은 소유 규칙을 따른다고 가정할 수 없다. [BCB 부분 실패][S14], [AOUT 정리][S3] |
| 호출자 오류 처리 | `logtb_Reuse_boot_managers`가 false인 분기에서 `pgbuf_initialize` 실패 후 `logtb_undefine_trantable`을 호출하며, 이 함수는 `pgbuf_finalize`를 호출한다. 내부 실패 정리에 이어 종료가 다시 호출될 수 있는 소스 경로다. 실제 호출 횟수와 대상별 초기화·파괴 횟수를 함께 확인해야 한다. [호출자][S15], [상위 정리][S16] |
| 정상 초기화·재초기화 | `free_holder_set_mutex`와 `show_status_mutex`는 초기 구간에서 `PTHREAD_MUTEX_INITIALIZER`를 대입하고 뒤에서 `pthread_mutex_init`도 호출한다. 이 수명 처리도 점검 대상이다. 한편 boot manager 재사용 분기는 페이지 버퍼 초기화·종료를 생략하므로, 모든 transaction table 재정의가 페이지 버퍼 재초기화를 뜻하지 않는다. [초기 대입][S17], [holder 초기화][S18], [상태 mutex 초기화][S19], [재사용 조건][S20] |

mutex 관련 실행 효과는 서버 빌드에서 확인해야 한다. 이 파일은 비서버 빌드의 `pthread_mutex_init`·`destroy`를 매크로로 비우므로 standalone에서 같은 코드를 통과했다는 사실로 서버 mutex 수명을 검증할 수 없다. standalone은 private LRU 0개와 배열 정리 검증에 별도로 포함한다. [빌드 구분][S21]

### 왜 해결해야 하는가

기존 세 지점에는 초기화 대상·개수·정리 책임과 코드가 어긋나는 구체적 근거가 있다. 이를 유지하면 초기화 실패 시험에서 자원 수명 오류와 최초 할당 오류를 분리하기 어렵고, private LRU가 없는 유효한 상태도 할당 동작에 종속된다. AOUT를 비활성으로 유지하는 현재 정책은 해당 hash 실패 경로의 노출을 줄이지만, AOUT 이전 실패나 호출자 중복 정리, 빈 배열 처리까지 해결하지는 않는다.

따라서 초기화·종료 영역을 한 작업 단위로 검토하되, 수정이 반드시 한두 줄 또는 한 파일로 끝나고 정상 경로 영향이 전혀 없다고 미리 약속하지 않는다. 필요한 결과는 실패 위치별로 자원 수명이 정의되고, 빈 구성이 불필요하게 실패하지 않으며, 최초 오류를 분석할 수 있는 상태를 남기는 것이다. 긴급도와 영향 규모를 정할 운영 장애 증거는 현재 없다.

## Test Build

현재 확인은 위 기준 커밋의 소스 검토다. 이 보고서 작성 과정에서 새 엔진 빌드, 실패 주입 또는 서버·standalone 실행을 수행하지 않았다. 영향을 받는 출시 버전, 운영체제와 allocator 조합은 TBD다.

기존 [CBRD-27194 보고서][H2]에는 `develop e6ed61e87`, Fedora 44, GCC 16.1.1, CMake `debug` 빌드의 디버그 정보에서 두 타입의 크기를 각각 24바이트와 16바이트로 확인했다는 기록이 있다. 이는 당시 빌드의 보고이며 현재 기준에서 재실행한 결과가 아니다. 같은 세 항목을 묶은 [당시 분석 제안][H1]도 수정 방향을 제안한 이력으로 참고한다.

2026-08-06 17:41 KST의 [첨부 이미지 1020015][H3]도 확인했다. 이미지는 24/16바이트 초기화 크기 비교와 수정 제안을 담은 코드 설명이며, 실행 로그나 크래시 증거는 아니다. 이미지의 재초기화 시 쓰레기 포인터 삭제 가능성과 동작 영향 없음이라는 주장은 현재 소스의 NULL 재설정·호출 경로를 고려한 검증을 대신하지 않는다.

## Repro

아래는 CUBRID 소스 저장소 최상위에서 기준 코드를 확인하는 절차다. 런타임 장애 재현 명령은 아니다.

```sh
pgbuf_source_commit=f6cac312310f39f46711693da157a08f0e725693

git show "$pgbuf_source_commit":src/storage/page_buffer.c | nl -ba | sed -n '721,729p;1581,1601p;1668,1718p;1826,1829p;1895,1939p;5765,5860p;13910,13995p'
git show "$pgbuf_source_commit":src/transaction/log_tran_table.c | nl -ba | sed -n '483,511p;587,594p'
git show "$pgbuf_source_commit":src/base/system_parameter.c | nl -ba | sed -n '6515,6519p;10235,10246p'
```

실행 검증은 미수행이며 다음을 제안한다. 시험용 주입 방법·빌드·설정과 산출물은 ANALYSIS에서 확정한다.

1. 서버 정상 초기화·종료와 가능한 재초기화 경로에서 각 mutex의 초기화·파괴 주소와 횟수를 기록한다. boot manager 재사용 여부도 함께 기록한다.
2. AOUT 이전의 배열 할당, AOUT `bufarray`, hash 포인터 배열, 각 `mht_create`, holder·quota 등 이후 할당의 실패를 구분해 주입한다. 원래 오류와 보조 함수·공통 종료·상위 호출자의 정리 순서를 수집한다. AOUT 경로는 유효 비율이 양수가 되는 조건부터 별도로 증명한다.
3. 서버의 `num_private_chains=0` 및 standalone에서 private 배열의 요청 크기와 결과를 확인한다. 크기 0에 NULL을 반환시키는 시험 조건을 다른 할당 실패와 구분한다.
4. 정리 뒤 포인터·개수 상태와 재시도 가능 여부를 확인한다. 도달하지 않은 초기화, 성공한 초기화, 이미 정리한 자원을 서로 구분해 검증한다.

## Expected Result

- `direct_victims`의 초기화 범위가 실제 대상과 일치한다.
- 정상 경로와 각 부분 실패 경로에서, 초기화하지 않았거나 이미 파괴한 mutex에 대한 파괴를 수행하지 않는다. 호출자까지 포함해 중복 정리가 안전하게 처리된다.
- private LRU가 0개이면 private 배열용 저장소가 없다는 이유만으로 초기화를 실패시키지 않는다. 다른 오류가 있으면 그 오류에 따라 실패한다.
- 실제 할당 실패의 진단 크기가 요청 크기와 일치하고, 정리 과정 때문에 최초 실패를 추적할 수 없게 되는 일이 없다.

## Actual Result

정적 검토에서 대상과 다른 `sizeof`, 조건부 AOUT 실패 경로의 중복 파괴, private 개수 0의 무조건 할당과 NULL 실패 판정을 확인했다. 공통 종료의 무조건 mutex 파괴와 상위 호출자의 추가 종료 경로도 확인했다. 실제 서버의 파괴 횟수, 오류 로그, 크래시 또는 지원 플랫폼에서의 기동 실패 결과는 아직 확보하지 않았다. 이전 빌드의 24/16바이트 기록을 현재 빌드의 출력으로 사용하지 않는다.

## Acceptance Criteria

- 세 기존 항목 각각에 대해 기준 소스와 수정 또는 유지 판단의 근거가 남아 있다. 초기화 대상 불일치와 빈 배열의 실패 판정이 해소되었는지 관찰할 수 있다.
- 서버에서 정상 종료, 초기화 전·중간 실패, 상위 호출자의 추가 정리를 포함한 검증으로 자원별 초기화·정리 횟수가 유효함을 확인한다. AOUT의 지원 경로 도달성과 시험용 주입 결과를 구분한다.
- private LRU 0개인 서버와 standalone에서 해당 빈 구성 때문에 초기화가 실패하지 않으며, 실제 할당 실패의 진단은 요청 크기와 일치한다.
- 재초기화와 boot manager 재사용 경로의 차이를 기록하고, 확인한 범위 및 미확인 출시 버전·플랫폼을 명시한다.

## Definition of done

ANALYSIS에서 확정한 범위의 변경과 함께, 서버·standalone의 정상 초기화/종료, 부분 실패 주입, private LRU 0개, 재초기화·boot manager 재사용 구분에 대한 검증 결과를 남긴다. 서버 mutex 수명은 주소별 초기화·파괴 기록으로 확인하고, 원래 실패와 정리 순서·최종 자원 상태를 함께 보관한다. AOUT의 지원 경로 검증과 시험용 주입을 구별하며, 실행하지 못한 조합은 그 이유와 영향 판단을 명시한다.

## Additional Information

이 작업은 페이지 버퍼 초기화·종료와 그 직접 호출자의 수명 경계를 담당한다. direct victim 대기 정책·긴급 배정 경로, private victim queue의 사용 정책, 페이지 flush 중 상태 복구는 별도 자식 이슈의 범위다. 실패 주입·관찰 방법은 CBRD-27423의 시험 프레임워크 조사와 공유할 수 있으나, 그 프레임워크의 완성을 이 수정의 필수 선행 조건으로 두지 않는다.

## Triage Request

초기화 대상 불일치, 빈 배열 처리와 자원 정리 수명 문제의 범위를 확인하고, 작성자 측에 ANALYSIS를 배정해 줄 것을 요청한다. ANALYSIS에서는 AOUT의 실제 도달 조건, 보조 함수와 상위 호출자를 포함한 정리 책임, 대상별 초기화 성공 여부, 지원 플랫폼별 영향과 필요한 검증 범위를 확정한다. 기존 JIRA의 Confirmed 상태는 현재 엔진에서 크래시를 재현했다는 증거로 사용하지 않는다.

[S1]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L717-L729
[S2]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L1593-L1601
[S3]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L5794-L5860
[S4]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L1668-L1718
[S5]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L1895-L1939
[S6]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L13910-L13933
[S7]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L13949-L13995
[S8]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L1978-L1991
[S9]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L3506-L3517
[S10]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L6515-L6519
[S11]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L10235-L10246
[S12]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14481-L14574
[S13]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L5774-L5788
[S14]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L5527-L5567
[S15]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_tran_table.c#L483-L511
[S16]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_tran_table.c#L587-L594
[S17]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L1617-L1637
[S18]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L5949-L5954
[S19]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L1820-L1829
[S20]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_manager.c#L1130-L1140
[S21]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L96-L103
[S22]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L816-L822
[S23]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L5868-L5876
[H1]: https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/pgbuf/e6ed61e_claude/09-issue-proposals.md#L72-L80
[S24]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L615-L625
[S25]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L1025-L1033
[S26]: https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L5706-L5724
[H2]: https://github.com/vimkim/my-cubrid-jira/blob/da39b0f3ee0bc1c55d2063588c3969a808a95687/issues/CBRD-27194-pgbuf-init-finalize-hygiene_e6ed61e_claude.md#L100-L158
[H3]: http://jira.cubrid.org/secure/attachment/1020015/image-2026-08-06-17-41-28-760.png
