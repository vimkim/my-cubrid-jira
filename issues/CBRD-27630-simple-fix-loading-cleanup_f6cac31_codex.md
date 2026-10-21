# [PGBUF] pgbuf_simple_fix 실패 정리가 다른 스레드의 로딩 기록을 삭제할 수 있다

## Issue Triage

**이슈 수행 목적**: 임시 페이지의 로딩 실패를 정리할 때 해당 호출의 로딩 기록만 해제하고, 다른 스레드가 새로 등록한 로딩 기록과 그 대기 관계를 보존한다.

**이슈 수행 이유**: CUBRID `f6cac312310f39f46711693da157a08f0e725693`에서 `pgbuf_claim_bcb_for_fix()`의 일부 실패 경로와 호출자 `pgbuf_simple_fix()`가 로딩 기록을 연속으로 정리한다. 제거 함수는 VPID만 비교하므로 두 정리 사이에 같은 페이지의 새 로딩 기록이 등록되면 그 기록을 삭제할 수 있다. 과거 리비전을 대상으로 한 Lean 모델에도 이 소유권 위반 반례가 있으나, 실제 엔진의 호출·실패·스케줄링 도달성은 미확인이다.

**영향**: 위 교차 실행이 실제로 가능하면 동일 임시 페이지의 로딩을 직렬화하는 보호가 깨져 여러 로더가 허용될 수 있다. 소스의 중복 정리와 소유자 검사 부재는 확인했으며, 실제 쿼리의 동일 VPID 동시 접근, 운영 장애, 중복 프레임 공개 및 데이터 손상은 확인하지 않았다. 적용 릴리스와 발생 빈도도 미확인이다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 소스에서 확인한 동작, 과거 모델 검증 기록, 조건부 추론과 미확인 사항을 구분한다.

## Description

### 무엇이 문제인가

`pgbuf_simple_fix()`는 임시 파일 페이지의 주소를 반환하는 읽기용 경로다. 일반 `pgbuf_fix()`와 달리 페이지 latch를 취득하지 않으며, 소스 경고는 페이지 내용의 동시 쓰기와 일반 FIX/LATCH와의 혼용을 제외한다. 여기서 VPID는 볼륨 번호와 페이지 번호의 쌍이며, BCB는 버퍼 슬롯의 제어 상태다. 반환 시 증가하는 `fcnt`는 사용 중인 슬롯의 재사용을 막는 fix 계수다. 페이지 latch나 트랜잭션 lock과 같은 의미가 아니다. [사용 조건과 miss 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2614-L2659), [resident 경로와 simple-unfix](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2673-L2724)

`need_fix=true`이고 페이지가 버퍼에 없으면 로딩 기록을 취득한 뒤 BCB를 확보하고 페이지를 읽는다. `need_fix=false`의 miss는 로딩하지 않고 `NULL`을 반환한다. 다만 resident hit에서는 이 값이 false여도 `fcnt`가 증가하므로 사용 종료 시 계수를 해제해야 한다. direct-victim으로 배정된 resident BCB는 false일 때 반환하지 않으며, true일 때는 해당 배정을 무효화하고 사용한다. [분기와 계수 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2631-L2699)

버퍼에 없는 같은 VPID의 로딩을 조정하는 기록은 `SERVER_MODE`의 `pgbuf_lock_page()`가 관리한다. 기존 기록을 찾으면 요청 스레드는 그 기록의 대기열에 들어가고, 기록이 없으면 현재 스레드의 `buf_lock_table[index]` 슬롯을 연결한 후 hash mutex를 해제한다. 이 로딩 기록은 페이지 내용 접근용 latch나 트랜잭션 lock과 별개다. [대기 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L7951-L7984), [스레드별 기록 등록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8039-L8052)

확인한 결함 구조는 helper가 로딩 기록을 해제한 뒤 호출자도 같은 VPID의 기록을 다시 해제한다는 점이다. 다음 세 경로에서는 helper의 정리 후 `NULL` 반환이 호출자의 두 번째 정리로 이어진다.

| helper 실패 조건 | helper의 첫 정리 | 호출자의 후속 동작 |
|---|---|---|
| `pgbuf_allocate_bcb()`가 `NULL` 반환 | [8430-8436행](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8430-L8436)에서 로딩 기록 제거 | `pgbuf_simple_fix()`의 [2649-2653행](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2649-L2653)에서 다시 제거 |
| `fileio_read()`가 `NULL` 반환 | [8477-8501행](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8477-L8501)에서 BCB를 invalid 목록으로 돌려보내고 기록 제거 | 같은 후속 정리 |
| TDE 복호화가 오류 반환 | [8504-8516행](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8504-L8516)에서 BCB를 invalid 목록으로 돌려보내고 기록 제거 | 같은 후속 정리 |

`pgbuf_unlock_page()`는 연결된 기록을 VPID로만 찾고 제거한다. 호출 스레드의 슬롯인지 검사하지 않는다. `need_hash_mutex=true`는 hash mutex 취득을 뜻하며 소유자 확인이 아니다. 첫 정리가 mutex를 해제한 뒤 다른 로더가 새 기록을 등록하면, 두 번째 정리는 이전 기록과 새 기록을 구별할 수 없다. 개별 호출의 mutex 보호만으로 두 호출 사이의 소유권 변경을 보호하지 못한다는 소스 기반 추론이다. [mutex 취득과 VPID 검색·제거](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8069-L8139)

### 왜 문제인가

로딩 기록은 아직 hash chain에 공개되지 않은 페이지를 다른 스레드도 로딩하는 일을 막는다. A의 실패 정리가 B의 새 기록을 제거하고 B가 공개하기 전에 C까지 진입할 수 있다면, B와 C의 로딩을 직렬화하던 근거가 사라진다. 이 소유권 위반과 두 로더의 허용은 아래 추상 모델에서 확인한 결과다. 실제 엔진에서 같은 교차 실행을 관측하거나 그 뒤의 페이지 공개·내용 손상을 확인한 결과는 아니다.

실제 호출 경로는 존재한다. 정렬 결과를 만드는 `qfile_put_next_sort_item()`가 원본 tuple 페이지를 참조할 때 `qmgr_get_old_page_simple_fix()`를 호출하고, query manager는 디스크 임시 페이지 경로에서 `pgbuf_simple_fix(..., true)`를 호출한다. `NULL_VOLID`의 메모리 임시 페이지 경로는 별도다. 이 호출 경로만으로 같은 임시 VPID를 여러 스레드가 동시에 읽는다고 결론내릴 수 없다. [정렬 호출자](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/query/list_file.c#L3834-L3878), [메모리/디스크 분기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/query/query_manager.c#L2775-L2817)

file manager의 두 직접 호출은 `need_fix=false`로 resident 페이지만 찾으므로 miss에서 이 로딩 실패 경로를 만들지 않는다. 따라서 모든 simple-fix 사용을 동일한 위험 경로로 세면 안 된다. [임시 페이지 정리 호출](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/file_manager.c#L4074-L4089), [table 페이지 정리 호출](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/file_manager.c#L4280-L4288)

### 왜 해결해야 하는가

실패 정리 후에는 해당 호출이 소유했던 기록의 정리가 끝나야 하며, 나중에 시작한 다른 호출의 기록을 변경해서는 안 된다. 현재 소스는 이 경계를 검사하지 않으며 모델 반례도 같은 빈틈을 지적한다. 소유권을 보장하지 않는 실패 경로를 남기면 오류 복구가 새 요청의 로딩 보호까지 훼손할 수 있다. 실제 적용 조건을 좁히고 정리 책임을 확정할 근거가 있으므로 분석과 필요한 수정을 진행할 가치가 있다.

검증된 운영 우회책은 없다. 동시 접근을 피하거나 simple-fix를 다른 API로 바꾸는 방법의 정확성·비용도 확인하지 않았다. 긴급도와 사용자 노출을 가정하기보다, 실제 호출 계약과 도달성을 확인하여 수정·회귀 검증 및 적용 버전을 결정해야 한다.

## Test Build

| 근거 | 식별 정보와 검증 범위 |
|---|---|
| 이번 소스 분석 | CUBRID `f6cac312310f39f46711693da157a08f0e725693`, 2026-10-21에 고정한 develop 기준이다. 위 행 번호는 이 커밋에 해당한다. 엔진 빌드나 SQL 재현은 수행하지 않았다. |
| 원 보고서의 엔진 기준 | CUBRID `ea57708a785e34b35a91e10cd0694839a53a4fe5`이다. 원 보고서는 소스 버전을 `11.5.0`으로 기록한다. 이것만으로 배포된 모든 11.5 릴리스의 영향을 확정하지 않는다. |
| 과거 모델 검증 기록 | 원 보고서는 2026-10-14, Linux, Lean `4.24.0`, Python 3에서 모델 빌드와 27개 정리의 공리 감사를 통과했다고 기록한다. 모델·문서는 `oos-lean-verification`의 `6bddfb23747d38deb780d45222a9df216bff0d17`에 고정한다. 이번 작성에서 모델을 다시 빌드하지 않았다. |
| 실제 엔진 재현 환경 | 빌드 번호, OS, 설정, 재현 SQL·실패 주입 방법·스케줄 제어는 TBD다. 동시 로딩 기록의 등록·제거·대기는 `SERVER_MODE` 경로를 대상으로 한다. |

과거 환경과 출력은 [원 보고서](https://github.com/vimkim/my-cubrid-jira/blob/da39b0f3ee0bc1c55d2063588c3969a808a95687/issues/CBRD-27630-pgbuf-simple-fix-load-ownership_ea57708_codex.md#L71-L125)에 기록되어 있다. 모델의 [provenance](https://github.com/vimkim/oos-lean-verification/blob/6bddfb23747d38deb780d45222a9df216bff0d17/proofs/pgbuf-simple-fix/source/provenance.json#L1-L26)는 과거 엔진 리비전과 소스 지문을 명시하고, 소스-모델 대응은 수동이며 기계적으로 검증하지 않았다고 밝힌다. 이번 분석에서도 해당 snapshot 지문과 제공된 고정 소스의 일치를 대조했다. 지문 일치는 모델이 엔진의 모든 실행을 표현한다는 증명이 아니다.

## Repro

### 모델에서 검증한 조건부 순서

시작 조건은 페이지가 hash chain에 없고 A가 해당 VPID의 로딩 기록을 소유하는 상태다. 다음은 실제 엔진의 관측 로그가 아니라 소스에서 추출한 로딩 프로토콜 모델의 실행 순서다.

| 순서 | 동작 | 모델의 기록과 로딩 상태 |
|---|---|---|
| 1 | A의 claim이 실패하고 helper가 첫 정리를 마친다. | A의 기록이 제거된다. |
| 2 | A의 후속 정리 전에 B가 같은 VPID의 로더가 된다. | B의 기록이 등록되고 B가 로딩 중이다. |
| 3 | A가 호출자의 두 번째 정리를 실행한다. | VPID가 같은 B의 기록이 제거되지만 B는 로딩 중이다. |
| 4 | B의 페이지 공개 전에 C도 같은 VPID의 로더가 된다. | B와 C가 로딩 중이며 기록의 소유자는 C다. |

`duplicate_cleanup_counterexample`와 `duplicate_cleanup_allows_two_loaders`는 각각 이 소유권 위반과 두 로더가 허용되는 상태를 모델 안에서 증명한다. 모델은 claim 실패와 B/C의 진입을 허용된 step으로 정의한다. 실제 allocator·I/O 오류의 발생, 엔진 스케줄러의 실행 가능성, query manager에서의 동일 VPID 동시 접근을 별도로 증명하지 않는다. 모델에는 페이지 내용의 동시 쓰기나 일반 FIX/LATCH 호출이 필요하지 않다. [모델 정의와 반례](https://github.com/vimkim/oos-lean-verification/blob/6bddfb23747d38deb780d45222a9df216bff0d17/proofs/pgbuf-simple-fix/Pgbuf/SimpleFix/LoadOwnership.lean#L18-L89), [문서가 명시한 검증 한계](https://github.com/vimkim/oos-lean-verification/blob/6bddfb23747d38deb780d45222a9df216bff0d17/docs/pgbuf-simple-fix.md#L116-L124)

### 과거 모델 검증을 다시 실행하는 명령

Git, Bash, Python 3, elan/Lake가 필요하다. 아래 명령은 Lean `4.24.0`에 고정된 모델과 소스 snapshot을 검사한다. 엔진 장애 재현 명령이 아니다.

```sh
git clone https://github.com/vimkim/oos-lean-verification.git
cd oos-lean-verification
git checkout 6bddfb23747d38deb780d45222a9df216bff0d17
./scripts/check-pgbuf.sh
```

고정된 [공리 감사 기록](https://github.com/vimkim/oos-lean-verification/blob/6bddfb23747d38deb780d45222a9df216bff0d17/proofs/pgbuf-simple-fix/axiom-audit.txt)은 27개 정리와 두 반례 정리의 감사 결과를 남긴다. 원 보고서는 다음 출력도 기록한다. 이는 이번 작성에서 새로 실행한 출력이 아니다.

```text
Build completed successfully (8 jobs).
'Pgbuf.SimpleFix.duplicate_cleanup_counterexample' does not depend on any axioms
'Pgbuf.SimpleFix.duplicate_cleanup_allows_two_loaders' does not depend on any axioms
Audited 27 theorems; only standard logical axioms permitted.
Bundled source snapshot checksum verified; correspondence remains manual.
```

과거 CUBRID 커밋을 포함한 clone이 있으면 소스 파일 지문과 snapshot 행 범위를 추가 검사할 수 있다. `/path/to/cubrid`는 그 clone 경로로 바꾼다. 이 검사도 `f6cac312`에 대한 형식 검증으로 확장되지 않는다.

```sh
python3 scripts/check-pgbuf-source.py --cubrid-repo /path/to/cubrid
```

원 보고서의 추가 검사 출력은 `Pinned source and helper files verified at ea57708a785e34b35a91e10cd0694839a53a4fe5.`이다. [검사 스크립트](https://github.com/vimkim/oos-lean-verification/blob/6bddfb23747d38deb780d45222a9df216bff0d17/scripts/check-pgbuf-source.py)

### 실제 엔진에서 확인할 조건

아래는 미실행 검증 계획이며, 최종 테스트 구성은 ANALYSIS에서 정한다.

1. 허용된 동일 임시 VPID 읽기 경로를 확인하고, A가 로딩 기록을 소유한 상태에서 claim 실패를 발생시킨다. 자연 발생 오류와 주입 오류를 구분한다.
2. A의 첫 정리 후 두 번째 정리 전을 제어하고, B가 같은 VPID의 기록을 등록한 뒤 페이지 공개 전에 멈추도록 한다.
3. A의 후속 정리 전후에 B의 기록과 대기열이 보존되는지 확인하고, C의 요청이 새 로더가 되는지 기록한다.
4. 성공 경로, `need_fix=false` miss/hit, 실제 도달 가능한 복호화 실패를 함께 검증하여 로딩 기록·BCB·mutex·fix 계수의 정리 책임을 확인한다.

할당 함수에는 victim 대기 중 interrupt 등으로 BCB 없이 반환할 수 있는 소스 경로가 있고, `fileio_read()`에는 읽기 오류의 `NULL` 반환이 있다. TDE 복호화도 오류 반환 인터페이스를 갖는다. 각 경로의 존재는 같은 임시 VPID의 동시 로딩과 결합된 자연 발생 재현을 뜻하지 않는다. [할당 실패 경로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8271-L8349), [파일 읽기 오류](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/file_io.c#L3962-L3986), [임시 키 선택과 복호화](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/tde.c#L1018-L1054)

## Expected Result

실패한 호출은 자신이 소유한 로딩 기록만 정리해야 한다. A의 기록이 이미 제거되고 B의 새 기록이 등록되었다면, A의 후속 정리가 B의 기록과 대기열을 보존해야 한다. 허용된 동일 VPID 동시 miss에서는 진행 중인 로더가 공개 또는 실패 정리를 마칠 때까지 후속 요청의 로딩이 직렬화되어야 한다.

## Actual Result

현재 고정 소스에서 세 helper 실패 경로의 첫 정리, simple-fix 호출자의 재정리, VPID만 사용하는 제거를 확인했다. 과거 Lean 모델에서는 위 조건부 순서의 소유권 위반과 두 로더의 허용을 검증했다. 실제 C++ 실행의 같은 스케줄, 중복 프레임 공개, 데이터 손상이나 운영 장애를 재현한 증거는 없다.

## Options for Analysis

다음은 미선택 후보이며, 현재 동작은 비교 기준이다.

| 후보 | 기대 효과 | 한계와 확인할 사항 |
|---|---|---|
| 현재 중복 정리 유지 | 다른 기록이 재등록되지 않으면 두 번째 제거는 대상이 없다. | 소유권이 바뀐 경우의 보호가 없으므로 동일 VPID 동시 접근이 불가능하다는 호출 계약과 근거가 필요하다. 현재 그 근거는 미확인이다. |
| helper/호출자 정리 책임을 정리하여 중복 제거 해소 | 문제의 후속 제거 자체를 없앨 수 있다. | 모든 helper 반환이 동일한 정리 상태라는 전제가 필요하다. 일반 fix와 simple-fix 및 예외 반환 경로를 함께 검토해야 한다. |
| 제거 시 호출자의 소유권 확인 | 다른 스레드가 등록한 기록을 보호할 수 있다. | 모델의 소유자 식별을 실제 스레드 슬롯·기록 수명에 대응시켜야 하며, 다른 호출자와 대기열 정리의 계약·비용은 미검증이다. |

중복 정리 해소는 호출 경계의 책임을 단순하게 만드는 방향이며, 소유권 확인은 제거 연산 자체의 조건을 강화하는 방향이다. 반환별 정리 계약과 실제 기록 수명 검토 결과로 선택해야 한다. Lean의 `proposed_owner_check_preserves_foreign_record`는 마지막 후보가 추상 모델에서 외부 소유 기록을 보존한다는 성질만 증명하며, 채택된 설계나 엔진 수정 검증이 아니다. [후보 모델과 정리](https://github.com/vimkim/oos-lean-verification/blob/6bddfb23747d38deb780d45222a9df216bff0d17/proofs/pgbuf-simple-fix/Pgbuf/SimpleFix/LoadOwnership.lean#L91-L99)

## Additional Information

일반 `pgbuf_fix()`도 같은 claim helper를 호출하지만, 해당 위치에서 `NULL`을 받으면 retry를 판단하거나 반환하며 같은 후속 unlock을 하지 않는다. helper 호출자는 현재 이 일반 fix와 simple-fix 두 곳이다. 동일 helper의 변경이 일반 fix의 정리 계약을 훼손하지 않아야 한다. [일반 fix의 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2319-L2329)

별도 `dwb_read_page()` 오류 분기는 helper가 직접 반환하여 정리 상태를 점검할 필요가 있으나, 고정 소스의 `dwb_read_page()`는 모든 정상 반환에서 `NO_ERROR`를 반환한다. 이 이슈의 중복 정리 반례는 그 방어 분기의 도달성에 의존하지 않는다. [helper의 방어 분기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8467-L8471), [DWB read 본문](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L3979-L4015)

[CBRD-27262](https://jira.cubrid.org/browse/CBRD-27262)의 flush 준비 실패 복구와는 같은 TDE/DWB 이름을 사용해도 소유 상태와 발생 단계가 다르다. 이 작업은 로딩 기록의 정리 소유권을 담당하며, 해당 flush 수정이나 DWB read 오류 발생을 선행 조건으로 두지 않는다. 페이지 내용 일관성, 전체 C++ 메모리·동시성 의미론, 종료성 및 버퍼 풀 전체 정확성은 이 모델의 증명 범위가 아니다. [모델의 계약과 검증 경계](https://github.com/vimkim/oos-lean-verification/blob/6bddfb23747d38deb780d45222a9df216bff0d17/docs/pgbuf-simple-fix.md#L57-L98)

## Acceptance Criteria

- 실제 호출 계약과 동일 임시 VPID 동시 접근·claim 실패의 도달성을 근거로 설명하고, 미도달로 판단하는 조건도 명시한다. 엔진 관측, 오류 주입, 모델 결과를 구별한다.
- 허용된 경로의 실패 정리가 다른 호출의 로딩 기록과 대기열을 변경하지 않음을 검증한다. 해당 교차 실행이 가능하면 이를 통제하는 엔진 회귀 증거를 남긴다.
- helper/호출자의 반환별 정리 책임과 성공·실패 후 기록, BCB, mutex 및 fix 계수 상태를 설명한다. 영향을 받는 리비전·릴리스와 후속 조치의 범위를 결정한다.

## Definition of done

반환 경로별 로딩 기록·BCB·mutex·fix 계수의 정리 계약을 검토하고, 허용된 호출에서 문제의 교차 실행에 도달할 수 있는지 근거와 함께 결정한다. 그 결정에 맞는 소스 검토, 모델 검사 또는 엔진 회귀 검증 증거를 남긴다. 해당 경로가 적용되지 않으면 그 조건과 제외 근거를 완료 증거로 기록한다.

## Triage Request

부모 [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)의 하위 작업으로 로딩 기록의 소유권과 실패 정리 문제를 확인하고, 작성자 측에 ANALYSIS를 배정할 것을 요청한다. 구현 선택에 앞서 다음 질문을 해소한다.

- 허용된 읽기 전용 호출 계약 안에서 같은 임시 VPID에 대한 동시 cold miss가 실제로 가능한가. 가능하다면 어떤 쿼리·병렬 실행 경로인가.
- 할당·파일 읽기·복호화 실패 중 어떤 것이 그 경로에서 발생하여 호출자까지 반환할 수 있는가. 정상 환경의 오류, 오류 주입, 비정상 입력을 구별한다.
- helper의 모든 반환 경로와 일반 fix/simple-fix 호출자 사이에서 누가 로딩 기록·BCB·mutex를 정리해야 하는가.
- 결함 유입 리비전, 적용 릴리스·패치 범위와 실제 장애 여부는 무엇인가.
