# CTP에 단일 SQL 테스트 실행 스크립트(`run_sql.sh`) 추가

#### **Description**

현재 CTP에서 SQL 테스트를 실행하려면 `ctp.sh sql -c conf`(전체 배치 실행) 또는 `ctp.sh sql --interactive`(수동 대화형 모드) 두 가지 방법만 존재합니다. 하지만 개발 중 단일 SQL 테스트 케이스를 빠르게 실행하고 싶은 경우가 빈번하며, 이를 위해 매번 conf 파일을 설정하거나 interactive 모드에 진입하는 것은 비효율적입니다.

특히 AI를 활용한 자동 버그 탐지 워크플로우에서 개별 SQL 테스트를 간편하게 실행할 수 있는 경량 도구가 필요합니다.

#### **Spec Changes**

- `CTP/bin/run_sql.sh` 신규 추가: `ConsoleAgent` 를 직접 호출하여 단일 SQL 테스트 파일을 실행하는 경량 래퍼 스크립트
- 사용법: `run_sql.sh <sql_file> [db_name]` (db_name 기본값: `basic`)
- `CTP/sql/configuration/Function_Db/testdb_qa.xml`: 커스텀 데이터베이스 설정 예제 추가
- `CTP/README.md`: `run_sql.sh` 사용법 및 커스텀 DB 설정 방법 문서 추가

#### **Implementation**

1. `CTP/bin/run_sql.sh` 스크립트 구현
   - `JAVA_HOME`, `CUBRID`, `CTP_HOME` 환경변수 유효성 검사
   - SQL 파일 존재 여부 확인
   - `ConsoleAgent` 를 직접 호출하여 지정된 데이터베이스로 단일 SQL 테스트 실행
   - `$CTP_HOME/sql/configuration/Function_Db/<db_name>_qa.xml` 파일을 참조하여 DB 설정 로드

2. 커스텀 데이터베이스 지원
   - `testdb_qa.xml` 예제 파일 추가
   - 사용자가 자체 DB 설정 파일을 생성하여 커스텀 데이터베이스로 테스트 가능

3. 문서화
   - README에 사용법, 필요 환경변수, 커스텀 DB 설정 방법 기술

#### **Acceptance Criteria**

- `run_sql.sh test.sql` 실행 시 기본 데이터베이스(`basic`)로 정상 테스트 수행 및 결과 출력
- `run_sql.sh test.sql testdb` 실행 시 지정된 데이터베이스로 정상 테스트 수행
- 인자 누락 또는 환경변수 미설정 시 적절한 에러 메시지 출력
- 존재하지 않는 SQL 파일 지정 시 에러 메시지 출력

#### **Definition of Done**

- A/C 충족
- 코드 리뷰 완료
- PR 머지 완료
