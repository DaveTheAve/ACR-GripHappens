# Bounded numeric overrides. Original/preset code is always verified before custom bytes.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ACR.Gameplay.psm1') -ErrorAction Stop
$script:CustomSchemaHash='a92977e450a9141e7c9c296aaeeb22de9fb4d1a7b1309317727c985db57ff85f'
$script:CustomBytesHash='d2ec476b55546df3f6045cae9412d0e4bd0c0ab6b90194d18b1565e8c36501bb'
$script:Schema=$null
function Get-ACRCustomSchema {
 if($null -eq $script:Schema){
  $path=Join-Path (Split-Path $PSScriptRoot) 'custom-tuning.json'
  if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $script:CustomSchemaHash){throw 'Custom tuning schema failed verification.'}
  $script:Schema=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
  if($script:Schema.Schema -ne 1 -or $script:Schema.Fields.Count -ne 23){throw 'Unsupported custom schema.'}
 }
 return $script:Schema
}
function Initialize-ACRCustomBytes {
 if(-not ('ACRCustomBytes' -as [type])){$path=Join-Path (Split-Path $PSScriptRoot) 'tools\ACR_CustomBytes.cs';if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $script:CustomBytesHash){throw 'Custom byte helper source failed verification.'};Add-Type -Path $path}
}
function ConvertTo-ACRCustomMap($Values) {
 Initialize-ACRCustomBytes;$spec=Get-ACRCustomSchema;$out=[ordered]@{}
 if($null -eq $Values){return ,$out}
 $keys=@();if($Values -is [Collections.IDictionary]){$keys=@($Values.Keys)}else{$keys=@($Values.PSObject.Properties | ForEach-Object { $_.Name })}
 if($keys.Count -gt 23){throw 'Too many custom parameters.'}
 foreach($key in $keys){
  $field=@($spec.Fields|Where-Object {$_.Key -ceq [string]$key});if($field.Count -ne 1){throw ('Unknown custom parameter: '+$key)}
  $text=[string]$Values.$key
  if($text.Length -gt 64 -or $text -notmatch '^[+]?[0-9]+(?:\.[0-9]+)?$'){throw ($key+': enter a finite decimal number without separators or exponent notation.')}
  $v=[double]::Parse($text,[Globalization.CultureInfo]::InvariantCulture)
  if([double]::IsNaN($v)-or [double]::IsInfinity($v)-or $v -lt $field[0].Min-or $v -gt $field[0].Max){throw ($key+': outside the supported range.')}
  if($null -ne $field[0].PSObject.Properties['Kind'] -and $field[0].Kind -eq 'Switch' -and $v -notin @(0,1)){throw ($key+': choose enabled or disabled, not a fractional switch.')}
  $out[$key]=[ACRCustomBytes]::Number($v)
 }
 return ,$out
}
function ConvertFrom-ACRCustomBase64([string]$Text) {
 if([string]::IsNullOrEmpty($Text)){return (ConvertTo-ACRCustomMap $null)}
 if($Text.Length -gt 4096){throw 'Custom parameter payload too large.'}
 try {$o=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))|ConvertFrom-Json}catch{throw 'Invalid custom parameter payload.'}
 return (ConvertTo-ACRCustomMap $o)
}
function ConvertTo-ACRCustomBase64($Map){$v=ConvertTo-ACRCustomMap $Map;return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($v|ConvertTo-Json -Compress)))}
function Test-ACRCustomFieldActive($Field,$Native,$Content) {
 if($Field.Mode -eq 'Always'){return $true}
 if($Field.Key -eq 'WearScale'){return [bool]$Content.wear_enabled}
 if($Field.Key -eq 'WetLossScale'){return $true}
 return ([string]$Native.($Field.Mode) -cin $Field.Allowed)
}
function Assert-ACRCustomModes($Map,$Native,$Content) {
 if($Map.Count -gt 0 -and (-not $Native.startup_guard -or -not $Native.http_request_block -or -not $Native.installable)){throw 'Custom tuning requires the supported game-local offline guards.'}
 foreach($f in (Get-ACRCustomSchema).Fields){if($Map.Contains($f.Key) -and -not (Test-ACRCustomFieldActive $f $Native $Content)){throw ($f.Label+': choose an enabled preset for this system before using a custom value.')}}
}
function New-ACRCustomRecord($Map,$Native,$Content) {
 # Self-describing numeric data in audited padding. No code or pointers in this record.
 $spec=Get-ACRCustomSchema;[byte[]]$b=New-Object byte[] 256
 [ACRCustomBytes]::Put($b,0,[Text.Encoding]::ASCII.GetBytes('GRIPHAPPENS-N16!'))
 [ACRCustomBytes]::Put($b,16,[BitConverter]::GetBytes([int]1))
 [ACRCustomBytes]::Put($b,32,[ACRCustomBytes]::Unhex($Native.exe_sha256))
 [ACRCustomBytes]::Put($b,64,[ACRCustomBytes]::Unhex($Content.index_sha256))
 [uint32]$mask=0
 for($i=0;$i -lt $spec.Fields.Count;$i++){
  $k=$spec.Fields[$i].Key
  if($Map.Contains($k)){
   $mask=$mask -bor (1 -shl $i)
   [ACRCustomBytes]::Put($b,(96+4*$i),[BitConverter]::GetBytes([single]::Parse($Map[$k],[Globalization.CultureInfo]::InvariantCulture)))
  }
 }
 [ACRCustomBytes]::Put($b,20,[BitConverter]::GetBytes($mask))
 [ACRCustomBytes]::Put($b,224,[ACRCustomBytes]::Unhex([ACRCustomBytes]::Hash([ACRCustomBytes]::Slice($b,0,224))))
 return ,$b
}
function Get-ACRCustomPatchMap($Manifest) {
 $result=@{};foreach($p in $Manifest.native_modules.patches){$result[[string]$p.name]=$p};return $result
}
function New-ACRBytesAtState([byte[]]$Original,$Patches,[int]$State) {
 [byte[]]$b=$Original.Clone();foreach($p in $Patches){[ACRCustomBytes]::Put($b,[int]$p.offset,[ACRCustomBytes]::Unhex((Get-ACRPatchHex $p $State)))};return ,$b
}
function Read-ACRCustomRecord([byte[]]$Exe,$Manifest) {
 Initialize-ACRCustomBytes;$spec=Get-ACRCustomSchema
 [byte[]]$b=[ACRCustomBytes]::Slice($Exe,[int]$spec.DescriptorOffset,256)
 if([ACRCustomBytes]::Equal($b,(New-Object byte[] 256))){return $null}
 if([Text.Encoding]::ASCII.GetString($b,0,16) -cne 'GRIPHAPPENS-N16!' -or [BitConverter]::ToInt32($b,16) -ne 1){throw 'Unknown custom tuning descriptor. No writes allowed.'}
 $hash=[ACRCustomBytes]::Hash([ACRCustomBytes]::Slice($b,0,224))
 if($hash -cne [ACRCustomBytes]::Hex([ACRCustomBytes]::Slice($b,224,32))){throw 'Damaged custom tuning descriptor. No writes allowed.'}
 $nh=[ACRCustomBytes]::Hex([ACRCustomBytes]::Slice($b,32,32));$ch=[ACRCustomBytes]::Hex([ACRCustomBytes]::Slice($b,64,32))
 $ni=-1;$ci=-1
 $ni=Find-ACRNativeStateHash $Manifest $nh
 for($i=0;$i -lt $Manifest.states.Count;$i++){if($Manifest.states[$i].index_sha256 -ceq $ch){$ci=$i;break}}
 if($ni -lt 0 -or $ci -lt 0){throw 'Custom tuning base is not in the supported catalogue.'}
 $raw=[ordered]@{};$mask=[BitConverter]::ToUInt32($b,20)
 if($mask -eq 0 -or $mask -ge (1 -shl $spec.Fields.Count)){throw 'Invalid custom field mask.'}
 for($i=0;$i -lt $spec.Fields.Count;$i++){if($mask -band (1 -shl $i)){$raw[$spec.Fields[$i].Key]=[ACRCustomBytes]::Number([BitConverter]::ToSingle($b,96+4*$i))}}
 $map=ConvertTo-ACRCustomMap $raw
 Assert-ACRCustomModes $map (Get-ACRNativeState $Manifest $ni) $Manifest.states[$ci]
 if(-not [ACRCustomBytes]::Equal($b,(New-ACRCustomRecord $map (Get-ACRNativeState $Manifest $ni) $Manifest.states[$ci]))){throw 'Noncanonical custom descriptor or unknown reserved bytes.'}
 return [pscustomobject]@{Values=$map;BaseNative=$ni;BaseContent=$ci}
}
function Restore-ACRCustomBuffer([byte[]]$Current,$Patches,[string]$OriginalHash) {
 # Only a validated descriptor selects this path; caller MUST verify the complete
 # rebuilt custom image before accepting it. Arbitrary bytes are never installed.
 if($OriginalHash -ceq '42c359b0cd24774a86441710fdc7d7db3bc06b57b3ff30cb9ea5d56fb71448fb'){
  $layout=Get-ACRGameplayLayout
  if(-not (Test-ACRGameplayExecutableLength $Current.Length)){throw 'Unknown custom executable extent.'}
  if($Current.Length -ne $layout.OriginalLength){$Current=[ACRCustomBytes]::Slice($Current,0,[int]$layout.OriginalLength)}
 }
 $b=New-ACRBytesAtState $Current $Patches 0
 if([ACRCustomBytes]::Hash($b) -cne $OriginalHash){throw 'Unrelated edits remain outside the audited custom ranges.'}
 return ,$b
}
function Add-ACRCustomConfiguration($Manifest,[int]$BaseNative,[int]$BaseContent,$Values,[byte[]]$OriginalExe,[byte[]]$OriginalIndex,$OriginalRegions) {
 Initialize-ACRCustomBytes;$spec=Get-ACRCustomSchema;$map=ConvertTo-ACRCustomMap $Values
 if($map.Count -eq 0){return [pscustomobject]@{NativeIndex=$BaseNative;ContentIndex=$BaseContent;Values=$map}}
 $native=(Get-ACRNativeState $Manifest $BaseNative);$content=$Manifest.states[$BaseContent]
 Assert-ACRCustomModes $map $native $content
 if([ACRCustomBytes]::Hash($OriginalExe) -cne $Manifest.exe.sha256 -or [ACRCustomBytes]::Hash($OriginalIndex) -cne $Manifest.index.original_sha256){throw 'Custom builder requires fully verified originals.'}
 if($OriginalRegions.Count -ne $Manifest.regions.Count){throw 'Custom content originals incomplete.'}
 [byte[]]$exe=New-ACRBytesAtState $OriginalExe $Manifest.native_modules.patches $BaseNative
 $patchMap=Get-ACRCustomPatchMap $Manifest
 foreach($f in $spec.Fields){
  if(-not $map.Contains($f.Key) -or $f.Slots.Count -eq 0){continue}
  $found=0
  foreach($slot in $f.Slots){
   $p=$patchMap[[string]$slot.Patch];[byte[]]$baseline=[ACRCustomBytes]::Unhex((Get-ACRPatchHex $p $BaseNative))
   if([ACRCustomBytes]::Hash($baseline) -cne $slot.BaseSHA256){continue}
   $found++;foreach($o in $slot.Offsets){[ACRCustomBytes]::Put($exe,([int]$p.offset+[int]$o),[BitConverter]::GetBytes([single]::Parse($map[$f.Key],[Globalization.CultureInfo]::InvariantCulture)))}
  }
  if($found -ne 1){throw ('No unique audited numeric location for '+$f.Key)}
 }
 [byte[]]$exe=Add-ACRGameplayBytes $exe $map $native
 [byte[]]$record=New-ACRCustomRecord $map $native $content
 [ACRCustomBytes]::Put($exe,[int]$spec.DescriptorOffset,$record);[ACRCustomBytes]::SetChecksum($exe)
 $nh=[ACRCustomBytes]::Hash($exe)
 [byte[]]$index=$OriginalIndex.Clone();$regionBytes=New-Object 'Collections.Generic.List[byte[]]'
 $regionHashes=New-Object 'Collections.Generic.List[string]';$chunkHashes=New-Object 'Collections.Generic.List[string]'
 for($i=0;$i -lt $Manifest.regions.Count;$i++){
  $r=$Manifest.regions[$i];[byte[]]$original=$OriginalRegions[$i]
  if([ACRCustomBytes]::Hash($original) -cne $r.original_sha256){throw 'Custom builder received an unverified original region.'}
  [byte[]]$b=New-ACRBytesAtState $original $r.patches $BaseContent
  $customKey=$null
  if($i -gt 0 -and $r.module -eq 'TyreWear' -and $map.Contains('WearScale')){$customKey='WearScale'}
  if($r.module -eq 'WetTarmac' -and $map.Contains('WetLossScale')){$customKey='WetLossScale'}
  if($customKey){
   foreach($p in $r.patches){
    if(([string]$p.bytes[0]).Length -ne 8){throw 'Custom asset scalar is not a four-byte value.'}
    $baseValue=[BitConverter]::ToSingle($original,[int]$p.offset)
    $gain=[double]::Parse($map[$customKey],[Globalization.CultureInfo]::InvariantCulture)
    [ACRCustomBytes]::Put($b,[int]$p.offset,[BitConverter]::GetBytes([single]([double]$baseValue*$gain)))
   }
  }
  $regionBytes.Add($b);$regionHashes.Add([ACRCustomBytes]::Hash($b));$chunk=[ACRCustomBytes]::Blake160($b);$chunkHashes.Add($chunk)
  [ACRCustomBytes]::Put($index,[int]$r.index_hash_offset,[ACRCustomBytes]::Unhex($chunk))
 }
 $ch=[ACRCustomBytes]::Hash($index);$ni=-1;$ci=-1
 $ni=Find-ACRNativeStateHash $Manifest $nh
 for($i=0;$i -lt $Manifest.states.Count;$i++){if($Manifest.states[$i].index_sha256 -ceq $ch){$ci=$i;break}}
 $tag=([ACRCustomBytes]::Hash($record)).Substring(0,16)
 if($ni -lt 0){
  $n=$native|ConvertTo-Json -Depth 8|ConvertFrom-Json
  $n.id+=';Custom='+$tag;$n.exe_sha256=$nh
  $n|Add-Member NoteProperty custom_values $map -Force
  $n|Add-Member NoteProperty custom_executable_length $exe.Length -Force
  if($exe.Length -ne $OriginalExe.Length){$n|Add-Member NoteProperty gameplay_tail_hex ([ACRCustomBytes]::Hex([ACRCustomBytes]::Slice($exe,$OriginalExe.Length,($exe.Length-$OriginalExe.Length)))) -Force}
  $meta=@{VisualScale='visual_multiplier';CollisionScale='collision_multiplier';EngineImpactFactor='engine_collision_factor';GearboxImpactFraction='gearbox_impact_fraction';GearboxGrindingRate='gearbox_grinding_rate_override'}
  foreach($k in $meta.Keys){if($map.Contains($k)){$n.($meta[$k])=[double]::Parse($map[$k],[Globalization.CultureInfo]::InvariantCulture)}}
  $ni=Add-ACRNativeCustomState $Manifest $n
  foreach($p in $Manifest.native_modules.patches){$len=(Get-ACRPatchHex $p 0).Length/2;Add-ACRNativeCustomPatchHex $p ([ACRCustomBytes]::Hex([ACRCustomBytes]::Slice($exe,[int]$p.offset,[int]$len)))}
 }
 if($ci -lt 0){
  $ci=$Manifest.states.Count;$c=$content|ConvertTo-Json -Depth 8|ConvertFrom-Json
  $c.id+=';Custom='+$tag;$c.index_sha256=$ch;$c.label+=' (custom numeric tuning)'
  $Manifest.states+=@($c)
  foreach($p in $Manifest.index.patches){$len=([string]$p.bytes[0]).Length/2;$p.bytes+=@([ACRCustomBytes]::Hex([ACRCustomBytes]::Slice($index,[int]$p.offset,[int]$len)))}
  for($i=0;$i -lt $Manifest.regions.Count;$i++){
   $r=$Manifest.regions[$i];$r.sha256_by_state+=@($regionHashes[$i]);$r.blake3_160_by_state+=@($chunkHashes[$i])
   foreach($p in $r.patches){$len=([string]$p.bytes[0]).Length/2;$p.bytes+=@([ACRCustomBytes]::Hex([ACRCustomBytes]::Slice($regionBytes[$i],[int]$p.offset,[int]$len)))}
  }
 }
 return [pscustomobject]@{NativeIndex=$ni;ContentIndex=$ci;Values=$map;BaseNative=$BaseNative;BaseContent=$BaseContent;ExecutableSHA256=$nh;IndexSHA256=$ch}
}
function Add-ACRExistingCustomState($Manifest,[byte[]]$CurrentExe,[string]$GameRoot) {
 $d=Read-ACRCustomRecord $CurrentExe $Manifest;if($null -eq $d){return $null}
 [byte[]]$originalExe=Restore-ACRCustomBuffer $CurrentExe $Manifest.native_modules.patches $Manifest.exe.sha256
 $indexPath=Join-Path $GameRoot $Manifest.index.relative_path;$dataPath=Join-Path $GameRoot $Manifest.ucas.relative_path
 if((Get-Item -LiteralPath $indexPath).Length -ne $Manifest.index.length){throw 'Custom index length mismatch.'}
 [byte[]]$currentIndex=[IO.File]::ReadAllBytes($indexPath)
 [byte[]]$originalIndex=Restore-ACRCustomBuffer $currentIndex $Manifest.index.patches $Manifest.index.original_sha256
 $originals=New-Object 'Collections.Generic.List[byte[]]';$currentHashes=New-Object 'Collections.Generic.List[string]'
 $stream=[IO.File]::Open($dataPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try {
  if($stream.Length -ne [long]$Manifest.ucas.length -or $currentIndex.Length -ne $Manifest.index.length){throw 'Custom content file length mismatch.'}
  foreach($r in $Manifest.regions){
   [byte[]]$b=New-Object byte[] $r.length;$stream.Position=[long]$r.offset;$got=0
   while($got -lt $b.Length){$n=$stream.Read($b,$got,$b.Length-$got);if($n -le 0){throw 'Incomplete custom content read.'};$got+=$n}
   $currentHashes.Add([ACRCustomBytes]::Hash($b));$originals.Add((Restore-ACRCustomBuffer $b $r.patches $r.original_sha256))
  }
 }finally{$stream.Dispose()}
 $state=Add-ACRCustomConfiguration $Manifest $d.BaseNative $d.BaseContent $d.Values $originalExe $originalIndex $originals
 if([ACRCustomBytes]::Hash($CurrentExe) -cne $state.ExecutableSHA256 -or [ACRCustomBytes]::Hash($currentIndex) -cne $state.IndexSHA256){throw 'Custom file differs from the complete reconstructed, audited configuration. No writes allowed.'}
 for($i=0;$i -lt $Manifest.regions.Count;$i++){if($currentHashes[$i] -cne $Manifest.regions[$i].sha256_by_state[$state.ContentIndex]){throw ('Custom content mismatch: '+$Manifest.regions[$i].name)}}
 $state|Add-Member NoteProperty VerifiedOriginalExe $originalExe
 return $state
}
function Get-ACRCustomValuesFromState($State){if($null -ne $State.PSObject.Properties['custom_values']){return (ConvertTo-ACRCustomMap $State.custom_values)};return (ConvertTo-ACRCustomMap $null)}
function Get-ACRCustomValuesFromSettings($Settings){if($null -ne $Settings -and $null -ne $Settings.PSObject.Properties['CustomValues']){return (ConvertTo-ACRCustomMap $Settings.CustomValues)};return (ConvertTo-ACRCustomMap $null)}
function Get-ACRCustomSummary($Map){$v=ConvertTo-ACRCustomMap $Map;$lines=@();foreach($f in (Get-ACRCustomSchema).Fields){if($v.Contains($f.Key)){$lines+=($f.Label+': '+$v[$f.Key]+' '+$f.Unit)}};return ($lines -join "`n")}
Export-ModuleMember -Function *-ACR*
function Add-ACRCustomRecoveryCandidates($Manifest,[string]$StateRoot,[string]$JournalPath) {
 # A verified original backup plus exact, bounded journal candidates permits the
 # existing per-byte interrupted-write restorer. The journal never supplies code.
 if(-not [IO.File]::Exists($JournalPath)){throw 'No interrupted custom-write journal exists.'}
 if((Get-Item -LiteralPath $JournalPath).Length -gt 65536){throw 'Recovery journal too large.'}
 $journal=Get-Content -LiteralPath $JournalPath -Raw|ConvertFrom-Json
 if($null -eq $journal.PSObject.Properties['CustomCandidates']){throw 'No custom recovery candidates in this journal.'}
 $candidates=@($journal.CustomCandidates);if($candidates.Count -lt 1 -or $candidates.Count -gt 2){throw 'Invalid custom recovery candidate count.'}
 Initialize-ACRCustomBytes
 $exe=[IO.File]::ReadAllBytes((Join-Path $StateRoot 'original-acr.exe'))
 $index=[IO.File]::ReadAllBytes((Join-Path $StateRoot 'original-pakchunk1.utoc'))
 $blob=[IO.File]::ReadAllBytes((Join-Path $StateRoot 'original-regions.bin'))
 if([ACRCustomBytes]::Hash($blob) -cne $Manifest.backup.regions_sha256){throw 'Custom recovery content backup failed verification.'}
 $originals=New-Object 'Collections.Generic.List[byte[]]';$offset=0
 foreach($r in $Manifest.regions){$originals.Add([ACRCustomBytes]::Slice($blob,$offset,[int]$r.length));$offset+=$r.length}
 foreach($candidate in $candidates){
  $ni=[int]$candidate.BaseNative;$ci=[int]$candidate.BaseContent
  if($ni -lt 0 -or $ni -ge (Get-ACRNativeStateCount $Manifest) -or $ci -lt 0 -or $ci -ge 91){throw 'Recovery candidate is not based on a published preset.'}
  if((Get-ACRNativeState $Manifest $ni).exe_sha256 -cne $candidate.BaseNativeHash -or $Manifest.states[$ci].index_sha256 -cne $candidate.BaseContentHash){throw 'Recovery candidate base fingerprint changed.'}
  $state=Add-ACRCustomConfiguration $Manifest $ni $ci $candidate.Values $exe $index $originals
 }
}
function Get-ACRCustomJournalCandidate($CustomState,$Manifest) {
 if($null -eq $CustomState -or $CustomState.Values.Count -eq 0){return}
 return [pscustomobject]@{BaseNative=$CustomState.BaseNative;BaseContent=$CustomState.BaseContent;BaseNativeHash=(Get-ACRNativeState $Manifest $CustomState.BaseNative).exe_sha256;BaseContentHash=$Manifest.states[$CustomState.BaseContent].index_sha256;Values=$CustomState.Values}
}
Export-ModuleMember -Function *-ACR*
