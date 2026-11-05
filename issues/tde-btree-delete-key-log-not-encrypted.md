# [TDE] 암호화 테이블 인덱스의 key를 담은 B-tree 삭제 로그가 TDE 암호화 대상 목록에 없다

**한 줄 요약**: [CBRD-27937](http://jira.cubrid.org/browse/CBRD-27937)(vacuum의 relocation 행 undo 로그 평문 누출)을 고치며 TDE 암호화 대상 목록 `LOG_MAY_CONTAIN_USER_DATA`를 읽다가 develop 코드에서 찾은 의심 결함으로, `ENCRYPT=AES` 테이블의 인덱스 key를 담는 B-tree 삭제 로그 세 종류가 이 목록에 없어 key가 로그 파일에 평문으로 남을 수 있는지 확인한다. 코드 읽기로만 찾았고 서버에서 실행해 확인하지 않았다.

## Issue Triage

**이슈 수행 목적**: `ENCRYPT=AES` 테이블의 인덱스 key를 담는 B-tree 삭제 로그가 활성 로그와 보관 로그에 평문으로 남는지 확인하고, 남는다면 다른 암호화 테이블 로그처럼 암호화되도록 고친다.

**이슈 수행 이유**: 로그 레코드는 recovery index가 `LOG_MAY_CONTAIN_USER_DATA` 목록에 있고 대상 페이지가 TDE 페이지일 때만 TDE 암호화 대상으로 표시된다. `btree_insert_mvcc_delid_into_page`는 인덱스 key를 담은 undo 데이터를 `RVBT_MVCC_DELETE_OBJECT`, `RVBT_MARK_DELETED`, `RVBT_DELETE_OBJECT_POSTPONE` 로그로 기록하는데, 세 recovery index 모두 목록에 없다. develop `e64a04a79`의 소스를 읽어 확인했고, 서버를 실행해 평문이 나타나는지는 확인하지 않았다.

**영향**: TDE는 데이터 볼륨이나 로그 파일이 유출되어도 암호화 테이블의 내용을 읽을 수 없게 하는 기능이다. 이 의심이 맞다면 암호화 테이블에서 행을 DELETE할 때 인덱스 key 값이 로그 파일에 평문으로 남고, 로그 파일을 읽을 수 있는 사람이 키 없이 그 값을 볼 수 있다. 다만 로그 암호화는 로그 페이지 단위이므로 같은 로그 페이지에 암호화 대상 레코드가 있으면 평문이 가려진다. 실제로 평문이 보이는 조건과 빈도는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래 내용은 develop `e64a04a79a5842827a124b3f8313516d0da2594c`의 코드 읽기만으로 작성했다. 빌드하거나 서버를 실행하지 않았고, 평문 key가 로그 파일에 나타나는 것을 관측하지 않았다.

## Description

### 암호화 대상 목록과 세 로그

로그 레코드를 append하는 함수는 `LOG_MAY_CONTAIN_USER_DATA (rcvindex)`가 참이고 대상 페이지가 TDE 페이지일 때만 레코드를 암호화 대상으로 표시한다. [undo/redo 로그의 표시 조건](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_manager.c#L2248-L2258), [postpone 로그의 표시 조건](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_manager.c#L2893-L2903) 이 목록은 [tde.h](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/tde.h#L106-L137)에 있다. B-tree 항목은 `RVBT_INS_PGRECORDS`, `RVBT_NDRECORD_*`, `RVBT_COPYPAGE`, `RVBT_DELETE_OBJECT_PHYSICAL`, `RVBT_NON_MVCC_INSERT_OBJECT`, `RVBT_MVCC_INSERT_OBJECT`, `RVBT_MVCC_INSERT_OBJECT_UNQ`, `RVBT_RECORD_MODIFY_*`, `RVBT_ONLINE_INDEX_UNDO_TRAN_*`이다.

[`btree_insert_mvcc_delid_into_page`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/btree.c#L25814)는 leaf 레코드에 delete MVCCID를 더할 때 다음 로그를 기록한다. [로그 기록 부분](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/btree.c#L25944-L25952)

| recovery index | 기록 방식 | 목록에 있는가 |
|---|---|---|
| `RVBT_MVCC_DELETE_OBJECT` | `log_append_undoredo_data` (`BTREE_OP_INSERT_MVCC_DELID`) | 없다 |
| `RVBT_MARK_DELETED` | `log_append_undoredo_data` (`BTREE_OP_INSERT_MARK_DELETED`) | 없다 |
| `RVBT_DELETE_OBJECT_POSTPONE` | 위 `RVBT_MARK_DELETED`와 함께 `log_append_postpone`으로 undo 데이터를 postpone 데이터로 기록 | 없다 |

이 세 로그의 undo 데이터는 [`btree_rv_save_keyval_for_undo`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/btree.c#L21295)가 만든다. 이 함수는 btid, 객체 OID와 MVCC 정보에 더해 `index_writeval`로 인덱스 key를 데이터에 기록한다. 즉 로그 레코드의 undo 데이터에 key 값이 들어 있다. `RVBT_MARK_DELETED`와 `RVBT_DELETE_OBJECT_POSTPONE`의 덤프 함수도 `btree_rv_keyval_dump`이다. [recovery.c](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/recovery.c#L593-L605)

따라서 인덱스를 가진 TDE 테이블의 행을 DELETE하면 key가 든 위 로그가 기록되지만, 목록에 없으므로 이 레코드 자체는 암호화 대상으로 표시되지 않는다. 같은 INSERT 경로의 `RVBT_MVCC_INSERT_OBJECT` 등은 목록에 있어 암호화 대상이다. 삭제 쪽만 빠져 있다.

### 로그 페이지 단위 암호화와 확인의 어려움

로그 암호화는 레코드가 아니라 로그 페이지 단위로 적용된다. 암호화 대상 레코드를 append하면 그 레코드가 걸친 로그 페이지 전체가 TDE 페이지로 표시된다(CBRD-27937에서 확인한 동작이다). 그러므로 위 로그가 암호화 대상 레코드와 같은 로그 페이지에 있으면 디스크에서 key가 보이지 않는다. 같은 DELETE가 기록하는 heap 로그나 다른 인덱스의 로그 위치에 따라 마스킹 여부가 달라질 것으로 보지만, 로그가 놓이는 순서와 페이지 경계는 읽어 확인하지 않았다. 따라서 이 의심이 실제 평문 노출로 이어지는지, 어떤 조건에서 그런지는 미확인이다.

### ANALYSIS에서 확인할 사항

1. **서버에서의 확인**: 아래 순서는 실행하지 않은 제안이다. CBRD-27937과 같은 마커 방식이다. 인덱스가 있는 `ENCRYPT=AES` 테이블과 대조군으로 암호화하지 않은 같은 구조의 테이블을 만든다. 인덱스 컬럼에 ASCII 마커를 넣은 행을 INSERT하고 COMMIT한 뒤 활성 로그(`<db>_lgat`)와 보관 로그(`<db>_lgar*`)에서 `grep -c -a`로 마커를 센다(INSERT 로그는 목록에 있어 TDE 쪽이 0이어야 하고, 대조군은 0보다 커야 이 방법이 유효하다). 그 행을 DELETE하고 COMMIT한 뒤 다시 센다. TDE 테이블에서 DELETE 뒤에 마커가 나타나면 확인된 것이다. 마커가 0이어도 로그 페이지 마스킹일 수 있으므로, 한 테이블에 인덱스를 여러 개 두거나 key를 크게 하고 행을 많이 지워 B-tree 삭제 로그만 담은 로그 페이지가 생기는 조건을 시험한다. 로그가 디스크에 쓰이도록 마지막에 다른 테이블에 커밋을 하나 더 한다.
2. **같은 문제가 있는 다른 recovery index**: `btree_rv_save_keyval_for_undo`와 `btree_rv_save_keyval_for_undo_two_objects`의 호출처가 기록하는 recovery index 전부를 목록과 대조하지 않았다. 이 이슈는 `RVBT_MVCC_DELETE_OBJECT`, `RVBT_MARK_DELETED`, `RVBT_DELETE_OBJECT_POSTPONE`만 확인했다. key나 행 이미지를 담으면서 목록에 없는 recovery index가 더 있는지 확인한다.
3. **롤백과 복구 시의 compensation 로그**: undo를 적용할 때 남는 compensation 로그도 같은 `LOG_MAY_CONTAIN_USER_DATA`로 암호화 여부를 정한다. [compensation의 조건](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_manager.c#L3173-L3189) 목록을 바꿀 때 이 경로와 postpone 실행 로그(`log_append_run_postpone`)에 어떤 영향이 있는지 확인한다.
4. **이미 남은 평문**: 이미 기록된 활성 로그, 보관 로그, 백업에 대해 운영자에게 안내할 내용이 있는가.

## Additional Information

- 관련 이슈: [CBRD-27937](http://jira.cubrid.org/browse/CBRD-27937)은 같은 목록에서 `RVVAC_HEAP_RECORD_VACUUM`이 빠진 문제를 다룬다. 이 이슈는 B-tree 삭제 로그라는 다른 경로이며, 같은 목록 점검에서 나왔다.
- [매뉴얼의 로그 데이터 암호화 절](https://github.com/CUBRID/cubrid-manual/blob/develop/ko/security.rst?plain=1#L202-L207)은 암호화 테이블과 관련된 모든 로그 정보를 암호화한다고 설명한다.
- 확인하지 않은 범위: 서버 실행, release 빌드, 11.x 릴리스 브랜치이다.
