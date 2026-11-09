[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Repository,
    [Parameter(Mandatory=$true)][string]$CommitSha,
    [Parameter(Mandatory=$true)][long]$CiRunId,
    [Parameter(Mandatory=$true)][long]$CiRunNumber,
    [Parameter(Mandatory=$true)][string]$ImageName,
    [string]$OutputDirectory=$env:KAKAO_EVIDENCE_DIR,
    [string]$StateDirectory=(Join-Path $env:LOCALAPPDATA 'kakao-chat-analyzer-deploy'),
    [string]$BaseUri='http://127.0.0.1:8000',
    [ValidateRange(500,1000)][int]$IntervalMilliseconds=500,
    [int]$BeforeSeconds=10,
    [int]$AfterSeconds=30,
    [ValidateSet('deployment','local-http-test')][string]$Mode='deployment',
    [string]$DeploymentScript=(Join-Path $PSScriptRoot 'Deploy.ps1')
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Monitoring.psm1') -Force -DisableNameChecking
if (-not $OutputDirectory) { $OutputDirectory=Join-Path (Split-Path -Parent $PSScriptRoot) ".deploy-state/monitor-$([guid]::NewGuid().ToString('N'))" }
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$null=New-Item -ItemType Directory -Force -Path $OutputDirectory
if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count) { throw 'Evidence directory must be new and empty' }
$job=$null; $deploymentOK=$false; $monitorStopped=$false; $failure=''; $proof=$null
$encoding=New-Object Text.UTF8Encoding($false)
try {
    if ($CommitSha -notmatch '^[0-9a-f]{40}$') { throw 'Invalid target commit SHA' }
    if ($Mode -eq 'deployment' -and ($BeforeSeconds -lt 10 -or $AfterSeconds -lt 30 -or $BaseUri -ne 'http://127.0.0.1:8000' -or [IO.Path]::GetFullPath($DeploymentScript) -ne [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Deploy.ps1')))) { throw 'Production proof requires the real deployment, user URL, >=10s before and >=30s after' }
    if ($BeforeSeconds -lt 1 -or $AfterSeconds -lt 1) { throw 'Observation windows must be positive' }
    Write-EvidenceEvent $OutputDirectory 'VerificationStarted' @{mode=$Mode;image="${ImageName}:sha-$CommitSha";target_version="sha-$CommitSha";health_uri="$BaseUri/health"}
    $job=Start-Job -FilePath (Join-Path $PSScriptRoot 'Monitor-Http.ps1') -ArgumentList $OutputDirectory,"$BaseUri/health",$IntervalMilliseconds,2000,1200
    Wait-MonitorPhase -Job $job -Directory $OutputDirectory -Phase before -Seconds $BeforeSeconds
    $before=@(Read-MonitorRows $OutputDirectory|Where-Object {$_.phase -eq 'before' -and $_.success -eq 'True'})
    if (-not $before.Count) { throw 'No successful baseline requests' }
    if ($before[0].version -eq "sha-$CommitSha") { throw 'Target is already active: no old-to-new transition can be verified' }
    Write-EvidenceEvent $OutputDirectory 'BeforeVerified' @{version=$before[0].version;samples=$before.Count}
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'during.marker'),[DateTimeOffset]::UtcNow.ToString('o'),$encoding)
    Write-EvidenceEvent $OutputDirectory 'DeploymentStarted' @{target_version="sha-$CommitSha"}
    $context=@{Job=$job;Directory=$OutputDirectory;BaseUri=$BaseUri;AfterSeconds=$AfterSeconds;BeforeSeconds=$BeforeSeconds;TargetVersion="sha-$CommitSha";Mode=$Mode}
    $afterValidation={
        param($Context)
        [IO.File]::WriteAllText((Join-Path $Context.Directory 'after.marker'),[DateTimeOffset]::UtcNow.ToString('o'))
        Write-EvidenceEvent $Context.Directory 'AfterValidationStarted' @{target_version=$Context.TargetVersion}
        Wait-MonitorPhase -Job $Context.Job -Directory $Context.Directory -Phase after -Seconds $Context.AfterSeconds
        Test-DeployedFeature $Context.BaseUri
        Write-EvidenceEvent $Context.Directory 'FeatureVerified' @{feature='busiest-weekday-v1';checks='synthetic API and served HTML marker; not browser rendering'}
        Assert-MonitorJob -Job $Context.Job -Directory $Context.Directory
        $window=Get-MonitorResult -Directory $Context.Directory -TargetVersion $Context.TargetVersion -BeforeSeconds $Context.BeforeSeconds -AfterSeconds $Context.AfterSeconds -DeploySucceeded $true -RequireCompletion $false -Mode $Context.Mode
        if (-not $window.validation_passed) { throw "Observation gate failed: $($window.reasons -join '; ')" }
    }
    # Start-Job remains independent while this synchronous deploy prepares and switches.
    # The callback runs after route/probe/stability/drain but before committing success,
    # so a failed After observation still enters Deploy.ps1's normal rollback path.
    & $DeploymentScript -Repository $Repository -CommitSha $CommitSha -CiRunId $CiRunId -CiRunNumber $CiRunNumber -ImageName $ImageName -StateDirectory $StateDirectory -EvidenceDirectory $OutputDirectory -PostSwitchValidation $afterValidation -ValidationContext $context
    $deploymentOK=$true
    # Also retain a full observation window after Deploy.ps1 has returned success.
    # The earlier callback is the rollback gate; this is post-completion evidence.
    Write-EvidenceEvent $OutputDirectory 'PostCompletionObservationStarted' @{}
    Wait-MonitorPhase -Job $job -Directory $OutputDirectory -Phase after -Seconds $AfterSeconds -Since ([DateTimeOffset]::UtcNow)
} catch {
    $failure=$_.Exception.Message
    Write-Warning "Redeployment verification failed: $failure"
    Write-EvidenceEvent $OutputDirectory 'VerificationFailed' @{reason=$failure}
} finally {
    if ($job) {
        try {
            if ($job.State -eq 'Running') {
                if (-not (Test-Path (Join-Path $OutputDirectory 'after.marker'))) {
                    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'after.marker'),[DateTimeOffset]::UtcNow.ToString('o'),$encoding)
                    Write-EvidenceEvent $OutputDirectory 'AfterFailureObservationStarted' @{}
                }
                # Even deployment errors retain >=30s of subsequent evidence where possible.
                Wait-MonitorPhase -Job $job -Directory $OutputDirectory -Phase after -Seconds $AfterSeconds -AllowFailures
            }
        } catch { if (-not $failure) {$failure=$_.Exception.Message}; Write-Warning $_.Exception.Message }
        [IO.File]::WriteAllText((Join-Path $OutputDirectory 'stop.marker'),'stop',$encoding)
        $null=Wait-Job -Job $job -Timeout 10
        if ($job.State -eq 'Running') { Stop-Job -Job $job; if (-not $failure) {$failure='Monitor did not stop within timeout'} }
        $monitorStopped=($job.State -eq 'Completed')
        $stopFile=Join-Path $OutputDirectory 'stopped.json'
        if (Test-Path $stopFile) { $stopped=Get-Content -LiteralPath $stopFile -Raw|ConvertFrom-Json; $monitorStopped=$monitorStopped -and ($stopped.reason -eq 'stop_marker') } else {$monitorStopped=$false}
        $null=Receive-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job
    }
    try {
        $proof=Get-MonitorResult -Directory $OutputDirectory -TargetVersion "sha-$CommitSha" -BeforeSeconds $BeforeSeconds -AfterSeconds $AfterSeconds -DeploySucceeded $deploymentOK -MonitorStopped $monitorStopped -Mode $Mode -Failure $failure
        Write-MonitorReport -Result $proof -Directory $OutputDirectory
    } catch {
        $failure="Evidence analysis failed: $($_.Exception.Message)"
        $text="## Zero-Downtime Verification: NOT VERIFIED`n$failure`nRaw monitoring logs are retained in the artifact.`n"
        [IO.File]::WriteAllText((Join-Path $OutputDirectory 'summary.md'),$text,$encoding)
        if($env:GITHUB_STEP_SUMMARY){[IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,$text,$encoding)}
    }
}
if (-not $proof -or -not $proof.validation_passed) { throw 'Redeployment/HTTP evidence validation failed; inspect Summary and artifact' }
