# 대화의 온도 — 카카오톡 대화 분석

한국어 카카오톡 TXT를 업로드하거나 붙여넣으면 메시지·참여자·시간대·단어·대화 개시·응답 시간 통계를 시각화하는 FastAPI 서비스입니다. 대화는 메모리에서만 처리하며 원문과 결과를 영구 저장하지 않습니다.

## 프로젝트 루트와 구성

이 README와 `.git`이 있는 **upload 폴더가 실제 개발 저장소의 루트**입니다. 상위 폴더는 이전 과제 보관용이며 빌드·테스트에 필요하지 않습니다. 아래 모든 명령은 이 README가 있는 폴더에서 실행합니다.

```text
.
├── .github/workflows/ci.yml  # main push → 테스트 → 빌드 → 검증 → Docker Hub
├── app/
│   ├── __init__.py
│   ├── main.py              # ASGI 객체 app, API 및 정적 파일 제공
│   └── analysis.py          # 파서와 통계
├── static/                  # index.html, style.css, app.js
├── tests/
│   ├── test_service.py      # 합성 데이터 기반 unittest + FastAPI TestClient
│   ├── smoke.py             # 실제 서버/컨테이너 HTTP 검증 (표준 라이브러리)
│   └── verify_docker.ps1    # 사용자가 실행하는 Docker 전체 검증·정리 스크립트
├── Dockerfile
├── .dockerignore
├── .gitignore
├── requirements.txt         # 실행 의존성 및 전이 의존성 버전 고정
├── requirements-dev.txt     # API 테스트용 httpx
├── run.py
├── CI_VALIDATION.md         # 이번 단계의 실제 검증 결과와 한계
└── README.md
```

## 기능과 기술 스택

- 한국어 PC/모바일 TXT, UTF-8(BOM 포함)/CP949, 최대 5 MiB
- 여러 줄 메시지, 사용자별 메시지 수와 참여 비율, 날짜·요일·시간대 분포
- 단어와 연속 두 단어 표현, 30/60/180분 공백 기준 대화 개시
- 직전의 다른 발신자 기준 응답 시간 중앙값·평균
- 반응형 HTML/CSS/JavaScript 대시보드, 외부 CDN 없는 DOM/CSS 그래프
- Python 3.12, FastAPI 0.115.12, Uvicorn 0.34.2; 통계는 표준 라이브러리 사용

응답 통계는 실제 답장 대상이나 읽은 시간을 알 수 없는 추정치입니다. 단어는 단순 토큰 집계이며 형태소/감정 분석이 아닙니다. 동명이인은 합산되고 내보내기 구조와 동일한 본문은 오인할 수 있습니다. UTF-16·CSV·영문 UI 내보내기는 지원하지 않습니다.

## Python 로컬 설치·실행

Python 3.12를 설치한 뒤 PowerShell에서 실행합니다. 가상환경 활성화나 실행 정책 변경은 필요하지 않습니다.

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.\.venv\Scripts\python.exe -m pip check
.\.venv\Scripts\python.exe -m unittest discover -s tests -p "test_*.py" -v
.\.venv\Scripts\python.exe run.py
```

서비스 실행만 필요하면 `requirements-dev.txt` 대신 `requirements.txt`를 설치하세요. 브라우저에서 **http://127.0.0.1:8000** 접속 후 `가상 데이터 체험`으로 확인합니다. 서버 종료는 **Ctrl+C**입니다.

Linux/macOS는 `python3 -m venv .venv` 후 `.venv/bin/python`으로 같은 명령을 실행합니다. ASGI 객체는 `app.main:app`이며 `run.py`는 Uvicorn을 실행합니다. 정적 파일 위치는 `app/main.py` 위치를 기준으로 계산되므로 로컬 절대 경로가 필요하지 않습니다.

## API와 배포 버전

| 경로 | 동작 |
| --- | --- |
| `GET /` | 웹 화면 |
| `GET /static/style.css`, `/static/app.js` | 정적 파일 |
| `GET /health` | HTTP 200, `{"status":"ok","version":"..."}` |
| `GET /api/health` | 기존 호환 경로, `{"status":"ok"}` 유지 |
| `POST /api/analyze` | `Content-Type: text/plain` 요청 본문으로 분석 |
| `GET /docs` | 기존 설정 유지: Swagger 비활성화로 HTTP 404 |

파일 업로드도 multipart 임시파일 대신 TXT 파일 바이트를 `text/plain` 본문으로 전송합니다. `session_minutes=30`, `60`, `180` 쿼리 옵션을 지원합니다. 잘못된 형식은 422, 잘못된/빈 텍스트는 400, 크기 초과는 413, 지원하지 않는 Content-Type은 415를 반환합니다.

| 환경 변수 | 기본값 / 용도 |
| --- | --- |
| `HOST` | 로컬 `127.0.0.1`, 이미지 기본값 `0.0.0.0` |
| `PORT` | `8000` |
| `APP_VERSION` | 로컬 `local`; 이미지 빌드 인자 또는 컨테이너 환경 변수로 설정 |

`APP_VERSION`은 프로세스 시작 시 읽으며 `/health`에 그대로 표시됩니다. 비밀정보를 넣지 마세요. CI에서는 `sha-<전체 40자리 커밋 SHA>`를 빌드 인자로 전달해 이미지 안에 기본값으로 기록합니다. 실행 시 `-e APP_VERSION=...`으로 바꿀 수 있지만 실제 이미지 버전과 달라질 수 있으므로 운영에서는 CI가 이미지에 기록한 값을 그대로 사용하는 것을 권장합니다. `/health`는 애플리케이션 응답 확인이며 DB 등 외부 의존성은 없습니다.

예를 들어 구버전과 신버전을 서로 다른 로컬 포트에 실행한 경우 다음 응답의 `version`을 비교합니다.

```powershell
Invoke-RestMethod http://127.0.0.1:18080/health
Invoke-RestMethod http://127.0.0.1:18081/health
```

이는 후속 CD/Blue-Green 검증을 위한 인터페이스이며 이번 단계에는 전환·재배포 로직이 없습니다.

## Docker 이미지 빌드와 로컬 검증

Docker Desktop을 Linux Containers 모드로 실행합니다. 공식 `python:3.12.12-slim-bookworm` 이미지와 고정된 Python 패키지를 사용합니다. 컨테이너는 비루트 UID 10001로 Uvicorn을 실행하고 기본 `0.0.0.0:8000`에서 수신합니다. OS 패키지 태그는 갱신될 수 있으므로 장기적인 바이트 단위 재현까지 필요하면 검증한 베이스 이미지 digest도 고정·갱신해야 합니다.

```powershell
docker version
docker build --build-arg APP_VERSION=local-check -t kakao-chat-analyzer:local-check .
docker run -d --name kakao-local-check -p 127.0.0.1:18080:8000 kakao-chat-analyzer:local-check
Invoke-RestMethod http://127.0.0.1:18080/health
.\.venv\Scripts\python.exe tests/smoke.py http://127.0.0.1:18080 local-check
docker inspect --format '{{.State.Health.Status}}' kakao-local-check
docker logs kakao-local-check
```

브라우저 주소는 **http://127.0.0.1:18080** 입니다. 18080 포트 또는 해당 컨테이너 이름이 사용 중이면 새 이름/포트를 선택하세요. Docker HEALTHCHECK는 15초 간격으로 `/health`를 확인하며 초기에는 `starting`일 수 있습니다. 충분히 기다린 뒤 `healthy`를 확인합니다. 검증이 끝나면 **본인이 만든 테스트 컨테이너만** 정리합니다.

```powershell
docker rm -f kakao-local-check
```

`.dockerignore`는 허용 목록 방식입니다. 실행 소스 8개 파일과 requirements만 전송하고 `.git`, `.venv`, `.env`, 비밀 키, 대화 TXT, 테스트, 로그, 캐시, 스크린샷과 README를 빌드 컨텍스트에서 제외합니다. Dockerfile도 필요한 파일만 COPY합니다. 실제 원문을 소스의 지정된 Python/HTML 파일에 삽입하지 마세요. 새 런타임 파일을 추가하면 Dockerfile과 `.dockerignore`도 함께 갱신해야 합니다.

## GitHub Actions CI 구조

`.github/workflows/ci.yml`의 표시 이름은 **CI - Test and publish Docker image**입니다. `main` 브랜치 push에만 반응하며 Pull Request 이벤트, self-hosted runner, CD는 설정하지 않았습니다. GitHub-hosted `ubuntu-24.04`를 사용하고 GitHub 토큰 권한은 `contents: read`로 제한합니다.

1. 소스 checkout(자격정보 유지 끔), Python 3.12.12 준비
2. `requirements-dev.txt` 설치, 의존성 검사 및 합성 데이터 API/파서 테스트
3. Buildx로 이미지를 한 번 빌드해 로컬 runner에 load (아직 push 안 함)
4. 같은 이미지로 컨테이너 실행 → `/health`의 커밋 버전, 홈/정적 파일, UTF-8/CP949 분석, 오류 응답, `/docs` 404 검사
5. Docker HEALTHCHECK가 `healthy`인지 확인 후 테스트 컨테이너 정리
6. 앞 단계가 성공한 경우에만 Docker Hub 로그인
7. 검증한 같은 로컬 이미지에 SHA/latest 태그를 붙이고 순서대로 push

테스트·빌드·HTTP 검증·HEALTHCHECK 중 실패하면 정상 실행 경로의 로그인/push 단계가 건너뛰어져 게시하지 않습니다. 실패 시 컨테이너 로그를 표시하고 정리는 `always()`로 시도합니다. 게시 중 레지스트리/네트워크 오류가 나면 CI가 실패하며, 두 태그의 push는 원자적이지 않아 SHA 태그만 먼저 올라갈 수 있습니다. 최종 성공 여부는 Actions 로그와 Docker Hub를 함께 확인하세요. 동일 브랜치의 게시 작업은 concurrency 그룹으로 동시 실행을 제한합니다.

공식 릴리스 조회 후 사용한 버전:

- `actions/checkout@v7.0.1`
- `actions/setup-python@v7.1.0`
- `docker/setup-buildx-action@v4.4.1`
- `docker/build-push-action@v7.4.0`
- `docker/login-action@v4.8.0`

## Docker Hub 저장소·태그·Secrets

이미지 이름: **`<DOCKERHUB_USERNAME>/kakao-chat-analyzer`**

| 태그 | 의미 |
| --- | --- |
| `sha-<전체 github.sha>` | 특정 커밋의 이미지 선택용 고유 태그 |
| `latest` | 가장 최근에 게시를 마친 정상 이미지; 가변 태그 |

후속 CD에서는 `latest` 대신 성공한 CI의 SHA 태그를 선택하세요. SHA 태그도 Docker Hub 설정상 덮어쓰기가 가능한 태그이므로 더 강한 불변성이 필요하면 저장소의 immutable tag 정책 또는 이미지 digest를 사용하세요.

기존 Repository Secrets 이름을 그대로 사용합니다.

- `DOCKERHUB_USERNAME`: Docker Hub 사용자명/이미지 namespace
- `DOCKERHUB_TOKEN`: 해당 namespace의 이미지 push 권한이 있는 Docker Hub access token

GitHub 저장소 **Settings → Secrets and variables → Actions → Repository secrets**에서 두 이름이 있는지만 직접 확인하세요. 기존 값은 UI에서 읽을 수 없으며 값을 소스/로그/대화에 붙여넣을 필요가 없습니다. Docker Hub에 해당 이름의 저장소를 직접 준비하고 토큰의 Write 권한과 namespace 일치를 확인하세요. 계정 설정이나 레지스트리 게시 권한은 로컬 테스트만으로 확인할 수 없습니다.

## 직접 GitHub에 반영할 명령

이미 `.git`이 존재하므로 다시 init하거나 remote를 변경하지 않습니다. 이 README가 있는 upload 폴더에서 현재 브랜치가 main인지 확인한 뒤 직접 실행하세요. 다른 브랜치라면 본인의 병합 절차를 적용하세요.

```powershell
git status
git branch --show-current
git add app/main.py requirements.txt requirements-dev.txt Dockerfile .dockerignore .github/workflows/ci.yml tests/test_service.py tests/smoke.py tests/verify_docker.ps1 README.md CI_VALIDATION.md
git diff --cached --stat
git diff --cached
git commit -m "Add Docker packaging and verified Docker Hub CI"
git push origin main
```

명령은 사용자 실행용 안내이며 개발 도구가 Git 명령, commit, push를 수행하지 않았습니다. push 후 GitHub **Actions**에서 각 단계의 성공을 확인하고 Docker Hub **Tags**에서 SHA/latest가 게시되었는지 직접 확인하세요. 첫 원격 CI와 Docker Hub push 자체는 로컬 실행으로 대체 검증할 수 없습니다.

## 개인정보·운영 범위

원문·참여자·파일명을 서버 로그에 기록하지 않고 Uvicorn 접근 로그도 끕니다. 파일/DB/브라우저 저장소를 사용하지 않지만 프로세스 메모리의 암호학적 즉시 소거를 보장하지는 않습니다. 결과에는 이름과 단어가 포함될 수 있으므로 공유 전 확인하세요. 로컬에서는 로컬 서버로, 배포 후에는 배포 서버로 대화가 전송됩니다. 테스트에는 합성 데이터만 사용합니다.

공개 운영 시 HTTPS, 접근 제어와 전체 동시 요청/요청 빈도 제한은 운영 환경에서 별도로 준비하세요. 이번 단계는 Docker 패키징과 CI까지이며 GitHub Secrets 변경, 원격 업로드, self-hosted runner, 클라우드 배포, CD workflow, Blue-Green 전환은 수행하지 않습니다.

## 아직 필요한 수동 검증 (승인 시스템 오류 이후)

로컬 Docker 이미지는 실제 빌드되었으나 승인 시스템의 HTTP 404 오류로 이후 Docker 상태 조회/HTTP 검사/정리는 실행하지 못했습니다. GitHub Actions의 원격 실행과 Docker Hub push도 아직 수행하지 않았습니다. 실제 결과 구분은 `CI_VALIDATION.md`를 확인하세요.

이번에 먼저 생성한 컨테이너는 사용자가 직접 정리하기로 했습니다. 아래 명령은 해당 이름의 검증용 컨테이너 하나만 제거합니다.

```powershell
docker rm -f kakao-hw2-ci-check-20261108
```

이후 저장소 루트에서 다음 스크립트를 직접 실행하면 새 임시 컨테이너를 생성해 빌드·HTTP·버전·분석 API·정적 파일·HEALTHCHECK·의존성·이미지 파일·비루트 실행을 검사하고, finally에서 자신이 생성한 컨테이너만 정리합니다. 시스템의 실행 정책을 변경하지 않으며 조직 정책 때문에 스크립트가 차단되면 앞의 개별 Docker 명령을 사용하세요. 이미지와 빌드 캐시는 남겨 두며 push하지 않습니다.

```powershell
.\tests\verify_docker.ps1
```

이 스크립트는 작성 및 PowerShell 문법 검사만 했고 Docker 실행 검증은 아직 하지 않았습니다. 출력 결과를 전달하면 실패 원인과 다음 단계를 분석할 수 있습니다.

별도 Python HTTP 테스트는 통과했으나 Windows 가상환경 런처를 종료한 뒤 자식 서버까지 종료됐는지는 확인되지 않았습니다. 프로세스 조회도 승인 오류로 차단되어 PID를 확정하지 못했습니다. 다른 서비스를 종료하지 않도록 먼저 아래 출력에서 이번 테스트 시각과 upload 가상환경의 `-B run.py` 명령을 확인하고, 확인한 PID만 종료하세요. 확실하지 않으면 조회 결과만 전달해 주세요.

```powershell
Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
    Where-Object { $_.CommandLine -match '-B run.py' } |
    Select-Object ProcessId, ParentProcessId, CommandLine, CreationDate
# 이번 검증에서 생성된 서버 PID를 확인한 후에만:
# Stop-Process -Id <확인한_PID>
```

Git에 반영할 때 위 기본 파일 목록에 `tests/verify_docker.ps1`도 포함하세요. GitHub Actions에서는 이 PowerShell 스크립트 대신 Linux runner의 빌드/검증 단계를 사용합니다.
