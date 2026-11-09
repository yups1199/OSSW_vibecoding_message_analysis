$ErrorActionPreference='Stop'

function Write-EvidenceEvent([string]$Directory,[string]$Name,[hashtable]$Data=@{}) {
    $record=@{timestamp_utc=[DateTimeOffset]::UtcNow.ToString('o');name=$Name;data=$Data}
    [IO.File]::AppendAllText((Join-Path $Directory 'events.jsonl'),(($record|ConvertTo-Json -Depth 6 -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))
}
function Read-MonitorRows([string]$Directory) {
    $path=Join-Path $Directory 'requests.csv'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    # Snapshot complete lines only while the independent writer is appending.
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8)
    try { $text=$reader.ReadToEnd() } finally { $reader.Dispose() }
    $lastNewline=$text.LastIndexOf("`n")
    if ($lastNewline -lt 0) { return @() }
    return @($text.Substring(0,$lastNewline+1)|ConvertFrom-Csv)
}
function Assert-MonitorJob($Job,[string]$Directory,[switch]$AllowFailures) {
    if ($Job.State -ne 'Running') { throw "HTTP monitor is not running: $($Job.State)" }
    $heartbeat=Join-Path $Directory 'heartbeat.txt'
    if ((Test-Path -LiteralPath $heartbeat) -and ([DateTime]::UtcNow-(Get-Item -LiteralPath $heartbeat).LastWriteTimeUtc).TotalSeconds -gt 10) { throw 'HTTP monitor heartbeat stalled' }
    if (-not $AllowFailures -and (Test-Path (Join-Path $Directory 'failure.marker'))) { throw 'Independent HTTP monitor observed a failed request; see requests.csv' }
}
function Wait-MonitorPhase($Job,[string]$Directory,[string]$Phase,[double]$Seconds,[switch]$AllowFailures,[DateTimeOffset]$Since=[DateTimeOffset]::MinValue) {
    $deadline=[DateTime]::UtcNow.AddSeconds($Seconds+20)
    do {
        Assert-MonitorJob -Job $Job -Directory $Directory -AllowFailures:$AllowFailures
        $rows=@(Read-MonitorRows $Directory | Where-Object { $_.phase -eq $Phase -and $_.timestamp_utc -and [DateTimeOffset]::Parse($_.timestamp_utc) -ge $Since })
        if ($rows.Count -gt 1) {
            try {
                $span=([DateTimeOffset]::Parse($rows[-1].timestamp_utc)-[DateTimeOffset]::Parse($rows[0].timestamp_utc)).TotalSeconds
                if ($span -ge $Seconds) { return }
            } catch { } # A currently appended CSV row may not be complete yet.
        }
        if ([DateTime]::UtcNow -ge $deadline) { throw "Monitor did not record a continuous $Seconds-second $Phase window" }
        Start-Sleep -Milliseconds 250
    } while ($true)
}
function Test-DeployedFeature([string]$BaseUri) {
    $html=Invoke-WebRequest -UseBasicParsing -Uri "$BaseUri/" -TimeoutSec 5 -DisableKeepAlive
    if ($html.StatusCode -ne 200 -or $html.Content -notmatch 'data-feature="busiest-weekday-v1"') { throw 'New weekday highlight UI marker is absent' }
    $sample="2026. 11. 8. 09:00, SyntheticA : hello project`n2026. 11. 8. 09:02, SyntheticB : hello friend"
    $response=Invoke-WebRequest -UseBasicParsing -Uri "$BaseUri/api/analyze" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($sample)) -ContentType 'text/plain' -TimeoutSec 5
    $body=$response.Content|ConvertFrom-Json
    if ($response.StatusCode -ne 200 -or $body.total -ne 2 -or $body.busiest_weekday.message_count -ne 2 -or $body.busiest_weekday.weekday_indexes.Count -ne 1 -or $body.busiest_weekday.weekday_indexes[0] -ne 6 -or $body.busiest_weekday.ratio -ne 100) { throw 'New weekday highlight API verification failed' }
}
function Get-MonitorResult {
    param([string]$Directory,[string]$TargetVersion,[double]$BeforeSeconds=10,[double]$AfterSeconds=30,[bool]$DeploySucceeded=$false,[bool]$MonitorStopped=$false,[bool]$RequireCompletion=$true,[string]$Mode='deployment',[string]$Failure='')
    $rows=@(Read-MonitorRows $Directory)
    $eventsPath=Join-Path $Directory 'events.jsonl'
    $events=if (Test-Path $eventsPath) { @(Get-Content -LiteralPath $eventsPath -Encoding UTF8|Where-Object {$_}|ForEach-Object {$_|ConvertFrom-Json}) } else {@()}
    $phases=@{}
    foreach ($phase in @('before','during','after')) {
        $part=@($rows|Where-Object {$_.phase -eq $phase})
        $span=if ($part.Count -gt 1) {([DateTimeOffset]::Parse($part[-1].timestamp_utc)-[DateTimeOffset]::Parse($part[0].timestamp_utc)).TotalSeconds} else {0}
        $phases[$phase]=@{count=$part.Count;success=@($part|Where-Object {$_.success -eq 'True'}).Count;failure=@($part|Where-Object {$_.success -ne 'True'}).Count;span_seconds=$span}
    }
    $good=@($rows|Where-Object {$_.success -eq 'True'})
    $beforeGood=@($good|Where-Object {$_.phase -eq 'before'})
    $oldVersion=if ($beforeGood.Count) {$beforeGood[0].version} else {''}
    $lastVersion=if ($good.Count) {$good[-1].version} else {''}
    $failures=@($rows|Where-Object {$_.success -ne 'True' -or $_.http_status -ne '200'})
    $gaps=@($rows|ForEach-Object {[double]::Parse($_.gap_ms,[Globalization.CultureInfo]::InvariantCulture)})
    $latencies=@($rows|ForEach-Object {[double]::Parse($_.latency_ms,[Globalization.CultureInfo]::InvariantCulture)})
    $maxGap=if ($gaps.Count) {($gaps|Measure-Object -Maximum).Maximum} else {0}
    $maxLatency=if ($latencies.Count) {($latencies|Measure-Object -Maximum).Maximum} else {0}
    $duringOld=@($good|Where-Object {$_.phase -eq 'during' -and $_.version -eq $oldVersion}).Count
    $duringNew=@($good|Where-Object {$_.phase -eq 'during' -and $_.version -eq $TargetVersion}).Count
    $badVersion=@($good|Where-Object {($_.phase -eq 'before' -and $_.version -ne $oldVersion) -or ($_.phase -eq 'after' -and $_.version -ne $TargetVersion) -or ($_.phase -eq 'during' -and $_.version -notin @($oldVersion,$TargetVersion))}).Count
    $feature=@($events|Where-Object {$_.name -eq 'FeatureVerified'}).Count -gt 0
    $completed=@($events|Where-Object {$_.name -eq 'DeploymentCompleted'}).Count -gt 0
    $completion=@($events|Where-Object {$_.name -eq 'DeploymentCompleted'}|Select-Object -Last 1)
    $postCompletionSpan=if($completion.Count -and $rows.Count){([DateTimeOffset]::Parse($rows[-1].timestamp_utc)-[DateTimeOffset]::Parse($completion[0].timestamp_utc)).TotalSeconds}else{0}
    $rollbacks=@($events|Where-Object {$_.name -like 'Rollback*'})
    $firstNew=@($good|Where-Object {$_.version -eq $TargetVersion}|Select-Object -First 1)
    $reasons=New-Object Collections.Generic.List[string]
    if (-not $DeploySucceeded) {$reasons.Add('Deployment did not succeed')}
    if ($RequireCompletion -and -not $MonitorStopped) {$reasons.Add('Independent monitor did not stop normally')}
    if ($rows.Count -eq 0) {$reasons.Add('No actual HTTP samples')}
    if ($failures.Count) {$reasons.Add('Failed HTTP requests were observed')}
    if ($maxGap -gt 2500) {$reasons.Add('Monitoring gap exceeded 2500 ms')}
    if ($phases.before.span_seconds -lt $BeforeSeconds -or $phases.before.count -lt ([Math]::Floor($BeforeSeconds)+1)) {$reasons.Add('Before window is incomplete')}
    if ($phases.after.span_seconds -lt $AfterSeconds -or $phases.after.count -lt ([Math]::Floor($AfterSeconds)+1)) {$reasons.Add('After window is incomplete')}
    if (-not $oldVersion -or $oldVersion -eq $TargetVersion -or -not $duringOld -or -not $duringNew) {$reasons.Add('Old-to-new version change was not observed during deployment')}
    if ($badVersion) {$reasons.Add('Unexpected phase/version sequence')}
    if (-not $feature) {$reasons.Add('New feature API/UI marker was not verified')}
    if ($RequireCompletion -and -not $completed) {$reasons.Add('Deployment completion event is missing')}
    if ($RequireCompletion -and $postCompletionSpan -lt $AfterSeconds) {$reasons.Add('Post-completion observation window is incomplete')}
    if ($rollbacks.Count) {$reasons.Add('Rollback occurred')}
    for ($i=0;$i -lt $rows.Count;$i++) {if ([int]$rows[$i].sequence -ne $i+1) {$reasons.Add('Missing or reordered sample sequence');break}}
    if ($Failure) {$reasons.Add($Failure)}
    $passed=($reasons.Count -eq 0)
    return [ordered]@{
        mode=$Mode;validation_passed=$passed;zero_downtime_verified=($passed -and $Mode -eq 'deployment')
        observation=if($passed){'No interruption observed in the sampled validation window; not an absolute guarantee.'}else{'NOT VERIFIED: failures, missing evidence or deployment errors; inspect CSV and events.'}
        old_version=$oldVersion;target_version=$TargetVersion;final_version=$lastVersion
        started_utc=if($rows.Count){$rows[0].timestamp_utc}else{$null};ended_utc=if($rows.Count){$rows[-1].timestamp_utc}else{$null}
        first_new_version_utc=if($firstNew.Count){$firstNew[0].timestamp_utc}else{$null}
        requests=$rows.Count;success=$good.Count;failure=$failures.Count;max_latency_ms=$maxLatency;max_gap_ms=$maxGap
        phases=$phases;post_completion_seconds=$postCompletionSpan;feature_verified=$feature;rollback_events=$rollbacks;events=$events;reasons=@($reasons.ToArray())
    }
}
function Write-MonitorReport($Result,[string]$Directory) {
    $enc=New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $Directory 'summary.json'),($Result|ConvertTo-Json -Depth 10),$enc)
    $lines=New-Object Collections.Generic.List[string]
    $lines.Add('# Zero-Downtime Redeployment Verification')
    $lines.Add("Mode: **$($Result.mode)** | Validation passed: **$($Result.validation_passed)** | Deployment proof: **$($Result.zero_downtime_verified)**")
    $lines.Add($Result.observation)
    $lines.Add('## Before Deployment')
    $lines.Add("- Existing version: ``$($Result.old_version)``")
    $lines.Add("- Requests: $($Result.phases.before.count); failures: $($Result.phases.before.failure); observed span: $($Result.phases.before.span_seconds) seconds")
    $lines.Add('## During Deployment')
    $lines.Add("- Target version: ``$($Result.target_version)``")
    $lines.Add("- Requests: $($Result.phases.during.count); failures: $($Result.phases.during.failure)")
    $lines.Add("- First observed new version: $($Result.first_new_version_utc)")
    foreach ($event in $Result.events) { $lines.Add("- $($event.timestamp_utc) **$($event.name)**: $(($event.data|ConvertTo-Json -Compress))") }
    $lines.Add('## After Deployment')
    $lines.Add("- Final observed version: ``$($Result.final_version)``")
    $lines.Add("- New feature API + UI marker verified: **$($Result.feature_verified)** (browser rendering is checked separately)")
    $lines.Add("- Requests: $($Result.phases.after.count); failures: $($Result.phases.after.failure); observed span: $($Result.phases.after.span_seconds) seconds")
    $lines.Add("- Observation after deployment success: $($Result.post_completion_seconds) seconds")
    $lines.Add('## Overall HTTP observations (UTC)')
    $lines.Add("- Start: $($Result.started_utc); end: $($Result.ended_utc)")
    $lines.Add("- Total: $($Result.requests); successes: $($Result.success); failures: $($Result.failure)")
    $lines.Add("- Maximum latency: $($Result.max_latency_ms) ms; maximum sample gap: $($Result.max_gap_ms) ms")
    foreach($reason in $Result.reasons) {$lines.Add("- NOT VERIFIED: $reason")}
    $text=($lines -join "`n")+"`n"
    [IO.File]::WriteAllText((Join-Path $Directory 'summary.md'),$text,$enc)
    if($env:GITHUB_STEP_SUMMARY){[IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,$text,$enc)}
    Write-Host $text
}
Export-ModuleMember -Function Write-EvidenceEvent,Read-MonitorRows,Assert-MonitorJob,Wait-MonitorPhase,Test-DeployedFeature,Get-MonitorResult,Write-MonitorReport
