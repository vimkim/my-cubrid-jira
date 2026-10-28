## Goal

OOS M1에서 미룬 운영 기능과 검증을 보완하여 `feat/oos` 를 `develop` 에 병합할 수 있는 품질을 확보한다.

## Scope

- UPDATE/DELETE 후 vacuum 정리, DROP TABLE 시 파일 회수, 빈 페이지 회수와 공간 재사용을 구현한다.
- 저장 정책, 오류 처리와 진단 기능을 보완한다.
- 복구·HA·유틸리티 연동을 검증하고, 회귀 오류 수정과 SQL/Shell/단위 테스트·CI 검증을 수행한다.

## Limitations

- OOS 압축, PEEK, 페이지 간 compaction 등 추가 최적화는 후속 작업으로 둔다.
- CDC/flashback의 OOS 이력 지원은 이번 병합 범위에서 제외한다.
- 개발 중인 OOS 디스크 포맷 간 호환은 보장하지 않으며, 포맷 변경 시 개발용 DB를 재생성한다.

세부 구현과 진행 상태는 아래 하위 작업에서 관리한다.
