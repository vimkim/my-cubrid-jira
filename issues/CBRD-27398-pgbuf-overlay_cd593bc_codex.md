# [PGBUF] 선택적으로 활성화하는 페이지 버퍼 상태 관찰 인터페이스

## Issue Triage

**이슈 수행 목적**: Volmap의 디스크 페이지 지도 위에 CUBRID 페이지 버퍼의 관찰 상태를 표시할 수 있도록, 읽기 전용 상태 제공 인터페이스를 추가한다.

**이슈 수행 이유**: AS-IS에서는 디스크 파일 해석과 `SHOW PAGE BUFFER STATUS`의 집계만으로 특정 페이지의 버퍼 상주 여부, latch 상태와 dirty 상태를 함께 확인하기 어렵다. TO-BE에서는 페이지 식별자로 두 관찰 결과를 연결하되, 디스크 내용과 메모리가 일치한다는 뜻으로 해석하지 않는다. 페이지 단위 진단에서 디스크 구조와 실행 중 상태를 따로 추적해야 하는 제약을 줄이는 것이 목적이다.

**이슈 수행 방안**: 기본값이 꺼진 시작 시점 전용 `enable_pgbuf_inspector` 파라미터로 Unix 상태 관찰 소켓을 활성화한다. 버퍼에 상주한 페이지를 순회하는 작업(resident-set scan)으로 의미가 정의된 상태값만 내보내고, Volmap은 공유 캐시를 통해 선택/표시 페이지에 투영한다. 확정된 Wayfinder 설계 기록의 분기, 보안, 예산, 검증 결정을 적용한다. 페이지 이미지 비교, AOUT 이력과 flush 이벤트 기록은 이번 범위에서 제외한다.

---

## AI-Generated Context

> 아래는 확정된 설계와 로컬 소스 확인을 정리한 구현 인계 초안이다. 구현, 성능 측정, JIRA 반영 및 PR 생성은 아직 수행하지 않았다.

### 변경 범위와 기준

대상은 기존 `CBRD-27398`이며, JIRA 유형은 `Sub-task`, 상위 이슈는 `CBRD-27193`이다. 유형이나 상위 관계를 변경하지 않는다. 확인한 엔진 기준 커밋은 `cd593bcf2d8643b4698f1cb311c4c23af23a9d57`이다. 이 커밋은 분석 기준이지 앞으로 제출할 구현 PR의 HEAD가 아니다.

`src/storage/page_buffer.c`와 서버 시작/종료 경로, 시스템 파라미터 및 테스트 연결부가 엔진 측 범위다. Volmap은 별도 저장소에서 상태 수신, HTTP 경계, 브라우저 표시를 담당한다. 일반 파일 해석, TUI 출력, 검사 결과와 내보내기 형식은 바꾸지 않는다.

## Description

BCB는 버퍼 슬롯의 관리 정보이며, VPID는 볼륨 번호와 페이지 번호로 구성된 물리 페이지 식별자다. BCB를 순서대로 읽는 동안 다른 스레드가 상태를 바꿀 수 있으므로 전체 풀을 한 시점에 고정한 결과는 아니다. latch는 페이지 접근을 조정하는 잠금 상태이고, dirty는 변경된 버퍼 상태다. 이 값들은 트랜잭션 commit 여부나 디스크 영속성을 판정하지 않는다.

관찰값의 시간은 scan 시작/끝 구간으로 전달한다. 페이지별 정확한 관찰 시각을 만들지 않으며, 서로 다른 scan의 기록을 합쳐 하나의 완전한 관찰처럼 표시하지 않는다. 상주하지 않는 페이지를 읽어 들이거나 페이지 내용을 복사하는 기능도 제공하지 않는다.

## Specification Changes

### 활성화와 지원 범위

| 항목 | 확정 규칙 |
| --- | --- |
| 파라미터 | Boolean `enable_pgbuf_inspector=false`, `PRM_FOR_SERVER \| PRM_HIDDEN` |
| 변경 시점 | 서버 시작 시 한 번 읽는다. 재시작이 필요하며 reload/client 동기화 플래그는 추가하지 않는다 |
| 지원 빌드 | Unix `SERVER_MODE`의 Release, RelWithDebInfo, Debug, OptDebug |
| 기본 동작 | 비활성화 시 daemon과 socket을 모두 만들지 않는다 |
| 컴파일 경계 | v1 전용 CMake 옵션은 추가하지 않는다. Windows 및 비서버 바이너리는 endpoint를 제공하지 않는다 |
| 향후 고비용 관찰 | 페이지 이미지/해시/비교 및 per-fix/전이 계측은 별도 기능과 debug 전용 gate가 필요하다 |

### 접속과 식별

Unix domain `SOCK_STREAM`에서 버전이 있는 JSON-lines를 사용한다. 양쪽 프로세스는 `SO_PEERCRED`로 상대 effective UID가 자신과 정확히 같은지 확인하며 root/group 예외는 두지 않는다. Volmap은 전용 디렉터리와 socket 소유자도 확인한다.

기존 CUBRID socket root 아래 `pgbuf-inspector/` 디렉터리는 `0700`, socket은 `0600`이다. socket 이름은 데이터베이스 경로와 생성 식별자에서 얻은 길이 제한 opaque key를 사용한다. symlink, 다른 소유자, 비소켓 파일과 접속 가능한 socket은 보존한다. 같은 소유자의 stale socket만 확인 후 회수하고, 종료 시에도 생성한 socket의 식별자가 같은 경우에만 제거한다.

안전한 경로 준비나 bind/listen에 실패하면 해당 incarnation 동안 inspector를 사용할 수 없다고 알리고 데이터베이스 시작은 계속한다. 자동 bind 재시도는 하지 않는다. incarnation은 서버 재시작마다 달라지는 예측 불가능한 식별자다.

handshake는 데이터베이스 생성 식별자와 모든 영구 볼륨의 `(volid, volume_creation, device, inode)`를 맞춘다. 임시 볼륨은 이 집합에서 제외한다. 이름/경로만 같다는 이유로 접속을 허용하지 않는다. Volmap의 runtime 연결은 명시적 enable과 socket 경로가 모두 필요하며, HTTP listener가 loopback이 아니면 시작 오류로 처리한다. 일반 비연결 serve의 동작은 유지한다.

브라우저에는 검증 결과, 프로토콜 버전, 안전한 fingerprint, 축약 incarnation, 관찰 구간과 안정적인 제한 코드만 공개한다. 경로, UID/GID/PID, raw OS 오류는 노출하지 않는다.

### 상태 레코드와 완전성

| 그룹 | 전달할 의미값 |
| --- | --- |
| 페이지 | `volid`, `pageid`, 문자열 `page_kind` |
| latch | `latch_mode=none/read/write/flush`, `waiter_present`, `fix_count`: 하나의 atomic latch-word 읽기에서 해석 |
| 상태 | `dirty`, `flushing`, `async_flush_requested`, `to_vacuum` |
| LRU | `lru_zone=lru1/lru2/lru3/void/invalid`, `lru_list_kind=shared/private/none/invalid`, kind 내부 `lru_list_index` 또는 null: 하나의 flags 읽기에서 해석 |
| 로그 위치 | `page_lsa`, `oldest_unflush_lsa`: LSA는 로그 내 위치이며 commit 판정이 아니다 |

LRU는 교체 정책의 리스트 분류다. handshake의 shared/private 리스트 개수와 인덱스는 incarnation에 종속된다. raw page-type 번호, flags, 포인터와 native 리스트 카운터/할당량은 내보내지 않는다. 브랜치마다 달라지는 page-type 번호는 의미 문자열로 변환하며 develop은 `oos` 종류를 생성하지 않는다.

작업은 bulk resident-set scan 하나다. handshake 뒤 scan header의 `scan_seq`와 시작 시각, 레코드들, footer의 종료 시각/레코드 수/truncation을 전달한다. `scan_seq`는 incarnation 내부에서 증가하며 이벤트 순번이 아니다. snake_case 필드와 소문자 문자열 enum을 사용하고 같은 major 버전에서는 additive 변경만 허용한다. 선택적 상태 필드의 부재와 필수 framing 필드의 부재는 구별한다.

요청 범위 중 평가한 페이지가 완전한 scan에 없을 때만 관찰상 비상주로 해석한다. 부분 scan에서 누락되거나 평가하지 않은 페이지는 unknown이다. 응답에는 요청 수와 평가 수를 따로 싣는다. footer가 없거나 수량/순번/구조가 틀리면 전체 조립 결과를 버린다. 중복 VPID는 마지막 값으로 덮지 않고 ambiguous/unknown으로 처리한다. 원본 레코드 수 검증은 중복 제거 전에 수행한다.

### 생산자 제한

아래 수치는 확정된 구현 한계이며 성능 측정 결과가 아니다. byte 단위는 framing을 포함하는 이진 단위다.

| 자원 | 제한과 목적 |
| --- | --- |
| 접속/주기 | 2개 client, 최소 scan 간격 100 ms: 공유 Volmap과 수동 진단 접속을 제한한다 |
| 방문/기록 | scan당 각각 65,536개 이하: 16 KiB 페이지의 1 GiB 풀을 기준 대상으로 삼되 큰 풀의 비용은 고정한다 |
| 출력 | scan 전체 64 MiB, record/control frame 4 KiB, handshake 64 KiB, JSON depth 16: parsing/출력 자원을 제한한다 |
| 순회 | slot 사이에서 확인하는 100 ms 경과 한계: 실시간 보장은 아니며 backpressure 대기 시간도 포함한다 |
| 전송 | 출력 버퍼 64 KiB, write 진행 없음 250 ms면 disconnect, scan 교환 전체 2 s: 느린 client가 자원을 점유하지 못하게 한다 |
| 연결 | connect와 handshake 합계 500 ms: 접속 시도를 제한한다 |

footer 공간을 먼저 남긴다. pool 전체를 방문하기 전에 멈췄으면 truncation을 표시하고 다음 scan은 방문 구간 뒤에서 이어 시작한다. 각 scan에서 같은 slot을 두 번 방문하지 않는다. 이전 scan과 합쳐 전체 관찰로 간주하지 않는다. decoder 한계에 걸린 client는 임의의 부분 footer를 만들지 않는다.

안정적인 거절 코드는 `version-unsupported`, `busy`, `rate-limited`, `incarnation-changed`다. 파라미터가 꺼지면 socket 자체가 없으므로 생산자가 `parameter-off`를 보내지는 않는다. client가 호환 목적으로 이 코드를 수용할 수는 있다.

### Volmap 연동 경계

서버 세션당 접속과 최신 관찰값을 공유하는 중개 모듈(broker) 하나를 둔다. `GET /api/v1/runtime/capabilities` 및 `POST /api/v1/runtime/page-buffer/observe`는 no-store이며 디스크 검사와 별도의 동시 요청 한도와 응답 형식을 사용한다.

| 항목 | 소비자 계약 |
| --- | --- |
| 메모리 | retained/in-flight/index/parser/응답을 포함해 128 MiB, decoded scan 하나는 48 MiB 이하. spill/history는 없다 |
| observe 요청 | 512 VPIDs, body 64 KiB, 응답 1 MiB, waiter 포함 동시 8개, 추가 queue 없음, 2.5 s deadline, 초과 시 429 |
| capability 요청 | 별도 4개 slot, queue 없음, 1 s deadline |
| sampling | 선택 페이지 500 ms, 표시 페이지 2 s, broker scan 시작 간격 최소 500 ms |
| retry | 0.5/1/2/4/8 s nominal 지수 backoff와 +/-20% jitter, 실제 최대 9.6 s. 정상 scan 후 초기화 |
| pause/hidden | pause는 5 s마다 metadata만 확인하고 scan을 요구하지 않는다. hidden은 요청하지 않는다 |
| age | broker monotonic scan 요청 시작에 기반한 보수적 age 상한에 브라우저 전송/경과 불확실성을 더한다. 두 요청 주기 이내만 fresh다 |
| expiry | pause 중에도 30 s 뒤 관찰값을 제거한다. 응답/캐시 조회 시 age를 초기화하지 않는다 |

일시 오류는 이전의 유효하고 만료되지 않은 scan을 유지하지만, identity/peer 거절 또는 비호환은 지우고 명시적 retry를 요구한다. 재시작은 pause 중에도 이전 incarnation의 값과 진행 중 응답 권한을 무효화한다. 다른 tab의 요청이 남으면 한 tab의 취소로 공유 scan을 취소하지 않는다. 마지막 관찰자가 사라지면 불필요한 작업을 중단하고, resume은 그 이후 시작한 scan을 요구한다.

## Implementation

### 엔진과 소비자의 책임

응답은 요청 범위와 요청 식별값(epoch)을 되돌려준다. 경로, 요청 범위, 표시 방식 또는 pause 상태가 바뀌면 이전 요청의 응답을 적용하지 않는다. 요청 취소만으로 이 검증을 대신하지 않는다.

구현 예정 위치는 아래와 같다. 기존 코드 또는 완료한 테스트를 뜻하지 않으며 내부 모듈 파일명은 구현 과정에서 조정할 수 있다.

| 담당 | 예정 위치 | 책임 |
| --- | --- | --- |
| 엔진 상태 제공 | `src/storage/page_buffer.c`, 예정 `src/storage/pgbuf_inspector.cpp/.hpp` | 의미값 추출, bounded scan/serializer, daemon 수명과 socket |
| 파라미터/시작 연결 | `src/base/system_parameter.*`, 기존 서버 시작/종료 경로 | startup-only gate와 실패 시 DB 시작 유지 |
| 엔진 검증 | 예정 `unit_tests/pgbuf_inspector/`, `docs/pgbuf-inspector/v1/` | unit 실행 연결과 생산자 소유 conformance corpus |
| 외부 shell 검증 | testcase 저장소의 예정 `pgbuf_inspector/CBRD-27398/` | 실제 socket, parameter, permission, restart 및 bounded fixture 검증 |
| Volmap | private runtime module, `src/web.rs`, `web/src/` | UDS adapter/broker, 별도 HTTP, 상태 투영과 접근성 |

```text
enable_pgbuf_inspector 확인
  -> 안전한 socket 활성화 / 실패 시 inspector 없이 DB 시작
  -> peer 및 database/volume identity 확인
  -> 한계 내 BCB 순회 -> 의미값 JSON-lines -> 유효 footer
  -> Volmap 공용 최신 scan -> 선택/표시 VPID 투영 -> 정적 상태 표시
```

검사자는 page fix, page image 복사/해시 또는 disk read를 하지 않는다. 파라미터 조회를 hot path에 넣지 않으며, page 보호를 socket 전송이나 backpressure 동안 유지하지 않는다. CUBRID의 C 오류 처리와 기존 파일 형식/들여쓰기를 보존한다. JSON에는 기존 RapidJSON을 사용하고 Volmap은 기존 serde_json을 사용해 새 runtime 의존성을 추가하지 않는다.

### 브랜치와 인계 순서

Volmap이 지원하는 형식 기준 `e1e651d`에서 생산자를 개발하고 통합한 뒤 develop으로 이식한다. develop에서는 의미 page-kind 변환을 다시 확인한다. develop의 생산자 검증과 형식이 맞는 브랜치의 Volmap 전체 연동 검증을 각각 debug와 release에서 수행한다. 먼저 wire/corpus와 엔진 상태 경로를 고정하고, 공유 broker/HTTP를 거쳐 선택한 시각 표현과 검증을 완성한다.

## Acceptance Criteria

- [ ] 파라미터 off에서 daemon/socket이 없고 on에서도 안전한 활성화 실패가 DB 시작을 막지 않는다.
- [ ] 양쪽 peer와 전체 영구 볼륨 identity를 검증하며 잘못된 소유자, identity, framing 및 incarnation을 안전하게 거절한다.
- [ ] 양 저장소가 동일 revision/hash의 corpus를 네트워크 없이 검증한다. chunking, partial, malformed, 중복, additive 필드와 모든 한계의 경계값을 포함한다.
- [ ] 엔진 unit executable이 실제 실행됐음을 testcase 이름과 실행 개수로 증명한다. build 성공이나 빈 ctest 결과로 대신하지 않는다.
- [ ] debug/release 실제 socket과 제어된 known-VPID fixture로 residency/dirty/eviction을 검증한다. sleep으로 전제 상태를 추측하지 않으며 전제 확보 실패는 inconclusive다.
- [ ] release 전용 기준 장비에서 512 MiB/1 GiB/4 GiB 풀, idle/read/write-flush/churn, 1/8/32 tab과 stall/pause/hidden/restart/clock/rotation을 검증한다.
- [ ] 각 성능 case는 60 s warmup 후 5분 이상, 해당 시 100,000 transaction 이상을 측정하는 paired run 10회로 평가한다. throughput 손실 2%, transaction p99 증가 5% 이하를 95% 신뢰 상한으로 증명하며 불확실하면 통과가 아니다.
- [ ] idle/read-heavy 1 GiB 기준에서 완전 scan 비율 99% 이상, refresh p95 250 ms 이하, cached HTTP p95 25 ms 이하, 디스크 검사 p95 증가 5% 이하를 만족한다. 큰 풀은 정직한 partial coverage를 검증한다.
- [ ] 기본 cadence에서 생산자 CPU는 논리 core 하나의 20%, broker는 50% 이하이며 incremental peak RSS는 각각 16 MiB/192 MiB, browser tab은 32 MiB 이하다. 별도 allocation 한계도 유지한다.
- [ ] Chromium/Firefox의 실제 10,000-page 표시 밀도에서 입력부터 표시까지 p95 100 ms 이하를 확인하고 keyboard, non-color 표시, reduced motion/high contrast 및 수동 screen-reader/시각 검토 증거를 남긴다.

## Definition of done

- [ ] 구현 및 위 수락 조건의 실행 증거를 exact producer/consumer commit, corpus hash, 환경, 실행 개수, 원본 결과와 함께 기록한다.
- [ ] 비활성/활성 무요청 비용을 별도로 측정하고, upstream review와 socket 도입 승인을 받는다. 미실행/누락/skip/inconclusive는 release gate를 충족하지 않는다.
- [ ] 외부 testcase 변경과 공개 가능한 build/test 안내, 사용자 설정/제한 문서를 반영한다.
- [ ] Volmap 일반 디스크 검사, TUI 및 기존 export에 영향이 없음을 확인한다.

## Remarks

관련 선행 자료는 [CBRD-26325](https://jira.cubrid.org/browse/CBRD-26325)의 latch timeout instrumentation 제안이다. 그 제안은 holder/대기열, 소유 시간, breadcrumb, 선택적 stack 수집을 단계적으로 추가하는 내용이다. 진단 필요성의 참고 자료이며, 해당 계측이나 raw thread 정보 공개를 이번 상태 제공 범위로 가져오지 않는다.

이번 초안은 계획만 확정한다. 실제 JIRA description 교체와 develop draft PR 발행은 별도 작업이며, 구현 후의 PR HEAD로 문서/증거를 다시 묶어야 한다. 후속 페이지 일관성 검사, AOUT 및 flush-transition event 설계는 이 이슈의 완료 조건이 아니다.
