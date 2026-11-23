# [OOS] 빈 OOS 페이지를 반환하지 않고 제자리에서 재사용하는 방안의 채택 여부 결정 (ADR-0011)

**한 줄 요약**: CBRD-27925를 PR #8434로 종결하면서 분리한 후속 이슈다. Draft PR #8493이 구현한 ADR-0011(빈 OOS 페이지를 반환·재할당하지 않고 그 자리에서 다시 쓰고, vacuum fast path를 없앤다)은 2026-11-05 미팅 결정을 바꾼다. 측정된 이득과 대가를 근거로 채택 여부를 정한다. ADR-0010까지의 OOS 코드는 2026-11-20 develop에 병합되었으므로([PR #7990](https://github.com/CUBRID/cubrid/pull/7990)), 채택하면 develop 대상 변경이 된다.

## Issue Triage

**이슈 수행 목적**: 같은 OOS 파일이 빈 페이지를 다시 쓸 때 거치는 페이지 반환과 재할당을 없애, 큰 값을 반복해서 넣고 지우는 테이블의 로그와 할당 비용을 줄인다. "회수 가능한 빈 페이지가 있으면 새 섹터를 예약하지 않는다"는 규칙(ADR-0009)은 그대로 지킨다.

**이슈 수행 이유**: PR #8434(ADR-0010)로 성장 전 회수 규칙은 충족했다. 하지만 지금도 빈 페이지는 `file_dealloc`으로 파일 관리자에 반환한 뒤 다음 `file_alloc`으로 다시 받는다. 영구 파일의 섹터는 `file_destroy`에서만 디스크로 돌아가므로 이 반환은 공간을 만들지 않는다. 반환된 페이지를 쓸 수 있는 것은 같은 파일의 다음 할당뿐이다. Draft PR #8493이 이를 제자리 재사용으로 바꾼 구현과 측정을 갖췄다. 다만 미팅에서 정한 vacuum fast path 유지를 뒤집으므로 따로 판단해야 한다.

**영향**: 단일 세션 churn 측정(release 빌드)에서 INSERT 1,000건당 로그 레코드가 39% 줄고, DML 중 페이지 반환·할당 system operation이 사라졌다. 대량 UPDATE는 약 14% 빨라졌고 단건·동시 INSERT와 섹터 수는 같았다. 기존에 원인을 모르던 UPDATE 뒤 vacuum drain 지연(0.34 s → 2.4 s)과 재초기화~INSERT 사이 crash 검증 공백은 추가 검증으로 모두 해소되었다. 남는 대가는 빈 페이지가 파일에 할당된 채 남아 `SHOW HEAP OOS`·`spacedb`의 사용 페이지 수가 커지는 점과, 여러 OOS 파일이 동시에 churn하는 경우 및 집합 상한(4,096쪽) 도달을 아직 재지 않았다는 점이다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 채택 여부와 범위를 결정한다. 후보 구현은 Draft PR #8493(ADR-0011, 제안 상태)이다.

---

## AI-Generated Context

## Description

[OOS TODO CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978)의 후속이다. [CBRD-27925](https://jira.cubrid.org/browse/CBRD-27925)에서 2단계로 계획했던 "반환을 제자리 재사용으로 바꾸고 vacuum fast path를 없앤다"(2026-11-09 결정)를 이 이슈로 옮겼다. CBRD-27925는 1단계인 [PR #8434](https://github.com/CUBRID/cubrid/pull/8434)로 종결한다.

용어를 먼저 정리한다. OOS 파일에서 값을 지워 데이터 페이지가 완전히 비면, 그 페이지는 파일별 빈 페이지 집합에 들어간다(ADR-0010). 새 페이지가 필요한 INSERT를 "성장"이라 부른다. 성장은 새 섹터를 잡기 전에 이 집합의 페이지를 먼저 쓴다. vacuum fast path는 vacuum이 한 batch에서 비운 페이지를 batch 끝에서 바로 반환하는 최적화다.

### 지금의 동작 (ADR-0010, develop `68a9c7766f`)

- 성장이 집합에서 빈 페이지를 찾으면 그 페이지를 READ fix하고, OOS 헤더 페이지의 WRITE 래치를 잡고, 다시 WRITE fix해서 별도 system operation으로 반환한다. 헤더 래치는 그 system operation이 commit할 때까지 유지된다.
- 이어서 `file_alloc`이 두 번째 system operation으로 같은 페이지를 다시 받아 초기화한다.
- vacuum fast path도 batch가 비운 페이지를 같은 방식으로 반환한다. 이를 위해 `oos_delete`부터 vacuum heap 코드까지 빈 페이지 목록을 넘긴다.
- 모든 OOS INSERT는 페이지를 찾을 때 같은 헤더 WRITE 래치를 잡는다. 그래서 INSERT 경로에서 반환이 일어나면 같은 파일의 다른 INSERT가 기다린다.

### 후보 변경 (ADR-0011, Draft PR #8493)

- 성장은 집합의 후보를 조건부 WRITE 래치로 잡고, 그 래치 아래에서 이 파일의 빈 OOS 페이지이고 레코드가 들어갈 자리가 있는지 확인한 뒤 그대로 쓴다. 반환하지 않으며, 헤더 래치도 잡지 않는다. OOS 데이터 페이지는 `file_destroy`에서만 반환된다.
- 지워진 slot 때문에 자리가 모자라면 페이지를 새 OOS 페이지로 다시 초기화한다. 이 로그는 redo 전용(`RVPGBUF_NEW_PAGE`)이다. 빈 OOS 페이지를 대상으로 하는 undo는 없다. chunk 삭제는 redo 전용이고(ADR-0008), 아직 undo할 INSERT가 있는 페이지는 그 chunk를 갖고 있어 비어 있지 않기 때문이다.
- 지우기로 빈 페이지는 bestspace 캐시(모든 OOS 파일이 함께 쓰는 1,000칸)에 넣지 않고 집합에만 넣는다. 이렇게 하지 않으면 빈 페이지가 캐시를 채워, 반쯤 찬 페이지가 캐시에 들어가지 못하고 파일이 첫 cycle 뒤 약 5% 커졌다.
- vacuum fast path와 이를 위한 빈 페이지 목록 전달 코드(`emptied_vpids` 인자 등)를 지운다.
- 로그 레코드 종류와 저장 형식은 바뀌지 않는다.

설계 근거는 OOS 명세 [ADR-0011](https://github.com/vimkim/cubrid-oos-context/blob/08dd98a/docs/adr/0011-reuse-emptied-pages-in-place.md)(제안 상태)에 있다.

## Conflicts with Earlier Decisions

채택하면 아래 결정을 바꿔야 한다. 섹터를 늘리지 않는다는 규칙 자체(ADR-0009 결정 2)는 바뀌지 않는다.

| 기존 결정 | 내용 | ADR-0011과의 충돌 |
| --- | --- | --- |
| 2026-11-05 미팅 결정(CBRD-27925 본문) | vacuum fast path·growth-gate sweep과 빈 페이지 반환·성장 전 재사용 요구를 유지한다. | fast path를 없애고, 빈 페이지를 `file_destroy` 전까지 반환하지 않는다. |
| ADR-0009 결정 3 | vacuum fast path와 성장 sweep을 유지한다. fast path는 최적화이고 sweep이 보장이다. | fast path를 없앤다. 빈 페이지는 집합을 거쳐 성장으로만 재사용된다. |
| ADR-0010 결정 3 | 성장은 집합의 후보를 기존 2단계 회수(반환)로 검사한다. | 반환 대신 래치 아래 검증 뒤 그 자리에서 쓴다. |

쓰기가 없는 동안의 반환 요구는 미팅 당일 ADR-0009에서 이미 제외했다. 따라서 남은 쟁점은 fast path를 없애는 것과, 빈 페이지를 반환하지 않고 할당된 채 두는 것이다.

## Measured Benefit and Cost

출처: [성장 비용 측정: 재사용 우선 대 ADR-0010](https://github.com/vimkim/my-cubrid-docs/blob/0bb7ed8/cbrd-27872/growth-cost-reuse-measurement.md)([CBRD-27872](https://jira.cubrid.org/browse/CBRD-27872), 2026-11-11). release 빌드, 공용 서버에서 단일 세션으로 churn(UPDATE·DELETE·재INSERT 반복)을 돌렸다. 비교 대상은 PR #8434 당시 head `94ed2ea46`(ADR-0010)과 PR #8493 계열 `b24fe8741e`이다.

| 항목 | ADR-0010 | ADR-0011 후보 |
| --- | --- | --- |
| INSERT 1,000건당 로그 레코드 (DML 구간) | 10,166 | 6,241 (−39%) |
| UPDATE·재INSERT 중 `file_alloc` / `file_dealloc` 호출 | 1,283 / 240 | 0 / 0 |
| UPDATE·재INSERT 로그 페이지 쓰기 | 183 | 134 |
| 대량 UPDATE, cycle 2 이후 중앙값 (2,000행 / 6,000행) | 129 / 386 ms | 111 / 334 ms |
| 단건 INSERT, 동시 8세션 INSERT | 기준 | 차이 없음 (서버 실행 간 변동 2~4 ms 안) |
| churn 뒤 섹터 수 (2,000행 / 6,000행) | 32 / 94 | 32 / 94 |
| UPDATE 뒤 vacuum이 옛 chunk를 다 지우는 시간 | 0.34 s | 2.4 s |

- 로그 감소분 가운데 fast path 제거(`5d7eda23c`)가 약 19%, 제자리 재사용(`b8a7e5d74`)이 나머지를 줄였다.
- 빈 페이지를 할당된 채 둔다. 2,000행 churn에서 drain 뒤 할당 페이지는 ADR-0010이 1,001쪽, 후보가 2,101쪽이었다(`b24fe8741e` 이전 측정). 섹터 수가 같으므로 디스크 사용량은 늘지 않지만, `SHOW HEAP OOS`·`spacedb`에는 사용 중으로 보인다. ADR-0009는 idle 중 이렇게 보이는 것을 이미 정상으로 정했다.
- 측정 과정에서 결함 두 개를 찾아 고쳤다. 성장마다 집합 전체를 복사해 대량 UPDATE가 2.6배 느려진 문제(`f8cdfca747`)와, 빈 페이지가 bestspace 캐시를 채워 파일이 5% 커진 문제(`b24fe8741e`)다.

## Open Questions

- **vacuum drain 지연 (해소 — 검증 완료)**: UPDATE 뒤 vacuum이 옛 chunk를 다 지우는 시간이 0.34 s(filler 1개)에서 2.4 s(filler 12개)로 길어진 원인을 `er_log_vacuum` 추적으로 규명했다. ADR-0010에서는 vacuum worker가 `file_dealloc` sysop WAL(블록당 약 25~29쪽)을 쓰면서 후속 31쪽 로그 블록을 스스로 닫아(자가 폐쇄) filler 1개 만에 끝났으나, fast path 제거(`2d40794363`) 후에는 redo-only `RVOOS_DELETE`만 소량 기록하므로 외부 filler가 마지막 단일 31쪽 블록을 닫아야 한다(`REPEAT('f', 1500)` filler는 WAL에서 LZ4 압축되어 실제 `pageid` 전진이 약 2.07쪽이다). 대기·filler 없는 연속 churn 3종(2,000행 20 cycle 전체 churn, 500/1,000행 30회 연속 UPDATE, 4세션 동시 15회 UPDATE)에서 무한 누적이나 해소되지 않는 vacuum backlog는 없었고, 섹터 수도 ADR-0010 대비 같거나 작았다(500행 16 vs 17, 1,000행 24 vs 24, 동시 4세션 47 vs 48, 2,000행 36 vs 33~37 sector).
- **재초기화 crash (해소 — 검증 완료)**: 코드 전수 감사로 live `FILE_OOS` 데이터 페이지의 빈 페이지를 대상으로 하는 undo 경로가 0건임을 재확인했다. 또한 테스트 훅(`oos_test_exit_after_empty_page_reinit`)을 추가해 `RVPGBUF_NEW_PAGE`(redo-only) flush 직후 `RVOOS_INSERT` 전 crash 테스트 2건(단독 crash 및 선행 미커밋 `RVOOS_INSERT`로 재시작 UNDO 페이즈가 실제로 실행되는 경우)을 구현·통과시켜(로컬 커밋 `96fb566bcc`, Debug 빌드 `ctest` OOS 12/12 통과), 재시작 후 해당 페이지가 유효한 빈 `PAGE_OOS`로 남아 새 페이지 할당 없이 재사용되고 값이 보존됨을 확인했다.
- **검증 보고서**: 위 두 항목의 측정·타임라인·코드 감사 상세는 [기술 검증 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-28281/adr-0011-technical-verification.md)에 기록했다.
- **측정 범위**: 여러 OOS 파일의 동시 churn, 동시 쓰기와 rollback이 섞인 churn, 집합 상한(파일당 4,096쪽)에 닿는 경우, bestspace mutex 점유가 다른 OOS 파일에 미치는 영향은 재지 않았다.
- **PR 상태**: PR #7990의 develop 병합 뒤 PR #8493의 base를 develop으로 바꿨다. 원격 브랜치(`f1c78ce70b`)는 아직 11-12의 `feature/oos-merge` 위에 있어 develop과 충돌한다. triage 후 신규 crash 테스트 커밋(`96fb566bcc`, 로컬)을 포함해 develop으로 rebase하고 CI를 다시 돌려야 한다. rebase 전에는 `ctest -R oos` 53건이 모두 통과했고, rebase 뒤에는 부하가 큰 상태에서 51건이 통과, 나머지 2건은 단독 재실행으로 통과했다.

## Timing

이 이슈를 만들 때는 `feature/oos-merge`의 develop 병합 전에 넣을지 뒤에 넣을지를 함께 정하려 했다. 2026-11-20 PR #7990(`68a9c7766f`)으로 ADR-0010 상태가 develop에 먼저 들어갔으므로 이 선택은 끝났다. 채택하면 위 Open Questions를 정리한 뒤 develop 대상 PR로 넣는다. 반환 경로·fast path·빈 페이지 목록 API는 develop에 들어간 뒤 다시 지우게 된다. CBRD-26659의 회수 TC 5건은 병합 직전 `feature/oos-merge` `8c478d8559`에서 로컬로 통과했다.

## Acceptance Criteria

- [ ] 채택 여부를 결정하고, ADR-0011의 상태와 2026-11-05 미팅 결정의 변경 여부를 기록한다.
- [ ] 채택하면 반복 churn에서 섹터 수와 cycle별 peak가 ADR-0009 결정 4의 기준을 넘지 않는다. CBRD-26659의 회수 TC 5건으로 확인한다.
- [ ] 채택하면 churn 뒤 단건·동시 INSERT와 대량 UPDATE 시간이 ADR-0010보다 나쁘지 않다.
- [ ] 채택하면 vacuum drain 지연의 원인을 설명하거나, 그대로 받아들인다는 결정을 근거와 함께 기록한다.
- [ ] 채택하면 재초기화와 INSERT 사이 crash 뒤에도 페이지가 다시 쓰이고 값이 보존됨을 확인한다.
- [ ] 채택하지 않으면 PR #8493의 처리(종료 또는 보류)와 ADR-0011을 기각한 근거를 기록한다.

## Related Work

- [CBRD-27925](https://jira.cubrid.org/browse/CBRD-27925): 성장 전 회수 규칙. PR #8434로 종결하고 2단계를 이 이슈로 옮겼다.
- [CBRD-27781](https://jira.cubrid.org/browse/CBRD-27781): 확정 뒤 postpone·redo-only 회수(ADR-0008). 후보 변경은 이 회수 API의 빈 페이지 목록 반환을 없앤다.
- [CBRD-27872](https://jira.cubrid.org/browse/CBRD-27872): 새 페이지 할당 때 회수 검사 비용이 파일 크기에 비례하는 문제다. 위 측정은 이 이슈에서 했다. 그 본문 목적은 "빈 페이지는 결국 파일 관리자로 반환된다"는 보장을 유지한다고 적는다. 이 보장은 ADR-0009가 이미 쓰기가 있을 때로 좁혔고, ADR-0011을 채택하면 반환 자체가 없어진다.
- [CBRD-27213](https://jira.cubrid.org/browse/CBRD-27213): OOS bestspace를 heap 재설계 기반으로 바꾸는 이슈다. ADR-0011은 빈 페이지를 bestspace 캐시에서 빼므로, 두 변경이 겹치면 함께 검증한다.
- [CBRD-26659](https://jira.cubrid.org/browse/CBRD-26659): 회수 TC 5건(ADR-0009 판정).
