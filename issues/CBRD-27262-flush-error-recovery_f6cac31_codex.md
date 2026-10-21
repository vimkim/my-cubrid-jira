# [PGBUF] flush 준비 오류 후 페이지 버퍼 상태와 대기자의 진행을 복구한다

## Issue Triage

**이슈 수행 목적**: 페이지 flush 준비가 실패해도 BCB의 dirty/flushing 상태와 아직 반영되지 않은 변경의 추적 정보를 일관되게 유지하고, 후속 flush와 대기자가 진행할 수 있게 한다.

**이슈 수행 이유**: 기준 소스에서 `pgbuf_bcb_mark_is_flushing` 이후 TDE 암호화 또는 DWB 준비 함수가 오류를 반환하면, 정규 write 실패 경로의 상태 복구를 거치지 않고 반환한다. 오류 분기의 실제 도달 조건과 단계별 정리 책임을 확인할 필요가 있다.

**영향**: 해당 오류 반환이 발생하면 flush를 수행할 주체가 사라졌는데도 BCB가 flushing 상태로 남을 수 있다. 이 상태는 교체 후보 제외와 후속 동기 flush의 완료 대기 위험으로 이어진다. 과거 이슈 본문은 오류 주입 후 checkpoint와 서버 종료 대기를 보고하지만, 현재 기준 빌드의 실행 결과와 운영 발생 빈도, 고객 장애 및 데이터 유실은 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

페이지 버퍼는 디스크 페이지를 메모리에 보관하고 접근, 교체 및 flush를 관리한다. BCB(Buffer Control Block)는 버퍼 슬롯의 페이지 식별자와 사용 수, latch, dirty/flushing 상태 등을 관리하는 제어 정보이다. VPID는 볼륨 번호와 페이지 번호로 이루어진 페이지 식별자이다. fix/unfix는 페이지의 메모리 상주 사용을 획득하고 해제하는 절차이며, page latch는 메모리 페이지의 짧은 접근을 조정한다. 트랜잭션 lock과는 책임이 다르다. 이 이슈의 `PGBUF_LATCH_FLUSH`는 일반적인 READ/WRITE page latch가 아니라 flush 완료를 기다리는 내부 대기 모드이다.

분석 기준은 CUBRID commit `f6cac312310f39f46711693da157a08f0e725693`이다. 이 기준의 `pgbuf_bcb_flush_with_wal`은 BCB mutex를 보유한 상태에서 `pgbuf_bcb_mark_is_flushing`을 호출한다. dirty 페이지이면 flushing을 켜면서 dirty를 끈다. flush 중 추가 변경을 별도로 추적하기 위한 전이이다. 이후 다음 두 오류 반환은 정규 write 실패 정리를 거치지 않는다. [flush 준비 코드](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10701-L10785), [플래그 전이](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L16025-L16074)

| 단계 | 현재 오류 처리 | 필요한 결과 |
|---|---|---|
| TDE 데이터 페이지 암호화 | `tde_encrypt_data_page`의 오류를 바로 반환한다. | 실패한 flush가 flushing 상태의 소유자로 남지 않고 변경 추적이 유지되어야 한다. |
| DWB 쓰기 준비 | `dwb_set_data_on_next_slot`의 오류를 바로 반환한다. | 오류 반환과 슬롯을 즉시 얻지 못한 정상 반환을 구분하고, 실제 오류에는 상태 복구가 이루어져야 한다. |
| 이후 `dwb_add_page` 또는 `fileio_write` 실패 | BCB mutex를 다시 획득하고 dirty/flushing, 저장한 `oldest_unflush_lsa`, flush 대기자를 처리한다. | 준비 실패에도 단계에 맞는 일관된 실패 처리가 필요하다. |

TDE는 데이터 페이지 암호화이며, DWB(Double Write Buffer)는 데이터 페이지의 부분 쓰기에 대비하는 별도 쓰기 버퍼이다. 이 둘의 오류 가능성을 동일하게 해석하면 안 된다. TDE 함수에는 암호화 상태 미로딩 오류와 암호화 context 초기화 또는 암호화 연산 실패의 반환 경로가 있다. 이 경로가 실제 DB 작업에서 발생하는 조건과 빈도는 미확인이다. [TDE 진입 함수](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/tde.c#L965-L1005), [암호화 실패 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/tde.c#L1220-L1300)

DWB 준비 호출의 `can_wait`는 `false`이다. 슬롯이 사용 중이거나 구조 변경 중이라 즉시 얻을 수 없는 경우는 `NO_ERROR`와 NULL 슬롯으로 돌아오므로, 단순 슬롯 부족을 이 결함의 오류 발생 조건으로 제시하지 않는다. 이 호출 경로에서 확인한 비정상 반환은 DWB가 생성되지 않았는데 블록 쓰기 진행 비트가 남아 있는 경우의 `ER_DWB_DISABLED`이다. 정상적인 구조 변경 및 종료 순서에서 그 상태에 도달할 수 있는지는 ANALYSIS에서 검증해야 한다. 오류 반환 시점까지 슬롯 출력은 NULL이며, 슬롯 할당 뒤에는 이 준비 함수에서 오류를 반환하는 코드가 없다. [슬롯 획득의 분기와 출력](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L2469-L2600), [준비 함수](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L2687-L2711)

`oldest_unflush_lsa`는 아직 flush되지 않은 변경을 추적하는 가장 오래된 로그 위치이다. 첫 준비 시도에서는 두 오류 분기가 이 값을 지역 변수로 저장하고 BCB의 값을 NULL로 만드는 처리보다 앞선다. 따라서 이 경우에는 값이 그대로이며, 무조건 LSA 복원을 추가하라는 요구는 맞지 않는다. 다만 `dwb_add_page`가 성공하면서 슬롯이 NULL이면, 함수는 이미 LSA를 저장하고 BCB의 값을 NULL로 만든 뒤 BCB mutex를 다시 잡아 `start_copy_page`로 재진입한다. 이 재시도의 TDE 오류는 첫 준비 시도와 상태가 다를 수 있다. 정리 책임은 이 단계 차이를 포함해 확인해야 한다. [LSA 이동과 재시도](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10782-L10828), [정규 write 실패 정리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10852-L10866)

### 왜 문제인가

오류 코드가 호출자에게 전달되는 것만으로 flush 상태가 정리되지는 않는다. 첫 준비 시도에서 원래 dirty였던 페이지가 이 오류 반환을 통과하면, 함수는 dirty를 끄고 flushing을 켠 상태를 되돌리지 않는다. 첫 시도의 `oldest_unflush_lsa`는 그대로이다. flushing 플래그가 켜진 BCB는 victim, 즉 다른 페이지를 담기 위해 재사용할 교체 후보에서 제외된다. BCB mutex는 `is_bcb_locked`를 확인하는 호출자나 safe-flush 래퍼에서 해제하므로, 이 쓰기 준비 문제를 mutex 영구 보유와 동일시하지 않는다. [교체 제외 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L253-L262), [flush 호출자의 mutex 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L4007-L4023), [safe-flush 래퍼](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8718-L8760)

후속 동기 flush의 위험에는 추가 조건이 있다. `pgbuf_bcb_safe_flush_internal`은 dirty가 꺼져 있으면 즉시 성공 반환한다. 이후 페이지가 다시 dirty가 되고 flushing이 남아 있으면 동기 요청자는 `PGBUF_LATCH_FLUSH` 대기로 진입할 수 있다. 이 대기는 일반 READ/WRITE 대기의 timed sleep을 사용하지 않으며, 별도의 interrupt 처리 경로는 존재한다. 따라서 소스로 확인한 것은 정상 flush 완료 통지가 사라진 상태에서 기한 없는 대기가 가능한 제어 흐름이다. 현재 빌드의 무한 정지를 실행으로 입증한 것은 아니다. [동기 flush의 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8786-L8851), [flush 대기와 interrupt 정리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L7055-L7115)

checkpoint는 해당 페이지를 대상으로 선정한 뒤 동기 safe-flush를 호출한다. 서버 종료의 `log_final`도 `pgbuf_flush_all`을 호출하며, 이 경로는 dirty 페이지를 동기 flush한다. 그러므로 오류 후 상태가 남고 후속 접근 조건까지 충족되면 checkpoint나 종료 진행을 막을 위험이 있다. 종료 때 checkpoint를 항상 호출한다는 설명은 부정확하며, `log_final`의 checkpoint 호출에는 별도 조건이 있다. 재수정, 대상 선정 및 대기 해제 여부까지 포함한 현재 실행 검증이 필요하다. [checkpoint의 동기 flush](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L4454-L4484), [전체 flush](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L3583-L3639), [종료 시 flush와 조건부 checkpoint](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/transaction/log_manager.c#L1864-L1892)

dirty, LSA 및 flush 완료는 트랜잭션 commit이나 영구 디스크 반영과 같은 의미가 아니다. 현재 확인한 정리 누락만으로 데이터 유실 또는 복구 실패를 확정하지 않는다. 영향을 판단하려면 실패 전후 페이지 이미지, 로그 위치, 실제 쓰기와 재시작 결과를 함께 확인해야 한다.

### 왜 해결해야 하는가

복구 가능한 준비 오류가 오류 반환 이후에도 페이지 버퍼의 진행을 막는 상태로 남으면, 호출자는 실패를 처리해도 같은 페이지를 다시 flush할 수 없을 수 있다. 운영자는 원래 암호화 또는 DWB 오류와 나중의 flush 대기를 별개 장애로 추적해야 하므로 진단과 복구가 어려워진다. 단순 재시도는 flushing이 남은 상태를 해결한다는 근거가 없다. 실패 이후에도 변경 추적과 완료 통지의 책임이 남지 않도록 확인하고, 필요한 복구를 검증할 가치가 있다. 운영 발생 빈도와 긴급성은 아직 확정하지 않는다.

이 작업은 [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)의 하위 작업이며, flush 준비 실패의 상태 복구가 주된 완료 경계이다. 상태 복구 코드를 어디에 모을지와 함수 변경 범위는 ANALYSIS에서 결정한다. 일반적인 flush 대기 timeout 정책 변경은 이 이슈의 선결 조건으로 두지 않는다.

## Test Build

| 구분 | 확인 범위 |
|---|---|
| 현재 소스 검토 | CUBRID `f6cac312310f39f46711693da157a08f0e725693`의 고정 소스를 검토한다. 이 보고서 작성 중 엔진 빌드와 실행은 수행하지 않았다. |
| 과거 이슈의 보고 | [기존 CBRD-27262 본문](https://github.com/vimkim/my-cubrid-jira/blob/da39b0f3ee0bc1c55d2063588c3969a808a95687/issues/CBRD-27262-pgbuf-flush-error-bcb-recovery_e6ed61e_claude.md)은 develop `e6ed61e87`, Linux x86_64 debug 빌드에서 DWB 호출 직전 일회성 오류 주입을 사용했다고 기술한다. |
| 과거 증거의 한계 | 현재 확보한 이슈 본문에는 원시 로그, backtrace 및 실제 빌드 산출물의 식별 정보가 첨부되어 있지 않다. 과거 설정 표기의 `double_write_buffer_size = 2M`도 해당 실행 환경에서 수용되었는지 재확인해야 한다. |
| 릴리스 영향 | 지원 릴리스별 포함 여부, 자연 발생 사례 및 운영 노출 범위는 TBD이다. |

## Repro

현재 소스 검토는 다음과 같이 같은 revision을 별도 소스 checkout에 준비하여 확인할 수 있다.

```sh
git clone https://github.com/CUBRID/cubrid.git cubrid-27262-review
cd cubrid-27262-review
git checkout --detach f6cac312310f39f46711693da157a08f0e725693
rg -n 'pgbuf_bcb_mark_is_flushing|tde_encrypt_data_page|dwb_set_data_on_next_slot|copy_unflushed_lsa|pgbuf_bcb_mark_was_not_flushed' src/storage/page_buffer.c
rg -n 'can_wait == false|ER_DWB_DISABLED|dwb_read_page' src/storage/double_write_buffer.cpp
```

다음은 **미실행 검증안**이며, 이미 수행한 재현 절차로 해석하지 않는다. 오류 주입용 코드와 자동 판정 도구는 아직 준비되지 않았다.

1. 동일 revision의 격리된 시험 DB와 debug/release 빌드를 준비한다. 프로젝트 빌드 명령은 `./build.sh -m debug` 및 `./build.sh -m release`를 사용한다. 해당 빌드의 TDE와 DWB 설정, 페이지 크기 및 실행 환경을 기록한다.
2. 특정 VPID의 dirty 페이지를 대상으로 TDE 오류와 DWB 준비의 비정상 반환을 각각 한 번만 통제해 발생시킨다. 실제 오류 반환 경로와 호출 직전 강제 반환 실험을 구별한다. 첫 준비와 DWB 비활성화 후 재시도 경로를 분리한다.
3. 오류 직후 BCB의 dirty/flushing, `oldest_unflush_lsa`, mutex 보유 여부, DWB 슬롯 출력 및 오류 전달을 기록한다. 정상 진행 중인 flush도 dirty가 꺼지고 flushing이 켜질 수 있으므로, 플래그 조합 하나만으로 누수라고 판정하지 않는다.
4. 오류 복구 후 재flush 가능 여부를 확인한다. 같은 페이지의 후속 변경, 동기 flush 대기자 및 checkpoint/종료의 완료를 제한 시간과 thread stack으로 확인한다. 완료 로그가 없다는 사실만으로 hang이라고 판정하지 않는다.
5. 오류 없는 flush와 일반 write 실패를 대조한다. dirty 페이지뿐 아니라 원래 clean인 페이지를 flush하는 호출과 재시도 도중 실패도 포함해, 새 변경의 dirty 상태와 로그 추적을 훼손하지 않는지 확인한다.

## Expected Result

- 준비 실패가 호출자에게 전달된 뒤, 실제 작업이 없는 flushing 상태가 남지 않아야 한다. 원래 미반영 변경과 flush 중 추가 변경의 추적이 보존되어야 한다.
- 첫 준비와 재시도의 LSA 이동 여부에 맞게 상태가 유지 또는 복구되고, 오류를 제거하면 같은 페이지의 후속 flush가 완료되어야 한다.
- flush 대기자는 정한 실패 처리 계약에 따라 진행하거나 오류를 받아야 하며, 실패한 시도의 완료 통지를 기한 없이 기다리지 않아야 한다.
- 해당 실패를 포함하는 checkpoint/종료 시험과 오류 없는 flush 대조 시험의 관찰 결과를 제시해야 한다. 최종 판정 시간과 시험 구성은 ANALYSIS에서 정한다.

## Actual Result

현재 확인한 결과는 소스의 제어 흐름이다. TDE/DWB 준비의 두 오류 반환은 dirty/flushing 복구를 호출하지 않으며, 정규 write 실패는 상태 복구와 flush 대기자 기상을 수행한다. 첫 준비 시도의 LSA는 아직 옮기지 않았고, DWB 비활성화 후 재시도는 다른 단계에서 시작한다.

기존 이슈 본문은 `e6ed61e87` 오류 주입 후 flushing 잔존, 같은 페이지 재수정 후 checkpoint 대기와 서버 종료 미완료를 보고한다. 이는 과거 본문의 보고로 보존한다. 현재 기준에서 독립 재현한 관측이나 실제 고객 장애 증거로 제시하지 않는다.

## Additional Information

### 기존 읽기 실패 정리 주장의 범위

기존 본문은 `pgbuf_claim_bcb_for_fix`의 `dwb_read_page` 실패 시 BCB와 페이지 로딩 기록 정리가 없다는 N2 항목을 함께 다룬다. 호출부의 오류 분기에는 `assert(false)`와 바로 반환하는 코드가 있으며, 인접한 `fileio_read` 및 TDE 복호화 실패는 BCB를 invalid list로 돌려보내고 페이지 로딩 기록을 해제한다. 그러나 현재 `dwb_read_page`의 모든 정상 반환은 `NO_ERROR`이므로 이 분기는 운영 오류로 도달했다고 입증되지 않았다. 이를 release 빌드의 실제 mutex 영구 잠금이나 현재 서버 정지로 표현하지 않는다. 방어 경로를 유지하며 정리할지, 불가능한 오류 계약을 정리할지는 ANALYSIS 판단 사항이다. [읽기 실패 호출부](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8430-L8517), [DWB 읽기의 전체 구현](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L3979-L4015)

이 읽기 경로를 변경한다면 `pgbuf_fix`와 `pgbuf_simple_fix`의 오류 정리 책임을 함께 확인해야 한다. 두 API는 같은 claim 함수를 사용하지만, `pgbuf_simple_fix` 호출자는 NULL 반환 뒤에도 `pgbuf_unlock_page`를 호출한다. 인접 오류 정리를 그대로 복사하면 중복 정리 문제가 생길 수 있으므로 [CBRD-27630](https://jira.cubrid.org/browse/CBRD-27630)의 로딩 기록 소유권 분석과 조율한다. 이 조율은 주된 flush 준비 오류 복구의 완료를 기다리게 하는 필수 선행 관계를 뜻하지 않는다. [일반 fix 호출부](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2317-L2329), [simple-fix 호출부](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2644-L2656)

### 분석 이력과 남은 질문

과거 [오류 복구 제안 P2](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/pgbuf/e6ed61e_claude/09-issue-proposals.md#p2-flush-조기-실패-경로에서-flushing-플래그-미복구로-hang-가능)는 `e6ed61e87` 소스의 비대칭과 오류 주입 검증안을 제시한다. 이 제안 자체는 구현 합의나 현재 운영 재현 증거가 아니다.

ANALYSIS에서는 TDE 오류의 지원 환경 도달 조건, 비대기 DWB 호출의 `ER_DWB_DISABLED` 도달성, 첫 준비와 재시도의 상태 소유권, 이미 대기 중인 요청과 오류 후 새 요청의 진행을 구분한다. 복구 주체는 flush 수행 스레드 외에 성공 후 post-flush 처리로 이관될 수도 있으므로, 특정 두 함수가 항상 원래 수행 스레드에서만 호출된다는 전제는 사용하지 않는다. [성공 후 이관](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10871-L10895), [post-flush 정리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L15494-L15503)

## Triage Request

triage 담당자에게 현재 Confirmed인 본 하위 작업의 문제와 범위를 재확인하고, 작성자 측에 ANALYSIS를 배정할 것을 요청한다. 분석 결과에는 실제 도달 가능한 오류와 주입 전용 실패의 구분, 단계별 복구 계약, 검증 결과 및 N2 방어 분기의 처리 결정을 포함한다. 우선순위와 최종 구현 범위는 triage 및 ANALYSIS에서 결정한다.
