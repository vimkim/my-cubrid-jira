# [HEAP] 지정한 시작 주소 대신 빈 주소를 조회하는 코드 오류

## Issue Triage

**이슈 수행 목적**: 호출자가 “이 데이터부터 읽어라”라고 지정하면 그 위치부터 정상적으로 읽기 시작하도록
한다.

**이슈 수행 이유**:

| 구분 | 동작 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | 시작 주소를 정상적으로 받지만, 실제 조회에는 아직 값이 없는 다른 주소를 사용한다. |
| **TO-BE (목표 상태 / 기대 동작)** | 호출자가 지정한 주소를 실제 조회에도 사용한다. |

**영향**: 설계 의도 훼손 — 함수가 약속한 입력을 그대로 처리하지 않으므로, 시작 위치를 지정하는 기능을
안전하게 사용할 수 없다.

**이슈 수행 방안**: 객체 조회에 사용하는 주소를 호출자가 지정한 시작 위치와 일치시키고, 유효한 시작 주소를
전달하는 회귀 테스트를 추가한다. 이미 삭제됐거나 현재 읽을 수 없는 주소를 받았을 때의 동작은
`TBD - 합의 미확인`이다.

---

## AI-Generated Context

> 아래는 AI가 develop 코드를 분석해 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로
> 충분하며, 본문은 구현과 리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/heap_file.c`의 내부 데이터 읽기 범위 처리에 한정된다. 현재 확인되는
  직접 호출 코드는 문제가 있는 입력 방식을 사용하지 않는다. SQL 문법, 디스크 저장 형식, 사용자가 호출하는
  공개 인터페이스는 바뀌지 않는다.

## Description

### 먼저 알아야 할 말

| 용어 | 뜻 |
|------|----|
| 객체 | CUBRID가 저장하고 읽는 데이터 한 건 |
| 변수 | 프로그램이 값을 보관하는 이름 붙은 칸 |
| 함수 | 정해진 일을 수행하는 코드 묶음 |
| `OID` | 객체가 저장된 위치를 나타내는 내부 주소. 사물함 번호와 비슷하다. |
| `NULL OID` | 아직 주소가 정해지지 않은 빈 상태 |
| `scanrange` | 여러 객체를 읽을 때 시작과 끝을 기록하는 읽기 범위 |

scanrange에는 두 개의 주소 칸이 있다.

| 변수 | 뜻 |
|------|----|
| `first_oid` | 이번 범위에서 처음 읽을 객체의 주소 |
| `last_oid` | 이번 범위에서 마지막으로 읽을 객체의 주소 |

### 어떤 코드 실수인가?

`heap_scanrange_start()`는 새 범위를 만들면서 `first_oid`를 NULL OID로 초기화한 뒤 그 값을 `last_oid`에
복사한다. 아직 시작 객체와 마지막 객체를 정하지 않았기 때문이다.

그다음 `heap_scanrange_to_following()` 함수에 유효한 시작 주소인 `start_oid`를 전달하면, 코드는 그 주소를
`first_oid`에 올바르게 복사한다. 그런데 바로 다음 줄에서 객체를 조회할 때 `first_oid`가 아니라 아직 비어
있는 `last_oid`를 전달한다.

```c
scan_range->first_oid = *start_oid;       /* 시작 주소를 이 칸에 저장함 */

scan = heap_get_visible_version (
         thread_p,
         &scan_range->last_oid,           /* 실수: 아직 빈 다른 칸을 사용함 */
         ...);
```

주소를 A 칸에 적어 놓고, 배달할 때는 비어 있는 B 칸을 읽는 것과 같다.

```text
호출자가 준 주소: valid_oid
        |
        v
first_oid = valid_oid
last_oid  = NULL
        |
        v
객체 조회에는 last_oid를 전달
        |
        v
호출자가 지정한 주소를 조회하지 못함
```

따라서 잘못된 변수를 객체 조회 함수에 넘긴 코드 실수다. 다만 어느 변수로 바꿀지가 겉으로 명확해 보여도,
지정한 객체가 이미 삭제됐거나 현재 읽기 시점에 보이지 않을 때 어느 객체부터 읽을지는 별도로 정해야 한다.

## Test Build

- 코드 확인 기준: CUBRID develop `a74fdf2e94fbce8be7f3addb8d036b55bbf47784`
- 최신 원격 develop 재확인: `8b870bbaf8e589c52c656caec594bc3e5611c42e`
- 확인 환경: Linux `5.14.0-570.30.1.el9_6.x86_64`, x86_64
- develop에서 실행 테스트는 아직 수행하지 않았다.

## Repro

다음 명령으로 develop 소스에 잘못된 변수 선택이 있는지 확인한다.

```bash
git checkout a74fdf2e94fbce8be7f3addb8d036b55bbf47784
nl -ba src/storage/heap_file.c | sed -n '8230,8325p'
```

출력에서 다음 순서를 확인할 수 있다.

```text
8235  OID_SET_NULL (&scan_range->first_oid);
8237  scan_range->last_oid = scan_range->first_oid;
8313  scan_range->first_oid = *start_oid;
8314  scan = heap_get_visible_version (thread_p, &scan_range->last_oid, ...);
```

현재 직접 호출 위치도 다음 명령으로 확인한다.

```bash
rg -n 'heap_scanrange_to_following \(' src --glob '*.c' --glob '*.cpp'
```

## Expected Result

`start_oid`로 받은 주소를 객체 조회에 사용해야 한다.

## Actual Result

`start_oid`를 `first_oid`에 저장하고도, 객체 조회에는 아직 빈 `last_oid`를 사용한다.

## Additional Information

- 함수 설명과 구현: `src/storage/heap_file.c:8267-8334`
- 잘못된 변수를 전달하는 코드: `src/storage/heap_file.c:8313-8315`
- 현재 직접 호출 위치: `src/query/scan_manager.c:5053`
- `heap_scanrange_to_following`, `scanrange`, `start_oid`로 기존 JIRA를 검색했으며 같은 결함은 확인하지 못했다.
