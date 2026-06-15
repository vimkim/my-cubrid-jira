# [OOS][TDE] encrypt 테이블의 큰 가변 컬럼이 OOS 페이지에 평문으로 저장됨

## Issue Triage

**이슈 수행 목적**: `encrypt` 테이블의 512 바이트 초과 가변 컬럼 값이 OOS 파일에도 TDE 로 암호화되어 디스크에 저장되도록 한다. heap, heap-overflow, btree 와 동일하게 맞춘다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: TDE 를 거는 두 경로가 모두 OOS 파일을 빠뜨린다. 파일을 돌며 암호화하는 `xfile_apply_tde_to_class_files` (`file_manager.c:12421`) 는 heap, heap-overflow, btree, btree-overflow 만 처리하고 `FILE_OOS` 분기가 없다. OOS 파일을 처음 만드는 `heap_oos_find_vfid` (`heap_file.c:12489`, `docreate=true`) 도 `oos_create_file` (`oos_file.cpp:909`) 직후 TDE 를 걸지 않는다. OOS 도입 전 같은 값이 지나던 heap-overflow 경로 (`heap_ovf_find_vfid`, `heap_file.c:6586-6606`) 는 파일 생성 직후 TDE 를 걸었는데, 그 단계가 OOS 로 옮겨오지 못한 회귀다.
- **영향**: 고객 장애 (보안 컴플라이언스 위반). `encrypt` 테이블에 큰 값을 INSERT 하면 그 값이 OOS 페이지에 평문으로 남아 `grep -a` 로 디스크에서 그대로 읽힌다. 디스크나 백업이 유출돼도 평문이 새지 않게 한다는 TDE 의 목적이 깨진다.

**이슈 수행 방안**: A 와 B 를 함께 적용한다 (defense in depth). 수정량은 두 파일에 약 35 라인.

- (A) `xfile_apply_tde_to_class_files` 에 OOS 분기 추가. heap-overflow 처리 직후 `heap_oos_find_vfid(..., docreate=false)` 로 이미 만들어진 OOS 를 찾아 `file_apply_tde_algorithm` 호출. NULL 이면 아직 생성 전이라 건너뛴다. `ALTER ... encrypt` 경로를 잡는다.
- (B) `heap_oos_find_vfid` 의 `docreate=true` 분기에서 `oos_create_file` 직후 `heap_get_class_tde_algorithm` + `file_apply_tde_algorithm` 를 sysop 안에서 호출. `heap_ovf_find_vfid` 패턴을 그대로 따른다. 첫 큰 INSERT 로 새로 만들어지는 OOS 를 잡는다.
- `oos_create_file` 시그니처 변경, `file_apply_tde_algorithm` 시그니처, `FILE_OOS` 디스크 포맷은 건드리지 않는다.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료입니다. 빠른 triage에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하시면 됩니다.

### Summary

- **문제**: `encrypt` 테이블의 큰 가변 컬럼이 OOS 페이지에 평문으로 저장된다.
- **원인**: TDE walker 와 OOS lazy 생성 두 곳 모두 OOS 파일에 `file_apply_tde_algorithm` 을 부르지 않는다.
- **변경**: walker 에 OOS 분기 추가 + lazy 생성 직후 인라인 TDE 적용.
- **영향 범위**: TDE 가 켜진 테이블의 512 바이트 초과 가변 컬럼만. 미암호화 테이블과 작은 컬럼은 무영향. 디스크 포맷 무변경.

---

## Description

`encrypt` 테이블은 디스크에 저장되는 데이터가 모두 TDE (Transparent Data Encryption, 페이지 단위 디스크 자동 암호화) 로 암호화돼야 한다. 디스크나 백업이 통째로 유출돼도 안의 값을 못 읽게 하는 것이 목적이다.

그런데 512 바이트를 넘는 큰 가변 컬럼은 OOS 파일로 따로 빠지고, 이 OOS 파일에만 TDE 가 걸리지 않는다. 그래서 `encrypt` 테이블인데도 큰 값이 평문 그대로 디스크에 적힌다.

OOS 도입 전에는 같은 값이 heap-overflow 로 들어갔고, 그 경로는 파일을 만들자마자 TDE 를 걸었다. OOS 를 새로 만들면서 이 단계를 같이 옮기지 못한 것이 원인이다. 예전엔 암호화되던 데이터가 OOS 도입 후 평문이 된 회귀다.

| 항목 | OOS 도입 전 | OOS 도입 후 (패치 전) | 패치 후 |
|---|---|---|---|
| 저장 위치 | heap-overflow | OOS | OOS |
| encrypt 테이블 TDE | O | X | O |
| diagdb 의 tde_algorithm | AES | NONE | AES |
| 디스크 평문 노출 | 차단 | 노출 | 차단 |

## Test Build

- 브랜치: `feature/oos-m2`, 커밋 `412c36c06` 기반 디버그 빌드
- 빌드: `./build.sh -m debug`
- OS: Linux (RHEL/CentOS 9)

## Repro

```bash
db=db_tde_oos_verify
mkdir -p /tmp/$db
export CUBRID_DATABASES=/tmp/$db
cd /tmp/$db
cubrid createdb -r $db --db-volume-size=20m --log-volume-size=20m
cubrid server start $db

csql -udba -c "create table ttt (a int, b varchar(20000)) encrypt;" $db
csql -udba -c "insert into ttt (a, b) values (0, rpad('zzzznotsecret', 20000));" $db

cubrid server stop $db

grep -a "zzzznotsecret" /tmp/$db/* || echo "OK: no plaintext on disk"
```

## Expected Result

- `grep -a "zzzznotsecret"` 가 아무것도 출력하지 않는다.
- `cubrid diagdb -d1` 에서 OOS 파일의 `tde_algorithm` 이 `AES` 로 표시된다. `create ... encrypt` 와 `ALTER ... encrypt` 둘 다 동일해야 한다.

## Actual Result

- `grep -a "zzzznotsecret"` 가 평문을 그대로 출력한다.
- `cubrid diagdb -d1` 에서 OOS 파일만 `tde_algorithm: NONE` 으로 나온다. heap 본체와 heap-overflow 는 `AES` 인데 OOS 만 비대칭이다.

## Additional Information

연관 회귀 테스트: `shell/_36_damson/cbrd_23608_tde/tbl_enc_08`, `tbl_enc_14`. 패치로 평문 검증이 통과한 뒤 `result.answer` 를 재생성해 통과시킨다.

## Remarks

- 부모: CBRD-26583 ([OOS][M2] 마일스톤 2, 회귀 발생 지점)
- 형제: CBRD-26831 ([OOS] 인접 회귀)
- 참고: CBRD-23608 (TDE 도입 원본, 기준 동작 정의)
- `feature/oos-m2` 가 develop 으로 머지되기 전에 닫혀야 한다.
