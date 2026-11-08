# Docker/CI 검증 기록

작업 기준일: 2026-11-08 (Asia/Seoul). Git 명령·commit·push·시크릿 변경·레지스트리 게시·CD는 수행하지 않았습니다.

## 조사와 변경 범위

- 실제 저장소는 이 문서가 있는 upload 폴더이며 `.git` 디렉터리의 존재를 확인했습니다. Git 명령으로 저장소 상태를 조회하지 않았습니다.
- 변경 전 app 3개, static 3개, run.py, requirements.txt 총 8개 파일을 보관 원본과 해시 비교했으며 모두 동일했습니다.
- 보관 원본에만 있는 테스트/검증 자료는 필수 런타임 파일이 아니어서 복사하지 않았습니다. 이번 테스트는 upload 안에서 새로 작성했습니다.
- ASGI는 app.main:app, 실행기는 run.py이며 정적 경로는 소스 위치 기준입니다. API는 text/plain 요청 본문을 메모리에서 처리합니다.
- 기존 분석/UI는 수정하지 않았습니다. app/main.py에는 APP_VERSION과 GET /health만 추가했습니다. 기존 /api/health 및 /docs 404 설정은 유지했습니다.
- 상위 보관용 코드는 수정하지 않았습니다. 모든 신규 파일과 전용 .venv는 upload 안에 있습니다.

## 실제 성공한 항목

1. Docker Desktop의 Linux 엔진 확인: Engine 29.9.2, linux/amd64.
2. `docker build --build-arg APP_VERSION=local-ci-check -t kakao-chat-analyzer:local-ci-check .` 성공 (exit 0).
   - 공식 python:3.12.12-slim-bookworm을 실제 내려받음.
   - 고정된 런타임 패키지를 Linux Python 3.12에 설치 성공.
   - Dockerfile 전체 단계와 이미지 내보내기 완료.
   - 로컬 이미지 manifest list: sha256:1fc48c257cd040a642beb4c472d6c736799d6bd8ea0581eeb47ec8be7028ad70.
3. 검증용 컨테이너 생성 명령 exit 0. 이름: kakao-hw2-ci-check-20261108. ID: 1bb9d16acf2b153e6b8ee7e72882ad516995b429bb8512dd0bd0b234848e1114. 이후 상태는 미조회.
4. upload 전용 새 .venv에 requirements-dev.txt 설치 및 pip check 성공.
5. `APP_VERSION=local-unit-check`에서 unittest 7개 모두 통과.
   - PC/모바일, 여러 줄, 응답 중앙값, 참여 비율, 시간대 합계, 세션 임계값
   - UTF-8 BOM/CP949, 5 MiB 초과, 빈/잘못된 형식과 인코딩, Content-Type 오류
   - /health의 상태·버전, 기존 /api/health, 홈/정적 파일, /docs 404, 캐시/보안 헤더
6. 별도 로컬 Python HTTP 서버에서 tests/smoke.py 성공.
   - /health의 local-http-check 버전, 홈/정적 파일, /docs 404, UTF-8/CP949 분석 및 오류 응답 확인.
   - 이 성공은 Docker 컨테이너의 응답 검증을 의미하지 않습니다.
7. PyYAML로 YAML 문법을 읽고 main push 전용, hosted Ubuntu, contents:read, SHA 태그와 검증 이후 게시 순서를 정적 확인.
8. 공식 GitHub 공개 릴리스 API 및 각 action.yml을 읽어 Actions 버전, node24 런타임과 사용한 입력 옵션 존재를 확인. 계정 인증정보는 사용하지 않음.
9. tests/verify_docker.ps1을 PowerShell Parser로 문법 검사 성공. 최종 Python 소스 AST 및 YAML 문법도 통과. 스크립트의 Docker 실행은 미수행.

## 차단 또는 미완료

- Docker 후속 명령(포트/HEALTHCHECK 조회, pip check, 이미지 내부 파일 확인)은 실행 전 자동 승인 검토 시스템 오류로 차단되었습니다.
- 오류: HTTP 404, `Model 'codex-auto-review' not found`. 명령이 위험하다는 판정이 아니라 승인 시스템 실패입니다. 승인 우회는 하지 않았습니다.
- 따라서 컨테이너 안의 /health, /, /docs, 분석 API, 정적 파일, 비루트 실행, 이미지 파일 허용 목록, Docker HEALTHCHECK는 아직 실행 검증하지 않았습니다.
- 사용자에게 컨테이너 정리를 요청했고 사용자가 직접 수행하겠다고 답했습니다. 도구가 종료/삭제했다고 보고하지 않습니다.
- Windows .venv Python 런처 종료만으로 자식 서버가 종료되지 않는 문제가 관측되었습니다. HTTP 테스트 후 종료 확인에서 TCP 연결이 남아 있었으며, 포트 bind 검사도 실패했습니다. 조회 권한/승인 시스템 오류로 자식 PID를 확정하지 못했습니다. 로컬 테스트 서버의 완전한 종료·포트 해제도 미확인입니다. README의 안전한 PID 조회/선별 종료 안내를 참조하세요.
- GitHub Actions 서버에서의 워크플로 실행, 저장소 Secrets의 존재/값/권한, Docker Hub 로그인/push, SHA/latest의 원격 동일 이미지 여부는 사용자 push 이후 확인해야 합니다.
- actionlint나 GitHub 측 전체 workflow 검증은 실행하지 않았습니다. PyYAML과 구성 조건, 공식 action.yml만 정적으로 확인했습니다.

## 사용자 검증 순서

1. 본인이 정리하기로 한 기존 검증용 컨테이너 하나를 제거합니다.
2. README의 PID 조회 결과에서 이번 Python 테스트 서버만 확인해 종료합니다. 불확실하면 결과를 전달해 분석을 요청하세요.
3. `tests/verify_docker.ps1`을 직접 실행하고 결과를 확인합니다. 스크립트는 새 고유 이름과 임시 포트를 사용하며 자기 컨테이너만 정리합니다. Docker 실행 검증 전이므로 오류가 나면 출력 그대로 전달하세요.
4. 정상 확인 후 직접 Git commit/push합니다.
5. GitHub Actions 각 단계, Docker Hub SHA/latest 태그와 권한을 확인합니다. 이 단계가 완료돼야 원격 CI 게시 성공이라고 볼 수 있습니다.

## Readiness 수정 후 검증 (2026-11-08)

이 항목은 위 초기 구축 기록 이후의 수정 결과입니다. Git 명령과 Docker 작업은 이번 수정에서 실행하지 않았습니다. 기존 승인 시스템 오류와 사용자 지침에 따라 Docker 검증은 수동 실행 절차를 유지합니다.

### 발견한 사실과 원인 판단

- 기존 CI는 `docker run -d` 바로 뒤 Smoke Test를 실행하고, Docker HEALTHCHECK 대기는 그 뒤에 있었습니다.
- 기존 smoke의 재시도는 URLError/TimeoutError만 처리하므로 직접 발생하는 ConnectionResetError는 즉시 실패했습니다. 해당 예외를 주입한 회귀 테스트로 수정 후 재시도 성공을 확인했습니다.
- Dockerfile HOST=0.0.0.0, PORT=8000, run.py의 환경 변수 사용, CI의 127.0.0.1:8000:8000 매핑은 정적으로 일치합니다.
- 오류가 실제 Uvicorn 시작 경쟁인지 컨테이너 crash/리소스 오류인지는 당시 실행 로그가 없으므로 미확정입니다. 포트 설정 오류의 증거도 현재 파일에서는 발견하지 못했습니다.

### 변경

- tests/wait_ready.py: 최대 30회, 요청당 3초, 간격 1초. 실제 HTTP 200 + status/version 검사. 연결 리셋/거절/타임아웃/HTTP 전송 오류 재시도. 한도 초과 시 실패와 원인 예외 보존. JSON/버전 오류는 즉시 실패.
- tests/smoke.py: 공통 readiness 사용. UTF-8/CP949 분석 및 응답 시간, 정적 파일, 기존 health와 /docs 404 검사 유지. HTTPError 응답 자원 해제.
- ci.yml: Smoke 전에 독립 Readiness 단계. 실패 시 docker ps -a, State/Healthcheck 이력, 포트, 최근 로그를 정리 전에 출력. 실패하면 로그인/push는 건너뜀.
- tests/test_readiness.py: 연결 리셋→503→성공, 연결 끊김/타임아웃/거절, 한도 초과, 버전 오류, 잘못된 JSON, 비200 응답, 실제 HTTP 503→200을 검증.
- Dockerfile, run.py, app 코드, 기존 Secrets와 분석/UI는 변경하지 않았습니다.

### 실제 로컬 결과

- unittest 14개 모두 통과 (기존 서비스 7 + readiness 7). ResourceWarning을 오류로 설정한 재실행에서도 경고 없이 통과.
- 실제 Uvicorn/FastAPI를 같은 Python 프로세스 안의 제어 가능한 서버 스레드로 실행하고 Smoke Test 통과: /health/version, 홈/정적 파일, /docs 404, UTF-8/CP949 분석, 잘못된 입력 422.
- 이번에 생성한 Uvicorn 스레드와 HTTP 테스트 서버를 종료·join하고, Uvicorn 테스트 포트 51839에 더 이상 TCP 연결이 되지 않음을 확인. 초기 구축 때 남았을 가능성이 있는 별도 프로세스의 상태까지 확인한 것은 아닙니다.
- YAML 파싱 및 단계 순서·실패 진단·권한·실행 조건 정적 검사 결과는 아래 최종 검사로 확인.

### 남은 확인

- Docker 컨테이너에서의 재현/수정 후 성공과 GitHub Actions 원격 실행은 미검증입니다. 이번 변경은 테스트 도구/CI만 변경하여 이미지의 서비스 코드는 기존과 동일합니다.
- 사용자가 push한 후 Readiness의 READY 로그(HTTP 200, 예상 SHA 버전), Smoke PASS, Docker healthy, 로그인/push 순서와 Docker Hub 태그를 확인해야 합니다.
- 실패 시 진단 그룹의 컨테이너 State 및 Uvicorn 로그를 전달하면 crash/포트/시작 경쟁 여부를 추가 판별할 수 있습니다.
