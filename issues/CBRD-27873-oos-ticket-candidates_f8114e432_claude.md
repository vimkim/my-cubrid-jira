## 후보 목록

PR #8299 적대적 리뷰([보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr8299-adversarial-review_f8114e432_claude.md))에서 나온 OOS 후속 후보다. 위치는 `f8114e432` 기준이다.

2026-11-02 기준 OOS 2개와 non-OOS 4개를 후속 이슈로 등록했다. midxkey와 copyarea/workspace 테스트 후보는 CBRD-27880 한 건으로 묶었다. 아래의 생성 상태는 이슈 등록 여부를 뜻하며, 구현 진행은 연결된 이슈에서 추적한다. 생성된 6개 후속 이슈의 담당자는 모두 `vimkim`이다.

| # | 후보 | 위치 | 근거 | 우선순위 | 후속 이슈 | 생성 상태 |
|---|---|---|---|---|---|---|
| 1 | 검사 없는 `OR_VAR_IS_NULL`을 `heap_recdes_get_var_offset_pair()`로 교체 | `heap_file.c:11828` `heap_midxkey_get_oos_extra_size()`, `locator_sr.c:14471` `locator_fixup_oos_oids_in_recdes()` | 잘린 레코드에서 VOT를 범위 밖에서 읽을 수 있다. PR #8299가 같은 패턴을 `heap_oos_attr_has_inline_ref()`에서 고쳤다. 코드 근거만 있다 | 보통 | [CBRD-27874](http://jira.cubrid.org/browse/CBRD-27874) | 생성 |
| 2 | midxkey OOS COPY 수명을 검증하는 테스트 | `heap_file.c` `heap_midxkey_get_value()` | 기존 리뷰는 COPY를 false로 바꾼 변형이 통과했다고 보고했다. 임시 버퍼 수명 계약의 회귀 테스트를 보완한다. 최신 head의 변형은 재실행하지 않았다 | 낮음 | [CBRD-27880](http://jira.cubrid.org/browse/CBRD-27880) | 생성 |
| 3 | copyarea 및 workspace 지원 입력 경로의 테스트 보완 | `locator_sr.c` `locator_finalize_oos_record()`, `locator_update_force()` | 초기 후보의 비동일 UPDATE 플래그 조합은 현재 호출처에서 사용하지 않는다. 별도 결함 이슈 대신 지원 경로의 테스트 보완을 midxkey와 같은 misc 이슈에 포함한다 | 낮음 | [CBRD-27880](http://jira.cubrid.org/browse/CBRD-27880) | 생성 |

CBRD-27874와 CBRD-27880은 [OOS TODO CBRD-26978](http://jira.cubrid.org/browse/CBRD-26978)의 하위 이슈다.

## non-OOS 항목

`develop`(`d5674fe94`)에도 같은 코드가 있는 항목을 OOS 후보에서 제외해 별도로 추적한다. 다만 shutdown 후보는 검출 코드의 동일성만 확인했으며, 실제 실패의 OOS 관련성은 아직 미확정이다. 생성된 항목은 독립 이슈에서 추적한다.

| 항목 | 위치 | 후속 이슈 | 생성 상태 |
|---|---|---|---|
| 손상 레코드의 가변 필드 offset 및 VOT 순회 경계 검사 부족 | `heap_attrvalue_point_variable()` | [CBRD-27877](http://jira.cubrid.org/browse/CBRD-27877) | 생성 |
| 짧은 레코드를 읽을 때 재사용한 속성 캐시의 상태 불일치 | `heap_attrinfo_recache()`, `heap_rec_layout_init()` assert | [CBRD-27876](http://jira.cubrid.org/browse/CBRD-27876) | 생성 |
| writer가 초기화하지 않은 padding 및 미사용 bound bit를 기록 | `heap_attrinfo_transform_to_disk_internal()` | [CBRD-27878](http://jira.cubrid.org/browse/CBRD-27878) | 생성 |
| ASan 보고: `xasl_header` stack-use-after-scope | `do_prepare_update()`, `do_prepare_delete()` | [CBRD-27875](http://jira.cubrid.org/browse/CBRD-27875) | 생성 |
| ASan 보고: shutdown 중 `db_ws_free()` global-buffer-overflow | `quick_fit.c` `db_ws_free()` | 없음 | 생성 보류 |

`db_ws_free()` 항목은 원본 ASan stack, 해제 대상 포인터와 호출자, 실패한 테스트 및 재현 명령을 확보하지 못했다. 같은 검출 함수를 사용하는 기존 JIRA는 있으나 이 후보와 중복인지 판단할 근거가 부족하다. 일반 이슈 생성은 보류하고, 원본 로그를 확보하거나 독립 재현한 뒤 OOS 관련성, 범위 및 중복 여부를 다시 판단한다.

상세 근거는 [OOS 후보](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr8299-adversarial-review_f8114e432_claude.md#oos-existing)와 [OOS 무관 기존 문제](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr8299-adversarial-review_f8114e432_claude.md#non-oos-existing) 절에 있다.
