# Current Grip Happens gameplay image construction and strict extended-image recovery.
Set-StrictMode -Version Latest
$script:GameplayLayoutHash='f52934a0bfc092dd89f3e1ba537804e969b03cc6950517307488828579a59d32'
$script:GameplayLayout=$null
function Get-ACRGameplayLayout {
 if($null -eq $script:GameplayLayout){
  $path=Join-Path (Split-Path $PSScriptRoot) 'gameplay-layout.json'
  if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $script:GameplayLayoutHash){throw 'Gameplay layout failed verification.'}
  $script:GameplayLayout=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
  if($script:GameplayLayout.Schema -ne 1 -or $script:GameplayLayout.CodeLength -ne 8192 -or $script:GameplayLayout.DataLength -ne 4096){throw 'Unsupported gameplay layout.'}
  foreach($entry in $script:GameplayLayout.Entries){if($null -eq $entry.PSObject.Properties['NativePatchName'] -or [string]::IsNullOrWhiteSpace([string]$entry.NativePatchName)){throw 'Gameplay layout entry is missing its native patch identity.'}}
 }
 return $script:GameplayLayout
}
function Test-ACRGameplayFeature($Map,[string]$Key) {
 if($Key -ceq 'EngineUseWearScale'){return ($Map.Contains($Key) -and [double]::Parse([string]$Map[$Key],[Globalization.CultureInfo]::InvariantCulture) -ne 1)}
 return ($Map.Contains($Key) -and [double]::Parse([string]$Map[$Key],[Globalization.CultureInfo]::InvariantCulture) -gt 0)
}
function Test-ACRGameplayEnabled($Map) {
 foreach($key in (Get-ACRGameplayLayout).FeatureKeys){if(Test-ACRGameplayFeature $Map $key){return $true}}
 return $false
}
function Test-ACRGameplayExecutableLength([long]$Length) {
 $layout=Get-ACRGameplayLayout
 return ($Length -eq $layout.OriginalLength -or $Length -eq $layout.NewLength)
}
function Get-ACRGameplayExecutableLength($State,[long]$OriginalLength) {
 if($null -ne $State.PSObject.Properties['custom_executable_length']){
  $n=[long]$State.custom_executable_length;if(-not (Test-ACRGameplayExecutableLength $n)){throw 'Unrecognized executable extent.'};return $n
 }
 return $OriginalLength
}
function Add-ACRGameplayBytes([byte[]]$Exe,$Values,$NativeState) {
 $layout=Get-ACRGameplayLayout
 if(-not (Test-ACRGameplayEnabled $Values)){return ,$Exe}
 if($Exe.Length -ne $layout.OriginalLength){throw 'Gameplay construction requires a verified original-sized base.'}
 [byte[]]$code=[ACRCustomBytes]::Unhex($layout.CodeHex)
 if([ACRCustomBytes]::Hash($code) -cne $layout.CodeSHA256){throw 'Gameplay code template failed verification.'}
 if($NativeState.gearbox_damage -eq 'Engagement'){[ACRCustomBytes]::Put($code,0x1c08,[BitConverter]::GetBytes([single]0.75))}
 foreach($property in $layout.ConstantOffsets.PSObject.Properties){
  if($Values.Contains($property.Name)){
   $value=[single]::Parse([string]$Values[$property.Name],[Globalization.CultureInfo]::InvariantCulture)
   [ACRCustomBytes]::Put($code,[int]$property.Value,[BitConverter]::GetBytes($value))
  }
 }
 if($NativeState.gearbox_damage -notin @('Responsive','Mechanical','Engagement','Consequences')){
  $displacement=[int](0x00d22500-[int]$layout.CoolingFallbackNextRVA)
  [ACRCustomBytes]::Put($code,[int]$layout.CoolingFallbackOffset,[BitConverter]::GetBytes($displacement))
 }
 if(Test-ACRGameplayFeature $Values 'EngineUseWearScale'){
  $wear=$layout.EngineUseWear;$scale=[single]::Parse([string]$Values['EngineUseWearScale'],[Globalization.CultureInfo]::InvariantCulture)
  if([single]::IsNaN($scale) -or [single]::IsInfinity($scale) -or $scale -lt 0 -or $scale -gt 2){throw 'Invalid routine engine wear scale.'}
  [ACRCustomBytes]::Put($code,[int]$wear.Offset,[ACRCustomBytes]::Unhex($wear.Bytes))
  [ACRCustomBytes]::Put($code,[int]$wear.ConstantOffset,[BitConverter]::GetBytes($scale))
 }
 if(Test-ACRGameplayFeature $Values 'HudDamageWarnings'){
  foreach($span in $layout.HudDisplay.CodeSpans){[ACRCustomBytes]::Put($code,[int]$span.Offset,[ACRCustomBytes]::Unhex([string]$span.Bytes))}
  $progression=[int](Test-ACRGameplayFeature $Values 'GearboxProgression')
  [ACRCustomBytes]::Put($code,[int]$layout.HudDisplay.GearboxFlagOffset,[BitConverter]::GetBytes($progression))
 }
 foreach($key in @('SuspensionAlignmentDegrees','SuspensionCamberDegrees')){if(-not (Test-ACRGameplayFeature $Values $key)){[ACRCustomBytes]::Put($code,[int]$layout.ConstantOffsets.$key,[BitConverter]::GetBytes([single]0))}}
 if(Test-ACRGameplayFeature $Values 'HudDamageWarnings'){[ACRCustomBytes]::Put($code,[int]$layout.OperationalFeedback.EnabledOffset,[BitConverter]::GetBytes([int]1))}
 [byte[]]$result=New-Object byte[] ([int]$layout.NewLength)
 [Buffer]::BlockCopy($Exe,0,$result,0,$Exe.Length)
 [ACRCustomBytes]::Put($result,[int]$layout.RawOffset,$code)
 foreach($header in $layout.HeaderPatches){[ACRCustomBytes]::Put($result,[int]$header.Offset,[ACRCustomBytes]::Unhex($header.Enabled))}
 foreach($entry in $layout.Entries){
  $active=Test-ACRGameplayFeature $Values $entry.Feature
  if($entry.Feature -eq 'SuspensionAlignmentDegrees'){$active=$active -or (Test-ACRGameplayFeature $Values 'SuspensionCamberDegrees')}
  if($active){[ACRCustomBytes]::Put($result,[int]$entry.Offset,[ACRCustomBytes]::Unhex($entry.Bytes))}
 }
 if((Test-ACRGameplayFeature $Values 'HudDamageWarnings') -and -not (Test-ACRGameplayFeature $Values 'CoolingConsequences')){[ACRCustomBytes]::Put($result,[int]$layout.OperationalFeedback.EntryOffset,[ACRCustomBytes]::Unhex($layout.OperationalFeedback.EntryBytes))}
 if(Test-ACRGameplayFeature $Values 'HudDamageWarnings'){
  $hud=$layout.HudDisplay;$size=[BitConverter]::ToInt32($result,[int]$hud.ExceptionSizeOffset)
  if($size -lt $hud.OriginalExceptionSize -or $size -gt $hud.OriginalExceptionSize+48 -or ($size-$hud.OriginalExceptionSize)%12 -ne 0){throw 'Unexpected existing unwind-table length.'}
  [byte[]]$record=New-Object byte[] 12
  [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]$hud.TickRVA),0,$record,0,4)
  [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]($hud.TickRVA+$hud.TickLength)),0,$record,4,4)
  [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]$hud.UnwindRVA),0,$record,8,4)
  [ACRCustomBytes]::Put($result,([int]$hud.ExceptionTableFileOffset+$size),$record)
  [ACRCustomBytes]::Put($result,[int]$hud.ExceptionSizeOffset,[BitConverter]::GetBytes([uint32]($size+12)))
  $extent=[Math]::Max([BitConverter]::ToUInt32($result,[int]$hud.PdataVirtualSizeOffset),[uint32]($size+12))
  [ACRCustomBytes]::Put($result,[int]$hud.PdataVirtualSizeOffset,[BitConverter]::GetBytes([uint32]$extent))
 }
 return ,$result
}
function Complete-ACRGameplayExecutable([byte[]]$Prefix,$State) {
 if($null -eq $State.PSObject.Properties['gameplay_tail_hex']){return ,$Prefix}
 $layout=Get-ACRGameplayLayout
 if($Prefix.Length -ne $layout.OriginalLength){throw 'Unexpected gameplay prefix length.'}
 [byte[]]$tail=[ACRCustomBytes]::Unhex([string]$State.gameplay_tail_hex)
 if($tail.Length -ne $layout.NewLength-$layout.OriginalLength){throw 'Unexpected gameplay tail length.'}
 [byte[]]$result=New-Object byte[] ([int]$layout.NewLength)
 [Buffer]::BlockCopy($Prefix,0,$result,0,$Prefix.Length)
 [Buffer]::BlockCopy($tail,0,$result,$Prefix.Length,$tail.Length)
 return ,$result
}
function Assert-ACRGameplayRecoveryTail([byte[]]$Current,$Manifest) {
 $layout=Get-ACRGameplayLayout
 if($Current.Length -eq $layout.OriginalLength){return}
 if($Current.Length -ne $layout.NewLength){throw 'Unknown interrupted executable extent.'}
 $allowed=New-Object 'Collections.Generic.List[byte[]]'
 $allowed.Add((New-Object byte[] ([int]($layout.NewLength-$layout.OriginalLength))))
 $seen=New-Object 'Collections.Generic.HashSet[string]'
 $states=New-Object 'Collections.Generic.List[object]'
 if($null -ne $Manifest.runtime_native){foreach($item in $Manifest.native_modules.runtime_custom_states){$states.Add($item)}}else{foreach($item in $Manifest.native_modules.states){$states.Add($item)}}
 foreach($state in $states){
  if($null -ne $state.PSObject.Properties['gameplay_tail_hex'] -and $seen.Add([string]$state.gameplay_tail_hex)){$allowed.Add([ACRCustomBytes]::Unhex([string]$state.gameplay_tail_hex))}
 }
 if($allowed.Count -lt 2 -or $allowed.Count -gt 3){throw 'No bounded gameplay recovery candidates.'}
 for($i=0;$i -lt $allowed[0].Length;$i++){
  $ok=$false;foreach($bytes in $allowed){if($Current[[int]$layout.OriginalLength+$i] -eq $bytes[$i]){$ok=$true;break}}
  if(-not $ok){throw 'Unknown bytes in the interrupted gameplay section. No writes allowed.'}
 }
}
Export-ModuleMember -Function *-ACR*
