# [CBRD-27443] 서버 시작 명령이 끝나도 출력을 받는 도구가 계속 기다림

## Issue Triage

**이슈 수행 목적**: DB 서버를 시작한 뒤, 시작을 요청한 도구가 결과를 받고 다음 작업으로 넘어갈 수 있도록 한다. DB 서버는 계속 실행되어야 한다.

**이슈 수행 이유**: `cubrid server start testdb | cat`을 실행하면 시작 명령이 종료한 뒤에도 `cat`이 끝나지 않을 수 있다. 시작 명령이 만든 서버나 관리 프로세스가 같은 출력 통로를 계속 열어 두기 때문이다.

**영향**: 사람이 보기에는 명령이 멈춘 것처럼 보인다. 자동화 도구나 AI agent는 시작 작업이 끝나기를 기다리느라 다음 SQL 시험이나 정리 작업을 실행하지 못한다. 호출 도구가 사용한 파일 잠금도 서버에 남아 후속 작업을 막을 수 있다.

**이슈 수행 방안**: 백그라운드 프로세스가 불필요하게 물려받은 출력 통로와 파일 연결을 놓도록 한다. 시작 성공·실패 결과와 오류 진단은 보존한다. 서버뿐 아니라 master와 재시작 경로도 포함한다. 로그를 보낼 위치, 초기 오류 전달 방식, 터미널에서 계속 실행하는 모드의 예외 및 적용 API는 `TBD - 합의 미확인`이다.

---

## AI-Generated Context

> 아래는 AI가 코드와 실행 결과를 분석해 작성한 상세 자료다.

## Description

### 어떤 문제가 생기는가

`cubrid server start testdb`는 DB 서버를 시작시키는 명령이다. 이 명령 자체가 DB 서버는 아니다. 시작 명령은 결과를 알리고 종료하지만, 실제 DB 서버는 뒤에서 계속 실행되며 SQL 요청을 처리한다.

사용자는 보통 약 3초면 끝나던 시작 호출이 1분 넘게 반환되지 않는 경험을 보고했다. 이 이슈에서 확인한 것은 그중 **시작 명령은 이미 끝났는데, 출력을 받는 쪽이 계속 기다리는 경우**다. 복구 작업 등으로 시작 명령 자체가 오래 걸리는 경우와는 구분한다.

대표적인 재현 명령은 다음과 같다.

```bash
cubrid server start testdb | cat
```

`|`는 왼쪽 명령의 출력을 오른쪽 프로그램의 입력으로 전달하는 통로, 즉 파이프를 만든다. `cat`은 전달받은 내용을 화면에 출력하고, 입력이 끝나면 종료한다. 기대하는 동작은 시작 결과가 출력된 뒤 셸 프롬프트가 돌아오는 것이다. 하지만 이 문제가 발생하면 시작 명령이 끝난 뒤에도 `cat`이 기다리므로 프롬프트가 돌아오지 않는다.

### 시작 명령이 끝났는데 왜 cat이 기다리는가

출력이 잠시 없는 것과 앞으로 더 이상 출력이 올 수 없는 것은 다르다. `cat`은 조용하다는 이유만으로 종료할 수 없다. 운영체제가 **입력의 끝(EOF, End of File)**을 알려줄 때까지 기다린다.

프로그램은 열린 파일이나 통신 통로를 FD(파일 디스크립터)라는 번호로 사용한다. 부모 프로세스가 `fork()`로 자식 프로세스를 만들면 자식도 같은 통로를 사용하는 FD를 물려받는다. 부모가 자신의 FD를 닫아도 자식의 연결은 남는다.

```text
시작 명령 ── 쓰기 연결 ──┐
                        ├── 출력 파이프 ──→ cat
DB 서버   ── 쓰기 연결 ──┘

시작 명령 종료: 위쪽 연결만 닫힘
서버에 연결이 남음: cat은 입력의 끝을 받지 못함
```

파이프의 쓰기 연결이 모두 닫히고 남은 데이터도 다 읽었을 때, 커널은 `cat`의 읽기 요청에 0을 반환한다. 이것이 EOF다. 서버가 로그를 계속 찍어야만 문제가 생기는 것은 아니다. **아무것도 출력하지 않아도 연결을 열어 두면 기다림이 계속된다.** [pipe(7)](https://man7.org/linux/man-pages/man7/pipe.7.html)

### 무엇을 바꾸려는가

서버가 호출자의 불필요한 출력 연결을 놓으면, 서버가 계속 살아 있어도 `cat`은 종료할 수 있다. 실제 제품에서는 서버의 이후 로그를 적절한 대상으로 보내고, 시작을 요청한 쪽에는 성공·실패 결과와 필요한 오류 정보를 전달해야 한다.

| 현재 | 수정 목표 |
|---|---|
| 시작 명령은 종료했지만 서버 등에 출력 연결이 남아 `cat`이 기다림 | 시작 결과를 받은 `cat`이 종료하고 서버는 계속 실행됨 |
| 호출 도구의 파일 잠금도 서버에 남아 다음 작업을 막을 수 있음 | 호출 도구가 작업을 끝내면 잠금을 해제할 수 있음 |
| 서버를 재시작할 때 불필요한 연결이 다시 전달될 수 있음 | 최초 시작과 재시작 모두 같은 정리 규칙을 적용함 |

CUBRID에는 DB 서버 외에 서버 등록·연결을 관리하는 `master`와 저장 프로시저를 실행하는 `PL` 프로세스도 있다. 이들 중 하나라도 같은 출력 연결을 보유하면 기다림이 남을 수 있으므로 함께 수정 범위에 둔다. 단순히 DB 서버 하나의 연결만 닫는 것으로 충분한지는 전체 보유자를 확인해야 한다.

## Test Build

| 근거 | 빌드 및 조건 |
|---|---|
| 소스 재검토 | develop `c63a3b993be552ef6ad3ce244c386d5081147958` |
| 댓글 작성자의 실측 | 위 develop/debug에서 일반 시작·파이프·single-node HA. 이 문서 작성자가 해당 빌드를 재실행한 결과는 아니다. |
| 2026-10-01 독립 실측 | Linux, `11.5.0.2602-a0026f9`, 64bit debug. 별도 PID·network·mount·user namespace와 전용 설정·DB 목록·로그를 사용했다. |

독립 실측 빌드와 소스 재검토 커밋의 생성 경로 7개 파일을 대조했다. 차이는 `util_service.c`의 관리 명령 목록에 `upgradedb`를 추가한 한 줄이며 해당 FD 처리 코드는 같다. 엔진 전체의 동일성을 주장하거나 이를 `c63a3b993` 재빌드 시험으로 표기하지 않는다.

## Repro

### 한 줄로 증상을 확인한다

CUBRID가 설치된 Linux 테스트 환경에서, 이미 생성되어 있고 현재는 중지된 `testdb`를 사용한다. 실행 중인 DB에 start를 다시 요청하면 새 서버를 만드는 경로를 확인하지 못하므로 이 조건을 맞춘다.

```bash
cubrid server start testdb | cat
```

시작 결과가 출력된 뒤에도 셸 프롬프트가 돌아오지 않는지 본다. 평소 약 3초면 끝나는 환경에서 1분 넘게 기다린다면 조사할 증상이다. 다만 3초나 1분은 제품의 정상·오류 판정 기준이 아니다. **시간만으로 원인을 확정하지 않고, 다음 단계에서 시작 명령 자체가 끝났는지 확인한다.**

### 시작 명령은 끝났는지 구분한다

앞 시험을 정리하고 DB가 다시 중지된 상태에서, Bash로 다음을 실행한다. 이 코드는 시작 명령 직후에 종료 코드(`rc`)를 표시한다. `rc=0`은 명령이 성공으로 종료했음을 뜻한다.

```bash
{
    cubrid server start testdb
    rc=$?
    printf '시작 명령 종료: rc=%d\n' "$rc" >&2
} | cat
```

`>&2`는 확인 문구를 파이프가 아닌 표준 오류로 보낸다. 일반 터미널에서는 이 문구도 화면에 보인다. 중괄호 안에는 이후에 기다리는 작업이 없으므로, 문구를 출력하면 왼쪽 실행 블록도 끝난다.

| 관찰 | 해석 |
|---|---|
| `시작 명령 종료: rc=0`이 나오고 프롬프트도 돌아옴 | 이 실행에서는 표준 출력 파이프 대기가 재현되지 않음 |
| 종료 문구가 나왔는데도 프롬프트가 돌아오지 않음 | 시작 명령은 끝났지만 파이프의 입력이 끝나지 않음. 남은 쓰기 연결을 조사할 상황 |
| 종료 문구 자체가 아직 나오지 않음 | 시작 명령 자체가 아직 실행 중임. 복구나 서버 등록 대기 등을 따로 조사해야 함 |

종료 코드가 0이 아닌 실패 경로에서도 파이프 대기는 생길 수 있다. 또한 이 예제는 표준 출력만 확인한다. 표준 오류까지 확인하는 코드는 아래 상세 진단에 두고, 파일 잠금 시험은 분석서의 재실행 스크립트로 제공한다.

### 시험을 마무리한다

파이프라인이 기다리는 동안에는 별도 터미널에서 같은 테스트 환경에 접속해 다음을 실행한다.

```bash
cubrid server stop testdb
```

서버를 중지해도 `cat`이 기다릴 수 있다. 시작 명령이 master를 새로 만들었다면 그 master에도 연결이 남기 때문이다. **다른 DB가 없는 전용 테스트 인스턴스에서는** 다음 명령으로 서비스 전체를 정리한다.

```bash
cubrid service stop
```

이 명령은 서비스 전체에 영향을 주므로 공유 환경의 다른 DB를 대상으로 실행하지 않는다. 이 정리는 재현 후 남은 프로세스를 정리하는 절차다. 수정 목표는 서버나 서비스를 중지하지 않아도 시작 호출이 완료되게 하는 것이다.

## Expected Result

시작 결과가 출력된 뒤 `cat`이 종료하고 셸 프롬프트가 돌아온다. 성공한 경우 DB 서버는 계속 실행된다. 실패한 경우에도 실패 결과와 필요한 진단을 받은 뒤 호출자가 다음 작업으로 넘어갈 수 있어야 한다.

## Actual Result

2026-09-23 검토 댓글은 `cubrid server start DB | cat`에서 시작 명령이 1~3초 만에 끝나도 출력 수집이 끝나지 않는다고 보고했다. 2026-10-01 독립 시험에서도 **시작 명령이 성공 코드 0으로 약 3.1초 만에 종료했지만 표준 출력과 표준 오류의 EOF가 오지 않았다.** 서버를 중지한 뒤에도 남았고, 서비스 전체를 중지한 뒤 해제됐다. 이 결과는 master가 없던 상태에서 시작한 조건이다.

master가 이미 실행 중인 경우와 실패·재시작 조건의 측정값은 아래에 구분해 둔다. 위 한 줄 예제와 종료 표시 예제를 이번 문서 개정에서 CUBRID로 새로 실행한 것은 아니다. 기존 댓글과 독립 시험의 증거를 바탕으로 재현 절차를 정리했다.

## Additional Information

### 조사 범위와 근거의 구분

Unix 계열의 서비스 실행부, master, 서버 및 PL의 생성·재시작 경계를 조사했다. 장애 대응을 위해 서버를 감시·재시작하는 HA(고가용성) 구성과 클라이언트 연결을 중개하는 broker 계열도 검토 대상이다. 이슈 유형은 `Correct Error`다. 엔진 코드를 수정하거나 Windows 동작을 검증한 결과는 아니다.

### FD를 복사해도 파이프 자체가 복제되지는 않는다

FD는 프로세스마다 관리하는 작은 정수다. 보통 0은 표준 입력, 1은 표준 출력, 2는 표준 오류다. 커널은 각 프로세스의 FD 테이블에서 해당 번호가 가리키는 열린 파일 객체를 찾는다. 여기서 파일 객체는 디스크 파일뿐 아니라 파이프나 소켓의 열린 연결도 나타낸다. FD와 `flock`은 다른 개념이다. `flock`은 파일 잠금 기능이며, 그 기능을 사용할 때도 FD로 대상 파일을 지정한다.

`a.out | cat`에서 셸은 `a.out`의 표준 출력과 `cat`의 표준 입력을 파이프로 연결한다. 이후 `a.out`이 `fork()`하면 자식의 FD 테이블에도 같은 열린 파일 객체를 가리키는 참조가 생긴다. 파이프나 버퍼를 하나 더 만드는 것이 아니다.

```text
부모의 FD 테이블                  커널 내부
  1 (stdout) ────┐
                 ├── 같은 쓰기 파일 객체 ──→ 파이프 버퍼
자식의 FD 테이블 │                              │
  1 (stdout) ────┘                              ↓
                                          읽기 파일 객체
                                                ↑
                                         cat의 0 (stdin)
```

부모가 종료해도 자식의 참조는 남을 수 있다. 반대로 자식이 자기 쓰기 FD를 닫으면, 자식 프로세스 자체는 계속 살아 있어도 된다. `cat`은 부모나 자식의 생존을 감시하는 것이 아니라 자신의 표준 입력에서 `read()`를 실행한다.

자식 프로세스의 종료 상태를 받는 `wait()`와 파이프에서 EOF를 받는 `read()`는 별개의 작업이다. 호출 도구는 실행한 명령의 종료 코드를 이미 받았어도 출력 수집이 끝나기를 기다릴 수 있다. [wait(2)](https://man7.org/linux/man-pages/man2/wait.2.html)

### close는 시그널이 아니라 커널에 참조 해제를 요청하는 호출이다

`close(1)`은 다른 프로세스에 종료 시그널을 보내는 동작이 아니다. 호출한 프로세스의 FD 테이블에서 1번 연결을 제거하고, 그 연결이 보유하던 파일 객체의 참조를 해제하도록 커널에 요청한다. 다른 프로세스의 FD나 같은 프로세스에서 `dup()`으로 만든 별도 FD는 함께 닫히지 않는다.

프로세스가 종료되면 커널이 남아 있는 FD를 정리한다. `SIGKILL`(`kill -9`)로 종료되어 프로그램의 종료 처리 코드가 실행되지 않아도 이 정리는 수행된다. 다만 부모 하나를 죽인다고 자식까지 자동으로 종료되는 것은 아니다. 손자나 다른 프로세스에 쓰기 끝의 참조가 남았다면 EOF는 아직 오지 않는다.

파이프를 읽는 `cat`의 관점에서는 다음 세 상태를 구분한다. 아래는 읽을 크기가 0보다 큰 일반적인 blocking `read()` 기준이다.

| 파이프 상태 | read의 동작 |
|---|---|
| 버퍼에 데이터가 있음 | 데이터를 복사하고 읽은 바이트 수를 반환한다. |
| 버퍼가 비었지만 쓰기 끝이 열려 있음 | 데이터나 상태 변화가 생길 때까지 기다린다. 출력이 없다는 사실만으로 끝났다고 판단하지 않는다. |
| 버퍼가 비었고 모든 쓰기 끝이 닫힘 | 0을 반환한다. 이것이 EOF다. |

EOF라는 문자나 메시지가 파이프에 추가되는 것은 아니다. 커널이 더 읽을 데이터도, 앞으로 쓸 연결도 없음을 판단해 `read()`의 반환값으로 알린다. `cat`은 그 0을 보고 입력 수집을 끝낸다. 따라서 마지막 쓰기 끝이 닫혀도 버퍼에 남은 데이터는 먼저 읽는다.

### 커널은 두 종류의 카운트로 수명을 관리한다

다음은 Linux v6.12 소스에서 확인한 구현 설명이다. CUBRID가 특정 커널 버전이나 내부 자료형에 의존한다는 뜻은 아니며, 이번 실행 호스트의 커널 내부 카운트를 직접 측정한 결과도 아니다.

| 위치 | 자료형과 동기화 | 의미 |
|---|---|---|
| 열린 파일 객체 `struct file`의 `f_count` | `atomic_long_t` | 해당 파일 객체를 계속 사용하겠다는 참조가 몇 개 남았는지 센다. C++의 `shared_ptr` 참조 카운트와 비슷한 역할을 한다. |
| 파이프 `struct pipe_inode_info`의 `writers` | `unsigned int`, 변경 시 파이프 mutex로 보호 | 파이프의 열린 쓰기 끝 수다. FD 번호나 프로세스 수를 직접 세는 값이 아니다. |

atomic 연산은 여러 실행 흐름이 동시에 값을 바꾸더라도 증가·감소가 서로 덮어써지지 않도록 한다. mutex는 한 번에 하나의 실행 흐름만 보호된 작업을 수행하게 하는 잠금이다. 여기서는 서로 다른 방법으로 카운트 변경을 보호한다.

부모와 자식이 하나의 쓰기 파일 객체를 공유하고, 그 외의 FD나 일시적인 커널 참조는 없다고 단순화하면 다음과 같다. 각 행은 해당 정리가 완료된 뒤의 상태다.

| 사건 | 쓰기 파일 객체의 f_count | 파이프의 writers |
|---|---:|---:|
| 부모만 쓰기 FD 보유 | 1 | 1 |
| fork 후 부모와 자식이 보유 | 2 | 1 |
| 부모가 자기 FD를 닫음 | 1 | 1 |
| 자식도 자기 FD를 닫아 마지막 참조 해제 | 0, 파일 객체 정리 | 0 |

`fork()`나 `dup()`은 같은 파일 객체의 참조를 늘리므로 `writers`가 FD 수만큼 증가하지 않는다. 파일 참조 해제 경로는 atomic 연산으로 마지막 참조인지 확인하고, 최종 정리에서 파이프의 `pipe_release()`를 호출한다. 이 함수가 mutex를 잡고 `writers`를 감소시킨다. 마지막 writer가 없어지면 읽기 대기자를 깨워 상태를 다시 확인하게 한다. 버퍼까지 비어 있으면 읽기 경로가 EOF를 반환한다. 읽기 쪽이 남아 있는 동안 파이프 객체 자체는 계속 존재할 수 있다.

즉 참조 카운트로 관리한다는 이해는 맞다. 다만 파일 객체의 atomic 참조 카운트와, 잠금으로 보호하는 파이프 writer 카운트가 서로 다른 계층에 있다.

근거: Linux v6.12의 [파일 객체 정의](https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.12/include/linux/fs.h), [파일 참조 해제](https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.12/fs/file_table.c), [파이프 구조체](https://github.com/torvalds/linux/blob/v6.12/include/linux/pipe_fs_i.h), [파이프 읽기와 해제](https://github.com/torvalds/linux/blob/v6.12/fs/pipe.c).

### 자식의 생존과 cat의 종료를 분리해서 보는 작은 예제

아래 프로그램을 `fork_demo.c`로 저장한다. 부모는 바로 종료하고 자식은 두 모드 모두 3초 동안 살아 있다. `close` 모드에서만 자식의 stdout을 닫는다. 자식의 상태 안내는 stderr로 출력하므로, 아래 명령에서는 `cat`으로 보내는 파이프에 들어가지 않는다.

```c
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    int release = argc > 1 && strcmp(argv[1], "close") == 0;
    pid_t child = fork();
    if (child < 0) {
        perror("fork");
        return 1;
    }
    if (child == 0) {
        if (release) {
            close(STDOUT_FILENO);
        }
        fprintf(stderr, "child: %s stdout; staying alive for 3 seconds\n",
                release ? "closed" : "keeping");
        sleep(3);
        fprintf(stderr, "child: exiting now\n");
        _exit(0);
    }
    printf("parent: exiting; child PID = %ld\n", (long)child);
    return 0;
}
```

대화형 Bash에서 다음을 실행한다.

```bash
cc -Wall -Wextra -o a.out fork_demo.c
time ./a.out keep | cat
time ./a.out close | cat
```

`keep`에서는 자식이 종료하는 약 3초 뒤 파이프라인이 끝난다. `close`에서는 파이프라인이 먼저 끝나고, 자식의 `exiting now` 안내가 약 3초 뒤 터미널에 나타난다. 비교 조건을 유지하려면 `2>&1`이나 `|&`를 붙이지 않는다. stderr까지 같은 파이프로 연결하면, 자식이 stdout만 닫아도 stderr의 쓰기 참조가 남기 때문이다. 자동화 도구가 stderr를 별도 파이프로 수집하고 있다면 도구 자체의 완료 시점도 그 EOF에 영향을 받을 수 있다.

2026-10-02 Linux `5.14.0-570.30.1.el9_6.x86_64`에서 같은 로직의 프로그램을 실행하고, Python으로 부모와 `cat`을 각각 기다려 시간을 측정했다. 자식 stderr는 `cat`의 입력에 연결하지 않았다. 아래는 각 조건의 최초 1회 실행 결과이며 성능 통계가 아니다.

| 모드 | 부모 종료 | cat 종료 | 자식의 동작 |
|---|---:|---:|---|
| keep | 0.002초 | 3.001초 | stdout을 유지한 채 3초 생존 후 종료 |
| close | 0.002초 | 0.003초 | stdout을 먼저 닫고 3초 생존 후 종료 |

이 예제는 Linux 파이프의 수명 규칙을 보여 주며, CUBRID 수정본의 검증 결과는 아니다. 이슈에서 필요한 것은 서버를 종료시켜 EOF를 얻는 것이 아니라, 서버가 계속 실행되는 동안에도 호출자의 불필요한 쓰기 참조를 놓도록 하는 것이다. 시작 결과와 필요한 진단은 별도로 보존해야 한다.

### CUBRID의 시작과 재기동 경로에 적용하면

```text
호출 도구
  +─ cubrid server start DB                  <- 결과 출력 후 종료
       +─ master가 없으면 cub_master 생성    <- 같은 stdout/stderr와 잠금 FD 보유
       |    +─ 서버 자동/HA 재기동            <- 보유한 FD를 다시 전달
       +─ cub_server                         <- 같은 FD 보유
            +─ cub_pl                        <- 같은 FD + 서버 내부 FD 보유

시작 명령 종료 코드 수신 != 파이프 EOF 수신
```

호출자가 `flock`으로 잠근 파일도 같은 원리로 수명이 늘어난다. 이번 시험처럼 명시적인 잠금 해제 없이 호출자가 FD를 닫는 경우, 백그라운드 프로세스에 참조가 남으면 잠금이 유지된다. 잠금은 CUBRID가 만든 DB 잠금이 아니라 호출 도구의 자원이다. [flock(2)](https://man7.org/linux/man-pages/man2/flock.2.html)

### 검토 댓글을 반영한 원인 정정

[2026-09-23 검토 댓글 4776522](http://jira.cubrid.org/browse/CBRD-27443?focusedCommentId=4776522&page=com.atlassian.jira.plugin.system.issuetabpanels%3Acomment-tabpanel#comment-4776522)은 develop `c63a3b993`에서 파이프와 master·HA 재전파까지 재현했다고 보고했다. 이전 feat/oos 자료의 다음 설명을 정정한다.

| 이전 설명 | 개정 내용과 소스 근거 |
|---|---|
| master에는 FD 정리 코드가 있으므로 같은 문제가 없다 | `util_service.c:1017`이 `CUBRID_NO_DAEMON`을 설정한다. `master.c:1313` 분기에서 `css_daemon_start()` 전체를 건너뛰므로 서비스 명령으로 시작한 master도 일반 FD를 유지한다. |
| 파이프 대기는 아직 원인 후보다 | 댓글의 재현 보고에 더해 이번 독립 시험도 stdout·stderr EOF 부재를 확인했다. |
| master 방식의 FD 3 이상 정리로 충분하다 | `master.c:1686` 루프는 0·1·2를 남긴다. 직접 daemon 실행에서도 파이프 대기는 남는다. |
| master가 부모인 재기동은 셸의 FD 상속과 다른 조건이다 | master에 원래 FD가 남아 있으면 새 서버도 받는다. `master_server_monitor.cpp:266`, `master_heartbeat.c:3137`의 fork/exec 경계에 일반 정리가 없다. |

`proc_execute_internal()`은 선택적으로 stdout·stderr를 닫지만 서버와 master 호출부는 해당 옵션을 사용하지 않는다. PL 생성의 `create_child_process()`도 입출력 파일 인수를 모두 `nullptr`로 받으며 일반 FD를 정리하지 않는다. `setsid()`는 세션을 분리할 뿐 FD를 닫지 않는다.

### 성공 응답과 진단을 보존하는 수정 방향

시작 결과를 출력하는 주체는 서비스 명령이다. `process_server()`는 `is_server_running()`으로 master의 서버 등록 상태를 확인한 뒤 `print_result()`를 실행한다. 백그라운드 서버가 호출자 파이프를 계속 보유해야 결과를 알려줄 수 있는 구조는 아니다.

다만 서버 진입부의 복구 안내와 초기 오류는 현재 stdout·stderr에도 출력된다. 수정 시 이후 출력은 별도 진단 대상으로 연결하고, 호출자에게는 성공·실패와 필요한 진단을 유지해야 한다. 단순히 출력을 버리거나 실제 준비 확인보다 먼저 성공을 반환하는 방식은 충분하지 않다.

AI 분석상 권장 방향은 백그라운드 생성 경계에 명시적 FD 상속 정책을 두고, 표준 입출력은 새 대상으로 연결하며 그 외 FD는 필요한 인계 목록만 남기는 것이다. 서버 내부 파일의 close-on-exec 적용은 PL·재기동 전파를 줄이는 보완책이다. 정확한 API와 로그 정책은 확정안이 아니다.

공통 도우미의 `wait_child` 값만으로 정책을 정하면 안 된다. 동기로 실행한 broker 관리 명령도 장수 자식을 생성한다. 또한 실행 중 `SCM_RIGHTS`로 소켓을 전달하는 경로는 exec 당시 FD 상속과 다르므로, 그 존재만으로 불필요한 FD 보존을 정당화할 수 없다.

### 조건별 독립 실측 결과

2026-10-01 독립 실측 결과다. 각 조건은 1회 실행했으며 시간은 성능 통계가 아니다.

| 조건 | 명령 종료 코드 / 시간 | 종료 후 두 출력 EOF | 호출자 잠금 | 해제 시점 |
|---|---|---|---|---|
| master 없음 + 정상 DB | 0 / 3.107초 | 둘 다 없음 | 획득 실패 | 서버 stop 이후에도 남고 service stop 뒤 해제 |
| master 미리 실행 + 정상 DB | 0 / 2.106초 | 둘 다 없음 | 획득 실패 | 서버 stop 뒤 해제 |
| master 없음 + 존재하지 않는 DB | 1 / 2.105초 | 둘 다 없음 | 획득 실패 | 남아 있는 master를 service stop으로 종료한 뒤 해제 |
| 직접 daemon master | 0 / 0.101초 | 둘 다 없음 | 획득 성공 | 파이프는 service stop 뒤 해제 |
| 일반 서버 자동 재기동 | 최초 0 / 3.108초 | 재기동 뒤에도 없음 | 재기동 뒤에도 실패 | service stop 뒤 해제 |

정상 시작의 stdout에는 성공 결과가 있었고 stderr는 빈 문자열이었다. 그럼에도 두 파이프의 EOF는 오지 않았다. `/proc`에서 master·서버·PL이 같은 파이프와 잠금 파일을 보유하는 것을 확인했다. master를 미리 실행한 조건에서는 해당 master가 이번 호출의 자원을 보유하지 않았다.

일반 재기동 시험은 서버 PID 29를 종료한 뒤 새 서버 PID 276과 PL PID 278에 동일한 호출자 FD가 남는 것을 확인했다. 번호는 해당 namespace 안의 값이다. PL의 서버 오류 로그·활성 로그 볼륨 보유도 관측했다.

### 표준 출력과 표준 오류를 각각 확인하는 상세 진단

다른 DB가 없는 전용 테스트 인스턴스에서 실행한다. 아래는 master가 없는 조건의 파이프 대기를 관측한다. 명령 종료 뒤 2초는 관측창이고 30초는 시험 중 명령 대기 상한이다. 제품 timeout 설정이 아니다.

```bash
cubrid service stop
cubrid createdb --db-volume-size=20M --log-volume-size=20M fd27443 en_US.utf8
python3 - <<'PY'
import os
import selectors
import subprocess
import time

p = subprocess.Popen(['cubrid', 'server', 'start', 'fd27443'],
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
sel = selectors.DefaultSelector()
eof = {'stdout': False, 'stderr': False}
for label, stream in [('stdout', p.stdout), ('stderr', p.stderr)]:
    os.set_blocking(stream.fileno(), False)
    sel.register(stream, selectors.EVENT_READ, label)

def collect(seconds):
    deadline = time.monotonic() + seconds
    while sel.get_map() and time.monotonic() < deadline:
        for key, _ in sel.select(0.1):
            data = os.read(key.fd, 65536)
            if data:
                print(key.data, repr(data))
            else:
                eof[key.data] = True
                sel.unregister(key.fileobj)

def control(args):
    with open('fd27443-control.log', 'ab') as output:
        subprocess.run(args, stdout=output, stderr=output,
                       timeout=30, check=True)

try:
    deadline = time.monotonic() + 30
    while p.poll() is None and time.monotonic() < deadline:
        collect(0.1)
    print('launcher_rc =', p.poll())
    collect(2)
    print('EOF after launcher exit =', eof)
    control(['cubrid', 'server', 'stop', 'fd27443'])
    collect(2)
    print('EOF after server stop =', eof)
finally:
    control(['cubrid', 'service', 'stop'])
    collect(2)
    print('EOF after service stop =', eof)
PY
cubrid deletedb fd27443
```

master 사전 실행, 존재하지 않는 DB, 직접 daemon master, 일반 재기동과 잠금 시험은 분석서의 재실행 스크립트와 원시 JSON에 함께 제공한다. 이 상세 진단 코드는 호출자 잠금 검사를 포함하지 않는다.

### 수정본 검증 조건

| 대상 | 필요한 판정 |
|---|---|
| 정상 시작과 실패 | 올바른 종료 코드·진단, stdout 및 stderr EOF, 서버 실행 중 잠금 해제 |
| master 유무·직접 daemon 실행 | 어느 경로에서도 호출자 자원이 master 수명에 묶이지 않음 |
| 일반 서버·PL 재시작 | 호출자 및 부모 내부의 불필요한 FD 미상속, SQL·저장 프로시저 정상 실행 |
| HA 시작·재기동·heartbeat stop | master 포함 전체 보유자 검사. single-node 결함 실측은 댓글에 있고 2-node copylogdb/applylogdb는 추가 검증 필요 |
| 동기 명령·foreground·broker | 기존 출력·리다이렉션·접속 동작 보존. broker 최초 실행과 내부 재시작을 별도 검사 |
| FD 경계값·실패 처리 | 높은 FD, 닫힌 0·1·2, 같은 파이프의 복제 FD, 로그 접근 실패, exec 실패 검증 |

### 별도로 추적할 사항

`NO_DAEMON` master의 프로세스 그룹 잔류와 timeout 신호에 의한 종료는 별도 결함 후보로 유지한다. 세션 분리와 FD 정리는 서로 대체할 수 없다. 이번에는 그룹 잔류를 관측했으며 timeout 신호 실측은 댓글의 보고를 근거로 한다.

`is_server_running()`에는 살아 있는 자식의 등록을 기다리는 자체 시간 상한이 없다. 시작 명령 자체가 종료하지 않는 사례는 이 경로와 실제 복구 시간을 따로 조사해야 한다. 사용자가 경험한 모든 1분 이상 대기를 이번 FD 원인으로 단정하지 않는다.

PL의 실제 fork는 모니터 스레드에서 실행된다. 따라서 초기화 호출을 로그 초기화보다 앞에 두었다는 사실만으로 로그 FD 미상속을 보장할 수 없다. 다중 스레드의 fork 이후 안전성, 내부 파일의 원자적 close-on-exec 설정 및 지원 OS의 FD 정리 API도 구현 검토에 포함한다.

### 분석서와 소스

상세 분석서: `my-cubrid-docs/cbrd-27443/CBRD-27443-fd-lifecycle-analysis_c63a3b9_codex.md`. 같은 디렉터리의 `evidence/`에 댓글 조회본, 실행 스크립트, 다섯 조건의 JSON, 소스 비교 및 바이너리 해시를 보존한다.

- [서비스 실행·master 시작](https://github.com/CUBRID/cubrid/blob/c63a3b993be552ef6ad3ce244c386d5081147958/src/executables/util_service.c#L868), [시작 결과 확인](https://github.com/CUBRID/cubrid/blob/c63a3b993be552ef6ad3ce244c386d5081147958/src/executables/util_service.c#L1570)
- [master의 NO_DAEMON 분기](https://github.com/CUBRID/cubrid/blob/c63a3b993be552ef6ad3ce244c386d5081147958/src/executables/master.c#L1313), [FD 정리](https://github.com/CUBRID/cubrid/blob/c63a3b993be552ef6ad3ce244c386d5081147958/src/executables/master.c#L1676)
- [PL 생성](https://github.com/CUBRID/cubrid/blob/c63a3b993be552ef6ad3ce244c386d5081147958/src/sp/pl_sr.cpp#L356), [공통 자식 생성](https://github.com/CUBRID/cubrid/blob/c63a3b993be552ef6ad3ce244c386d5081147958/src/base/process_util.c#L262)
- [일반 재기동](https://github.com/CUBRID/cubrid/blob/c63a3b993be552ef6ad3ce244c386d5081147958/src/executables/master_server_monitor.cpp#L262), [HA 재기동](https://github.com/CUBRID/cubrid/blob/c63a3b993be552ef6ad3ce244c386d5081147958/src/executables/master_heartbeat.c#L3137)
