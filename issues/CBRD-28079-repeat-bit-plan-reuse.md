# [QUERY] REPEAT(비트 리터럴)을 대입하는 UPDATE가 XASL plan 재사용 시 다른 값을 저장하는 문제

**한 줄 요약**: 저장 구조 성능 비교(CBRD-28077) 중 발견한 develop 결함이다. `UPDATE ... SET b = REPEAT(X'D1', 100)`가 처음 compile될 때는 100바이트 `0xD1`을 저장하지만, 같은 문장의 XASL cache plan을 재사용하면 오류 없이 문자열 "d1"을 반복한 25바이트를 저장한다.

## Issue Triage

**이슈 수행 목적**: 같은 SQL이 plan을 새로 compile했는지, XASL cache에서 재사용했는지와 관계없이 같은 값을 저장하게 한다. 또 비트 리터럴을 인자로 받은 `REPEAT`의 결과 타입과 값을 하나로 정한다.

**이슈 수행 이유**: develop `a7f220d5d7`에서 같은 형태의 UPDATE를 세 번 실행하면 첫 번째는 800 bit, 두 번째와 세 번째는 200 bit 값을 저장한다. 같은 식을 SELECT 목록에 쓰면 1600 bit가 나온다. 같은 식이 실행 경로에 따라 세 가지 결과를 내며, 어느 경우에도 오류나 경고가 없다.

**영향**: 사용자가 같은 UPDATE를 반복 실행하면 첫 실행 뒤의 행에는 의도와 다른 값이 조용히 저장된다(데이터 무결성 문제). 여러 client가 같은 문장을 동시에 실행하면 어느 client가 plan을 먼저 compile했는지에 따라 결과 테이블 내용이 실행마다 달라진다. 실제로 CBRD-28077 벤치마크가 의도한 크기의 1/4인 값을 쓴 채 측정되어 1차 실행의 두 시나리오 결과를 정정해야 했다. 영향이 `REPEAT`와 비트 리터럴 조합에만 한정되는지, UPDATE 대입에만 한정되는지는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

`REPEAT(X'D1', 100)`처럼 비트 리터럴을 `REPEAT`에 넘기고 그 결과를 `BIT VARYING` 컬럼에 대입하는 UPDATE를 같은 세션에서 반복 실행했다. 문장 형태가 같으면 두 번째 실행부터는 XASL cache(서버가 compile한 실행 계획을 재사용하는 cache)의 plan을 쓴다. 이때 저장되는 값이 첫 실행과 다르다.

- 첫 실행(새로 compile): 100바이트, 모든 바이트가 `0xD1`. 비트 컬럼 사용자가 기대하는 값이다.
- plan 재사용: 25바이트, 내용은 ASCII 문자열 `d1d1...`(`0x64 0x31` 반복).
- SELECT 목록: `select bit_length(REPEAT(X'D1', 100)) from db_root`는 1600을 반환하고, hex 값은 `6431...`이다. 비트 리터럴을 문자열 "d1"로 보고 100번 반복한 200바이트다.

즉 같은 식이 800 bit, 200 bit, 1600 bit의 세 가지 결과를 낸다. 어느 쪽이 정의된 동작인지도 정해야 한다. 첫 실행 결과가 비트 컬럼 사용자의 기대와 맞지만, SELECT 결과는 `REPEAT`가 비트 리터럴을 문자열로 해석함을 보여준다.

### Test Build

- CUBRID develop `a7f220d5d7` (CUBRID/cubrid)
- `release_gcc` CMake preset (GCC 11.5, RelWithDebInfo). GCC 11의 `src/optimizer/query_planner.c` 경고를 통과하려고 `-Wno-error=return-local-addr`만 추가했다.
- CS 모드, `ha_mode=off`, `stored_procedure=no`

### Repro

새 DB를 만들고 서버를 시작한 뒤, 하나의 csql 세션에서 다음을 실행한다.

```bash
cubrid createdb --db-volume-size=128M --log-volume-size=64M rbdb en_US.utf8
cubrid server start rbdb
csql -u dba rbdb
```

```sql
create table rb (id int primary key, b bit varying);
insert into rb select rownum, REPEAT(X'AB', 100) from db_class limit 4;
update rb set b = REPEAT(X'D1', 100) where id = 1;
update rb set b = REPEAT(X'D1', 100) where id = 2;
update rb set b = REPEAT(X'D1', 100) where id = 3;
select id, bit_length(b), substring(hex(b) from 1 for 12) from rb order by id;
select bit_length(REPEAT(X'D1', 100)), substring(hex(REPEAT(X'D1', 100)) from 1 for 12) from db_root;
```

위 SQL과 같은 내용을 실행한 스크립트: [repeat_bit_probe.py](https://github.com/vimkim/my-cubrid-docs/blob/69ca1c5/CBRD-28077/tools/repeat_bit_probe.py). `createdb` 옵션은 제안이며, 관찰은 벤치마크 harness가 만든 새 DB에서 했다.

### Expected Result

id 1, 2, 3 모두 같은 값을 저장한다. 비트 컬럼 기준으로는 800 bit, hex `D1D1D1...`이 기대값이다. 최소한 첫 실행과 plan 재사용 실행의 결과가 같아야 한다.

### Actual Result

```
id  bit_length(b)  substring(hex(b) from 1 for 12)
1   800            'D1D1D1D1D1D1'   <- 첫 실행: 100바이트 0xD1
2   200            '643164316431'   <- 같은 형태, plan 재사용: ASCII "d1d1..." 25바이트
3   200            '643164316431'
4   800            'ABABABABABAB'
```

SELECT 목록의 `REPEAT(X'D1', 100)`은 1600 bit, hex `643164316431...`이다.

### Additional Information

**재현되지 않은 경우** (같은 빌드):

- UPDATE에서 `CAST(REPEAT(X'E1', 100) AS BIT VARYING)`를 대입: 두 번 실행 모두 800 bit.
- `update ... set b = (select b from vals where tag = 'B1')` 처럼 scalar subquery로 대입: 재현되지 않음.
- `update /*+ RECOMPILE */ ...`: 매번 새로 compile하므로 800 bit.
- `insert into vals select x.tag, CAST(REPEAT(x.tag, 100) AS BIT VARYING) from (...) x`: 800 bit.

**동시 실행에서의 결과**: 8개 csql client가 각각 `update t set big = REPEAT(X'D1', 100) where id = ?; commit;`을 250번 실행했다. 문장을 직접 compile한 client의 첫 UPDATE만 800 bit를 저장했고 나머지 UPDATE는 모두 200 bit를 저장했다. 먼저 compile한 client 수는 timing에 따라 8개 중 3개 또는 4개였고, 그래서 같은 실행 두 번이 서로 다른 테이블 내용으로 끝났다. develop과 Sidecar POC 빌드 모두에서 같은 현상을 보았으므로 POC 결함이 아니다. 스크립트: [concurrent_len_probe.py](https://github.com/vimkim/my-cubrid-docs/blob/69ca1c5/CBRD-28077/tools/concurrent_len_probe.py)

**발견 경위**: CBRD-28077 2차 실행에서 Sidecar 빌드의 100 B 테이블 checksum이 다른 빌드와 600 bit 달랐다. 원인을 추적하다가 이 결함을 찾았다. 1차 실행의 두 시나리오는 의도한 크기의 1/4 값으로 측정되어 결과를 정정했고, 3차 실행은 모든 값을 `CAST(... AS BIT VARYING)`으로 만들어 이 결함을 피했다. 경위: [run3-report.md 6.4절](https://github.com/vimkim/my-cubrid-docs/blob/69ca1c5/CBRD-28077/run3-report.md)

**확인하지 않은 범위**: develop `a7f220d5d7` 외의 버전(11.x release 등)은 확인하지 않았다. 원인 코드도 분석하지 않았다.

**관련 이슈**:

- CBRD-28077: 이 결함을 발견한 저장 구조 성능 비교 이슈.
- CBRD-27868: XASL cache 재사용으로 틀린 결과가 나오는 다른 사례다. 그 이슈는 MONETARY 리터럴이 다른 두 질의가 같은 cache key로 출력되어 생긴다. 이 이슈는 같은 문장(조건 값만 다름)의 plan 재사용에서 대입 값 자체가 달라지므로 원인이 다를 수 있다.
- CBRD-27583: 타입 결정을 컴파일로 옮기고 XASL을 바인드 타입 서명마다 두게 한 변경(Resolved). 이 결함과의 관계는 확인하지 않았다.

### ANALYSIS 확인 사항

- 비트 리터럴을 인자로 받은 `REPEAT`의 정의된 결과는 무엇인가(비트 반복 800 bit, 또는 문자열 반복 1600 bit). 매뉴얼과 다른 문자열 함수(`CONCAT`, `LPAD` 등)의 비트 인자 처리와 일관되는가.
- 첫 compile과 plan 재사용 사이에서 무엇이 달라지는가(대입 대상 컬럼 타입으로의 변환, 상수 folding, XASL에 저장되는 결과 도메인 등).
- 같은 차이가 `REPEAT` 외의 함수, 비트 외의 타입, UPDATE 외의 문장(INSERT VALUES, MERGE 등)에서도 생기는가.
