# [EPIC] [Security] Application-CAS 및 CAS-cub_server 종단 간 전송 보안

## Issue Triage

**이슈 수행 목적**: 응용 프로그램에서 CAS(broker의 application server process)를 거쳐 `cub_server` 에 이르는 모든 네트워크 구간에서 데이터 기밀성과 상대 신원 인증을 보장할 수 있게 한다. 보호 필수 구성에서는 평문 연결이나 인증 실패 후의 자동 fallback을 허용하지 않는다.

**이슈 수행 이유**:

| 구분 | AS-IS (현재 동작 / 배경) | TO-BE (목표 상태 / 기대 동작) |
|------|--------------------------|-------------------------------|
| Application-CAS | TLS를 선택할 수 있지만 기본 구성은 평문이며, 분석한 CCI(CUBRID C driver)에는 서버 신원 검증 설정이 없다. | 운영자가 TLS와 서버 신원 인증을 명시적으로 요구할 수 있고, 요구 조건을 만족하지 못하면 연결이 실패한다. |
| CAS-cub_server | CAS가 별도의 평문 CSS(CUBRID 내부 client-server 통신 계층) TCP 연결을 만들며 transport 보안 설정을 제공하지 않는다. | CSS packet 전체를 인증된 TLS로 보호할 수 있고, HA(High Availability) 전환이나 동적 server port에서도 같은 정책을 유지한다. |

**영향**: 기술 부채 — TDE(Transparent Data Encryption, 저장 데이터 암호화) 테이블과 Application-CAS TLS를 함께 사용해도 원격 CAS-cub_server 구간에는 같은 보호 정책을 강제할 수 없다. 공격자가 이 통신 경로를 관찰할 수 있으면 SQL 처리 데이터와 결과 레코드를 수집할 수 있으며, 이는 CWE-319 유형에 해당할 수 있다.

**이슈 수행 방안**: 이 Epic은 CAS-cub_server CSS 전송 보호, Application-CAS 상대 신원 검증, 보안 경계 문서화와 검증을 필수 하위 작업으로 추적한다. JDBC의 현재 인증 동작은 하위 이슈에서 먼저 확인한다. 구간별 설정 이름과 전환 mode, 기본값, 인증서 배포 및 mTLS(mutual TLS, 양방향 인증) 적용 여부는 `TBD - 합의 미확인` 이다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### 범위 요약

- **변경 범위 / 영향**: `src/connection`, `src/communication`, `src/broker`, CCI/JDBC 드라이버, HA 연결 처리, broker 및 server 보안 설정, 설치·운영 매뉴얼이 영향을 받는다.
- **호환성**: 기존 평문 배포를 위한 전환 정책이 필요하다.
- **릴리스 범위**: 대상 release와 하위 버전 backport 여부는 정해지지 않았다.

## Description

### 현재 연결 경계

CAS는 응용 프로그램 요청을 받아 DB client 역할로 `cub_server` 에 접속하는 broker application server다. 두 구간은 같은 연결이 아니라 서로 독립된 소켓이다.

```
[Application / JDBC·CCI]
          |
          | Application-CAS transport
          | broker SSL=ON + driver useSSL=true인 경우 TLS
          | 기본값: SSL=OFF
          v
        [CAS]
          |
          | CAS-cub_server transport
          | CSS TCP
          v
     [cub_server]
```

`SSL=ON` 은 CAS의 client socket에서 `SSL_accept()` 를 수행하고 이후 `SSL_read()` 와 `SSL_write()` 를 사용하게 한다. CAS가 `ux_database_connect()` 를 거쳐 `db_restart_ex()` 를 호출하면 별도의 `css_connect_to_cubrid_server()` 경로가 시작된다. 따라서 첫 번째 구간의 TLS는 CAS에서 종료되며 두 번째 CSS 연결로 이어지지 않는다.

### TDE와 전송 암호화의 경계

TDE는 data at rest, 즉 디스크에 기록된 페이지·로그·백업을 보호한다. 암호화된 data page는 buffer pool에 들어올 때 `tde_decrypt_data_page()` 로 복호화되므로 이후 query 실행과 network 전송 계층은 평문 메모리 데이터를 다룬다.

`RECDES` 는 heap record의 직렬화된 바이트와 길이를 가리키는 내부 record descriptor다. `xfetch_all()` 계열의 실제 server 흐름은 다음과 같다.

```
[TDE data page read]
 pgbuf_fix 계열
   └ tde_decrypt_data_page()                         page_buffer.c
        └ buffer pool의 평문 page

[fetch]
 xlocator_fetch_all()                               locator_sr.c
   └ heap_next(..., COPY)
        └ RECDES bytes를 LC_COPYAREA content에 배치

[send]
 slocator_fetch_all()                               network_interface_sr.cpp
   └ locator_send_copy_area()
        └ content_ptr = copyarea->mem               locator.c
           ★ content는 별도 변환 없이 전달
   └ css_send_reply_and_2_data_to_client()
        └ connection worker의 sendmsg()             connection_worker.cpp
```

이 흐름에서 TDE는 정상적으로 저장 데이터 보호 책임을 끝낸다. CAS-cub_server 구간까지 보호하려면 TDE나 locator에 record별 암호화를 추가하는 것이 아니라 CSS transport 자체에 TLS를 적용해야 한다. 그래야 fetch content뿐 아니라 request, bind value, result, error를 포함한 protocol packet 전체가 같은 정책으로 보호된다.

### Application-CAS 상대 인증 현황

현재 분석한 CCI commit `2fb8d6d02c41386be0d56c3cfc6a14ad7e17ac15` 에서는 `TLS_client_method()`, `SSL_new()`, `SSL_set_fd()`, `SSL_connect()` 로 TLS session을 만든다. 그러나 CCI source에서 `SSL_CTX_set_verify()`, CA(Certificate Authority) trust store 설정, hostname 또는 SAN(Subject Alternative Name) 검증 호출은 확인되지 않는다. OpenSSL은 verify flag를 명시하지 않으면 `SSL_VERIFY_NONE` 을 사용한다.

JDBC submodule은 분석 worktree에 checkout되어 있지 않아 같은 항목을 확인하지 못했다. JDBC 인증 동작과 지원 설정은 하위 이슈에서 별도로 감사해야 한다.

### 공격자 능력별 노출

| 조건 | 공격자 능력 | 판단 |
|------|-------------|------|
| loopback이며 host가 신뢰 경계 안에 있음 | host와 local socket에 접근할 수 없음 | 네트워크 도청 가능성은 제한적이다. |
| network 관리자나 운영 계정이 packet capture 가능 | CAS-cub_server 통신 경로를 관찰할 수 있음 | DB payload가 노출될 수 있다. |
| 공격자가 통신 경로를 관찰하거나 변조할 수 있음 | packet 수집, 차단, redirect 변조 가능 | 기밀성과 server identity를 보장할 수 없다. |

위험도는 배포 형태만으로 고정할 수 없으며, 공격자가 통신 경로에 접근할 수 있는지가 핵심 조건이다. remote CAS 구성을 지원하는 이상 transport 보호 부재를 배포 전제만으로 해소할 수는 없다. 기능이 제공되기 전까지 원격 두 번째 구간에는 VPN이나 IPsec 같은 별도 보호 채널을 적용하는 것이 운영상 완화책이다.

## Specification Changes

다음은 Epic 목적을 검증하기 위한 합의 전 권장 요구사항이다. 설정 이름, 기본값, 호환 정책과 인증서 운용 방식은 review에서 확정해야 한다.

### 보호 보장

1. Application-CAS와 CAS-cub_server를 서로 다른 transport 보안 경계로 문서화한다.
2. 각 구간에서 암호화와 peer 인증을 요구할 수 있어야 한다.
3. 보호 필수 mode에서는 TLS handshake, certificate chain, hostname 검증 중 하나라도 실패하면 연결을 종료하며 평문으로 재접속하지 않는다.
4. TDE 사용 여부와 network transport 보안 상태는 독립적으로 설정하고 확인할 수 있어야 한다.

### 설정과 호환성

| 항목 | 필요한 결정 |
|------|-------------|
| CAS-cub_server mode | `disabled`, 전환용 mode, `required` 같은 상태 이름과 의미: `TBD - 합의 미확인` |
| 기존 Application-CAS transport TLS와의 관계 | 독립 설정으로 둘지 종단 간 profile을 추가할지: `TBD - 합의 미확인` |
| 기본값과 upgrade | 신규 설치 기본값, 기존 설치 호환, deprecation 기간: `TBD - 합의 미확인` |
| TLS baseline | 최소 protocol version, cipher policy, TLS 1.3 지원 범위: `TBD - 합의 미확인` |
| 상대 인증 | CA bundle 위치, hostname/SAN 규칙, self-signed certificate 지원 방식: `TBD - 합의 미확인` |
| mTLS | CAS client certificate를 필수 또는 선택으로 둘지: `TBD - 합의 미확인` |

### 운영과 관측성

연결 실패는 TLS handshake, trust chain, hostname, protocol mismatch, certificate 만료를 구분할 수 있는 error와 log를 남겨야 한다. 현재 연결이 평문인지 TLS인지, peer 인증이 성공했는지를 운영자가 진단할 수 있는 상태 정보도 필요하다. certificate 교체와 갱신이 기존 connection 및 신규 connection에 미치는 동작은 하위 설계에서 정한다.

### 문서

보안 매뉴얼의 현재 `client-server` 표현을 실제 두 구간으로 나눠 설명한다. broker `SSL=ON` 이 Application-CAS까지만 보호한다는 점, TDE가 data at rest만 보호한다는 점, remote CAS-cub_server 배포의 보호 방법, mode별 실패 동작과 인증서 배포 절차를 명시한다.

## Implementation

### 하위 작업 구조

| 작업 | 책임과 산출물 | 주요 위치 |
|------|---------------|-----------|
| CAS-cub_server authenticated TLS | CSS packet framing 아래의 stream I/O에 TLS adapter를 추가하고 client/server handshake, peer 검증, HA 재연결, error mapping을 구현한다. | `src/connection/connection_cl.cpp`, `connection_worker.cpp`, `connection_support.cpp`, `server_support.c` |
| Application-CAS 상대 신원 검증 | CCI의 CA 및 hostname 검증을 추가하고 JDBC의 현재 동작을 먼저 감사한다. 호환 가능한 driver property와 실패 정책을 정의한다. | `cubrid-cci/src/cci/cci_ssl.c`, `cci_network.c`, `cubrid-jdbc` |
| Configuration and operations | mode, certificate/key/CA 위치, secret 권한, rotation, 진단 정보와 upgrade 절차를 정의한다. | `src/base/system_parameter*`, broker/server 설정, utility 및 log |
| Documentation and validation | 두 구간과 TDE 경계를 문서화하고 packet capture, HA, certificate failure, 성능 회귀 검증을 자동화한다. | CUBRID manual, SQL/shell/driver test |

### 권장 CSS 구현 경계

TLS는 `RECDES`, locator 또는 개별 network request에 삽입하지 않고 CSS의 stream read/write seam에 둔다. CSS packet framing은 현재와 같이 length와 payload를 만들고, 하위 adapter가 plain TCP 또는 TLS stream으로 전송하게 한다.

```
[CSS request/reply framing]
          |
          v
[transport adapter]
   ├ plain TCP adapter       전환·호환 정책이 허용한 경우만
   └ TLS adapter
        ├ handshake와 peer 검증
        ├ partial read/write
        ├ SSL_ERROR_WANT_READ / SSL_ERROR_WANT_WRITE
        ├ timeout과 nonblocking event 연동
        └ shutdown과 error 변환
          |
          v
       [socket]
```

현재 비동기 송신 경로는 `sendmsg()` 의 partial send를 남은 `iovec` 과 buffer lifetime으로 관리한다. TLS adapter는 `SSL_write_ex()` 의 partial return과 `SSL_ERROR_WANT_READ/WRITE` 를 기존 worker 상태에 매핑해야 한다. 기존 scatter/gather 및 zero-copy 특성을 유지할 수 있는지는 설계·측정 대상으로 둔다.

`css_connect_to_cubrid_server()` 는 먼저 `cub_master` 를 거친다. `SERVER_CONNECTED_NEW` 에서는 전달받은 `port_id` 로 새 연결을 만들고, `SERVER_CONNECTED` 에서는 기존 연결을 계속 사용한다. TLS 시작 지점과 server identity 검증은 두 경로 모두 정의해야 하며, 평문 bootstrap의 redirect 결과를 신뢰할 수 있는지도 함께 결정해야 한다. HA의 `preferred_hosts`, alternate host, failover에서도 검증 대상 hostname을 어떤 server identity와 연결할지 정해야 한다.

### 범위 밖

- TDE page/log format 또는 master/data key 구조 변경
- `RECDES` 나 특정 `xfetch_all()` response만 별도로 암호화하는 application-layer protocol 추가
- DB data 자체의 field-level encryption
- TLS를 대신하는 자체 암호 protocol 설계

## Acceptance Criteria

다음은 종단 간 보안 목표를 검증하기 위한 권장 A/C다. 미결정 정책을 합의한 뒤 해당 값과 실패 동작을 구체화한다.

| ID | 검증 조건 |
|----|-----------|
| A1 | Application-CAS와 CAS-cub_server 두 구간의 보안 책임, 설정, 기본값, upgrade 정책을 승인된 하위 스펙으로 확정한다. |
| A2 | CCI와 JDBC 각각에 대해 client→CAS request와 CAS→client response가 TLS로 보호되고, 합의된 certificate chain 및 hostname 검증 정책을 충족한다. |
| A3 | CAS-cub_server의 `SERVER_CONNECTED` 와 `SERVER_CONNECTED_NEW` 분기 모두에서 request와 response가 같은 TLS 및 server identity 정책을 따른다. |
| A4 | 보호 필수 구성에서 평문 연결 시도, 신뢰할 수 없는 CA, 만료 certificate, hostname 불일치가 연결 실패로 끝나며 평문 fallback이 발생하지 않는다. |
| A5 | request, bind value, result, error, fetch copy-area content에 서로 다른 sentinel을 넣은 packet capture test에서 어느 값도 평문으로 나타나지 않는다. 상대 신원 인증은 A4의 negative test로 별도 검증한다. |
| A6 | `preferred_hosts`, alternate host와 HA failover에서도 A3과 A4의 정책을 유지한다. |
| A7 | nonblocking partial I/O, timeout, connection close와 동시 session test를 통과한다. certificate rotation이 기존 session과 신규 connection에 미치는 동작을 먼저 확정하고 자동화 test로 고정한다. |
| A8 | TLS 적용 전후의 throughput, latency, CPU, memory를 측정한다. 허용 회귀 기준은 `TBD - 합의 미확인` 이다. |
| A9 | 매뉴얼이 Application-CAS transport TLS의 종료 지점, TDE와 transport encryption의 차이, topology별 설정과 운영 절차를 설명한다. |

## Definition of done

- [ ] 위 A/C를 충족한다.
- [ ] 관련 engine, broker, HA, CCI/JDBC regression QA를 통과한다.
- [ ] security review와 packet capture 기반 검증을 통과한다.
- [ ] 설정 reference, security guide, driver guide, upgrade note를 반영한다.
- [ ] 생성된 하위 이슈를 이 Epic에 연결하고 각 source 및 manual 변경을 추적한다.

## Open Questions

| 결정 항목 | 후보 / 상태 | 권장안과 근거 |
|-----------|-------------|---------------|
| upgrade 정책 | 기존 기본값 유지 후 단계적 강화, 신규 설치 우선 강화 | 기존 설치의 갑작스러운 연결 실패를 막되 secure-by-default 전환 시점을 release plan에 명시한다. |
| same-host 정책 | loopback 평문 허용, 모든 연결 `required` | 운영 단순성과 일관된 보장을 위해 `required` 를 우선 검토하되 성능 측정 후 확정한다. |
| 상대 인증 범위 | server authentication, mTLS | 우선 server identity를 필수로 하고 mTLS는 certificate 운영 비용과 위협 모델을 비교한다. |
| certificate identity | DB server name, host FQDN, HA node name | HA failover와 실제 접속 주소가 달라질 수 있으므로 SAN mapping 규칙을 먼저 설계한다. |
| TLS baseline | 최소 version과 cipher policy | 지원 OpenSSL version과 배포 OS를 조사한 뒤 TLS 1.3 범위를 확정한다. |
| CSS 적용 범위 | CAS client type만 적용, 모든 CS_MODE 연결의 공통 기능 | 공통 adapter의 영향 범위가 csql, 일반 client와 master/HA 연결까지 넓어지는지 먼저 감사한다. |
| release 범위 | 신규 major/minor, 하위 버전 backport | protocol 및 운영 변경 규모와 보안 지원 정책을 함께 검토한다. |

## References

### 분석 기준

- CUBRID source commit: `f30f1c26003e5aa8e93182648e06cad76fc77064`
- CCI source commit: `2fb8d6d02c41386be0d56c3cfc6a14ad7e17ac15`
- CUBRID manual commit: `3b6ae97bfbdc664b010ffa933ded5a05b291ae03`

### 주요 코드

- `src/broker/broker_config.h:101`, `broker_config.c:653` — broker `SSL` 기본값과 설정
- `src/broker/cas_network.c:79-82`, `cas_ssl.c:136-247` — Application-CAS TLS read/write
- `src/broker/cas.c:375-380`, `cas_execute.c:451-455` — CAS의 별도 DB 접속 시작
- `src/connection/connection_cl.cpp:1087-1181`, `css_server_connect_part_two():882-925` — 기존 연결 유지와 동적 server port 재접속 분기
- `src/storage/page_buffer.c:8491-8505` — TDE data page를 buffer pool에서 복호화
- `src/transaction/locator_sr.c:2897-2921` — `xlocator_fetch_all()` 의 copy area 구성
- `src/transaction/locator.c:656-686` — fetch content를 copy area memory 그대로 전달
- `src/communication/network_interface_sr.cpp:954-1020` — copy area content를 CSS response로 전달
- `src/connection/server_support.c:669-721`, `connection_worker.cpp:115-160` — CSS packet 구성과 socket `sendmsg()`
- `cubrid-cci/src/cci/cci_ssl.c:35-78`, `cci_network.c:1604-1643` — CCI TLS session 생성과 handshake

### 외부 근거

- [CUBRID 11.4 Security Manual](https://www.cubrid.org/manual/en/11.4/security.html) — broker packet encryption과 TDE의 data-at-rest 범위
- [OpenSSL SSL_CTX_set_verify](https://docs.openssl.org/3.0/man3/SSL_CTX_set_verify/) — verify flag를 명시하지 않을 때 `SSL_VERIFY_NONE` 이 기본값임을 설명
- [CWE-319: Cleartext Transmission of Sensitive Information](https://cwe.mitre.org/data/definitions/319.html) — sniff 가능한 통신 채널의 평문 민감 데이터 전송 분류
