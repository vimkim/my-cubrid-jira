# [OOS] standalone loaddb와 CSQL workspace 쓰기의 OOS 지원

## Issue Triage

**이슈 수행 목적**: standalone 적재에서도 OOS (Out-of-row Overflow Storage, 큰 컬럼 값을 별도 페이지로 분리하는 저장 방식)를 사용할 수 있도록 한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|---|---|
| AS-IS (현재 동작 / 배경) | `loaddb -S`와 `insert_execution_mode=0`으로 선택한 `csql -S` 쓰기는 OOS 대상인 큰 값을 분리하지 않는다. |
| TO-BE (목표 상태 / 기대 동작) | 두 경로에도 기존 OOS 저장 정책을 적용하고, 저장한 값과 객체 참조를 유지한다. |
| 영향 | 설계 의도 훼손: 같은 5,000바이트 VARBIT 값이 일반 SQL INSERT에서는 별도 페이지에 저장되지만 standalone 객체 적재에서는 행 내부에 남는다. |

**이슈 수행 방안**: loader와 CSQL이 공유하는 standalone 저장 경로를 수정한다. 현재 `feat/oos` 기준에서 독립적으로 구현하고 PR #7695와의 호환성은 별도로 검증한다. 기존 저장 정책과 no-logging 지원은 유지한다.

---

## AI-Generated Context

> 아래 상세 내용은 AI가 소스 코드, 실행 결과와 진단 보고서를 바탕으로 작성한 구현·검증 참고 자료다.

### 변경 범위

변경 파일은 `src/transaction/locator_sr.c`, `src/transaction/locator_sr.h`, `unit_tests/oos/CMakeLists.txt`, `unit_tests/oos/scripts/test_workspace_oos.py`이다. 외부 프로토콜과 OOS 참조의 디스크 형식은 변경하지 않는다.

## Description

workspace는 저장 전 객체를 메모리에 보관하는 영역이다. 해당 영역의 객체는 `tf_mem_to_disk`에서 디스크 레코드로 직렬화된 뒤 force 경계, 즉 실제 heap·index 쓰기를 수행하는 단계로 전달된다. 기존 경로에는 컬럼별 OOS 배치를 결정하는 변환 호출이 없다.

```text
변경 전 workspace 경로
  tf_mem_to_disk
    -> xlocator_force
      -> locator_insert_force / locator_update_force
        -> heap·index 쓰기

기존 SQL 실행기 경로
  locator_attribute_info_force
    -> locator_allocate_copy_area_by_attr_info
      -> heap_attrinfo_transform_to_disk
        -> OOS 배치 결정 및 값 조각 생성
    -> heap·index 쓰기
```

디버거에서 최소 SA (standalone) loader 재현은 `tf_mem_to_disk`를 한 번 호출했지만 `heap_attrinfo_determine_disk_layout`과 `oos_insert_many`를 호출하지 않았다. 따라서 변환기의 선택 결과나 생성 후 조각 유실을 조사하기 전에, 변환 진입 자체가 빠져 있음을 확인했다.

`csql -S`의 `-S`는 별도 서버 프로세스 없이 실행한다는 뜻이며, SQL의 내부 쓰기 경로까지 정하지 않는다. 일반 INSERT는 SQL 실행기 경로를 사용하므로 이미 OOS가 적용된다. 영향 확인에는 workspace를 선택하는 시스템 파라미터를 사용했고, UPDATE는 행 트리거가 있는 경로로 검증했다.

## Repro

### 독립 실행 예제

아래 내용을 `CBRD-27424-repro_e24b458_codex.sh`로 저장한다. 이 예제는 PR에 추가한 회귀 테스트 파일에 의존하지 않으므로 수정 전 빌드에서도 실행할 수 있다. Bash, Python 3와 OOS 통계 명령을 지원하는 해당 브랜치의 설치본이 필요하다. `CUBRID`, `PATH`, 라이브러리 경로가 검사할 설치본을 가리키도록 설정한다.

매번 임시 디렉터리에 독립된 DB 등록 파일과 DB를 만든다. 모두 SA 모드로 접근하며, 성공하면 DB를 삭제하고 생성한 SQL·객체 입력·출력 파일은 남긴다. 기본 INSERT 동작에 영향을 주는 별도 환경 설정 없이 실행한다.

```bash
#!/usr/bin/env bash
set -euo pipefail
expected=${1:?Usage: bash CBRD-27424-repro_e24b458_codex.sh before|after}
case "$expected" in before|after) ;; *) exit 2 ;; esac
repro_dir=$(mktemp -d "${TMPDIR:-/tmp}/cbrd27424-repro.XXXXXX")
export CUBRID_DATABASES="$repro_dir"
export CUBRID_CONF_FILE="$repro_dir/cubrid.conf"
cd "$repro_dir"
printf '[common]\ndata_buffer_size=64M\nlog_buffer_size=16M\n' > cubrid.conf
printf 'Evidence: %s\n' "$repro_dir"
cubrid createdb --db-page-size=16K --db-volume-size=32M --log-volume-size=32M -F "$repro_dir" oos27424 en_US.utf8 > createdb.out 2>&1
python3 - <<'PY'
from pathlib import Path
import random
rng = random.Random(27424)
payload = bytes(rng.randrange(256) for _ in range(5000)).hex()
Path('schema.sql').write_text('CREATE TABLE t_load(v BIT VARYING);\nCREATE TABLE t_ws(v BIT VARYING);\nCREATE TABLE t_normal(v BIT VARYING);\nCOMMIT;\n')
Path('load.objects').write_text("%%class t_load (v)\nX'%s'\n" % payload)
Path('workspace.sql').write_text("SET SYSTEM PARAMETERS 'insert_execution_mode=0';\nINSERT INTO t_ws VALUES (X'%s');\nCOMMIT;\n" % payload)
Path('normal.sql').write_text("INSERT INTO t_normal VALUES (X'%s');\nCOMMIT;\n" % payload)
for table in ('t_load', 't_ws', 't_normal'):
    Path(table + '.sql').write_text("SELECT CASE WHEN COUNT(*)=1 AND SUM(CASE WHEN v=X'%s' THEN 1 ELSE 0 END)=1 THEN 'VALUE_OK' ELSE 'VALUE_BAD' END AS verdict FROM %s;\n;oos_stats %s\n" % (payload, table, table))
PY
csql -S -u dba --no-auto-commit oos27424 < schema.sql > schema.out 2>&1
cubrid loaddb -S -u dba -d load.objects oos27424 > load.out 2>&1
csql -S -u dba --no-auto-commit oos27424 < workspace.sql > workspace.out 2>&1
# 새 CSQL 프로세스에서 기본 INSERT 경로를 실행한다.
csql -S -u dba --no-auto-commit oos27424 < normal.sql > normal.out 2>&1
for table in t_load t_ws t_normal; do
    csql -S -u dba --no-auto-commit oos27424 < "$table.sql" > "$table.out" 2>&1
done
python3 - "$expected" <<'PY'
from pathlib import Path
import re
import sys
expected = [0, 0, 1] if sys.argv[1] == 'before' else [1, 1, 1]
for table, wanted in zip(('t_load', 't_ws', 't_normal'), expected):
    output = Path(table + '.out').read_text()
    assert "'VALUE_OK'" in output and "'VALUE_BAD'" not in output, output
    match = re.search(r'Live OOS records\s*:\s*(\d+)', output)
    actual = int(match[1]) if match else 0 if 'has no OOS file' in output else None
    print('%s: VALUE_OK, OOS=%s (expected %s)' % (table, actual, wanted))
    assert actual == wanted, output
PY
cubrid deletedb oos27424 > deletedb.out 2>&1
```

수정 전 `f4299ac0c` 설치 환경:

```sh
bash CBRD-27424-repro_e24b458_codex.sh before
```

수정 후 `e24b458bf`와 같은 소스의 설치 환경:

```sh
bash CBRD-27424-repro_e24b458_codex.sh after
```

인자는 비교할 기대값만 선택한다. 실제로 사용할 바이너리는 실행 전에 지정한 설치 환경으로 결정된다. `before`가 성공한다는 것은 수정 전 증상을 그대로 관찰했다는 뜻이다.

### 각 입력이 확인하는 경로

| 파일 | 핵심 입력 | 실행 경로 |
|---|---|---|
| `load.objects` | `%class t_load (v)` 다음 줄의 `X'…'` | `cubrid loaddb -S -u dba -d load.objects oos27424` |
| `workspace.sql` | `SET SYSTEM PARAMETERS 'insert_execution_mode=0';` 다음 INSERT와 COMMIT | CSQL workspace 쓰기 |
| `normal.sql` | 파라미터 변경 없이 INSERT와 COMMIT | 별도 CSQL 프로세스의 일반 INSERT 제어군 |
| `t_load.sql`, `t_ws.sql`, `t_normal.sql` | 정확한 값 비교 SELECT 및 `;oos_stats` | 새 연결에서 논리 값과 물리 저장을 함께 확인 |

`X'…'`는 표의 축약 표기다. 실행 스크립트가 실제 10,000자리 16진수 리터럴을 생성하므로 수동으로 값을 채울 필요가 없다.

### 예상 출력과 증상 판정

```text
수정 전
  t_load:   VALUE_OK, OOS=0
  t_ws:     VALUE_OK, OOS=0
  t_normal: VALUE_OK, OOS=1

수정 후
  t_load:   VALUE_OK, OOS=1
  t_ws:     VALUE_OK, OOS=1
  t_normal: VALUE_OK, OOS=1
```

`has no OOS file` 출력은 위 비교에서 0으로 취급한다. 행 수나 값 일치만 확인하면 수정 전에도 성공하므로, 반드시 OOS 조각 수까지 확인한다. 같은 예제를 수정 전·후 설치 환경에서 각각 실행하여 위 조각 수와 값 일치를 확인했다. 두 실행 모두 지정한 기대값과 일치해 종료 코드 0을 반환했다.

## Specification Changes

새 SQL 문법이나 설정은 추가하지 않는다. 기존 OOS 배치 규칙을 standalone 객체 쓰기에 연결하며, 분리할 컬럼이 없으면 기존 레코드를 그대로 저장한다. 일반 SQL 실행기, CS (client-server) loader와 복제 경로의 호출 동작은 유지한다.

`--no-logging`은 성공한 적재와 읽기를 지원하는 범위로 검증한다. 실패 후 복구나 로그가 없을 때의 참조 식별자 유일성을 새로 보장하지 않는다. OOS 크기 기준과 identity stamp (참조 대상을 구분하는 식별 정보) 도입은 이번 변경에 포함하지 않는다.

## Implementation

`locator_demote_workspace_record`가 SA 모드의 workspace 레코드를 읽어 기존 heap attribute 변환기에 전달한다.

| 처리 지점 | 구현 |
|---|---|
| 호출 경로 구분 | `from_workspace` 인자로 INSERT, 예약된 OID (객체 식별자)를 채우는 UPDATE, 여러 행 UPDATE를 구분한다. 클래스 정의와 이미 OOS 변환한 레코드는 제외한다. |
| 파티션 결정 | 실제 파티션과 heap을 고른 뒤 변환한다. 파티션 이동은 대상 INSERT까지 호출 경로 정보를 전달한다. |
| 트랜잭션 범위 | 기존 top operation (묶어서 되돌릴 내부 작업 단위) 안에서 OOS 생성과 heap·index 쓰기를 수행한다. 적재 중 무시하는 오류의 객체별 롤백도 포함한다. |
| 버퍼와 메타데이터 | 별도 copyarea (전송·저장 레코드 버퍼)에 결과를 만들고 모든 종료 경로에서 해제한다. OOS 분리를 수행한 레코드는 입력 CHN (캐시 변경 번호)을 보존한다. |
| 기존 외부 LOB | `LOB_FLAG_EXCLUDE_LOB`를 사용해 BLOB/CLOB의 기존 외부 파일을 다시 복사하지 않는다. |

### 수정 위치 후보와 선택 근거

다음 표는 수정 위치별 구조적 장단점이다. 모든 후보를 구현해 성능을 비교한 결과는 아니다.

| 후보 | 구현 방향 | 장점 | 선택하지 않은 이유 또는 제약 |
|---|---|---|---|
| loader 전용 수정 | SA loader가 force를 호출하기 전에 OOS 변환을 추가한다. | loader에 수정 범위를 한정하기 쉽다. | CSQL workspace 쓰기는 해결되지 않는다. 객체 참조·파티션·오류 처리를 loader 쪽에서 다시 연결해야 한다. |
| workspace 직렬화 수정 | `tf_mem_to_disk`에서 OOS를 생성한다. | 공통 직렬화 단계에서 대상 쓰기를 모을 수 있다. | 최종 저장 파티션과 force의 롤백 범위가 확정되기 전이다. 직렬화 단계에 저장 부수 효과를 넣고 client/server 호출 경계까지 다뤄야 한다. |
| **공통 force 경계 수정 — 선택** | workspace 호출을 구분하고 INSERT/UPDATE에서 파티션 선택 후 기존 변환기를 호출한다. | loader와 CSQL을 함께 처리하며 OOS 생성·index 오류를 기존 작업 단위로 되돌릴 수 있다. | 예약 OID를 채우는 UPDATE와 파티션 이동까지 전달해야 한다. 임시 버퍼 및 CHN 보존도 필요하다. |
| 저수준 heap 쓰기 수정 | 모든 heap INSERT/UPDATE에서 OOS 여부를 다시 판단한다. | 물리 쓰기 지점에 처리를 모을 수 있다. | 이미 변환한 SQL·loader·복제 레코드까지 대상이 넓어진다. index 작업과의 순서 및 중복 변환을 더 많은 호출자에서 검증해야 한다. |

선택 기준은 두 가지다. loader만 고치면 사용자가 선택한 CSQL 포함 범위가 충족되지 않는다. 반대로 모든 물리 쓰기를 바꾸면 기존 변환 경로까지 영향을 받는다. 공통 force 경계에서는 실제 저장 대상과 롤백 범위를 이용하면서 `from_workspace`로 적용 대상을 한정할 수 있다.

기준 브랜치도 별도로 결정했다. PR #7695 위로 옮기는 방법은 identity stamp 변경을 함께 전제로 삼게 된다. 현재 기준에서 구현하는 방법은 기존 OOS API만 사용하므로 loader 지원과 참조 형식 변경을 분리해 검토할 수 있다. 사용자가 현재 기준 유지와 공통 SA workspace 수정을 선택했으며, PR #7695에 동일 패치를 적용하는 별도 검증으로 호환성을 확인했다.

### 선택한 경계의 처리 순서

```text
xlocator_force / locator_force_for_multi_update
  -> 기존 top operation 안에서 처리
  -> locator_insert_force / locator_update_force
     -> 실제 저장 파티션 선택
        (이동 시 대상 locator_insert_force로 from_workspace 전달)
     -> locator_demote_workspace_record
        -> 레코드를 속성 값으로 읽기
        -> 기존 OOS 변환기 호출, 기존 외부 LOB 복사 제외
        -> 분리된 레코드의 CHN 보존
     -> heap·index 쓰기
     -> 성공·실패 경로에서 임시 copyarea 해제 후 반환
  -> 오류 시 기존 전체/객체별 롤백으로 생성한 OOS 조각도 취소
```

## Acceptance Criteria

- [x] SA loader와 CSQL workspace INSERT에서 값 일치 및 실제 OOS 저장을 확인한다.
- [x] 객체 참조, 파티션별 소유권과 파티션 이동을 보존한다.
- [x] INSERT·UPDATE 롤백, DELETE, 적재 실패 및 무시한 오류 뒤에 불필요한 OOS 조각이 남지 않는다.
- [x] 작은 값·NULL·빈 값, FORCE_OUTLINE, 큰 컬럼 우선 선택, 여러 조각 저장을 검증한다.
- [x] 기존 외부 BLOB/CLOB 파일을 보존하고 no-logging 적재 후 값을 정확히 읽는다.
- [x] 일반 SA/CS SQL INSERT와 CS loader 동작을 확인하고 PR #7695 기준에서도 집중 회귀 테스트를 통과한다.

## Definition of done

- [x] 수락 조건을 로컬 회귀 테스트로 확인한다.
- [x] GCC debug 빌드와 구성된 CTest를 통과한다.
- [x] 구현·검증 보고서를 작성하고 draft PR을 게시한다.
- [ ] 회사 CI/QA 결과를 확인한다.
- [ ] 코드 리뷰 승인을 받고 병합한다.
- [ ] 매뉴얼 반영 필요 여부를 확인한다.

## Verification

### 검증 기준

| 항목 | 기준 |
|---|---|
| 변경 전 소스 | `f4299ac0cd777a2a964c1f197ae5ebf9841a4936` |
| 분석한 PR #7925 소스 | `e24b458bfea4d49cc763328c055c5c5374694b06` |
| 기준 브랜치 | `feat/oos` |
| 빌드 | GCC debug, `11.5.0.2648-f4299ac` 기준 소스에 수정 적용 |
| 테스트 환경 | 전용 DB 등록 파일과 임시 DB, 회귀 테스트의 DB 페이지 크기는 16 KiB |
| 데이터 확인 | 고정 난수 VARBIT의 정확한 값 일치와 `;oos_stats`의 실제 OOS 조각 수 |

5,000바이트 입력은 작은 값 제어군과 구분되는 OOS 대상 값이며 문자열 압축의 영향을 피한다. 추가로 50,000바이트 값을 사용해 한 값이 여러 페이지에 걸리는 경우를 확인했다.

### 전체 회귀 테스트 실행

해당 소스의 빌드를 설치하고 `cubrid`와 `csql`이 그 설치본을 사용하도록 환경을 설정한 뒤, 소스 루트에서 실행한다. Python 3가 필요하다.

```sh
python3 unit_tests/oos/scripts/test_workspace_oos.py
```

### 확인한 결과

| 검증 | 결과 |
|---|---|
| 변경 전 최소 SA loader 회귀 | 논리 값은 일치하지만 OOS 조각이 0개여서 실패 |
| 변경 전 구성된 CTest | 27/27 통과 |
| 변경 후 구성된 CTest | 28/28 통과, 176.16초 |
| 추가한 CLI 회귀 | 12개 시나리오 통과, 62.86초 |
| SA/CS loader와 일반 CSQL의 4개 경로 비교 | 모두 값 일치, 각 1개 OOS 조각, 17.48초 |
| PR #7695의 `eaf1165bbc76d5f22b6ff34f08ccd8deca0c11b4` | 동일 패치 적용·별도 빌드·새 DB의 12개 회귀 시나리오 통과 |

테스트한 소스 내용은 분석한 PR 커밋과 동일하다. PR #7695 호환성 결과는 빌드와 집중 회귀 검증이며, 해당 PR의 전체 테스트나 CI 통과를 뜻하지 않는다.

## Remarks

기존 외부 LOB 검증은 다른 컬럼을 OOS로 분리할 때 BLOB/CLOB 내용과 파일 이름·바이트가 롤백 및 커밋 후 유지되는지 확인한 결과다. LOB locator 자체의 OOS 분리 조합 전체를 검증한 것은 아니다.

새 BLOB/CLOB를 workspace INSERT로 생성할 때 파일을 찾지 못하는 별도 결함은 수정 전 기준에서도 재현되며, 본 이슈의 수정 범위에서 제외한다.

관련 자료:

- [CBRD-27424](https://jira.cubrid.org/browse/CBRD-27424)
- [Draft PR #7925](https://github.com/CUBRID/cubrid/pull/7925)
- [진단 및 검증 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27424/CBRD-27424-sa-workspace-oos_e24b458_codex.md)
- [호환성을 별도 검증한 PR #7695](https://github.com/CUBRID/CUBRID/pull/7695)
