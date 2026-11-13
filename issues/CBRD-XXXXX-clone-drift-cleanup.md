# [Cleanup] 복사본끼리 어긋난 검사·처리 5건 정리 (집계 hash key, schema info 죽은 코드, 기본값 NUL, critical section 시간 초과, compactdb 누수)

**한 줄 요약**: 중복 코드 drift 점검(한쪽 복사본에만 수정이 들어가고 다른 복사본은 남은 경우를 찾는 작업, CBRD-28080과 같은 유형)에서 즉시 장애로 이어지지는 않지만 정리가 필요한 5건을 찾았다. 각각 한두 줄 수정이거나 죽은 코드 제거라서 한 이슈로 묶는다.

## Issue Triage

**이슈 수행 목적**: 같은 일을 하는 두 복사본 중 한쪽에만 있는 검사나 처리를 다른 쪽에도 맞추거나, 쓰지 않는 복사본을 없앤다. 앞으로 이 코드 경로가 다시 쓰이거나 조건이 바뀔 때 이미 다른 쪽에서 고친 결함이 되살아나지 않게 한다.

**이슈 수행 이유**: 아래 5건은 모두 짝이 되는 코드에는 검사나 처리가 있고 이쪽에는 없다. 지금은 메모리 부족에서만 드러나거나(1), 호출 경로가 막혀 있거나(2, 4), 영향이 작다(3, 5). 하지만 같은 유형인 CBRD-28080은 실제로 client 비정상 종료로 이어졌다. 한 번에 정리하는 비용이 작다.

**영향**: 현재 사용자에게 확인된 장애는 없다. (1)은 메모리 부족 시 서버 비정상 종료 가능성, (3)은 서버 측 JDBC 열 메타데이터의 기본값 문자열 끝에 NUL 문자가 붙을 가능성이 있다(Java 쪽 처리는 확인하지 않았다). (2)는 기능을 다시 켜는 순간 7건의 결함이 한꺼번에 살아난다. (4), (5)는 현재 영향이 없다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

소스 기준은 develop `e64a04a79a`다. 모두 소스와 git 이력으로 확인했고, 실행으로 재현한 것은 없다.

### 1. `qdata_alloc_agg_hkey`가 `pr_make_value` 실패를 검사하지 않는다

- 검사가 있는 쪽: `src/query/query_hash_scan.c:232-239`는 `key->values[i] = pr_make_value ();` 뒤에 NULL이면 지금까지 만든 값을 해제하고 NULL을 반환한다. 이 검사는 hash list scan을 추가한 `e9e09485c7`(CBRD-23665)에서 들어왔다.
- 검사가 없는 쪽: `src/query/query_aggregate.cpp:2920-2923`은 `pr_make_value ()` 결과를 그대로 쓴다. 같은 파일 `:3022-3023`의 accumulator 값 할당도 같다.
- 호출자(`src/query/query_executor.c`의 hash GROUP BY 경로)는 key 자체가 NULL인지만 본다. `values[i]`가 NULL이면 이후 처리에서 역참조된다.
- `pr_make_value`는 malloc이 실패할 때만 NULL을 반환한다. 메모리 부족에서만 드러나고, 결과는 서버 비정상 종료다.

### 2. `method_schema_info.cpp`가 broker 쪽 수정 7건을 받지 못했다 (현재 도달 불가)

`src/method/method_schema_info.cpp`의 `schema_info_handler`는 broker `cas_execute.c`의 `sch_*` 함수를 C++로 옮긴 것이다. 옮긴 뒤 broker 쪽에 들어간 수정이 C++ 쪽에는 없다.

| # | 내용 | C++ 위치 | broker 쪽 수정 |
| --- | --- | --- | --- |
| 1 | `information_schema` 소유 클래스의 이름 한정 `CASE` 누락 | `:213-217`, `:300-309`, `:828-842`, `:915-922` | `8a64a3a10a` (CBRD-26859) |
| 2 | `sch_attr_info` 정확 일치 분기가 `a.attr_name` 대신 `a.class_name`을 비교 | `:360` | 처음부터 `a.attr_name` |
| 3 | `sch_queryspec`이 삭제된 열 `db_vclass.unique_name` 조회 | `:406` | `63fa361c7b` (CBRD-24379) |
| 4 | `sch_trigger`가 트리거 객체의 소유자를 쓰고, 소유자를 뺀 이름을 계산만 하고 쓰지 않음 | `:624`, `:632`, `:644` | `496c148d66` |
| 5 | `sch_class_priv`가 `class_name_only` 대신 `class_name`으로 패턴 비교 | `:742` | `63fa361c7b` |
| 6 | `sch_attr_priv`가 속성 이름 자리에 클래스 이름 전달 | `:795` | 처음부터 `attr_name` |
| 7 | `sch_primary_key` SQL 오타 `AMD`, 모호한 `owner_name` | `:932`, `:942` | `43b48e20ac` |

이 코드는 지금 실행되지 않는다. `src/method/method_callback.cpp:195-197`의 `METHOD_CALLBACK_GET_SCHEMA_INFO` 분기는 호출을 주석 처리하고 `assert (false)`만 남겼다. `schema_info_handler`를 만드는 유일한 코드도 주석 블록(`method_callback.cpp:526-541`) 안에 있다. 따라서 이 요청이 오면 debug 빌드는 assert로 멈추고 release 빌드는 빈 응답을 보낸다.

ANALYSIS에서 정할 것: 이 기능을 되살릴 계획이 없으면 파일과 분기를 지운다. 되살린다면 위 7건을 broker 쪽에 맞춰 고친 다음 켠다.

### 3. 서버 측 JDBC 열 기본값 문자열에 NUL이 하나 더 붙는다

- broker `src/broker/cas_execute.c:3861-3867`은 `'` + 값 + `'` 뒤에 C 문자열 종료 문자를 쓴다.
- C++ `src/method/method_query_util.cpp:762`는 `std::string`에 `push_back ('\0')`을 한다. 이 NUL은 문자열 길이에 포함되어 `column_info::default_value_string`(`src/method/method_struct_query.cpp:117`)을 통해 Java로 간다.
- 영향(추론): 서버 측 JDBC에서 열 메타데이터의 기본값 문자열 끝에 `\u0000`이 붙을 수 있다. Java 쪽에서 이를 어떻게 처리하는지는 확인하지 않았다.

### 4. `csect_enter_critical_section`의 시간 제한 대기가 시간 초과를 오류로 본다 (현재 영향 없음)

- `src/thread/critical_section.c:1290`(promote 경로)은 대기 결과로 `ER_CSS_PTHREAD_COND_WAIT`와 `ER_CSS_PTHREAD_COND_TIMEDOUT`을 모두 받아들인다.
- `critical_section.c:602`(enter 경로)는 `ER_CSS_PTHREAD_COND_WAIT`만 받아들인다. 시간 초과가 나면 assert 후 오류를 반환한다.
- 지금은 양수 대기 시간으로 enter를 부르는 호출자가 없다고 판단했다. 시간 제한 진입을 쓰기 시작하면 드러난다.

### 5. SA 모드 compactdb가 `tables` 배열을 해제하지 않는다

`src/executables/compactdb.c:130`에서 `malloc`한 `tables`를 해제하지 않는다. CS 쪽 복사본은 `src/executables/compactdb_cl.c:924`에서 해제한다. 프로세스가 끝나기 직전의 한 번뿐인 누수라 영향은 사소하다.

## Acceptance Criteria

- 1, 3, 4, 5: 짝이 되는 복사본과 같은 검사·처리를 하거나, 다르게 두는 이유를 주석으로 남긴다.
- 2: 파일을 지우거나, 7건을 고친 뒤 기능을 켠다. 어느 쪽인지 ANALYSIS에서 정한다.
- 3: 서버 측 JDBC로 기본값이 있는 열의 메타데이터를 읽었을 때 기본값 문자열 끝에 NUL이 없다.

## 관련 이슈

- CBRD-28080: 같은 유형(broker 원본의 NULL 검사가 C++ 이식본에서 빠짐)으로 실제 client 비정상 종료가 재현된 사례다.
- CBRD-28097: 같은 점검에서 찾은 다른 drift(서버 측 JDBC의 바인드 변수 개수 세기가 `no_backslash_escapes`를 무시)로, 별도 이슈로 등록되었다.
