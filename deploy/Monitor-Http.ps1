# Independent sampler. Writes only health metadata, never chat/request bodies.
param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$HealthUri = 'http://127.0.0.1:8000/health',
    [ValidateRange(500,1000)][int]$IntervalMilliseconds = 500,
    [ValidateRange(100,10000)][int]$TimeoutMilliseconds = 2000,
    [ValidateRange(1,7200)][int]$MaxDurationSeconds = 1200
)
$ErrorActionPreference='Stop'
$uri=[Uri]$HealthUri
if ($uri.Scheme -ne 'http' -or $uri.Host -notin @('127.0.0.1','localhost') -or $uri.AbsolutePath -ne '/health' -or $uri.Query -or $uri.Fragment) { throw 'Only loopback /health is permitted' }
$null=New-Item -ItemType Directory -Force -Path $OutputDirectory
$csvPath=Join-Path $OutputDirectory 'requests.csv'
if (Test-Path -LiteralPath $csvPath) { throw 'Refusing to overwrite existing monitoring evidence' }
$encoding=New-Object Text.UTF8Encoding($false)
$writer=New-Object IO.StreamWriter($csvPath,$false,$encoding)
$clock=[Diagnostics.Stopwatch]::StartNew()
$sequence=0
$previousStart=0.0
$nextSample=0.0
$stopReason='unexpected_error'
try {
    $writer.WriteLine('sequence,timestamp_utc,phase,http_status,latency_ms,version,success,error,gap_ms')
    $writer.Flush()
    while ($clock.Elapsed.TotalSeconds -lt $MaxDurationSeconds) {
        if (Test-Path -LiteralPath (Join-Path $OutputDirectory 'stop.marker')) { $stopReason='stop_marker'; break }
        $start=$clock.Elapsed.TotalMilliseconds
        $timestamp=[DateTimeOffset]::UtcNow.ToString('o')
        $phase=if (Test-Path (Join-Path $OutputDirectory 'after.marker')) { 'after' } elseif (Test-Path (Join-Path $OutputDirectory 'during.marker')) { 'during' } else { 'before' }
        $code=0; $version=''; $success=$false; $errorText=''; $response=$null
        $latency=[Diagnostics.Stopwatch]::StartNew()
        try {
            $request=[Net.HttpWebRequest]::Create($uri)
            $request.Method='GET'; $request.Timeout=$TimeoutMilliseconds
            $request.ReadWriteTimeout=$TimeoutMilliseconds; $request.KeepAlive=$false
            $request.Proxy=$null
            $response=$request.GetResponse()
            $code=[int]$response.StatusCode
            $reader=New-Object IO.StreamReader($response.GetResponseStream())
            try { $health=$reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            if ($health.status -ne 'ok' -or $health.version -notmatch '^sha-[0-9a-f]{40}$') { throw 'Invalid health status or deployment version' }
            $version=[string]$health.version
            $success=($code -eq 200)
            if (-not $success) { $errorText="HTTP $code" }
        } catch {
            $errorText=$_.Exception.GetBaseException().Message.Replace("`r",' ').Replace("`n",' ')
            if ($_.Exception.Response) {
                $response=$_.Exception.Response
                try { $code=[int]$response.StatusCode } catch { $code=0 }
            }
        } finally {
            $latency.Stop()
            if ($response) { $response.Close() }
        }
        $sequence++
        $gap=if ($sequence -eq 1) { 0 } else { $start-$previousStart }
        $record=[pscustomobject][ordered]@{
            sequence=$sequence; timestamp_utc=$timestamp; phase=$phase; http_status=$code
            latency_ms=[Math]::Round($latency.Elapsed.TotalMilliseconds,3).ToString([Globalization.CultureInfo]::InvariantCulture)
            version=$version; success=$success; error=$errorText
            gap_ms=[Math]::Round($gap,3).ToString([Globalization.CultureInfo]::InvariantCulture)
        }
        $line=@($record | ConvertTo-Csv -NoTypeInformation)[1]
        $writer.WriteLine($line); $writer.Flush()
        [IO.File]::WriteAllText((Join-Path $OutputDirectory 'heartbeat.txt'),"$sequence",$encoding)
        if ($sequence -eq 1) { [IO.File]::WriteAllText((Join-Path $OutputDirectory 'started.json'),(@{timestamp_utc=$timestamp}|ConvertTo-Json),$encoding) }
        if (-not $success) { [IO.File]::WriteAllText((Join-Path $OutputDirectory 'failure.marker'),"$timestamp $errorText",$encoding) }
        $previousStart=$start
        $nextSample=[Math]::Max($nextSample+$IntervalMilliseconds,$clock.Elapsed.TotalMilliseconds)
        $delay=[int]($nextSample-$clock.Elapsed.TotalMilliseconds)
        if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
    }
    if ($stopReason -eq 'unexpected_error') { $stopReason='duration_limit' }
} finally {
    $writer.Dispose()
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'stopped.json'),(@{timestamp_utc=[DateTimeOffset]::UtcNow.ToString('o'); reason=$stopReason; samples=$sequence}|ConvertTo-Json),$encoding)
}
