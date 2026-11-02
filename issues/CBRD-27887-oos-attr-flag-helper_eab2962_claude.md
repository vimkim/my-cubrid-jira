# [OOS] ALTER 속성 변경 판정에서 같은 모양으로 복사된 플래그 블록 세 개를 하나로 합친다

## Issue Triage

**이슈 수행 목적**: `build_attr_change_map`에서 속성 플래그(INVISIBLE, STORAGE PREFER_INLINE, STORAGE FORCE_OUTLINE)의 변경 여부를 판정하는 규칙을 한 함수에 두어, 플래그를 추가하거나 규칙을 바꿀 때 한 곳만 고치게 한다.

**이슈 수행 이유**: OOS가 STORAGE 옵션을 추가하면서 기존 INVISIBLE 판정 블록을 두 번 복사했다. 세 블록은 대상 플래그와 비교하는 값만 다르고, 판정 순서(UNSET이면 유지, 요청 값이면 새로 얻음, 이전에 있었으면 잃음)는 같다.

**영향**: 동작은 바뀌지 않는다. ALTER ... MODIFY/CHANGE의 INVISIBLE, VISIBLE, STORAGE 처리 결과가 같다.

**이슈 수행 방안**: 판정 규칙을 `build_attr_flag_change_property`로 옮기고 세 곳에서 호출한다.

---

## AI-Generated Context

- CBRD-27881의 OOS 리팩토링 후보 조사(`feature/oos-merge` dcbf09e4f 기준)에서 나온 여섯 번째 단위이다.
- 검증: 원래 세 블록과 새 함수를 실제 소스에서 추출해, 가능한 모든 입력 768가지에서 결과가 같음을 확인했다. 일부러 틀리게 바꾼 경우 8가지는 모두 검사에서 걸렸다. OOS 관련 ctest 44개가 변경 전후 모두 통과했다. csql로 INVISIBLE/STORAGE ALTER 35단계를 실행해 catalog 상태가 의도와 같음을 확인했다.
- INVISIBLE 쪽은 OOS 단위 테스트가 다루지 않는다. CI의 `test_sql` 중 `_36_guava/cbrd_26401` 계열이 이 경로를 다룰 것으로 본다(추정).
