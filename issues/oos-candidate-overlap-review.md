# OOS 후보 중복 및 브랜치 귀속 검토

사용자는 CBRD-27944·27945가 기존 조사와 겹치는지, develop에도 해당하는지 확인하여 이슈 정리와 실제 DB 재현의 다음 결정을 내리려 한다. 독립 소스·이슈 검토를 대조한 결과, **27944는 가설을 보존하고 27925로 통합할 것을 권고하고, 27945는 별도로 유지할 것을 권고한다. 두 이슈 모두 삭제를 권고하지 않는다.**

검토일은 2026-11-05다. 실제 DB 재현은 수행하지 않았다. 사용자가 승인한 외부 작업은 27944·27945의 댓글 게시다. 본문·담당자·상태 변경이나 삭제는 이번 범위에 없다.

## 판단

| 이슈 | 기존 이슈와의 관계 | develop 비교 | 권고 |
| --- | --- | --- | --- |
| [CBRD-27944](https://jira.cubrid.org/browse/CBRD-27944) | 27925의 abort 잔여 페이지와 회수 재시도 조사에 추가할 구체적인 원인 가설이다. 별도 완료 조건은 약하다. 과거 두 페이지의 원인을 입증한 것은 아니다. | 해당 OOS 알림·READ 실패·정산 경로가 없다. OOS에 귀속되는 소스 후보다. | 가설·증거·검증 조건을 27925에 보존하고 담당자 동의로 Duplicate 종료. 그 전에는 유지. 삭제하지 않는다. |
| [CBRD-27945](https://jira.cubrid.org/browse/CBRD-27945) | 27925와 상위 회수 요구는 같지만 메타데이터 포화와 재귀 예약 시점의 별도 검증 조건이 있다. 힌트 보존만으로 끝나지 않는다. | 재귀 할당의 공통 함수는 동일하다. OOS의 회수 요구와 유발 상태까지 develop에 연결한 증거는 없다. | 별도 OOS 조사로 유지. 27925가 검증 조건과 담당자를 명시적으로 맡을 때만 통합 검토. |

27944 브랜치 검토의 ‘조사 유지’와 중복 검토의 ‘27925로 통합’은 서로 다른 질문에 대한 답이다. 후보를 기각할 근거는 없지만 별도 티켓이 필요한지는 추적 범위로 판단한다. 27945도 같은 상위 요구만으로 중복 종료하면 재귀 예약 경계의 검증이 빠진다.

## 고정 소스와 직접 확인

| 대상 | revision |
| --- | --- |
| 기존 모델·추출 실행 기준 | `f67f2f692a7ad9f9efada2178759ca713e596b9d` |
| 가져온 origin/feature/oos-merge | `d52b1889e907abcf84190ec504dde3bc93de260d` |
| 가져온 origin/develop | `be0a9ab1fd83daa509f5ca53dcc03f6c3cbea16d` |

27944의 [조건부 READ 실패](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/oos_file.cpp#L1570-L1604)와 [lap 정산](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/oos_file.cpp#L1777-L1798)은 최신 비교 대상에서도 남아 있다. develop 고정 객체에는 해당 OOS 파일·상태와 경로가 없다. develop의 heap rollback과 bestspace는 별도로 확인했으며 같은 정산 경합을 입증하지 못했다.

27945의 [공통 재귀 할당](https://github.com/CUBRID/cubrid/blob/be0a9ab1fd83daa509f5ca53dcc03f6c3cbea16d/src/storage/file_manager.c#L5041-L5063)은 원래 메타데이터 확장 경로다. 여유 비트가 0이라는 장부 상태와 반환되지 않은 빈 OOS 페이지는 구분한다. OOS 쪽의 [예약 전 회수 요구](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/oos_file.cpp#L1262-L1272)와 예약 순간의 안전성을 함께 확인해야 결함으로 판단할 수 있다.

root는 아래 여섯 함수의 정의를 고정 객체에서 다시 추출해 세 revision의 SHA-256이 같은 것을 확인했다. 범위는 열 0의 함수 이름부터 열 0의 닫는 중괄호와 뒤 개행까지다. 파일 전체가 같다는 뜻은 아니다.

| 함수 | SHA-256 |
| --- | --- |
| file_header_alloc | `12384c275c167d133c5be305e1ee2bc19816c95baf00b1259ef6058b1b4974cb` |
| file_perm_expand | `d56662e5a2efa1b52fbc5c44506133fc1b3f231c3fc8316f615c33b50671a6f9` |
| file_table_add_full_sector | `98e30bdc9960ca1d6bca5357fe8306669e4e7ff253951beb93b5c24999bb2835` |
| file_perm_alloc | `af1f796e922bd6947d94d0e7b9f7f33526788dc3522db25248913baf2a3bb4bf` |
| file_alloc | `0720aa64135f3f684a67310d1783276fe20a346773256929c9fe607c46ea3230` |
| file_perm_dealloc | `c7a0ca828a915ab5412843485911bfdd8b98fa1248c005ab912ed90964b6e26c` |

f67 기준 이후 OOS의 bestspace zero-wait 설정이 제거됐고 vacuum·heap 주변 경로도 바뀌었다. 핵심 함수가 남아 있다는 사실로 예전 모델·추출 실행을 최신 전체 DB 실행의 증거로 취급하지 않는다.

## 기존 이슈 대조

- [CBRD-27925](https://jira.cubrid.org/browse/CBRD-27925)는 LSA gate 유예와 abort 잔여 두 페이지의 emptiness·latch·최종 결과 및 안전한 재방문을 이미 조사한다. 27944의 가설을 수용할 범위다.
- [CBRD-26786](https://jira.cubrid.org/browse/CBRD-26786)는 회수 요구와 과거 2차 WRITE 실패 수리다. 27944의 1차 READ 실패를 같은 수리로 취급하지 않는다.
- [CBRD-27872](https://jira.cubrid.org/browse/CBRD-27872)는 sweep 비용과 trigger 개정이다. INSERT rollback·recovery 이후의 회수 요구가 겹치므로 함께 검증해야 한다.
- [CBRD-27213](https://jira.cubrid.org/browse/CBRD-27213)는 부분 여유 공간의 bestspace·재시작 재발견이다. full-sector table의 재귀 할당과 다르다.
- [CBRD-26659](https://jira.cubrid.org/browse/CBRD-26659)는 회귀 테스트 범위이며 두 원인 후보의 별도 결함 보고가 아니다.
- [CBRD-27827](https://jira.cubrid.org/browse/CBRD-27827)는 동시 INSERT의 헤더 래치 오류·assertion 수리다. 회수 힌트 정산이나 메타데이터 재귀 예약과 완료 조건이 다르다.

초기 중복 검토는 위 이슈들의 본문과 전체 댓글을 읽었다. 넓은 검색의 첫 100개만 읽었던 한계는 새 검토자가 모든 페이지를 읽어 보완했다. `OOS`·`out-of-row` 검색은 156건을 100+56건으로, `reclaim`·`sweep`·`metadata` 검색은 150건을 100+50건으로 확인했다. 합집합은 277건이다. `pending_deletes`·`oos_reclaim_sweep_step`·`file_table_add_full_sector`를 찾는 초기 검색은 7건 전체를 반환했다.

추가로 26668·26609·26608·26658·27933·23945·21253·20185·26356·26358의 설명을 대조했으며 권고가 달라질 근거는 없었다. 26517·27873은 설명이 없어 제목만으로 담당 조사 범위를 확정할 수 없다. 검색 결과 전체의 페이지를 읽었다는 뜻이며, 키워드·접근 가능한 JIRA 색인 밖의 모든 과거 이슈까지 비중복이라고 보장하지 않는다. 추가 결과의 모든 댓글·첨부·변경 이력까지 읽은 것은 아니다.

페이지 순회에 사용한 JQL은 다음과 같다. 두 검색 모두 `--start-at 0`과 `--start-at 100`, `--max 100`으로 요청했다. 페이지별 total이 일치하고 각 검색에 중복 키가 없음을 확인했다. updated 정렬의 동시 변경 가능성은 남는다.

```text
project = CBRD AND (text ~ "OOS" OR text ~ "\"out-of-row\"") ORDER BY updated DESC
project = CBRD AND (text ~ "reclaim" OR text ~ "sweep" OR text ~ "metadata") ORDER BY updated DESC
```

## 사용자가 결정할 사항

1. 27944의 가설·근거·검증 조건을 27925에 보존한 뒤 Duplicate로 종료하는 추적 방식을 채택할지 결정한다. 댓글만으로 이관·종료가 완료되지 않는다. 27945는 별도 유지가 기본 권고다.
2. 팀장에게 실제 DB 재현의 목적·환경·실행 범위를 승인받는다. 권고 범위는 최신 OOS revision에서 27925에 통합할 rollback·회수 알림 가설과 27945의 예약 시점 검증을 포함한다. 승인 전 서버·DB 재현을 시작하지 않는다.

실제 결함 여부는 이후 증거로 판정할 사실이다. 아직 해결 알고리즘이나 명세 완화를 사용자가 고를 단계가 아니다. 승인 요청을 팀장에게 대신 전송하지 않았다.

## 검증과 한계

독립 검토 3개, 별도 통합 검토, 검색 페이지 보완을 root가 대조했다. 코드 직접 비교·함수 해시·이슈 본문·댓글이 근거다. 모델 반례, 의존 함수를 대체한 실행, 실제 DB 재현을 구분한다. 27945의 7개 섹터는 fixture 수치다. native 도달 가능성·빈도·디스크 비용은 미확인이다. partial-sector fixture를 이미 full인 섹터에 일반화하지 않는다.

Prove It Works 원칙은 고정 소스와 실제 게시 댓글을 직접 확인하는 선택에 적용했다. Separate Before Serializing Shared State 원칙은 각 작업자의 출력 경로를 나누고 root만 영구 문서·JIRA 댓글을 쓰는 선택에 적용했다.

검토 모델은 GPT-6.1 Terra와 GPT-6 Astra다. 사용 가능한 모델이 모두 GPT-6 계열이므로 서로 다른 모델 계열의 검토는 확보하지 못했다. 이는 독립 작업을 했다는 사실과 구분한다.

원본 작업 자료는 `/tmp/oos-candidate-review-20261105/`에 있다. 영구 기록은 이 문서, 두 댓글 원문, `oos-candidate-review-decisions.tsv`다. 게시 결과와 읽기 검증은 게시 후 별도 기록한다.
