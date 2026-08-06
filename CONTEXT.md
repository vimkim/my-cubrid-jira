# CUBRID Transport Security Context

CUBRID의 다중 홉 연결에서 전송 보안 경계를 일관된 용어로 구분한다. 저장 암호화와 전송 암호화를 섞어 부르는 일을 막고, 어느 연결을 보호하는지 명확히 드러내기 위한 문맥이다.

## Language

**Application-CAS transport**:
응용 프로그램의 JDBC 또는 CCI 드라이버와 CAS 사이의 연결이다. broker의 `SSL` 설정과 드라이버의 `useSSL` 설정이 이 구간을 제어한다.
_Avoid_: client-server TLS, broker TLS

**CAS-cub_server transport**:
CAS가 DB client로서 `cub_server`에 접속하는 별도 CSS 연결이다. 초기 연결 협상은 기존 연결을 유지하거나 동적 server port로 redirect할 수 있으며, Application-CAS transport와 소켓 및 보안 설정을 공유하지 않는다.
_Avoid_: internal connection, trusted backend connection

**CSS transport**:
CUBRID 내부 client-server 프로토콜의 packet framing을 TCP stream으로 전달하는 계층이다. CAS-cub_server transport가 이 계층을 사용한다.
_Avoid_: broker protocol

**End-to-end transport security**:
Application-CAS transport와 CAS-cub_server transport 모두에서 기밀성과 상대 신원 인증을 보장하는 상태다. 한 구간만 TLS로 보호하는 상태에는 이 용어를 사용하지 않는다.
_Avoid_: packet encryption

**TDE**:
데이터 페이지, 로그, 백업 등 디스크에 기록되는 data at rest를 보호하는 Transparent Data Encryption이다. 메모리에서 처리되거나 네트워크로 전송되는 데이터의 암호화를 뜻하지 않는다.
_Avoid_: network encryption, end-to-end encryption

**RECDES**:
heap record의 직렬화된 바이트와 길이 정보를 가리키는 CUBRID 내부 record descriptor다. fetch 경로에서는 이 바이트가 copy area의 content payload로 들어갈 수 있다.
_Avoid_: encrypted record, wire record format
