#Requires -Version 5.1
# Allowlist export, not regex scrubbing of arbitrary private logs.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ACR.Common.psm1') -ErrorAction Stop
function ConvertTo-ACRSafeEnum($Value,[string[]]$Allowed) {
    if ($null -ne $Value -and $Allowed -contains [string]$Value) { return [string]$Value }
    return 'Unknown'
}
function Get-ACRProperty($Object,[string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $null }
    $p=$Object.PSObject.Properties[$Name]; if ($null -ne $p) { return $p.Value }; return $null
}
function ConvertTo-ACRSafeHash($Value) {
    if ($null -ne $Value -and [string]$Value -match '^[a-fA-F0-9]{64}$') { return ([string]$Value).ToLowerInvariant() }
    return $null
}
function New-ACRSanitizedReport($Diagnostic) {
    $core=Get-ACRProperty $Diagnostic 'Core'
    $config=Get-ACRProperty $core 'VerifiedConfiguration';$configurationSource='Latest operation';$configurationCore=$core
    if($null -eq $config){$last=Get-ACRProperty $Diagnostic 'SupportLastVerifiedCore';$config=Get-ACRProperty $last 'VerifiedConfiguration';if($null -ne $config){$configurationSource='Last successful file check; may precede the latest operation';$configurationCore=$last}}
    $exeHash=ConvertTo-ACRSafeHash (Get-ACRProperty $config 'ExecutableSHA256')
    if (-not $exeHash) { $exeHash=ConvertTo-ACRSafeHash (Get-ACRProperty $configurationCore 'ExecutableSHA256') }
    $report=[ordered]@{
        ConfigurationSource=$configurationSource
        Tool='Grip_Happens_Support'; Version='1.0.1'; UTC=[DateTime]::UtcNow.ToString('o')
        PowerShellVersion=$PSVersionTable.PSVersion.ToString(); WindowsVersion=[Environment]::OSVersion.Version.ToString()
        Is64BitProcess=[Environment]::Is64BitProcess
        Action=(ConvertTo-ACRSafeEnum (Get-ACRProperty $Diagnostic 'Action') @('Check','Install','Restore','Snapshot','DriveTrace','Support','Menu'))
        Result=(ConvertTo-ACRSafeEnum (Get-ACRProperty $Diagnostic 'Status') @('Success','Failed','Cancelled','Starting'))
        CoreStatus=(ConvertTo-ACRSafeEnum (Get-ACRProperty $core 'Status') @('Checked','Installed','AlreadyInstalled','Restored','AlreadyStock','Failed'))
        Wear=(ConvertTo-ACRSafeEnum (Get-ACRProperty $config 'WearRateScale') @('0','0.00025','0.0005','0.001','0.002','0.005','0.01','0.02','0.05','0.1'))
        WetTarmac=(ConvertTo-ACRSafeEnum (Get-ACRProperty $config 'WetTarmac') @('Off','VeryLight','Light','Mild','Balanced','Moderate','Firm','Strong','Maximum'))
        VisualDamage=(ConvertTo-ACRSafeEnum (Get-ACRProperty $config 'VisualDamage') @('Off','Enhanced','Strong'))
        CollisionDamage=(ConvertTo-ACRSafeEnum (Get-ACRProperty $config 'CollisionDamage') @('Stock','Sensitive','Strong'))
        TyreDamage=(ConvertTo-ACRSafeEnum (Get-ACRProperty $config 'TyreDamage') @('Stock','Native'))
        MechanicalFailures=(ConvertTo-ACRSafeEnum (Get-ACRProperty $config 'MechanicalFailures') @('Stock','Earlier85','Earlier90'))
        BrakeWear=(ConvertTo-ACRSafeEnum (Get-ACRProperty $config 'BrakeWear') @('Stock','Native'))
        Detachment=(ConvertTo-ACRSafeEnum (Get-ACRProperty $config 'Detachment') @('Stock','Easier','Aggressive'))
        CriticalDamage=(ConvertTo-ACRSafeEnum (Get-ACRProperty $config 'CriticalDamage') @('Stock','Cumulative'))
        CoolingRouting=(ConvertTo-ACRSafeEnum (Get-ACRProperty $config 'CoolingRouting') @('Stock','EngineBay'))
        EngineImpact=(ConvertTo-ACRSafeEnum (Get-ACRProperty $config 'EngineImpact') @('Stock','Matched'))
        PowerResponse=(ConvertTo-ACRSafeEnum (Get-ACRProperty $config 'PowerResponse') @('Stock','Progressive'))
        WheelImpact=(ConvertTo-ACRSafeEnum (Get-ACRProperty $config 'WheelImpact') @('Stock','Localized','Bent'))
        GearboxDamage=(ConvertTo-ACRSafeEnum (Get-ACRProperty $config 'GearboxDamage') @('Stock','Grinding','Impact','Responsive','Mechanical','Engagement','Consequences'))
        ExecutableSHA256=$exeHash
        StartupGuard=(ConvertTo-ACRSafeEnum (Get-ACRProperty $config 'GameLocalStartupGuard') @('True','False'))
        NativeHTTPRejection=(ConvertTo-ACRSafeEnum (Get-ACRProperty $config 'NativeHTTPRejection') @('True','False'))
        CompleteNetworkIsolationProven=$false; SystemNetworkSettingsChanged=$false
        CachedResultIsolationImplemented=$false; AdditionalWearGripPenaltyImplemented=$false
        RawLogsIncluded=$false; GameFilesIncluded=$false; SavesIncluded=$false; LocalPathsIncluded=$false
        AutomaticUpload=$false; Note='Allowlisted summary only. Does not certify complete request coverage or in-game behavior.'
    }
    $phase=Get-ACRProperty $Diagnostic 'Phase'
    $report['Phase']=ConvertTo-ACRSafeEnum $phase @('Startup','Integrity','Discovery','Menu','Preflight','Consent','Physics','Restore','Snapshot','Export','Complete')
    $report['IndexSHA256']=ConvertTo-ACRSafeHash (Get-ACRProperty $configurationCore 'IndexSHA256')    $report['WriteStarted']=ConvertTo-ACRSafeEnum (Get-ACRProperty $core 'WriteStarted') @('True','False')
    $mismatch=Get-ACRProperty $core 'PatchMismatch'
    if ($null -ne $mismatch) {
        $safe=[ordered]@{}
        $safe['Reason']=ConvertTo-ACRSafeEnum (Get-ACRProperty $mismatch 'Reason') @('NormalizedHashMismatch','UnexpectedPatchByte')
        $offset=Get-ACRProperty $mismatch 'FileOffset'
        # Never convert arbitrary strings from an error report into output fields.
        if (($offset -is [int] -or $offset -is [long]) -and $offset -ge 0 -and $offset -le 2147483647) { $safe['FileOffset']=[long]$offset }
        $actual=Get-ACRProperty $mismatch 'ActualByte'
        if ($actual -is [string] -and $actual -match '^[0-9A-Fa-f]{2}$') { $safe['ActualByte']=$actual.ToUpperInvariant() }
        $file=Get-ACRProperty $mismatch 'File'
        if ($file -is [string] -and $file -ceq 'acr/Binaries/Win64/acr.exe') { $safe['File']='GameExecutable' }
        elseif ($file -is [string] -and $file -ceq 'acr/Content/Paks/pakchunk1-Windows.utoc') { $safe['File']='ContainerIndex' }
        elseif ($file -is [string] -and $file.StartsWith('acr/Content/Paks/pakchunk1-Windows.ucas / ',[StringComparison]::Ordinal)) { $safe['File']='TargetedContentRegion' }
        else { $safe['File']='Unknown' }
        $safe['ExpectedOriginalSHA256']=ConvertTo-ACRSafeHash (Get-ACRProperty $mismatch 'ExpectedOriginalSHA256')
        $safe['NormalizedSHA256']=ConvertTo-ACRSafeHash (Get-ACRProperty $mismatch 'NormalizedSHA256')
        # Range labels, messages and all paths remain local; only typed numbers and hashes leave the private report.
        $report['PatchMismatch']=[pscustomobject]$safe
    }
    # Timing export is a numeric allowlist, not raw logs or arbitrary object fields.
    $timings=Get-ACRProperty $core 'TimingsMs'
    $safeTimings=[ordered]@{}
    foreach($name in @('RuntimeAndManifestValidationMs','LiveFileVerificationAndNormalizationMs','CandidateConstructionAndVerificationMs','OriginalBackupValidationMs','WriteAndFullReadbackVerificationMs','CompletionOrFailureHandlingMs','TotalCoreMs')) {
        $value=Get-ACRProperty $timings $name
        if($value -is [double] -or $value -is [single] -or $value -is [decimal] -or $value -is [int] -or $value -is [long]) {
            $number=[double]$value
            if(-not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and $number -ge 0 -and $number -le 86400000) {
                $safeTimings[$name]=[math]::Round($number,2)
            }
        }
    }
    $value=Get-ACRProperty $Diagnostic 'InstallSafetyMilliseconds'
    if($value -is [double] -or $value -is [single] -or $value -is [decimal] -or $value -is [int] -or $value -is [long]) {
        $number=[double]$value
        if(-not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and $number -ge 0 -and $number -le 86400000) {
            $safeTimings['InstallSafetyMs']=[math]::Round($number,2)
        }
    }
    $report['TimingsMs']=[pscustomobject]$safeTimings
    $report['UtilityBuild']='1.0.1'
    $custom=Get-ACRProperty $config 'CustomValues'
    if($null -ne $custom){try{Import-Module (Join-Path $PSScriptRoot 'ACR.Custom.psm1') -ErrorAction Stop;$v=ConvertTo-ACRCustomMap $custom;$safe=[ordered]@{};foreach($key in $v.Keys){$safe[$key]=[double]::Parse($v[$key],[Globalization.CultureInfo]::InvariantCulture)};$report['CustomValues']=[pscustomobject]$safe}catch{$report['CustomValuesStatus']='Invalid - excluded'}}
    $report['SupportedFileSet']='ACR-42c359b0';$report['Distribution']='Public release';$report['AccountDataIncluded']=$false
    return [pscustomobject]$report
}
function Export-ACRSanitizedSupport([string]$OutputDirectory,$PreparedReport=$null) {
    if (-not $OutputDirectory) { $OutputDirectory=Get-ACRDownloads }
    $public=if($null -ne $PreparedReport){$PreparedReport}else{New-ACRSanitizedReport (Get-ACRSupportDiagnostic)}
    $name='Grip_Happens_Support_'+[DateTime]::Now.ToString('yyyyMMdd_HHmmss')+'_'+[Guid]::NewGuid().ToString('N').Substring(0,8)
    $stage=Join-Path ([IO.Path]::GetTempPath()) $name
    [IO.Directory]::CreateDirectory($stage)|Out-Null
    [IO.Directory]::CreateDirectory($OutputDirectory)|Out-Null
    try {
        Save-ACRJson (Join-Path $stage 'support-summary.json') $public
        'This report contains an allowlisted summary of the last launcher operation. No raw logs, paths, usernames, Steam IDs, memory snapshots, saves, or game files are bundled. Nothing was uploaded automatically. It cannot prove complete server-request coverage or gameplay behavior.' | Set-Content -LiteralPath (Join-Path $stage 'README.txt') -Encoding UTF8
        $zip=Join-Path $OutputDirectory ($name+'.zip')
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
        Write-Host ('Sanitized support ZIP: '+$zip) -ForegroundColor Green
        return $zip
    } finally { if ([IO.Directory]::Exists($stage)) { Remove-Item -LiteralPath $stage -Recurse -Force } }
}
function Get-ACRSupportDiagnostic {
 $p=Join-Path (Get-ACRUserStateRoot) 'latest-diagnostic.json'
 if(-not [IO.File]::Exists($p)){return $null};Assert-ACRNoReparse $p
 if((Get-Item -LiteralPath $p).Length -gt 2097152){throw 'Local diagnostic is too large to preview safely.'}
 $d=[IO.File]::ReadAllText($p)|ConvertFrom-Json
 $lastPath=Join-Path (Get-ACRUserStateRoot) 'last-file-check.json'
 if([IO.File]::Exists($lastPath)){Assert-ACRNoReparse $lastPath;if((Get-Item -LiteralPath $lastPath).Length -le 2097152){$last=[IO.File]::ReadAllText($lastPath)|ConvertFrom-Json;$d|Add-Member NoteProperty SupportLastVerifiedCore (Get-ACRProperty $last 'Core') -Force}}
 return $d
}
Export-ModuleMember -Function *-ACR*
