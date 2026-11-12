# [BUILD] GCC 11.5 최적화 빌드에서 파티션 키 반환 코드로 컴파일 실패

**한 줄 요약**: develop을 GCC 11.5로 최적화 빌드하면 `qo_node_partition_key()`의 지역 변수 주소 반환 경고가 오류로 처리되어 빌드가 중단된다.

## Issue Triage

**이슈 수행 목적**: GCC 11.5에서 경고를 비활성화하지 않고 develop의 최적화 빌드를 완료한다.

**이슈 수행 이유**: 현재 develop `98b892cf496ced0d1e7836f58189797f9842e1ec`에서 `-O2 -DNDEBUG -Werror` 조건으로 재현하였다.

**영향**: 해당 도구 체인으로 개발하거나 검증하는 엔지니어가 빌드 결과물을 만들 수 없다. 실행 중 잘못된 결과나 메모리 오류는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

`qo_node_partition_key()`는 지역 `DB_VALUE attr_name`에서 얻은 문자열 포인터를 반환한다. `db_get_string()`은 SMALL_STRING인 경우 `DB_VALUE` 내부 배열의 주소를 반환할 수 있어 GCC 11.5가 지역 변수 주소 반환을 진단한다. 실제 파티션 메타데이터에 SMALL_STRING이 생성되는지는 별도 확인이 필요하다. 이번에 확인한 문제는 컴파일 실패다.

이 함수는 [CBRD-27866의 PR #8356](https://github.com/CUBRID/cubrid/pull/8356)에서 추가되었다.

## Repro

- 소스 기준은 develop `98b892cf496ced0d1e7836f58189797f9842e1ec`이다.
- 컴파일러는 GCC/G++ 11.5.0, Red Hat 패키지 `11.5.0-5`이다.
- `RelWithDebInfo` 구성에서 `src/optimizer/query_planner.c`를 `-O2 -DNDEBUG -Werror`로 컴파일하였다.

```text
In function ‘const char* qo_node_partition_key(QO_NODE*, int*)’:
cc1plus: error: function may return address of local variable [-Werror=return-local-addr]
src/optimizer/query_planner.c:6806:12: note: declared here
 6806 |   DB_VALUE attr_name, part_count;
      |            ^~~~~~~~~
cc1plus: all warnings being treated as errors
```

## Expected Result

GCC 11.5의 최적화 빌드가 완료되고 기존 파티션 조인 동작을 유지한다.
