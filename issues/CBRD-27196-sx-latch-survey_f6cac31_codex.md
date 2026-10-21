# [PGBUF] B-tree split/merge를 기준으로 SX page latch 도입 필요성과 적용 범위를 조사한다

## Issue Triage

**이슈 수행 목적**: CUBRID의 B-tree split/merge에서 SX(shared-exclusive) page latch가 재시작과 읽기 차단을 줄이는지 조사하고, 도입·보류·미도입 중 하나를 근거와 함께 권고한다.

**이슈 수행 이유**: 현재 B-tree는 READ에서 WRITE로 승격하지 못하면 삽입을 WRITE 하강으로 재시작하거나 merge를 생략·재시작한다. 2026-08-07 작성자 코멘트는 실제 CUBRID split/merge의 이점 검토를 요청했다. 기존 타 DBMS 비교와 flush 복사 제거 가능성만으로 이 요청에 답할 수 없으므로 실제 호출 경로와 비용을 구분해 판단해야 한다.

**영향**: WRITE 하강으로 재시작하는 경우 추가 탐색과 WRITE latch 점유가 발생하고, merge를 생략하는 경로도 있다. 발생 빈도와 처리량·지연·공간 사용에 미치는 크기는 미확인이다. SX를 추가하면 수정 후보의 조기 직렬화와 상태·대기열 관리 비용도 생기므로 성능 개선을 전제하지 않는다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

이 이슈는 [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)의 SX page latch 조사 자식 이슈다. 필요한 결과는 SX의 채택 자체가 아니라 실제 B-tree 작업에서 얻는 이점과 비용을 설명하는 도입 판정이다. 작성자는 [2026-08-07 코멘트](https://jira.cubrid.org/browse/CBRD-27196?focusedCommentId=4775688#comment-4775688)에서 실제 CUBRID workload의 B-tree split/merge 이점을 검토해 작성하도록 요청했고, [2026-08-11 코멘트](https://jira.cubrid.org/browse/CBRD-27196?focusedCommentId=4775744#comment-4775744)에서 기존 조사서의 B-tree 사례를 참고 자료로 제시했다. 이 요청은 구현 방식이나 성능 향상에 대한 합의로 해석하지 않는다.

페이지 버퍼는 디스크 페이지를 메모리 슬롯에 보관한다. VPID는 볼륨과 페이지 번호로 된 식별자이며, BCB는 슬롯의 fix 수, latch 등 제어 상태다. fix/unfix는 페이지를 사용하는 동안 슬롯의 사용을 계수하는 동작이고, page latch는 그 메모리 내용의 접근을 조정한다. 트랜잭션의 논리적 충돌을 다루는 transaction lock과 구분한다. 분석 기준 `f6cac312310f39f46711693da157a08f0e725693`에서 fix에 사용하는 content latch는 READ와 WRITE다. `PGBUF_LATCH_FLUSH`는 flush 완료 대기용으로, fix 가능한 제3 mode가 아니다. 이 기준은 소스 관찰이며 특정 배포 버전의 성능 측정 결과가 아니다. [latch 정의](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.h#L189-L203)

`pgbuf_promote_read_latch`는 항상 실패하는 함수가 아니다. 단독 holder이면 제자리 WRITE 승격이 가능하다. 다른 reader가 있을 때 `ONLY_READER` 조건이거나 선두 대기자가 다른 promoter이면 `ER_PAGE_LATCH_PROMOTE_FAIL`을 반환한다. 그 밖의 공유 reader 승격은 자신의 fix 계수를 빼고 holder를 제거한 뒤 WRITE 선두 대기자로 등록한다. 단순히 READ를 계속 보유한 채 WRITE를 기다리는 모델과 다르다. [승격 분기와 대기 등록](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2826-L2919)

이 정책 아래에서 다음 실제 B-tree 경로가 확인된다.

| 작업 | 현재 동작 | SX 조사에서 답할 질문 |
|---|---|---|
| root 변경 | root split, 최대 key 길이 갱신, root가 leaf인 경우에 승격을 요청한다. 실패하면 WRITE mode로 재시작한다. | split에 의한 실패와 일반 root 갱신을 구분할 때, 수정 후보를 미리 직렬화할 가치가 있는가? |
| 하위 node split | 부모를 `ONLY_READER`로 승격하고 필요하면 child도 승격한다. 실패하면 잡은 페이지를 해제하고 root부터 WRITE로 재시작한다. | 재탐색과 WRITE 하강 비용이 실제 병목인가? SX를 먼저 획득하는 대기로 옮기면 총비용이 줄어드는가? |
| root 및 하위 node merge | 부모와 두 자식·형제 페이지를 순서대로 승격한다. 실패하면 조건에 따라 merge를 생략하거나 WRITE 하강으로 재시작한다. | merge 생략·재시작 빈도, 공간 사용과 reader 지연을 함께 개선할 수 있는가? 여러 페이지의 획득 순서와 부분 승격 실패는 어떻게 처리하는가? |

[root 승격](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/btree.c#L31355-L31405), [split 승격과 재시작](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/btree.c#L31646-L31707), [root merge](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/btree.c#L34824-L34893), [하위 node merge](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/btree.c#L35083-L35136)

현재 소스의 승격 호출은 B-tree 삽입 관련 4곳, 삭제·merge 관련 7곳, file manager 1곳이다. 이 목록은 적용 후보를 찾는 범위이며 모든 호출이 split/merge이거나 병목이라는 뜻은 아니다. file manager 호출도 같은 mode 변경의 호환성 검토 대상에 포함한다. [root의 overflow key 파일 생성 경로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/btree.c#L31083-L31114), [file manager 호출](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/file_manager.c#L8288-L8308)

### 왜 문제인가

승격 실패는 현재 알고리즘이 허용하는 재시도 결과이며, 그것만으로 정합성 결함은 아니다. 다만 동일 작업이 다시 root부터 탐색하고 WRITE로 하강하면 추가 fix/unfix와 reader 충돌이 발생할 수 있다. merge가 생략되면 해당 시점의 공간 회수 기회를 넘긴다. 이를 줄일 수 있는지는 실패율뿐 아니라 재시작당 비용, 페이지별 대기, merge 빈도와 실제 공간 사용을 함께 확인해야 한다. 현재 자료에는 이 기준 소스에서 수행한 경쟁 split/merge 비교 결과가 없다.

SX 후보는 READ와 공존하면서 다른 SX 및 WRITE 요청과 충돌하도록 정의할 수 있다. 수정 후보 하나가 SX를 먼저 확보하면 읽기·판단 구간에 reader를 통과시키고, 수정 순간에 WRITE로 올리는 방식이 가능하다. 그러나 SX끼리의 대기는 더 일찍 시작한다. 새 reader 유입 제어, 기존 reader의 종료, 여러 페이지의 획득 순서가 충족되어야 승격 진행을 논할 수 있으며 timeout·interrupt 같은 실패도 남는다. 따라서 "SX면 승격이 항상 성공한다"거나 "실패 수만큼 빨라진다"고 단정할 수 없다. 이 의미와 제약은 기존 조사서도 설계 가설로 구분한다. [기존 B-tree 후보와 한계](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/cbrd-27196-sx-page-latch-aio-direct-i-o-cubrid/f799e05_codex/chapters/06-policy.html#L84-L109)

### 왜 해결해야 하는가

실제 B-tree 비용을 확인하지 않고 mode부터 추가하면 기존의 재시작 비용을 다른 대기 비용으로 바꾸고, 빠른 READ 경로와 holder 계수 관리까지 복잡하게 만들 수 있다. 반대로 해당 비용이 크다면 현재 방식만 유지하는 판단도 개선 기회를 놓친다. 조사로 필요한 근거를 확보하면 도입을 진행할지, 기존 정책을 유지할지, 더 좁은 개선으로 해결할지를 선택할 수 있다. 긴급성이나 고객 노출 범위는 확인되지 않았다.

이 조사는 기존 분석을 재사용하되, 그 분석의 기준 시점과 반례를 반영한다. 타 DBMS가 유사 mode를 사용한다는 사실, 장래 AIO 요구, memcpy 제거 가능성은 각각 검토 자료이며 CUBRID의 SX 채택 근거를 대신하지 않는다. flush만 필요할 때와 B-tree에서도 수정 후보 직렬화가 필요한 때를 분리해 평가해야 한다.

## Evidence and Limits

### 기존 조사에서 유지할 결과와 정정할 해석

기존 조사서는 InnoDB SX, PostgreSQL content lock, SQL Server UP를 비교했다. 그 비교의 보호 대상과 I/O 수명은 CUBRID의 page latch에 그대로 대응하지 않는다. 특히 다른 엔진의 index 범위 latch를 CUBRID root page와 같은 보호 범위로 간주하지 않는다. 비교 자료는 기준 revision을 유지한 참고 근거로 사용하며, 현행 CUBRID 적용 가능성은 위 호출 경로로 판정한다. [고정 revision의 비교 조사](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/cbrd-27196-sx-page-latch-aio-direct-i-o-cubrid/f799e05_codex/index.html)

현재 `pgbuf_bcb_flush_with_wal`은 BCB mutex 아래에서 plain page를 별도 버퍼로 복사하거나 TDE 암호화 출력을 만들고, mutex를 해제한 뒤 WAL 처리와 쓰기를 수행한다. DWB(Double Write Buffer) 사용 시에는 DWB slot에도 페이지 이미지를 복사한다. 이 경로는 live frame을 그대로 I/O에 넘기는 설계가 아니므로 "중간 latch가 없어서 현행 flush가 안전하지 않다"는 문제는 확인되지 않는다. SX로 plain frame의 복사를 줄이려면 대신 I/O 동안 writer를 제한하는 비용을 평가해야 한다. TDE 출력과 DWB 복사는 SX 추가만으로 사라지지 않는다. [현행 flush](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10747-L10842), [DWB slot 복사](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L2613-L2631)

기존 조사는 synchronous live-frame 쓰기에는 READ와 fix 유지가 정확성 후보이고, true AIO에는 완료까지 유지되는 입력 이미지와 수명·소유권이 필요하다고 구분했다. request 소유 사본, request 수명에 맞춘 참조, SX, 전용 I/O freeze는 후보이며 SX만 필수인 것은 아니다. `O_DIRECT` 사용과 비동기 완료도 같은 개념이 아니다. 이것은 설계 비교 결과로 유지하고, AIO/direct I/O 구현을 이 이슈의 확정 작업으로 추가하지 않는다. [기존 소스 분석과 적용 한계](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/cbrd-27196-sx-page-latch-aio-direct-i-o-cubrid/f799e05_codex/research/packets/cubrid.md#L80-L152)

2026-08-11 코멘트의 overflow OID 예제도 역사적 기준을 보존한다. 현재 소스는 비유니크 인덱스의 overflow chain을 OID directory로 처리하며, 기존의 빈자리 선형 탐색은 unique 인덱스용 경로로 남아 있다. 과거의 비유니크 `ACTIVE` 예제를 현재 일반 동작으로 반복하지 않는다. overflow까지 조사한다면 directory·legacy 경로를 구분하고 leaf와 overflow page의 대기를 분리해야 한다. overflow latch만 바꾸어도 leaf WRITE 점유나 주소 탐색 자체가 없어지는 것은 아니다. [현재 분기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/btree.c#L33079-L33088), [directory의 보호 범위](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/btree.c#L12153-L12175), [삽입 leaf WRITE 전제](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/btree.c#L31891-L31899)

### 과거 측정의 증명 범위

과거 20,000건 단일 세션 삽입 실험의 관측 파일에는 summary 승격 성공 `89587.00`과 raw `Num_data_page_promote_ext` 성공 `887`이 함께 기록되어 있다. 후속 소스 분석은 computed summary의 중복 계산을 지적했다. 따라서 "삽입당 약 4.4회 승격" 해석은 사용하지 않는다. raw 값도 `PAGE_UNKNOWN` 집계여서 B-tree split만의 횟수로 단정할 수 없고, 단일 세션의 실패 0은 경쟁 시 이점을 증명하지 않는다. [summary 원문](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/cbrd-27196-sx-page-latch-aio-direct-i-o-cubrid/f799e05_claude/evidence/runs/exp1-obs-1/stdout.txt#L444-L446), [raw 원문](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/cbrd-27196-sx-page-latch-aio-direct-i-o-cubrid/f799e05_claude/evidence/runs/exp1-obs-1/stdout.txt#L677-L679), [산식 재검토](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/cbrd-27196-sx-page-latch-aio-direct-i-o-cubrid/f799e05_codex/research/packets/cubrid.md#L405-L437)

이 실험의 기록상 source HEAD는 `f799e05d77d5300c6ea5753b4a6cc7caee6d8912`이고 실행 파일의 표시 버전은 `11.5.0.2396-5cd4f86`, Linux 64bit debug build다. 두 식별자를 구분하며 현재 `f6cac312`의 런타임 재현으로 취급하지 않는다. [실행 파일·소스 provenance](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/code-analysis/cbrd-27196-sx-page-latch-aio-direct-i-o-cubrid/f799e05_claude/evidence/runtime-tools-baseline.json)

## Specification Changes

조사의 확정 산출물은 CUBRID split/merge에 대한 필요성·적용 범위·도입 판정이다. public `pgbuf_fix`에 SX를 추가하거나 flush 내부 상태부터 순차 도입하는 방향은 합의가 확인되지 않았다. 엔진 동작과 API 변경 명세는 TBD - ANALYSIS에서 결정한다.

## Implementation

TBD - ANALYSIS 단계에서 결정한다. 다음 항목을 확인하되, 필요성이 없는 후보의 상세 구현 설계를 완료 조건으로 요구하지 않는다.

- SX 후보의 READ 공존, SX/WRITE 배타 규칙과 보호 대상 페이지를 정한다. READ 보유 중 blocking SX 획득, 재귀 fix, downgrade, conditional 요청, 부분 승격 실패의 처리 규칙을 검토한다.
- BCB의 64bit atomic 상태어와 thread별 holder의 fix 계수, unfix, 대기열·wakeup, ordered fix의 watcher, SERVER_MODE/SA_MODE에 미치는 영향을 확인한다. 별도 bit·owner나 enum 확장 중 어느 표현을 사용할지는 선정하지 않는다. 현재 lock-free READ는 mode·waiter·fix 수·VPID를 확인하고 같은 상태어를 CAS로 바꾸므로 원자성과 계수 정합성을 보존해야 한다. [상태어와 holder](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L440-L487), [READ fast path](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L7690-L7715)
- flush를 후보로 남기면 page latch, flush 진행 상태, fix/참조 수명, WAL, TDE/DWB 이미지 소유권을 구분한다. completion이 다른 실행 주체에서 처리되는 설계에 thread 소유 holder만으로 충분하다고 가정하지 않는다.

## Decision Criteria

현재 확보한 근거의 결론은 **B-tree split/merge의 실측 조사를 진행할 이유는 있으나 SX 채택과 성능 우위는 미확정**이라는 것이다. 현행 snapshot flush는 SX 도입의 필수 사유가 아니며, flush 최우선 또는 public SX 확대를 이 단계에서 선택하지 않는다.

ANALYSIS에서는 다음 순서로 조사 범위를 한정한다.

1. 동일 소스·빌드·통계 수집 조건을 기록하고, 승격 성공·실패·대기를 split, root 갱신, merge별로 구분한다. 기존 summary와 raw의 의미를 확인하고 부족한 호출자·재시작·merge 생략 계측을 식별한다.
2. 동시 삽입으로 split이 발생하는 workload와 삭제·물리 정리로 실제 merge가 발생하는 workload를 확보한다. 단일 세션 대조군과 경합 강도를 구분하고, 해당 경로가 실행됐다는 증거를 남긴다. 처리량·작업 지연, reader/writer 대기, 재탐색 비용, merge 및 페이지 사용량을 비교한다. 실행 환경·자료·수집 명령·반복 수는 TBD - ANALYSIS에서 재현 가능하게 정한다.
3. 기존 정책 유지와 SX 후보의 비용을 비교한다. baseline에서 해당 병목이 확인될 때만 필요한 범위의 프로토타입을 검토한다. 비교 전에 허용 회귀·개선 판정 기준을 정하며, 승격 실패가 줄어도 SX 대기와 전체 지연이 악화되면 개선으로 판정하지 않는다.
4. READ 중심·WRITE 중심 부하에서 빠른 fix/unfix 경로와 공정성을 확인한다. flush 후보를 실제 비교할 때만 flush-pressure, copy CPU, writer 대기와 TDE/DWB 조합을 추가한다. 부모 코멘트의 TPC-H CBRD-27188/27191 사례는 관련 회귀 확인에 활용할 수 있으나 B-tree 경쟁 실험을 대체하지 않는다.
5. 결과를 도입·보류·미도입으로 기록한다. 병목이나 이득이 확인되지 않으면 현행 유지로 종료할 수 있다. 보류이면 결정을 막는 자료와 재검토 조건을 명시하고, 도입 권고이면 최초 적용 범위와 후속 구현에서 입증할 정합성·성능 조건을 제시한다.

## Acceptance Criteria

- [ ] 현재 기준 소스의 split/merge 승격·재시작·merge 생략 경로와 보호 대상 페이지가 근거와 함께 정리된다.
- [ ] 경쟁 workload에서 해당 경로의 실행과 비용을 확인하거나, 확인하지 못한 원인과 판정 한계를 기록한다. 과거 단일 세션 수치나 타 DBMS 사례로 CUBRID 성능 향상을 단정하지 않는다.
- [ ] 현행 유지와 SX 후보를 동일 문제·지표로 비교한다. 도입을 권고할 경우 조기 직렬화, reader 유입, 여러 페이지 순서, 계수·오류 정리 및 회귀 비용을 포함한다.
- [ ] flush에 SX가 필요한지와 B-tree에 SX가 유용한지를 별도로 판정한다. 후보로 남긴 경로만 상세 설계·프로토타입 필요성을 결정한다.
- [ ] 도입·보류·미도입 권고, 근거, 미해결 질문 및 후속 범위가 기록된다. 코드 변경 없이 조사 결론으로 완료할 수 있다.

## Definition of done

- [ ] 분석 기준 소스와 실행 빌드, workload·설정·수집 조건, 원자료 및 해석의 연결을 검토한다.
- [ ] 조사 결과와 판정이 부모 CBRD-27193에서 추적 가능하고, 구현이 필요하면 별도 작업의 범위와 검증 기준을 제시한다.

## Triage Request

실제 CUBRID B-tree split/merge에 대한 SX의 필요성·이득·비용을 판단하는 조사 과제로 이슈 확인을 요청한다. 작성자 측에 ANALYSIS를 배정해 기존 자료의 기준 차이를 정리하고, 경쟁 workload와 판정 근거를 확보하도록 요청한다. 우선순위와 담당 배정은 triage에서 결정한다.

CBRD-27423의 성능 분석 도구와 CBRD-27266의 통계 의미 조사 결과는 공유할 수 있다. CBRD-27356의 latch 대기 정책, CBRD-27370의 nested fix 계수 정책은 새 mode의 계약 검토에 참고한다. 이들을 일괄 선행 완료 조건으로 만들지는 않는다. 현행 flush 오류 복구는 CBRD-27262의 범위이며, SX 조사에 그 수정을 포함하지 않는다.
