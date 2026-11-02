## 후보 목록

PR #8299 적대적 리뷰([보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr8299-adversarial-review_f8114e432_claude.md))에서 나온 OOS 후속 후보다. 위치는 `f8114e432` 기준이다.

2026-11-02 기준 OOS 1개와 non-OOS 4개를 후속 이슈로 등록했다. 아래의 생성 상태는 이슈 등록 여부를 뜻하며, 구현 진행은 연결된 이슈에서 추적한다.

| # | 후보 | 위치 | 근거 | 우선순위 | 후속 이슈 | 생성 상태 |
|---|---|---|---|---|---|---|
| 1 | 검사 없는 `OR_VAR_IS_NULL`을 `heap_recdes_get_var_offset_pair()`로 교체 | `heap_file.c:11828` `heap_midxkey_get_oos_extra_size()`, `locator_sr.c:14471` `locator_fixup_oos_oids_in_recdes()` | 잘린 레코드에서 VOT를 범위 밖에서 읽을 수 있다. PR #8299가 같은 패턴을 `heap_oos_attr_has_inline_ref()`에서 고쳤다. 코드 근거만 있다 | 보통 | [CBRD-27874](http://jira.cubrid.org/browse/CBRD-27874) | 생성 |
| 2 | midxkey OOS COPY를 고정하는 테스트 | `heap_file.c` `heap_midxkey_get_value()` | COPY 플래그를 false로 바꾼 mutant가 모든 테스트를 통과한다 | 낮음 | 없음 | 미생성 |
| 3 | copyarea와 workspace 플래그가 다른 UPDATE 경로의 테스트 | `locator_sr.c` `locator_update_force()` | 호출처 네 곳이 항상 같은 값을 넘겨 이 경로는 검증되지 않았다 | 낮음 | 없음 | 미생성 |

CBRD-27874는 [OOS TODO CBRD-26978](http://jira.cubrid.org/browse/CBRD-26978)의 하위 이슈다.

## non-OOS 항목

`develop`(`d5674fe94`)에도 같은 코드가 있어 OOS 후보에서 제외했다. 생성된 항목은 독립 이슈에서 추적한다.

| 항목 | 위치 | 후속 이슈 | 생성 상태 |
|---|---|---|---|
| 손상 레코드의 가변 필드 offset 및 VOT 순회 경계 검사 부족 | `heap_attrvalue_point_variable()` | [CBRD-27877](http://jira.cubrid.org/browse/CBRD-27877) | 생성 |
| 짧은 레코드를 읽을 때 재사용한 속성 캐시의 상태 불일치 | `heap_attrinfo_recache()`, `heap_rec_layout_init()` assert | [CBRD-27876](http://jira.cubrid.org/browse/CBRD-27876) | 생성 |
| writer가 초기화하지 않은 padding 및 미사용 bound bit를 기록 | `heap_attrinfo_transform_to_disk_internal()` | [CBRD-27878](http://jira.cubrid.org/browse/CBRD-27878) | 생성 |
| ASan 보고: `xasl_header` stack-use-after-scope | `do_prepare_update()`, `do_prepare_delete()` | [CBRD-27875](http://jira.cubrid.org/browse/CBRD-27875) | 생성 |
| ASan 보고: shutdown 중 `db_ws_free()` global-buffer-overflow | `quick_fit.c` `db_ws_free()` | 없음 | 미생성 |

`db_ws_free()` 항목은 해제 대상 포인터와 호출자를 아직 특정하지 못했다. 미생성 항목의 이슈화 여부와 범위는 추가 검토한다.

상세 근거는 [OOS 후보](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr8299-adversarial-review_f8114e432_claude.md#oos-existing)와 [OOS 무관 기존 문제](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr8299-adversarial-review_f8114e432_claude.md#non-oos-existing) 절에 있다.
