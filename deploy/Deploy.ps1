# Windows PowerShell 5.1 compatible. All Docker resources are ownership-checked.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Repository,
    [Parameter(Mandatory=$true)][string]$CommitSha,
    [Parameter(Mandatory=$true)][long]$CiRunId,
    [Parameter(Mandatory=$true)][long]$CiRunNumber,
    [Parameter(Mandatory=$true)][string]$ImageName,
    [string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'kakao-chat-analyzer-deploy'),
    [ValidateRange(1,30)][int]$ReadySamples = 3,
    [ValidateRange(1,120)][int]$StabilizeSeconds = 15,
    [ValidateRange(60,180)][int]$DrainTimeoutSeconds = 75,
    [string]$EvidenceDirectory,
    [scriptblock]$PostSwitchValidation,
    [object]$ValidationContext
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$network = 'kakao-chat-net'
$volume = 'kakao-chat-nginx-config'
$proxy = 'kakao-chat-proxy'
$nginxImage = 'nginx:1.28.0-alpine'
$version = "sha-$CommitSha"
$containerLabel = 'io.kakao.deploy.repository'
$active = $null
$candidate = $null
$helper = $null
$switched = $false
$initialProxyCreated = $false
$oldConfig = $null
$lock = $null

function Record-Deployment([string]$Name,[hashtable]$Data=@{}) {
    if ($EvidenceDirectory) {
        $record=@{timestamp_utc=[DateTimeOffset]::UtcNow.ToString('o');name=$Name;data=$Data}
        [IO.File]::AppendAllText((Join-Path $EvidenceDirectory 'events.jsonl'),(($record|ConvertTo-Json -Depth 6 -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))
    }
}
function Assert-EvidenceMonitor {
    if ($EvidenceDirectory) {
        $heartbeat=Join-Path $EvidenceDirectory 'heartbeat.txt'
        if (-not (Test-Path $heartbeat) -or ([DateTime]::UtcNow-(Get-Item $heartbeat).LastWriteTimeUtc).TotalSeconds -gt 10 -or (Test-Path (Join-Path $EvidenceDirectory 'stopped.json'))) { throw 'Independent HTTP monitor is absent or stalled' }
        if (Test-Path (Join-Path $EvidenceDirectory 'failure.marker')) { throw 'Independent HTTP monitor recorded a failed request' }
    }
}

function Invoke-Docker {
    param([string[]]$Arguments)
    # Windows PowerShell can turn native stderr into ErrorRecords. Judge the
    # actual exit code, not informational stderr from e.g. nginx -t.
    $ErrorActionPreference = 'Continue'
    $result = & docker @Arguments
    $commandSucceeded = $?
    if (-not $commandSucceeded -or $LASTEXITCODE -ne 0) { throw "Docker command failed (exit $LASTEXITCODE): $($Arguments[0])" }
    return $result
}
function Container([string]$Name) {
    $names = @(Invoke-Docker -Arguments @('container','ls','-a','--format','{{.Names}}'))
    if ($names -notcontains $Name) { return $null }
    return ((Invoke-Docker -Arguments @('inspect',$Name) | Out-String) | ConvertFrom-Json)[0]
}
function Assert-Owned($Object) {
    $labels = $Object.Config.Labels
    $property = $labels.PSObject.Properties[$containerLabel]
    if (-not $property -or $property.Value -ne $Repository) { throw "Unmanaged container name collision: $($Object.Name)" }
}
function Assert-ResourceOwner($Object) {
    $property = $Object.Labels.PSObject.Properties[$containerLabel]
    if (-not $property -or $property.Value -ne $Repository) { throw 'Unmanaged Docker network/volume collision' }
}
function Assert-Ci {
    if (-not $env:GITHUB_TOKEN) { throw 'GITHUB_TOKEN is required for CI origin/main validation' }
    $headers = @{Authorization="Bearer $env:GITHUB_TOKEN"; Accept='application/vnd.github+json'; 'X-GitHub-Api-Version'='2022-11-28'}
    $run = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/actions/runs/$CiRunId" -Headers $headers -TimeoutSec 20
    if ($run.conclusion -ne 'success' -or $run.status -ne 'completed' -or $run.event -ne 'push' -or $run.head_branch -ne 'main' -or $run.head_sha -ne $CommitSha -or $run.head_repository.full_name -ne $Repository -or $run.repository.full_name -ne $Repository -or $run.path -ne '.github/workflows/ci.yml' -or $run.name -ne 'CI - Test and publish Docker image' -or $run.run_number -ne $CiRunNumber) { throw 'CI origin/status/version validation failed' }
    $branch = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/branches/main" -Headers $headers -TimeoutSec 20
    return ($branch.commit.sha -eq $CommitSha)
}
function Ensure-Infrastructure {
    $netNames = @(Invoke-Docker -Arguments @('network','ls','--format','{{.Name}}'))
    if ($netNames -contains $network) {
        Assert-ResourceOwner (((Invoke-Docker -Arguments @('network','inspect',$network) | Out-String) | ConvertFrom-Json)[0])
    } else { $null = Invoke-Docker -Arguments @('network','create','--label',"$containerLabel=$Repository",$network) }
    $volNames = @(Invoke-Docker -Arguments @('volume','ls','--format','{{.Name}}'))
    if ($volNames -contains $volume) {
        Assert-ResourceOwner (((Invoke-Docker -Arguments @('volume','inspect',$volume) | Out-String) | ConvertFrom-Json)[0])
    } else { $null = Invoke-Docker -Arguments @('volume','create','--label',"$containerLabel=$Repository",$volume) }
}
function Health([string]$Expected) {
    $response = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8000/health' -TimeoutSec 5 -DisableKeepAlive
    if ($response.StatusCode -ne 200) { throw 'Proxy health is not HTTP 200' }
    $body = $response.Content | ConvertFrom-Json
    if ($body.status -ne 'ok' -or $body.version -ne $Expected) { throw 'Proxy version/status mismatch' }
}
function Probe-Proxy([string]$Expected) {
    Health $Expected
    foreach ($path in @('/','/docs','/openapi.json','/static/app.js','/static/style.css','/static/docs.js','/static/vendor/swagger-ui/swagger-ui-bundle.js','/static/vendor/swagger-ui/swagger-ui.css')) {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8000$path" -TimeoutSec 10
        if ($response.StatusCode -ne 200) { throw "Proxy endpoint failed: $path" }
    }
    $sample = "2026. 11. 8. 09:00, SyntheticA : hello project`n2026. 11. 8. 09:02, SyntheticB : hello friend"
    $result = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8000/api/analyze' -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($sample)) -ContentType 'text/plain' -TimeoutSec 10
    $data = $result.Content | ConvertFrom-Json
    if ($result.StatusCode -ne 200 -or $data.total -ne 2 -or $data.participant_count -ne 2) { throw 'Proxy synthetic analysis failed' }
    if ($data.busiest_weekday.message_count -ne 2 -or $data.busiest_weekday.weekday_indexes[0] -ne 6 -or $data.busiest_weekday.ratio -ne 100) { throw 'New weekday highlight is absent or incorrect' }
}
function Worker-Ids {
    $text = (Invoke-Docker -Arguments @('exec',$proxy,'cat','/proc/1/task/1/children') | Out-String).Trim()
    return @($text -split '\s+' | Where-Object { $_ -match '^\d+$' })
}
function Wait-Drain([string[]]$Ids) {
    $deadline = [DateTime]::UtcNow.AddSeconds($DrainTimeoutSeconds)
    do {
        Assert-EvidenceMonitor
        $remaining = @(Worker-Ids | Where-Object { $Ids -contains $_ })
        if ($remaining.Count -eq 0) { return }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Previous Nginx workers have not drained; keeping both app slots' }
        Start-Sleep -Seconds 2
    } while ($true)
}
function Write-Config([string]$Slot,[string]$Version,[long]$Run) {
    $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'nginx.conf.template'))
    $text = $text.Replace('@@SLOT@@',$Slot).Replace('@@VERSION@@',$Version).Replace('@@RUN@@',"$Run").Replace('@@UPSTREAM@@',"kakao-chat-$Slot")
    $file = Join-Path $StateDirectory 'candidate.conf'
    [IO.File]::WriteAllText($file,$text,(New-Object Text.UTF8Encoding($false)))
    return $file
}
function Install-Config([string]$Target,[string]$File) {
    $null = Invoke-Docker -Arguments @('cp',$File,"${Target}:/etc/nginx/managed/candidate.conf")
    $null = Invoke-Docker -Arguments @('exec',$Target,'nginx','-t','-c','/etc/nginx/managed/candidate.conf')
    $null = Invoke-Docker -Arguments @('exec',$Target,'mv','/etc/nginx/managed/candidate.conf','/etc/nginx/managed/nginx.conf')
}
function Save-State([string]$Slot,[string]$Version,[long]$Run) {
    $record = @{Repository=$Repository; Slot=$Slot; Version=$Version; RunNumber=$Run; UpdatedUTC=[DateTime]::UtcNow.ToString('o')}
    $temp = Join-Path $StateDirectory 'state.json.tmp'
    [IO.File]::WriteAllText($temp,($record | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination (Join-Path $StateDirectory 'state.json') -Force
}

try {
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $CommitSha -notmatch '^[0-9a-f]{40}$' -or $ImageName -notmatch '^[a-z0-9][a-z0-9_.-]*/kakao-chat-analyzer$' -or $CiRunId -lt 1 -or $CiRunNumber -lt 1) { throw 'Invalid deployment inputs' }
    $StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
    $null = New-Item -ItemType Directory -Force -Path $StateDirectory
    $lock = [IO.File]::Open((Join-Path $StateDirectory 'deploy.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    if ((Invoke-Docker -Arguments @('info','--format','{{.OSType}}') | Out-String).Trim() -ne 'linux') { throw 'Docker Desktop Linux Containers is required' }
    if (-not (Assert-Ci)) { Write-Host 'SKIP: successful CI is no longer the main head'; return }
    $stateFile = Join-Path $StateDirectory 'state.json'
    if (Test-Path -LiteralPath $stateFile) {
        $state = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
        if ($state.Repository -ne $Repository) { throw 'State directory belongs to another repository' }
        if ([long]$state.RunNumber -gt $CiRunNumber) { Write-Host 'SKIP: newer CI already deployed'; return }
    }
    $currentProxy = Container $proxy
    if ($currentProxy) {
        Assert-Owned $currentProxy
        if (-not $currentProxy.State.Running) { throw 'Managed proxy is stopped. Inspect and start it manually; not replacing it.' }
        $oldConfig = (Invoke-Docker -Arguments @('exec',$proxy,'cat','/etc/nginx/managed/nginx.conf') | Out-String)
        if ($oldConfig -notmatch '# kakao-slot=(blue|green)') { throw 'Unknown active slot configuration' }
        $active = $Matches[1]
        if ($oldConfig -notmatch '# kakao-version=(sha-[0-9a-f]{40})') { throw 'Missing active version' }
        $oldVersion = $Matches[1]
        if ($oldConfig -notmatch '# kakao-run=(\d+)') { throw 'Missing active run number' }
        $oldRun = [long]$Matches[1]
        $oldApp = Container "kakao-chat-$active"
        if (-not $oldApp) { throw 'Active app container is missing' }
        Assert-Owned $oldApp
        Health $oldVersion
        if ($oldRun -gt $CiRunNumber) { Write-Host 'SKIP: proxy already routes to a newer CI'; return }
        if ($oldVersion -eq $version) { Probe-Proxy $version; Write-Host 'NO-OP: requested version is already active'; return }
        # An interrupted prior reload must finish draining before slot reuse.
        $deadline = [DateTime]::UtcNow.AddSeconds($DrainTimeoutSeconds)
        while (@(Worker-Ids).Count -gt 1) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Prior Nginx workers are still draining; no slot removed' }
            Start-Sleep -Seconds 2
        }
    } else {
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse('127.0.0.1'),8000)
        try { $listener.Start() } catch { throw 'Host port 8000 is occupied. Inspect its owner; no process was stopped.' } finally { $listener.Stop() }
    }
    Ensure-Infrastructure
    $image = "${ImageName}:$version"
    Write-Host "PULL: $image"
    $null = Invoke-Docker -Arguments @('manifest','inspect',$image)
    $null = Invoke-Docker -Arguments @('pull',$image)
    Record-Deployment 'ImagePulled' @{image=$image;target_version=$version}
    # Pin this deployment to the pulled digest, not a subsequently mutable tag.
    $imageInfo = ((Invoke-Docker -Arguments @('image','inspect',$image) | Out-String) | ConvertFrom-Json)[0]
    $digest = @($imageInfo.RepoDigests | Where-Object { $_ -like "$ImageName@sha256:*" } | Select-Object -First 1)
    if ($digest.Count -ne 1) { throw 'Pulled image digest is missing' }
    $slot = if ($active -eq 'blue') { 'green' } else { 'blue' }
    $candidateName = "kakao-chat-$slot"
    $unused = Container $candidateName
    if ($unused) { Assert-Owned $unused; $null = Invoke-Docker -Arguments @('rm','-f',$candidateName) }
    $candidate = $candidateName
    Assert-EvidenceMonitor
    $null = Invoke-Docker -Arguments @('run','-d','--name',$candidate,'--restart','unless-stopped','--network',$network,'--label',"$containerLabel=$Repository",'--label',"io.kakao.deploy.version=$version",$digest[0])
    Record-Deployment 'CandidateCreated' @{slot=$slot;container=$candidate;image=$digest[0]}
    $healthCode = "import json,urllib.request; r=urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=3); assert r.status==200; d=json.load(r); assert d.get('status')=='ok' and d.get('version')=='$version'"
    $successes = 0
    for ($attempt=1; $attempt -le 30; $attempt++) {
        Assert-EvidenceMonitor
        $healthExit = 1
        try {
            & docker exec $candidate python -c $healthCode 2>$null
            $healthExit = $LASTEXITCODE
        } catch { $healthExit = 1 }
        if ($healthExit -eq 0) { $successes++ } else { $successes=0 }
        if ($successes -ge $ReadySamples) { break }
        $info = Container $candidate
        if (-not $info.State.Running) { throw 'Candidate app exited before readiness' }
        Start-Sleep -Seconds 2
    }
    if ($successes -lt $ReadySamples) { throw 'Candidate HTTP health/version readiness timed out' }
    Write-Host "READY: $candidate version=$version consecutive_checks=$successes"
    Record-Deployment 'CandidateReady' @{slot=$slot;version=$version;checks=$successes}
    if (-not (Assert-Ci)) { throw 'Main changed during preparation; leaving current route unchanged' }
    $configFile = Write-Config $slot $version $CiRunNumber
    Assert-EvidenceMonitor
    if ($currentProxy) {
        $workers = @(Worker-Ids)
        # Mark before mutation so even an interrupted reload command rolls back.
        $switched = $true
        Install-Config $proxy $configFile
        Record-Deployment 'RouteSwitchRequested' @{from=$active;to=$slot;version=$version}
        $null = Invoke-Docker -Arguments @('exec',$proxy,'nginx','-s','reload','-c','/etc/nginx/managed/nginx.conf')
        Record-Deployment 'RouteReloaded' @{slot=$slot;version=$version}
    } else {
        $null = Invoke-Docker -Arguments @('pull',$nginxImage)
        $helper = "kakao-config-$([guid]::NewGuid().ToString('N'))"
        $null = Invoke-Docker -Arguments @('run','-d','--name',$helper,'--network',$network,'--mount',"type=volume,src=$volume,dst=/etc/nginx/managed",'--label',"$containerLabel=$Repository",$nginxImage,'sleep','300')
        Install-Config $helper $configFile
        $null = Invoke-Docker -Arguments @('rm','-f',$helper)
        $helper = $null
        $null = Invoke-Docker -Arguments @('run','-d','--name',$proxy,'--restart','unless-stopped','--network',$network,'-p','127.0.0.1:8000:80','--mount',"type=volume,src=$volume,dst=/etc/nginx/managed",'--label',"$containerLabel=$Repository",$nginxImage,'nginx','-c','/etc/nginx/managed/nginx.conf','-g','daemon off;')
        $initialProxyCreated = $true
        $workers = @()
    }
    # Host-side readiness, followed by strict full probe and stability window.
    $ready = $false
    for ($attempt=0; $attempt -lt 15; $attempt++) {
        Assert-EvidenceMonitor
        try { Health $version; $ready=$true; break } catch { Start-Sleep -Seconds 1 }
    }
    if (-not $ready) { throw 'Proxy did not route to expected version' }
    Probe-Proxy $version
    Record-Deployment 'ProxyVerified' @{slot=$slot;version=$version}
    $until = [DateTime]::UtcNow.AddSeconds($StabilizeSeconds)
    do { Assert-EvidenceMonitor; Health $version; Start-Sleep -Seconds 2 } while ([DateTime]::UtcNow -lt $until)
    if ($workers.Count -gt 0) { Wait-Drain $workers }
    Record-Deployment 'RoutingAndDrainComplete' @{slot=$slot;version=$version}
    if ($PostSwitchValidation) { $null = & $PostSwitchValidation $ValidationContext }
    Assert-EvidenceMonitor
    Save-State $slot $version $CiRunNumber
    Record-Deployment 'DeploymentCompleted' @{slot=$slot;version=$version;image=$digest[0]}
    Write-Host "DEPLOYED: slot=$slot version=$version image=$($digest[0]); prior app retained for rollback"
} catch {
    $failure = $_
    Write-Warning "DEPLOYMENT FAILED: $($failure.Exception.Message)"
    Record-Deployment 'DeploymentFailed' @{reason=$failure.Exception.Message}
    if ($switched -and $oldConfig) {
        Record-Deployment 'RollbackStarted' @{version=$oldVersion;reason=$failure.Exception.Message}
        try {
            $file = Join-Path $StateDirectory 'rollback.conf'
            [IO.File]::WriteAllText($file,$oldConfig,(New-Object Text.UTF8Encoding($false)))
            Install-Config $proxy $file
            $null = Invoke-Docker -Arguments @('exec',$proxy,'nginx','-s','reload','-c','/etc/nginx/managed/nginx.conf')
            $restored = $false
            for ($attempt=0; $attempt -lt 15; $attempt++) {
                try { Health $oldVersion; $restored=$true; break } catch { Start-Sleep -Seconds 1 }
            }
            if (-not $restored) { throw 'Old proxy version did not recover' }
            Save-State $active $oldVersion $oldRun
            Write-Warning "ROLLED BACK: $active $oldVersion"
            Record-Deployment 'RollbackSucceeded' @{slot=$active;version=$oldVersion}
        } catch { Record-Deployment 'RollbackFailed' @{reason=$_.Exception.Message}; Write-Warning "ROLLBACK FAILED: $($_.Exception.Message). Keeping both app containers for recovery." }
    }
    foreach ($name in @($candidate,$proxy)) {
        if ($name) {
            try {
                $diagnosticContainer = Container $name
                if ($diagnosticContainer) {
                    Assert-Owned $diagnosticContainer
                    & docker logs --tail 100 $name
                    & docker inspect --format '{{json .State}}' $name
                }
            } catch { Write-Warning "Cannot inspect owned diagnostic target $name" }
        }
    }
    # Never delete a candidate that might still serve traffic after a reload.
    if ($candidate -and -not $switched -and -not $initialProxyCreated) {
        $ownedCandidate = Container $candidate
        if ($ownedCandidate) { Assert-Owned $ownedCandidate; $null = Invoke-Docker -Arguments @('rm','-f',$candidate) }
    }
    throw $failure
} finally {
    try {
        if ($helper) {
            $ownedHelper = Container $helper
            if ($ownedHelper) { Assert-Owned $ownedHelper; $null = Invoke-Docker -Arguments @('rm','-f',$helper) }
        }
    } finally { if ($lock) { $lock.Dispose() } }
}
