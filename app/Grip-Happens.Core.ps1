#Requires -Version 5.1
<#
Grip Happens 1.0.1. Exact-build, reversible ACR physics tuning.
Check is the default. Thirteen independently selectable controls; new experiments default to Stock.
Visual deformation and collision sensitivity modify acr.exe; verified FULL original EXE backup is mandatory.
The original publisher signature is invalid while either executable module is enabled.
No DRM/anti-cheat changes. No dry/snow friction or wear-to-grip/slip-curve edits. New optional controls target native compression, failure eligibility, brake consumption and attachment thresholds.
Game-local startup/HTTP guard is installed with any non-stock module; no system network rules are used.
Current release retains the validated tyre, wet-road, damage, and game-local guard implementation.
#>
[CmdletBinding()]
param(
    [ValidateSet('Check','Install','Restore')][string]$Action = 'Check',
    [Parameter(Mandatory=$true)][string]$GameRoot,
    [ValidateSet('0','0.00025','0.0005','0.001','0.002','0.005','0.01','0.02','0.05','0.1')][string]$RateScale = '0.005',
    [ValidateSet('Off','VeryLight','Light','Mild','Balanced','Moderate','Firm','Strong','Maximum')][string]$WetTarmac = 'Moderate',
    [ValidateSet('Off','Enhanced','Strong')][string]$VisualDamage = 'Off',
    [ValidateSet('Stock','Sensitive','Strong')][string]$CollisionDamage = 'Stock',
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
    [switch]$OfflineConfirmed
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Common.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Custom.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Gameplay.psm1') -ErrorAction Stop

function Get-BytesHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-StreamHash([IO.FileStream]$Stream) {
    $saved = $Stream.Position; $sha = [Security.Cryptography.SHA256]::Create()
    try { $Stream.Position = 0; return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-','').ToLowerInvariant() }
    finally { $Stream.Position = $saved; $sha.Dispose() }
}
function Read-Region([IO.FileStream]$Stream, [long]$Offset, [int]$Length) {
    if ($Offset -lt 0 -or $Length -lt 0 -or $Offset -gt $Stream.Length - $Length) { throw 'Read outside file bounds refused.' }
    [byte[]]$buffer = New-Object byte[] $Length
    $Stream.Position = $Offset; $read = 0
    while ($read -lt $Length) {
        $n = $Stream.Read($buffer,$read,$Length-$read)
        if ($n -le 0) { throw 'Unexpected end of file.' }
        $read += $n
    }
    return ,$buffer
}
function Convert-Hex([string]$Hex) {
    if (($Hex.Length % 2) -ne 0 -or $Hex -notmatch '^[0-9a-fA-F]+$') { throw 'Invalid manifest byte string.' }
    [byte[]]$b = New-Object byte[] ($Hex.Length/2)
    for ($i=0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($Hex.Substring($i*2,2),16) }
    return ,$b
}
function Get-OriginalBytes([byte[]]$Current, $Patches, [string]$OriginalHash, [string]$SourceLabel = 'file', [long]$BaseOffset = 0, [string]$KnownCurrentHash = '') {
    # Accept only known per-byte mixtures, for recovery after interrupted writes.
    # Install still requires a complete coherent known state across ALL regions.
    # The shortcut is admitted by the FULL current-buffer hash from the authenticated
    # manifest, never by file size, timestamp, a cached result, or a UI selection.
    # Unknown/mixed states continue through the exact old per-byte recovery path.
    $exactKnown=$false
    if (-not [string]::IsNullOrEmpty($KnownCurrentHash)) {
        if ($KnownCurrentHash -notmatch '^[0-9a-f]{64}$' -or (Get-BytesHash $Current) -cne $KnownCurrentHash) {
            throw 'The complete current-file fingerprint did not match the requested fast verification path. No writes permitted.'
        }
        $exactKnown=$true
    }
    [byte[]]$original = $Current.Clone()
    foreach ($p in $Patches) {
        [int]$offset = $p.offset
        [byte[]]$before = Convert-Hex (Get-ACRPatchHex $p 0)
        if ($offset -lt 0 -or $offset -gt $Current.Length-$before.Length) { throw 'Invalid patch bounds.' }
        if ($exactKnown) {
            [Array]::Copy($before,0,$original,$offset,$before.Length)
            continue
        }
        $possible = New-Object 'System.Collections.Generic.List[byte[]]'
        $seenHex = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($hex in (Get-ACRPatchVariantHexes $p)) {
            if (-not $seenHex.Add([string]$hex)) { continue }
            [byte[]]$b = Convert-Hex $hex
            if ($b.Length -ne $before.Length) { throw 'Length-changing patch refused.' }
            $possible.Add($b)
        }
        for ($k=0; $k -lt $before.Length; $k++) {
            $allowed = $false
            foreach ($b in $possible) { if ($Current[$offset+$k] -eq $b[$k]) { $allowed=$true; break } }
            if (-not $allowed) {
                $fileOffset=$BaseOffset+[long]$offset+[long]$k
                $expectedValues=New-Object 'System.Collections.Generic.List[string]'
                foreach ($variant in $possible) { $expectedValues.Add($variant[$k].ToString('X2')) }
                $expected=@($expectedValues | Select-Object -Unique) -join ', '
                $rangeName='audited range'
                if ($p.PSObject.Properties['name']) { $rangeName=[string]$p.name }
                $detail=[ordered]@{Reason='UnexpectedPatchByte';File=$SourceLabel;Range=$rangeName;FileOffset=$fileOffset;FileOffsetHex=('0x{0:X}' -f $fileOffset);ActualByte=$Current[$offset+$k].ToString('X2');AcceptedBytes=$expected}
                $errorObject=New-Object IO.InvalidDataException ('Unrecognized bytes in '+$SourceLabel+' at 0x'+$fileOffset.ToString('X')+' ('+$rangeName+'). Found '+$detail.ActualByte+'; accepted '+$expected+'. No game files were changed. Export a support report; do not force an older patch or delete your backups.')
                $errorObject.Data['PatchMismatch']=$detail
                throw $errorObject
            }
            $original[$offset+$k] = $before[$k]
        }
    }
    $normalizedHash=Get-BytesHash $original
    if ($normalizedHash -ne $OriginalHash) {
        $errorObject=New-Object IO.InvalidDataException ('The verified original fingerprint could not be recovered for '+$SourceLabel+'. This can indicate a different game build or another modification. No game files were changed; unknown data will not be overwritten.')
        $errorObject.Data['PatchMismatch']=[ordered]@{File=$SourceLabel;Reason='NormalizedHashMismatch';ExpectedOriginalSHA256=$OriginalHash;NormalizedSHA256=$normalizedHash}
        throw $errorObject
    }
    return ,$original
}
function Get-StateBytes([byte[]]$Original, $Patches, [int]$StateIndex) {
    [byte[]]$b = $Original.Clone()
    foreach ($p in $Patches) {
        [byte[]]$v = Convert-Hex (Get-ACRPatchHex $p $StateIndex)
        [int]$offset=$p.offset
        if ($offset -lt 0 -or $offset -gt $b.Length-$v.Length) { throw 'Invalid state bounds.' }
        [Array]::Copy($v,0,$b,$offset,$v.Length)
    }
    return ,$b
}
function Write-Ranges([IO.FileStream]$Stream, [long]$BaseOffset, $Patches, [int]$StateIndex) {
    foreach ($p in $Patches) {
        [byte[]]$b = Convert-Hex (Get-ACRPatchHex $p $StateIndex)
        [long]$offset = $BaseOffset + [long]$p.offset
        if ($offset -lt 0 -or $offset -gt $Stream.Length-$b.Length) { throw 'Write outside file bounds refused.' }
        $Stream.Position = $offset; $Stream.Write($b,0,$b.Length)
    }
}
function Save-OriginalBackup([string]$Path, [byte[]]$Bytes, [string]$ExpectedHash) {
    if ((Get-BytesHash $Bytes) -ne $ExpectedHash) { throw 'Refusing to back up unverified source data.' }
    if ([IO.File]::Exists($Path)) {
        if ((Get-BytesHash ([IO.File]::ReadAllBytes($Path))) -ne $ExpectedHash) { throw "Existing backup failed validation: $Path" }
        return
    }
    $temp=$Path+'.tmp.'+[Guid]::NewGuid().ToString('N')
    try {
        $s=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $s.Write($Bytes,0,$Bytes.Length); $s.Flush($true) } finally { $s.Dispose() }
        if ((Get-BytesHash ([IO.File]::ReadAllBytes($temp))) -ne $ExpectedHash) { throw 'Backup read-back failed.' }
        [IO.File]::Move($temp,$Path)
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Save-Json([string]$Path, $Value) {
    $temp=$Path+'.tmp.'+[Guid]::NewGuid().ToString('N')
    try {
        $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Assert-GameClosed {
    $running=@(Get-Process -Name 'acr','acr-Win64-Shipping' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) { throw 'Close Assetto Corsa Rally before checking, installing, changing rate, or restoring.' }
}
function Resolve-GameFile([string]$Relative) {
    $full=[IO.Path]::GetFullPath((Join-Path $GameRoot $Relative))
    $prefix=$GameRoot.TrimEnd('\')+'\'
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe path in patch manifest.' }
    return $full
}
function Write-ExecutableRanges([IO.FileStream]$Stream, $Patches, [int]$StateIndex) {
    # Game is closed and exclusively locked. Restore all ten native entry sites first,
    # write metadata/constants, then install selected entry branches last.
    $entries = @($Patches | Where-Object { $_.name -like '* entry' })
    $other = @($Patches | Where-Object { $_.name -notlike '* entry' })
    if ($entries.Count -ne 32) { throw 'Executable entry patch table incomplete.' }
    foreach ($name in @('visual_damage entry','collision_damage entry','offline startup entry','Cooling socket lookup entry','Engine impact weighting entry','Progressive power response entry','Localized wheel collision entry','Gearbox grinding rate entry','Gearbox collision transfer entry','Gearbox accumulated Critical entry','Gearbox timed-request entry','Suspension deformation entry','Mechanical request entry','Admission observation entry','Shift result observation entry','Shift refusal observation entry','Overrev observation entry','Grinding observation entry','Unprotected downshift entry','Worn upshift duration entry','Worn downshift duration entry','Deferred upshift commit entry','Deferred downshift commit entry','Native-life admission 0 entry','Native-life admission 256 entry','Differential material rate entry','Damage-sensitive physical toe entry','Cooling thermal integration entry','HUD native aggregation entry','HUD reflected aggregation entry','HUD warning refresh entry','Engine routine-use wear entry')) {
        if (@($entries | Where-Object {$_.name -ceq $name}).Count -ne 1) { throw 'Executable entry patch identities incomplete.' }
    }
    Write-Ranges $Stream 0 $entries 0
    $Stream.Flush($true)
    $selected=(Get-ACRNativeState $m $StateIndex)
    $wantedLength=Get-ACRGameplayExecutableLength $selected ([long]$m.exe.length)
    if($Stream.Length -lt $wantedLength){$Stream.SetLength($wantedLength)}
    if($null -ne $selected.PSObject.Properties['gameplay_tail_hex']){
        [byte[]]$tail=Convert-Hex ([string]$selected.gameplay_tail_hex)
        if($tail.Length -ne $wantedLength-$m.exe.length){throw 'Gameplay tail extent mismatch.'}
        $Stream.Position=[long]$m.exe.length;$Stream.Write($tail,0,$tail.Length);$Stream.Flush($true)
    }
    Write-Ranges $Stream 0 $other $StateIndex
    $Stream.Flush($true)
    if ($StateIndex -ne 0) { Write-Ranges $Stream 0 $entries $StateIndex }
    if($Stream.Length -ne $wantedLength){$Stream.SetLength($wantedLength)}
    $Stream.Flush($true)
}
function Assert-InstalledState($Manifest, [IO.FileStream]$IndexStream, [IO.FileStream]$DataStream, [int]$StateIndex, [IO.FileStream]$ExeStream, [int]$NativeIndex) {
    if ($ExeStream.Length -ne (Get-ACRGameplayExecutableLength (Get-ACRNativeState $Manifest $NativeIndex) ([long]$Manifest.exe.length)) -or (Get-StreamHash $ExeStream) -ne (Get-ACRNativeState $Manifest $NativeIndex).exe_sha256) { throw 'Full executable verification failed.' }
    if ($IndexStream.Length -ne [long]$Manifest.index.length -or $DataStream.Length -ne [long]$Manifest.ucas.length) { throw 'Container file length changed.' }
    if ((Get-StreamHash $IndexStream) -ne $Manifest.states[$StateIndex].index_sha256) { throw 'Full index verification failed.' }
    foreach ($r in $Manifest.regions) {
        [byte[]]$d=Read-Region $DataStream ([long]$r.offset) ([int]$r.length)
        if ((Get-BytesHash $d) -ne $r.sha256_by_state[$StateIndex]) { throw ('Asset read-back failed: '+$r.name) }
    }
}

$script:CoreTimingClock=[Diagnostics.Stopwatch]::StartNew()
$script:CoreTimingPrevious=0.0
$script:CoreTimings=[ordered]@{}
function Add-CoreTiming([string]$Stage) {
    $now=$script:CoreTimingClock.Elapsed.TotalMilliseconds
    $script:CoreTimings[$Stage]=[math]::Round(($now-$script:CoreTimingPrevious),2)
    $script:CoreTimingPrevious=$now
}
$exeStream=$null; $indexStream=$null; $dataStream=$null
$customTarget=$null;$existingCustom=$null
$writeStarted=$false; $reportPath=$null; $journalPath=$null; $m=$null; $operation=$null
$report=[ordered]@{
    Tool='GripHappens'; Version='1.0.1'; UtilityBuild='1.0.1'; Action=$Action
    UTC=[DateTime]::UtcNow.ToString('o'); Status='Starting'
    RequestedRateScale=$RateScale; RequestedWetTarmac=$WetTarmac; RequestedVisualDamage=$VisualDamage; RequestedCollisionDamage=$CollisionDamage;RequestedTyreDamage=$TyreDamage;RequestedMechanicalFailures=$MechanicalFailures;RequestedBrakeWear=$BrakeWear;RequestedDetachment=$Detachment;RequestedCriticalDamage=$CriticalDamage; RequestedCoolingRouting=$CoolingRouting; RequestedEngineImpact=$EngineImpact;RequestedPowerResponse=$PowerResponse;RequestedWheelImpact=$WheelImpact;RequestedGearboxDamage=$GearboxDamage;PowerResponse=$PowerResponse;WheelImpact=$WheelImpact;GearboxDamage=$GearboxDamage; OfflineConfirmed=[bool]$OfflineConfirmed
    NetworkPolicyEnforcementImplemented=$false; OfflineLockRequiredForInstall=$false; GameLocalGuardImplemented=$true; AllServerPathsProvenBlocked=$false; CachedResultIsolationImplemented=$false; NewRateGameplayTested=$false; WetTarmacGameplayTested=$false; DamageChangesImplemented=$true; VisualDamageGameplayTested=$false; CollisionDamageGameplayTested=$false; AdditionalWearGripPenaltyImplemented=$false
    PowerShellVersion=$PSVersionTable.PSVersion.ToString(); ExecutablePatchGameplayTested=$false
}
try {
    Assert-ACRWindows
    $requestedCustom=ConvertFrom-ACRCustomBase64 $CustomJsonBase64
    $operation=Enter-ACROperation
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell.' }
    if ($Action -eq 'Install' -and -not $OfflineConfirmed) { throw 'Install requires offline confirmation. Read README.md and use -OfflineConfirmed only for offline testing.' }
    $m=Get-ACRRuntimeManifest $PSScriptRoot
    if ($m.schema -ne 6 -or $m.version -ne '1.0.1' -or $m.regions.Count -ne 114 -or $m.states.Count -ne 91 -or (Get-ACRNativeStateCount $m) -lt 1) { throw 'Unsupported runtime manifest.' }
    foreach ($r in $m.regions) {
        if ($r.sha256_by_state.Count -ne $m.states.Count) { throw 'Incomplete region state table.' }
        foreach ($p in $r.patches) {
            if ($p.bytes.Count -ne $m.states.Count) { throw 'Incomplete patch state table.' }
        }
    }
    foreach ($p in $m.native_modules.patches) {
        if($null -eq $p.PSObject.Properties['runtime_patch_index'] -or $p.byte_pool.Count -lt 1){throw 'Incomplete runtime executable patch table.'}
    }
    Add-CoreTiming 'RuntimeAndManifestValidationMs'
    $GameRoot=ConvertTo-ACRLocalPath $GameRoot
    foreach ($spec in @($m.exe,$m.index,$m.ucas)) { Assert-ACRNoReparse (Join-Path $GameRoot $spec.relative_path) }
    $report['GameRoot']=$GameRoot
    $key=(Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($GameRoot.ToLowerInvariant()))).Substring(0,12)
    # 0.5.1 shares the 0.5.0 backup/journal schema; never strand an incomplete-write journal.
    $stateRoot=Get-ACRBackupStateRoot $GameRoot
    [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    $reportPath=Join-Path $stateRoot ('Grip_Happens_'+$Action+'_'+[DateTime]::Now.ToString('yyyyMMdd_HHmmss_fff')+'.json')
    $journalPath=Join-Path $stateRoot 'incomplete-write.json'
    $report['BackupDirectory']=$stateRoot
    $report['PreviousWriteJournalPresent']=[IO.File]::Exists($journalPath)
    Assert-GameClosed
    $access=[IO.FileAccess]::Read; $sharing=[IO.FileShare]::Read
    if ($Action -ne 'Check') { $access=[IO.FileAccess]::ReadWrite; $sharing=[IO.FileShare]::None }
    $exeStream=[IO.File]::Open((Resolve-GameFile $m.exe.relative_path),[IO.FileMode]::Open,$access,$sharing)
    if (-not (Test-ACRGameplayExecutableLength $exeStream.Length)) { throw 'Executable length mismatch. Refusing another game build.' }
    [byte[]]$currentExe=Read-Region $exeStream 0 ([int]$exeStream.Length)
    $customRecoveryReady=$false;$inheritedCustomCandidates=@()
    if($Action -eq 'Restore' -and [IO.File]::Exists($journalPath)){
        $recoveryJournal=Get-Content -LiteralPath $journalPath -Raw|ConvertFrom-Json
        if($null -ne $recoveryJournal.PSObject.Properties['CustomCandidates'] -and @($recoveryJournal.CustomCandidates).Count -gt 0){Add-ACRCustomRecoveryCandidates $m $stateRoot $journalPath;$customRecoveryReady=$true;$inheritedCustomCandidates=@($recoveryJournal.CustomCandidates)}
    }
    try {$existingCustom=Add-ACRExistingCustomState $m $currentExe $GameRoot}
    catch {if(-not $customRecoveryReady){throw}}
    $exeHash=Get-BytesHash $currentExe
    $report['ExecutableSHA256']=$exeHash
    $report['OriginalExecutableSHA256']=$m.exe.sha256
    [int]$knownNative=Find-ACRNativeStateHash $m $exeHash
    $knownExeHash=''
    if ($knownNative -ge 0) { $knownExeHash=[string](Get-ACRNativeState $m $knownNative).exe_sha256 }
    # Both routes must reproduce the ENTIRE stock EXE hash after restoring only
    # audited ranges. Unknown bytes and unknown outside edits are still refused.
    if($null -ne $existingCustom){[byte[]]$originalExe=$existingCustom.VerifiedOriginalExe}
    else {
        if($currentExe.Length -ne $m.exe.length){
            if(-not $customRecoveryReady){throw 'Extended image has no verified descriptor or recovery journal.'}
            Assert-ACRGameplayRecoveryTail $currentExe $m
            $currentExe=[ACRCustomBytes]::Slice($currentExe,0,[int]$m.exe.length);$knownExeHash=''
        }
        [byte[]]$originalExe=Get-OriginalBytes $currentExe $m.native_modules.patches $m.exe.sha256 $m.exe.relative_path 0 $knownExeHash
    }
    $currentExe=$null
    $report['ExecutableSHA256']=$exeHash
    $report['OriginalExecutableSHA256']=$m.exe.sha256
    $indexStream=[IO.File]::Open((Resolve-GameFile $m.index.relative_path),[IO.FileMode]::Open,$access,$sharing)
    $dataStream=[IO.File]::Open((Resolve-GameFile $m.ucas.relative_path),[IO.FileMode]::Open,$access,$sharing)
    if ($indexStream.Length -ne [long]$m.index.length -or $dataStream.Length -ne [long]$m.ucas.length) { throw 'Container length mismatch. Refusing to patch another build.' }
    [byte[]]$currentIndex=Read-Region $indexStream 0 ([int]$m.index.length)
    $indexHash=Get-BytesHash $currentIndex
    $report['IndexSHA256']=$indexHash
    [int]$knownState=-1
    for ($s=0; $s -lt $m.states.Count; $s++) { if ($indexHash -ceq $m.states[$s].index_sha256) { $knownState=$s; break } }
    $knownIndexHash=''
    if ($knownState -ge 0) { $knownIndexHash=[string]$m.states[$knownState].index_sha256 }
    [byte[]]$originalIndex=Get-OriginalBytes $currentIndex $m.index.patches $m.index.original_sha256 $m.index.relative_path 0 $knownIndexHash
    $observed=New-Object 'System.Collections.Generic.List[object]'
    $originals=New-Object 'System.Collections.Generic.List[byte[]]'
    foreach ($r in $m.regions) {
        [byte[]]$current=Read-Region $dataStream ([long]$r.offset) ([int]$r.length)
        $hash=Get-BytesHash $current
        $knownRegionHash=''
        if ($knownState -ge 0 -and $hash -ceq $r.sha256_by_state[$knownState]) {
            $knownRegionHash=[string]$r.sha256_by_state[$knownState]
        }
        [byte[]]$original=Get-OriginalBytes $current $r.patches $r.original_sha256 ($m.ucas.relative_path+' / '+$r.name) ([long]$r.offset) $knownRegionHash
        $originals.Add($original)
        $observed.Add([ordered]@{ Name=$r.name; Offset=[long]$r.offset; SHA256=$hash })
        if ($knownState -ge 0 -and $hash -ne $r.sha256_by_state[$knownState]) { $knownState=-1 }
    }
    $report['Before']=[ordered]@{ State='MixedOrInterrupted'; NativeModules='MixedOrInterrupted'; ExecutableSHA256=$exeHash; IndexSHA256=$indexHash; Regions=@($observed.ToArray()) }
    if ($knownState -ge 0) { $report['Before']['State']=$m.states[$knownState].id }
    if ($knownNative -ge 0) { $report['Before']['NativeModules']=(Get-ACRNativeState $m $knownNative).id }
    Write-Host ('Current content state: '+$report['Before']['State']+'; Native modules: '+$report['Before']['NativeModules'])
    $report['VerifiedRegions']=$m.regions.Count
    Add-CoreTiming 'LiveFileVerificationAndNormalizationMs'
    [int]$target=0; [int]$nativeTarget=0
    if ($Action -eq 'Install') {
        $target=-1
        for ($s=0; $s -lt $m.states.Count; $s++) {
            if ($m.states[$s].installable -and $m.states[$s].rate -eq $RateScale -and $m.states[$s].wet_tarmac -eq $WetTarmac) { $target=$s; break }
        }
        if ($target -lt 0) { throw 'Unknown requested module combination. Use supported menu selections.' }
        $guardWanted=($RateScale -ne '0' -or $WetTarmac -ne 'Off' -or $VisualDamage -ne 'Off' -or $CollisionDamage -ne 'Stock' -or $TyreDamage -ne 'Stock' -or $MechanicalFailures -ne 'Stock' -or $BrakeWear -ne 'Stock' -or $Detachment -ne 'Stock' -or $CriticalDamage -ne 'Stock' -or $CoolingRouting -ne 'Stock' -or $EngineImpact -ne 'Stock' -or $PowerResponse -ne 'Stock' -or $WheelImpact -ne 'Stock' -or $GearboxDamage -ne 'Stock' -or $requestedCustom.Count -gt 0)
        $nativeTarget=Find-ACRNativeSelection $m $VisualDamage $CollisionDamage ([bool]$guardWanted) $TyreDamage $MechanicalFailures $BrakeWear $Detachment $CriticalDamage $CoolingRouting $EngineImpact $PowerResponse $WheelImpact $GearboxDamage
        if ($nativeTarget -lt 0) { throw 'Unknown native-module combination.' }
    }
    if($Action -eq 'Install' -and $requestedCustom.Count -gt 0) {
        $customTarget=Add-ACRCustomConfiguration $m $nativeTarget $target $requestedCustom $originalExe $originalIndex $originals
        $nativeTarget=$customTarget.NativeIndex;$target=$customTarget.ContentIndex
    }
    if ($Action -eq 'Check') {
        $report['Status']='Checked'
        if ($knownState -lt 0 -or $knownNative -lt 0) { Write-Warning 'Mixed/interrupted state. DO NOT launch the game. Run this version''s Restore action.' }
        elseif ($knownState -eq 0 -and $knownNative -eq 0) { Write-Host 'Compatible stock files; all mod modules are OFF.' -ForegroundColor Green }
        else { Write-Host ('Installed: '+$m.states[$knownState].label+'; '+(Get-ACRNativeState $m $knownNative).id) -ForegroundColor Yellow }
        if ([IO.File]::Exists($journalPath)) { Write-Warning 'A previous write journal remains. Restore clears it after full stock verification.' }
    } elseif ($Action -eq 'Install' -and ($knownState -lt 0 -or $knownNative -lt 0)) {
        throw 'Mixed/interrupted state. Run Restore before installation. Do not launch the game.'
    } elseif ($Action -eq 'Install' -and [IO.File]::Exists($journalPath)) {
        throw 'An incomplete-write journal remains. Run Restore before installation.'
    } elseif ($target -eq $knownState -and $nativeTarget -eq $knownNative) {
        if ($Action -eq 'Restore') {
            Assert-InstalledState $m $indexStream $dataStream 0 $exeStream 0
            if ([IO.File]::Exists($journalPath)) { [IO.File]::Delete($journalPath) }
            $report['Status']='AlreadyStock'; Write-Host 'Already stock. Full executable, full index and all target regions verified.' -ForegroundColor Green
        } else { $report['Status']='AlreadyInstalled'; Write-Host 'The selected module combination is already installed. Values have NOT been multiplied again.' -ForegroundColor Green }
    } else {
        # Build and verify all target hashes before any game-file write.
        [byte[]]$candidateExe=Complete-ACRGameplayExecutable (Get-StateBytes $originalExe $m.native_modules.patches $nativeTarget) (Get-ACRNativeState $m $nativeTarget)
        if ((Get-BytesHash $candidateExe) -ne (Get-ACRNativeState $m $nativeTarget).exe_sha256) { throw 'Candidate executable self-check failed.' }
        $candidateExe=$null
        [byte[]]$candidateIndex=Get-StateBytes $originalIndex $m.index.patches $target
        if ((Get-BytesHash $candidateIndex) -ne $m.states[$target].index_sha256) { throw 'Candidate index self-check failed.' }
        [byte[]]$backupBlob=New-Object byte[] ([int]$m.backup.regions_length)
        $backupOffset=0
        for ($i=0; $i -lt $m.regions.Count; $i++) {
            $r=$m.regions[$i]; [byte[]]$original=$originals[$i]
            [byte[]]$candidate=Get-StateBytes $original $r.patches $target
            if ((Get-BytesHash $candidate) -ne $r.sha256_by_state[$target]) { throw ('Candidate asset self-check failed: '+$r.name) }
            [Array]::Copy($original,0,$backupBlob,$backupOffset,$original.Length); $backupOffset+=$original.Length
        }
        if ($backupOffset -ne $backupBlob.Length) { throw 'Backup length self-check failed.' }
        Add-CoreTiming 'CandidateConstructionAndVerificationMs'
        Save-OriginalBackup (Join-Path $stateRoot 'original-acr.exe') $originalExe $m.exe.sha256
        Save-OriginalBackup (Join-Path $stateRoot 'original-pakchunk1.utoc') $originalIndex $m.index.original_sha256
        Save-OriginalBackup (Join-Path $stateRoot 'original-regions.bin') $backupBlob $m.backup.regions_sha256
        Save-Json (Join-Path $stateRoot 'backup-info.json') ([ordered]@{
            Tool=$m.id; Version=$m.version; GameRoot=$GameRoot; ExecutableSHA256=$m.exe.sha256
            ExecutableBackup='original-acr.exe'; ExecutableLength=$m.exe.length
            UCASRelativePath=$m.ucas.relative_path; IndexOriginalSHA256=$m.index.original_sha256
            RegionsBlobSHA256=$m.backup.regions_sha256; RegionsBlobLength=$m.backup.regions_length
            Regions=@($m.regions | ForEach-Object { [ordered]@{ Name=$_.name; Offset=$_.offset; Length=$_.length; OriginalSHA256=$_.original_sha256 } })
        })
        Add-CoreTiming 'OriginalBackupValidationMs'
        Assert-GameClosed
        $journalCandidates=@(Get-ACRCustomJournalCandidate $existingCustom $m;Get-ACRCustomJournalCandidate $customTarget $m)
    if($Action -eq 'Restore' -and $journalCandidates.Count -eq 0 -and $customRecoveryReady){$journalCandidates=$inheritedCustomCandidates}
    if($journalCandidates.Count -gt 2){throw 'Too many bounded custom recovery candidates.'}
    Save-Json $journalPath ([ordered]@{ Tool=$m.id; Version=$m.version; Action=$Action; FromState=$report['Before']['State']; TargetState=$m.states[$target].id; CustomCandidates=$journalCandidates; FromNative=$report['Before']['NativeModules']; TargetNative=(Get-ACRNativeState $m $nativeTarget).id; UTC=[DateTime]::UtcNow.ToString('o') })
        $writeStarted=$true
        # Remove/restore the executable branch before content on a full restore.
        # With the game closed and all handles exclusive, no partial state is executable.
        if ($nativeTarget -eq 0) { Write-ExecutableRanges $exeStream $m.native_modules.patches 0 }
        # Fixed-length disjoint UCAS ranges, then their index hashes.
        foreach ($r in $m.regions) { Write-Ranges $dataStream ([long]$r.offset) $r.patches $target }
        $dataStream.Flush($true)
        Write-Ranges $indexStream 0 $m.index.patches $target
        $indexStream.Flush($true)
        if ($nativeTarget -ne 0) { Write-ExecutableRanges $exeStream $m.native_modules.patches $nativeTarget }
        Assert-InstalledState $m $indexStream $dataStream $target $exeStream $nativeTarget
        [IO.File]::Delete($journalPath)
        $report['After']=[ordered]@{ State=$m.states[$target].id; NativeModules=(Get-ACRNativeState $m $nativeTarget).id; VisualDamage=(Get-ACRNativeState $m $nativeTarget).visual_damage; CollisionDamage=(Get-ACRNativeState $m $nativeTarget).collision_damage; ExecutableSHA256=(Get-ACRNativeState $m $nativeTarget).exe_sha256; IndexSHA256=$m.states[$target].index_sha256; VerifiedRegions=$m.regions.Count; FileLengthsUnchanged=$true }
        if ($Action -eq 'Restore') {
            $report['Status']='Restored'; Write-Host 'Stock executable, activation, 112 tyre coefficients, tarmac wet-loss coefficient and index hashes restored and verified.' -ForegroundColor Green
        } else {
            $report['Status']='Installed'; $report['InstalledRateScale']=$m.states[$target].scale; $report['InstalledWetTarmac']=$m.states[$target].wet_tarmac; $report['InstalledVisualDamage']=(Get-ACRNativeState $m $nativeTarget).visual_damage; $report['InstalledCollisionDamage']=(Get-ACRNativeState $m $nativeTarget).collision_damage
            Write-Host ('Installed: '+$m.states[$target].label+'; '+(Get-ACRNativeState $m $nativeTarget).id) -ForegroundColor Green
            Write-Host 'Use fresh tyres / a fresh offline session. Reapplying selections never stacks multipliers.'
            Write-Warning 'File-level verification is complete, NOT gameplay validation. Stay offline. Damage stock means no mod-added scaling; the game still controls its normal damage settings.'
        }
        $writeStarted=$false
        Add-CoreTiming 'WriteAndFullReadbackVerificationMs'
    }
    $verifiedState=$knownState; $verifiedNative=$knownNative
    if ($Action -ne 'Check') { $verifiedState=$target; $verifiedNative=$nativeTarget }
    if ($verifiedState -ge 0 -and $verifiedNative -ge 0) {
        $verifiedCustom=Get-ACRCustomValuesFromState (Get-ACRNativeState $m $verifiedNative)
        $s=$m.states[$verifiedState]
        $report['VerifiedConfiguration']=[ordered]@{
            
            CustomValues=$verifiedCustom; State=$s.id; TyreWearEnabled=$s.wear_enabled; WearRateScale=$s.rate
            WetTarmac=$s.wet_tarmac; WetLossCoefficientScale=$s.wet_loss_scale
            VisualDamage=(Get-ACRNativeState $m $verifiedNative).visual_damage; VisualImpulseScale=(Get-ACRNativeState $m $verifiedNative).visual_multiplier
            CollisionDamage=(Get-ACRNativeState $m $verifiedNative).collision_damage; CollisionLossScale=(Get-ACRNativeState $m $verifiedNative).collision_multiplier
            TyreDamage=(Get-ACRNativeState $m $verifiedNative).tyre_damage
            MechanicalFailures=(Get-ACRNativeState $m $verifiedNative).mechanical_failures
            BrakeWear=(Get-ACRNativeState $m $verifiedNative).brake_wear
            Detachment=(Get-ACRNativeState $m $verifiedNative).detachment
            CriticalDamage=(Get-ACRNativeState $m $verifiedNative).critical_damage
            CoolingRouting=(Get-ACRNativeState $m $verifiedNative).cooling_routing
            EngineImpact=(Get-ACRNativeState $m $verifiedNative).engine_impact
            PowerResponse=(Get-ACRNativeState $m $verifiedNative).power_response
            WheelImpact=(Get-ACRNativeState $m $verifiedNative).wheel_impact
            GearboxDamage=(Get-ACRNativeState $m $verifiedNative).gearbox_damage
            CriticalAdmissionOverride=(Get-ACRNativeState $m $verifiedNative).critical_admission_override
            TyreCompressionRateOverride=(Get-ACRNativeState $m $verifiedNative).tyre_compression_rate_override
            FailureHealthThresholdOverride=(Get-ACRNativeState $m $verifiedNative).failure_health_threshold_override
            BrakeConsumptionGateOverride=(Get-ACRNativeState $m $verifiedNative).brake_consumption_gate_override
            AttachmentThresholdOverride=(Get-ACRNativeState $m $verifiedNative).attachment_global_threshold_override
            NativeExtensionsGameplayTested=$false; ClutchDifferentialWearPatched=$false
            GameLocalStartupGuard=[bool](Get-ACRNativeState $m $verifiedNative).startup_guard; NativeHTTPRejection=[bool](Get-ACRNativeState $m $verifiedNative).http_request_block; CompleteNetworkIsolationProven=$false; ExecutableSHA256=(Get-ACRNativeState $m $verifiedNative).exe_sha256; DamageChangesImplemented=$true; VisualDamageGameplayTested=$false; CollisionDamageGameplayTested=$false; AdditionalWearGripPenaltyImplemented=$false
        }
    }
} catch {
    $report['Status']='Failed'; $report['Error']=$_.Exception.Message
    $exception=$_.Exception
    while ($null -ne $exception) {
        if ($exception.Data.Contains('PatchMismatch')) { $report['PatchMismatch']=$exception.Data['PatchMismatch']; break }
        $exception=$exception.InnerException
    }
    $report['WriteStarted']=[bool]$writeStarted
    if ($writeStarted -and $null -ne $m) {
        $errors=New-Object 'System.Collections.Generic.List[string]'
        try { Write-ExecutableRanges $exeStream $m.native_modules.patches 0 } catch { $errors.Add($_.Exception.Message) }
        foreach ($r in $m.regions) {
            try { Write-Ranges $dataStream ([long]$r.offset) $r.patches 0 } catch { $errors.Add($_.Exception.Message) }
        }
        try { $dataStream.Flush($true) } catch { $errors.Add($_.Exception.Message) }
        try { Write-Ranges $indexStream 0 $m.index.patches 0; $indexStream.Flush($true) } catch { $errors.Add($_.Exception.Message) }
        $verified=$false
        try { Assert-InstalledState $m $indexStream $dataStream 0 $exeStream 0; $verified=$true } catch { $errors.Add($_.Exception.Message) }
        $report['RollbackToStockVerified']=$verified
        if ($verified) {
            try { if ([IO.File]::Exists($journalPath)) { [IO.File]::Delete($journalPath) } } catch { $errors.Add($_.Exception.Message) }
            Write-Warning 'Operation failed, but rollback to STOCK was verified. The requested module combination is not installed.'
        } else { Write-Warning 'Rollback is NOT verified. DO NOT launch the game. Use this version''s Restore; if it refuses, use Steam file-integrity verification.' }
    }
    if ($writeStarted) { $report['RollbackErrors']=@($errors.ToArray()) }
    Write-Host ('ERROR: '+$report['Error']) -ForegroundColor Red
    Write-Host 'For access-denied errors, close ACR and run as administrator. Do not force mismatched files or change their permissions.'
} finally {
    Add-CoreTiming 'CompletionOrFailureHandlingMs'
    $script:CoreTimings['TotalCoreMs']=[math]::Round($script:CoreTimingClock.Elapsed.TotalMilliseconds,2)
    $report['TimingsMs']=$script:CoreTimings
    foreach ($stream in @($dataStream,$indexStream,$exeStream)) { if ($null -ne $stream) { $stream.Dispose() } }
    if ($reportPath) {
        try { Save-Json $reportPath $report; Write-Host ('Report: '+$reportPath) }
        catch { Write-Warning ('Could not save report: '+$_.Exception.Message) }
    }
    Exit-ACROperation $operation
}
# Return to the release wrapper; never terminate its recovery/diagnostic workflow.
return [pscustomobject]$report
