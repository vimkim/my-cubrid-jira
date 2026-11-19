# [SERIAL] serial 행 갱신을 가드된 제자리 쓰기로 일원화하고, 비HA에서는 바뀐 바이트만 로그한다

**한 줄 요약**: CBRD-28073(OOS) 리뷰와 이어진 serial 행 형태 연구에서, NEXT VALUE가 `_db_serial` 행 전체를 다시 인코딩해 redo 전용으로 덮어쓰는 구조가 재시작 불가(CBRD-28271), 카탈로그 손상(CBRD-28272), OOS chain 결함(CBRD-28073)의 공통 원인임을 확인했다. 이 이슈는 OOS가 develop에 병합된 뒤의 근본 수정이다. 모든 serial 행 쓰기를 "로그 전에 확인하고, 행이 실제로 있는 slot에 쓰고, 맞지 않으면 일반 update로 넘기는" helper 하나로 모으고, 비HA에서는 행 전체 대신 바뀐 바이트만 로그한다.

## Issue Triage

**이슈 수행 목적**: NEXT VALUE, CACHE 블록 예약, cache write-back이 serial 행을 쓰는 모든 경우에 다음을 보장한다.
- 행 크기가 바뀌어도, 행이 relocation 상태여도, comment가 OOS에 있어도 로그와 page가 어긋나지 않는다.
- 같은 값을 두 번 발급하지 않는다.
- 비HA 서버에서는 호출당 로그가 comment 길이와 무관하게 수십 바이트로 줄어든다.

새 redo 전용 heap 행 writer가 같은 결함을 다시 만들지 못하도록 debug 검사와 CI 검사로 막는다.

**이슈 수행 이유**:
- `serial_update_serial_object`(`src/query/serial.c`)는 일반 heap update를 거치지 않는다. 행 전체를 다시 인코딩해 redo 전용 `RVHF_UPDATE`를 먼저 남기고, home slot을 `spage_update`로 덮어쓴다.
- 이 경로는 세 가정에 기댄다: 행 크기가 변하지 않는다, 행이 `REC_HOME`이다, 각 열의 저장 형태(inline/OOS)가 바뀌지 않는다. 세 가정은 각각 develop과 OOS 브랜치에서 실제로 깨졌다.
- safety net(CBRD-28271, CBRD-28272)은 "로그 전 확인과 폴백"으로 당장의 손상과 재시작 불가를 막는다. 그러나 다음은 남는다.
  - relocation된 행은 매 호출 폴백을 탄다.
  - 행 전체 redo 비용이 그대로다(comment 1000자 serial은 호출당 약 1.3 KB).
  - 같은 패턴을 다시 막는 장치가 없다.

**영향**:
- **정합성**: 대상은 serial(AUTO_INCREMENT 포함)을 쓰는 모든 사용자다. safety net이 없으면 재시작 불가, `_db_serial` 손상, serial 소실이 생긴다(실행으로 확인). safety net만 있으면 relocation된 serial의 NEXT VALUE가 계속 일반 update 경로를 타며 오늘보다 큰 로그(추정 약 2.3~2.6 KB/호출)를 남긴다.
- **성능**: NOCACHE serial을 여러 세션이 쓰는 비HA 서버에서는 처리량이 로그 대역폭에 묶인다. comment 길이에 따라 3~4배 차이가 난다(debug 빌드 실측).
- **HA**: HA 환경에서는 이 이슈로 로그가 줄지 않는다(아래 "남는 위험").

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다. 출발점은 연구에서 세 설계와 교차 검토가 합의한 방향(아래 "Implementation 후보")이며, 아직 확정된 설계는 아니다.

---

## AI-Generated Context

## Description

### 용어

- **redo 전용 쓰기**: undo 로그 없이 redo 로그만 남기는 page 변경이다. 트랜잭션이 rollback해도 되돌아가지 않는다. 그래서 NEXT VALUE로 발급한 값이 rollback 뒤에도 다시 나오지 않는다.
- **relocation**: heap 행이 커져 원래 페이지(home)에 들어가지 못하면 다른 페이지로 옮겨진다. home slot은 8바이트 forward OID(`REC_RELOCATION`)만 갖고, 실제 행은 다른 페이지에 `REC_NEWHOME`으로 있다.
- **sysop**: 부모 트랜잭션 안의 짧은 하위 작업이다. commit하면 부모가 rollback해도 그 변경은 남는다. serial 경로는 서버 모드에서 HA 복제 표시(flush mark) 때문에 sysop을 연다.

### 근거 (Phase 0 결과)

모든 실행은 develop `de4f32740e` debug 빌드에서 했다. release 동작은 gdb로 debug 전용 assert만 건너뛰어 흉내 냈다.

| 가정 | 깨지는 조건 | 결과 | 근거 |
|---|---|---|---|
| 1. 행 크기 불변 | develop의 NUMERIC 디스크 크기는 값에 따라 4~20 B다(`numeric_opfunc.h:303-330`, CBRD-26006 이후). 이웃 serial의 `ALTER SERIAL ... COMMENT`로 page 여유가 소진된 뒤 255→256(+4 B)이 되는 경우 | redo를 먼저 남긴 뒤 `spage_update`가 실패한다. flush 전에 crash하면 재시작할 때마다 `logpb_fatal_error`로 끝난다. 즉 영구적으로 재시작할 수 없다 | 실행. CBRD-28271 |
| 2. 행이 REC_HOME | `ALTER SERIAL ... COMMENT`로 행이 relocation된 상태에서 NEXT VALUE | home 페이지에 공간이 없으면 assert 또는 재시작 fatal이다. 공간이 있으면 오류 없이 8 B stub 자리에 1140 B 본문을 쓰고, 재시작 뒤 serial이 카탈로그에서 사라진다. PK 키는 남으므로 같은 이름으로 다시 만들 수 없다 | 실행(SA, 서버, CACHE 5). CBRD-28272 |
| 3. 열 저장 형태 유지 | OOS 브랜치, 4K/8K page, 긴 comment | NEXT VALUE마다 OOS chain이 쌓이고, SA rollback 뒤 손상(-1397), savepoint rollback/crash 창 dangling, HA 반영 정지, latch 교착 가능성이 있다 | 실행·소스. CBRD-28073(#8514 keep_form으로 OOS 병합 시 해결 예정) |

**비용 기준선** (p0c, 실행, debug 빌드, 부하가 높은 공유 호스트):

| 측정 | comment 없음 | 256자 | 1000자(무작위) |
|---|---:|---:|---:|
| 서버, NOCACHE, 호출당 로그 | 272.2 B | 544.3 B | 1298.2 B |
| SA, NOCACHE, 호출당 로그 (sysop 없음, `RVHF_UPDATE` 단독) | 168.3 B | 440.3 B | 1184.5 B |
| 서버, CACHE 100, 호출당 로그 | 2.7 B | 5.5 B | 13.0 B |
| 서버 8세션, 행이 서로 다른 page | 115k~150k calls/s | - | 약 36k calls/s |
| 서버 8세션, 행이 같은 page | 약 30k calls/s | - | 약 26~30k calls/s |

- SA와 서버의 차이(약 104.7 B)는 sysop의 `LOG_SYSOP_END`다.
- 행이 다른 page에 있으면 처리량은 로그 바이트율 상한(이 환경에서 약 42~46 MB/s)에 묶인다. 8개 worker가 모두 prior list throttle에서 대기했다.
- 같은 page의 serial은 서로 다른 serial이어도 page WRITE latch로 직렬화된다.
- 서버 CPU 기준: 행 decode/encode와 로그 생성이 약 19%다(`heap_attrinfo_transform_to_disk` 8.0%, `log_append_redo_recdes` 4.6%(LZ4 2.2% 포함), `log_sysop_commit` 3.4%).

### 인벤토리 결과

develop과 OOS 브랜치를 검색했다(`spage_update`, `log_append_*_recdes*`, `heap_*_logical` 호출처) [소스].
- heap 사용자 행을 "redo 전용, 제자리, 행 전체 재인코딩"으로 쓰는 곳은 **serial 하나**다.
  - NEXT VALUE `serial.c:1432`
  - cache write-back `serial.c:1079`
  - 공통 함수 `serial.c:1561-1578`
- vacuum(`vacuum.c:2262` → `:2269`)은 행이 줄어들기만 하고 `spage_update`가 성공한 뒤에 로그를 남기므로 안전하다.
- 그 밖의 `_db_*` 쓰기는 `heap_update_logical`을 지난다.

따라서 serial을 고치고, 같은 패턴이 새로 생기지 않게 막으면 된다.

### 수정에서 반드시 지켜야 할 함정 (교차 검토에서 확인)

- **F0-1 병합 훅이 새 값을 버린다** [소스]
  - `heap_update_logical`은 `_db_serial` 행이면 `serial_row_write_begin`을 켠다(`heap_file.c:25615`). `REC_HOME`이면 `serial_row_write_keep_value`가 새 레코드의 `current_val`/`started`를 page의 이전 값으로 바꾼다(`heap_file.c:25665`, `serial.c:2250-2276`).
  - NEXT VALUE의 폴백이 이 훅을 타면 행에 옛 값이 남는다. 그러면 같은 값을 다시 발급한다.
  - safety net에서 이 훅을 우회한다. 이 이슈의 helper도 같은 우회를 써야 한다.
- **F0-2 undo 가능한 폴백과 CACHE** [소스+추정]
  - SA 모드(lock이 항상 X)나 같은 트랜잭션 DDL 뒤의 폴백은 부모 트랜잭션에서 undo 가능해야 한다. committed sysop으로 relocation을 확정하면, 뒤의 DDL undo가 home slot을 이전 전체 이미지로 덮어 NEWHOME이 고아가 되기 때문이다.
  - 그런데 그 폴백이 CACHE 블록을 예약하고 cache entry를 설치한 뒤 rollback되면, entry는 남고 행은 되돌아간다. 그러면 commit된 값이 다음 세션에서 다시 발급된다.
  - 이런 폴백의 블록은 cache에 설치하지 않는다. 이 대책은 safety net에 포함한다.
- **병합의 REC_HOME 제한** [소스]
  - DDL 쓰기 중 병합은 `REC_HOME`에서만 실행된다(`heap_file.c:25665`).
  - relocation된 행에서 NEXT VALUE가 성공하게 되면, 그 행의 ALTER가 동시에 발급된 값을 덮을 수 있는 창이 처음으로 도달 가능해진다.

### Implementation 후보 (ANALYSIS 출발점)

연구의 세 설계(상태 분리, 고정 폭 패치, 순수 인코더와 가드)와 교차 검토가 합의한 순서다. 이 중 이 이슈가 4A와 4C를 다룬다.

1. CBRD-28271/28272 safety net (develop, 선행. F0-1 우회와 F0-2 cache 설치 금지 포함)
   - 진행 중인 PR #8460(CBRD-27744, CBRD-27746, develop 대상, 열림)도 같은 `serial.c`, `heap_file.c`, `recovery.c`, `log_applier.c`를 바꾼다. 이 이슈는 그 PR이 병합된 뒤의 코드를 기준으로 설계해야 한다(아래 "남는 위험" 2, 3).
2. OOS 병합 (CBRD-28073 #8514 keep_form 그대로)
3. **4A, 이 이슈**
4. **4C, 이 이슈**
5. 4B (별도 일정)
6. release 측정
7. option 2 (조건부)

**4A. 가드된 재작성 helper**

1. **헬퍼 하나로 모은다.** serial 행의 모든 redo 전용 쓰기(NEXT VALUE, CACHE 블록 예약, write-back)를 heap 계층 helper 하나로 옮긴다. helper는 **로그를 쓰기 전에** 다음을 모두 확인한다.
   - page의 실제 slot 타입. 호출자의 recdesc 복사본 타입이 아니다.
   - `spage_is_updatable`
   - 새 OOS chain이 없을 것
   - MVCC 비활성 클래스일 것

   하나라도 맞지 않으면 아무것도 쓰지 않고 `S_DOESNT_FIT`을 돌려준다. 이렇게 하면 "redo는 남았는데 page는 그대로"인 상태가 만들어질 수 없다.
2. **행이 실제로 있는 slot에 쓴다.** `REC_RELOCATION`이면 forward page를 home과 함께 ordered fix(WRITE)로 잡는다. 그다음 `REC_NEWHOME` slot을 대상으로 값을 읽고, 계산하고, 쓴다. `page_was_unfixed`이면 처음부터 다시 읽는다(고정 폭 패치 설계의 `heap_get_record_for_inplace_write` 방식). 이렇게 하면 relocation이 지속되는 행이 매 호출 폴백을 타지 않는다.
3. **폴백.** 맞지 않을 때만 일반 `heap_update_logical`(relocation 처리)로 넘긴다. 이때 다음을 지킨다.
   - F0-1 병합 훅을 우회한다.
   - 기존 sysop 규칙을 따른다: non-X이면 sysop commit, X/SA이면 부모 트랜잭션.
   - F0-2 cache 설치를 금지한다.
4. **병합을 relocation 행으로 확장한다.** DDL 쓰기 중 병합(`serial_row_write_keep_value`)이 forward 레코드를 읽어 `REC_RELOCATION` 행에서도 동작하게 한다.
5. **재발 방지.**
   - debug 빌드: 이 helper 범위 밖에서 heap 행 RV index(`RVHF_*`)로 redo 전용 로그를 쓰면 assert가 걸린다. allowlist는 bestspace 등이다.
   - CI 검사: `spage_update`와 `log_append_redo_recdes*(…, RVHF_*)`를 allowlist 파일 밖에서 쓰면 실패한다.

**4C. 비HA partial redo와 sysop 생략**

- **partial redo.** `log_does_allow_replication ()`이 거짓이면 행 전체 이미지 대신 바뀐 바이트 구간만 새 heap RV index로 남긴다. 이 index의 번호는 OOS가 쓰는 137~144 뒤로 정한다.
  - 기존 범용 partial 형식과 적용 함수를 재사용한다: `log_rv_pack_redo_record_changes`(`log_recovery.c:6499`), `log_rv_redo_record_modify`(`log_recovery.h:41`). 형식은 `[offset 2B][old 1B][new 1B][bytes]`이고 4 B로 정렬한다. 지금 RV 표에는 이 함수를 쓰는 항목이 없다.
  - 이 형식은 old/new 크기가 달라도 되므로, NUMERIC 크기가 바뀌는 호출(256, 2^40 등을 넘을 때)도 맞으면 partial로 처리한다. 고정 폭 NUMERIC(wide form)은 필요 없다.
- **비HA에서는 sysop을 열지 않는다.** redo 전용 레코드 하나를 sysop으로 감쌀 이유가 없다. HA이거나 폴백일 때만 연다.
- **HA에서는 전체 이미지를 유지한다.** HA applier는 repl LSA가 가리키는 `RVHF_UPDATE`에서 행 전체 이미지를 읽기 때문이다(`log_manager.c:2298-2303`, `log_applier.c:4541`, `:4727`). 그래서 HA에서는 로그 형식이 바뀌지 않는다.

### 기대 효과 [추정, 계산]

- **로그 (비HA, NOCACHE)**: 호출당 약 60~75 B다. 계산은 `LOG_RECORD_HEADER` 32 B + `LOG_REC_REDO` 16 B + `current_val` 구간(4 B 메타 + 4~20 B 값, 4 B 정렬)이다. `started`가 바뀌는 첫 호출은 +8 B다.
  - p0c 서버 기준 comment 없음 272.2 B → 약 70 B(약 3.8배), 1000자 1298.2 B → 약 70 B(약 18배)다.
  - 호출당 로그가 comment와 이름 길이에 무관해진다. 255 B 미만이므로 LZ4 압축 시도도 없어진다.
- **처리량 (비HA, 행이 서로 다른 page)**: 로그 바이트율 상한으로는 수십만 calls/s가 되므로, 병목은 CPU와 latch로 옮겨간다. 실제 값은 release 측정이 필요하다.
- **같은 page의 serial**: page WRITE latch 직렬화는 그대로다. 줄어드는 것은 latch 보유 시간뿐이다(sysop과 로그 생성). 정체점이 얼마나 오르는지는 측정해야 한다.
- **CACHE 100**: 블록당 1회 쓰기이므로 호출당 1 B 미만이다.
- **HA**: 로그가 줄지 않는다(오늘과 같은 272~1298 B + 복제 레코드).
- **relocation 행**: 폴백 대신 NEWHOME 제자리 쓰기를 탄다. safety net만 있을 때의 호출당 약 2.3~2.6 KB(추정)를 피한다.

### 남는 위험과 열린 질문

1. **폴백 배타 제어와 잠금 순서**
   - NEXT VALUE는 serial 행 lock을 잡지 않는다(`serial.c:2206` 주석). 폴백의 relocation은 ordered fix 중에 home latch를 잠시 놓을 수 있다(`page_was_unfixed`, `heap_file.c:7466-7478`). 그 틈에 다른 세션이 옛 값을 읽을 수 있다 [소스+추정].
   - 후보는 OID 해시 stripe mutex다. 순서는 serial cache entry mutex → stripe mutex → page latch다.
   - 그러나 DDL flush가 앞 객체의 page latch를 쥔 채 `serial_row_write_begin`에서 mutex를 기다리면 교착될 수 있다(검토 H4-3, 확인 못함).
   - ANALYSIS에서 force scan cache의 latch 보유를 확인해야 한다. 그 결과로 mutex, transient lock, try-lock과 재시도 중에서 고른다.
2. **교차 트랜잭션 물리 undo (검토 H4-1)** [소스+추정]
   - 시나리오: T1이 ALTER로 X lock을 쥔다. 그 사이 cached XASL을 가진 T2의 NEXT VALUE가 폴백으로 행을 committed sysop 안에서 relocation한다. T1이 rollback한다.
   - T1의 undo는 이전 전체 이미지와 타입 `REC_HOME`으로 home slot을 덮는다. NEWHOME은 고아가 되고, T2가 발급한 값은 다시 발급된다.
   - stripe mutex로는 막을 수 없다. T1의 rollback은 mutex를 잡지 않기 때문이다.
   - 4A의 NEWHOME 제자리 쓰기 덕분에 폴백은 "맞지 않을 때"로 줄어든다. 그래도 구조 손상이 가능하다.
   - gdb로 창을 강제해 재현 여부를 확인하고, lock 기반 보호가 필요한지 정해야 한다.
   - PR #8460(CBRD-27744)은 DDL의 `_db_serial` 쓰기 undo를 논리 기록 `RVHF_SERIAL_DDL_UPDATE_UNDO`로 바꾸어, DDL rollback이 발급된 값보다 `current_val`을 뒤로 돌리지 않게 한다. 그 PR 본문에 따르면 "배치가 다른 행이나 페이지에 들어가지 않는 병합 행은 이전 행으로 되돌린다". 그래서 이 시나리오의 값 재발급은 그 PR이 다룰 가능성이 있다. 반면 relocation으로 NEWHOME이 고아가 되는 구조 손상까지 막는지는 확인하지 않았다. ANALYSIS에서 그 PR의 undo가 home slot이 `REC_RELOCATION`일 때 어떻게 동작하는지 확인해야 한다.
3. **HA에서는 로그 절감이 없다.** HA 고객의 NOCACHE 비용과 같은 page 경합은 이 이슈로 풀리지 않는다(후속 option 2의 조건).
   - PR #8460(CBRD-27746)을 적용하면 받는 노드는 serial 이미지에서 `current_val`/`started`만 반영하고, 발급 기록에 표시(`LOG_REPL_SERIAL_ISSUE_MAGIC`)를 붙인다. 보내는 쪽은 여전히 repl LSA의 행 이미지를 쓴다.
   - 그 위에서 보내는 노드가 값을 복제 기록 안에 직접 싣게 하면(write-back의 prior 값 부착 방식과 같은 형태), HA에서도 partial redo를 쓸 수 있을지 모른다. 이 이슈의 범위에 넣을지는 ANALYSIS에서 정한다.
4. **새 RV index의 파급.** rcvindex를 쓰는 분류 매크로와 목록을 모두 갱신해야 한다: `LOG_IS_MVCC_HEAP_OPERATION`, TDE의 rcvindex 목록(`tde.h:113` 계열), diagdb 덤프. 다운그레이드는 정상 종료(checkpoint) 뒤에만 가능하다. 번호는 OOS(137~144)와 PR #8460의 새 index 뒤로 정한다.
5. **SA와 X_LOCK 폴백의 의미 차이.** NOCACHE에서 undo 가능한 폴백을 탄 NEXT VALUE를 rollback하면 그 값이 다시 발급될 수 있다. 빈도는 낮다. 받아들일지 ANALYSIS에서 정한다.
6. **CDC 영향 없음.** `_db_serial`은 시스템 클래스라 행 supplemental 대상이 아니다(`heap_file.c:3008-3013`). 그래서 비HA partial 레코드를 CDC가 참조하지 않는다 [소스]. 다만 CDC reader가 모르는 RV index를 만났을 때의 동작은 실행으로 확인하지 않았다.

### 후속 이슈 (이 이슈의 범위 밖)

| 후속 | 내용 | 착수 조건 | 규모 (검토 보정치) |
|---|---|---|---|
| 4B 순수 인코더 | `heap_attrinfo_transform_to_disk`를 부수효과 없는 계획(`heap_record_plan`)과 인코딩으로 나눈다. keep_form을 정책값으로 흡수하고, 시스템 클래스는 `INLINE_ONLY`로 둔다. 레거시 즉시 OOS 게시 경로(`serial.c` 2곳, MVCC 재평가 copy area)를 제거한다 | OOS 병합이 안정된 뒤 별도 일정. 다음 중 하나가 생기면 앞당긴다: 데이터 page를 잡은 채 인코더를 부르는 새 writer, 이전 빌드 OOS stub을 담은 serial 이미지의 HA 반영 문제 확인 | 2~3주 |
| option 2 상태 분리 | `current_val`/`started`를 고정 32 B slot 파일로 옮긴다(`RVSERIAL_STATE_SET` 72 B). 같은 page 경합, HA 로그량, DDL과 NEXT VALUE 병합 문제를 구조적으로 없앤다 | 다음 중 하나: release 측정에서 4C 뒤에도 같은 page의 serial이 수만 calls/s에서 정체한다, HA 고객의 고빈도 NOCACHE 사용이 확인된다, F0-2/F0-3/H4-1 계열 중복 발급이 개별 규칙으로 계속 샌다, OOS 릴리스가 디스크 비호환으로 확정된다 | 8~12주. 선행 보완: page 헤더 `nused` 로그, 복제 프로토콜 버전 검사(옛 applier는 release에서 모르는 항목을 조용히 건너뛴다, `log_applier.c:5888-5891`), slot 세대 번호, `checkdb --repair` 값 후퇴 거부, 재시작 DDL logical undo |

고정 폭 NUMERIC 패치(wide form)는 채택하지 않는다. 비정규 NUMERIC 표현에 기대야 하고, 새 행마다 첫 쓰기에서 행을 넓혀야 해서 폴백 빈도가 늘어난다. 그 장점(NEWHOME 제자리 쓰기, partial redo 재사용)은 4A와 4C가 흡수한다.

## Specification Changes

- **사용자 SQL**: 바뀌지 않는다. `_db_serial`/`db_serial` 스키마와 값, NEXT VALUE 의미, AUTO_INCREMENT 동작이 그대로다.
- **디스크와 카탈로그**: 바뀌지 않는다. migration이 필요 없다.
- **로그**: 비HA 서버와 SA에서 새 heap RV index(partial redo)가 생긴다. HA에서는 로그 형식이 바뀌지 않으므로 HA 혼합 버전이 동작한다.

## Acceptance Criteria

- 다음 경우에 NEXT VALUE, CACHE 블록 예약, write-back이 모두 성공하고, 값이 중복되지 않고, `checkdb`가 통과하며, kill -9 뒤 재시작이 성공한다. SA와 서버 모드 모두 확인한다.
  - 행이 커져 page에 맞지 않을 때(이웃 COMMENT로 slack 소진 뒤 255→256)
  - 행이 relocation 상태일 때(home 페이지에 공간이 있는 경우와 없는 경우 모두)
- relocation이 지속되는 serial의 NEXT VALUE가 폴백 없이 NEWHOME 제자리 쓰기로 처리된다.
- 비HA 서버에서 NOCACHE NEXT VALUE의 호출당 로그가 comment 길이와 무관한 상수가 되고, 행 전체 이미지보다 작다(p0c와 같은 측정법). 목표 수치는 ANALYSIS에서 정한다. 추정치는 약 70 B다. HA에서는 로그 형식과 applier 동작이 바뀌지 않는다.
- 폴백이 serial 병합 훅에 값을 빼앗기지 않는다. 폴백 직후 NEXT VALUE가 다음 값을 돌려준다.
- relocation된 serial 행에서 ALTER와 동시 NEXT VALUE가 겹쳐도(gdb로 창을 강제), 이미 발급된 값이 다시 나오지 않는다.
- helper 밖에서 `RVHF_*` redo 전용 로그를 쓰는 코드는 debug 빌드 assert와 CI 검사에서 실패한다.
- OOS 병합 뒤 4K page DB에서 CBRD-28073 수락 조건(OOS 레코드 수 불변, SA rollback 뒤 comment 정상)을 계속 만족한다.

## Definition of done

**단위 / ctest:**
- helper: 맞으면 제자리, 맞지 않으면 `S_DOESNT_FIT`이고 로그 tail과 page LSA가 바뀌지 않는다. `REC_RELOCATION`이면 NEWHOME 대상이 된다. 새 chain이 있는 계획은 release에서도 거부한다.
- partial redo: runtime 패치와 회복 적용 결과가 바이트 단위로 같다. NUMERIC 크기 변화(255/256, 2^40) 구간도 확인한다.
- debug scope 검사가 동작한다.

**SQL / shell TC:**
- 성장 시나리오(이웃 COMMENT 뒤 255→256)
- relocation 시나리오 3종(공간 없음, 공간 있음, 공간 있음 + kill -9), CACHE 5
- 같은 트랜잭션 CREATE/ALTER + NEXT VALUE + rollback, savepoint rollback
- CACHE write-back(decache, shutdown)
- AUTO_INCREMENT 테이블로 `_db_serial` page를 채운 뒤 INSERT

**회복:**
- **release 빌드**에서 NEXT VALUE 반복 중 kill -9를 checkpoint 경계를 포함해 실행하고, 재시작 뒤 값이 단조 증가하는지 본다.
- 폴백 relocation의 `RVHF_INSERT_NEWHOME`과 `LOG_SYSOP_END` 사이에서 kill한다.
- H4-1 창을 gdb로 강제한 뒤 checkdb를 실행한다.

**동시성:**
- 같은 serial에 8세션 NOCACHE를 실행하면서 다른 세션의 COMMENT ALTER로 relocation과 복귀를 반복한다. 발급 값이 유일해야 하고, gdb 스냅샷에 교착이 없어야 한다.

**HA:**
- master/slave에서 relocation 행과 성장 행의 NEXT VALUE를 복제하고, `db_serial` 값이 일치하는지 본다.
- 혼합 버전(새 master + 옛 slave, 그 반대)을 확인한다.

**성능:**
- release 빌드에서 p0c와 같은 방식으로 측정한다(서버 stmt 20000회, `SHOW LOG HEADER` 차이로 B/call, 8세션 same/diff/sep 시나리오). 이 결과로 option 2 착수 여부를 판단한다.

**규모 (교차 검토 보정치, 추정):**
- 4A: 1.5~2주. safety net이 helper 모양으로 들어가면 그만큼 줄어든다.
- 병합의 relocation 지원: 2일.
- 4C: 3~4일.
- 회복·HA 시험: 약 1주.
- 합계 약 3~4주.

## Related Issues

- CBRD-28073: OOS에서 NEXT VALUE가 OOS chain을 쓰는 문제(keep_form). 이 이슈는 그 뒤의 일반화된 근본 수정이다.
- CBRD-28271, CBRD-28272: develop의 성장/relocation safety net. 이 이슈의 선행 작업이다.
- CBRD-28273: keep-form 분기의 자동 테스트.
- CBRD-28035, CBRD-28052: NEXT VALUE의 OOS chain 누수, SA rollback 손상. CBRD-28073으로 대체되었다.
- CBRD-27744, CBRD-27746 (PR #8460, 열림): DDL rollback이 발급 값을 되돌리는 문제와 HA serial 이미지 적용 방식. 같은 함수(`serial_update_serial_object`, `serial_row_write_keep_value`)를 바꾸므로 이 이슈는 그 PR 뒤에 설계한다.
