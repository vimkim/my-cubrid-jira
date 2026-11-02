# CBRD-27873 후속 이슈의 기존 기록 검색 및 생성 결과

2026-11-02에 기존 JIRA와 소스 수정 이력을 검색하고, 사용자가 요청한 OOS 1개와 non-OOS 4개를 생성했다. 이 기록은 이슈 생성과 중복 판단의 근거이며, 새로운 실행 재현 보고서가 아니다.

## Created issues

| 이슈 | 유형 | 부모 | 범위 |
|---|---|---|---|
| [CBRD-27874](http://jira.cubrid.org/browse/CBRD-27874) | Sub-task | CBRD-26978 | [OOS] 복합 인덱스 키 크기 계산 및 복제 OID 보정에서 VOT 접근 전 경계 검사 추가 |
| [CBRD-27875](http://jira.cubrid.org/browse/CBRD-27875) | Correct Error | 없음 | UPDATE 및 DELETE prepare 경로의 xasl_header stack-use-after-scope 수정 |
| [CBRD-27876](http://jira.cubrid.org/browse/CBRD-27876) | Correct Error | 없음 | 짧은 heap 레코드를 읽을 때 재사용한 속성 캐시의 불일치 처리 |
| [CBRD-27877](http://jira.cubrid.org/browse/CBRD-27877) | Correct Error | 없음 | 손상된 heap 레코드의 가변 필드 offset 및 VOT 순회 경계 검사 보강 |
| [CBRD-27878](http://jira.cubrid.org/browse/CBRD-27878) | Improve Function/Performance | 없음 | heap 레코드 writer의 미사용 padding 및 bound bit 초기화 |

모든 이슈는 생성 직후 JIRA에서 다시 읽었다. summary, description, type, parent 및 요청한 Relates 연결을 생성 dry-run payload와 비교했다. description은 변환된 JIRA 본문과 정확히 같았다. 상태는 모두 Open이었다. 담당자와 우선순위를 명시적으로 지정하지 않았다.

## Duplicate search

함수명과 관련 용어로 JQL을 실행하고 모든 페이지를 수집했다. 검색 결과에서 대상 심볼과 관련 문제를 확인했다. 아래 검색 범위에서는 같은 작업 범위를 맡은 별도 이슈를 찾지 못했다. JIRA 검색은 용어 기반이므로 전체 이슈의 의미적 중복이 없다는 보장은 아니다.

| 검색 | 결과 수 | JQL |
|---|---|---|
| xasl | 56 | `project = CBRD AND (text ~ "xasl_header" OR text ~ "stack-use-after-scope") ORDER BY updated DESC` |
| cache | 8 | `project = CBRD AND (text ~ "NULL_REPRID" OR text ~ "read_attrepr" OR text ~ "heap_rec_layout_init" OR text ~ "heap_attrinfo_recache") ORDER BY updated DESC` |
| bounds | 476 | `project = CBRD AND (text ~ "heap_attrvalue_point_variable" OR (text ~ "offset" AND (text ~ "corrupt" OR text ~ "bounds" OR text ~ "손상" OR text ~ "경계"))) ORDER BY updated DESC` |
| padding | 59 | `project = CBRD AND (text ~ "padding" OR (text ~ "초기화" AND (text ~ "레코드" OR text ~ "bound"))) ORDER BY updated DESC` |
| oos | 8 | `project = CBRD AND (text ~ "OR_VAR_IS_NULL" OR text ~ "heap_recdes_get_var_offset_pair" OR text ~ "heap_midxkey_get_oos_extra_size" OR text ~ "locator_fixup_oos_oids_in_recdes") ORDER BY updated DESC` |

## Previous fixes and scope differences

| 새 이슈 | 기존 기록 | 구분 근거 |
|---|---|---|
| CBRD-27874 | [CBRD-26950](http://jira.cubrid.org/browse/CBRD-26950), [PR #7695](https://github.com/CUBRID/cubrid/pull/7695), [PR #8299](https://github.com/CUBRID/cubrid/pull/8299) | 기존 수정은 OOS identity와 stub 경계 및 다른 grouped 읽기 호출처다. 키 크기 계산과 복제 OID 보정의 선행 OR_VAR_IS_NULL 읽기는 남아 있다. |
| CBRD-27875 | [CBRD-26768](http://jira.cubrid.org/browse/CBRD-26768), [PR #7144](https://github.com/CUBRID/cubrid/pull/7144), [PR #7476](https://github.com/CUBRID/cubrid/pull/7476) | a454b8eff는 SELECT만 수정했다. 532ce4b6d가 이후 UPDATE와 DELETE에 block-local header 포인터를 추가했다. |
| CBRD-27876 | [CBRD-27215](http://jira.cubrid.org/browse/CBRD-27215), CBRD-24539, CBRD-25984 | 오래된 NULL_REPRID 조기 반환과 b8199438e의 layout assert가 만나는 캐시 상태 전이가 대상이다. MIDXKEY 정리 및 함수 인덱스 개선과 다르다. |
| CBRD-27877 | [CBRD-26769](http://jira.cubrid.org/browse/CBRD-26769), [CBRD-26488](http://jira.cubrid.org/browse/CBRD-26488) | OOS 오류 전파나 MVCC header lookup이 아니라 일반 필드와 전체 VOT 순회 경계 검사다. 검사 없는 매크로는 8ac881d52 이전에도 있었다. |
| CBRD-27878 | [CBRD-21716](http://jira.cubrid.org/browse/CBRD-21716), [PR #7163](https://github.com/CUBRID/cubrid/pull/7163), CBRD-27109 | log header padding, catalog VOT 정렬 및 createdb charset 초기화와 구분한다. heap writer가 출력하는 미사용 바이트와 비트가 대상이다. |

기타 관련 이슈 CBRD-27368은 MVCC header 형식의 현대화 여부 조사이고, CBRD-20383은 XASL stream 포인터 구조 재편이다. 새 이슈들은 현재의 구체적인 입력 처리와 객체 수명 문제로 범위를 제한했다.

## Evidence limits

- non-OOS 소스 기준은 develop d5674fe94f08d084c6832ba4e3f6521d66cbee0e이다. 최신 develop 2b3158b66843052fdecadff60df864bbee84fab1의 DML 및 일반 reader 코드를 추가 확인했다.
- OOS 소스 기준은 PR #8299 head 5837393ffb9d69bccb93271d63b0e38b884e0ed4이다.
- 실행 결과의 출처는 [원본 리뷰](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr8299-adversarial-review_f8114e432_claude.md)다. 이번 작업에서는 재현 빌드, ASan, SQL 또는 HA 테스트를 새로 실행하지 않았다.
- OOS 두 호출처의 범위 밖 읽기는 코드 근거이며 실행 미확인이다. 손상 레코드 sweep 전체를 각 새 이슈의 최소 재현으로 주장하지 않았다.
- padding 차이는 기존 보고서의 관측이다. 민감 정보의 저장이나 백업 유출은 확인되지 않았다.

## Local records

각 이슈의 생성에 사용한 Markdown을 같은 번호의 파일로 보관했다. 문서 저장소의 task/cbrd-27873-followup-issues 브랜치에서 로컬 커밋한다. 사용자 요청은 JIRA 생성까지를 승인하며, main 병합과 push는 별도 Git 승인 대상으로 남긴다.

## Review correction

독립 검토에서 원본 리뷰 harness의 공개 상태가 초기 확인 내용과 달라졌음을 확인했다. 개인 fork의 [공개 브랜치](https://github.com/vimkim/cubrid/tree/CBRD-27785-review-harness), 커밋 `7472ed577850c13be1aed915691a35b6dec23b6b`를 직접 조회했다. CBRD-27876 본문의 로컬 전용 표현을 공개 링크로 정정한다. 이 이슈만의 최소 재현 입력과 실행 명령은 검증하지 않았다는 한계는 유지한다. 정정 후 JIRA 본문도 다시 비교한다.
