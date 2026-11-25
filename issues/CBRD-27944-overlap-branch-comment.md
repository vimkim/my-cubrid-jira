### 기존 이슈와의 중복 범위 및 브랜치 귀속 검토

2026-11-05에 이슈 중복, INSERT undo·회수 힌트 경로, 공통 파일 할당 경로를 독립적으로 검토하고 결과를 대조했습니다.

**권고는 구체적인 가설과 근거를 CBRD-27925에 보존한 뒤 추적을 통합하는 것입니다. 삭제는 권고하지 않습니다.** 이번 댓글은 상태 변경이나 이관 완료를 뜻하지 않습니다.

[CBRD-27925](https://jira.cubrid.org/browse/CBRD-27925)는 abort 잔여 두 페이지의 진입 시 emptiness·page LSA·latch와 최종 reclaimed/deferred/skipped 결과를 같은 호출에 연결하도록 이미 요구합니다. 이번 이슈는 그 조사에 추가할 구체적인 원인 가설입니다. 과거 잔여 두 페이지가 실제로 이번 순서를 겪었다고 확인한 것은 아닙니다. [CBRD-27872](https://jira.cubrid.org/browse/CBRD-27872)의 INSERT rollback 이후 회수 요구와도 연관됩니다.

현재 `feature/oos-merge`의 `d52b1889e907abcf84190ec504dde3bc93de260d`에서도 다음 근거가 남아 있습니다.

- [INSERT undo의 삭제 알림](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/oos_file.cpp#L3649-L3673)은 페이지가 아직 고정된 상태에서 발생합니다.
- [조건부 READ 획득 실패](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/oos_file.cpp#L1570-L1604)는 기본 SKIPPED로 반환됩니다.
- [lap 종료 정산](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/oos_file.cpp#L1777-L1798)은 시작 건수를 차감하고 유예 건수를 더합니다. 다른 알림·유예·성공 회수가 없는 모델 순서에서는 힌트가 0이 되는 후보가 남습니다.

비교한 develop은 `be0a9ab1fd83daa509f5ca53dcc03f6c3cbea16d`입니다. 해당 revision에는 OOS 파일별 회수 상태와 이 sweep 경로가 없습니다. 따라서 **이 후보의 귀속은 OOS입니다.** develop에 다른 형태의 공간 재사용 결함도 없다는 주장은 아닙니다.

통합 시에는 삭제 알림, sweep 시작 건수, READ 획득 실패 결과, lap 정산, 후속 재방문을 같은 실행에 연결하는 검증 조건을 27925에 남겨야 합니다. 자료와 조건을 보존하고 담당자가 동의한 뒤 Duplicate 종료를 권고합니다. 과거 2차 WRITE 실패 수리인 [CBRD-26786](https://jira.cubrid.org/browse/CBRD-26786)와 동일한 경로로 취급하지 않습니다.

기존 모델·추출 소스 실행 기준은 `f67f2f692a7ad9f9efada2178759ca713e596b9d`입니다. 이후 bestspace의 대기 설정이 바뀌었으므로 기존 실행을 최신 브랜치의 실제 DB 재현으로 취급하지 않습니다. 실제 발생과 추가 공간 할당 여부는 미확인입니다. **서버·DB를 이용한 재현은 팀장 승인 후 진행한다는 조건을 유지합니다.**
