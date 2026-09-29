#Requires -Version 5.1
[CmdletBinding()]param([string]$OutputPath='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot;$checks=New-Object 'Collections.Generic.List[object]';$clock=[Diagnostics.Stopwatch]::StartNew()
function Require($Test,[string]$Message){if(-not $Test){throw $Message}}
function SafetyCheck([string]$Name,[scriptblock]$Body){
 $sw=[Diagnostics.Stopwatch]::StartNew();$ok=$true;$error=''
 try{& $Body}catch{$ok=$false;$error=$_.Exception.Message}
 $checks.Add([pscustomobject]@{Name=$Name;Passed=$ok;Milliseconds=[math]::Round($sw.Elapsed.TotalMilliseconds,2);Error=$error})
 if($ok){Write-Host ('PASS '+$Name)}else{Write-Host ('FAIL '+$Name+': '+$error) -ForegroundColor Red}
}
SafetyCheck 'Public package has no development-era runtime files' {
 Require (-not [IO.File]::Exists((Join-Path $root 'tests\Test-ACR-Release.ps1'))) 'Pre-release developer suite is present.'
}
SafetyCheck 'PowerShell syntax for all shipped scripts' {
 foreach($p in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {$_.Extension -in @('.ps1','.psm1')}){
  $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($p.FullName,[ref]$tokens,[ref]$errors)
  Require ($errors.Count -eq 0) ($p.FullName+': '+(($errors|ForEach-Object{$_.Message}) -join ' | '))
 }
}
SafetyCheck 'Authenticated runtime manifest and current gameplay layout' {
 Import-Module (Join-Path $root 'modules\ACR.Common.psm1') -Force -ErrorAction Stop
 Import-Module (Join-Path $root 'modules\ACR.Custom.psm1') -Force -ErrorAction Stop
 Import-Module (Join-Path $root 'modules\ACR.Gameplay.psm1') -Force -ErrorAction Stop
 $m=Get-ACRRuntimeManifest $root
 Require ($m.version -ceq '1.0.1') 'Runtime manifest is not 1.0.1.'
 $layout=Get-ACRGameplayLayout
 Require ($layout.Entries.Count -eq 15) 'Unexpected gameplay entry count.'
 Require ($layout.FeatureKeys -notcontains 'EngineWearAudit') 'Developer accounting feature remains public.'
 if(-not ('ACRDamageProbe' -as [type])){Add-Type -Path (Join-Path $root 'tools\ACR_DamageProbe.cs')}
 [ACRDamageProbe]::ValidateGameplayFeatures([string[]]$layout.FeatureKeys)
 foreach($entry in $layout.Entries){
  $p=@($m.native_modules.patches|Where-Object {$_.name -ceq $entry.NativePatchName})
  Require ($p.Count -eq 1) ('Missing native entry: '+$entry.NativePatchName)
  Require ($p[0].offset -eq $entry.Offset) ('Native offset disagreement: '+$entry.NativePatchName)
 }
}
SafetyCheck 'Core verification report builder is executable' {
 $core=[IO.File]::ReadAllText((Join-Path $root 'Grip-Happens.Core.ps1'))
 $matches=[regex]::Matches($core,'(?m)^\s*\$report\[''VerifiedConfiguration''\]=\[ordered\]@\{\s*$')
 Require ($matches.Count -eq 1) 'VerifiedConfiguration must be constructed by one standalone assignment.'
 Require ($core -notmatch '\$verifiedNative\s{4,}\$report\[''VerifiedConfiguration''\]') 'Merged verification statements detected.'
}
SafetyCheck 'Recommended profile is the public gameplay setup' {
 Import-Module (Join-Path $root 'modules\ACR.Player.psm1') -Force -ErrorAction Stop
 Import-Module (Join-Path $root 'modules\ACR.Desktop.psm1') -Force -ErrorAction Stop
 $s=Get-ACRPlayerPreset 'Recommended';$cv=Get-ACRCustomValuesFromSettings $s
 Require ($s.RateScale -ceq '0.005' -and $s.WetTarmac -ceq 'Moderate') 'Tyre/wet Recommended changed.'
 Require ($s.VisualDamage -ceq 'Enhanced' -and $s.CollisionDamage -ceq 'Sensitive') 'Crash Recommended changed.'
 Require ($s.TyreDamage -ceq 'Native' -and $s.MechanicalFailures -ceq 'Earlier85' -and $s.BrakeWear -ceq 'Native' -and $s.Detachment -ceq 'Easier' -and $s.CriticalDamage -ceq 'Cumulative') 'Damage-system Recommended changed.'
 Require ($s.CoolingRouting -ceq 'EngineBay' -and $s.EngineImpact -ceq 'Matched' -and $s.PowerResponse -ceq 'Progressive' -and $s.WheelImpact -ceq 'Bent' -and $s.GearboxDamage -ceq 'Consequences') 'Powertrain/chassis Recommended changed.'
 foreach($pair in @(@('CollisionScale','1.5'),@('EngineUseWearScale','0.5'),@('GearboxProgression','1'),@('GearboxStressExposure','0.12'),@('DifferentialWearRate','0.000001'),@('SuspensionAlignmentDegrees','1.5'),@('SuspensionCamberDegrees','2.5'),@('CoolingConsequences','1'),@('CoolingHealthThreshold','0.9'),@('CoolingStressRate','1'),@('HudDamageWarnings','1'))){
  Require ($cv.Contains($pair[0]) -and $cv[$pair[0]] -ceq $pair[1]) ('Recommended custom value changed: '+$pair[0])
 }
 Require (-not $cv.Contains('EngineWearAudit')) 'Developer accounting is enabled.'
 Require (Test-ACRDesktopStockSelection (Get-ACRPlayerPreset 'Stock')) 'Original-game profile is not stock.'
}
SafetyCheck 'Recording publication is take-bound and public-only' {
 Import-Module (Join-Path $root 'modules\ACR.Recording.psm1') -Force -ErrorAction Stop
 $take='0123456789abcdef0123456789abcdef'
 $valid='Grip_Happens_DamageState_DrivingTrace_20260929_120000_'+$take+'.zip'
 Require ([IO.Path]::GetFileName((Get-ACRRecordingExportPath $valid $take)) -ceq $valid) 'Valid driving trace rejected.'
 $failed=$false;try{$null=Get-ACRRecordingExportPath ('Grip_Happens_DamageState_Developer_20260929_120000_'+$take+'.zip') $take}catch{$failed=$true}
 Require $failed 'Development-only recording filename accepted.'
}
SafetyCheck 'Player UI/help covers shipped controls and permanent support link' {
 Import-Module (Join-Path $root 'modules\ACR.Player.psm1') -Force -ErrorAction Stop
 Import-Module (Join-Path $root 'modules\ACR.Desktop.psm1') -Force -ErrorAction Stop
 $xaml=[IO.File]::ReadAllText((Join-Path $root 'ui\Main.xaml'))
 Require ($xaml.Contains('x:Name="BuyCoffeeButton"')) 'Buy Me a Coffee button missing.'
 Require (-not $xaml.Contains('Compatibility &amp; beta status') -and -not $xaml.Contains('CalArmChoice')) 'Pre-release UI remains.'
 $player=[IO.File]::ReadAllText((Join-Path $root 'modules\ACR.Player.psm1'))
 Require ($player.Contains('https://buymeacoffee.com/davethegeek')) 'Support URL is not pinned.'
 foreach($field in (Get-ACRCustomSchema).Fields){Require (-not [string]::IsNullOrWhiteSpace((Get-ACRPlayerControlHelp $field.Key))) ('Missing numeric help: '+$field.Key)}
 foreach($key in (Get-ACRDesktopChoices).Keys){Require (-not [string]::IsNullOrWhiteSpace((Get-ACRPlayerSystemHelp $key))) ('Missing system help: '+$key)}
}
SafetyCheck 'Frozen critical files match release metadata' {
 $meta=Get-Content -LiteralPath (Join-Path $root 'release-metadata.json') -Raw|ConvertFrom-Json
 Require ($meta.release -ceq '1.0.1' -and $meta.channel -ceq 'public-release') 'Release metadata is not public 1.0.1.'
 foreach($p in $meta.frozen_files.PSObject.Properties){
  $file=Join-Path $root $p.Name;Require ([IO.File]::Exists($file)) ('Missing frozen file: '+$p.Name)
  $actual=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
  Require ($actual -ceq [string]$p.Value) ('Frozen file changed: '+$p.Name)
 }
}
SafetyCheck 'Recognized runtime states have unique fingerprints' {
 Import-Module (Join-Path $root 'modules\ACR.Common.psm1') -Force -ErrorAction Stop
 $m=Get-ACRRuntimeManifest $root
 Require ((Get-ACRNativeStateCount $m) -ge 1) 'Runtime state catalogue is empty.'
 Require ([GripHappensRuntimeNativeV1]::UniqueHashes()) 'Duplicate executable fingerprint.'
}
$passed=@($checks|Where-Object{-not $_.Passed}).Count -eq 0
$report=[ordered]@{Tool='GripHappensInstallSafety';Version='1.0.1';Mode='InstallationSafety';UTC=[DateTime]::UtcNow.ToString('o');Passed=$passed;TotalMilliseconds=[math]::Round($clock.Elapsed.TotalMilliseconds,2);Checks=$checks.ToArray();GameFilesChanged=$false;CoreMustVerifyLiveFiles=$true}
if(-not $OutputPath){$OutputPath=Join-Path $env:USERPROFILE ('Downloads\Grip_Happens_InstallSafety_'+[Guid]::NewGuid().ToString('N')+'.json')}
[IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath))|Out-Null
[IO.File]::WriteAllText($OutputPath,($report|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($true)))
Write-Host ('Installation-safety report: '+$OutputPath)
if($passed){exit 0}else{exit 1}
