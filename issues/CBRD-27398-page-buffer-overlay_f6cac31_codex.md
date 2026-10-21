# [PGBUF] Volmap용 읽기 전용 페이지 버퍼 상태 관찰 인터페이스를 제공한다

## Issue Triage

**이슈 수행 목적**: Volmap의 디스크 페이지 지도에서 같은 VPID의 페이지 버퍼 상주·dirty·page latch·LRU 상태를 관찰할 수 있도록 선택적으로 활성화하는 읽기 전용 인터페이스를 제공한다.

**이슈 수행 이유**: 현재 기준 소스의 `SHOW PAGE BUFFER STATUS`는 풀 집계를 제공하며 특정 VPID의 상태를 Volmap에 연결하는 인터페이스가 없다. 합의된 state-only v1 설계와 별도 Draft PR이 있으므로, 기존 결정을 유지하면서 미병합 구현·계약 차이와 남은 검증을 정리할 필요가 있다.

**영향**: 페이지 단위로 디스크 구조와 실행 중 버퍼 상태를 연결하려는 개발·진단 작업이 제한된다. 관찰은 시간 구간의 표본이며 commit·디스크 영속성·페이지 이미지 일치를 증명하지 않는다. 기능의 성능 비용과 release 수락 조건 충족은 미확인이다.

**이슈 수행 방안**: 기록된 기본 off·시작 시점 전용 `enable_pgbuf_inspector`, 로컬 Unix stream socket, 의미값 기반 bounded resident-set scan 방향을 유지한다. ANALYSIS에서 Draft PR의 안전성, 지원 플랫폼, 계약 변경 이력과 최종 통합·검증 범위를 확정한다.

---

## AI-Generated Context

> 아래는 현재 소스, 기록된 설계 결정과 별도 Draft 구현을 구분한 상세 맥락이다. 과거 검증 기록은 해당 producer·consumer·build에만 적용하며 이 보고서에서 새 실행 결과를 주장하지 않는다.

## Description

### 무엇이 문제인가

페이지 버퍼는 디스크 페이지를 메모리에 보관하고 접근을 조정한다. BCB는 버퍼 슬롯의 관리 상태이며, VPID는 볼륨 번호와 페이지 번호로 구성된 식별자다. fix/unfix는 페이지의 사용·상주를 관리하는 계수와 관련되고, page latch는 메모리 페이지 접근을 조정한다. 이는 트랜잭션의 논리적 접근을 제어하는 transaction lock과 구분한다.

확인 기준은 CUBRID `f6cac312310f39f46711693da157a08f0e725693`이다. 이 기준의 BCB에는 VPID, atomic latch, flags, LRU 연결과 oldest-unflush LSA 등이 존재한다. 그러나 `SHOW PAGE BUFFER STATUS`의 공개 결과는 풀 크기, clean/dirty 수와 페이지 종류별 수 등의 집계이며 개별 VPID를 반환하지 않는다. 페이지 상태를 내부에 보유한다는 사실과 외부 진단 도구가 안전하게 이용할 수 있다는 것은 별개다. [BCB 정의](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L477-L522), [SHOW 결과 열](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/parser/show_meta.c#L694-L733), [집계 결과 생성](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L17394-L17469)

필요한 기능은 상주 페이지의 의미 상태를 VPID로 전달하고 Volmap의 디스크 지도에 별도 관찰로 투영하는 것이다. 전체 풀을 한 시점에 고정하거나 메모리와 디스크 내용을 비교하는 기능은 이 요청에 포함하지 않는다. bulk resident-set scan과 별도 소비자 캐시 방향은 이미 기록된 결정이다. [v1 결정](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/05-define-wire-contract-v1.md), [관찰 의미와 현 소비자 계약](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/docs/runtime-page-buffer-observation.md#L11-L29)

### 왜 문제인가

예를 들어 Volmap에서 특정 B-tree 페이지를 선택해도 풀의 dirty 총수만으로는 그 페이지가 관찰 당시 상주했는지, dirty였는지, 어느 LRU 리스트에 속했는지 판단할 수 없다. 디스크 구조와 실행 중 상태를 별도로 추적해야 하며, 현재 집계나 파일 해석만으로 페이지별 대응 관계를 복원할 수 없다. 이는 요청된 진단 흐름의 기능 공백이다. 실제 사용 빈도, 진단 시간 절감량과 고객 노출 범위는 확인하지 않았다.

관찰 기능 자체가 잘못된 결론을 만들지 않도록 의미도 제한해야 한다. 정상 footer를 받은 완전 scan에서의 누락은 관찰상 비상주이며, 부분 scan의 누락·미평가 페이지·중복 VPID는 unknown이다. 개별 레코드와 전체 순회는 atomic snapshot이 아니며 서로 다른 scan을 합쳐 완전한 결과로 취급하지 않는다. dirty와 LSA는 commit이나 디스크 영속성을 판정하지 않는다. [관찰·완전성 계약](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/docs/runtime-page-buffer-observation.md#L16-L21), [broker 결정](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/10-define-volmap-overlay-architecture.md)

### 왜 해결해야 하는가

상태 전용 인터페이스는 기존 집계에서 얻을 수 없는 페이지별 진단 경로를 제공한다. 동시에 잘못된 데이터베이스 연결, 무제한 순회, 느린 소비자와 오래된 표본을 통제해야 서버 작업과 진단 결과를 보호할 수 있다. 따라서 단순 내부 구조 덤프가 아니라 식별·자원·완전성 계약을 가진 선택적 기능으로 검토할 근거가 있다. 성능 비용과 착수 우선순위는 분석과 triage에서 확인할 사항이다.

기존 설계와 Draft 구현을 다시 활용하되 병합·release 검증이 완료된 기능으로 취급하지 않는다. ANALYSIS에서 기존 결정을 입력으로 삼아 아래의 명시적 차이와 미실행 조건을 해결할 것을 요청한다.

## Specification Changes

### 유지할 v1 결정과 책임 경계

아래는 기록된 결정이다. 세부 wire schema와 제한 코드는 연결한 원본 계약에서 관리한다.

| 항목 | 유지할 결과와 근거 |
| --- | --- |
| 활성화 | Boolean `enable_pgbuf_inspector=false`, `PRM_FOR_SERVER \| PRM_HIDDEN`, 시작 시 한 번 읽고 변경은 재시작으로 반영한다. off에서는 daemon/socket을 만들지 않는다. v1 전용 제품 CMake gate는 두지 않는다. [gating 결정](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/04-define-gating-matrix.md) |
| 접속·수명 | AF_UNIX `SOCK_STREAM`과 버전 JSON-lines를 사용한다. 양쪽 peer는 `SO_PEERCRED`의 exact effective UID를 검증한다. 전용 디렉터리 0700/socket 0600, 안전한 stale socket 회수와 자신이 생성한 socket만 제거하는 규칙을 유지한다. 활성화 실패 시 inspector를 unavailable로 남기고 DB 시작을 계속한다. [transport](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/03-choose-transport-channel.md), [보안 결정](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/08-set-security-posture.md) |
| 식별·공개 | 데이터베이스 생성 정보와 모든 영구 볼륨의 `(volid, volume_creation, device, inode)`를 검증하고 임시 볼륨은 이 집합에서 제외한다. incarnation은 재시작마다 바뀌며 이전 관찰을 무효화한다. raw flags/type 번호, 포인터, 페이지 내용, 경로·프로세스 식별자·OS 오류 문자열은 wire 또는 브라우저 공개 범위에 맞게 배제한다. [보안 결정](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/08-set-security-posture.md), [wire 결정](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/05-define-wire-contract-v1.md) |
| 의미 상태 | VPID, 의미 문자열 page kind, latch mode/waiter/fix count, dirty/flushing/async flush/to-vacuum, LRU zone·shared/private·kind-local index, 안전하게 읽은 LSA를 제공한다. latch tuple과 LRU tuple은 각각 한 번의 읽기에서 해석하며 안전하지 않거나 없는 필드는 unknown이다. native page-type 번호를 전송하지 않는다. [v1 결정](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/05-define-wire-contract-v1.md), [정확한 LRU membership 결정](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/14-expose-exact-lru-list-membership.md) |
| 관찰 경계 | scan 시작/끝, incarnation·scan sequence, 정확한 원본 record count와 truncation을 검증한 뒤 공개한다. malformed/missing footer는 prefix를 부분 결과로 승격하지 않는다. page fix/load, page image 복사·해시, disk/DWB/TDE 비교와 hot-path 전이 계측을 추가하지 않는다. [v1 결정](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/05-define-wire-contract-v1.md), [일관성 검사 경계](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/13-choose-consistency-inspection-boundary.md) |
| Volmap 책임 | 별도 저장소의 공유 broker가 한 접속·최신 scan·한 in-flight scan을 소유하고 별도 no-store HTTP로 제공한다. age를 cache 조회로 갱신하지 않으며 pause/hidden/restart/취소와 scope·epoch 검증을 유지한다. 관찰은 inspection facts/revisions/exports/TUI 밖에 둔다. [broker 결정](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/10-define-volmap-overlay-architecture.md), [현 소비자 계약](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/docs/runtime-page-buffer-observation.md#L23-L67) |

### 기존 초안 이후의 명시적 변경

| 항목 | 후속 근거와 적용 범위 |
| --- | --- |
| scan 전송량 | 2026-09-11 사용자 요청에 따라 64 MiB에서 1 GiB streaming byte ceiling으로 변경했다. 메모리·시간 한계와는 독립이다. 과거 64 MiB fixture의 출처와 판정은 유지한다. [변경 기록](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/docs/runtime-page-buffer-observation.md#L97-L108) |
| HTTP listener | 기존 loopback-only 결정을 accepted ADR에서 loopback 또는 명시적 IPv4로 변경했다. wildcard는 거절하고 exact Host/Origin을 검증한다. LAN 경로는 인증 없는 plain HTTP라는 공개 범위를 그대로 명시한다. [ADR 0006](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/docs/adr/0006-runtime-observations-are-loopback-web-capabilities.md) |
| 표시 범위 | 512 VPID는 legacy explicit scope의 한계다. Volume은 최대 64 visible sectors/4,096 pages의 residency·LRU projection을 사용하며 초과는 unevaluated이고 timer rotation을 하지 않는다. Sector/Page는 별도 detail 목적을 유지한다. Volume에 dirty/flushing detail을 요구하지 않는다. [ADR 0008](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/docs/adr/0008-scope-runtime-projections-to-view-level.md), [현재 scope](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/docs/runtime-page-buffer-observation.md#L69-L95) |
| 브라우저 메모리 | 32 MiB에서 tab당 incremental peak RSS 64 MiB로 변경했다. 사용자가 승인한 재검토 안에서 정한 engineering policy이며 사용자가 숫자를 직접 선택했거나 충분성을 입증했다는 뜻은 아니다. 1/8/32-tab matrix와 반복 사용 검증은 유지한다. [예산 개정](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay-implementation/browser-memory-budget-revision.md#L3-L34) |

생산자 2 clients, scan 시작 간격 100 ms, 방문·출력 각각 65,536개, 4 KiB record/control·64 KiB handshake·depth 16, 64 KiB 출력 버퍼, write 무진행 250 ms·연결 500 ms·전체 교환 2 s 등과 소비자의 128 MiB accounting/decoded scan 48 MiB, 응답·동시 요청·age/expiry 한계는 원본 예산과 후속 계약을 함께 적용한다. 수치는 측정 결과가 아니다. 순회 경과 한계의 불일치는 다음 절의 미결 사항으로 남긴다. [원래 예산 결정](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/15-set-overlay-resource-budgets.md), [후속 소비자 한계](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/docs/runtime-page-buffer-observation.md#L86-L133)

## Implementation

### 현재 기준과 미병합 구현을 구분한다

2026-10-21 확인한 [PR #7940](https://github.com/CUBRID/cubrid/pull/7940)은 develop 대상 Open·Draft이며 HEAD는 `6bf4753eaa136fb87a4632deac44dc403ad0538e`다. 이는 현재 기준 `f6cac312`에 병합된 동작이 아니다. 현재 JIRA 본문·댓글은 비어 있으므로 기능 요구의 상세 근거는 위 설계 기록과 PR에서 가져왔다.

Draft의 실제 sampler는 BCB mutex를 한 번 trylock하고 실패하면 unavailable로 남긴다. latch word와 flags는 각각 한 번 atomic load하며, page-kind/LSA는 latch 없음·fix count 0·flush 중 아님을 확인한 경우에만 읽는다. 전송 전에 mutex를 해제한다. 따라서 기존 계획의 “전체 수집이 lock-free”라는 표현을 구현 사실로 사용하지 않는다. 이 접근의 race·수명 안전성은 리뷰 대상이다. [Draft sampler](https://github.com/CUBRID/cubrid/blob/6bf4753eaa136fb87a4632deac44dc403ad0538e/src/storage/page_buffer.c#L17491-L17554)

원래 계획은 Unix server와 여러 build mode를 허용하지만 Draft sampler는 `SERVER_MODE && LINUX`다. Draft의 scan 상수는 1 GiB·1,500 ms이며 원래 승인된 순회 경과 예산은 100 ms다. 전송량의 후속 변경 근거는 확인했으나, 1,500 ms 순회 한계의 별도 결정 근거는 확인하지 못했다. scan 시작 간격 100 ms와 순회 경과 한계는 다른 값이다. ANALYSIS에서 최종 플랫폼 약속과 시간 예산·성능 gate·문서·corpus의 일치를 결정하고 기록해야 한다. [원래 gating](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/04-define-gating-matrix.md), [원래 예산](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/15-set-overlay-resource-budgets.md), [Draft 상수](https://github.com/CUBRID/cubrid/blob/6bf4753eaa136fb87a4632deac44dc403ad0538e/src/storage/pgbuf_inspector_scan.hpp#L29-L33)

엔진 변경은 page-buffer 상태 추출, parameter·boot/shutdown 연결, socket·serializer와 그 검증을 담당한다. Volmap의 broker·HTTP·browser는 별도 저장소 책임이다. 초기 OOS 형식 정렬 경로와 develop 이식 결정은 이력으로 보존하되, 최종 검증에서는 실제 producer/consumer와 명시한 disk format profile을 맞춘다. 의미 wire 호환만으로 디스크 형식 호환을 주장하지 않는다. [초기 브랜치 결정](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/issues/02-choose-target-branch.md), [검증 기준](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/docs/runtime-overlay-release.md#L12-L28)

과거 Debug/native 테스트 보고와 Volmap의 기능 검증 기록은 존재한다. 그러나 Draft PR 설명의 남은 검증과 Volmap release 문서의 미실행 전용 호스트 성능·수동 접근성 검토를 완료로 바꾸지 않는다. 이 보고서는 빌드나 런타임 재현을 새로 실행하지 않았다. [PR 검증 범위](https://github.com/CUBRID/cubrid/pull/7940), [과거 producer 보고](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/cbrd-27398/CBRD-27398-page-buffer-inspector_c2492f8_codex.md), [Volmap release 상태](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/docs/runtime-overlay-release.md#L1-L8)

## Acceptance Criteria

- [ ] off에서 daemon/socket이 없고 안전한 활성화 실패가 DB 시작을 막지 않는다. peer·영구 볼륨 identity·socket 소유권과 종료·재시작을 실제 endpoint에서 확인한다.
- [ ] 정상 complete/partial과 malformed/missing footer, 중복 VPID, unknown 필드·enum, 모든 자원 경계값의 해석이 동일 revision/hash의 producer/consumer corpus 및 실제 socket 검사와 일치한다. 실행한 testcase 이름·개수와 원본 결과를 남긴다.
- [ ] 지원하기로 확정한 debug/release 구성에서 known-VPID fixture로 residency·dirty·eviction을 독립적으로 확인한다. 전제 확보 실패를 inconclusive로 남기며 sleep이나 observer 결과로 전제를 대신하지 않는다. 실제 shipped-server 경로와 외부 testcase 증거를 구분한다.
- [ ] 최종 구현·문서·corpus가 플랫폼, scan byte/time cap, optional field 안전 조건에서 일치한다. 100 ms 대비 1,500 ms 차이를 명시적으로 처리하고 영향을 받는 검증을 다시 수행한다.
- [ ] Volmap의 공유 demand, age·30 s expiry, pause/hidden/resume, incarnation 변경, scope·epoch 권한, overload와 일반 디스크 검사·TUI·export 독립성을 정해진 책임 경계에서 확인한다. 최신 ADR의 HTTP·Volume scope를 적용한다.
- [ ] [release 측정 계약](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/docs/runtime-overlay-release.md#L30-L109)의 pool/workload/1·8·32-tab matrix와 matched 비교를 실행한다. case당 10 paired runs, 60 s warmup·최소 5분·해당 시 100,000 transactions, throughput 손실 2%·transaction p99 증가 5%의 95% 신뢰 상한을 포함한다. 완전 scan 비율·refresh/HTTP·CPU·RSS·allocation·디스크 검사 간섭과 양 browser의 실제 10,000-cell 반응성·수동 접근성 검토도 각 gate로 판정한다.

## Definition of done

- [ ] exact producer/consumer commit, binary/build·환경·testcase revision·corpus hash·원본 결과를 묶은 최종 gate manifest와 공개 가능한 설정·제한·검증 문서를 남긴다.
- [ ] 각 수락 조건의 판정을 기록하고 누락/skip/fail/inconclusive는 열린 gate로 남긴다. socket 도입의 upstream 검토 결과와 최종 통합·release의 남은 조건을 명시한다.

## Triage Request

[CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)의 하위 기능으로 페이지별 상태 관찰 인터페이스의 필요성을 확인하고 작성자 측에 ANALYSIS를 배정할 것을 요청한다. 기존 설계 결정과 후속 개정은 입력으로 유지하고, Draft 구현의 지원 범위·안전성·계약 차이와 release 증거의 부족을 우선 정리한다. 우선순위와 담당 확정은 triage에서 결정한다.

CBRD-27266의 통계 의미 정리나 CBRD-27423의 성능 분석 도구와는 근거·측정 방법을 공유할 수 있다. 이들 조사 전체 완료를 이 기능의 선행조건으로 추가하지 않는다. 페이지 이미지 일관성 검사, AOUT 이력, flush-transition event와 TUI runtime parity는 기록된 v1 범위 밖이며 별도 계측 제안을 이 이슈에 합치지 않는다. [scope 결정 모음](https://github.com/vimkim/volmap/blob/c9ed4ccaae4310fad380384a5808ee1e14e8d14c/.scratch/pgbuf-overlay/map.md)
