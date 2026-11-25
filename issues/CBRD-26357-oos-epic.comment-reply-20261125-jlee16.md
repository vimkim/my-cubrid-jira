[~jlee16] JOB 측정과 플랜 분석 감사합니다. 분석하신 대로 쿼리 실행 자체의 회귀는 없고, 저장 구조가 바뀌며 히스토그램 표본이 달라진 데 따른 플랜 변화로 보여 OOS 쪽에서 따로 이슈를 만들지는 않겠습니다.

- HEAP 파일 수(55 → 56)를 `cubrid spacedb` 로 세셨다면, 늘어난 1개는 `movie_info` 에 새로 생긴 OOS 파일입니다. `spacedb` 는 OOS 파일을 별도 항목 없이 HEAP에 합쳐 보여 줍니다(`src/storage/file_manager.c` 의 `FILE_OOS` case, 출력 형식을 유지하려는 의도된 동작).
