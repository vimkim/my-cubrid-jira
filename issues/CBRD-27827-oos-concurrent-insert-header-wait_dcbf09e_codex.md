# [OOS] 동시 INSERT 중 파일 헤더 경합으로 INSERT가 실패하거나 서버가 종료된다

## Issue Triage

**이슈 수행 목적**: 같은 테이블에 여러 세션이 OOS 값을 저장할 때, 정상적인 파일 헤더 경합만으로 INSERT가 실패하거나 서버가 종료되지 않게 한다.

**이슈 수행 이유**: OOS 후보 페이지 검색이 함수 전체를 강제 무대기 상태로 바꿔, 후보 페이지의 소유 확인에 필요한 파일 헤더 읽기까지 기다리지 못하게 한다. 다른 세션의 새 페이지 할당과 겹치면 소유 확인이 오류 설정 없이 실패한다. PR 7990의 hornetmj 리뷰에서 보고됐으며, 동일 기준 소스의 debug 빌드에서 같은 assertion으로 독립 재현했다.

**영향**: 직접 확인한 debug 실행은 동시 INSERT 첫 회차에 서버가 종료되고 모든 클라이언트가 서버 실패 오류를 반환했다. 리뷰어는 release에서 INSERT 실패도 보고했다. release 결과와 운영 발생 빈도는 이번 작업에서 독립 검증하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 소스와 직접 실행한 결과를 바탕으로 작성했다. 리뷰어의 관찰과 미검증 범위를 구분한다.

## Description

### 무엇이 문제인가

OOS는 큰 컬럼 값을 별도 파일에 저장하고 행에는 그 위치를 남긴다. 새 값을 넣을 때는 기존 OOS 페이지의 빈 공간을 먼저 찾고, 공간이 부족하면 새 페이지를 할당한다. 여러 세션이 같은 테이블에 값을 넣으면 이 두 작업이 동시에 실행될 수 있다.

`oos_stats_find_page_in_bestspace`는 후보 페이지를 찾는 동안 `LK_FORCE_ZERO_WAIT`를 설정한다. 후보 페이지는 이미 명시적인 조건부 래치로 접근하므로, 바쁘면 기다리지 않고 다른 후보를 찾을 수 있다. 문제는 후보를 잡은 뒤 소유권을 확인하는 `file_is_vpid_in_file`에도 같은 무대기 설정이 적용된다는 점이다. 이 함수의 파일 헤더 읽기는 원래 대기하는 요청이지만 버퍼 관리자가 이를 조건부 요청으로 바꾼다. 다른 세션이 새 페이지 할당을 위해 파일 헤더를 쓰고 있으면 읽기가 오류 설정 없이 실패할 수 있다.

분석 기준은 PR 7990의 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`이다. [OOS의 대기 설정과 후보 접근](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/oos_file.cpp#L560-L706), [버퍼 관리자의 조건부 전환](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/page_buffer.c#L2247-L2255), [파일 헤더 읽기 실패와 assertion](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/file_manager.c#L6906-L6926).

### 왜 문제인가

사용자는 서로 다른 행을 같은 테이블에 동시에 저장할 수 있어야 한다. 파일의 새 페이지를 준비하는 동안 생기는 내부 경합은 이 작업에서 가능한 정상 상태다. 그런데 현재 구현은 이 경합을 INSERT 실패로 바꾼다. debug 빌드에서는 오류가 있어야 한다는 내부 검사도 실패해 서버가 종료되므로 다른 세션의 작업도 중단된다.

직접 실행한 8세션 부하에서 `file_manager.c:6924`의 동일한 assertion을 관찰했다. 10회 반복을 요청했지만 첫 회차에서 중단됐으므로, 이를 10회 장애로 세지 않는다. [리뷰 원문](https://github.com/CUBRID/cubrid/pull/7990#discussion_r4398825716)은 release의 INSERT 실패도 보고한다. 이번 작업은 release에서 이를 다시 실행하지 않았다.

### 왜 해결해야 하는가

OOS 도입 PR의 검증에서 기본적인 동시 저장이 서버 중단으로 이어지는 상태다. 클라이언트에서 INSERT를 다시 시도하더라도 서버 종료와 다른 세션의 중단을 막을 수 없다. 정상적인 경합을 견디는 결과가 필요하며, 오류 코드만 추가하면 INSERT 실패 자체는 남는다.

기존 CBRD-27183은 같은 트랜잭션의 병렬 스레드 사이에서 전역 대기 설정이 오염되는 문제다. 이 결함은 후보를 찾는 스레드 자신의 파일 헤더 읽기에도 무대기를 적용하므로, 스레드 사이의 설정 오염이 없어도 발생한다. CBRD-27356의 공통 page latch 정책 개선과 관련되지만, 이번 범위는 OOS 검색의 구체적인 동시 INSERT 실패를 독립적으로 수정·검증하는 것이다. 2026-10-29 JIRA의 OOS 이슈 110개 및 두 식별자 검색 결과 7개를 검토한 범위에서 같은 OOS 결함의 별도 티켓은 찾지 못했다.

## Test Build

- CUBRID 소스는 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`이다. 재현을 위한 Python 스크립트 외 엔진 수정과 계측은 없다.
- CUBRID `11.5.0.2781`, 64-bit debug, GCC 11.5.0, Linux `5.14.0-570.30.1.el9_6.x86_64`에서 실행했다.
- 기본 16KB 페이지를 쓰는 별도 CS 서버에서 passwordless DBA로 접속했다. standalone 모드로는 여러 세션의 이 경합을 검증할 수 없다.
- 입력은 같은 새 테이블에 8세션이 각각 1,500행을 넣는 것이다. payload는 세션별 고정 seed로 만든 6,000자 값이며 열에 `STORAGE FORCE_OUTLINE`을 지정했다. 각 INSERT는 autocommit이다.
- release와 DELETE·vacuum 혼합 부하는 직접 실행하지 않았다. OOS가 없는 출시 버전이 이 결함의 영향을 받는다고 주장하지 않는다.

## Repro

1. 분석 기준 소스를 독립 checkout에서 debug로 빌드·설치한다. 빌드 의존성은 프로젝트의 `docs/install_build_requirements.md`를 따른다. `CUBRID`는 별도 설치 경로로, `CUBRID_DATABASES`는 별도 registry 경로로 설정한다. `$CUBRID/bin`을 PATH에, `$CUBRID/lib`를 라이브러리 경로에 추가하고 다른 인스턴스와 겹치지 않는 master port를 사용한다.

```sh
cmake --preset debug -DUNIT_TEST_OOS=ON
cmake --build build_preset_debug
cmake --install build_preset_debug
```

2. 업무 DB와 다른 새 테스트 DB를 만들고 CS 서버를 시작한다. 아래 DB 이름이 이미 있으면 새 이름을 선택한다. 기존 DB를 삭제하거나 대체하지 않는다.

```sh
cubrid createdb oosr1 en_US.utf8
cubrid server start oosr1
```

3. 아래의 재현 스크립트를 `test_oos_concurrent_insert.py`로 저장하고 새 출력 디렉터리를 지정해 실행한다. 스크립트는 테이블과 입력·출력·JSON 결과를 보존하며 DB나 서버의 생성·삭제를 수행하지 않는다.

```sh
python3 test_oos_concurrent_insert.py oosr1 ./oos-r1-output --rounds 10 --timeout 120
```

4. 서버 assertion과 클라이언트 오류를 확인한다. 경합 시점에 의존하므로 매 실행에서 같은 스케줄을 보장하지 않는다. 한 회차의 제한 시간은 생성·INSERT·조회 검증을 포함한 120초다.

### 재현 스크립트

아래 스크립트는 실제 수정 전후 검증에 사용한 내용이다.

```python
#!/usr/bin/env python3
# Copyright 2016 CUBRID Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Run against a running CS database: python3 test_oos_concurrent_insert.py DB OUTPUT_DIR.

Requires csql on PATH and DBA access with no password. Retains tables and all artifacts.
The timeout covers each round, including setup, concurrent inserts, and validation.
"""
import argparse
import concurrent.futures
import json
import random
import re
import subprocess
import threading
import time
import uuid
from pathlib import Path


def positive(value):
    value = int(value)
    if value < 1:
        raise argparse.ArgumentTypeError('must be positive')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('database')
    parser.add_argument('output_dir', type=Path)
    parser.add_argument('--sessions', type=positive, default=8)
    parser.add_argument('--rows', type=positive, default=1500)
    parser.add_argument('--rounds', type=positive, default=1)
    parser.add_argument('--timeout', type=positive, default=120)
    args = parser.parse_args()
    if args.sessions * args.rows > 2147483647:
        parser.error('sessions * rows exceeds INT range')
    args.output_dir.mkdir(parents=True, exist_ok=False)
    run_id = uuid.uuid4().hex[:16]
    summary = {'database': args.database, 'run_id': run_id, 'rounds': [], 'status': 'running'}
    command = ['csql', '-C', '-u', 'dba', '--line-output', '--no-pager', args.database]

    def client(name, sql, deadline, barrier=None):
        sql_path = args.output_dir / (name + '.sql')
        out_path = args.output_dir / (name + '.out')
        err_path = args.output_dir / (name + '.err')
        sql_path.write_text(sql)
        with sql_path.open('rb') as source, out_path.open('wb') as out, err_path.open('wb') as err:
            if barrier:
                barrier.wait(timeout=max(0.01, deadline - time.monotonic()))
            process = subprocess.Popen(command, stdin=source, stdout=out, stderr=err)
            try:
                code = process.wait(timeout=max(0.01, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                raise RuntimeError(name + ' timed out')
        output = out_path.read_text(errors='replace') + err_path.read_text(errors='replace')
        if code != 0 or re.search(r'\bERROR\b', output, re.IGNORECASE):
            raise RuntimeError(f'{name} failed (exit {code}); see logs')
        return output

    try:
        for round_no in range(args.rounds):
            deadline = time.monotonic() + args.timeout
            table = f'oos_concurrent_{run_id}_{round_no}'
            result = {'table': table, 'sessions': [], 'status': 'running'}
            summary['rounds'].append(result)
            client(f'r{round_no}_create', f'CREATE TABLE {table} (id INT PRIMARY KEY, '
                   'payload VARCHAR(6000) STORAGE FORCE_OUTLINE);\n', deadline)
            for session in range(args.sessions):
                start = session * args.rows
                rng = random.Random(session)
                payload = bytes(rng.getrandbits(8) for _ in range(3000)).hex()
                result['sessions'].append({'id_start': start, 'id_end': start + args.rows - 1,
                                           'name': f'r{round_no}_s{session}', 'payload': payload})
            barrier = threading.Barrier(args.sessions)
            def run_session(session):
                sql = ''.join(f"INSERT INTO {table} VALUES ({row}, '{session['payload']}');\n"
                              for row in range(session['id_start'], session['id_end'] + 1))
                client(session['name'], sql, deadline, barrier)
            with concurrent.futures.ThreadPoolExecutor(max_workers=args.sessions) as pool:
                futures = [pool.submit(run_session, session) for session in result['sessions']]
                for future in futures:
                    future.result()
            matches = ' OR '.join(f"(id BETWEEN {s['id_start']} AND {s['id_end']} "
                                  f"AND payload = '{s['payload']}')" for s in result['sessions'])
            sql = (f'SELECT COUNT(*) AS total_rows, SUM(CASE WHEN {matches} THEN 1 ELSE 0 END) '
                   f'AS matching_rows FROM {table};\nSHOW HEAP OOS OF {table};\n')
            output = client(f'r{round_no}_verify', sql, deadline)
            def field(name):
                values = re.findall(rf'^\s*(?:<\d+>\s*)?{name}\s*:\s*(\d+)\s*$', output, re.I | re.M)
                if len(values) != 1:
                    raise RuntimeError(f'expected one {name} in verification output, got {values}')
                return int(values[0])
            total, matching, chunks = field('total_rows'), field('matching_rows'), field('Oos_num_recs')
            result.update(total_rows=total, matching_rows=matching, oos_num_recs=chunks)
            if total != args.sessions * args.rows or matching != total or chunks <= 0:
                raise RuntimeError(f'{table}: wrong row count, payload, or OOS record count')
            result['status'] = 'passed'
        summary['status'] = 'passed'
    except Exception as exc:
        summary['status'] = 'failed'
        summary['error'] = str(exc)
    finally:
        (args.output_dir / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({'status': summary['status'], 'output_dir': str(args.output_dir),
                      'error': summary.get('error')}))
    return 0 if summary['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
```

## Expected Result

정상적인 파일 헤더 경합이 풀리면 저장을 계속한다. 모든 INSERT가 완료되고 행 수와 payload가 일치해야 한다. `SHOW HEAP OOS`로 실제 OOS 저장도 확인한다. 바쁜 후보 데이터 페이지를 기다리지 않고 건너뛰는 정책은 유지한다.

## Actual Result

수정 전 첫 회차에 서버가 다음 assertion으로 종료했다.

```text
file_manager.c:6924: DISK_ISVALID file_is_vpid_in_file(THREAD_ENTRY*, const VFID*, const VPID*): Assertion `er_errid () != NO_ERROR' failed.
ERROR: Your transaction has been aborted by the system due to server failure or mode change.
```

클라이언트가 exit 1을 반환해 스크립트의 결과도 `failed`였다. master가 서버를 다시 시작했지만, 재현 회차의 클라이언트 작업은 성공하지 못했다.

## Additional Information

- 함수 전체의 강제 무대기 설정·복원을 제거하는 7줄 삭제 후보를 로컬에서 검증했다. 후보 페이지의 조건부 래치와 함수 시그니처는 유지했다. 이는 팀 리뷰 전 후보이며 공통 latch 정책의 최종 설계가 아니다.
- 수정 후 같은 입력을 새 테이블로 10회 실행했다. 총 120,000행의 개수와 payload가 일치했고 회차별 OOS 레코드는 12,000개였다. 클라이언트 오류와 서버 assertion은 관찰하지 않았다.
- 기존 `test_oos_bestspace` 23개, `test_oos_growth_sweep` 11개와 setup·cleanup을 포함한 CTest 4개가 통과했다. 첫 CTest 시도는 configure 시점의 빈 DB registry 경로 때문에 fixture가 실패했으며, 초기화된 환경에서 재구성한 뒤 통과했다.
- 관련 원본은 [PR 7990](https://github.com/CUBRID/cubrid/pull/7990), [CBRD-27183](https://jira.cubrid.org/browse/CBRD-27183), [CBRD-27356](https://jira.cubrid.org/browse/CBRD-27356)이다.

## Triage Request

동시 INSERT의 오류와 서버 중단을 확인하고 OOS 담당 작성자 측의 ANALYSIS 배정을 요청한다. 로컬 후보의 래치 순서와 호출자의 원래 zero-wait 정책을 검토하고, 필요한 release 및 DELETE·vacuum 혼합 검증 범위를 결정한다. 독립 회사 PR의 리뷰와 CI를 받은 뒤 반영한다.
