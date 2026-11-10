# [OOS] diagdb가 보여주는 OOS 파일 유형 이름을 기능 이름(Out-of-row)에 맞춘다

**한 줄 요약**: CBRD-27881 리팩토링 조사 항목 R-39에서 나온 후속 작업으로, `cubrid diagdb` 출력에 나오는 OOS 파일 유형 이름 `OUT_OF_LINE_OVERFLOW_STORAGE` 를 기능 이름 Out-of-row Overflow Storage에 맞게 develop 병합 전에 바꾼다.

## Issue Triage

**이슈 수행 목적**: 사용자가 diagdb 출력에서 보는 OOS 파일 유형 이름이 기능 이름, 문서, 코드의 용어와 같아진다.

**이슈 수행 이유**: `file_type_to_string (FILE_OOS)` 가 `"OUT_OF_LINE_OVERFLOW_STORAGE"` 를 반환한다. OOS의 기능 이름은 Out-of-row Overflow Storage다. 이 문자열은 `cubrid diagdb` 처럼 사용자가 보는 출력에 나온다. 사용자에게 보이는 문자열은 release 뒤에 바꾸면 출력에 기대는 스크립트와 테스트 답안이 함께 깨지므로, OOS가 develop에 병합되기 전에 바꾸는 것이 비용이 가장 작다.

**영향**: 지금은 이름이 기능 이름과 달라서 diagdb 출력을 읽는 운영자와 개발자가 OOS 파일을 다른 기능으로 오해할 수 있다. 바꾸면 이 문자열을 기대값으로 담은 테스트 답안 2개를 함께 고쳐야 한다. 동작 변화는 없다.

**이슈 수행 방안**: 2026-11-10 담당자가 R-39를 "develop 병합 전에 바꾼다"로 정했다. 새 문자열(예: `OUT_OF_ROW_OVERFLOW_STORAGE`)과 테스트 답안 수정 범위는 ANALYSIS에서 확정한다.

---

## AI-Generated Context

## Description

CUBRID 파일 관리자는 파일마다 유형(`FILE_TYPE`)을 가지고, `file_type_to_string` 이 이를 사람이 읽는 이름으로 바꾼다. `cubrid diagdb` 는 파일 목록을 출력할 때 이 이름을 쓴다. OOS 파일의 이름은 [`file_manager.c` 3038행](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/storage/file_manager.c#L3038)에서 `"OUT_OF_LINE_OVERFLOW_STORAGE"` 다(`feature/oos-merge` `50619ce53` 기준). 엔진 소스에서 이 문자열이 나오는 곳은 여기 한 곳이다.

### 함께 고쳐야 하는 테스트

`cubrid-testcases-private-ex` 의 `feature/oos-merge`(`e56dfa32a`)에서 이 문자열을 찾은 결과다.

| 파일 | 쓰임 | 수정 필요 |
|---|---|---|
| `shell/_36_damson/cbrd_23608_tde/tbl_enc_08/cases/result.answer` 7행 | diagdb 출력 기대값 `type = OUT_OF_LINE_OVERFLOW_STORAGE` | 필요 |
| `shell/_36_damson/cbrd_23608_tde/tbl_enc_14/cases/result.answer` 8행 | 같음 | 필요 |
| `shell/_06_issues/_26_1h/cbrd_26527/cases/cbrd_26527.sh` 100, 103행 | 주석의 출력 예시. 검사는 `OOS for HFID` 로 한다 | 주석만 |

다른 저장소와 개인 작업 브랜치의 테스트 보조 스크립트에도 같은 문자열이 있을 수 있다. 병합 전에 다시 검색한다.

### 관련 이슈

- [CBRD-27350](https://jira.cubrid.org/browse/CBRD-27350)은 `cubrid spacedb` 에 OOS 전용 분류를 추가한다. 출력 이름을 정할 때 두 이슈의 용어를 맞춘다.
- [CBRD-26570](https://jira.cubrid.org/browse/CBRD-26570)에서 위 TDE 답안이 OOS 출력에 맞게 갱신됐다.

## Acceptance Criteria

- `cubrid diagdb` 가 OOS 파일 유형을 기능 이름에 맞는 문자열로 출력한다.
- 위 TDE shell 테스트 2개가 새 문자열로 통과한다.
- 엔진 소스와 OOS 테스트 저장소에 옛 문자열이 남지 않는다.
