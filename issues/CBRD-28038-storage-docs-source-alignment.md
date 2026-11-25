# storage AGENTS.md와 코드 분석 문서를 실제 구현에 맞게 갱신

**한 줄 요약**: storage 지침과 분석서에서 확인한 잘못된 함수·파일 안내와 빠진 자원·복구 조건을 수정하는 CBRD-27537의 후속 문서 갱신 작업이다.

## Issue Triage

**이슈 수행 목적**: 개발자와 에이전트가 `src/storage`를 수정할 때 실제 구현에 맞는 진입점과 자원·복구 조건을 찾게 한다.

**이슈 수행 이유**: 기존 문서는 B-tree bulk load 정렬을 `external_sort.c`로 안내하고, 존재하지 않는 `stats_get_ndv_by_query()`를 나열한다. 읽기 latch 예제에는 페이지 수정이 가능하다고 적혀 있다. 소스와 대조해 이 불일치를 확인했다.

**영향**: 개발자가 잘못된 구현 파일을 조사하거나 latch·버퍼 수명·복구 조건을 놓칠 위험이 있다. 이번에 확인한 것은 문서 오류이며, 이 설명 때문에 실제 데이터 오류가 발생했다는 주장은 하지 않는다.

**이슈 수행 방안**: 사용자가 요청한 소스 대조 결과에 따라 `src/storage/AGENTS.md`와 기존 분석서 7개를 수정하고, `develop` 대상 draft PR로 검토한다.

---

## AI-Generated Context

## Description

부모 이슈는 [CBRD-27537](https://jira.cubrid.org/browse/CBRD-27537)이다. 기존 [CBRD-26974](https://jira.cubrid.org/browse/CBRD-26974)는 주제별 분석 문서를 처음 구성한 작업이며 Resolved/Fixed 상태다. 이번 하위 작업은 그 문서들을 이후 구현과 대조해 보정한다. 공통 루트 지침을 다루는 [CBRD-27539](https://jira.cubrid.org/browse/CBRD-27539)와는 대상 파일이 다르다.

변경 범위는 다음과 같다.

| 문서 | 변경 내용 |
| --- | --- |
| `src/storage/AGENTS.md` | 중복된 fix 예제를 상세 문서로 모은다. 읽기·쓰기 latch, ordered fix의 재검증, 실제 정렬·검색 모듈, CMake 컴파일 근거와 예외 처리 지침을 바로잡는다. |
| `storage-foundations.md` | `RECDES` 길이에 포함되는 데이터와 소유권을 구분한다. `S_DOESNT_FIT`의 음수 길이와 peek한 페이지 메모리의 수명을 설명한다. |
| `buffer-io-durability.md` | fix 실패 처리, dirty 표시와 복구 로그의 차이, ordered refix, 임시 페이지, 선택적 DWB, TDE 페이지 이미지와 적용 전제조건을 보강한다. |
| `disk-file-space.md` | 영구·임시 파일 수명, 지연 해제, sticky page, 페이지 초기화 계약, 임시·영구 extendible hash를 구분한다. |
| `heap-record-pages.md` | 조건부·비공개 API, snapshot 적용 조건, 연산별 로그 순서, undo용 공간과 빈 슬롯, bestspace 페이지 공개 순서를 설명한다. |
| `btree-indexes.md` | `btree_sort*`와 writer wait 모듈을 안내한다. 논리·물리 삭제, 하강 중 split·merge, overflow 디렉터리와 병렬 빌드 system operation 경계를 구분한다. |
| `catalog-statistics-maintenance.md` | 없는 NDV 함수를 제거한다. 실제 추정기·수집기, partition sketch 병합, catalog cache·access 정리, compactdb 조건을 안내한다. |
| `external-storage-lob.md` | OWFS 빌드·stub 조건, prefix API의 mode 제한, commit·rollback·vacuum에 따른 transactional LOB 정리를 설명한다. |

위 7개 분석서는 `src/storage/docs/`에 있다. 런타임 소스, CMake 설정, SQL 동작과 디스크 형식은 변경하지 않는다.

## Verification

- 원래 소스 기준 `e64a04a79`에서 8개 문서를 소스·헤더·CMake와 대조하고 독립 검토의 파일 소유권 지적 2건을 반영했다.
- 로컬 파일·절 링크 42개와 함수명 참조 313개를 정적으로 검사했다. 함수명 검사는 정의·컴파일 가능성·동작의 증명이 아니며, 의미는 별도 소스 대조로 확인했다.
- `git diff --check`와 최종 문서 해시 비교를 통과했다.
- 문서 변경의 로컬 검증으로 빌드와 SQL 테스트는 실행하지 않았다. PR CI 결과는 실행 후 별도로 기록한다.

## Acceptance criteria

- 기존 8개 문서의 잘못된 진입점과 안전 조건을 실제 코드 근거로 수정한다.
- 문서 링크를 확인하고 조건부 API와 private helper를 구분한다.
- 이 하위 이슈를 연결한 `develop` 대상 draft PR에서 변경과 검증 결과를 검토한다.
