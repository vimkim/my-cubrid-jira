# [OOS] cubrid spacedb 에 SPACEDB_OOS_FILE 카테고리 추가

> 부모 epic: CBRD-26583 / 발단: CBRD-26871(OOS 병합 QA 검증 시나리오)의 툴링 선행과제 T1

## Issue Triage

**이슈 수행 목적**: `cubrid spacedb` 가 OOS 파일(`FILE_OOS`)의 공간을 heap 과 분리된 카테고리로 집계하도록 해, OOS 포함 DB 에서도 abort 없이 OOS 공간을 관측할 수 있게 한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: 파일별 집계 콜백 `file_tracker_item_spacedb`(`file_manager.c:12205`)의 `FILE_OOS` case(`:12236`)는 `assert_release(false)` 를 실행한 뒤 `spacedb_ftype = SPACEDB_HEAP_FILE` 로 처리한다. `SPACEDB_FILE_TYPE` enum(`storage_common.h:581`)에 OOS 용 값이 없어서 넣은 임시 워크어라운드다(코드 주석 "I did not add SPACEDB_OOS_FILE yet ... This is just a workaround"). `assert_release` 는 debug 빌드에서 `assert` 라(`error_manager.h:195`), OOS 파일이 있는 DB 에 `cubrid spacedb` 를 돌리면 **debug 빌드에서 abort** 한다. release 빌드(`NDEBUG`)에서는 abort 대신 `ER_NOTIFICATION_SEVERITY` 로그(`ER_FAILED_ASSERTION`)를 남기고 OOS 페이지를 heap 으로 오집계한다.
- **영향**: QA 검증 곤란. OOS 병합 검증(CBRD-26871)에서 release 빌드에는 OOS 발동/공간을 증명할 수단이 없어, 검증이 debug 빌드 + `oos.log` grep 에만 의존한다. 출하 바이너리(release)에서 OOS 가 차지하는 공간을 운영/QA 가 관측할 방법이 없고, OOS 페이지가 heap 으로 잘못 합산돼 공간 통계도 왜곡된다.

**이슈 수행 방안**:

- `SPACEDB_FILE_TYPE` enum(`storage_common.h:581`)에 `SPACEDB_OOS_FILE` 추가(`SPACEDB_TOTAL_FILE` 앞). 합계 루프(`file_manager.c:7936`, `i < SPACEDB_TOTAL_FILE`)는 자동 합산하지만, 출력 라벨 배열 `file_type_strings[]`(`util_cs.c:954`)는 enum 과 같은 위치로 OOS 라벨을 넣지 않으면 OOB read 가 난다 - 동기화 필수.
- `file_tracker_item_spacedb` 의 `FILE_OOS` case(`file_manager.c:12236`)에서 `assert_release(false)` 제거하고 `spacedb_ftype = SPACEDB_OOS_FILE` 로 집계.
- `cubrid spacedb` 출력에 OOS 카테고리 행 추가. 출력 라벨 배열(`util_cs.c:954`)/헤더 문자열, 메시지 카탈로그(`utils.msg`), 매뉴얼/QA answer 갱신 필요.
- 출력 라벨 문자열(예: `OOS`)과 정렬 포맷: `TBD - ANALYSIS 단계에서 결정`.

---

## AI-Generated Context

> 아래는 AI 가 코드를 분석해 작성한 상세 자료다. 빠른 triage 에는 위 블록으로 충분하다.

### Summary

- **목적**: `cubrid spacedb` 가 OOS 공간을 별도 집계.
- **배경**: 현재 `FILE_OOS` 가 `assert_release(false)` + heap 오집계 워크어라운드 상태.
- **변경 사항**: enum 1개 값 추가(`storage_common.h`) + 집계 case 수정(`file_manager.c`) + 출력 라벨 배열/포맷 갱신(`util_cs.c`). 디스크 포맷 변경 없음.
- **영향 범위**: `file_manager.c`, `util_cs.c`, `cubrid spacedb` 출력, 메시지 카탈로그, 매뉴얼/QA answer. 동일 버전 클라이언트/서버는 하위호환 영향 없음(버전 불일치 직렬화는 Spec 참고).

---

## Description

OOS(Out-of-row Overflow Storage - heap 의 큰 가변 컬럼을 별도 OOS 파일로 분리 저장하는 기능)는 테이블별로 `FILE_OOS` 파일을 만든다. `cubrid spacedb` 는 파일 종류별 페이지 사용량을 보고하는 운영/QA 도구지만, OOS 파일 종류를 인식하지 못한다.

파일별 집계 콜백 `file_tracker_item_spacedb` 가 파일을 순회하며 종류별로 `SPACEDB_FILES` 배열에 누적하는데, `FILE_OOS` 에 대응하는 `SPACEDB_FILE_TYPE` enum 값이 없다. 임시로 `assert_release(false)`(미구현 표시) 후 heap 으로 분류하고 있어, debug 빌드에서는 OOS 파일을 만나는 순간 abort 하고, release 빌드에서는 `ER_FAILED_ASSERTION` 알림을 남긴 채 OOS 페이지가 heap 통계에 섞인다.

---

## Specification Changes

- `cubrid spacedb` 출력에 OOS 파일 카테고리 행이 신설된다. 출력을 파싱하는 QA answer 파일, 매뉴얼의 spacedb 출력 예시, in-binary 메시지 카탈로그(`msg/en_US.utf8/utils.msg` + `ko_KR` 의 spacedb 포맷/컬럼 폭)를 갱신해야 한다.
- `SPACEDB_FILE_COUNT` 변경은 `or_pack_spacedb`/`or_unpack_spacedb`(`object_representation.c:6131`)의 직렬화 길이를 바꾼다. 동일 버전 클라이언트/서버는 무해하나, 버전 불일치(롤링 업그레이드) 시 비호환 - 호환성 정책 명시 필요.
- 디스크 포맷/카탈로그 변경 없음.

---

## Implementation

1. `SPACEDB_FILE_TYPE` enum(`storage_common.h:581`)에 `SPACEDB_OOS_FILE` 추가(`SPACEDB_TOTAL_FILE` 직전, 예: `SPACEDB_HEAP_FILE` 뒤). `SPACEDB_FILE_COUNT` 는 enum 마지막 값이라 자동 증가한다.
2. `file_tracker_item_spacedb`(`file_manager.c:12205`)의 `case FILE_OOS:`(`:12236`)에서 `assert_release (false)` 와 워크어라운드 주석 제거, `spacedb_ftype = SPACEDB_OOS_FILE;` 로 변경.
3. 합계 루프(`file_manager.c:7936`, `file_spacedb`)는 `i < SPACEDB_TOTAL_FILE` 를 순회해 새 카테고리를 TOTAL 에 자동 합산함 - 추가 작업 불필요.
4. 출력 라벨 배열 `file_type_strings[]`(`util_cs.c:954`)에 enum 과 동일한 위치로 OOS 라벨 추가(예: `{"INDEX","HEAP","OOS","SYSTEM","TEMP","-"}`). 배열 길이가 `SPACEDB_FILE_COUNT` 와 어긋나면 출력 루프(`util_cs.c:1156`)가 OOB read.
5. 메시지 카탈로그(`utils.msg` en/ko)의 spacedb 포맷/컬럼 폭 검토, 매뉴얼 예시, QA answer 갱신.

## Acceptance Criteria

- [ ] OOS 파일이 있는 DB 에서 `cubrid spacedb` 가 debug/release 양쪽에서 abort/알림 없이 정상 동작
- [ ] OOS 페이지가 heap 과 분리된 카테고리로 집계됨
- [ ] release 빌드에서 OOS 공간 페이지 수 > 0 을 확인 가능(CBRD-26871 의 release 게이트 공백 해소)
- [ ] `cubrid spacedb` 출력 매뉴얼/QA answer 갱신

## Definition of done

- [ ] 위 Acceptance Criteria 충족
- [ ] QA 통과
- [ ] 문서/매뉴얼 반영

---

## 참고 코드

- `src/storage/file_manager.c:12236` - `file_tracker_item_spacedb` 의 `FILE_OOS` 워크어라운드(`assert_release(false)` + heap 집계)
- `src/storage/file_manager.c:7936` - `file_spacedb` 의 `SPACEDB_TOTAL_FILE` 합계 루프
- `src/storage/storage_common.h:581` - `SPACEDB_FILE_TYPE` enum / `SPACEDB_FILES` 구조체 정의
- `src/executables/util_cs.c:954` - `file_type_strings[]` 출력 라벨 배열(enum 동기화 필요), 출력 루프 `:1156`
- `src/base/error_manager.h:187` - `assert_release` 매크로(release=알림, debug=abort)

## Remarks

- 관련: CBRD-26583(epic), CBRD-26871(OOS 병합 QA 검증; 본 이슈는 그 T1 선행과제), CBRD-YYYYY(T2 - OOS 파일 parent HFID)
- T2 와 함께 적용하면 `cubrid spacedb`/`diagdb` 가 "어느 테이블의 OOS 가 얼마나 쓰는지" 까지 보고 가능
