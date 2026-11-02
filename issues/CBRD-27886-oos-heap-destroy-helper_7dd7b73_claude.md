# [OOS] heap 삭제 경로 두 곳에 복사된 OOS 파일 정리 코드를 하나로 합친다

## Issue Triage

**이슈 수행 목적**: heap을 삭제할 때 그 heap의 OOS 파일을 찾아 지우는 코드를 한 함수로 모아, 앞으로 한쪽만 고쳐지는 일을 막는다.

**이슈 수행 이유**: `xheap_destroy`와 `xheap_destroy_newly_created`에 같은 18줄 블록(`heap_oos_find_vfid`로 OOS 파일을 찾고 `oos_remove_file`로 지우는 코드)이 따로 들어 있다.

**영향**: 정상 경로의 동작은 바뀌지 않는다. heap header 페이지가 손상되어 `heap_oos_find_vfid`가 에러 없이 실패하는 경우만 다르다. 기존 코드는 heap 파일과 OOS 파일을 모두 남긴 채 성공을 반환했고, 새 코드는 heap 파일을 정리하고 OOS 파일만 남긴다. debug 빌드에서는 두 경우 모두 같은 `ASSERT_ERROR`에서 멈춘다.

**이슈 수행 방안**: 블록을 `heap_oos_remove_file` helper로 옮기고 두 함수가 호출하게 한다.

---

## AI-Generated Context

- CBRD-27881의 OOS 리팩토링 후보 조사(`feature/oos-merge` dcbf09e4f 기준)에서 나온 다섯 번째 단위이다.
- 검증: OOS 관련 ctest 44개가 변경 전후 모두 통과했다. 기존 테스트는 `xheap_destroy_newly_created` 쪽 호출부에 닿지 않아, `DONT_REUSE_OID` 테이블을 직접 만들고 DROP해 gdb로 호출과 OOS 파일 삭제(diagdb file tracker)를 확인했다.
- 후속 후보: `DONT_REUSE_OID` 테이블을 DROP하는 OOS 단위 테스트가 없다.
