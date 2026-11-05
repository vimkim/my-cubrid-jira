# [Utility] `cubrid diagdb -d 8`이 표준 입력이 EOF이면 프롬프트를 무한 반복하며 출력을 쌓는다

**한 줄 요약**: CBRD-27937 검증 중 `cubrid diagdb -d 8`을 표준 입력을 `/dev/null`로 두고 실행했더니 종료하지 않고 출력 파일을 약 80GB까지 키웠으며, 로그 덤프 인자를 묻는 프롬프트 루프(`util_sa.c`)가 `scanf`의 EOF와 입력 실패를 검사하지 않는 것이 원인으로 보여 이를 입력이 끝나거나 읽을 수 없으면 멈추도록 고친다.

## Issue Triage

**이슈 수행 목적**: `cubrid diagdb`의 로그 덤프가 대화형으로 인자를 물을 때 표준 입력이 EOF이거나 읽을 수 없으면 오류를 내고 종료하여, 입력이 없는 환경에서 무한 반복과 디스크 소진이 일어나지 않게 한다.

**이슈 수행 이유**: `diagdb`는 `-d 8`(로그 덤프)이나 `-d -1`(기본값, 전체 덤프)에서 인자가 주어지지 않으면 `isforward`, `start_logpageid`, `dump_npages`, `desired_tranid`를 `scanf`로 묻고, 마지막에 `y/n`을 묻는다. 이 루프는 `scanf`의 반환값을 보지 않고 `y`가 입력될 때까지 `do-while`로 반복한다. develop `e64a04a79` debug 빌드에서 표준 입력을 `/dev/null`로 둔 실행이 끝나지 않고 출력 파일을 80GB까지 쓴 뒤 timeout으로 종료되었다. 이 실행은 한 번 관찰했다.

**영향**: `diagdb`를 스크립트, QA 자동화, 에이전트처럼 입력이 없는 환경에서 실행하는 사람이 터미널 없이 `-d 8`이나 기본 `-d`를 쓰면 프로세스가 끝나지 않고 출력이 디스크를 채운다. 관찰한 실행에서는 한 번에 약 80GB가 쓰였다. 인자를 5개 모두 주는 비대화형 형식이 있으나 `diagdb`의 usage 메시지에는 나오지 않는다. 운영 환경에서의 사용 빈도와 피해는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 관찰은 CBRD-27937 검증 중 한 번 얻었고, 아래 코드 위치는 develop `e64a04a79a5842827a124b3f8313516d0da2594c`를 읽어 확인했다. 이 이슈를 쓰며 다시 실행하지 않았다.

## Description

### 관찰

CBRD-27937 검증에서 develop `e64a04a79` debug 빌드로 `cubrid diagdb -d 8 <db>`를 표준 입력을 `/dev/null`로 두고 실행했다. 프로세스가 끝나지 않고 출력 파일을 약 80GB까지 쓰다가 timeout으로 종료되었다. 같은 명령을 질문에 대한 답을 담은 파일을 표준 입력으로 주고 다시 실행했을 때는 정상 종료했다. 한 번의 관찰이며 반복 실행으로 확인하지 않았다. 커진 파일이 표준 출력을 받은 파일이었는지 `-o`로 지정한 파일이었는지는 이 이슈에 근거가 없다. 코드에서 프롬프트는 `printf`로 표준 출력에 쓰인다.

### 프롬프트 루프

`diagdb`는 [`DIAGDUMP_LOG` 분기](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/executables/util_sa.c#L1891-L1954)에서 로그를 덤프한다. 덤프 유형 `-d`의 기본값은 `-1`(전체 덤프)이므로 [옵션 정의](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/executables/util_admin.c#L324) `-d`를 주지 않은 `cubrid diagdb <db>`도 이 분기에 온다. 조건이 `diag == DIAGDUMP_ALL` 이거나 데이터베이스 이름 외에 인자가 없으면 [대화형 루프](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/executables/util_sa.c#L1898-L1918)로 들어간다.

```c
char yn[2];
do
  {
    printf ("\n");
    printf ("isforward (1 or 0) ? ");
    scanf ("%d", &isforward);
    ...
    printf ("log_dump(%d, %lld, %d, %d) (y/n) ? ", ...);
    scanf ("%1s", yn);
  }
while (yn[0] != 'y');
```

- `scanf`의 반환값을 모두 무시한다. 표준 입력이 EOF이면 `scanf`는 EOF를 돌려주고 변수를 바꾸지 않는다.
- `yn`은 초기화하지 않은 `char yn[2]`이다. EOF에서는 `yn[0]`이 쓰이지 않은 스택 값이므로 `'y'`일 때만 루프가 끝난다. 관찰에서는 끝나지 않았다.
- `isforward`, `dump_npages`, `desired_tranid`와 `s`도 초기화하지 않아 `y`가 우연히 들어가면 초기화되지 않은 값으로 `xlog_dump`를 호출한다.
- 한 번 반복마다 빈 줄 하나와 프롬프트 다섯 개가 표준 출력에 쓰인다. 종료 조건이 없으므로 표준 출력이 파일이면 그 파일이 계속 커진다.

인자를 모두 주는 경로는 문제가 없다. [`utility_get_option_string_table_size (arg_map) == 5`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/executables/util_sa.c#L1919-L1947)이면 데이터베이스 이름 뒤의 네 인자(`isforward`, `start_logpageid`, `dump_npages`, `desired_tranid`)를 프롬프트 없이 읽어 `xlog_dump`를 호출한다. [diagdb의 usage 메시지](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/msg/en_US.utf8/utils.msg#L842-L858)에는 이 형식이 설명되어 있지 않다.

같은 저장소에는 입력이 끝났을 때 멈추는 선례가 있다. 로그 아카이브를 묻는 프롬프트는 `fgets`가 NULL이면 종료로 처리하고([log_page_buffer.c:5779-5782](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_page_buffer.c#L5779-L5782)), flashback의 페이징 프롬프트는 `EOF`에서 출력을 멈춘다([flashback_cl.c:303-307](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/flashback_cl.c#L303-L307)).

## Test Build

- CUBRID `develop` `e64a04a79a5842827a124b3f8313516d0da2594c`, Linux 64bit debug 빌드 (관찰한 환경)
- 코드 위치는 같은 커밋의 소스에서 읽었다. 해당 코드에 빌드 종류에 따른 조건은 없다. release 빌드와 다른 릴리스 브랜치는 시험하지 않았다.

## Repro

아래는 이 이슈를 쓰며 실행하지 않은 제안이다. 데이터베이스가 실행 중이 아닌 상태에서 `diagdb`를 쓴다. 출력은 `head -c`로 1MiB에서 끊고, `timeout`으로 20초에서 끊는다.

```bash
cubrid createdb --db-volume-size=64M --log-volume-size=64M diagdbeof en_US.utf8
timeout 20 cubrid diagdb -d 8 diagdbeof < /dev/null | head -c 1048576 > diagdb-eof.out
echo "exit statuses: ${PIPESTATUS[*]}"
wc -c diagdb-eof.out
grep -c 'isforward' diagdb-eof.out
```

정리는 `cubrid deletedb diagdbeof`로 한다.

## Expected Result

표준 입력이 EOF이거나 숫자를 읽을 수 없으면 오류 메시지를 내고 0이 아닌 상태로 즉시 종료한다. 프롬프트는 반복되지 않고, 초기화되지 않은 값으로 `xlog_dump`가 호출되지 않는다.

## Actual Result

CBRD-27937 검증의 관찰에서는 종료하지 않고 출력 파일이 약 80GB가 될 때까지 반복하다가 timeout으로 종료되었다. 위 제안 명령에서 같은 동작이면 `head -c`가 1MiB에서 끊고 `diagdb-eof.out`이 1048576바이트이며 `isforward`를 포함한 줄이 여러 개 나온다.

## Additional Information

- 관련 이슈: [CBRD-27937](http://jira.cubrid.org/browse/CBRD-27937) 검증 중에 발견했다. 원인은 서로 다르다.
- ANALYSIS에서 확인할 사항:
  1. 위 재현 명령이 같은 동작을 보이는지, release 빌드에서도 같은지.
  2. 같은 파일의 다른 확인 프롬프트(`synccolldb`의 계속 여부 확인: [util_sa.c:3086](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/executables/util_sa.c#L3086))도 `scanf`의 반환값을 검사하지 않고 초기화하지 않은 `yn`을 읽는다. 이 경우는 반복하지 않고 취소로 끝나는지 확인한다.
  3. 인자 5개 비대화형 형식을 usage 메시지와 매뉴얼에 설명할지 여부.
