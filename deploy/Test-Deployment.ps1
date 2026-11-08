# Deterministic orchestration tests. No real Docker/GitHub commands are run.
$ErrorActionPreference = 'Stop'
$global:KakaoMock_repo = 'synthetic-owner/synthetic-repo'
$global:KakaoMock_images = 'synthetic-owner/kakao-chat-analyzer'
$global:KakaoMock_containers = @{}
$global:KakaoMock_networks = @{}
$global:KakaoMock_volumes = @{}
$global:KakaoMock_config = ''
$global:KakaoMock_routed = ''
$global:KakaoMock_worker = 10
$global:KakaoMock_mode = ''
$global:KakaoMock_removed = @()
$global:KakaoMock_runNumber = 1
$global:KakaoMock_sha = ('1' * 40)
$global:KakaoMock_stale = $false
$global:KakaoMock_root = Split-Path -Parent $PSScriptRoot
$global:KakaoMock_state = Join-Path $global:KakaoMock_root ".deploy-state/test-$([guid]::NewGuid().ToString('N'))"
$global:KakaoMock_oldToken = $env:GITHUB_TOKEN
$env:GITHUB_TOKEN = 'synthetic-test-value-not-a-credential'

function Assert($condition,[string]$message) { if (-not $condition) { throw "TEST FAILED: $message" } }
function Start-Sleep { param([int]$Seconds); [Threading.Thread]::Sleep(5) }
function Invoke-RestMethod {
    param($Uri,$Headers,$TimeoutSec)
    if ($Uri -like '*/branches/main') {
        $head = if ($global:KakaoMock_stale) { 'f' * 40 } else { $global:KakaoMock_sha }
        return @{commit=@{sha=$head}}
    }
    return @{conclusion='success';status='completed';event='push';head_branch='main';head_sha=$global:KakaoMock_sha;head_repository=@{full_name=$global:KakaoMock_repo};repository=@{full_name=$global:KakaoMock_repo};path='.github/workflows/ci.yml';name='CI - Test and publish Docker image';run_number=$global:KakaoMock_runNumber}
}
function Invoke-WebRequest {
    param($Uri,[switch]$UseBasicParsing,$TimeoutSec,[switch]$DisableKeepAlive,$Method,$Body,$ContentType)
    if ($Uri -like '*/health') { return @{StatusCode=200;Content=(@{status='ok';version=$global:KakaoMock_routed}|ConvertTo-Json -Compress)} }
    if ($global:KakaoMock_mode -eq 'proxy-failure') { $global:KakaoMock_mode=''; throw 'Synthetic post-switch proxy failure' }
    if ($Uri -like '*/api/analyze') { return @{StatusCode=200;Content='{"total":2,"participant_count":2}'} }
    return @{StatusCode=200;Content='synthetic'}
}
function docker {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
    $global:LASTEXITCODE=0
    $a=$Arguments
    switch ($a[0]) {
        'info' { return 'linux' }
        'container' { return @($global:KakaoMock_containers.Keys) }
        'network' {
            if ($a[1] -eq 'ls') { return @($global:KakaoMock_networks.Keys) }
            if ($a[1] -eq 'create') { $global:KakaoMock_networks['kakao-chat-net']=@{Labels=@{'io.kakao.deploy.repository'=$global:KakaoMock_repo}};return 'net' }
            return ConvertTo-Json -InputObject @($global:KakaoMock_networks['kakao-chat-net']) -Depth 8 -Compress
        }
        'volume' {
            if ($a[1] -eq 'ls') { return @($global:KakaoMock_volumes.Keys) }
            if ($a[1] -eq 'create') { $global:KakaoMock_volumes['kakao-chat-nginx-config']=@{Labels=@{'io.kakao.deploy.repository'=$global:KakaoMock_repo}};return 'vol' }
            return ConvertTo-Json -InputObject @($global:KakaoMock_volumes['kakao-chat-nginx-config']) -Depth 8 -Compress
        }
        'manifest' { return '{}' }
        'pull' {
            if ($global:KakaoMock_mode -eq 'pull-failure') { $global:LASTEXITCODE=1;return }
            return 'synthetic pull'
        }
        'image' { return ConvertTo-Json -InputObject @(@{RepoDigests=@("$global:KakaoMock_images@sha256:$('a'*64)")}) -Compress }
        'inspect' {
            if ($a -contains '--format') { return '{"Running":true}' }
            return ConvertTo-Json -InputObject @($global:KakaoMock_containers[$a[1]]) -Depth 8 -Compress
        }
        'run' {
            $name=$a[[array]::IndexOf($a,'--name')+1]
            $labels=@{}
            for ($i=0;$i -lt $a.Length;$i++) {
                if ($a[$i] -eq '--label') { $parts=$a[$i+1].Split('=',2);$labels[$parts[0]]=$parts[1] }
            }
            $global:KakaoMock_containers[$name]=@{Name=$name;Config=@{Labels=$labels};State=@{Running=$true};Id="id-$name"}
            if ($name -eq 'kakao-chat-proxy') {
                Assert ($global:KakaoMock_config -match '# kakao-version=(sha-[0-9a-f]{40})') 'initial config exists'
                $global:KakaoMock_routed=$Matches[1]
            }
            return "id-$name"
        }
        'cp' { $global:KakaoMock_pending=[IO.File]::ReadAllText($a[1]);return }
        'exec' {
            if ($a[2] -eq 'python') {
                if ($global:KakaoMock_mode -eq 'candidate-failure') { $global:LASTEXITCODE=1 }
                return
            }
            if ($a[2] -eq 'cat') {
                if ($a[3] -like '/proc/*') { return "$global:KakaoMock_worker " }
                return $global:KakaoMock_config
            }
            if ($a[2] -eq 'mv') { $global:KakaoMock_config=$global:KakaoMock_pending;return }
            if ($a -contains '-t') {
                if ($global:KakaoMock_mode -eq 'config-failure') { $global:KakaoMock_mode='';$global:LASTEXITCODE=1 }
                return
            }
            if ($a -contains 'reload') {
                Assert ($global:KakaoMock_config -match '# kakao-version=(sha-[0-9a-f]{40})') 'reload config exists'
                $global:KakaoMock_routed=$Matches[1];$global:KakaoMock_worker++;return
            }
            throw "Unexpected docker exec: $($a -join ' ')"
        }
        'rm' { $name=$a[-1];$global:KakaoMock_removed+=,$name;$global:KakaoMock_containers.Remove($name);return $name }
        'logs' { return 'synthetic logs only' }
        default { throw "Unexpected mock Docker command: $($a[0])" }
    }
}
function Deploy([int]$Number,[string]$Digit,[string]$Failure='') {
    $global:KakaoMock_runNumber=$Number
    $global:KakaoMock_sha=$Digit*40
    $global:KakaoMock_mode=$Failure
    & (Join-Path $PSScriptRoot 'Deploy.ps1') -Repository $global:KakaoMock_repo -CommitSha $global:KakaoMock_sha -CiRunId $Number -CiRunNumber $Number -ImageName $global:KakaoMock_images -StateDirectory $global:KakaoMock_state -ReadySamples 1 -StabilizeSeconds 1
}
try {
    Deploy 1 '1'
    Assert ($global:KakaoMock_routed -eq ('sha-'+('1'*40))) 'initial blue version'
    $proxyId=$global:KakaoMock_containers['kakao-chat-proxy'].Id
    Deploy 2 '2'
    Assert ($global:KakaoMock_routed -eq ('sha-'+('2'*40))) 'green switch'
    Assert ($global:KakaoMock_containers['kakao-chat-proxy'].Id -eq $proxyId) 'proxy not recreated'
    Assert ($global:KakaoMock_containers.ContainsKey('kakao-chat-blue')) 'prior app retained'
    foreach ($failure in @('pull-failure','candidate-failure','config-failure','proxy-failure')) {
        $failed=$false
        try { Deploy 3 '3' $failure } catch { $failed=$true }
        Assert $failed "$failure reports failure"
        Assert ($global:KakaoMock_routed -eq ('sha-'+('2'*40))) "$failure retains/restores active version"
        Assert ($global:KakaoMock_containers.ContainsKey('kakao-chat-green')) 'active app never removed'
    }
    $global:KakaoMock_stale=$true
    $before=$global:KakaoMock_removed.Count
    Deploy 4 '4'
    Assert ($global:KakaoMock_removed.Count -eq $before) 'stale CI has no container removals'
    $global:KakaoMock_stale=$false
    $before=$global:KakaoMock_removed.Count
    Deploy 1 '1'
    Assert ($global:KakaoMock_removed.Count -eq $before) 'persisted newer run prevents rollback by older CI'
    Deploy 2 '2'
    Assert ($global:KakaoMock_containers['kakao-chat-proxy'].Id -eq $proxyId) 'same-version no-op'
    $before=$global:KakaoMock_removed.Count
    $global:KakaoMock_containers['kakao-chat-proxy'].Config.Labels['io.kakao.deploy.repository']='unrelated/repository'
    $failed=$false
    try { Deploy 5 '5' } catch { $failed=$true }
    Assert $failed 'foreign resource collision fails closed'
    Assert ($global:KakaoMock_removed.Count -eq $before) 'foreign resource is not removed'
    Write-Host 'PASS: mocked initial deploy, blue-green switch, pull/candidate/config/proxy failures, rollback, stale/newer skip, idempotency and ownership protection'
} finally { $env:GITHUB_TOKEN=$global:KakaoMock_oldToken }
