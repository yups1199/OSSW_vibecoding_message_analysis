# 작업 3: 기능 개선 및 무중단 재배포 검증

개발 루트는 `.git`이 있는 **upload**입니다. 상위 보관용 코드, 운영 컨테이너와 Runner를 변경하지 않았고 Git 명령은 실행하지 않았습니다.

## 변경 파일

| 파일 | 역할 |
| --- | --- |
| `app/analysis.py` | `busiest_weekday`: 최다 요일·메시지 수·전체 대비 비율. 공동 1위는 월→일 순서 |
| `static/index.html`, `static/app.js`, `static/style.css` | 가장 활발한 요일 카드, 실제 `/health` 버전 배지, 모바일 표시 |
| `tests/test_service.py`, `tests/smoke.py` | 단일 요일·동률·반올림 및 기존 분석 기능 검사 |
| `deploy/Monitor-Http.ps1` | 독립 Background Job의 실제 HTTP 표본 수집 |
| `deploy/Monitoring.psm1` | 관측 창·실패·구→신 전환 판정, Summary 생성 |
| `deploy/Invoke-MonitoredDeploy.ps1` | Before→실제 배포와 모니터 병행→After→최종 판정 |
| `deploy/Deploy.ps1` | 기존 배포/롤백 유지, 이벤트 기록과 모니터 실패 시 롤백 게이트 |
| `.github/workflows/cd.yml` | 모니터링 래퍼 호출, 실패 시에도 관측 Artifact 업로드 |
| `deploy/Test-Deployment.ps1` | 모의 배포/롤백 검사. 실제 포트를 점유하지 않음 |
| `tests/verify_monitoring.py`, `tests/fixture_deploy.ps1` | 실제 로컬 HTTP와 모의 배포로 병행 실행·실패 판정 검사 |
| `tests/verify_preview.py` | 임의 포트의 실제 앱과 Edge로 UI 검사 후 서버 종료 |
| `README.md`, `deploy/README.md`, 이 문서 | 기능·운영·검증 안내 |

기존 요일 그래프는 유지됩니다. 가상 데이터 체험에서 새 카드는 **목요일 / 6개 메시지 / 전체의 50%**입니다. 공동 1위 비율은 각 요일별 비율입니다. 원문 저장과 외부 분석 의존성을 추가하지 않았으며 `/health` 응답 구조는 유지합니다.

## CI/CD 및 관측 흐름

1. 사용자가 main에 push → 기존 `CI - Test and publish Docker image`. Python 테스트, Docker 빌드, readiness와 HTTP smoke 성공 후에만 publish합니다.
2. 성공한 동일 저장소 main push CI만 `workflow_run`으로 Windows Self-hosted CD를 실행합니다. 원본 `head_sha`로 checkout 및 `sany19/kakao-chat-analyzer:sha-<40자리 SHA>`를 선택합니다. SHA를 고정하지 않습니다. 기존 공식 로그인, 오래된 CI 차단과 concurrency를 유지합니다.
3. 모니터는 **`http://127.0.0.1:8000/health`**에 500ms 간격(설정 범위 500~1000ms), 타임아웃 2초로 요청합니다. Before 표본을 최소 10초 확보한 뒤 배포합니다.
4. 활성 앱 유지 → 비활성 슬롯 새 앱 준비 → 내부 HTTP 200/status/version 연속 readiness → Nginx 후보 `nginx -t` → atomic 설정 교체와 reload. 프록시 재시작이나 활성 앱 선종료는 없습니다. 프록시만 호스트 `127.0.0.1:8000:80`을 게시하며 앱은 내부 네트워크 8000을 사용합니다.
5. 실제 프록시의 `/`, `/docs`, 정적 파일, 분석 API, `/health`, 15초 안정화와 기존 worker drain을 검사합니다. 구 앱은 보존하고 다음 배포에서 소유권을 확인한 비활성 슬롯만 재사용합니다.
6. 라우팅·drain 이후 After를 최소 30초 관측하고 신기능 API/HTML 마커를 검사합니다. 이 게이트 실패는 기존 배포의 롤백 경로로 전달됩니다.
7. 배포 성공 반환 **이후에도 최소 30초** 추가 관측합니다. After는 보통 총 60초 이상입니다. 이 최종 관측 실패는 CD를 실패 처리하며 이미 성공 반환한 배포를 자동으로 다시 전환하지는 않습니다. 양 슬롯은 보존됩니다.
8. 샘플러 정상 종료, CSV/이벤트 분석, Job Summary 및 Artifact 저장.

단계는 요청 시작 시점 기준입니다. During에는 신규 준비와 전환 후 안정화가 포함되며 구·신 응답을 모두 관측해야 합니다. After는 안정화·drain 이후입니다. 동일 SHA 재실행은 전환 증거가 될 수 없어 검증 실패입니다. 이번 검증은 이미 정상 서비스가 있어야 하며, 없으면 Before에서 중단합니다. 기존 `Deploy.ps1`의 초기 배포 기능은 유지됩니다.

## 오류 처리와 성공 기준

Pull/readiness 실패 시 기존 라우팅을 유지합니다. 설정·전환 후 검사·After 게이트 실패 시 구 설정 복원과 reload 후 구버전 health를 확인합니다. 실패를 성공으로 바꾸지 않습니다.

실패 표본, heartbeat 정지, 2.5초 초과 표본 간격, 번호 누락, 관측 시간 부족, 구→신 미관측, 잘못된 버전, 롤백, 신기능 미확인 중 하나라도 있으면 검증 실패입니다. 예외 시에도 가능한 After 관측과 로그 보존을 시도합니다. Runner 강제 종료/PC 전원 종료에는 마지막 flush까지의 로컬 CSV만 남을 수 있습니다.

`zero_downtime_verified=true`는 실제 deployment 모드의 조건을 모두 만족할 때만 설정합니다. `local-http-test`는 성공해도 항상 false입니다. 성공 시 표현은 **“관측한 검증 구간에서 서비스 중단이 관측되지 않았다”**입니다. 표본 사이 모든 순간이나 모든 종류의 요청을 보장하지 않습니다.

## Summary, Artifact 및 제출 화면

GitHub → Actions → 해당 CD 실행:

- `Monitor before, during and after Blue-Green deployment` 로그: Before 버전, Pull, READY, 전환·완료·실패 이유.
- **Summary**: Before Deployment / During Deployment / After Deployment, 요청·성공·실패 수, 최대 지연/간격, 준비·reload·완료·롤백 시각.
- **Artifacts → deployment-http-evidence-<run_id>-<attempt>**: `requests.csv`, `events.jsonl`, `summary.json`, `summary.md`, 시작/종료 정보. 보존 14일. 인증 전 실패라면 관측 파일이 없을 수 있습니다.
- target/final version이 CI SHA와 일치하고 실패 0, 실제 버전 전환, `post_completion_seconds >= 30`, `zero_downtime_verified=true`인지 확인하세요.

CSV 열: sequence, timestamp_utc(ISO 8601 UTC), phase, http_status(연결 실패는 0), latency_ms, version, success, error, gap_ms. 원문·참여자·Secret은 수집하지 않습니다. 이벤트에는 배포 메타데이터와 오류/복구를 기록합니다.

제출 캡처 순서:

1. **push 전** 현재 `/`에서 가상 데이터 체험→분석한 기존 화면과 `/health` 구 SHA.
2. push 후 CI/CD 성공 화면, CD Summary와 Artifact 요청 기록.
3. 같은 URL 새로고침 후 가상 데이터 분석: 새 목요일 카드, 헤더 버전 배지와 `/health` 신 SHA.
4. `/docs` 및 합성 TXT 업로드 결과.

확보한 로컬 증거는 `.deploy-state/evidence/`입니다. `before-dashboard.png`, `before-health.png`, `before-health.json`은 기존 서비스에서 실제 수집했습니다. `local-preview-dashboard.png`, `local-preview-mobile.png`는 **임의 포트 미리보기**이며 Docker/CD 배포 후 화면이 아닙니다. 실제 push 후 화면은 추가 확보해야 합니다. 증거는 Git과 Docker 컨텍스트에서 제외됩니다.

## 실제 로컬 검증과 한계

- 기존 운영 `/`, `/docs`, `/health`: 200. 기존 버전 `sha-6201487f59c59ae1be85a83780e8a0d85a3d9472` 관측.
- Python 단위 테스트 15개 성공. 새 요일·동률·반올림 및 기존 파서/응답 검사 포함.
- 임의 포트 FastAPI HTTP smoke: 버전, 정적 파일, Swagger, UTF-8/CP949 분석과 잘못된 입력 성공.
- 실제 Edge: 새 카드, TXT 업로드, 동률, 버전 배지, 모바일 가로 넘침 없음, Swagger 렌더링 성공. JavaScript 오류 없음. 서버 종료와 포트 해제 확인.
- PowerShell 모의 배포: 초기 배포, 전환, Pull/readiness/설정/프록시/관측 게이트 실패, 롤백, 오래된 실행 차단, 동일 버전, 소유권 검사 성공. 실제 Docker 결과가 아닙니다.
- 실제 HTTP 병행 테스트: 성공 사례와 HTTP 503·버전 미변경·타임아웃·연결 종료·잘못된 JSON의 실패 판정. `.deploy-state/http-test-*/summary.json`은 모두 `local-http-test`입니다.
- 최종 성공 사례 `http-test-success-eba8a3a05c924594bbb70a13636d70e3`: 실제 HTTP 151건, 실패 0, Before 10.009초, During 8건, After 60.529초, 성공 반환 후 30.113초. 최대 지연 69.907ms, 최대 요청 간격 520.699ms. 모의 배포이므로 `zero_downtime_verified=false`입니다.
- PowerShell 문법 및 CI/CD YAML 파싱·workflow 이름/트리거·SHA·Windows Runner·Artifact 조건의 정적 검사 성공. GitHub 서버의 workflow 실행 검증은 아닙니다. 빈 증거의 성공 차단 및 쓰는 중인 CSV의 미완성 행 제외도 검사했습니다.
- 모니터 Job 강제 종료 사례는 실제 HTTP 3건이 모두 성공했어도 전체 검증을 실패 처리했습니다. 요청 실패 0건만으로 관측 중단을 성공 처리하지 않습니다. 모든 통합 테스트의 임시 HTTP 서버는 종료했습니다.
- 이번 Docker 조회/빌드/재배포는 미검증입니다. 자동 승인 검토 시스템 HTTP 404 (`Model 'codex-auto-review' not found`)로 실행이 차단됐습니다. 활성 슬롯·실행 이미지·Nginx 런타임 설정을 직접 확인하지 못했고 기존 컨테이너는 변경하지 않았습니다.
- 원격 CI/CD, 신규 이미지, 실제 전환과 무중단 결과는 **사용자 push 후 확인 필요**합니다. 현재 실제 무중단 재배포 성공을 주장하지 않습니다.

## 사용자가 실행할 명령

실제 저장소 `upload`에서 변경 목록을 확인한 뒤 실행하세요. 아래 Git 명령은 안내이며 도구가 실행하지 않았습니다.

```powershell
Set-Location '<현재 프로젝트 전체 경로>\upload'
git status
git add app/analysis.py static/index.html static/app.js static/style.css tests/test_service.py tests/smoke.py tests/fixture_deploy.ps1 tests/verify_monitoring.py tests/verify_preview.py deploy/Monitor-Http.ps1 deploy/Monitoring.psm1 deploy/Invoke-MonitoredDeploy.ps1 deploy/Deploy.ps1 deploy/Test-Deployment.ps1 .github/workflows/cd.yml README.md deploy/README.md TASK3_VALIDATION.md
git diff --cached --stat
git commit -m "Add weekday highlight and monitored blue-green redeployment"
git push origin main
```

push 전 Runner의 Listening for Jobs와 Docker Desktop Linux Containers를 확인하세요. Secret 값과 Runner 인증 파일은 제출하지 마세요.

읽기 전용 실제 상태 확인(사용자 실행):

```powershell
Invoke-RestMethod http://127.0.0.1:8000/health
docker ps --filter "name=kakao-chat-" --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}"
docker exec kakao-chat-proxy cat /etc/nginx/managed/nginx.conf
docker network inspect kakao-chat-net
```

추가 로컬 테스트:

```powershell
.\.venv\Scripts\python.exe -B -m unittest discover -s tests -p 'test_*.py' -v
.\deploy\Test-Deployment.ps1
# opt-in: 내부 테스트 프로세스에만 ExecutionPolicy Bypass 사용을 허용할 때 실행
.\.venv\Scripts\python.exe -B tests/verify_monitoring.py
```

이번 검증은 사용자 승인을 받아 테스트 프로세스에만 Bypass를 적용했으며 시스템 정책은 바꾸지 않았습니다. 브라우저 검증에는 개발용 Playwright와 Edge가 필요하며 서비스 requirements에는 추가하지 않았습니다.
