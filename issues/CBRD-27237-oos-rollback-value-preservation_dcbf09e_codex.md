# [OOS] UPDATE를 취소한 뒤에도 vacuum이 원래 값을 지워 조회가 실패한다

## Issue Triage

**이슈 수행 목적**: UPDATE를 취소하면 이전에 저장을 확정한 값이 계속 남아 있어야 한다. 큰 컬럼 값을 행 밖에 저장하는 OOS에서도 이 원칙을 지키도록 한다.

**이슈 수행 이유**: UPDATE를 취소한 직후에는 원래 값을 읽을 수 있다. 그러나 나중에 불필요한 데이터의 공간을 정리하는 작업인 vacuum이 그 값을 지워 버린다. PR #7990 리뷰어가 SQL로 재현하고 머지 차단 사유로 지적했다.

**영향**: 이미 저장이 확정된 값을 잃고, 그 값을 읽는 질의가 `-1389` 오류로 실패한다. 큰 컬럼 자체를 바꾸지 않고 같은 행의 작은 컬럼만 바꿨다가 취소해도 발생한다. 운영 부하에서의 발생 빈도는 측정하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

OOS는 큰 문자열 같은 값을 행과 별도인 공간에 저장한다. 행에는 그 값이 있는 곳을 가리키는 참조를 남긴다. 하나의 값이 여러 조각으로 나뉘면, 연결된 조각 전체를 OOS 체인이라고 한다.

다음은 큰 컬럼의 원래 값이 A인 경우다. commit은 저장을 확정하는 것이고, rollback은 아직 확정하지 않은 변경을 취소하는 것이다.

1. 값 A를 저장하고 commit한다.
2. UPDATE로 값을 B로 바꾼다. DB는 B를 새 공간에 쓰고, 취소할 때 A로 돌아갈 수 있도록 변경 전 행을 로그에 남긴다.
3. rollback한다. 행은 다시 A를 가리킨다. 이때 조회하면 A가 정상으로 읽힌다.
4. 나중에 vacuum이 UPDATE 로그를 읽는다. 로그에 남은 A를 더 이상 쓰지 않는 값으로 잘못 판단해 지운다.
5. 행은 여전히 A를 가리키지만 A의 실제 데이터는 없다. 이후 조회가 `-1389` 오류로 실패한다.

핵심은 **UPDATE가 취소되었으므로 A가 다시 현재 값이 되었는데, vacuum은 여전히 A를 버려진 값으로 취급한다는 점**이다.

이 경로에서 vacuum은 변경 전 행의 로그 사본인 undo image만 보고 삭제할 OOS 체인을 찾는다. UPDATE가 commit되었는지, 현재 행이 그 체인을 여전히 쓰는지는 확인하지 않는다. rollback 뒤에도 원래 UPDATE 로그가 vacuum 처리 대상에 남아 있어 위 순서가 가능하다. [삭제 판단을 하는 코드](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/query/vacuum.c#L3608-L3626), [rollback 완료 후 MVCC 상태를 정리하는 코드](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/transaction/log_manager.c#L5383-L5396).

현재 구현은 작은 컬럼만 UPDATE해도 행의 OOS 값을 새 체인에 다시 쓴다. 따라서 큰 컬럼의 값을 직접 바꾸지 않은 UPDATE도 같은 문제를 일으킨다.

### 왜 문제인가

사용자는 UPDATE를 취소하면 이전에 commit한 데이터가 보존된다고 기대한다. 현재는 rollback 직후 조회까지 성공하므로 정상적으로 취소되었다고 판단하게 된다. 실제 손실은 나중에 vacuum이 실행될 때 생긴다. 실패한 변경 때문에 그보다 먼저 확정된 데이터를 잃는 것이다.

리뷰어는 이를 영구 데이터 손실로 보고했다. 원본 소스 분석에서도 vacuum의 삭제는 별도 작업으로 확정되므로 원래 UPDATE를 다시 rollback해서 복원할 수 없다고 설명한다. 삭제 시점에는 오류가 없고 이후 조회에서 오류가 드러나므로, 원인이 된 UPDATE를 찾기도 어렵다.

명시적인 ROLLBACK과 서버 장애 후 복구에서는 리뷰어의 재현 보고가 있다. 연결 끊김이나 deadlock 때문에 DB가 변경을 취소하는 경우도 같은 영향이 예상되지만, 이 두 경로는 소스만 확인했고 실행으로 검증하지 않았다.

### 왜 해결해야 하는가

데이터 보존은 rollback의 기본 요구사항이다. vacuum을 중단하면 불필요한 데이터의 공간 정리까지 멈춘다. 응용이 UPDATE나 모든 취소 상황을 피하는 것도 실용적인 우회책이 아니다.

2026-10-27 PR #7990 리뷰어는 이 결함을 머지 차단 사유로 지적했다. 당시 OOS는 미출시 기능이므로 고객 장애 보고는 없지만, 수정 없이 `develop`에 통합하면 개발과 QA에서도 같은 데이터 손실을 겪을 수 있다. CBRD-27089의 최종 검증도 이 수정에 의존한다.

## Test Build

- 원본 소스 분석 기준: PR #7990의 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`이다. 이번 문서는 이 분석을 쉽게 다시 설명하며, 최신 HEAD에서의 검증을 뜻하지 않는다.
- 리뷰어 SQL 재현: 엔진 `5a70787feea9e0488222af7e3a0249cc431562ca`의 debug 빌드다. 리뷰 대상 커밋은 `4408135c0`이다. OS와 상세 설정은 리뷰에 없다. 원본은 이 결함 관련 경로가 분석 기준 커밋까지 바뀌지 않았음을 확인했다.
- 이전 SERVER_MODE 단위 테스트: 2026-09-08, 기준 엔진 `b871ea386d2c5419b7abae07dda58b9b7f36377a`와 routing 변경 엔진, `debug_gcc` 구성이다.
- 원본 작성 시점의 버전 범위: 11.4 이하는 OOS가 없어 해당하지 않으며, OOS가 포함된 11.5는 미출시다.
- 이번 재작성에서는 테스트를 다시 실행하지 않았다.

## Repro

### 리뷰어가 보고한 SQL 재현

OOS를 지원하는 빌드의 **서버 모드**에서 실행한다. 아래는 리뷰어가 보고한 절차를 요약한 것이다. `'<random 30000>'`은 실제로 압축이 잘 되지 않는 30,000자 무작위 문자열로 바꿔야 한다. 같은 문자의 반복은 압축되어 OOS에 저장되지 않을 수 있다.

```sql
create table t(id int primary key, k int, big varchar(200000));
insert into t values(1, 1, '<random 30000>');
commit;
update t set k = 99 where id = 1;
rollback;
select length(big) from t; -- rollback 직후: 30000
-- 별도 테이블에 데이터를 넣고 commit해 로그를 충분히 쌓는다.
-- vacuum이 해당 UPDATE 로그를 처리한 뒤 다시 조회한다.
select length(big) from t; -- 보고된 결과: ERROR -1389
```

위 SQL만으로 vacuum 처리 시점까지 보장하지는 않는다. 무작위 문자열 생성, 추가 로그 생성, 실행 명령은 [보존된 상세 재현 문서](https://github.com/vimkim/my-cubrid-jira/blob/b89dc2bd34c15c312bddf9ee91e10a3b3738858c/issues/CBRD-27237-oos-forward-walk-rollback-delete_dcbf09e_claude.md#repro)에 있다. 그 문서의 실행 예는 제안이며 미실행이다. [리뷰어의 재현 보고](https://github.com/CUBRID/cubrid/pull/7990#discussion_r4385247867)와 구분한다.

이전 SERVER_MODE 단위 테스트는 A로 rollback한 뒤 다른 행의 공간이 실제로 회수될 때까지 기다려 vacuum 진행을 확인했다. 이후 A를 다시 읽어 실패를 검출했다. 테스트는 CBRD-27089 작업 커밋 `479cd960e`에 `DISABLED_` 상태로 보존되어 있고 PR #7990에는 포함되지 않았다.

## Expected Result

- UPDATE를 취소한 뒤에는 vacuum이 실행되어도 원래 값이 그대로 읽힌다. 위 SQL의 마지막 조회도 `30000`을 반환한다.
- 큰 컬럼 변경, 작은 컬럼만 변경, 큰 컬럼을 NULL로 변경한 경우 모두 같은 원칙을 지킨다.
- 명시적 ROLLBACK 외에 서버 장애 복구, 연결 끊김, deadlock에 따른 취소에서도 원래 값을 보존한다.
- commit된 UPDATE가 실제로 버린 옛 값은 계속 회수한다. 수정 때문에 쓰지 않는 OOS 공간이 계속 남아서는 안 된다.

## Actual Result

다음은 2026-10-27 리뷰어의 debug 빌드 실행 보고다. 이번 세션에서 재실행하지 않았다.

| 작업 | 취소 직후 | vacuum 처리 후 |
|---|---|---|
| 큰 컬럼 변경 후 ROLLBACK | 정상 | `-1389` |
| 작은 컬럼만 변경 후 ROLLBACK | 정상 | `-1389` |
| 큰 컬럼을 NULL로 변경 후 ROLLBACK | 정상 | `-1389` |
| DELETE 후 ROLLBACK, INSERT 후 ROLLBACK | 정상 | 정상 |
| UPDATE 후 commit | 정상 | 정상 |

미확정 UPDATE가 있는 서버를 `kill -9`로 종료하고 재기동한 경우에도, 복구로 변경을 취소한 뒤 vacuum이 실행되면 같은 오류가 났다고 보고했다. `-1389`는 OOS 참조가 실제 데이터와 맞지 않을 때 발생하는 `ER_HEAP_OOS_CORRUPTED_RECORD`다.

2026-09-08 단위 테스트에서도 rollback 직후에는 A를 읽었지만 vacuum 진행 확인 뒤 읽기가 실패했다. 기준 엔진 3회, routing 변경 엔진 2회 모두 실패했다. 이 테스트는 SQL과 서버 장애 복구를 다루지 않은 하위 heap/OOS 테스트다.

## Additional Information

- **상위와 범위**: 상위는 [CBRD-26583](https://jira.cubrid.org/browse/CBRD-26583)이다. 이 하위 작업은 취소한 UPDATE의 옛 OOS 값을 vacuum이 잘못 삭제하는 문제를 다룬다. 일반 UPDATE 로그(`RVHF_UPDATE_NOTIFY_VACUUM`)와, 행을 다른 위치로 옮겨 저장한 경우의 로그(`RVHF_DELETE_NEWHOME_NOTIFY_VACUUM`)가 대상이다.
- **확인이 남은 경로**: 연결 끊김, deadlock, 다른 위치로 옮겨 저장한 행은 소스 확인만 했다. savepoint 이후 일부 변경만 취소하고 나머지를 commit하는 경우는 소스 추론이며 재현이 필요하다. release 빌드의 증상도 확인이 필요하다.
- **CBRD-26950과 차이**: 그 이슈의 식별 표식 검사는 다른 데이터로 재사용된 공간을 잘못 지우는 것을 막는다. 여기서는 복원된 행과 로그가 똑같은 원래 값을 가리키므로 그 검사로 막을 수 없다.
- **CBRD-26668과 차이**: 기존 rollback 검토는 취소가 진행되는 동안 vacuum이 끼어들지 못함을 다뤘다. 여기서는 취소가 끝난 뒤 남아 있는 UPDATE 로그를 vacuum이 처리한다.
- **CBRD-27230과 관계**: 작은 컬럼만 바꿀 때 OOS 값을 다시 쓰지 않도록 하는 개선이다. 같은 체인을 재사용하게 되면 commit된 UPDATE에서도 그 체인을 잘못 지우지 않도록 정합성을 검토해야 한다. 이 결함이 그 개선으로 자동 해결된다고 가정하지 않는다.
- **CBRD-27781과 차이**: CBRD-27237은 아직 쓰는 값을 삭제 대상으로 잘못 판단한다. CBRD-27781은 삭제 자체는 정당하지만, 그 삭제를 되돌릴 공간을 다른 트랜잭션이 먼저 써서 복원에 실패한다.
- **상세 근거와 설계 후보**: [원본 분석 문서](https://github.com/vimkim/my-cubrid-jira/blob/b89dc2bd34c15c312bddf9ee91e10a3b3738858c/issues/CBRD-27237-oos-forward-walk-rollback-delete_dcbf09e_claude.md)에 함수별 근거, 이전 실험, 미확정 설계 후보를 보존한다. 후보의 선택은 ANALYSIS에서 결정한다.

## Triage Request

이 결함을 확인하고 OOS 담당인 작성자 측에 ANALYSIS 배정을 요청한다. 분석에서는 삭제해도 되는 값의 판단 기준을 정하고, 두 로그 경로와 아직 실행하지 않은 취소 경로를 검증한다. 부분 rollback의 영향과 CBRD-27230과의 정합성도 확인한다.

회귀 테스트는 서버 모드에서 **rollback 직후와 vacuum이 실제로 진행된 뒤**를 모두 확인해야 한다. 이미 보고된 세 UPDATE 시나리오와 서버 장애 복구를 포함하고, 단일 사용자 모드(SA_MODE)의 rollback 직후 검사만으로 완료를 판단하지 않는다. commit된 UPDATE의 불필요한 옛 값은 계속 회수되는지도 함께 검증한다.
