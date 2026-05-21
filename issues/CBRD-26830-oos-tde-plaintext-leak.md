# [OOS] [TDE] OOS 페이지에 TDE 미적용 -- encrypt 테이블의 큰 가변 컬럼이 평문으로 디스크에 저장됨

> **JIRA**: [CBRD-26830](http://jira.cubrid.org/browse/CBRD-26830) (Sub-task, parent [CBRD-26583](http://jira.cubrid.org/browse/CBRD-26583))
> **타입**: Correct Error (Regression -- OOS M2 도입에서 발생)
> **상태**: Open, 담당 vimkim
> **재현 테스트**: `shell/_36_damson/cbrd_23608_tde/tbl_enc_08`, `tbl_enc_14`

---

## Issue Triage

**이슈 수행 목적**: `encrypt` 키워드로 생성된 테이블에서 512 바이트를 넘는 가변 컬럼 값을 디스크에 평문으로 남기지 않는다. OOS (Out-of-row Storage -- heap 의 큰 가변 컬럼을 별도 파일에 분리 저장하는 구조) 파일에도 heap / heap-overflow / btree 와 동일한 TDE (Transparent Data Encryption -- 페이지 단위 디스크 암호화) 알고리즘이 적용되도록 한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `xfile_apply_tde_to_class_files` (`src/storage/file_manager.c:12421`) 가 클래스의 영구 파일을 순회할 때 heap (`hfid.vfid`), heap-overflow (`hovf_vfid`), btree (`idx[i].btid.vfid`), btree-overflow (`root->ovfid`) 네 종류에만 `file_apply_tde_algorithm` 을 호출하고 `FILE_OOS` 분기가 빠져 있다. OOS 파일 lazy 생성 분기인 `heap_oos_find_vfid` (`src/storage/heap_file.c:12489`, `docreate=true` 경로) 와 `oos_create_file` (`src/storage/oos_file.cpp:909`) 어느 쪽도 TDE 알고리즘을 적용하지 않는다. OOS 도입 전 동일 데이터가 거치던 heap-overflow 경로인 `heap_ovf_find_vfid` (`heap_file.c:6527` 정의, TDE 적용 블록 `6586-6606`) 는 `file_create_with_npages` 후 `heap_get_class_tde_algorithm` + `file_apply_tde_algorithm` 를 `sysop` (top system operation -- partial commit 단위로 묶이는 다중 페이지 변경 마이크로-트랜잭션) 안에서 원자적으로 호출하는데, 이 패턴이 OOS 측에는 미반영이다. OOS 분기 결정은 `heap_attrinfo_determine_disk_layout` 의 `column_size[i] > 512` (`heap_file.c:12472`) 에서 일어난다.
- **영향**: 고객 장애 (보안 컴플라이언스 위반). `create table ttt (a int, b varchar(20000)) encrypt;` 후 `insert (rpad('zzzznotsecret', 20000))` 하면 `b` 값이 OOS 페이지에 그대로 남아 `grep -a "zzzznotsecret" /tmp/<db>/*` 로 디스크에서 평문이 추출된다. TDE 보안 모델 -- 디스크 도난 시 평문 노출 차단 -- 이 사실상 깨진 상태다.

**이슈 수행 방안**:

- (A) `xfile_apply_tde_to_class_files` 에 OOS 분기 추가: heap-overflow 처리 직후 `heap_oos_find_vfid(thread_p, &hfid, &oos_vfid, /*docreate=*/false)` 로 기존 OOS VFID (Volume-File Identifier) 조회 후 `file_apply_tde_algorithm` 호출. NULL 이면 아직 lazy 생성 전이므로 스킵한다.
- (B) `heap_oos_find_vfid` lazy create 분기에 인라인 TDE 적용: `oos_create_file` 성공 직후, `log_sysop_commit` 이전에 `heap_get_class_tde_algorithm(&heap_hdr->class_oid, &tde_algo)` + `file_apply_tde_algorithm(oos_vfid, tde_algo)` 호출. `heap_ovf_find_vfid` (`heap_file.c:6527` 정의, TDE 적용 블록 `6586-6606`) 패턴을 그대로 미러링해 sysop 안에서 원자적으로 처리한다.
- A + B 동시 적용 (defense in depth) -- A 는 `ALTER ... encrypt` 시점에 이미 생성된 OOS 를 잡고, B 는 INSERT 가 512 B 임계치를 처음 넘는 시점에 새로 만들어지는 OOS 를 잡는다.
- (C) `oos_create_file` API 시그니처에 class OID 또는 TDE 알고리즘을 추가하는 방안은 본 이슈 범위 밖이다 -- `oos_create_file` 의 호출처는 lazy 분기 한 곳뿐이라 push-down 의 이득이 없다.
- `file_apply_tde_algorithm` 시그니처와 `OUT_OF_LINE_OVERFLOW_STORAGE` 라벨은 본 패치에서 건드리지 않는다. diagdb 출력에서 OOS 가 안 잡히는 라벨/CLASS_OID 문제는 별도 cosmetic 티켓으로 분리한다.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료입니다. 빠른 triage에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하시면 됩니다.

### Summary

- **문제 / 목적**: `encrypt` 테이블의 512 B 초과 가변 컬럼이 OOS 페이지에 평문으로 저장되는 TDE 컴플라이언스 회귀 -- OOS M2 도입 이전 경로에서는 정상 암호화되던 데이터가 M2 이후 평문으로 디스크에 노출된다.
- **원인 / 배경**: TDE walker 와 OOS lazy 생성 양쪽이 OOS 파일에 `file_apply_tde_algorithm` 을 호출하지 않음 -- M2 (CBRD-26583) 의 OOS 도입이 기존 TDE 코드 경로에 반영되지 못했다.
- **제안 / 변경**: walker (`xfile_apply_tde_to_class_files`) 에 OOS 분기 추가 (+16 lines) + lazy create (`heap_oos_find_vfid` `docreate=true`) 안에서 인라인 TDE 적용 (+19 lines) -- defense in depth.
- **영향 범위**: TDE 가 켜진 테이블의 큰 가변 컬럼 (`varchar(N>512)` 등). 미암호화 테이블이나 작은 컬럼은 무영향. `file_apply_tde_algorithm` API 와 디스크 포맷은 무변경.

---

## Description

OOS M2 (CBRD-26583) 도입으로 큰 가변 컬럼 값이 `FILE_OOS` 라는 별도 파일로 빠지게 되었다. M2 이전에는 같은 값이 `FILE_MULTIPAGE_OBJECT_HEAP` (heap-overflow) 로 들어갔고, 이 경로는 `heap_ovf_find_vfid` 에서 파일 생성 직후 `heap_get_class_tde_algorithm` + `file_apply_tde_algorithm` 를 호출해 `encrypt` 테이블이면 즉시 AES 가 걸렸다 (`heap_file.c:6586-6606`).

OOS 경로에는 이 호출이 없다. 같은 데이터가 OOS 도입 전에는 암호화되어 디스크에 적혔지만, OOS 도입 후에는 평문으로 적힌다. 이 회귀는 M2 코드 리뷰 당시 OOS 파일 생성 경로가 기존 TDE walker 루프 및 lazy-create 패턴과 독립적으로 작성되어 슬쩍 빠진 결과다. TDE 위협 모델 -- 디스크가 외부에 노출돼도 평문이 새지 않는다 -- 이 깨진 상태이며, M2 의 OOS 가 사실상 TDE 를 우회하는 결과가 된다.

회귀는 두 위치의 누락이 합쳐서 만든다.

1. `xfile_apply_tde_to_class_files` (`src/storage/file_manager.c:12421`) 의 walker 루프가 heap, heap-overflow, btree, btree-overflow 만 순회하고 `FILE_OOS` 를 건너뜀.
2. `heap_oos_find_vfid` (`src/storage/heap_file.c:12489`) 의 `docreate=true` 분기에서 `oos_create_file` (`src/storage/oos_file.cpp:909`) 직후 TDE 미적용.

`file_apply_tde_algorithm` 자체는 VFID 만 받고 file_type 을 따지지 않으므로 OOS 에도 무수정으로 동작한다 -- 호출만 추가하면 해결된다.

---

## Test Build

- **브랜치**: `feature/oos-m2` (M1 부모 브랜치 `feat/oos` 위에서 파생된 M2 작업 브랜치)
- **기반 빌드**: `cubrid 11.5.x` 디버그 빌드, 커밋 `412c36c06` 기반 (`feat/oos` 머지 직후)
- **빌드 명령**: `./build.sh -m debug`
- **OS**: Linux (RHEL/CentOS 9 계열)

---

## Repro

서버를 띄우고 `encrypt` 테이블에 512 B 초과 가변 컬럼 값을 INSERT 한 뒤 디스크에서 평문을 grep 한다.

```bash
db=db_tde_oos_verify
mkdir -p /tmp/$db
export CUBRID_DATABASES=/tmp/$db
cd /tmp/$db
cubrid createdb -r $db --db-volume-size=20m --log-volume-size=20m
cubrid server start $db

# encrypt 테이블 + 512 B 초과 가변 컬럼
csql -udba -c "create table ttt (a int, b varchar(20000)) encrypt;" $db
csql -udba -c "insert into ttt (a, b) values (0, rpad('zzzznotsecret', 20000));" $db

cubrid server stop $db

# 디스크 파일 전체에서 평문 토큰 검색
grep -a "zzzznotsecret" /tmp/$db/* || echo "OK: no plaintext on disk"
```

추가 검증: `cubrid diagdb -d1 $db | grep -E "OUT_OF_LINE_OVERFLOW_STORAGE|tde_algorithm" -B1 -A1` 로 OOS 파일의 `tde_algorithm` 필드를 확인한다. 라벨 정규화 전이라 `OUT_OF_LINE_OVERFLOW_STORAGE` 가 매치되지 않으면 `tde_algorithm` 단독으로 grep 한다.

연관된 CI 테스트:

```
shell/_36_damson/cbrd_23608_tde/tbl_enc_08/cases/tbl_enc_08.sh    (shard 14)
shell/_36_damson/cbrd_23608_tde/tbl_enc_14/cases/tbl_enc_14.sh    (shard 32)
```

두 테스트 모두 같은 패턴 (`create table ttt (... varchar(N)) encrypt;` + `rpad` 20 KB INSERT) 으로 `diagdb -d1` 출력을 `result.answer` 와 비교한다.

---

## Expected Result

- `grep -a "zzzznotsecret" /tmp/$db/*` 가 아무 매치도 출력하지 않는다 (`OK: no plaintext on disk`).
- `cubrid diagdb -d1` 출력에서 OOS 파일의 `tde_algorithm` 이 `AES` (또는 클래스가 가진 TDE 알고리즘) 로 표시된다. eager 경로 (`create table ... encrypt`) 와 lazy 경로 (`ALTER ... encrypt`) 모두 동일해야 한다.
- `tbl_enc_08`, `tbl_enc_14` shell 회귀에서 diff 결과가 OOS 도입 후 새 포맷에 맞게 `result.answer` 재생성된 상태로 통과한다.

---

## Actual Result

- `grep -a "zzzznotsecret" /tmp/$db/*` 가 OOS 페이지를 가진 데이터 볼륨에서 다수의 평문 매치를 출력한다 (전체 페이로드가 그대로 노출됨).
- `cubrid diagdb -d1` 에서 OOS 파일은 `tde_algorithm: NONE` 으로 표시된다 -- heap 본체와 heap-overflow 가 `AES` 인 것과 비대칭.
- `tbl_enc_08`, `tbl_enc_14` shell 회귀는 두 가지 이유로 실패한다.
  1. M2 이전 정상 경로에서 생성되던 `MULTIPAGE_OBJECT_HEAP` (heap-overflow) 블록이 더 이상 생성되지 않으므로 `result.answer` 의 해당 엔트리가 빠진다 (`diff result.log result.answer` 에서 `8a9,12` 형태로 출력).
  2. 새로 만들어진 OOS 파일은 라벨 (`OUT_OF_LINE_OVERFLOW_STORAGE`, 대소문자 차이로 테스트의 `grep -P "ttt|Overflow"` 에 안 잡힘) 과 누락된 CLASS_OID 출력 때문에 테스트 grep 필터에 잡히지 않는다 -- TDE 가 빠진 OOS 파일이 디스크에는 존재하지만 회귀 출력에는 한 줄도 안 남는다.

---

## Additional Information

### 적용된 수정

`feature/oos-m2` 브랜치에 두 군데 패치를 적용 (defense in depth, 수정 위치: `file_manager.c` +16 lines, `heap_file.c` +19 lines, 합계 +35 lines).

**(A) `src/storage/file_manager.c` `xfile_apply_tde_to_class_files` (heap-overflow 처리 직후)**:

```c
  /* apply to OOS file (if it has been lazily created already).
   * Lazy creation that happens after this point applies TDE inline in
   * heap_oos_find_vfid (docreate=true branch). */
  {
    VFID oos_vfid;
    VFID_SET_NULL (&oos_vfid);
    if (heap_oos_find_vfid (thread_p, &hfid, &oos_vfid, false) && !VFID_ISNULL (&oos_vfid))
      {
        error_code = file_apply_tde_algorithm (thread_p, &oos_vfid, tde_algo);
        if (error_code != NO_ERROR)
          {
            goto exit;
          }
      }
  }
```

**(B) `src/storage/heap_file.c` `heap_oos_find_vfid` `docreate=true` 분기 (`oos_create_file` 직후)**:

```c
  TDE_ALGORITHM tde_algo = TDE_ALGORITHM_NONE;

  /* START A TOP SYSTEM OPERATION */
  log_sysop_start (thread_p);
  if (oos_create_file (thread_p, *oos_vfid) != NO_ERROR)
    {
      log_sysop_abort (thread_p);
      goto exit_on_error;
    }

  /* Apply TDE to the new OOS file atomically with its creation.
   * Pattern mirrors heap_ovf_find_vfid (heap_file.c:6586). */
  if (heap_get_class_tde_algorithm (thread_p, &heap_hdr->class_oid, &tde_algo) != NO_ERROR)
    {
      log_sysop_abort (thread_p);
      goto exit_on_error;
    }

  if (file_apply_tde_algorithm (thread_p, oos_vfid, tde_algo) != NO_ERROR)
    {
      log_sysop_abort (thread_p);
      goto exit_on_error;
    }

  /* Log undo, then redo */
  log_append_undo_data (thread_p, RVHF_STATS, &addr_hdr, sizeof (*heap_hdr), heap_hdr);
  VFID_COPY (&heap_hdr->oos_vfid, oos_vfid);
  log_append_redo_data (thread_p, RVHF_STATS, &addr_hdr, sizeof (*heap_hdr), heap_hdr);
  pgbuf_set_dirty (thread_p, addr_hdr.pgptr, DONT_FREE);

  log_sysop_commit (thread_p);
```

WAL (Write-Ahead Log) undo/redo 는 `file_apply_tde_algorithm` 내부의 `RVFL_FHEAD_SET_TDE_ALGORITHM` 로 이미 처리되므로 별도 처리는 필요 없다.

### 코드 경로 비교 (pre-OOS vs OOS M2)

| 항목 | M2 이전 (heap-overflow 경로) | M2 도입 후 (OOS 경로, 패치 전) | M2 + 패치 후 |
|------|------------------------------|-------------------------------|--------------|
| 큰 가변 컬럼 저장 위치 | `FILE_MULTIPAGE_OBJECT_HEAP` | `FILE_OOS` | `FILE_OOS` |
| 파일 생성 시점 | `heap_ovf_find_vfid` (eager) | `heap_oos_find_vfid` lazy (첫 큰 INSERT 시) | 동일 |
| `encrypt` 테이블에서 TDE 적용 | O (`heap_file.c:6586-6606`) | X (양쪽 다 누락) | O (A + B) |
| `diagdb` 출력의 `tde_algorithm` | `AES` | `NONE` | `AES` |
| 디스크 grep 평문 노출 | 차단 | 노출 | 차단 |

### 회귀 분석 자료

내부 분석 노트와 CI 실패 shard artifacts 는 작성자 워크스페이스에 보관. PR 본문에 필요 발췌를 옮긴다. CI 실패 원본은 [CircleCI job #126965](https://circleci.com/gh/CUBRID/cubrid/126965) (shard 14 / shard 32) 참고.

### 후속 작업

- `OUT_OF_LINE_OVERFLOW_STORAGE` 라벨을 `Overflow` 포함 형태로 정규화하거나 `file_header_dump_descriptor` 의 `FILE_OOS` 분기에서 backref CLASS_OID 를 출력해 `diagdb` 테스트 grep 에 잡히게 하기 -- cosmetic / triage UX 개선이며 보안 수정과 분리. 본 이슈 범위 밖.
- `tbl_enc_*` 계열 (`varchar(N) encrypt + rpad`) `result.answer` 일괄 재생성 -- 본 패치로 평문 검증이 통과한 뒤에만 수행하고, 소스 수정과 별개 커밋으로 분리.
- `MNT_SERVER_COPY_STATS` 응답 크기가 +4464 B 증가한 다른 회귀 (`cbrd_22803`, `cbrd_20145_1`) -- 별 건이며 stats exact-equality 비교를 range 비교로 완화하는 방향 검토.

## Acceptance Criteria

- [ ] (A) `xfile_apply_tde_to_class_files` 가 OOS VFID 도 순회해 `file_apply_tde_algorithm` 호출 (CREATE encrypt + ALTER encrypt 양쪽 경로).
- [ ] (B) `heap_oos_find_vfid` lazy create 분기에서 `oos_create_file` 직후 `heap_get_class_tde_algorithm` + `file_apply_tde_algorithm` 호출이 sysop 안에서 원자적으로 실행.
- [ ] 디버그 빌드 통과 (`./build.sh -m debug`).
- [ ] 위 Repro 의 `grep -a "zzzznotsecret"` 이 매치 0건 출력.
- [ ] `cubrid diagdb -d1` 의 OOS 파일 엔트리가 `tde_algorithm: AES` (또는 클래스 TDE 알고리즘) 로 표시.
- [ ] `tbl_enc_08`, `tbl_enc_14` shell 테스트가 재생성된 `result.answer` 로 통과.

## Definition of done

- [ ] A/C 전 항목 통과.
- [ ] 소스 수정 PR 과 `result.answer` 재생성 PR (또는 동일 PR 안의 별도 커밋) 으로 분리해 리뷰어가 독립적으로 확인 가능.
- [ ] PR 본문에 `grep -a` 결과, `diagdb` 발췌, `tbl_enc_*` diff 결과를 증거로 첨부.
- [ ] `feature/oos-m2` 머지 후 CI (`test_sql` + `test_medium` + `test_shell`) 전체 그린.

---

## Remarks

### 위협 모델 메모

본 회귀의 심각도는 `Minor` 로 들어와 있지만, 위협 모델 관점에서는 TDE 의 **단일 보호 목표** (디스크 도난·백업 유출 시 평문 노출 차단) 가 직접 무력화된 상태다. JIRA priority 판단은 담당 리뷰어에게 맡기되, `feature/oos-m2` 가 develop 으로 머지되기 전에 닫혀야 하는 항목임을 에픽 [CBRD-26583](http://jira.cubrid.org/browse/CBRD-26583) 의 머지 게이트에 추가하도록 제안한다.

### 범위 밖 불변 항목

`file_apply_tde_algorithm` 선언부, `FILE_OOS` 디스크 포맷, `OUT_OF_LINE_OVERFLOW_STORAGE` 라벨은 본 패치에서 변경하지 않는다. 이 항목들의 개선은 별도 cosmetic 티켓으로 분리한다.

### 관련 티켓

- 부모: [CBRD-26583](http://jira.cubrid.org/browse/CBRD-26583) ([OOS][M2] 마일스톤 2)
- 형제: [CBRD-26831](http://jira.cubrid.org/browse/CBRD-26831) ([OOS] numerable file with OOS) -- 인접 OOS regression
- 참고: [CBRD-23608](http://jira.cubrid.org/browse/CBRD-23608) -- TDE 도입 원본 티켓 (회귀의 reference 동작이 정의된 곳)
