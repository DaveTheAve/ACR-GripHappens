# Player-facing profiles for Grip Happens 1.0.1.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ACR.Common.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ACR.Desktop.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ACR.Custom.psm1') -ErrorAction Stop
function Get-ACRPlayerPreset([ValidateSet('Recommended','TyresOnly','Stock')][string]$Name='Recommended') {
 $s=Get-ACRDesktopDefaults
 if($Name -eq 'Stock'){$s.RateScale='0';$s.WetTarmac='Off';return $s}
 if($Name -eq 'TyresOnly'){return $s}
 $s.VisualDamage='Enhanced';$s.CollisionDamage='Sensitive';$s.TyreDamage='Native';$s.MechanicalFailures='Earlier85'
 $s.BrakeWear='Native';$s.Detachment='Easier';$s.CriticalDamage='Cumulative';$s.CoolingRouting='EngineBay'
 $s.EngineImpact='Matched';$s.PowerResponse='Progressive';$s.WheelImpact='Bent';$s.GearboxDamage='Consequences'
 $custom=ConvertTo-ACRCustomMap ([ordered]@{
   CollisionScale='1.5';GearboxProgression='1';GearboxStressExposure='0.12';DifferentialWearRate='0.000001'
   SuspensionAlignmentDegrees='1.5';SuspensionCamberDegrees='2.5';CoolingConsequences='1'
   CoolingHealthThreshold='0.9';CoolingStressRate='1';HudDamageWarnings='1';EngineUseWearScale='0.5'
 })
 $s|Add-Member NoteProperty CustomValues $custom
 return $s
}
function Get-ACRPlayerProfileName($Settings) {
 if(-not (Test-ACRDesktopSettings $Settings)){return 'Not verified'}
 foreach($pair in @(@('Recommended','Recommended - Grip Happens'),@('TyresOnly','Tyres & wet grip only'),@('Stock','Original game'))){
  if(Test-ACRDesktopConfigurationMatch (Get-ACRPlayerPreset $pair[0]) $Settings){return $pair[1]}
 }
 return 'Custom setup'
}
function Get-ACRPlayerGroupReset($Settings,[string]$Group) {
 if(-not (Test-ACRDesktopSettings $Settings)){throw 'Choose valid settings first.'}
 $schema=Get-ACRCustomSchema;$groups=@('DrivetrainWear')+@(Get-ACRDesktopChoices).Keys
 if($Group -cnotin $groups){throw 'Unknown tuning section.'}
 $s=$Settings|ConvertTo-Json -Depth 8|ConvertFrom-Json;$recommended=Get-ACRPlayerPreset
 $cv=Get-ACRCustomValuesFromSettings $s;$defaults=Get-ACRCustomValuesFromSettings $recommended
 if($Group -ne 'DrivetrainWear'){$s.$Group=$recommended.$Group}
 foreach($f in $schema.Fields){if($f.Group -eq $Group){if($cv.Contains($f.Key)){$cv.Remove($f.Key)};if($defaults.Contains($f.Key)){$cv[$f.Key]=$defaults[$f.Key]}}}
 if($null -eq $s.PSObject.Properties['CustomValues']){$s|Add-Member NoteProperty CustomValues $cv}else{$s.CustomValues=$cv}
 return $s
}
function Get-ACRPlayerHelp {
 return (Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot) 'player-help.json') -Raw|ConvertFrom-Json)
}
function Get-ACRPlayerControlHelp([string]$Key) {
 $p=(Get-ACRPlayerHelp).Controls.PSObject.Properties[$Key];if($null -eq $p){throw ('No player explanation for '+$Key)};return [string]$p.Value
}
function Get-ACRPlayerSystemHelp([string]$Key) {
 $p=(Get-ACRPlayerHelp).Systems.PSObject.Properties[$Key];if($null -eq $p){throw ('No player explanation for '+$Key)};return [string]$p.Value
}
function Get-ACRPlayerVerificationText($Settings,[switch]$Installed) {
 if(-not (Test-ACRDesktopSettings $Settings)){return 'Installed setup not verified. Run Check installation.'}
 $name=Get-ACRPlayerProfileName $Settings
 if($Installed){return ($name+' - installed and file-verified.')}
 return ($name+' selected. Review & apply is required to change the game.')
}
function Open-ACRBuyMeACoffee {
 $start=New-Object Diagnostics.ProcessStartInfo
 $start.FileName='https://buymeacoffee.com/davethegeek'
 $start.UseShellExecute=$true
 $process=[Diagnostics.Process]::Start($start)
 if($null -eq $process){throw 'Windows did not open the support page.'}
 $process.Dispose()
}
Export-ModuleMember -Function *-ACRPlayer*,Open-ACRBuyMeACoffee
