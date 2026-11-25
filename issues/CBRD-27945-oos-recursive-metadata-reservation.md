# [OOS][조사] 파일 메타데이터 재귀 할당이 회수 가능한 빈 페이지를 두고 섹터를 예약하는 후보 확인

**한 줄 요약**: TLA+와 추출 소스 실행에서 OOS 회수 검사 이후 안전해진 빈 페이지를 두고 파일 메타데이터 할당이 새 섹터를 예약하는 경로를 확인하여, 실제 발생 조건과 보완 범위를 조사한다.

## Issue Triage

**이슈 수행 목적**: OOS 성장 검사와 실제 섹터 예약 사이에 회수 가능한 페이지가 생겼을 때 메타데이터 할당이 이를 놓치는지 확인하고 필요한 보장을 정한다.

**이슈 수행 이유**: 사용자 페이지 할당이 마지막 예약 여유 페이지를 소비하면, 가득 찬 섹터 정보를 기록할 메타데이터 페이지가 추가로 필요할 수 있다. 그 재귀 할당은 OOS 회수 검사를 다시 거치지 않는다. 앞선 검사에서 유예한 rollback 페이지가 이 사이에 안전해지는 후보를 TLA+와 추출 소스 실행에서 확인했다.

**영향**: 큰 OOS 파일의 메타데이터가 확장되는 경계에서 빈 페이지를 둔 채 추가 디스크 공간을 예약할 가능성이 있다. 실제 DB의 도달 가능성, 빈도와 디스크 비용은 미확인이다. 영구 누수나 데이터 손상을 주장하지 않는다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

기준 엔진 소스는 `f67f2f692a7ad9f9efada2178759ca713e596b9d`다. 이 이슈는 회수 알림이 사라지는 후보와 관련되지만, 알림이 남아 있는 실행에서도 성립하는 별도 경로를 조사한다. READ 획득 실패를 유예로 남기는 가상 수정도 이 경로를 제거하지 못했다. 하나의 수정으로 두 문제를 해결했다고 판단하지 않는다.

근거는 소스와 연결한 유한 모델 및 일부 의존 함수를 대체한 추출 C++ 실행이다. 실제 CUBRID 서버와 SQL을 통한 통합 재현은 하지 않았다. 조사 이슈 등록이 재현 승인이나 결함 확정을 의미하지 않는다.

## Evidence

1. OOS 성장 검사가 빈 페이지를 보지만 rollback의 수명이 아직 끝나지 않아 회수를 유예한다. [검사와 LSA gate](https://github.com/CUBRID/cubrid/blob/f67f2f692a7ad9f9efada2178759ca713e596b9d/src/storage/oos_file.cpp#L1587-L1649)를 기준으로 한다.
2. 사용자 페이지 할당이 마지막 예약 여유 페이지를 소비하고, 가득 찬 섹터 정보를 full table에 옮긴다. [이동과 메타데이터 등록](https://github.com/CUBRID/cubrid/blob/f67f2f692a7ad9f9efada2178759ca713e596b9d/src/storage/file_manager.c#L5302-L5322)을 따른다.
3. full table에 공간이 없어 [메타데이터 페이지를 재귀 할당](https://github.com/CUBRID/cubrid/blob/f67f2f692a7ad9f9efada2178759ca713e596b9d/src/storage/file_manager.c#L5058-L5075)한다. 이 사이 rollback이 완료되어 빈 페이지가 회수 가능한 상태가 되는 실행을 조사한다.
4. 재귀 `file_perm_alloc`이 [예약 여유 공간 0 검사](https://github.com/CUBRID/cubrid/blob/f67f2f692a7ad9f9efada2178759ca713e596b9d/src/storage/file_manager.c#L5197-L5207)를 거쳐 [새 섹터 예약](https://github.com/CUBRID/cubrid/blob/f67f2f692a7ad9f9efada2178759ca713e596b9d/src/storage/file_manager.c#L4687-L4698)을 수행한다. OOS 회수 검사는 재실행하지 않는다.

TLA+ 모델의 `NoMetadataReservationWithSafeEmpty` 위반은 16개 전이의 경로로 나타난다. 회수 힌트가 양수로 남는 별도 반례도 있다. 오래된 할당자 트랜잭션 head가 있으면 LSA horizon이 페이지의 회수 가능 판정을 막는 대조군을 별도로 확인했다. 따라서 rollback 완료만으로 항상 회수가 가능하다고 가정하지 않는다.

추출 소스 실행은 4 KiB 파일에 사용자 페이지 할당 47,741회를 실행해 full table이 찬 fixture를 구성했다. 선택한 순서에서 재귀 할당이 7개 섹터를 예약했고, 빈 대상 페이지와 회수 힌트가 남았다. 후속 실험은 첫 OOS tail의 할당과 나머지 chunk 삽입까지 연결했다. 실제 트랜잭션 상태, 래치와 로그 공개 시점 등 일부 의존 조건은 대체하거나 고정했다. 이 수치는 실제 DB에서 측정한 디스크 증가량이 아니다.

## Acceptance Criteria

- [ ] 팀장에게 실제 DB 재현의 목적, 환경과 실행 범위를 승인받고 승인 근거를 기록한다. 승인 전 서버·DB 재현에 착수하지 않는다.
- [ ] 승인 후 실제 파일의 예약 여유 공간과 full table 용량, 재귀 할당 진입, 대상 빈 페이지를 같은 실행에 연결한다.
- [ ] 섹터 예약 시점의 transaction head, append clamp와 page LSA를 확인하여 대상 페이지가 그 시점에 실제로 안전했는지 판정한다.
- [ ] 후보가 성립하면 회수 가능성 확인과 실제 예약 사이에 필요한 보완 범위를 정한다. 파일 헤더 래치나 sysop을 임의로 전역 배제로 간주하지 않는다.
- [ ] 후보가 기각되면 모델에서 빠진 실제 배제 조건을 기록하고 원래 안전 성질을 유지한 채 모델을 수정한다.

## Related Work

[CBRD-27925](https://jira.cubrid.org/browse/CBRD-27925)의 빈 OOS 페이지 회수 과제와 연관되며, [CBRD-26786](https://jira.cubrid.org/browse/CBRD-26786)의 성장 전 회수 요구를 점검한다. [CBRD-27872](https://jira.cubrid.org/browse/CBRD-27872)의 검사 비용 문제와 구분한다. [회수 힌트 소실 후보 CBRD-27944](https://jira.cubrid.org/browse/CBRD-27944)와 연결하되, 힌트를 보존하는 것만으로 이 재귀 할당 경로를 해결했다고 판단하지 않는다.
