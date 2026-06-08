# [SCAN] [조사/설계] Heap/B-Tree Scan Prefetch 매커니즘 검토

## 목적

Heap Scan 및 B-Tree Range Scan 수행 시 발생 가능한 storage I/O 지연을 완화하기 위한 prefetch 매커니즘(prefetch mechanism) 도입 가능성을 검토한다.

본 이슈는 구현 목적이 아닌 조사, 코드 분석, 설계 방향 정리를 위한 기획/제안 이슈이며, 아이디어 검증 및 적용 가능성 분석을 우선 목표로 한다.

## 배경

- 현재 Heap Scan 및 B-Tree Range Scan 은 현재 page 에서 획득한 next page VPID 를 기반으로 다음 page 를 탐색한다.
- 현재 구조는 logical sequential access 형태이나, physical locality 가 충분히 보장되지 않아 buffer miss 발생 시 storage latency 영향이 발생할 수 있다.
- 일부 환경에서는 OS block prefetch/readahead 영향으로 성능 이득이 발생할 수 있으나, 이는 storage layout 및 allocation 상태에 의존적이다.
- 이에 따라 scan path 에 대해 DBMS 내부 prefetch 매커니즘 도입 가능성을 검토한다.

## 기본 아이디어

- Heap 및 B-Tree scan 수행 중 다음 page 정보를 사전에 획득할 수 있다.
- 이를 기반으로 다음 page 를 미리 prefetch 하여 scan 수행 중 I/O latency hiding 가능성을 검토한다.
- Access Method 에 따라 prefetch 정책을 다르게 적용할 수 있는지 함께 검토한다.

예:

- B-Tree Range Scan
  - next leaf page 기반 prefetch
- Heap Full Table Scan
  - allocation bitmap in sector 기반 prefetch 가능성 검토

## 주요 검토 항목

### 1. Scan Path 분석

- Heap Scan / B-Tree Range Scan access pattern 분석
- Current page 기반 next page 예측 가능 범위 확인
- Access Method 별 locality 특성 분석

### 2. Prefetch 적용 가능성 검토

- Scan 중 prefetch 적용 가능 구조 검토
- Access Method 별 정책 차별화 가능성 검토
- OS readahead 와의 중복/상호작용 분석

### 3. Buffer Pool 영향 검토

- Prefetch page 처리 시 buffer replacement policy 영향 분석
- Large scan workload 에서의 buffer pollution 가능성 검토

### 4. Async 실행 구조 검토

- Scan worker 진행을 block 하지 않는 비동기 처리 방식 검토
- 향후 async I/O 확장 가능성 고려

### 5. 검증 시나리오 확보

설계 이전 단계에서 다음 항목에 대한 검증 시나리오를 우선 확보한다.

- OS readahead 영향 분석
- Storage layout/locality 수준별 성능 변화 측정
- Full Table Scan / Index Range Scan workload 비교
- Buffer miss 환경에서의 scan throughput 변화 측정
- Prefetch 효과 측정 가능 지표 정의

## 기대 효과

- Scan path 의 storage latency 완화 가능성 검증
- Access Method 별 prefetch 정책 적용 가능성 확보
- 향후 async I/O 및 allocation 개선과 연계 가능한 기반 확보
- Heap/B-Tree scan 성능 개선 방향성 정리

## 참고 사항

- 현재 CUBRID 는 LRU midpoint insertion 기반 buffer replacement policy 를 사용하고 있으므로, prefetch 적용 시 기존 buffer 정책과의 상호작용을 함께 고려해야 한다.
- 현재 Parallel Scan 은 sector aware scan 기반으로 동작하며, 일정 규모 이상의 scan workload(기본 2048 page 이상, configurable)에 대해 활성화된다. 본 prefetch 아이디어는 Parallel Scan과 중복되지 않도록 하며, 필요 시 상호 보완적으로 동작할 수 있는 방향을 함께 검토한다.
- 본 이슈는 설계 확정 목적이 아닌 조사/검토 단계이며, 상세 정책 및 구현 구조는 후속 설계 이슈에서 구체화한다.
