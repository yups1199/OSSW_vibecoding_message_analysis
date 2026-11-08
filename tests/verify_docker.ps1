# Run manually from PowerShell after Docker Desktop is available.
# Only the container created by this script is removed. No registry push.
param([string]$Python = '.\.venv\Scripts\python.exe')

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$containerId = $null
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 10)
$version = "manual-$suffix"
$image = "kakao-chat-analyzer:$version"

Push-Location -LiteralPath $repositoryRoot
try {
    $engineOS = docker info --format '{{.OSType}}'
    if ($LASTEXITCODE -ne 0 -or $engineOS -ne 'linux') {
        throw 'Docker Desktop Linux engine is unavailable.'
    }
    docker build --build-arg "APP_VERSION=$version" -t $image .
    if ($LASTEXITCODE -ne 0) { throw 'Docker build failed.' }

    $created = docker run -d --name "kakao-manual-$suffix" -p '127.0.0.1::8000' $image
    if ($LASTEXITCODE -ne 0) { throw 'Container creation failed.' }
    $containerId = ($created | Select-Object -Last 1).Trim()
    $stateJson = docker inspect $containerId
    if ($LASTEXITCODE -ne 0) { throw 'Container inspection failed.' }
    $state = ($stateJson | ConvertFrom-Json)[0]
    $port = $state.NetworkSettings.Ports.'8000/tcp'[0].HostPort
    if (-not $port) { throw 'No loopback port was allocated.' }
    $baseURL = "http://127.0.0.1:$port"
    Write-Host "Container: $containerId"
    Write-Host "URL: $baseURL ; expected version: $version"

    & $Python -B tests/smoke.py $baseURL $version
    if ($LASTEXITCODE -ne 0) { throw 'HTTP smoke test failed.' }
    $healthy = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $health = docker inspect --format '{{.State.Health.Status}}' $containerId
        if ($LASTEXITCODE -ne 0) { throw 'Health inspection failed.' }
        if ($health -eq 'healthy') { $healthy = $true; break }
        if ($health -eq 'unhealthy') { throw 'Docker HEALTHCHECK is unhealthy.' }
        Start-Sleep -Seconds 2
    }
    if (-not $healthy) { throw 'Timed out waiting for Docker HEALTHCHECK.' }

    docker exec $containerId python -m pip check
    if ($LASTEXITCODE -ne 0) { throw 'Container dependencies failed validation.' }
    $fileCheck = "from pathlib import Path; import os; expected={'requirements.txt','run.py','app/__init__.py','app/main.py','app/analysis.py','static/index.html','static/style.css','static/app.js'}; actual={p.relative_to('/service').as_posix() for p in Path('/service').rglob('*') if p.is_file()}; assert actual==expected, actual; assert os.getuid()==10001; print('PASS: non-root UID and exact runtime file allowlist')"
    docker exec $containerId python -c $fileCheck
    if ($LASTEXITCODE -ne 0) { throw 'Image file/user check failed.' }
    Write-Host 'PASS: build, HTTP/version/API/static, Docker health, dependencies and image contents'
} catch {
    if ($containerId) { docker logs $containerId }
    throw
} finally {
    try {
        if ($containerId) {
            docker rm -f $containerId
            if ($LASTEXITCODE -ne 0) {
                throw "Cleanup failed; manually remove only container $containerId"
            }
            Write-Host 'PASS: temporary verification container removed'
        }
    } finally {
        Pop-Location
    }
}
