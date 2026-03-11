## 검증을 위해 사용할 벡터 데이터 셋 조사

- 보편적으로 사용되고 있는 벡터 데이터 셋이 있는지 조사

### Major

- SIFT
- GIST
- Cohere
- openai hugging face

### Minor

- DEEP1B
- Fashion-MNIST
- GloVe
- Kosarak
- MNIST
- MovieLens-10M
- NYTimes
- Sift
- Last.fm

#### 출처

- 질리즈의 벡터 벤치마크
  - [GitHub - zilliztech/VectorDBBench: VectorDBBench is a benchmark designed to compare the performance and cost-effectiveness of popular vector databases.](https://github.com/zilliztech/VectorDBBench)
- 에릭번 프로젝트
  - [GitHub - erikbern/ann-benchmarks: Benchmarks of approximate nearest neighbor libraries in Python](https://github.com/erikbern/ann-benchmarks)

## 데이터 특성이 있다면 같이 정리

    - ex) csv, json, binary format 등

- fvecs: <https://github.com/kshard/fvecs>
- HDF5

## 타 벤더(ex) pgvector)의 데이터 로딩 방법 조사

- pgvector - binary copy 로드
- oracle - fvecs 로드

## 벡터 데이터 제공 포맷에 맞게 데이터 로딩 방안 정리

- 1안. fvecs 로더 설계 (채택)
- 2안. fvecs와 HDF5를 csv로 변환 후 csv 로딩
