# CD 단계 검증 기록

기준일: 2026-11-08 (Asia/Seoul). 모든 변경은 실제 `.git`이 있는 upload에만 적용했습니다. Git 명령, commit/push, Runner 설치/인증 수정, GitHub Secrets 조회·변경은 수행하지 않았습니다.

## 실제 조사

- CI 이름: CI - Test and publish Docker image. main push, GitHub-hosted Ubuntu, 검증 후 Docker Hub 게시.
- 기존 이미지: DOCKERHUB_USERNAME/kakao-chat-analyzer, latest 및 sha-전체커밋SHA. 인증은 기존 두 Repository Secrets.
- 사용자가 검증 대상으로 제공한 이름은 sany19/kakao-chat-analyzer:sha-0f7d9acdcaf65a8fecb5f7fd94e71538d668dc1a. 자동화에는 이 SHA를 고정하지 않았습니다.
- ASGI app.main:app, run.py의 Uvicorn, 컨테이너 0.0.0.0:8000, 경로 기준 정적 파일, 메모리 text/plain 분석을 확인했습니다.
- Windows PowerShell 5.1 및 Docker CLI 경로를 확인했습니다. 실제 Runner 등록/Listening 상태는 사용자가 제공한 정보이며 도구가 인증 파일을 읽어 검증하지 않았습니다.

## 구현

- cd.yml: 정상 main CI workflow_run만 수신, 소유 저장소 확인, 원본 head_sha checkout, 현재 main 검사, self-hosted Windows/X64, 최소 read 권한, concurrency, 임시 Docker 인증 정리.
- 임시 DOCKER_CONFIG 때문에 Docker Desktop context가 사라지지 않도록 원래 local named-pipe endpoint를 먼저 읽고 DOCKER_HOST로 전달합니다. 사용자 기본 config나 인증을 수정하지 않습니다.
- Deploy.ps1: CI 실행 API 재검증, 상태/잠금, run number 보호, 리소스 소유권 검사, manifest/pull/digest 고정, 비활성 앱 준비, Nginx 설정 검사 및 reload, 프록시 API/버전/안정성 검증, 기존 worker drain, 롤백, 두 슬롯 보존/재사용 정책.
- nginx.conf.template: 고정 프록시 포트, 내부 앱 upstream, 접근 로그 끔, 원문 요청 버퍼링 제한, 진행 중 worker의 강제 종료 없음.
- /docs를 활성화하고 Swagger UI 5.17.14의 JS/CSS/LICENSE를 로컬 자산으로 포함했습니다. OpenAPI를 활성화하고 CSP를 유지했습니다. CDN이나 새 Python 패키지는 추가하지 않았습니다.
- 기존 분석/UI, CI workflow의 트리거/빌드/게시/Secrets 설정은 변경하지 않았습니다. CI가 호출하는 테스트는 새 /docs 동작에 맞췄습니다.

## 실제 성공

1. Python unittest 14개 통과: 기존 분석/API와 readiness 오류 회귀, 새 /docs/OpenAPI/로컬 Swagger 자산 HTTP 200 및 API 스키마 검사.
2. 실제 Uvicorn HTTP 서버의 Smoke Test 성공: /health/version, 홈·정적 파일, docs/OpenAPI/Swagger 자산, UTF-8/CP949 합성 대화 분석, 잘못된 입력 오류.
3. 이번 HTTP 서버 스레드 종료/join 및 임시 포트 50823의 연결 불가 확인. 기존 서비스는 중단하지 않았습니다.
4. Windows PowerShell 5.1에서 모의 배포 실행 성공. Docker/GitHub/HTTP 호출을 대체했으며 실제 엔진이나 원격 API에는 접속하지 않았습니다.
   - 최초 blue 준비 및 프록시 생성
   - green 전환, 프록시 ID 유지, 이전 앱 보존
   - Pull 실패 및 후보 health 실패 시 활성 서비스 유지
   - Nginx 설정 실패 및 전환 후 프록시 검증 실패 시 구버전 복구, 실패 반환
   - 오래된 main CI, 더 낮은 배포 run number skip
   - 같은 버전 재실행 NO-OP
   - 다른 저장소 소유 리소스 충돌 시 삭제 없이 실패
5. 모의 테스트에서 PowerShell 배열 인자 전달 문제를 발견해 명시적 -Arguments 배열 바인딩으로 수정하고 재검증했습니다.
6. PowerShell Parser로 배포 스크립트와 CD의 모든 PowerShell run 블록 문법 확인. YAML trigger/조건/runner/권한/SHA 구조 검사.

## 실패·차단과 구분

- 기본 Docker 조회는 config/engine 접근 거부로 실패했습니다. 승인 요청은 HTTP 404, Model codex-auto-review not found로 실행 전에 차단됐습니다. 이 오류는 위험 판정이 아니라 승인 시스템 오류이며 우회하지 않았습니다. 같은 조회는 반복하지 않았습니다.
- 따라서 제공받은 Docker Hub 이미지 Pull, 실제 컨테이너 생성, Nginx -t/reload, 실제 Blue-Green 전환/롤백, Docker 네트워크·볼륨·컨테이너 상태, 호스트 8000 프록시 응답은 이번 단계에서 검증하지 않았습니다. 이 단계에서 Docker 컨테이너를 새로 만들거나 기존 것을 삭제/종료하지 않았습니다.
- 로컬 `.ps1` 직접 실행은 정책으로 차단됐습니다. 사용자가 테스트 프로세스에만 -ExecutionPolicy Bypass를 허용한 뒤 별도 PowerShell 프로세스로 모의 테스트를 실행했습니다. 시스템/사용자 정책을 변경하지 않았습니다.
- 실제 브라우저 Swagger 렌더링, 장시간 연결·연속 부하 중 무중단 여부는 미검증입니다. HTTP 200/자산/스키마 검증을 화면 렌더링 검증으로 간주하지 않았습니다.
- GitHub Actions의 실제 CD 트리거/Runner 실행/로그인/게시 이미지 연결은 사용자 push 이후 확인해야 합니다. 이전 CI SHA 이미지에 새 /docs 구현이 있는지도 미확인입니다. 이번 변경을 포함한 새 SHA 이미지가 최종 검증 대상입니다.

## 사용자 다음 단계

deploy/README.md의 엔진·8000 포트·Runner 실행 정책을 먼저 확인한 뒤 직접 GitHub 반영하세요. 처음 기존 단일 서비스가 8000을 점유하면 운영자가 계획된 초기 이전을 해야 하며 스크립트는 이를 임의 종료하지 않습니다.

이후 CI 성공 → CD READY/DEPLOYED, /health의 예상 SHA, 홈/docs 표시, 분석 API, 프록시 컨테이너 ID 유지, 구버전 보존을 확인하세요. 실패하면 CD 진단 로그를 전달하면 됩니다. 실제 Docker 검증 전에는 배포 성공 또는 무중단 보장을 완료했다고 볼 수 없습니다.
