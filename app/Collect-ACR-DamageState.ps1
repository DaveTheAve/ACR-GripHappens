#Requires -Version 5.1
<# Exact-build read-only paused-stage snapshot. No injections, game calls or memory writes.
Reads ONLY bounded game object fields. Does not collect saves or unrelated process memory.
C# source is compiled locally by PowerShell Add-Type; no SDK or network download is used.
Snapshot hotfix 1: use System.UInt64, supported by Windows PowerShell 5.1.
Includes material, binding, native control, geometry and joint-body-frame chapters.
It reads twenty-five native instruction/code sites; no game function is invoked or memory written.
The decoder is tested separately on Windows; live capture remains read-only.
#>
[CmdletBinding()]
param(
    [string]$GameRoot='',
    [string]$OutputDirectory=(Join-Path $env:USERPROFILE 'Downloads'),
    [ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$Label='Snapshot',
    [ValidateRange(0,1800)][int]$RecordSeconds=0,
    [ValidateSet(5,10)][int]$SampleHz=10,
    [string]$StopRequestPath='',
    [string]$RecordingTaskDirectory='',
    [string]$RecordingTakeId=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Common.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Custom.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Gameplay.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Recording.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules\Routing.Coverage.psm1') -ErrorAction Stop
$probe=$null; $stage=$null; $code=1
# Read-only timed recording. No game functions or writes are requested.
function Invoke-ACRDrivingRecording($Probe,$Initial,[int]$Seconds,[string]$Directory,[scriptblock]$Status,[scriptblock]$StopRequested=$null,[int]$SampleHz=10,$Metrics=$null,[scriptblock]$ResetRequested=$null) {
 if($Seconds -lt 1 -or $Seconds -gt 1800 -or $SampleHz -notin @(5,10)){throw 'Recording duration or frequency is outside its supported range.'}
 if(-not $Initial['nativeControlSitesMatchSelectedFile']){throw 'Live instructions were not verified; driving recording refused.'}
 $cars=@(foreach($o in $Initial['objects']) {
  if(-not $o.ContainsKey('physics') -or -not $o['physics'].ContainsKey('nativeMaterialState')){continue}
  $c=$o['physics']['nativeMaterialState']
  if(-not $c.ContainsKey('vectorStableAcrossRead') -or -not $c['vectorStableAcrossRead']){continue}
  foreach($row in $c['cars']){if($row['status'] -eq 'Captured' -and $row.ContainsKey('drivetrainAddress')){$row}}
 })
 if($cars.Count -ne 1){throw 'Exactly one stable loaded car is required. Pause inside a local stage and start the recording again.'}
 $car=[Convert]::ToUInt64(([string]$cars[0]['carAddress']).Substring(2),16)
 $drive=[Convert]::ToUInt64(([string]$cars[0]['drivetrainAddress']).Substring(2),16)
 $clock=New-Object Diagnostics.Stopwatch;$samples=0;$spans=New-Object 'Collections.Generic.List[double]'
 $discard=$false;$metricError='';$stop='Duration completed';$userStopped=$false;$began=$false;$tracePath=Join-Path $Directory 'driving-trace.jsonl'
 $utf8=New-Object Text.UTF8Encoding($false)
 $stream=New-Object IO.FileStream($tracePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 $writer=New-Object IO.StreamWriter($stream,$utf8)
 try {
  if($null -ne $Status){& $Status ('Recorder ready. Return to ACR and unpause; up to '+[math]::Ceiling($Seconds/60)+' minutes, '+$SampleHz+' samples/second. Recording starts in 8 seconds.')}
  Write-Host 'Recorder ready. Return to ACR and unpause. Recording starts in 8 seconds.'
  $leadIn=[Diagnostics.Stopwatch]::StartNew()
  while($leadIn.Elapsed.TotalSeconds -lt 8){
   if($null -ne $ResetRequested -and (& $ResetRequested)){$discard=$true;break}
   if($null -ne $StopRequested -and (& $StopRequested)){$userStopped=$true;break}
   Start-Sleep -Milliseconds 100
  }
  $leadIn.Stop()
  if($discard){$stop='Discarded for reset'}
  elseif($userStopped){$stop='Stopped by user before recording began'}
  else {
  if($null -ne $Status){& $Status 'Recording started. Drive the full test now.'}
  Write-Host 'Recording started.'
  $began=$true;$clock.Restart();$next=0.0;$lastStatus=-1
  while($clock.Elapsed.TotalSeconds -lt $Seconds -and $samples -lt $Seconds*$SampleHz) {
   if($null -ne $ResetRequested -and (& $ResetRequested)){$discard=$true;break}
   if($null -ne $StopRequested -and (& $StopRequested)){$userStopped=$true;$stop='Stopped by user';break}
   $wait=$next-$clock.Elapsed.TotalMilliseconds
   if($wait -gt 0){Start-Sleep -Milliseconds ([int]$wait)}
   try {$sample=$Probe.CaptureDrivingSample($car,$drive)}
   catch {$stop='Stopped: '+$_.Exception.Message;break}
   $sample['sampleIndex']=$samples;$sample['elapsedMilliseconds']=$clock.Elapsed.TotalMilliseconds
   $line=$sample|ConvertTo-Json -Depth 22 -Compress;$writer.WriteLine($line);$samples++
   if($null -ne $Metrics -and -not $metricError){try{$Metrics.Add($line)}catch{$metricError=$_.Exception.Message}}
   $spans.Add([double]$sample['readSpanMilliseconds'])
   if($samples%10 -eq 0){$writer.Flush()}
   if($stream.Position -gt 536870912){$stop='Stopped at the 512 MiB recording-file limit.';break}
   $secondsLeft=[math]::Max(0,[int]($Seconds-$clock.Elapsed.TotalSeconds))
   if($secondsLeft -ne $lastStatus -and $secondsLeft%10 -eq 0){
    if($null -ne $Status){& $Status ('Recording read-only driving data: '+$secondsLeft+' seconds left. No game files are being changed.')}
    $lastStatus=$secondsLeft
   }
   $next=[math]::Max($next+(1000.0/$SampleHz),$clock.Elapsed.TotalMilliseconds)
  }
  }
 } finally {try{$writer.Flush()}finally{$writer.Dispose();$clock.Stop()}}
 if($discard -or ($null -ne $ResetRequested -and (& $ResetRequested))){return [pscustomobject]@{ResetRequested=$true;Saved=$false;Samples=$samples;StopReason='Discarded for reset'}}
 $average=$null;$maximum=$null
 if($spans.Count -gt 0){$stats=$spans|Measure-Object -Average -Maximum;$average=$stats.Average;$maximum=$stats.Maximum}
 $summary=[ordered]@{Tool='GripHappensDrivingTrace';Version='1.0.1';Samples=$samples;RequestedSeconds=$Seconds;ElapsedSeconds=$clock.Elapsed.TotalSeconds;TargetHz=$SampleHz;StopReason=$stop;Complete=($stop -eq 'Duration completed');StoppedByUser=$userStopped;RecordingBegan=$began;Saved=$true;CarAddress=$cars[0]['carAddress'];DrivetrainAddress=$cars[0]['drivetrainAddress'];MeanReadMilliseconds=$average;MaxReadMilliseconds=$maximum;ReadOnly=$true;GameFilesWritten=$false;SamplesAreNonAtomic=$true;Meaning='Timed observations, not interventions. Fast shifts can occur between samples. Use timestamps, read spans, validity flags and counters; do not treat paused or zero-speed samples as straight-line tests.'}
 if($null -ne $Metrics){
  $analysis=$Metrics.Finish()|ConvertFrom-Json;$analysis|Add-Member NoteProperty AnalysisComplete (-not [bool]$metricError);$analysis|Add-Member NoteProperty AnalysisError $metricError
  $analysis|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $Directory 'recording-analysis.json') -Encoding UTF8
 }
 $summary|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $Directory 'driving-trace-summary.json') -Encoding UTF8
 if($null -ne $Status){if($userStopped){& $Status 'Recording stopped and saved. Packaging the captured data.'}elseif($stop -eq 'Duration completed'){& $Status 'Recording finished. Full-test capture is complete.'}else{& $Status ('Recording ended early: '+$stop+'. Packaging available data.')}}
 Write-Host ('Driving recording saved: '+$samples+' samples. '+$stop)
 return [pscustomobject]$summary
}

function Test-CollectorRecordingReset {
 if(-not $RecordingTaskDirectory -or -not $RecordingTakeId){return $false}
 return (Test-ACRRecordingReset $RecordingTaskDirectory $RecordingTakeId)
}
function Assert-CollectorRecordingNotReset {
 if(Test-CollectorRecordingReset){throw [OperationCanceledException]::new('Recording reset requested.')}
}
$phase='Startup'; $collectorVersion='1.0.1'
function Hash-Bytes([byte[]]$Bytes) {
    $h=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($h.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $h.Dispose() }
}
    function Get-TraceValue($Map,[string]$Key) { if($Map.ContainsKey($Key)){return $Map[$Key]};return $null }
try {
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell.' }
    Write-Host 'Grip Happens 1.0.1 - Damage and collision-routing snapshot' -ForegroundColor Cyan
    Write-Host 'Pause ACR inside a loaded OFFLINE stage before taking a snapshot.' -ForegroundColor Cyan
    Write-Host 'This reads part health and damage configuration; it does not alter the game.'
    if($RecordingTaskDirectory -or $RecordingTakeId){
     if($RecordSeconds -lt 1){throw 'Only a driving recording can own a resettable take.'}
     $expectedTake=Get-ACRRecordingRoot $RecordingTaskDirectory $RecordingTakeId
     if(-not [String]::Equals([IO.Path]::GetFullPath($OutputDirectory),$expectedTake,[StringComparison]::OrdinalIgnoreCase)){throw 'Recording output is outside the active take.'}
     Assert-CollectorRecordingNotReset
    }
    $phase='Locate game installation'
    if (-not $GameRoot) { $loc=Resolve-ACRInstall '' ''; $GameRoot=$loc.GameRoot }
    $phase='Validate manifest and executable'
    $m=Get-ACRRuntimeManifest $PSScriptRoot
    $exe=[IO.Path]::GetFullPath((Join-Path $GameRoot $m.exe.relative_path))
    if (-not [IO.File]::Exists($exe) -or -not (Test-ACRGameplayExecutableLength (Get-Item -LiteralPath $exe).Length)) { throw 'Audited game executable not found, or its size changed.' }
    $hash=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
    $custom=Add-ACRExistingCustomState $m ([IO.File]::ReadAllBytes($exe)) $GameRoot
    $stateIndex=Find-ACRNativeStateHash $m $hash
    if($stateIndex -lt 0){throw 'Unknown executable. No memory was read. Restore/check the supported build instead of forcing offsets.'}
    $states=@((Get-ACRNativeState $m $stateIndex))
    $phase='Find the matching running ACR process'
    $targets=@()
    foreach ($p in @(Get-Process -Name 'acr' -ErrorAction SilentlyContinue)) {
        try { if ([String]::Equals($p.MainModule.FileName,$exe,[StringComparison]::OrdinalIgnoreCase)) { $targets+= $p } } catch { }
    }
    if ($targets.Count -ne 1) { throw 'Exactly one matching ACR process must be running. Load a fresh offline stage and pause; then run this snapshot.' }
    $target=$targets[0]; $module=$target.MainModule
    $phase='Validate and compile the read-only C# reader'
    $source=Join-Path $PSScriptRoot 'tools\ACR_DamageProbe.cs'
    [byte[]]$sb=[IO.File]::ReadAllBytes($source)
    if ((Hash-Bytes $sb) -ne 'b751ed657986a43e43198a124fa170055344d6735c87c01141ab86f9237be36d') { throw 'Probe source changed. Re-extract the package.' }
    if (-not ('ACRDamageProbe' -as [type])) { Add-Type -TypeDefinition ([Text.Encoding]::UTF8.GetString($sb)) -Language CSharp }
    $phase='Run local routing decoder checks (no game access yet)'
    & (Join-Path $PSScriptRoot 'Test-RoutingDecoder.ps1')
    $phase='Open the read-only probe'
    # Do not use newer unsigned shorthand type accelerators in this PS 5.1 script.
    $probe=New-Object -TypeName ACRDamageProbe -ArgumentList @([int]$target.Id, [System.UInt64]$module.BaseAddress.ToInt64(), [System.UInt64]$module.ModuleMemorySize)
    $phase='Verify complete gameplay helpers and native entry sites'
    $layout=Get-ACRGameplayLayout;$nativeIndex=Find-ACRNativeStateHash $m $hash
    $siteRvas=New-Object 'Collections.Generic.List[UInt64]';$siteNames=New-Object 'Collections.Generic.List[string]';$siteHex=New-Object 'Collections.Generic.List[string]'
    foreach($site in $layout.Entries){
        $patch=@($m.native_modules.patches|Where-Object {$_.name -ceq $site.NativePatchName})
        if($patch.Count -ne 1){throw 'Gameplay verification patch identity missing.'}
        $siteRvas.Add([System.UInt64]$site.RVA);$siteNames.Add([string]$site.NativePatchName);$siteHex.Add((Get-ACRPatchHex $patch[0] $nativeIndex))
    }
    [byte[]]$expectedCode=@();$features=New-Object 'Collections.Generic.List[string]'
    $values=Get-ACRCustomValuesFromState $states[0]
    if(Test-ACRGameplayEnabled $values){
        [byte[]]$tail=[ACRCustomBytes]::Unhex([string]$states[0].gameplay_tail_hex)
        $expectedCode=[ACRCustomBytes]::Slice($tail,([int]$layout.RawOffset-[int]$layout.OriginalLength),8192)
        foreach($feature in $layout.FeatureKeys){if(Test-ACRGameplayFeature $values $feature){$features.Add([string]$feature)}}
    }
    $extraSites=$probe.ConfigureGameplay([System.UInt64]$layout.CodeRVA,[System.UInt64]$layout.DataRVA,$expectedCode,$siteRvas.ToArray(),$siteNames.ToArray(),$siteHex.ToArray(),$features.ToArray())
    Assert-CollectorRecordingNotReset
    $phase='Capture the damage snapshot'
    $result=$probe.Capture()
    Assert-CollectorRecordingNotReset
    foreach($key in $extraSites.Keys){$result['nativeControlSites'][$key]=$extraSites[$key]}
    $result['gameplayExtensionVerification']=[ordered]@{AllEntrySitesMatched=$true;CompleteExtendedCodeMatched=($expectedCode.Length -eq 8192);ActiveFeatures=$features.ToArray();ReadOnly=$true}

    $result['collectorVersion']=$collectorVersion
    $result['executableSHA256']=$hash; $result['installedNativeModules']=($states[0]|Select-Object * -ExcludeProperty gameplay_tail_hex)
    $result['nativeOverrideInterpretation']='Installed overrides act at instruction use sites. Stored engine/policy values can remain zero or stock even while an override is active. Capturing a matching instruction is not proof of the resulting physics.'
    $siteMatch=$false
    if($result.ContainsKey('nativeControlSites')) {
        $stateIndex=Find-ACRNativeStateHash $m $hash
        $siteMatch=($stateIndex -ge 0);$verifiedSites=0
        foreach($patch in $m.native_modules.patches) {
            if($result['nativeControlSites'].ContainsKey([string]$patch.name)) {
                $verifiedSites++
                if([string]$result['nativeControlSites'][[string]$patch.name] -cne (Get-ACRPatchHex $patch $stateIndex)){$siteMatch=$false}
            }
        }
        if($verifiedSites -ne 49){$siteMatch=$false}
    }
    $result['nativeControlSitesMatchSelectedFile']=$siteMatch
    if(-not $siteMatch){Write-Warning 'Live native-control instructions did not all match the selected file state. The snapshot does not validate the new options; inspect its error/mismatch fields.'}
    $result['coolingRoutingInterpretation']='EngineBay is a conditional component-local fallback. Configured dedicated names remain unchanged and can still be reported unregistered. Inspect registered-collision-sockets.csv for Radiator/Intercooler linked to the actual Socket_Audio_Engine. No live coolant leak or force outcome is inferred.'
    $result['label']=$Label; $result['powerShellVersion']=$PSVersionTable.PSVersion.ToString()
    $result['gameLocalStartupGuard']=[bool]$states[0].startup_guard
    $result['nativeHTTPRejection']=[bool]$states[0].http_request_block
    $result['completeNetworkIsolationProven']=$false
    $result['cachedResultIsolationImplemented']=$false
    $phase='Export the snapshot report'
    [IO.Directory]::CreateDirectory($OutputDirectory)|Out-Null
    $tag='Grip_Happens_DamageState_'+$Label+'_'+[DateTime]::Now.ToString('yyyyMMdd_HHmmss')+'_'+[Guid]::NewGuid().ToString('N').Substring(0,8)
    if($RecordingTakeId){$tag='Grip_Happens_DamageState_'+$Label+'_'+[DateTime]::Now.ToString('yyyyMMdd_HHmmss')+'_'+$RecordingTakeId;$stage=Join-Path $OutputDirectory 'data'}else{$stage=Join-Path ([IO.Path]::GetTempPath()) $tag}
    if([IO.Directory]::Exists($stage)){throw 'Fresh recording workspace already exists.'}
    [IO.Directory]::CreateDirectory($stage)|Out-Null
    if($RecordSeconds -gt 0) {
        $phase='Read-only driving recording'
        $notify={param($text) if(Get-Command Set-DesktopPhase -ErrorAction SilentlyContinue){Set-DesktopPhase $text}}
        $stopCheck={if([string]::IsNullOrEmpty($StopRequestPath)){return $false};return [IO.File]::Exists($StopRequestPath)}.GetNewClosure()
        $result['drivingRecording']=Invoke-ACRDrivingRecording $probe $result $RecordSeconds $stage $notify $stopCheck $SampleHz $null {Test-CollectorRecordingReset}
        Assert-CollectorRecordingNotReset
    }
    $result | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath (Join-Path $stage 'damage-state.json') -Encoding UTF8
    $rows=@(foreach ($obj in $result['objects']) {
        if ($obj.ContainsKey('damagePart')) {
            $d=$obj['damagePart']
            [PSCustomObject]@{ Part=$d['instanceId']; LifePoints=$d['lifePoints']; MaxLifePoints=$d['maxLifePoints']; LifePercent=$d['lifePercentage']; StateIndex=$d['stateIndex']; EffectCount=$d['effectCount']; Path=$obj['path']; Address=$obj['address'] }
        }
    })
    if ($rows.Count -gt 0) {
        $rows | Sort-Object Part,Path | Export-Csv -LiteralPath (Join-Path $stage 'parts.csv') -NoTypeInformation -Encoding UTF8
        $rows | Sort-Object Part | Select-Object Part,LifePercent,StateIndex,EffectCount | Format-Table -AutoSize | Out-Host
    } else { Write-Warning 'No runtime part values found. The report is still useful; this is not proof that damage is absent.' }
    $routing=@(foreach($obj in $result['objects']) {
        if(-not $obj.ContainsKey('damageComponent')){continue}
        $d=$obj['damageComponent'];if(-not $d.ContainsKey('runtimePartInventory')){continue}
        $r=$d['runtimePartInventory']
        [pscustomobject]@{Component=$obj['address'];Status=$r['status'];RuntimeParts=$r['partCount'];EngineMatches=$r['engineMatches'];GearboxMatches=$r['gearboxMatches'];Stable=$r['identityStable'];CandidateReady=$r['candidateReady'];Selection=$states[0].gearbox_damage;LiveInstructionMatch=$siteMatch}
    })
    $routing | Export-Csv -LiteralPath (Join-Path $stage 'gearbox-impact-routing.csv') -NoTypeInformation -Encoding UTF8
    $gearboxRows=@(foreach($obj in $result['objects']) {
        if(-not $obj.ContainsKey('physics') -or -not $obj['physics'].ContainsKey('nativeMaterialState')){continue}
        $capture=$obj['physics']['nativeMaterialState']
        if(-not $capture.ContainsKey('vectorStableAcrossRead') -or -not $capture['vectorStableAcrossRead']){continue}
        foreach($car in $capture['cars']) {
            if($car['status'] -ne 'Captured' -or -not $car.ContainsKey('gearboxState')){continue}
            foreach($key in $car['gearboxState'].Keys) {
                [pscustomobject]@{Car=$car['carAddress'];Drivetrain=$car['drivetrainAddress'];Quantity=$key;Value=$car['gearboxState'][$key];SelectedGearboxOption=$states[0].gearbox_damage;LiveInstructionMatch=$siteMatch}
            }
        }
    })
    $gearboxRows | Export-Csv -LiteralPath (Join-Path $stage 'gearbox-state.csv') -NoTypeInformation -Encoding UTF8
    foreach($chapter in @(@('shiftObservations','shift-observations.csv'),@('powertrainInputs','powertrain-inputs.csv'))) {
        $rows=@(foreach($obj in $result['objects']) {
            if(-not $obj.ContainsKey('physics') -or -not $obj['physics'].ContainsKey('nativeMaterialState')){continue}
            $cap=$obj['physics']['nativeMaterialState'];if(-not (Get-TraceValue $cap 'vectorStableAcrossRead')){continue}
            foreach($car in $cap['cars']) {
                if(-not $car.ContainsKey($chapter[0])){continue}
                foreach($key in $car[$chapter[0]].Keys){[pscustomobject]@{Car=$car['carAddress'];Drivetrain=$car['drivetrainAddress'];Quantity=$key;Value=$car[$chapter[0]][$key];SelectedGearboxOption=$states[0].gearbox_damage;LiveInstructionMatch=$siteMatch}}
            }
        })
        if($rows.Count -gt 0){$rows|Export-Csv -LiteralPath (Join-Path $stage $chapter[1]) -NoTypeInformation -Encoding UTF8}
    }
    $rows=@(foreach($obj in $result['objects']) {
        if(-not $obj.ContainsKey('physics') -or -not $obj['physics'].ContainsKey('nativeMaterialState')){continue}
        $cap=$obj['physics']['nativeMaterialState'];if(-not (Get-TraceValue $cap 'vectorStableAcrossRead')){continue}
        foreach($car in $cap['cars']) {
            if(-not $car.ContainsKey('tyreForceFrames')){continue}
            foreach($wheel in $car['tyreForceFrames']) {
                [pscustomobject]@{Car=$car['carAddress'];Index=$wheel['nativeWheelIndex'];Status=$wheel['status'];Stable=(Get-TraceValue $car 'tyreForceFramesStable');BasisRow2HeadingDegrees=(Get-TraceValue $wheel 'basisRow2HeadingDegrees');OlderLateralScalar=(Get-TraceValue $wheel 'lateralForce');OlderLongitudinalScalar=(Get-TraceValue $wheel 'longitudinalForce');LateralSpeed=(Get-TraceValue $wheel 'lateralSpeed');LongitudinalSpeed=(Get-TraceValue $wheel 'longitudinalSpeed');GroundContact=(Get-TraceValue $wheel 'hasGroundContact');KinematicLateralVelocity=(Get-TraceValue $wheel 'kinematicLateralVelocity');KinematicForwardVelocity=(Get-TraceValue $wheel 'kinematicForwardVelocity');Error=(Get-TraceValue $wheel 'error');Meaning=$wheel['meaning']}
            }
        }
    })
    if($rows.Count -gt 0){$rows|Export-Csv -LiteralPath (Join-Path $stage 'tyre-force-frames.csv') -NoTypeInformation -Encoding UTF8}

    $physical=@(foreach($obj in $result['objects']) {
        if(-not $obj.ContainsKey('physics') -or -not $obj['physics'].ContainsKey('nativeMaterialState')){continue}
        $cap=$obj['physics']['nativeMaterialState'];if(-not (Get-TraceValue $cap 'vectorStableAcrossRead')){continue}
        foreach($car in $cap['cars']) {
            if($car['status'] -ne 'Captured' -or -not $car.ContainsKey('physicalTyreState')){continue}
            foreach($w in $car['physicalTyreState']){foreach($key in $w.Keys){[pscustomobject]@{Car=$car['carAddress'];Index=$w['nativeWheelIndex'];Status=$w['status'];Quantity=$key;Value=$w[$key]}}}
        }
    })
    if($physical.Count -gt 0){$physical|Export-Csv -LiteralPath (Join-Path $stage 'tyre-contact-forces.csv') -NoTypeInformation -Encoding UTF8}

    $materialRows=@(foreach($obj in $result['objects']) {
        if(-not $obj.ContainsKey('physics')){continue}
        $physics=$obj['physics']
        if(-not $physics.ContainsKey('nativeMaterialState')){continue}
        $capture=$physics['nativeMaterialState']
        if(-not $capture.ContainsKey('vectorStableAcrossRead') -or -not $capture['vectorStableAcrossRead']){continue}
        foreach($car in $capture['cars']) {
            if($car['status'] -ne 'Captured'){continue}
            foreach($flag in @('simulationActiveFlag','nativeStateFlag2c41','damagesEnabled','brakeTemperatureConfigured','brakeThermalModelEnabled')) {
                [pscustomobject]@{CarAddress=$car['carAddress'];NativeCarIndex=$car['nativeCarIndex'];Subsystem='Gates';NativeIndex='';Quantity=$flag;Value=$car[$flag]}
            }
            foreach($wheel in $car['brakes']) {
                foreach($key in $wheel.Keys) {
                    if($key -eq 'nativeWheelIndex'){continue}
                    [pscustomobject]@{CarAddress=$car['carAddress'];NativeCarIndex=$car['nativeCarIndex'];Subsystem='Brakes';NativeIndex=$wheel['nativeWheelIndex'];Quantity=$key;Value=$wheel[$key]}
                }
            }
            if($car.ContainsKey('clutchMaterial')) {
                foreach($key in $car['clutchMaterial'].Keys) {
                    [pscustomobject]@{CarAddress=$car['carAddress'];NativeCarIndex=$car['nativeCarIndex'];Subsystem='Clutch';NativeIndex='';Quantity=$key;Value=$car['clutchMaterial'][$key]}
                }
            }
            if($car.ContainsKey('differentialMaterial')) {
                foreach($diff in $car['differentialMaterial']) {
                    foreach($key in $diff.Keys) {
                        if($key -eq 'nativeDifferentialIndex'){continue}
                        [pscustomobject]@{CarAddress=$car['carAddress'];NativeCarIndex=$car['nativeCarIndex'];Subsystem='Differential';NativeIndex=$diff['nativeDifferentialIndex'];Quantity=$key;Value=$diff[$key]}
                    }
                }
            }
        }
    })
    if($materialRows.Count -gt 0) {
        $materialRows | Sort-Object CarAddress,Subsystem,NativeIndex,Quantity | Export-Csv -LiteralPath (Join-Path $stage 'materials.csv') -NoTypeInformation -Encoding UTF8
        Write-Host 'Native material/thermal values captured in materials.csv. Component health remains separate in parts.csv.'
    } else {Write-Warning 'Native material chapter was not captured or failed identity checks. Inspect its per-car errors in damage-state.json; do not infer zero wear from missing data.'}
    $traceRows=@(foreach($obj in $result['objects']) {
        if($obj.ContainsKey('damagePart')) {
            $part=$obj['damagePart']
            if($part.ContainsKey('activeEffects')) {
                foreach($effect in $part['activeEffects']) {
                    if(-not $effect.ContainsKey('damageTrace')){continue}
                    $t=$effect['damageTrace']
                    [pscustomobject]@{Part=$part['instanceId'];EffectAddress=$effect['address'];Status=$t['status'];Property=(Get-TraceValue $t 'property');BindingValid=(Get-TraceValue $t 'bindingValid');BoundValue=(Get-TraceValue $t 'boundValue');ValueType=(Get-TraceValue $t 'valueType');TargetOffset=(Get-TraceValue $t 'targetBlockOffset');IdentityStable=(Get-TraceValue $t 'identityStableAcrossRead');Error=(Get-TraceValue $t 'error')}
                }
            }
        }
    })
    if($traceRows.Count -gt 0){$traceRows | Export-Csv -LiteralPath (Join-Path $stage 'effect-bindings.csv') -NoTypeInformation -Encoding UTF8}
    $controlRows=@(foreach($obj in $result['objects']) {
        $blocks=@()
        if($obj.ContainsKey('physicsModifierControls')) {
            $blocks+=,[pscustomobject]@{Layer='Unreal-effect-target';Address=$obj['address'];Data=$obj['physicsModifierControls']['effectTargetBlock']}
        }
        if($obj.ContainsKey('physics')) {
            $p=$obj['physics'];if($p.ContainsKey('nativeMaterialState')) {
                $capture=$p['nativeMaterialState']
                if($capture.ContainsKey('vectorStableAcrossRead') -and $capture['vectorStableAcrossRead']) {
                    foreach($car in $capture['cars']) {
                        if($car['status'] -eq 'Captured' -and $car.ContainsKey('nativeDamageControls')) {
                            $blocks+=,[pscustomobject]@{Layer='Native-car';Address=$car['carAddress'];Data=$car['nativeDamageControls']}
                        }
                    }
                }
            }
        }
        foreach($b in $blocks) {
            foreach($key in $b.Data.Keys) {
                if($key -in @('wheels','interpretation')){continue}
                [pscustomobject]@{Layer=$b.Layer;Address=$b.Address;Index='';Quantity=$key;Value=$b.Data[$key]}
            }
            foreach($w in $b.Data['wheels']) {
                foreach($key in @('DamperMult','WheelGeometryMult')) {
                    [pscustomobject]@{Layer=$b.Layer;Address=$b.Address;Index=$w['index'];Quantity=$key;Value=$w[$key]}
                }
            }
        }
    })
    if($controlRows.Count -gt 0){$controlRows | Export-Csv -LiteralPath (Join-Path $stage 'damage-controls.csv') -NoTypeInformation -Encoding UTF8}

    $geometryRows=@(foreach($obj in $result['objects']) {
        if(-not $obj.ContainsKey('physics')){continue}
        $physics=$obj['physics'];if(-not $physics.ContainsKey('nativeMaterialState')){continue}
        $capture=$physics['nativeMaterialState']
        if(-not $capture.ContainsKey('vectorStableAcrossRead') -or -not $capture['vectorStableAcrossRead']){continue}
        foreach($car in $capture['cars']) {
            if($car['status'] -ne 'Captured' -or -not $car.ContainsKey('geometryDamageInputs')){continue}
            $g=$car['geometryDamageInputs']
            foreach($wheel in $g['wheels']) {
                [pscustomobject]@{CarAddress=$car['carAddress'];NativeWheelIndex=$wheel['nativeWheelIndex'];ConfiguredMaxSteeringOffset=$wheel['configuredMaxSteeringOffset'];GeometryDamageControl=$wheel['geometryDamageControl'];DamperMultiplier=$wheel['damperMultiplier'];CalculatedUnsignedOffsetTerm=$wheel['unsignedDamageOffsetTerm'];EffectiveUnsignedOffsetTerm=(Get-TraceValue $wheel 'effectiveUnsignedDamageOffsetTerm');DeformationGain=(Get-TraceValue $wheel 'nativeDeformationGain');ProductInputsValid=$wheel['productInputsValid'];NativeEarlyOutFlag_b4=$g['steeringOffsetEarlyOutFlag_b4']}
            }
        }
    })
    if($geometryRows.Count -gt 0){$geometryRows | Export-Csv -LiteralPath (Join-Path $stage 'geometry-inputs.csv') -NoTypeInformation -Encoding UTF8}

    $routingRows=@(foreach($obj in $result['objects']) {
        if(-not $obj.ContainsKey('damagePart')){continue}
        $part=$obj['damagePart'];if(-not $part.ContainsKey('collisionRouting')){continue}
        $r=$part['collisionRouting'];$fields=@(if($r.ContainsKey('fields')){foreach($field in $r['fields']){$field}})
        if($fields.Count -eq 0) {
            [pscustomobject]@{Part=$part['instanceId'];BagStatus=$r['status'];BagStable=(Get-TraceValue $r 'stableAcrossRead');Key='';FieldStatus='No captured collision keys';Value='';SocketNames='';SocketSetStatus='';Error=(Get-TraceValue $r 'error')}
        }
        foreach($f in $fields) {
            $sockets='';$socketStatus=''
            if($f.ContainsKey('socketSet')) {
                $s=$f['socketSet'];$socketStatus=[string]$s['status']
                $sockets=(@(foreach($entry in $s['names']){[string]$entry['socketName']})) -join '; '
            }
            [pscustomobject]@{Part=$part['instanceId'];BagStatus=$r['status'];BagStable=(Get-TraceValue $r 'stableAcrossRead');Key=$f['name'];FieldStatus=$f['status'];Value=(Get-TraceValue $f 'value');EnumName=(Get-TraceValue $f 'enumName');SocketNames=$sockets;SocketSetStatus=$socketStatus;Error=(Get-TraceValue $f 'error')}
        }
    })
    if($routingRows.Count -gt 0){$routingRows | Export-Csv -LiteralPath (Join-Path $stage 'collision-routing.csv') -NoTypeInformation -Encoding UTF8}
    $constraintRows=@(foreach($obj in $result['objects']) {
        if(-not $obj.ContainsKey('physics')){continue}
        $p=$obj['physics'];if(-not $p.ContainsKey('nativeMaterialState')){continue}
        $material=$p['nativeMaterialState']
        foreach($car in $material['cars']) {
            if(-not $car.ContainsKey('steeringConstraintRoute')){continue}
            $r=$car['steeringConstraintRoute']
            $parentStable=($material.ContainsKey('vectorStableAcrossRead') -and $material['vectorStableAcrossRead'] -and $car['status'] -eq 'Captured' -and $r.ContainsKey('vectorStableAcrossRead') -and $r['vectorStableAcrossRead'])
            if(-not $r.ContainsKey('wheels')) {
                [pscustomobject]@{Car=$car['carAddress'];Index='';Status=$r['status'];Stable=$false;CollectionStable=$false;EarlyOut='';ConstraintIndex='';RecordCount='';BackendCount='';BackendPresent='';RecordGeometry90='';GeometrySign='';SideSign='';MaximumOffset='';DamageControl='';CalculatedSignedTerm='';Route='';Error=(Get-TraceValue $r 'error')}
                continue
            }
            foreach($w in $r['wheels']) {
                [pscustomobject]@{Car=$car['carAddress'];Index=(Get-TraceValue $w 'nativeWheelIndex');Status=$w['status'];Stable=(Get-TraceValue $w 'stableAcrossRead');CollectionStable=$parentStable;EarlyOut=(Get-TraceValue $w 'carEarlyOutFlag_b4');ConstraintIndex=(Get-TraceValue $w 'constraintIndex');RecordCount=(Get-TraceValue $w 'constraintRecordCount');BackendCount=(Get-TraceValue $w 'backendCount');BackendPresent=(Get-TraceValue $w 'backendEntryPresent');RecordGeometry90=(Get-TraceValue $w 'constraintGeometryComponent90');GeometrySign=(Get-TraceValue $w 'nativeGeometrySign');SideSign=(Get-TraceValue $w 'nativeSideSign');MaximumOffset=(Get-TraceValue $w 'configuredMaxSteeringOffset');DamageControl=(Get-TraceValue $w 'geometryDamageControl');CalculatedSignedTerm=(Get-TraceValue $w 'calculatedSignedDamageTerm');EffectiveSignedTerm=(Get-TraceValue $w 'effectiveSignedDamageTerm');Route=(Get-TraceValue $w 'routeAtCapture');Error=(Get-TraceValue $w 'error')}
            }
        }
    })
    if($constraintRows.Count -gt 0){$constraintRows | Export-Csv -LiteralPath (Join-Path $stage 'steering-constraints.csv') -NoTypeInformation -Encoding UTF8}
    $jointRows=@(foreach($obj in $result['objects']) {
        if(-not $obj.ContainsKey('physics')){continue}
        $p=$obj['physics'];if(-not $p.ContainsKey('nativeMaterialState')){continue}
        $material=$p['nativeMaterialState']
        foreach($car in $material['cars']) {
            if(-not $car.ContainsKey('steeringConstraintRoute')){continue}
            $r=$car['steeringConstraintRoute'];if(-not $r.ContainsKey('wheels')){continue}
            foreach($w in $r['wheels']) {
                $stable=($material.ContainsKey('vectorStableAcrossRead') -and $material['vectorStableAcrossRead'] -and $car['status'] -eq 'Captured' -and $r.ContainsKey('vectorStableAcrossRead') -and $r['vectorStableAcrossRead'] -and $w['status'] -eq 'Captured' -and $w.ContainsKey('stableAcrossRead') -and $w['stableAcrossRead'])
                $j=if($w.ContainsKey('storedJointAnchors')){$w['storedJointAnchors']}else{@{status='Not captured';error='No validated backend entry for this wheel.'}}
                [pscustomobject]@{Car=$car['carAddress'];Index=(Get-TraceValue $w 'nativeWheelIndex');Status=$j['status'];Stable=(Get-TraceValue $j 'stableAcrossRead');ParentStable=$stable;Backend=(Get-TraceValue $w 'backendAddress');Joint=(Get-TraceValue $j 'jointAddress');Reverse=(Get-TraceValue $j 'reverseBodyOrder');FirstAnchorFrame=(Get-TraceValue $j 'firstAnchorFrame');StoredFirstX=(Get-TraceValue $j 'storedFirstAnchorX');StoredFirstY=(Get-TraceValue $j 'storedFirstAnchorY');StoredFirstZ=(Get-TraceValue $j 'storedFirstAnchorZ');ReferenceX=(Get-TraceValue $j 'suspensionReferenceAnchorX');ReferenceY=(Get-TraceValue $j 'suspensionReferenceAnchorY');ReferenceZ=(Get-TraceValue $j 'suspensionReferenceAnchorZ');TotalReferenceMinusX=(Get-TraceValue $j 'referenceMinusStoredAnchorX');TotalReferenceMinusY=(Get-TraceValue $j 'referenceMinusStoredAnchorY');TotalReferenceMinusZ=(Get-TraceValue $j 'referenceMinusStoredAnchorZ');CalculatedDamageInputOnly=(Get-TraceValue $w 'calculatedSignedDamageTerm');EffectiveDamageInputOnly=(Get-TraceValue $w 'effectiveSignedDamageTerm');JointDistance=(Get-TraceValue $j 'storedJointDistance');Error=(Get-TraceValue $j 'error');Meaning='Stored anchor is not wheel alignment; total offset includes normal steering, damage and possible other writes.'}
            }
        }
    })
    if($jointRows.Count -gt 0){$jointRows | Export-Csv -LiteralPath (Join-Path $stage 'steering-joint-anchors.csv') -NoTypeInformation -Encoding UTF8}
    $bodyRows=@(foreach($obj in $result['objects']) {
        if(-not $obj.ContainsKey('physics')){continue}
        $p=$obj['physics'];if(-not $p.ContainsKey('nativeMaterialState')){continue}
        $material=$p['nativeMaterialState']
        foreach($car in $material['cars']) {
            if(-not $car.ContainsKey('steeringConstraintRoute')){continue}
            $r=$car['steeringConstraintRoute'];if(-not $r.ContainsKey('wheels')){continue}
            foreach($w in $r['wheels']) {
                $stable=($material.ContainsKey('vectorStableAcrossRead') -and $material['vectorStableAcrossRead'] -and $car['status'] -eq 'Captured' -and $r.ContainsKey('vectorStableAcrossRead') -and $r['vectorStableAcrossRead'] -and $w['status'] -eq 'Captured' -and $w.ContainsKey('stableAcrossRead') -and $w['stableAcrossRead'])
                $j=Get-TraceValue $w 'storedJointAnchors'
                $f=if($j -and $j.ContainsKey('bodyFrames')){$j['bodyFrames']}else{@{status='Not captured';error='No validated pair of joint bodies.'}}
                [pscustomobject]@{
                    Car=$car['carAddress'];Index=(Get-TraceValue $w 'nativeWheelIndex');Status=$f['status']
                    Stable=(Get-TraceValue $f 'stableAcrossRead');ParentStable=$stable
                    FirstBody=(Get-TraceValue $f 'firstBodyAddress');SecondBody=(Get-TraceValue $f 'secondBodyAddress')
                    RelativeJointBodyYawDegrees=(Get-TraceValue $f 'relativeJointBodyYawDegrees')
                    RelativeJointBodyRollDegrees=(Get-TraceValue $f 'relativeJointBodyRollDegrees')
                    ActualAnchorDistance=(Get-TraceValue $f 'actualWorldAnchorDistance')
                    TargetAnchorDistance=(Get-TraceValue $f 'targetWorldAnchorDistance')
                    DistanceResidual=(Get-TraceValue $f 'distanceResidual')
                    EffectiveDamageInput=(Get-TraceValue $w 'effectiveSignedDamageTerm')
                    Error=(Get-TraceValue $f 'error');Meaning=(Get-TraceValue $f 'meaning')
                }
            }
        }
    })
    if($bodyRows.Count -gt 0){$bodyRows | Export-Csv -LiteralPath (Join-Path $stage 'steering-body-frames.csv') -NoTypeInformation -Encoding UTF8}

    # These are live initialized caches, not the configured CollisionsSockets bags.
    $policyRows=@(foreach($obj in $result['objects']) {
        if(-not $obj.ContainsKey('registeredCollisionRouting')){continue}
        $r=$obj['registeredCollisionRouting'];$owner=Get-TraceValue $r 'ownerDamageComponent'
        [pscustomobject]@{Policy=$obj['address'];Path=$obj['path'];Status=$r['status'];LiveOwner=(Get-TraceValue $r 'hasLiveOwner');Owner=$(if($owner){$owner['address']}else{''});Stable=(Get-TraceValue $r 'stableAcrossRead');Enabled=(Get-TraceValue $r 'nativeCollisionPolicyEnabledFlag');MassFlowRate=(Get-TraceValue $r 'MassFlowRate');DamageRate=(Get-TraceValue $r 'DamageRate');CriticalThreshold=(Get-TraceValue $r 'CriticalDamageThreshold');AllocatedSocketKeys=(Get-TraceValue $r 'cacheAllocatedKeys');FailedRows=(Get-TraceValue $r 'failedRows');Error=(Get-TraceValue $r 'error')}
    })
    $registeredRows=@(foreach($obj in $result['objects']) {
        if(-not $obj.ContainsKey('registeredCollisionRouting')){continue}
        $r=$obj['registeredCollisionRouting'];$owner=Get-TraceValue $r 'ownerDamageComponent'
        foreach($entry in $r['registrations']) {
            $component=Get-TraceValue $entry 'component'
            if(-not $entry.ContainsKey('parts') -or $entry['parts'].Count -eq 0){
                [pscustomobject]@{Policy=$obj['address'];Owner=$(if($owner){$owner['address']}else{''});CacheStatus=$r['status'];CacheStable=(Get-TraceValue $r 'stableAcrossRead');EntryStatus=$entry['status'];Socket=(Get-TraceValue $entry 'socketName');Component=$(if($component){$component['address']}else{''});ComponentPath=$(if($component){$component['path']}else{''});Part='';PartAddress='';Error=(Get-TraceValue $entry 'error')}
            } else {foreach($part in $entry['parts']) {
                [pscustomobject]@{Policy=$obj['address'];Owner=$(if($owner){$owner['address']}else{''});CacheStatus=$r['status'];CacheStable=(Get-TraceValue $r 'stableAcrossRead');EntryStatus=$entry['status'];Socket=(Get-TraceValue $entry 'socketName');Component=$(if($component){$component['address']}else{''});ComponentPath=$(if($component){$component['path']}else{''});Part=$part['instanceId'];PartAddress=$part['address'];Error=(Get-TraceValue $entry 'error')}
            }}
        }
    })
    $registrationChecks=@(foreach($obj in $result['objects']) {
        if(-not $obj.ContainsKey('damagePart')){continue};$part=$obj['damagePart'];$r=$part['collisionRouting']
        if(-not $r.ContainsKey('fields')){continue}
        $outer=Get-TraceValue $part 'outerObject';$owner=if($outer){[string]$outer['address']}else{''}
        $policies=@($policyRows|Where-Object {$_.Owner -eq $owner -and $_.LiveOwner -eq $true})
        $complete=($policies.Count -gt 0 -and @($policies|Where-Object {$_.Status -ne 'Captured' -or $_.Stable -ne $true}).Count -eq 0)
        foreach($field in $r['fields']) {
            if($field['name'] -ne 'CollisionsSockets' -or $field['status'] -ne 'Captured' -or -not $r['stableAcrossRead']){continue}
            foreach($socket in $field['socketSet']['names']) {
                $name=[string]$socket['socketName'];$address=[string]$obj['address']
                $hits=@($registeredRows|Where-Object {$_.Owner -eq $owner -and $_.PartAddress -eq $address -and $_.Socket -ceq $name -and $_.CacheStable -eq $true -and $_.EntryStatus -eq 'Captured'})
                $state=if($hits.Count -gt 0){'Registered in captured live cache'}elseif($complete){'NOT registered in captured live cache'}else{'Unknown - matching live policy cache missing or incomplete'}
                [pscustomobject]@{Part=$part['instanceId'];PartAddress=$address;Owner=$owner;ConfiguredSocket=$name;Result=$state;MatchingAssociations=$hits.Count;MatchingPolicies=$policies.Count;CoverageComplete=$complete}
            }
        }
    })
    $accumulatorRows=@(foreach($obj in $result['objects']) {
        if(-not $obj.ContainsKey('physicsDamageAccumulators')){continue};$a=$obj['physicsDamageAccumulators']
        foreach($key in @('EngineTurboAboveThresh','EngineRpmAboveThresh','EngineThrottleRevs','GearboxGrinding')) {
            [pscustomobject]@{CarAvatar=$obj['address'];Status=$a['status'];Quantity=$key;Value=(Get-TraceValue $a $key);Stable=(Get-TraceValue $a 'valuesStableAcrossRead');Error=(Get-TraceValue $a 'error')}
        }
    })
    if($policyRows.Count -gt 0){$policyRows|Export-Csv -LiteralPath (Join-Path $stage 'collision-policies.csv') -NoTypeInformation -Encoding UTF8}
    if($registeredRows.Count -gt 0){$registeredRows|Export-Csv -LiteralPath (Join-Path $stage 'registered-collision-sockets.csv') -NoTypeInformation -Encoding UTF8}
    if($registrationChecks.Count -gt 0){$registrationChecks|Export-Csv -LiteralPath (Join-Path $stage 'socket-registration-checks.csv') -NoTypeInformation -Encoding UTF8}
    if($accumulatorRows.Count -gt 0){$accumulatorRows|Export-Csv -LiteralPath (Join-Path $stage 'physics-damage-accumulators.csv') -NoTypeInformation -Encoding UTF8}
    $coolingSummary=@(Get-ACRCoolingRegistrationSummary -Checks $registrationChecks -Rows $registeredRows -Selection ([string]$states[0].cooling_routing))
    $result['coolingRegistrationSummary']=$coolingSummary
    if($coolingSummary.Count -gt 0){$coolingSummary | Export-Csv -LiteralPath (Join-Path $stage 'cooling-routing-checks.csv') -NoTypeInformation -Encoding UTF8}
    $livePolicies=@($policyRows|Where-Object {$_.LiveOwner -eq $true})
    $failedPolicyChapters=@($policyRows|Where-Object {$_.Status -ne 'Captured' -and $_.Status -ne 'Unbound policy template; not a live cache'})
    $registeredCoverage=[ordered]@{
        Status=$(if($livePolicies.Count -gt 0 -and $failedPolicyChapters.Count -eq 0){'Captured live registration caches'}else{'Partial or unavailable live registration caches'})
        LivePolicies=$livePolicies.Count;FailedPolicyChapters=$failedPolicyChapters.Count
        ConfiguredSocketChecks=$registrationChecks.Count
        NotRegistered=@($registrationChecks|Where-Object {$_.Result -eq 'NOT registered in captured live cache'}).Count
        Unknown=@($registrationChecks|Where-Object {$_.Result -like 'Unknown*'}).Count
        Associations=$registeredRows.Count
        Meaning='A configured socket is different from a registered socket; registration is still not proof of contact coverage during past crashes. Empty pending damage is not a crash history.'
    }
    $result['registrationCoverage']=$registeredCoverage
    $registeredCoverage|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $stage 'registration-coverage.json') -Encoding UTF8
    if($registeredCoverage.Status -like 'Partial*'){$result['status']='Completed with registration gaps'}
    Write-Host ('Socket registration: '+$registeredCoverage.Status+'; '+$registrationChecks.Count+' configured associations checked.')

    $coverage=Get-RoutingCoverage -RoutingRows $routingRows -SteeringRows $constraintRows -JointRows $jointRows
    $result['objectCaptureStatus']=$result['status']
    $result['routingCoverage']=$coverage
    if($coverage.Status -like 'Partial*' -and $result['status'] -eq 'Completed'){$result['status']='Completed with routing gaps'}
    $result | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath (Join-Path $stage 'damage-state.json') -Encoding UTF8
    $coverage | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stage 'routing-coverage.json') -Encoding UTF8
    Write-Host ('Routing: '+$coverage.Status)
    Write-Host ('Captured: '+$coverage.CollisionResistanceRows+' collision coefficients; '+$coverage.CollisionSocketSetRows+' socket sets; '+$coverage.StableSteeringRows+' steering routes; '+$coverage.StoredJointAnchorRows+' stored joints.')
    if($coverage.Status -like 'Partial*'){Write-Warning ('Keep the ZIP: '+$coverage.FailedOrUnstableCollisionFields+' collision fields, '+$coverage.FailedOtherScalarFields+' related scalar fields and '+$coverage.FailedOrUnstableJointRows+' joint rows were rejected. Bounded raw metadata is retained for diagnosis; missing values do not mean no damage.')}

    @'
Read-only, non-atomic snapshot. No game functions called or settings written.
parts.csv: generic component health, NOT material thickness.
effect-bindings.csv: exact-class effect bindings and actual destination values.
damage-controls.csv: separate Unreal-side and native-car damage controls.
geometry-inputs.csv: authored maximum steering offset and its calculated damage
term before native signs and constraint processing; NOT measured wheel alignment.
The two Critical admission sites are included in nativeControlSites.
materials.csv (when capture checks pass): brake disc/pad, clutch and differential
material state, native thermal/friction values and gates. Native indices and stored
units are retained, not guessed as millimetres/Celsius or UI axle names.
Compare fresh and post-drive captures from the same loaded stage and same addresses.
One capture does not establish consumption, fade, realistic life or performance.
Invalid/missing material data remains an explicit error in damage-state.json.
tyre-contact-forces.csv contains native contact-force samples, not damage-only effects.
Modeled cooling and engine operational feedback are explicitly labelled in the JSON.
They are not native coolant telemetry or proof of permanent engine destruction.
collision-routing.csv: per-part collision coefficient, configured socket set and
related native wear/failure/engine/gearbox accumulation scalars where present.
Their names are not automatically assigned a physical meaning or percentage.
steering-constraints.csv: extra steering-link conditions and signed input term.
These are not event-by-event impacts, toe angles or measured forces.
The integrated routing reader includes the actual registered collision socket cache and selected
physics-damage accumulator inputs; these are read-only observations, not interventions.
collision-policies.csv: the enabled flag and native policy configuration.
registered-collision-sockets.csv: cached component/socket-to-part associations.
socket-registration-checks.csv: match configured names against each part's owner
policy; incomplete caches remain Unknown, not missing.
physics-damage-accumulators.csv: current inputs, not historical collisions.
registration-coverage.json: separates templates, active caches and read failures.
steering-joint-anchors.csv: actual stored joint anchors and their difference from
the reference. TOTAL difference includes normal steering and damage, not just
damage; it is not measured alignment. Native coordinate/length units retained.
The JSON retains at most 4096 bytes of each part's own game-property storage,
selected descriptors and bounded socket metadata. No saves or full dumps.
Routing coverage reports nested failures separately from object enumeration.
A fresh undamaged loaded car can still provide its collision routing configuration.
No additional crash sequence is required for this diagnostic.
Older material/binding chapters were exercised in the user-supplied prior traces.
This is a detailed local diagnostic, not the sanitized support export. Review it
before sharing; nothing is uploaded automatically.
'@ | Set-Content -LiteralPath (Join-Path $stage 'README.txt') -Encoding UTF8
    Assert-CollectorRecordingNotReset
    $phase='Create the snapshot ZIP'
    $zip=Join-Path $OutputDirectory ($tag+'.zip')
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
    if (-not [IO.File]::Exists($zip) -or (Get-Item -LiteralPath $zip).Length -le 0) { throw 'Snapshot ZIP creation failed.' }
    Write-Host ('Snapshot status: '+$result['status'])
    if ($result.ContainsKey('error')) { Write-Warning $result['error'] }
    Write-Host ('Upload: '+$zip) -ForegroundColor Green
    Remove-Item -LiteralPath $stage -Recurse -Force; $stage=$null
    $code=0
} catch {
    if(Test-CollectorRecordingReset){$code=4;Write-Host 'Recording reset requested; this take will be discarded without exporting.'}
    else {
    # Save the original error before any diagnostic operation can replace $_.
    $failure=$_
    Write-Host ('Snapshot failed: '+$failure.Exception.Message) -ForegroundColor Red
    Write-Host ('Step: '+$phase)
    Write-Host 'No game settings were written. Do not change offsets or disable protection.'
    if ($stage) { Write-Host ('Partial snapshot: '+$stage) }
    # Diagnostics go only to the chosen report directory, never into the game.
    try {
        [IO.Directory]::CreateDirectory($OutputDirectory)|Out-Null
        $errorName='Grip_Happens_DamageState_Error_'+[DateTime]::Now.ToString('yyyyMMdd_HHmmss')+'_'+[Guid]::NewGuid().ToString('N').Substring(0,8)+'.txt'
        $errorPath=Join-Path $OutputDirectory $errorName
        $details=@(
            'Grip Happens - read-only damage snapshot failure',
            ('Collector: '+$collectorVersion),
            ('UTC: '+[DateTime]::UtcNow.ToString('o')),
            ('Step: '+$phase),
            ('PowerShell: '+$PSVersionTable.PSVersion.ToString()),
            ('64-bit process: '+[Environment]::Is64BitProcess),
            ('Error ID: '+$failure.FullyQualifiedErrorId),
            ('Message: '+$failure.Exception.Message),
            '', 'Exception details:', $failure.Exception.ToString(),
            '', 'Script position:', $failure.InvocationInfo.PositionMessage,
            '', 'Script stack:', $failure.ScriptStackTrace,
            '', 'No game settings were written. This is a diagnostic-tool failure, not a request to change offsets or security settings.'
        )
        $details | Set-Content -LiteralPath $errorPath -Encoding UTF8
        Write-Host ('Error report: '+$errorPath) -ForegroundColor Yellow
    } catch {
        Write-Warning ('Could not save the error report: '+$_.Exception.Message)
        Write-Host 'Copy the snapshot error and step shown above.'
    }
    }
} finally { if ($null -ne $probe) { $probe.Dispose() } }
exit $code
