# [CBRD-26974] storage AGENTS.md 정리

## Issue Triage

**이슈 수행 목적** (필수): `src/storage` 작업자가 필요한 저장소 모듈 안내를 빠르게 찾도록 `AGENTS.md` 를 짧은 진입점 문서로 정리하고, 세부 설명은 주제별 참고 문서로 분리한다.

**이슈 수행 이유** (필수):

- **현재 동작 / 배경**: 기존 `src/storage/AGENTS.md` 는 `Server-side (SERVER_MODE / SA_MODE)` 로 범위를 단순화하지만, 실제 `cubridcs` 빌드에도 `es.c`, `statistics_cl.c`, `file_io.c` 등 일부 storage 파일이 포함된다. 또 `btree.c` 약 37K lines, `heap_file.c` 약 27K lines, `page_buffer.c` 약 17K lines 규모에 비해 함수 진입점과 하위 파일 관계 안내가 한 문서 안에만 얕게 들어 있다.
- **영향**: 기술 부채 - 에이전트가 잘못된 build-mode 경계를 전제로 코드를 읽거나, 큰 파일에서 실제 수정 지점을 찾기 위해 불필요한 탐색을 반복할 수 있다.

**이슈 수행 방안**: 사용자 요청("since this module contains too many files... write separate reference doc file per file, and make AGENTS.md refer to it")을 기준으로, 엄격한 파일별 문서 대신 주제별 reference 문서 구조를 적용한다. `AGENTS.md` 는 index와 안전 규칙만 남기고, `src/storage/docs/` 에 storage foundations, buffer/I/O, disk/file, heap/record, btree, catalog/statistics, external storage 문서를 추가한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/AGENTS.md` 와 새 `src/storage/docs/*.md` 문서 7개만 대상이다. C/C++ 소스, CMake target, SQL 동작, 디스크 형식, 테스트 기대값은 변경하지 않는다.

---

## Description

이 작업은 `src/storage` 의 agent 안내 문서를 모듈 규모에 맞게 재구성한다. `AGENTS.md` 는 코드 작업 전에 반드시 읽히는 진입점에 가깝기 때문에, 너무 길어지면 오히려 중요한 규칙이 묻힌다. 따라서 상위 문서는 짧은 index 역할을 맡기고, 실제 코드 탐색에 필요한 세부 내용은 하위 문서로 보낸다.

변경 후 `src/storage/AGENTS.md` 는 다음 정보만 가진다.

- storage 모듈의 build-mode 경계
- 주제별 reference 문서 링크
- 주요 파일과 작업별 시작 지점
- `VPID`, `VFID`, `HFID`, `BTID`, `OID`, `RECDES` 같은 핵심 식별자
- `pgbuf_fix*`, `pgbuf_unfix*`, `pgbuf_set_dirty*` 중심의 buffer pool 사용 규칙
- page latch, transaction lock, `PGBUF_WATCHER`, disk compatibility 관련 주의 사항

새로 추가하는 reference 문서는 다음과 같이 나뉜다.

| 문서 | 담당 범위 |
|------|-----------|
| `src/storage/docs/storage-foundations.md` | 공통 식별자, OID helper, `RECDES`, byte order |
| `src/storage/docs/buffer-io-durability.md` | `page_buffer.c`, raw I/O, double-write buffer, TDE |
| `src/storage/docs/disk-file-space.md` | volume, sector, `VFID`, file allocation, extendible hash |
| `src/storage/docs/heap-record-pages.md` | heap scan, heap mutation, MVCC version, slotted page, overflow record |
| `src/storage/docs/btree-indexes.md` | B-tree lookup, range scan, insert/delete, bulk load, unique stats |
| `src/storage/docs/catalog-statistics-maintenance.md` | system catalog, catalog class, client/server statistics, compactdb |
| `src/storage/docs/external-storage-lob.md` | external storage URI, POSIX backend, OWFS backend, LOB 관련 진입점 |

특히 build-mode 경계를 바로잡는 것이 중요하다. `btree.c`, `heap_file.c`, `page_buffer.c`, `disk_manager.c`, `file_manager.c` 같은 핵심 manager는 server/standalone 중심이다. 반면 `es.c`, `es_common.c`, `es_posix.c`, `file_io.c`, `oid.c`, `statistics_cl.c`, `storage_common.c`, `tde.c` 는 client target에도 포함된다. 이 차이를 `AGENTS.md` 첫 부분에 명시해 agent가 server-only API를 client-side file에 잘못 끌어들이지 않도록 한다.

검증은 문서 파일 기준으로 수행한다. `src/storage/AGENTS.md` 와 `src/storage/docs/*.md` 를 staging한 뒤 `git diff --cached --check` 로 whitespace와 patch 형식을 확인하고, markdown link 대상 파일이 실제로 존재하는지 확인한다. 코드 변경이 없으므로 build와 SQL regression은 범위 밖이다.
