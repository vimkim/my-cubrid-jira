# [OOS] [M2] [Regression] 파티션 레코드의 OOS value chain 소유 heap 불일치

## Issue Triage

**이슈 수행 목적**: 파티션 레코드의 OOS value chain 을 레코드가 실제로 저장되는 child partition heap 이 소유하게 하여, vacuum 이 레코드가 있는 heap 에서 chain 을 찾아 정리할 수 있게 한다.

**이슈 수행 이유**:

| 구분 | 동작 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | 파티션 결정 전에 OOS value chain 을 root class heap 의 OOS file 에 기록하고, 레코드는 child partition heap 에 저장한다. SELECT 값은 맞지만 물리적 소유 heap 이 갈라진다. |
| **TO-BE (목표 상태 / 기대 동작)** | 값을 한 번 준비해 보관하고, 목적지 파티션을 고른 뒤, 그 heap 의 OOS file 에 chain 과 레코드를 함께 기록한다. |
| **영향** | QA 실패: vacuum 이 child heap header 에서 OOS VFID 를 찾지 못해 `vacuum_oos_find_vfid_for_heap_record` 의 계측이 abort 하고 cub_server 가 죽는다. 계측을 빼면 chain 정리를 건너뛰어 저장 공간이 누수된다. |

**이슈 수행 방안**: destination-owned deferred write 로 수정한다 — 모든 컬럼의 canonical bytes 를 한 번 직렬화해 소유하는 owner (`heap_prepared_row`) 를 만들고, 준비된 값으로 목적지 파티션을 선택한 뒤, destination heap 의 OOS file 에만 기록한다. INSERT·UPDATE·파티션 이동, 클라이언트 raw row, loader, 재분배, 복제 경로가 같은 계약을 따르고, REPLACE / ON DUPLICATE KEY UPDATE 의 중복 키 탐색은 chain 을 기록하지 않는다. 최초 수정이었던 two-pass probe suppression (PR #7600) 은 `STORAGE FORCE_OUTLINE` 경로가 suppression 을 우회하는 등 producer 경로별 구멍이 남아 이 방식으로 대체했다. 수행 PR 은 [#7927](https://github.com/CUBRID/cubrid/pull/7927) 이며, PR #7600 과 브랜치는 이력 보존을 위해 유지한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: server-side record transform 과 partition routing — `src/storage/heap_file.c`, `src/storage/heap_prepared_row.hpp` (신규), `src/transaction/locator_sr.c`, `src/query/partition.c`, `src/query/query_executor.c` 및 loader·복제 경로. SQL 문법, on-disk OOS inline stub 형식, client protocol 은 바꾸지 않는다. loader 는 payload 를 목적지 결정까지 보유하므로 server peak 메모리가 약 +7~8MiB 증가한다 (측정치는 상세 문서 참고).

---

## Description

OOS (Out-of-row Overflow Storage — 큰 가변 컬럼 값을 heap record 밖 전용 file 에 저장하는 방식) file 은 heap file 마다 최대 하나이며, 해당 heap 의 header page 가 OOS VFID (volume/file identifier) 를 보관한다. 따라서 OOS-backed record 와 그 value chain 은 같은 heap 이 소유해야 한다. SELECT 는 record 안의 24 바이트 OOS inline stub 이 가리키는 head OOS OID 로 chain 을 직접 읽으므로 이 불변식 없이도 값이 맞지만, vacuum 은 record 가 저장된 heap 의 header 에서 OOS VFID 를 찾아 chain 을 지우므로 소유가 어긋나면 vacuum 만 실패한다.

파티션 테이블에서 이 불변식이 깨졌다. 기존 `locator_attribute_info_force` 는 record 를 먼저 직렬화했고, 이 단계의 `heap_attrinfo_insert_to_oos` 는 그 시점에 아는 유일한 class 인 root class OID 를 소유자로 chain 을 기록했다. child partition 을 고르는 `partition_prune_insert` / `partition_prune_update` 는 그 뒤에 실행되므로, record 는 child heap 으로 가고 chain 은 root 의 OOS file 에 남는다.

```
locator_attribute_info_force
 ├ record transform
 │  └ heap_attrinfo_insert_to_oos(root class)   ★ chain 은 root 의 OOS file 로
 └ partition pruning
    └ record write                              ★ record 는 child heap 으로
```

record 크기와 무관하게 컬럼을 항상 OOS 로 보내는 `STORAGE FORCE_OUTLINE` 옵션을 쓰면 64 바이트 값으로도 재현된다. 첫 two-pass 수정 뒤에도 이 옵션 경로는 record-size gate 앞에서 OOS 선택을 먼저 확정해 suppression 검사에 도달하지 않았고, probe 단계에서 root 에 실제 chain 을 쓰는 구멍이 남았다 — 억제 방식 대신 준비-후-기록 방식으로 재설계한 직접적 계기다.

## Test Build

- 재현 (수정 전): `b871ea386d2c5419b7abae07dda58b9b7f36377a`, debug GCC build, Linux x86_64
- 수정 검증: PR #7927, 검증 source `512b361a7a34a4857cd8ad91c496c7e0e94c0769`

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

수정 전에는 값 비교가 1로 성공하는데도 root table 이 `has_oos=1`, `oos_num_recs=1` 이고 `p0` 는 `has_oos=0`, `oos_num_recs=0` 이다. 이후 vacuum 이 이 record 를 처리할 때 child heap 에서 OOS VFID 를 찾지 못해 계측 빌드에서는 cub_server 가 abort 한다.

## Additional Information

### 수정 구조

```
producer (INSERT / UPDATE / 이동 / loader / 재분배 / 복제 ...)
  → heap_prepared_row   모든 컬럼의 canonical bytes 를 한 번 직렬화해 소유
  → partition adapter   준비된 값으로 기존 partition expression 평가
  → locator             destination heap 선택
  → shared finalizer    destination heap 의 OOS file 에 chain 기록 + record 완성
  → 기존 heap / index / replication 소비자
```

목적지가 정해진 뒤에야 chain 이 생기므로 잘못된 소유자가 생길 시점 자체가 없다. owner 는 movable/non-copyable 이며 소멸자는 메모리만 해제한다 — 기록 취소는 기존 transaction/system operation 이 담당하므로 실패 시 record 와 chain 이 함께 롤백된다. 저장/통신 format 과 demotion 정책은 바꾸지 않는다.

### 검증

- 로컬: configured CTest 35/35 (identity, no-logging, crash recovery 포함), 실제 server loader·source/standby 복제·MVCC/SIGKILL 복구·scoped Valgrind 통과.
- 원격 CI (source `512b361a7`): static checks 5/5. medium 3/975 · SQL 2/17463 · shell 20/3277 실패는 전수 분류 결과 24건이 최신 parent 에서 독립 재현되는 baseline, 1건이 잘못된 partition 입력의 의도된 거절로, 이 PR 이 도입한 실패는 없다. 2026-09-15 에 이 범위에서 교체를 수용했다.

### 링크

- 해설 문서 (배경·설계·비용·검증·수용): <https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27089/CBRD-27089-deferred-write_bffe13b_claude.md>
- 원본 감사 기록: <https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27089/CBRD-27089-deferred-write_be7c01a_codex.md>
- PR: <https://github.com/CUBRID/cubrid/pull/7927> (현행), <https://github.com/CUBRID/cubrid/pull/7600> (대체됨, 이력 보존)
