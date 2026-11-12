**측정 근거의 시점에 대한 메모**

이 이슈의 성능 근거는 PR #7990 리뷰 당시의 측정이다. 리뷰어 보고는 PR head `dcbf09e`에서 쟀고, 본문의 수치(4~16KB 전체 읽기 −2.8%~−69.5%, 임계값을 한 페이지로 올린 빌드 −0.24%~+0.08%)는 [CBRD-27788](https://jira.cubrid.org/browse/CBRD-27788)에서 `feature/oos-merge` `67220b7e2`로 2026-11-11~12에 다시 잰 값이다.

OOS의 성능 관련 동작은 리뷰를 거치며 계속 바뀌고 있고, 아래 성능 개선 이슈들이 아직 열려 있다. 이 이슈들이 반영되면 손해의 크기와 임계값에 따른 trade-off가 달라질 수 있으므로, 그 뒤에 다시 측정해 이 이슈의 근거를 갱신할 예정이다. 재측정은 CBRD-27788에서 한다.

| 이슈 | 다루는 경로 |
| --- | --- |
| [CBRD-27791](https://jira.cubrid.org/browse/CBRD-27791) | 큰 값 조회의 읽기 지역성 |
| [CBRD-27725](https://jira.cubrid.org/browse/CBRD-27725) | OOS 분리 시점을 heap 쓰기 직전으로 미루는 방식의 비용 |
| [CBRD-27230](https://jira.cubrid.org/browse/CBRD-27230) | UPDATE에서 바뀌지 않은 OOS 값의 중복 적재 |
| [CBRD-27872](https://jira.cubrid.org/browse/CBRD-27872) | 새 OOS 페이지를 할당하는 INSERT가 파일 크기에 비례해 느려지는 문제 |
| [CBRD-27213](https://jira.cubrid.org/browse/CBRD-27213) | 재시작 뒤 OOS 빈 공간 재사용(bestspace) |
| [CBRD-26881](https://jira.cubrid.org/browse/CBRD-26881) | OOS 값 압축 |
| [CBRD-28011](https://jira.cubrid.org/browse/CBRD-28011) | SQL trace에서 heap 읽기와 OOS 읽기 비용 구분(측정 도구) |

그때까지 본문의 수치는 `67220b7e2` 기준의 참고값으로 본다.
