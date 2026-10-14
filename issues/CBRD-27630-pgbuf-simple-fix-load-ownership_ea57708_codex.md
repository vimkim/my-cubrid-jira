# [PGBUF] pgbuf_simple_fix 실패 후 중복 정리가 다른 스레드의 로딩 기록을 삭제할 수 있다

## Issue Triage

**이슈 수행 목적**: 임시 페이지의 로딩 실패를 정리할 때 해당 호출이 소유한 기록만 해제하고, 다른 스레드의 진행 중인 로딩을 보호한다.

**이슈 수행 이유**: develop `ea57708a785e34b35a91e10cd0694839a53a4fe5`에서 `pgbuf_claim_bcb_for_fix()`가 실패 시 로딩 기록을 해제한 뒤 `pgbuf_simple_fix()`가 같은 정리를 다시 호출한다. 삭제 함수는 페이지 식별자만 비교하므로 두 호출 사이에 다른 스레드가 등록한 기록을 삭제할 수 있다. 이 순서는 소스에서 확인했으며, 소스의 동작을 반영한 Lean 모델에서 소유권 위반 반례를 검증했다.

**영향**: 다른 스레드의 로딩 기록이 사라지면 동일 임시 페이지를 여러 스레드가 동시에 읽어들이는 상황이 허용된다. 같은 페이지의 로딩을 직렬화하는 보호가 깨진다. 실제 쿼리에서의 동시 호출·실패 경로 도달과 운영 장애, 데이터 손상은 아직 재현하거나 확인하지 않았다.

**이슈 수행 방안**: TBD - 합의 미확인. helper와 호출자의 실패 정리 책임을 점검하고, 중복 정리 제거 또는 소유자 확인을 수정 후보로 검토한다. 실제 C++ 실패·스케줄링 경로를 재현하고 다른 스레드의 기록이 보존되는 회귀 검증을 추가한다.

---

## AI-Generated Context

> 아래는 AI가 코드와 맥락을 분석해 작성한 상세 자료다.

## Description

`pgbuf_simple_fix()`는 임시 파일의 페이지를 페이지 버퍼에서 찾아 반환하는 함수다. 페이지가 없고 `need_fix=true`이면 메모리 프레임을 확보하고 페이지를 읽어들인다. 반환한 페이지에는 사용 중임을 나타내는 pin을 추가해 호출자가 사용하는 동안 프레임이 재사용되지 않도록 한다. 함수의 원래 사용 조건은 임시 페이지 읽기이며, 페이지 내용의 동시 쓰기나 일반 FIX/LATCH와의 혼용은 제외한다.

아직 메모리에 없는 페이지는 여러 스레드가 동시에 요청할 수 있다. 이를 직렬화하기 위해 `pgbuf_lock_page()`는 VPID별 로딩 기록을 등록한다. VPID는 볼륨 번호와 페이지 번호로 구성된 페이지 식별자다. 같은 VPID의 기록을 발견한 다른 스레드는 로더가 되지 않고 대기한다. 로더는 페이지를 해시 체인에 공개하거나 실패를 정리한 뒤 `pgbuf_unlock_page()`로 기록을 제거한다.

확인한 문제는 실패 정리가 두 곳에서 실행되지만, 삭제 대상의 소유권은 확인하지 않는다는 점이다. `pgbuf_claim_bcb_for_fix()`는 버퍼 할당 실패, 파일 읽기 실패, TDE 복호화 실패에서 로딩 기록을 제거하고 `NULL`을 반환한다. 호출자인 `pgbuf_simple_fix()`는 이 `NULL`을 받아 `pgbuf_unlock_page()`를 다시 호출한다.

첫 번째 정리에서 hash mutex가 해제된 뒤 다른 스레드가 동일 VPID의 기록을 등록할 수 있다. 두 번째 정리는 기존 기록과 새 기록을 구별하지 않으므로 새 로더의 기록을 제거할 수 있다. 각 등록·삭제 작업이 mutex로 보호되어도 두 호출 사이의 소유권 변경은 막지 못한다.

분석 기준은 CUBRID `VERSION=11.5.0`, develop 리비전 `ea57708a785e34b35a91e10cd0694839a53a4fe5`다. 적용되는 정확한 릴리스·패치 범위와 결함 유입 리비전은 TBD다. 기록의 등록·삭제와 대기열 처리는 `SERVER_MODE` 조건부 코드이며, 이 보고서는 해당 동시 실행 경로를 대상으로 한다.

### 중복 정리가 실행되는 코드

버퍼 할당 실패 경로는 helper에서 먼저 로딩 기록을 정리한다. [page_buffer.c:8418-8425](https://github.com/CUBRID/cubrid/blob/ea57708a785e34b35a91e10cd0694839a53a4fe5/src/storage/page_buffer.c#L8418-L8425)

```c
bufptr = pgbuf_allocate_bcb (thread_p, vpid);
if (bufptr == NULL)
  {
    ASSERT_ERROR ();
    (void) pgbuf_unlock_page (thread_p, hash_anchor, vpid, true);
    PGBUF_BCB_CHECK_MUTEX_LEAKS ();
    return NULL;
  }
```

호출자는 helper의 실패 후 다시 정리한다. [page_buffer.c:2626-2631](https://github.com/CUBRID/cubrid/blob/ea57708a785e34b35a91e10cd0694839a53a4fe5/src/storage/page_buffer.c#L2626-L2631)

```c
bufptr = pgbuf_claim_bcb_for_fix (thread_p, vpid, OLD_PAGE, hash_anchor, NULL, &retry, true);
if (bufptr == NULL)
  {
    (void) pgbuf_unlock_page (thread_p, hash_anchor, vpid, true);
    return NULL;
  }
```

같은 중복 정리로 이어지는 helper의 실패 경로는 다음과 같다.

| 실패 원인 | helper 내부의 정리 | 호출자의 재정리 |
|---|---|---|
| 버퍼 할당 실패 | `page_buffer.c:8422` | `page_buffer.c:2629` |
| 파일 읽기 실패 | `page_buffer.c:8479` | `page_buffer.c:2629` |
| TDE 복호화 실패 | `page_buffer.c:8502` | `page_buffer.c:2629` |

### 등록은 스레드별 슬롯을 사용하지만 삭제는 VPID만 확인한다

`pgbuf_lock_page()`는 `pgbuf_Pool.buf_lock_table[cur_thrd_entry->index]`를 사용해 현재 스레드의 기록을 등록한다. [등록 코드](https://github.com/CUBRID/cubrid/blob/ea57708a785e34b35a91e10cd0694839a53a4fe5/src/storage/page_buffer.c#L8027-L8036)

반면 `pgbuf_unlock_page()`는 연결 리스트를 순회하면서 `VPID_EQ(&cur_buffer_lock->vpid, vpid)`만 비교한다. 일치하는 기록을 찾으면 리스트에서 제거하고 대기자들을 깨운다. 호출한 스레드의 슬롯과 같은 기록인지 확인하는 비교는 없다. 마지막 인자인 `need_hash_mutex=true`는 hash mutex를 획득하라는 뜻이며, 소유권 검사를 의미하지 않는다. [검색·제거 코드](https://github.com/CUBRID/cubrid/blob/ea57708a785e34b35a91e10cd0694839a53a4fe5/src/storage/page_buffer.c#L8068-L8127)

## Test Build

- 분석 대상: CUBRID `11.5.0` 소스, develop `ea57708a785e34b35a91e10cd0694839a53a4fe5`.
- 조건: `SERVER_MODE`, 같은 임시 VPID에 대한 로딩 경로와 실패 정리의 교차 실행.
- 실제 엔진 재현 빌드·운영체제·빌드 번호: TBD. 이번 보고서를 위해 엔진을 빌드하거나 쿼리를 실행하지 않았다.
- 모델 검증 환경: Linux, Lean `4.24.0`, Python 3. 검증일은 2026-10-14다.
- 모델·문서 기준 리비전: `oos-lean-verification`의 `6bddfb23747d38deb780d45222a9df216bff0d17`.
- 관련 소스와 helper 파일의 고정 리비전 지문 검증, 모델 빌드 및 27개 정리의 공리 감사가 통과했다. 이는 C++ 실행 재현 결과를 의미하지 않는다.

## Repro

### 확인한 교차 실행 순서

페이지가 아직 해시 체인에 공개되지 않았고, 스레드 A가 해당 VPID의 로딩 기록을 소유한 상태에서 시작한다.

| 순서 | 스레드 동작 | 해당 VPID의 로딩 기록 |
|---|---|---|
| 1 | A의 claim이 실패한다. helper가 `pgbuf_unlock_page(..., true)`를 호출하고 `NULL`을 반환한다. | A의 기록이 제거된다. |
| 2 | A가 호출자의 두 번째 정리를 실행하기 전에 B가 같은 페이지를 요청한다. B는 `pgbuf_lock_page()`에서 로더가 되어 페이지를 읽기 시작한다. | B의 기록이 등록된다. |
| 3 | A가 `pgbuf_simple_fix()`의 2629행에서 두 번째 정리를 실행한다. | VPID만 일치하는 B의 기록이 제거된다. B는 아직 로딩 중이다. |
| 4 | B가 페이지를 공개하기 전에 C가 같은 페이지를 요청한다. | 기록이 없으므로 C도 로더가 된다. B와 C가 동시에 로딩 중인 상태가 허용된다. |

필요한 조건은 실제로 발생 가능한 claim 실패와, 같은 임시 페이지를 요청하는 스레드들의 교차 실행이다. 모델 반례에는 페이지 내용의 동시 쓰기나 일반 FIX/LATCH 호출이 필요하지 않다. `need_fix=false`의 miss는 로딩하지 않으므로 반례의 최초 로더 진입에 사용하지 않는다.

### Lean 모델 검증 명령

이 명령은 모델의 소유권 위반을 검증한다. 실제 엔진에서 장애를 재현하는 명령은 아니다. Git, Bash, Python 3, elan/Lake가 필요하며 패키지는 Lean 4.24.0을 고정한다.

```sh
git clone https://github.com/vimkim/oos-lean-verification.git
cd oos-lean-verification
git checkout 6bddfb23747d38deb780d45222a9df216bff0d17
./scripts/check-pgbuf.sh
```

확인한 출력은 다음과 같다.

```text
Build completed successfully (8 jobs).
'Pgbuf.SimpleFix.duplicate_cleanup_counterexample' does not depend on any axioms
'Pgbuf.SimpleFix.duplicate_cleanup_allows_two_loaders' does not depend on any axioms
Audited 27 theorems; only standard logical axioms permitted.
Bundled source snapshot checksum verified; correspondence remains manual.
```

소스의 고정 리비전도 Git 객체로 대조한다. CUBRID clone이 해당 리비전을 포함해야 한다.

```sh
python3 scripts/check-pgbuf-source.py --cubrid-repo /path/to/cubrid
```

`/path/to/cubrid`는 CUBRID 저장소 경로로 바꾼다. 확인한 출력은 다음과 같다.

```text
Pinned source and helper files verified at ea57708a785e34b35a91e10cd0694839a53a4fe5.
```

### 실제 C++ 재현 상태와 후속 검증

실제 엔진 재현 SQL·명령, 실패 주입 방법, 쿼리 수준의 동일 임시 VPID 동시 접근 시나리오는 TBD다. 우선 다음 조건을 통제할 수 있는 테스트를 구성해야 한다.

1. A가 로딩 기록을 소유한 상태에서 버퍼 할당 또는 파일 읽기 실패를 발생시킨다. 첫 번째 정리가 끝난 뒤 호출자의 두 번째 정리 직전에 A를 대기시킨다.
2. B가 같은 VPID의 기록을 등록하도록 하고, 해시 공개 전까지 B를 대기시킨다.
3. A의 두 번째 정리를 실행한 뒤 B의 기록이 그대로 연결되어 있는지 확인한다.
4. C의 동일 VPID 요청이 새 로더가 되지 않고 기존 로더를 기다리는지 확인한다.
5. 실제로 도달 가능한 복호화 실패 경로와 정상 성공 경로도 함께 검증한다.

실제 호출 경로에는 `qfile_put_next_sort_item()` -> `qmgr_get_old_page_simple_fix()` -> `pgbuf_simple_fix(..., true)`가 있다. 이 호출 경로의 존재는 소스에서 확인했지만, 동일 임시 VPID의 동시 호출과 실패가 해당 경로에서 함께 발생하는지는 추가 검증해야 한다.

## Expected Result

실패 정리는 해당 호출이 소유한 로딩 기록만 해제해야 한다. A의 기록이 이미 제거된 뒤 B가 새 기록을 등록했다면, A의 후속 정리는 B의 기록을 보존해야 한다. B가 로딩 중인 동안 동일 VPID를 요청한 C는 새 로더가 되지 않고 기존 로더를 기다려야 한다.

## Actual Result

소스에서 helper의 실패 정리와 호출자의 재정리, VPID만 확인하는 삭제 동작을 확인했다. 소스의 동작을 반영한 Lean 모델에서는 A의 두 번째 정리가 B의 기록을 지우는 3단계 소유권 위반과, 이후 C까지 로더가 되는 4단계 실행을 검증했다.

실제 C++ 실행이나 운영 환경에서 같은 스케줄링을 재현한 결과는 없다. 이 반례만으로 중복 프레임 공개, 데이터 손상, 실제 장애 발생을 확정하지 않는다.

## Additional Information

### 수정 후보와 검증 범위

정리 함수에서 현재 기록이 호출자의 소유인지 확인하면 다른 스레드의 기록을 보존할 수 있다. `proposed_owner_check_preserves_foreign_record`는 이 후보의 모델상 성질을 증명한다. 실제 소스 수정이나 채택된 설계는 아니다.

중복 정리를 제거하는 방향도 검토할 수 있으나, 먼저 `pgbuf_claim_bcb_for_fix()`의 반환 경로와 모든 호출자의 정리 책임을 함께 점검해야 한다. 일반 `pgbuf_fix()`는 이 helper가 `NULL`을 반환하면 재시도 여부를 확인한 뒤 반환하며, 해당 위치에서 중복 정리하지 않는다. [비교 코드](https://github.com/CUBRID/cubrid/blob/ea57708a785e34b35a91e10cd0694839a53a4fe5/src/storage/page_buffer.c#L2316-L2326)

별도의 `dwb_read_page()` 오류 분기는 정리 검토 대상이지만, 고정 리비전의 함수 본문은 모든 정상 반환에서 `NO_ERROR`를 반환한다. 이번 반례는 그 분기의 도달 가능성에 의존하지 않는다. [DWB 함수 본문](https://github.com/CUBRID/cubrid/blob/ea57708a785e34b35a91e10cd0694839a53a4fe5/src/storage/double_write_buffer.cpp#L3979-L4015)

이번 이슈의 범위는 로딩 기록의 소유권과 실패 정리다. 페이지 내용의 일관성, 전체 C++ 메모리·동시성 의미론, 함수 종료성, 버퍼 풀 전체의 정확성을 증명한 결과는 아니다.

### 관련 이슈와 검증 자료

- 부모 이슈: [CBRD-27193 - page buffer](http://jira.cubrid.org/browse/CBRD-27193).
- 분석 문서: [pgbuf-simple-fix.md](https://github.com/vimkim/oos-lean-verification/blob/6bddfb23747d38deb780d45222a9df216bff0d17/docs/pgbuf-simple-fix.md).
- 소유권 모델과 반례: [LoadOwnership.lean](https://github.com/vimkim/oos-lean-verification/blob/6bddfb23747d38deb780d45222a9df216bff0d17/proofs/pgbuf-simple-fix/Pgbuf/SimpleFix/LoadOwnership.lean).
- 검증 대상 소스 지문: [provenance.json](https://github.com/vimkim/oos-lean-verification/blob/6bddfb23747d38deb780d45222a9df216bff0d17/proofs/pgbuf-simple-fix/source/provenance.json).

## Code References

아래 행 번호는 모두 CUBRID `ea57708a785e34b35a91e10cd0694839a53a4fe5` 기준이다.

| 역할 | 코드 |
|---|---|
| 호출자의 중복 정리 | [page_buffer.c:2626-2631](https://github.com/CUBRID/cubrid/blob/ea57708a785e34b35a91e10cd0694839a53a4fe5/src/storage/page_buffer.c#L2626-L2631) |
| 버퍼 할당 실패 정리 | [page_buffer.c:8418-8425](https://github.com/CUBRID/cubrid/blob/ea57708a785e34b35a91e10cd0694839a53a4fe5/src/storage/page_buffer.c#L8418-L8425) |
| 파일 읽기·복호화 실패 정리 | [page_buffer.c:8465-8505](https://github.com/CUBRID/cubrid/blob/ea57708a785e34b35a91e10cd0694839a53a4fe5/src/storage/page_buffer.c#L8465-L8505) |
| 스레드별 로딩 기록 등록 | [page_buffer.c:8027-8040](https://github.com/CUBRID/cubrid/blob/ea57708a785e34b35a91e10cd0694839a53a4fe5/src/storage/page_buffer.c#L8027-L8040) |
| VPID만 비교하는 기록 제거 | [page_buffer.c:8092-8127](https://github.com/CUBRID/cubrid/blob/ea57708a785e34b35a91e10cd0694839a53a4fe5/src/storage/page_buffer.c#L8092-L8127) |
| 일반 fix의 helper 실패 처리 | [page_buffer.c:2316-2326](https://github.com/CUBRID/cubrid/blob/ea57708a785e34b35a91e10cd0694839a53a4fe5/src/storage/page_buffer.c#L2316-L2326) |
| 실제 simple-fix 호출 | [query_manager.c:2785-2798](https://github.com/CUBRID/cubrid/blob/ea57708a785e34b35a91e10cd0694839a53a4fe5/src/query/query_manager.c#L2785-L2798) |
| 정렬 결과 생성 중 호출 | [list_file.c:3839-3844](https://github.com/CUBRID/cubrid/blob/ea57708a785e34b35a91e10cd0694839a53a4fe5/src/query/list_file.c#L3839-L3844) |
