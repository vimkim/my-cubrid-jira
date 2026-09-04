# [OOS] [M2] [Regression] 파티션 레코드의 OOS value chain 소유 heap 불일치

## Issue Triage

**이슈 수행 목적**: 파티션 레코드의 OOS value chain 을 레코드가 실제로 저장되는 child partition heap 이 소유하도록 하며, `HAS_OOS` 레코드와 OOS VFID 의 heap 단위 불변식을 유지한다.

**이슈 수행 이유**:

| 구분 | 동작 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | 파티션 결정 전에 OOS value chain 을 root class heap 에 기록하고, `HAS_OOS` record 는 child partition heap 에 저장한다. `STORAGE FORCE_OUTLINE` 은 record-size gate 아래에서도 suppression mode 를 우회해 같은 불일치를 만들었다. |
| **TO-BE (목표 상태 / 기대 동작)** | fully-inline probe image 로 partition 을 먼저 결정한 뒤, 선택된 child heap 의 OOS file 에만 value chain 을 기록한다. FORCE_OUTLINE 도 probe 에서는 chain 을 쓰지 않고 final transform 필요성만 보고한다. |
| **영향** | QA 실패: vacuum 이 child heap header 에서 OOS VFID 를 찾지 못해 `vacuum_oos_find_vfid_for_heap_record` 의 merge-readiness 계측에서 abort 한다. 계측 제거 시에는 chain 정리를 건너뛰어 저장 공간이 누수된다. |

**이슈 수행 방안**: partitioned INSERT/UPDATE 에 OOS-suppressed probe transform 과 pruned class 를 받는 final transform 을 적용한다. REPLACE/ODKU 의 key probe 에도 suppression 을 적용하며, FORCE_OUTLINE candidate 는 probe 에서 `would_demote_oos` 만 설정한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/heap_file.c`, `src/transaction/locator_sr.c`, `src/query/query_executor.c` 의 server-side record transform 과 partition routing 을 수정한다. SQL 문법, on-disk OOS inline stub 형식, client protocol 은 바꾸지 않는다.

---

## Description

OOS (Out-of-row Overflow Storage - 큰 가변 컬럼 값을 heap record 밖 전용 file 에 저장하는 방식) file 은 heap file 마다 최대 하나이며, 해당 heap header 가 OOS VFID (volume/file identifier) 를 보관한다. 따라서 OOS-backed record 와 그 value chain 은 같은 heap 단위 ownership 을 가져야 한다.

기존 `locator_attribute_info_force` 는 record 를 먼저 직렬화했다. 이때 `heap_attrinfo_insert_to_oos` 는 INSERT 대상인 root class OID 로 chain 을 기록했다. 그 뒤 `partition_prune_insert` 또는 `partition_prune_update` 가 child partition 을 선택했으므로, record 와 chain 의 owner heap 이 갈라졌다.

```
locator_attribute_info_force
 ├ record transform
 │  └ heap_attrinfo_insert_to_oos(root class)       ★ root OOS file
 └ partition pruning
    └ record write                                  ★ child heap
```

SELECT 는 OOS inline stub 안의 head OOS OID 로 value chain 을 직접 읽으므로 값이 정상처럼 보였다. 반면 vacuum 은 record 가 저장된 child heap header 에서 OOS VFID 를 찾는다. `HAS_OOS` 는 켜져 있지만 VFID 가 없어서 `vacuum_oos_find_vfid_for_heap_record` 의 invariant 계측이 abort 했다.

첫 two-pass 구현 뒤에도 `STORAGE FORCE_OUTLINE` 경로는 suppression 을 우회했다. FORCE_OUTLINE loop 가 `oos_plan.selected` 와 `has_oos` 를 먼저 설정했으며, 일반 record-size gate 안의 suppression 검사에 도달하지 않았다. 그 결과 probe 가 root OOS file 에 실제 chain 을 쓰고도 final transform 필요성을 보고하지 않는 경우가 남았다.

## Test Build

`b871ea386d2c5419b7abae07dda58b9b7f36377a`, debug GCC build, Linux x86_64.

## Repro

```bash
cubrid createdb cbrd27089 en_US.utf8
cubrid server start cbrd27089
csql -u dba cbrd27089 <<'SQL'
CREATE TABLE t_oos_show_part (
  id INT,
  data_col BIT VARYING STORAGE FORCE_OUTLINE
)
PARTITION BY RANGE (id) (
  PARTITION p0 VALUES LESS THAN (10),
  PARTITION p1 VALUES LESS THAN MAXVALUE
);
INSERT INTO t_oos_show_part VALUES (1, REPEAT(X'EE', 64));
COMMIT;
SELECT data_col = CAST(REPEAT(X'EE', 64) AS BIT VARYING)
  FROM t_oos_show_part WHERE id = 1;
SHOW ALL HEAP OOS OF t_oos_show_part;
SQL
```

## Expected Result

값 비교 결과는 1이다. root table 은 `has_oos=0`, `oos_num_recs=0` 이며, 선택된 `p0` partition 만 `has_oos=1`, `oos_num_recs=1` 이다. `p1` 은 OOS file 을 만들지 않는다.

## Actual Result

수정 전 값 비교는 1이지만, root table 이 `has_oos=1`, `oos_num_recs=1` 이고 `p0` 는 `has_oos=0`, `oos_num_recs=0` 이다. 즉 logical read 는 성공해도 physical owner 가 뒤바뀐다.

## Additional Information

### 수정

```
probe transform
 ├ OOS demotion suppression
 └ fully-inline image 로 child partition 결정
       ↓
final transform
 ├ pruned class OID 를 OOS owner 로 사용
 └ child heap OOS file 에 value chain 기록
       ↓
기존 locator insert/update 경로로 record 저장
```

`heap_attrinfo_determine_disk_layout` 는 suppression mode 에서 FORCE_OUTLINE candidate 를 만나면 `would_demote_oos=true` 만 설정하고 계속한다. OOS plan, `HAS_OOS`, inline stub 은 final transform 전까지 만들지 않는다.

REPLACE와 `INSERT ... ON DUPLICATE KEY UPDATE` 가 unique-key 탐색에만 사용하는 임시 record image 도 suppression mode 로 변환한다. 삽입되지 않는 image 때문에 orphan chain 이 생기지 않는다.

### 검증

- FORCE_OUTLINE regression test 는 수정 전 root 1건, `p0` 0건으로 실패했고 수정 후 root 0건, `p0` 1건, `p1` 0건으로 통과했다.
- focused CTest fixture 3/3, 해당 GTest 5/5, configured OOS suite 27/27 통과.
- 999-row hash-partition workload 는 `COUNT(*)=999`, root `has_oos=0`, 네 child partition `has_oos=1`, workload 뒤 server 생존을 확인했다.
- 이 local rerun 의 backup 단계는 기존 backup 이름 충돌로 실패했으므로 backup/restart 검증 근거로 포함하지 않는다.
- 상세 보고서: https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27089/CBRD-27089-oos-chain-owner-b871ea3_codex.md
- PR: https://github.com/CUBRID/cubrid/pull/7600

