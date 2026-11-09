# Test double only: no Docker, GitHub, registry or production operations.
param($Repository,$CommitSha,$CiRunId,$CiRunNumber,$ImageName,$StateDirectory,
      $EvidenceDirectory,$PostSwitchValidation,$ValidationContext)
$ErrorActionPreference='Stop'
Write-EvidenceEvent $EvidenceDirectory 'CandidateReady' @{simulation=$true}
$case=Invoke-RestMethod -Uri "$($ValidationContext.BaseUri)/test-case"
if($case.mode -eq 'monitor-stop') { Stop-Job -Job $ValidationContext.Job }
Start-Sleep -Seconds 2
$null=Invoke-WebRequest -UseBasicParsing -Uri "$($ValidationContext.BaseUri)/test-switch" -Method Post
Write-EvidenceEvent $EvidenceDirectory 'RouteReloaded' @{simulation=$true}
Start-Sleep -Seconds 2
& $PostSwitchValidation $ValidationContext
Write-EvidenceEvent $EvidenceDirectory 'DeploymentCompleted' @{simulation=$true}
