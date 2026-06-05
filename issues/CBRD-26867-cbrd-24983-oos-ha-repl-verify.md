# [OOS] [M2] [HA] cbrd_24983 — 대형 가변 컬럼 OOS 복제 TC 로컬 재현 / 검증

## Issue Triage

**목적**: OOS 빌드 manual run 에서 fail 로 집계된 `cbrd_24983` 을 로컬 HA 로 재현해, 진짜 OOS 복제 결함인지 / 환경·타이밍 문제인지 가린다. CBRD-26854 의 `ha_shell` fail 9건 중 OOS 임계를 넘는 유일한 TC — OOS 머지 게이트의 마지막 미확인 항목.

**이유**:
- **현재**: 이 TC 는 `content varchar(1G)` 에 base64/HTML 2행(raw ~63KB, ~95KB)을 loaddb 하고 slave 복제만 본다. OOS 빌드에서 fail 로 집계됐으나 상세 결과(showHa)가 안 떠 원인 미확인이라 로컬 재현이 필요하다.
- **영향**: 미확인이면 OOS write/복제 경로가 검증 안 된 채 머지되거나 6/17 게이트가 안 닫힌다. 게다가 TC 가 OOS 발동을 직접 안 보므로, green 이어도 OOS 를 검증했다는 보장이 없다(아래 **주의**).

**방안**: 로컬 HA 재현 → ① OOS 발동 확인 → ② TC 통과 기준 확인. Fail>0 또는 row≠2 면 OOS 복제 결함으로 child 버그 분리, 깨끗하면 CBRD-26854 Bucket A 종결.

---

## 주의 — OOS 발동은 raw 크기가 아니라 "압축 후" 크기로 갈린다

OOS 발동 조건 = 레코드 디스크크기 > `DB_PAGESIZE/8`(~2KB) **AND** 그 가변 컬럼 디스크크기 > 512B (`heap_file.c:12466`, `:12472`). 그런데 `content` 는 VARCHAR 라 그 디스크크기가 **LZ4 압축 후** 값이다(255B 이상 문자열은 압축; `pr_data_writeval_disk_size` → `object_primitive.c:10548`). base64/HTML 은 압축이 잘 되므로 **raw 63/95KB 가 그대로 임계와 비교되는 게 아니다 — "varchar 라서 OOS 를 탄다"는 단정은 틀릴 수 있다.**

다만 95KB 짜리는 압축해도 512B/2KB 를 한참 넘으므로 **거의 100% OOS 를 탄다.** 그래도 TC 가 발동 여부를 직접 안 보니, 재현 때 한 번은 실제 발동을 확인해야 "green = OOS 검증" 이 성립한다. (압축 변수를 없애려면 `bit varying` + 비압축 값으로 한 번 더 돌리면 크기로 발동이 보장됨.)

---

## TC 가 실제로 검사하는 것 (정확히)

`cbrd_24983.sh` 의 OK/NOK 게이트는 **셋뿐** 이다:

1. master loaddb 로그에 `Total 2 object(s) inserted, 0 object(s) failed.`
2. slave `applyinfo … | grep Fail` 의 Fail count(`awk $4`) = 0
3. slave `SELECT DECODE(COUNT(*),2,'OK','FAIL')` 가 `OK`

→ **TC 는 master/slave `content` 값 동등성도, OOS 발동 여부도 검사하지 않는다.** 값 손상이 의심되면 수동 비교가 필요하다.

---

## 통과 기준

- [ ] **(TC 밖 추가)** OOS 발동 확인 — debug: `grep 'inserted to oid=' $CUBRID/log/oos.log` (`oos_file.cpp:1081`); release 는 컴파일아웃이라 `cubrid spacedb <db> | grep -i oos` 의 `FILE_OOS` 페이지 > 0
- [ ] loaddb 2건 성공 (`0 object(s) failed`)
- [ ] slave `applyinfo` Fail count = 0
- [ ] slave `count(*)` = 2
- [ ] **(권장)** master/slave `content` 값 동등 — TC 미포함, 의심 시 수동
- 모두 통과 → CBRD-26854 Bucket A 종결 / 하나라도 실패 → OOS 복제 child 버그 분리 (근본원인 후보: 복제 로그 생성 경로 또는 `heap_record_replace_oos_oids` `heap_file.c:7932/7942/7961`)

---

## Reference

> 아래는 코드/TC 에서 확인한 근거. 빠른 판단은 위 **Issue Triage** + **주의** 만 보면 된다.

- TC: `cubrid-testcases-private/HA/shell/_38_fig/cbrd_24983/cases/cbrd_24983.sh` (+ `tdb_objects`, 2행, `content` raw ~94KB/~63KB base64 HTML). 테이블 `im_enc_dmail_22 (idx, seqidx, fileinfo varchar(63), content varchar(1073741823))`.
- OOS 발동: `heap_attrinfo_determine_disk_layout` — 레코드 게이트 `heap_file.c:12466`, 컬럼 게이트 `:12472`, 컬럼 크기 `pr_data_writeval_disk_size` `:12388`(압축 후).
- VARCHAR 압축 임계 255B: `OR_MINIMUM_STRING_LENGTH_FOR_COMPRESSION` (`object_representation.h:1410`).
- 빌드: `feature/oos-m2` HEAD `ca3e7d522` (`11.5.0.2338-404b396`).
- 부모: CBRD-26583 (OOS M2) · 출처: CBRD-26854 (HA fail triage, Bucket A).
