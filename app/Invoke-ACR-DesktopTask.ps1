#Requires -Version 5.1
<# Noninteractive desktop worker. It uses the retained patch transformations with expanded, verified wet presets.
The graphical confirmation grants consent; this worker still checks package integrity,
Windows permissions, exact file state, and local preflight. No network/system controls. #>
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][ValidateSet('Check','Install','Restore','Snapshot','DriveTrace','Support')][string]$Action,
 [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{32}$')][string]$TaskId,
 [Parameter(Mandatory=$true)][string]$TaskDirectory,
 [Parameter(Mandatory=$true)][string]$RequestOwnerSid,
 [string]$GameRoot='',
 [ValidateSet('0','0.00025','0.0005','0.001','0.002','0.005','0.01','0.02','0.05','0.1')][string]$RateScale='0.005',
 [ValidateSet('Off','VeryLight','Light','Mild','Balanced','Moderate','Firm','Strong','Maximum')][string]$WetTarmac='Moderate',
 [ValidateSet('Off','Enhanced','Strong')][string]$VisualDamage='Off',
 [ValidateSet('Stock','Sensitive','Strong')][string]$CollisionDamage='Stock',
 [ValidateSet('Stock','Native')][string]$TyreDamage='Stock',
 [ValidateSet('Stock','Earlier85','Earlier90')][string]$MechanicalFailures='Stock',
 [ValidateSet('Stock','Native')][string]$BrakeWear='Stock',
 [ValidateSet('Stock','Easier','Aggressive')][string]$Detachment='Stock',
 [ValidateSet('Stock','Cumulative')][string]$CriticalDamage='Stock',
 [ValidateSet('Stock','EngineBay')][string]$CoolingRouting='Stock',
 [ValidateSet('Stock','Matched')][string]$EngineImpact='Stock',
 [ValidateSet('Stock','Progressive')][string]$PowerResponse='Stock',
 [ValidateSet('Stock','Localized','Bent')][string]$WheelImpact='Stock',
 [ValidateSet('Stock','Grinding','Impact','Responsive','Mechanical','Engagement','Consequences')][string]$GearboxDamage='Stock',
 [string]$CustomJsonBase64='',
 [switch]$Consent
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$exitCode=1;$core=$null
$response=[ordered]@{Schema=1;Tool='GripHappensDesktop';Version='1.0.1';EngineVersion='1.0.1';TaskId=$TaskId;Action=$Action;Status='Failed';Phase='Startup';Core=$null;Error='';OutputFiles=@();UTC=[DateTime]::UtcNow.ToString('o')}
$validDirectory=$false;$log=$null;$call=$null
$response['RecordingTakeId']='';$response['RecordingResetCount']=0
$response['LoggingError']=''
$response['UtilityBuild']='1.0.1'
$response['InstallSafetyMilliseconds']=$null
$taskClock=[Diagnostics.Stopwatch]::StartNew()
function Invoke-ACRDesktopCue([ValidateSet('Snapshot','DriveStart','DriveEnd')][string]$Cue) {
 try {
  switch($Cue) {
   'Snapshot' {$sound=[System.Media.SystemSounds]::Asterisk}
   'DriveStart' {$sound=[System.Media.SystemSounds]::Beep}
   'DriveEnd' {$sound=[System.Media.SystemSounds]::Exclamation}
  }
  if($null -ne $sound){$sound.Play()}
 } catch { }
}
function Set-DesktopPhase([string]$Text,[string]$TakeId='') {
 if($TakeId){$response.RecordingTakeId=$TakeId}
 $response.Phase=$Text
 Save-ACRJson (Join-Path $TaskDirectory 'progress.json') ([ordered]@{TaskId=$TaskId;Text=$Text;RecordingTakeId=$response.RecordingTakeId})
 if($Text -like 'Recording started*'){Invoke-ACRDesktopCue 'DriveStart'}
 elseif($Text -like 'Recording finished*' -or $Text -like 'Recording stopped and saved*'){Invoke-ACRDesktopCue 'DriveEnd'}
}
try {
 Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Common.psm1') -ErrorAction Stop
 Import-Module (Join-Path $PSScriptRoot 'modules\ACR.TaskLog.psm1') -ErrorAction Stop
 Assert-ACRWindows
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 try {$sid=$identity.User.Value} finally {$identity.Dispose()}
 if($sid -cne $RequestOwnerSid) {$exitCode=5;throw 'The administrator account differs from the account that opened the mod. Reopen the utility using that administrator account so backups and reports remain together.'}
 $expectedRoot=Join-Path (Get-ACRUserStateRoot) 'DesktopTasks'
 $expected=[IO.Path]::GetFullPath((Join-Path $expectedRoot $TaskId))
 if(-not [String]::Equals($expected,[IO.Path]::GetFullPath($TaskDirectory),[StringComparison]::OrdinalIgnoreCase)) {throw 'Unexpected task directory.'}
 Assert-ACRNoReparse $TaskDirectory
 $validDirectory=$true;$log=Join-Path $TaskDirectory 'details.log'
 Set-DesktopPhase 'Checking the mod package...'
 $call=New-ACRLoggedCall
 Invoke-ACRLoggedCommand -LogPath $log -State $call -Command {
   & (Join-Path $PSScriptRoot 'Verify-Package.ps1') -Quiet
   $call.ExitCode=$LASTEXITCODE
 }
 Assert-ACRLoggedCallSucceeded $call 'Package integrity check'
 Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Support.psm1') -ErrorAction Stop
 if($Action -in @('Install','Restore','Snapshot','DriveTrace')) {Assert-ACRAdministrator}
 if($Action -eq 'Install' -and -not $Consent) {throw 'Installation was not confirmed. No game change was requested.'}
 if($Action -eq 'Restore' -and -not $Consent) {throw 'Removal was not confirmed. No game change was requested.'}
 if($Action -eq 'Support') {
   Set-DesktopPhase 'Creating a sanitized support report...'
   $call=New-ACRLoggedCall
   Invoke-ACRLoggedCommand -LogPath $log -State $call -CaptureOutput -Command {
     Export-ACRSanitizedSupport (Get-ACRDownloads)
   }
   Assert-ACRLoggedCallSucceeded $call 'Support export'
   if($call.Output.Count -ne 1 -or $call.Output[0] -isnot [string] -or -not [IO.File]::Exists($call.Output[0])) {throw 'Support export did not produce a valid ZIP path.'}
   $response.OutputFiles=@([string]$call.Output[0])
 } elseif($Action -eq 'DriveTrace') {
   Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Recording.psm1') -ErrorAction Stop
   $location=Resolve-ACRInstall $GameRoot ''
   $captureTake={param($takeDirectory,$takeId)
    $call=New-ACRLoggedCall
    Invoke-ACRLoggedCommand -LogPath $log -State $call -Command {
     $captureArgs=@{GameRoot=$location.GameRoot;OutputDirectory=$takeDirectory;RecordSeconds=300;Label='DrivingTrace';StopRequestPath=(Join-Path $TaskDirectory 'stop-recording.request');RecordingTaskDirectory=$TaskDirectory;RecordingTakeId=$takeId}
     & (Join-Path $PSScriptRoot 'Collect-ACR-DamageState.ps1') @captureArgs
     $call.ExitCode=$LASTEXITCODE
    }
    return [pscustomobject]@{ExitCode=$call.ExitCode;ErrorCount=$call.ErrorCount}
   }
   $statusTake={param($takeId,$text)Set-DesktopPhase $text $takeId}
   $recording=Invoke-ACRRecordingLoop $TaskDirectory $captureTake $statusTake
   $response['RecordingTakeId']=$recording.TakeId;$response['RecordingResetCount']=$recording.Resets
   $response.OutputFiles=@($recording.OutputFiles)
   $response['RecordingCompletion']=Get-ACRRecordingCompletion $TaskDirectory $recording.TakeId
   if(-not $recording.Success){throw 'The recording stopped before it could finish. Its local error report and available data belong only to this take. Reset recording can discard it and try a fresh paused-stage capture.'}
 } elseif($Action -eq 'Snapshot') {
   if($Action -eq 'DriveTrace'){Set-DesktopPhase 'Preparing driving recorder. Keep ACR paused until the recorder is ready.'}else{Set-DesktopPhase 'Reading the paused game damage state...'}
   $location=Resolve-ACRInstall $GameRoot ''
   $stage=Join-Path $TaskDirectory 'snapshot';[IO.Directory]::CreateDirectory($stage)|Out-Null
   $call=New-ACRLoggedCall
   Invoke-ACRLoggedCommand -LogPath $log -State $call -Command {
     $captureArgs=@{GameRoot=$location.GameRoot;OutputDirectory=$stage}
     if($Action -eq 'DriveTrace'){$captureArgs.RecordSeconds=300;$captureArgs.Label='DrivingTrace';$captureArgs.StopRequestPath=Join-Path $TaskDirectory 'stop-recording.request'}
     & (Join-Path $PSScriptRoot 'Collect-ACR-DamageState.ps1') @captureArgs
     $call.ExitCode=$LASTEXITCODE
   }
   $snapshotExit=$call.ExitCode
   foreach($f in @(Get-ChildItem -LiteralPath $stage -File)) {
     if($f.Extension -notin @('.zip','.txt')) {continue}
     $dest=Join-Path (Get-ACRDownloads) $f.Name
     [IO.Directory]::CreateDirectory((Get-ACRDownloads))|Out-Null
     [IO.File]::Copy($f.FullName,$dest,$false)
     $response.OutputFiles+= $dest
   }
   if($snapshotExit -ne 0 -or $call.ErrorCount -gt 0) {throw 'The damage snapshot could not finish. The exported local error report identifies the failing step. No game settings were written.'}
   if(@($response.OutputFiles | Where-Object {$_ -like '*.zip'}).Count -eq 0) {throw 'The snapshot returned without an output ZIP.'}
   if($Action -eq 'Snapshot'){Invoke-ACRDesktopCue 'Snapshot'}
 } else {
   $location=Resolve-ACRInstall $GameRoot ''
   $GameRoot=$location.GameRoot
   $argsCore=@{GameRoot=$GameRoot;RateScale=$RateScale;WetTarmac=$WetTarmac;VisualDamage=$VisualDamage;CollisionDamage=$CollisionDamage;TyreDamage=$TyreDamage;MechanicalFailures=$MechanicalFailures;BrakeWear=$BrakeWear;Detachment=$Detachment;CriticalDamage=$CriticalDamage;CoolingRouting=$CoolingRouting;EngineImpact=$EngineImpact;PowerResponse=$PowerResponse;WheelImpact=$WheelImpact;GearboxDamage=$GearboxDamage;OfflineConfirmed=[bool]$Consent;CustomJsonBase64=$CustomJsonBase64}
   if($Action -eq 'Install') {
     Set-DesktopPhase 'Checking release consistency (full diagnostics are separate)...'
     $testPath=Join-Path $TaskDirectory 'preflight.json'
     $installSafetyClock=[Diagnostics.Stopwatch]::StartNew()
     $call=New-ACRLoggedCall
     Invoke-ACRLoggedCommand -LogPath $log -State $call -Command {
       & (Join-Path $PSScriptRoot 'tests\Test-ACR-InstallSafety.ps1') -OutputPath $testPath
       $call.ExitCode=$LASTEXITCODE
     }
     $response['InstallSafetyMilliseconds']=[math]::Round($installSafetyClock.Elapsed.TotalMilliseconds,2)
     Assert-ACRLoggedCallSucceeded $call 'Local preflight'
     if($call.LoggingError){$response.LoggingError=$call.LoggingError}
   }
   if($Action -eq 'Install') {Set-DesktopPhase 'Checking files, backing up originals, and applying settings...'}
   elseif($Action -eq 'Restore') {Set-DesktopPhase 'Restoring and verifying the original game files...'}
   else {Set-DesktopPhase 'Checking game compatibility and installed settings...'}
   $call=New-ACRLoggedCall
   Invoke-ACRLoggedCommand -LogPath $log -State $call -CaptureOutput -Command {
     & (Join-Path $PSScriptRoot 'Grip-Happens.Core.ps1') -Action $Action @argsCore
   }
   if($call.Output.Count -ne 1) {throw 'The patch engine did not return exactly one structured report.'}
   $core=$call.Output[0];$response.Core=$core
   Assert-ACRLoggedCallSucceeded $call 'Game-file operation'
   if($null -eq $core -or $core.Tool -ne 'GripHappens') {throw 'The patch engine did not return a valid report.'}
   if($core.Status -eq 'Failed') {throw ([string]$core.Error)}
   if($Action -eq 'Check' -and ($core.Before.State -eq 'MixedOrInterrupted' -or $core.Before.NativeModules -eq 'MixedOrInterrupted' -or $core.PreviousWriteJournalPresent)) {throw 'An interrupted or mixed game state needs Restore before playing.'}
   if($null -eq $core.PSObject.Properties['VerifiedConfiguration']) {throw 'The resulting game settings could not be verified.'}
 }
 $response.Status='Success';$exitCode=0
 Set-DesktopPhase 'Finished'
} catch {
 $response.Status='Failed';$response.Error=$_.Exception.Message
 $originalError=$_
 if($log) {
   # Logging is best effort here; do not lose the response if the log is locked.
   try {($originalError | Out-String) | Add-Content -LiteralPath $log -Encoding UTF8}
   catch {$response.LoggingError=$_.Exception.Message}
 }
} finally {
 $response['TotalWorkerMs']=[math]::Round($taskClock.Elapsed.TotalMilliseconds,2)
 if($null -ne $call -and $call.LoggingError){$response.LoggingError=$call.LoggingError}
 if($validDirectory) {
   try {
     # Support and preflight must not erase the useful preceding install/check diagnostic.
     if($Action -ne 'Support') {
       $phase='Preflight';if($Action -eq 'Install'){$phase='Physics'};if($Action -eq 'Restore'){$phase='Restore'};if($Action -eq 'Snapshot'){$phase='Snapshot'}
       if($response.Status -eq 'Success'){$phase='Complete'}
       Save-ACRJson (Join-Path (Get-ACRUserStateRoot) 'latest-diagnostic.json') ([ordered]@{Tool='Grip_Happens_Launcher';Version='1.0.1';Action=$Action;Status=$response.Status;Phase=$phase;Core=$core;Error=$response.Error;UtilityBuild='1.0.1';InstallSafetyMilliseconds=$response.InstallSafetyMilliseconds})
     }
   } catch {
     if(-not $response.LoggingError){$response.LoggingError='Could not save the additional launcher summary: '+$_.Exception.Message}
   }
   # Publish the operation result independently of the optional summary/log.
   try {Save-ACRJson (Join-Path $TaskDirectory 'response.json') $response}
   catch {$exitCode=1}
 }
}
exit $exitCode
