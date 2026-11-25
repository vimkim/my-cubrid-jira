### 기존 이슈와의 중복 범위 및 브랜치 귀속 검토

2026-11-05에 이슈 중복, OOS 회수 경로, 공통 파일 할당 경로를 독립적으로 검토하고 결과를 대조했습니다.

**권고는 CBRD-27925와 연결한 별도 OOS 조사로 유지하는 것입니다. 삭제는 권고하지 않습니다.** 이번 댓글은 상태 변경을 뜻하지 않습니다.

비교한 revision은 develop `be0a9ab1fd83daa509f5ca53dcc03f6c3cbea16d`, 기존 실험 기준 `f67f2f692a7ad9f9efada2178759ca713e596b9d`, 현재 `feature/oos-merge`의 `d52b1889e907abcf84190ec504dde3bc93de260d`입니다.

`file_header_alloc`, `file_perm_expand`, `file_table_add_full_sector`, `file_perm_alloc`, `file_alloc`, `file_perm_dealloc`의 함수 정의는 세 revision에서 바이트 단위로 같습니다. develop에도 [메타데이터 페이지의 재귀 할당](https://github.com/CUBRID/cubrid/blob/be0a9ab1fd83daa509f5ca53dcc03f6c3cbea16d/src/storage/file_manager.c#L5041-L5063), [예약 여유 공간 0 검사](https://github.com/CUBRID/cubrid/blob/be0a9ab1fd83daa509f5ca53dcc03f6c3cbea16d/src/storage/file_manager.c#L5185-L5201), [섹터 예약](https://github.com/CUBRID/cubrid/blob/be0a9ab1fd83daa509f5ca53dcc03f6c3cbea16d/src/storage/file_manager.c#L4678-L4687)이 있습니다. 이는 공통 할당 경로이며, 그 존재만으로 develop 결함을 주장할 수 없습니다.

이번 후보는 [OOS의 예약 전 회수 요구](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/oos_file.cpp#L1262-L1272)를 점검합니다. 앞선 sweep에서 유예한 빈 OOS 페이지가 실제 섹터 예약 전에 안전해지는 순서입니다. 파일 관리자의 여유 비트 수와 아직 반환하지 않은 빈 OOS 페이지의 존재는 서로 다른 상태입니다. rollback 완료만으로 안전성을 판정할 수 없으며, 예약 순간의 실제 transaction·system head, append clamp와 page LSA를 함께 확인해야 합니다. 같은 요구와 유발 상태를 develop의 소유자 경로에 연결한 증거는 없습니다.

[CBRD-27925](https://jira.cubrid.org/browse/CBRD-27925)와 상위 회수 요구는 겹칩니다. 다만 이번 이슈는 full-sector table 포화, 마지막 예약 여유 비트 소비, 메타데이터 재귀 진입과 예약 순간을 연결하는 별도 검증 조건이 있습니다. 모델에서는 회수 힌트가 남고 READ 실패를 유예로 처리해도 후보가 남습니다. 따라서 [CBRD-27944](https://jira.cubrid.org/browse/CBRD-27944)의 가설을 해결하거나 기각한 것만으로 이 조사가 끝나지 않습니다. [CBRD-27213](https://jira.cubrid.org/browse/CBRD-27213)의 bestspace 메타데이터·부분 여유 공간 재발견과도 구분합니다.

27925가 위 예약 시점의 검증 조건과 담당자를 명시적으로 맡으면 통합을 검토할 수 있습니다. 그 전에는 별도 유지가 적절합니다.

최신 feature에서도 관련 회수·할당 함수는 남아 있지만 bestspace 등 주변 경로가 바뀌었습니다. 기존 추출 실행의 7개 섹터는 일부 의존 함수를 대체한 fixture 결과이며 실제 DB의 디스크 증가 측정값이 아닙니다. partial-sector fixture를 이미 full인 섹터에 그대로 적용할 수도 없습니다. 최신 전체 실행의 도달 가능성과 실제 영향은 미확인입니다. **서버·DB를 이용한 재현은 팀장 승인 후 진행한다는 조건을 유지합니다.**
