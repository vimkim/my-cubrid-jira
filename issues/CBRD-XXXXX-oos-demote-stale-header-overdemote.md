# [OOS] Demotion 루프가 진입 시점 header 크기로 gate 를 판정해 경계 사례에서 컬럼을 과잉 demote 한다

## Issue Triage

**이슈 수행 목적**: OOS (Out-of-row Storage) 의 demotion (쓰기 시점에 큰 가변 컬럼을 record 밖 OOS file 로 내보내는 처리) 루프가 판정 시점의 실제 record 크기로 `DB_PAGESIZE/4` gate 를 비교하도록 고쳐, 꼭 필요한 컬럼만 OOS 로 나가게 한다.

**이슈 수행 이유**:

- **AS-IS (현재 동작 / 배경)**: `heap_attrinfo_determine_disk_layout` (heap_file.c:12192) 의 demote 루프는 진입 전에 한 번 계산한 header 크기를 고정해 두고 payload 감소분만 반영해 gate 와 비교한다. header 는 VOT (variable offset table) entry 폭을 통해 record 크기에 의존하므로 (`OR_MAX_BYTE` 127 / `OR_MAX_SHORT` 32767 경계에서 폭이 바뀐다), demotion 이 진행될수록 추정치가 실제보다 커질 수 있다.
- **TO-BE (목표 상태 / 기대 동작)**: 각 demote 판정이 그 시점의 header 재계산 값을 쓴다. gate 근처에서 불필요한 demote 가 사라진다.
- **영향**: 성능 저하 — 경계 사례에서 컬럼 1개가 불필요하게 OOS 로 나가, INSERT 마다 `oos_insert` + WAL 1건, 이후 full read 마다 `oos_read` 페이지 I/O 1건이 그 record 수명 내내 붙는다. 방향은 한쪽뿐이라 (추정 ≥ 실제) 덜 내보내서 페이지에 못 들어가는 정합성 문제는 없다.

**이슈 수행 방안**: 루프 판정을 실제 크기 기준으로 바꾼다. 구현 후보는 가드에서 `heap_attrinfo_get_record_header_size` 재호출 (정수 산술 몇 번이라 비용은 무시 가능). 재계산 방식 확정: TBD - 합의 미확인.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `heap_file.c` 의 `heap_attrinfo_determine_disk_layout` 단일 함수. record format 과 읽기 경로는 불변이고 기존 저장 데이터에도 영향이 없다 — 경계 사례에서 demote 되는 컬럼 수만 1개 줄어든다. 기술 리뷰 발표자료 (CBRD-27014 PPT A) 에서는 이 동작을 "보수적 추정" 으로 소개하던 문구를 제거했다.

## Description

demotion 은 record 가 `DB_PAGESIZE/4` (16KB 페이지에서 4096B) 를 넘을 때 가장 큰 가변 컬럼부터 16B stub (OOS OID) 로 바꿔 내보내는 루프다 (CBRD-26776). 판정식과 계산 시점은 다음과 같다:

```
heap_attrinfo_determine_disk_layout ()                 heap_file.c:12192
 ├ payload_size = Σ 컬럼 disk 크기                      :12207
 ├ header_size  = record header + VOT + bound bits     :12208  <- 한 번만 계산
 ├ mvcc_extra   = OR_MVCC_MAX_HEADER_SIZE(32)
 │              - OR_MVCC_INSERT_HEADER_SIZE(16) = 16  :12209
 └ for cand in 후보 (크기 내림차순):                     :12242
     ★ header_size + payload_size + mvcc_extra
        <= DB_PAGESIZE/4 이면 break                    :12245  <- header_size 는 stale
     payload_size -= cand.size; += 16B stub            :12250
   header_size 재계산 (루프 종료 후 한 번)                :12256
```

header 가 payload 에 의존하는 이유는 VOT entry 폭이다. entry 폭은 record 총 크기가 `OR_MAX_BYTE`(127) 이하면 1B, `OR_MAX_SHORT`(32767) 이하면 2B, 그 이상이면 4B 로 정해지고 (heap_file.c:12154-12171), VOT 는 entry 를 (n_variable + 1) 개 가진다. demotion 이 record 를 32767B 경계 아래로 끌어내리면 실제 header 는 entry 당 2B 씩 (아래 예에서 408B → 216B, 192B) 줄어드는데, 루프는 이 감소를 모른 채 진입 시점 값으로 비교하므로 실제로는 이미 gate 이하로 내려온 record 를 아직 크다고 보고 컬럼 하나를 더 내보낼 수 있다.

틀리는 방향은 한쪽뿐이다 — payload 는 단조 감소하고 header 는 payload 가 줄수록 같거나 작아지므로, 고정된 진입 시점 header 는 항상 실제 이상이다. 과소 추정이 구조적으로 불가능한 이유가 이것이다.

수치 예 — id INT (고정 1개, payload 에 4B 포함) + vc_big 30000B + small 40B × 95개 (가변 96개, VOT entry 97개):

| 단계 | 루프의 추정 | 실제 (재계산 시) |
|------|------------|-----------------|
| demotion 전 | 34212B > 32767 → entry 4B, header 408B | 동일 (아직 정확) |
| vc_big demote 직후 | 408 + 3820 + 16 = **4244 > 4096** | 216 + 3820 + 16 = **4052 ≤ 4096** |
| 판정 | small 1개 추가 demote | demote 불필요, 종료 |

> **요지**: 과잉은 최대 컬럼 1개다. 발생 조건은 (1) demotion 전 record > `OR_MAX_SHORT`(32767B) 이고 (2) demote 후 크기가 gate 위 VOT 축소분 (위 예에서 192B) 이내에 안착하는 경우다. demotion 은 gate (4096B) 에 닿으면 멈추므로 127B 경계는 루프 중에 지나지 않는다 — 실질적으로 32767B 경계만 해당한다.

참고로 PostgreSQL 의 TOAST 루프는 매 iteration `heap_compute_data_size` 로 데이터 크기를 재계산하고, tuple header 크기 (hoff) 는 데이터 크기와 무관해 같은 종류의 드리프트가 없다.

## Test Build

feat/oos 브랜치 `aa629e692` (origin/develop merge 포함). Linux kernel 5.14 (Rocky Linux 9).

## Repro

```bash
{
  printf "CREATE TABLE t_oos_edge (id INT PRIMARY KEY, vc_big BIT VARYING"
  for i in $(seq 1 95); do printf ", s%d BIT VARYING" "$i"; done
  printf ");\n"
  printf "INSERT INTO t_oos_edge VALUES (1, CAST(REPEAT('AA',30000) AS BIT VARYING)"
  for i in $(seq 1 95); do printf ", CAST(REPEAT('BB',40) AS BIT VARYING)"; done
  printf ");\n"
} | csql -u dba testdb
```

관찰은 debug 빌드의 `oos.log` 에서 `oos_insert ... src.size=` 라인 수로 한다 — 릴리스 빌드는 per-column OOS 배치를 확인할 수단이 없다 (CBRD-26871).

위 수치는 상수 기준 책상 계산이라 disk 표현의 per-value 정렬/prefix 로 수십 B 오차가 있을 수 있다. 경계에 안 걸리면 vc_big 또는 small 크기를 수십 B 단위로 스윕하면 걸린다.

## Expected Result

`oos_insert` 1건 — vc_big 만 demote 되고 small 95개는 전부 inline 에 남는다.

## Actual Result

`oos_insert` 2건 — vc_big demote 후 실제 크기는 gate 이하인데 stale header 로 4244B 로 추정해 small 1개를 추가로 demote 한다.

## Additional Information

- 도입 시점: CBRD-26776 (largest-first demotion, PR #7158) — 그 이전 M1 일괄 externalize 정책에는 이 판정 루프 자체가 없었다.
- `cubrid-oos-context` 의 OOS-CONTEXT.md 는 이 동작을 "안전한 보수적 추정 (PG 도 동일)" 으로 기록하고 있다 — PG 동일 서술은 위 Description 대로 부정확하며, 수정 merge 후 문서도 갱신해야 한다.
- 참고 코드: heap_file.c:12208 (진입 시 1회 계산) · :12245 (stale 비교) · :12250-12251 (payload 만 갱신) · :12256 (사후 재계산) · :12154-12171 (VOT entry 폭 선택).
