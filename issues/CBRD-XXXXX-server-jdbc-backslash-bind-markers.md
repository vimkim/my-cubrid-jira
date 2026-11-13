# [SP] 서버 측 JDBC가 '?' 바인드 변수 개수를 셀 때 no_backslash_escapes를 무시해, 백슬래시로 끝나는 문자열 리터럴이 있는 정상 SQL이 실패하는 문제

**한 줄 요약**: 복사된 코드에서 한쪽에만 들어간 수정을 찾는 감사(clone-drift audit)에서 나온 결함이다. Java SP와 PL/CSQL 동적 SQL이 쓰는 서버 측 JDBC는 SQL의 `?` 개수를 셀 때 `no_backslash_escapes`(기본값 `yes`)를 보지 않고 백슬래시를 항상 escape 문자로 취급한다. 그래서 `'C:\'`처럼 백슬래시로 끝나는 문자열 리터럴이 있으면 csql에서는 정상 실행되는 SQL이 바인드 오류로 실패한다. broker 쪽 같은 코드는 2012년에 고쳐졌지만, 2022년 C++ 이식(CBRD-23846) 때 그 조건이 주석 처리되었다.

## Issue Triage

**이슈 수행 목적**: Java SP의 서버 측 JDBC와 PL/CSQL 동적 SQL이 SQL 파서와 같은 문자열 리터럴 규칙으로 `?` 바인드 변수 개수를 세어, csql에서 실행되는 SQL이 서버 측에서도 같은 결과를 내게 한다.

**이슈 수행 이유**: `cubmethod::consume_tokens`(`src/method/method_query_util.cpp:608`, `:626`)는 `no_backslash_escapes` 검사를 주석으로 막아 두었다. 기본 설정에서 파서는 `'C:\'`를 완전한 문자열로 읽지만, 이 함수는 `\'`를 escape된 따옴표로 보고 문자열이 계속된다고 판단한다. develop과 같은 함수 본문인 debug 설치본(`11.5.0.2635-30043f4`)에서 PL/CSQL과 Java SP 모두 정상 SQL이 바인드 오류로 실패하는 것을 재현했다.

**영향**: 기본 설정을 쓰는 일반 사용자가 겪는다. Java SP의 `jdbc:default:connection:` prepare와 PL/CSQL `EXECUTE IMMEDIATE`에서 백슬래시로 끝나는 문자열 리터럴(예: Windows 경로 `'C:\'`)과 `?`가 함께 있으면 SQL이 실패한다. 리터럴 뒤의 `?`를 놓치면 "Missing or invalid position of the bind variable provided", 리터럴 안의 `?`를 바인드 변수로 세면 "not all the parameters are binded" 오류가 난다. 메모리 손상이나 잘못된 결과는 관찰하지 않았다. 사용자는 SQL을 바꾸거나 값을 바인드 변수로 넘겨 우회할 수 있지만, 오류 메시지만으로는 원인이 백슬래시라는 것을 알기 어렵다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

Java SP와 PL/CSQL이 서버 안에서 SQL을 실행하면 `cubmethod::query_handler`가 prepare를 처리한다. `query_handler::get_num_markers`(`src/method/method_query_handler.cpp:119-127`)는 `calculate_num_markers`(`src/method/method_query_util.cpp:508`)로 SQL 문자열의 `?`를 센다. 이 값은 prepare 응답의 `num_markers`(`method_query_handler.cpp:217`)로 Java 쪽에 전달된다. debug 빌드는 실행 때 이 값을 바인드 값 개수와 assert로 비교한다(`:588-589`, `:698-699`). 문자열 리터럴과 주석 안의 `?`는 `consume_tokens`가 건너뛴다.

broker의 원본 함수는 백슬래시를 escape로 볼지를 시스템 파라미터로 정한다.

```c
/* src/broker/cas_common_execute.c:225 (243도 같은 형태), develop e64a04a79a */
	  else if (cas_default_no_backslash_escapes == false && *p == '\\')
	    {
	      p++;
	    }
```

서버 측 C++ 복사본은 그 조건을 주석으로 막았다.

```cpp
/* src/method/method_query_util.cpp:608 (626도 같은 형태), develop e64a04a79a */
	    else if (/* cas_default_no_backslash_escapes == false && */ sql[index] == '\\')
	      {
		index++;
	      }
```

`no_backslash_escapes`의 기본값은 `yes`다(`src/base/system_parameter.c:2046-2052`). 이 설정에서 백슬래시는 일반 문자이므로 `'C:\'`는 완전한 문자열이다. `consume_tokens`는 이 백슬래시 다음의 `'`를 건너뛰고 문자열이 계속된다고 판단한다. 그래서 다음 두 가지 오류가 생긴다.

- 리터럴 뒤의 진짜 `?`를 문자열 안으로 보고 세지 않는다(실제 1개, 계산 0개).
- 다음 리터럴의 여는 따옴표를 닫는 따옴표로 보고, 그 리터럴 안의 `?`를 바인드 변수로 센다(실제 0개, 계산 1개).

PL 서버의 `SUStatement`(`pl_engine/pl_server/src/main/java/com/cubrid/jsp/impl/SUStatement.java`)는 이 개수를 기준으로 바인드를 검사한다. 계산이 0개이면 `bindValue`(`:231-235`)가 첫 바인드를 `ER_BIND_INDEX`("Missing or invalid position of the bind variable provided")로 거부한다. 계산이 1개인데 바인드가 없으면 `execute`(`:251-254`)가 `ER_NOT_BIND`("Attempt to execute the query when not all the parameters are binded")를 낸다.

같은 파일의 `get_backslash_escape_string`(`method_query_util.cpp:48`)은 이미 `PRM_ID_NO_BACKSLASH_ESCAPES`를 읽는다. 서버 측에서도 이 파라미터 값을 읽을 수 있다.

### 이력

| 커밋 | 날짜 | 내용 |
| --- | --- | --- |
| `9a221564b3` | 2012-07-10 | CUBRIDSUS-8197: broker `get_num_markers()`가 잘못된 바인드 변수 개수를 돌려주던 문제 수정 |
| `2bb2031711` | 2012-08-29 | CUBRIDSUS-7481: CAS prepare 시 호스트 변수 개수 계산 수정 |
| `d37359b032` | 2022-04-06 | [CBRD-23846](https://jira.cubrid.org/browse/CBRD-23846): Java SP를 서버 측에서 처리하도록 재설계. `method_query_util.cpp`의 C++ 복사본이 `no_backslash_escapes` 조건을 주석 처리한 채 추가됨 |

broker 코드를 서버 측 C++로 옮기면서 한쪽 수정이 빠진 경우다. 같은 이식에서 생긴 다른 사례는 아래 관련 이슈의 CBRD-28080이다.

### Test Build

- 실행: CUBRID 11.5.0 (11.5.0.2635-30043f4) 64bit debug build, GCC, Linux. 새 DB, 기본 `cubrid.conf`(`no_backslash_escapes=y` 확인).
- 소스 확인: CUBRID develop `e64a04a79a`. `30043f4`는 이 커밋의 조상이다. 두 커밋 사이에 `calculate_num_markers`와 `consume_tokens`의 판단 로직은 같고, `consume_tokens`의 인자 형식만 `std::string`에서 `const std::string &`로 바뀌었다. `e64a04a79a` 빌드에서는 실행하지 않았다.

### Repro

```sh
cubrid createdb --db-volume-size=64M --log-volume-size=64M d1db en_US.utf8
cubrid server start d1db
csql -u dba d1db -i repro.sql
```

`repro.sql`:

```sql
;server-output on
CREATE TABLE t (p VARCHAR(20), id INT);
INSERT INTO t VALUES ('C:\', 1);
SELECT COUNT(*) FROM t WHERE p = 'C:\' AND id = 1;
SELECT COUNT(*) FROM t WHERE p = 'C:\' OR p = '?';
CREATE OR REPLACE PROCEDURE p_dyn (x INT) AS n INT; BEGIN EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM t WHERE p = ''C:\'' AND id = ?' INTO n USING x; DBMS_OUTPUT.put_line ('dyn n=' || n); END;
CALL p_dyn (1);
CREATE OR REPLACE PROCEDURE p_dyn2 (x INT) AS n INT; BEGIN EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM t WHERE p = ''C:\'' OR p = ''?''' INTO n; DBMS_OUTPUT.put_line ('dyn2 n=' || n); END;
CALL p_dyn2 (1);
CREATE OR REPLACE PROCEDURE p_ok (x INT) AS n INT; BEGIN EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM t WHERE p = ''C:/'' AND id = ?' INTO n USING x; DBMS_OUTPUT.put_line ('ok n=' || n); END;
CALL p_ok (1);
CREATE OR REPLACE PROCEDURE p_ok2 (x INT) AS n INT; BEGIN EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM t WHERE p = ''C:/'' OR p = ''?''' INTO n; DBMS_OUTPUT.put_line ('ok2 n=' || n); END;
CALL p_ok2 (1);
CREATE OR REPLACE PROCEDURE p_static (x INT) AS n INT; BEGIN SELECT COUNT(*) INTO n FROM t WHERE p = 'C:\' AND id = x; DBMS_OUTPUT.put_line ('static n=' || n); END;
CALL p_static (1);
;get no_backslash_escapes
```

Java SP는 아래 클래스를 `javac BsTest.java`와 `loadjava d1db BsTest.class`로 올린 뒤 실행했다.

```java
import java.sql.*;

public class BsTest {
  public static String q1(int x) {
    return run("SELECT COUNT(*) FROM t WHERE p = 'C:\\' AND id = ?", x, true);
  }
  public static String q2() {
    return run("SELECT COUNT(*) FROM t WHERE p = 'C:\\' OR p = '?'", 0, false);
  }
  public static String q3(int x) {
    return run("SELECT COUNT(*) FROM t WHERE p = 'C:/' AND id = ?", x, true);
  }
  private static String run(String sql, int x, boolean bind) {
    try {
      Connection c = DriverManager.getConnection("jdbc:default:connection:");
      PreparedStatement ps = c.prepareStatement(sql);
      if (bind) ps.setInt(1, x);
      ResultSet rs = ps.executeQuery();
      rs.next();
      return "n=" + rs.getInt(1);
    } catch (Exception e) {
      return "EXC " + e.getClass().getSimpleName() + ": " + e.getMessage();
    }
  }
}
```

```sql
CREATE OR REPLACE FUNCTION jq1 (x INT) RETURN VARCHAR AS LANGUAGE JAVA NAME 'BsTest.q1(int) return java.lang.String';
CREATE OR REPLACE FUNCTION jq2 () RETURN VARCHAR AS LANGUAGE JAVA NAME 'BsTest.q2() return java.lang.String';
CREATE OR REPLACE FUNCTION jq3 (x INT) RETURN VARCHAR AS LANGUAGE JAVA NAME 'BsTest.q3(int) return java.lang.String';
SELECT jq1 (1);
SELECT jq2 ();
SELECT jq3 (1);
```

### Expected Result

서버 측 SQL도 csql에서 직접 실행한 같은 SQL과 같은 결과를 낸다. `p_dyn`, `p_dyn2`, `jq1`, `jq2`는 오류 없이 `COUNT(*)` 값 1을 돌려준다.

### Actual Result

| 실행 | 실제 `?` | 결과 |
| --- | --- | --- |
| csql 직접 `SELECT COUNT(*) FROM t WHERE p = 'C:\' AND id = 1;` | - | 정상, `1` |
| csql 직접 `SELECT COUNT(*) FROM t WHERE p = 'C:\' OR p = '?';` | 0 | 정상, `1` |
| `CALL p_dyn (1)` (PL/CSQL 동적 SQL) | 1 | `ERROR: Stored procedure execute error: (line 1, column 59) Missing or invalid position of the bind variable provided` |
| `CALL p_dyn2 (1)` (PL/CSQL 동적 SQL) | 0 | `ERROR: Stored procedure execute error: (line 1, column 60) Attempt to execute the query when not all the parameters are binded` |
| `SELECT jq1 (1)` (Java SP) | 1 | `CUBRIDServerSideException: Missing or invalid position of the bind variable provided` |
| `SELECT jq2 ()` (Java SP) | 0 | `CUBRIDServerSideException: Attempt to execute the query when not all the parameters are binded` |
| 대조: `CALL p_ok (1)`, `CALL p_ok2 (1)`, `SELECT jq3 (1)` (`'C:/'`로 바꿈) | 1, 0, 1 | 모두 정상(`ok n=0`, `ok2 n=0`, `n=0`) |
| 대조: `CALL p_static (1)` (PL/CSQL 정적 SQL) | - | 정상, `static n=1` |
| `;get no_backslash_escapes` | - | `no_backslash_escapes=y` |

백슬래시만 슬래시로 바꾼 대조군은 모두 정상이다. 따라서 실패 조건은 백슬래시로 끝나는 리터럴이다.

### Additional Information

ANALYSIS에서 확인할 사항:

- `no_backslash_escapes=no`로 바꾼 세션에서 서버 측 계산이 맞는지는 실행하지 않았다. 코드상으로는 이 설정에서 현재 동작이 파서와 일치한다(추론).
- 큰따옴표 리터럴(`:626`)도 같은 형태지만 실행으로 확인하지 않았다.
- release 빌드에는 `assert (num_bind == (int) bind_values.size ())`(`method_query_handler.cpp:589`, `:699`)가 없다. 오류 메시지로 보아 이번 재현의 네 경우는 모두 `SUStatement`의 검사가 실행 전에 막았다(추론). 이 검사를 통과한 채 개수가 어긋나 서버 실행까지 가는 조합이 있는지는 확인하지 않았다.
- `calculate_num_markers`의 `sql[++i] == ':'`(`method_query_util.cpp:523`)는 `?` 바로 다음 문자를 검사 대상에서 빼고 건너뛴다. 이번 결함과 원인이 다르며 코드로만 확인했다. 같은 함수를 고칠 때 함께 볼지 ANALYSIS에서 정한다.

### 관련 이슈

| 이슈 | 관계 |
| --- | --- |
| [CBRD-27718](https://jira.cubrid.org/browse/CBRD-27718) | 관련. PL/CSQL lexer와 본문 저장이 `no_backslash_escapes=no`에서 SQL lexer와 어긋나는 문제다. 이 이슈는 기본값 `yes`에서 서버 측 JDBC의 `?` 개수 계산이 어긋나는 문제라 코드와 조건이 다르다. |
| [CBRD-26529](https://jira.cubrid.org/browse/CBRD-26529) | 관련. 클라이언트 JDBC로 `CREATE PROCEDURE`를 prepare할 때 PL/CSQL 본문의 정적 SQL 안 `?`를 바인드 변수로 세는 문제다. 같은 "`?` 개수를 잘못 센다" 증상이지만 계산 위치(클라이언트 드라이버·CAS)와 원인이 다르다. |
| [CBRD-28080](https://jira.cubrid.org/browse/CBRD-28080) | 관련. 같은 broker → 서버 측 C++ 이식에서 `convert_db_value_to_string`의 NULL 검사가 빠진 문제다. |
