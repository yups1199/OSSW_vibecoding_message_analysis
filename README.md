# 대화의 온도 — 카카오톡 대화 분석

카카오톡에서 내보낸 한국어 TXT 파일을 업로드하거나 텍스트를 붙여넣으면 대화 통계를 보여 주는 웹 애플리케이션입니다. 데이터베이스 없이 메모리에서만 분석하며 대화 원문과 결과를 영구 저장하지 않습니다. 대학교 오픈소스 SW 개발 과제로 개발했습니다.

## 주요 기능

- 한국어 카카오톡 PC/모바일 TXT 및 여러 줄 메시지 파싱
- UTF-8(BOM 포함) / CP949, 최대 5 MiB 입력
- 전체·사용자별 메시지 수, 참여 비율, 날짜·요일·시간대별 분포
- 자주 사용하는 단어와 연속 두 단어 표현
- 30/60/180분 공백 기준 대화 개시 횟수
- 직전의 다른 발신자 메시지 기준 응답 시간의 중앙값·평균
- 반응형 대시보드와 막대그래프, 가상 데이터 체험, 입력·결과 지우기
- 잘못된 입력 안내, 요청 크기 제한, 기본 로깅과 보안 헤더

응답 대상과 읽은 시간은 알 수 없으므로 응답 통계는 추정치입니다. 단어 통계는 단순 토큰 집계이며 형태소·감정 분석이 아닙니다. UTF-16, 영문 UI 내보내기, CSV 등은 지원하지 않습니다. 동명이인은 같은 사람으로 집계되며 본문이 날짜/메시지 패턴과 일치하면 오인할 수 있습니다.

## 기술 스택과 구조

Python 3.12 권장(Windows 11 / Python 3.12.2에서 검증), FastAPI 0.115.12, Uvicorn 0.34.2, HTML/CSS/JavaScript를 사용합니다. 통계는 Python 표준 라이브러리, 그래프는 DOM/CSS로 구현하여 외부 CDN이나 별도 프론트엔드 빌드가 필요하지 않습니다.

```text
.
├── app/
│   ├── __init__.py
│   ├── main.py          # API, 입력 검증, 오류 처리
│   └── analysis.py      # 파서와 통계
├── static/
│   ├── index.html
│   ├── style.css
│   └── app.js
├── run.py              # HOST/PORT에 따라 서버 실행
├── requirements.txt    # 서비스 의존성
├── .gitignore
└── README.md
```

## 설치 및 로컬 실행

저장소를 ZIP으로 내려받아 압축을 풀거나 다음 명령을 직접 실행합니다. `<...>` 부분은 본인의 값으로 바꾸세요.

```powershell
git clone https://github.com/<GITHUB_USERNAME>/<REPOSITORY_NAME>.git
cd <REPOSITORY_NAME>
python --version
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe run.py
```

프로젝트 루트(이 README와 run.py가 있는 폴더)에서 실행하세요. 가상환경을 활성화하지 않고 직접 실행하므로 PowerShell 실행 정책을 바꿀 필요가 없습니다. 기존 시스템 Python 패키지는 변경하지 않습니다.

브라우저에서 **http://127.0.0.1:8000** 에 접속합니다. `가상 데이터 체험` → `대화 분석하기`로 실제 개인정보 없이 확인할 수 있습니다. 서버 종료는 실행한 터미널에서 **Ctrl+C**입니다.

포트가 사용 중이면 다른 포트를 지정합니다.

```powershell
$env:PORT = '8080'
.\.venv\Scripts\python.exe run.py
```

이 경우 http://127.0.0.1:8080 에 접속합니다. 환경 변수는 현재 PowerShell 세션에 적용되며 `$env:PORT = $null`로 해제할 수 있습니다.

Linux/macOS:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python run.py
```

## GitHub에 직접 업로드하기

다음은 사용자가 직접 수행할 절차입니다. 이 프로젝트 준비 과정에서는 Git 명령어를 실행하지 않았습니다.

1. GitHub에서 빈 저장소를 생성합니다. 아래 절차를 쓰려면 README, .gitignore, 라이선스를 자동 생성하지 마세요. 기존 커밋이 있는 저장소에는 별도 병합 절차가 필요합니다.
2. 배포 폴더의 내용이 저장소의 루트가 되도록 합니다. 즉 GitHub 최상위에 `run.py`, `requirements.txt`, `app/`, `static/`가 있어야 합니다. `upload/`라는 상위 폴더를 그대로 한 겹 더 올리지 마세요.
3. 아래 명령은 **이 README가 있는 upload 폴더 안에서** 직접 실행하세요. Git 사용자 정보와 인증은 본인의 Git/GitHub 설정을 사용합니다.

```powershell
git init
git branch -M main
git add .
git status
git diff --cached --stat
git commit -m "Initial KakaoTalk analysis web app"
git remote add origin https://github.com/<GITHUB_USERNAME>/<REPOSITORY_NAME>.git
git push -u origin main
```

커밋 전에 staged 목록을 확인해 원문·인증정보가 없는지 살펴보세요. `.gitignore`는 모든 개인정보 파일을 자동 탐지하지 않으므로 실제 대화 파일을 소스 폴더에 넣지 마세요. ZIP 다운로드/웹 업로드 방식이면 파일 내용과 폴더 구조를 동일하게 유지하고 숨김 파일 `.gitignore`도 포함하세요.

이후 사용자가 수정 사항을 배포할 때:

```powershell
git add .
git diff --cached --stat
git commit -m "Update application"
git push
```

## GitHub 연동 클라우드 자동 배포

GitHub와 연결되는 Python Web Service 유형의 플랫폼에서 실행할 수 있습니다. **Render의 GitHub 연동 Web Service**를 설정 예시로 안내합니다. 플랫폼을 확정하거나 계정을 연결하거나 실제 배포하지는 않았습니다. 무료 플랜/체험 크레딧의 제공 여부, 카드 요구, 만료 조건은 가입 시 공식 요금 페이지에서 확인하세요. 무료 서비스는 유휴 시 중단되거나 첫 요청에 시간이 걸릴 수 있습니다.

참고: [Render Python/FastAPI 배포 문서](https://render.com/docs/deploy-fastapi), [요금](https://render.com/pricing), [무료 서비스 제한](https://render.com/docs/free).

1. GitHub 업로드 완료 후 플랫폼에 직접 로그인하고 GitHub 계정을 연결합니다. 필요한 저장소에만 접근 권한을 부여합니다.
2. 새 **Web Service**를 만들고 저장소 및 `main` 브랜치를 선택합니다. Static Site 유형은 Python API를 실행할 수 없습니다.
3. Root Directory는 비워 두거나 저장소 루트로 지정합니다. 위 구조대로 업로드하면 `upload` 경로를 지정할 필요가 없습니다.
4. Python 런타임은 3.12 계열을 선택합니다. 플랫폼 UI/문서에서 해당 플랫폼의 Python 버전 지정 방법을 확인하세요. 특정 개인 PC 경로나 `.venv`를 업로드하지 않습니다.
5. 다음 빌드/실행 설정을 적용합니다.

| 설정 | 값 |
| --- | --- |
| Build command | `python -m pip install -r requirements.txt` |
| Start command | `python run.py` |
| 환경 변수 `HOST` | `0.0.0.0` |
| 환경 변수 `PORT` | 플랫폼이 제공하는 값을 사용; 제공하지 않으면 플랫폼 지정 포트 설정 |
| Health check path | `/api/health` |
| Deploy branch | `main` |
| Auto deploy | 해당 브랜치 push/commit 시 자동 배포 활성화 |

`run.py`는 HOST 기본값 `127.0.0.1`, PORT 기본값 `8000`을 사용합니다. 클라우드에서는 외부 요청을 받도록 HOST를 `0.0.0.0`으로 설정해야 합니다. PORT를 플랫폼 제공 값과 다르게 덮어쓰지 마세요. API 키, 데이터베이스 연결, 영구 디스크, `.env` 파일은 필요하지 않습니다.

6. 무료 또는 무료 사용 범위 내 인스턴스를 선택할 수 있는지 확인하고 직접 최초 배포합니다. 발급된 HTTPS 주소에서 첫 화면, `/api/health`, 가상 데이터 분석을 확인합니다.
7. 이후 `main`에 push하면 플랫폼이 GitHub 변경을 감지하여 패키지 설치와 서비스 재시작을 진행합니다. 배포 로그와 상태를 확인하고 실패하면 이전 정상 배포로 되돌리는 기능을 사용합니다.

이 방식은 플랫폼 자체 GitHub 연동이 자동 배포를 수행하므로 별도 GitHub Actions, Docker, Kubernetes 설정이 필수적이지 않습니다. 플랫폼이 달라도 위 설치/실행 명령과 HOST/PORT 원칙은 동일합니다. 이번 단계에서는 자동 배포 자체를 시험하지 않았습니다.

## 개인정보 및 운영 주의사항

- 파일은 multipart 임시파일 없이 제한된 메모리에서 처리하며 원문/결과를 파일·DB·브라우저 저장소에 저장하지 않습니다. 메모리의 암호학적 즉시 소거는 보장하지 않습니다.
- 화면의 결과에는 발신자 이름과 단어가 포함됩니다. 공유 전에 확인하세요. 입력·결과 지우기 또는 페이지 종료 전까지 화면에 남습니다.
- 외부 분석 API나 CDN을 사용하지 않습니다. 로컬에서는 로컬 서버로만 전송되지만 클라우드 배포 후에는 해당 클라우드 서버로 전송됩니다. 검증에는 가상 데이터를 사용하세요.
- 원문·이름·파일명을 서버 로그에 기록하지 않습니다. 접근 로그는 끄고 기본 시작/종료 로그와 예외 종류만 남깁니다. 호스팅 플랫폼의 별도 로그/보관 정책도 확인하세요.
- 공개 서비스로 운영할 때는 HTTPS, 접근 제어, 동시 요청/요청 빈도 제한, 플랫폼의 요청 크기 제한을 추가로 검토하세요. 앱의 5 MiB 제한은 요청당 제한이며 전체 동시 요청 수 제한은 없습니다.
- 현재 버전은 의존성 직접 버전을 requirements.txt에 명시했습니다. 클라우드의 전이 의존성 설치 결과는 로컬과 달라질 수 있으므로 최초 배포 로그와 상태 확인이 필요합니다.
