# Reset is scoped to one take in one desktop task. No game calls, patches or process termination.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ACR.Common.psm1') -ErrorAction Stop
function Get-ACRRecordingRoot([string]$TaskDirectory,[string]$TakeId) {
 if($TakeId -cnotmatch '^[a-f0-9]{32}$'){throw 'Invalid recording take identity.'}
 $task=[IO.Path]::GetFullPath($TaskDirectory).TrimEnd('\')
 $id=[IO.Path]::GetFileName($task)
 if($id -cnotmatch '^[a-f0-9]{32}$'){throw 'Invalid recording task identity.'}
 $expected=Join-Path (Join-Path (Get-ACRUserStateRoot) 'DesktopTasks') $id
 if(-not [String]::Equals($task,$expected,[StringComparison]::OrdinalIgnoreCase)){throw 'Recording directory is outside its own desktop task.'}
 Assert-ACRNoReparse $task
 $parent=Join-Path $task 'recordings';if([IO.Directory]::Exists($parent)){Assert-ACRNoReparse $parent}
 $takeRoot=Join-Path $parent ('take-'+$TakeId);if([IO.Directory]::Exists($takeRoot)){Assert-ACRNoReparse $takeRoot}
 return $takeRoot
}
function Get-ACRRecordingReceipt([string]$TaskDirectory) {
 $path=Join-Path $TaskDirectory 'recording-last.json'
 if(-not [IO.File]::Exists($path)){return $null}
 Assert-ACRNoReparse $path
 if((Get-Item -LiteralPath $path).Length -gt 8192){throw 'Unexpected recording receipt size.'}
 $r=[IO.File]::ReadAllText($path)|ConvertFrom-Json
 foreach($k in @('Schema','TaskId','TakeId','State','Files')){if($null -eq $r.PSObject.Properties[$k]){throw 'Incomplete recording receipt.'}}
 if($r.Schema -ne 1 -or $r.TaskId -cne [IO.Path]::GetFileName($TaskDirectory.TrimEnd('\'))){throw 'Recording receipt belongs to another task.'}
 $null=Get-ACRRecordingRoot $TaskDirectory $r.TakeId
 return $r
}
function Test-ACRRecordingReset([string]$TaskDirectory,[string]$TakeId) {
 $null=Get-ACRRecordingRoot $TaskDirectory $TakeId;$path=Join-Path $TaskDirectory 'reset-recording.request'
 if(-not [IO.File]::Exists($path)){return $false}
 Assert-ACRNoReparse $path
 if((Get-Item -LiteralPath $path).Length -gt 1024){throw 'Invalid reset request size.'}
 $r=[IO.File]::ReadAllText($path)|ConvertFrom-Json
 return ($r.Schema -eq 1 -and $r.TaskId -ceq [IO.Path]::GetFileName($TaskDirectory.TrimEnd('\')) -and $r.TakeId -ceq $TakeId)
}
function Request-ACRRecordingReset([string]$TaskDirectory,[string]$TakeId) {
 $receipt=Get-ACRRecordingReceipt $TaskDirectory
 if($null -eq $receipt -or $receipt.TakeId -cne $TakeId -or $receipt.State -eq 'Discarded'){throw 'This recording is no longer the current take.'}
 Save-ACRJson (Join-Path $TaskDirectory 'reset-recording.request') ([ordered]@{Schema=1;TaskId=$receipt.TaskId;TakeId=$TakeId})
}
function Get-ACRRecordingExportPath([string]$Name,[string]$TakeId) {
 if($TakeId -cnotmatch '^[a-f0-9]{32}$'){throw 'Invalid recording take identity.'}
 $pattern='\AGrip_Happens_(?:DamageState_DrivingTrace_[0-9]{8}_[0-9]{6}_'+[regex]::Escape($TakeId)+'\.zip|Recording_Error_'+[regex]::Escape($TakeId)+'\.txt)\z'
 if(-not [regex]::IsMatch($Name,$pattern,[Text.RegularExpressions.RegexOptions]::CultureInvariant)){throw 'Recording output name is not bound to this take.'}
 return (Join-Path (Get-ACRDownloads) $Name)
}
function Remove-ACRRecordingTake([string]$TaskDirectory,[string]$TakeId) {
 $root=Get-ACRRecordingRoot $TaskDirectory $TakeId;$r=Get-ACRRecordingReceipt $TaskDirectory
 if($null -eq $r -or $r.TakeId -cne $TakeId){throw 'Cannot clear a foreign or superseded recording.'}
 if($r.State -eq 'Discarded'){return}
 $files=New-Object 'Collections.Generic.List[string]';$dirs=New-Object 'Collections.Generic.List[string]'
 if([IO.Directory]::Exists($root)){
  Assert-ACRNoReparse $root
  foreach($entry in @(Get-ChildItem -LiteralPath $root -Force)){
   Assert-ACRNoReparse $entry.FullName
   if($entry.PSIsContainer){
    if($entry.Name -cne 'data'){throw 'Unexpected directory inside recording; reset refused.'}
    foreach($f in @(Get-ChildItem -LiteralPath $entry.FullName -Force)){
     Assert-ACRNoReparse $f.FullName
     if($f.PSIsContainer){throw 'Nested recording data directory refused.'};$files.Add($f.FullName)
    };$dirs.Add($entry.FullName)
   }else{$files.Add($entry.FullName)}
  }
 }
 # Check all exported files before deleting anything. A changed ZIP is left alone.
 if(@($r.Files).Count -gt 2){throw 'Too many recording outputs in receipt.'}
 foreach($f in @($r.Files)){
  if($f.SHA256 -cnotmatch '^[a-f0-9]{64}$' -or [long]$f.Length -lt 0){throw 'Invalid recording artifact fingerprint.'}
  $path=Get-ACRRecordingExportPath $f.Name $TakeId
  if([IO.File]::Exists($path)){
   Assert-ACRNoReparse $path
   if((Get-Item -LiteralPath $path).Length -ne [long]$f.Length -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $f.SHA256){throw 'The exported recording was changed outside Grip Happens. Reset did not delete it.'}
   $files.Add($path)
  }
 }
 foreach($p in $files){Assert-ACRNoReparse $p;[IO.File]::Delete($p)}
 foreach($p in $dirs){Assert-ACRNoReparse $p;[IO.Directory]::Delete($p,$false)}
 if([IO.Directory]::Exists($root)){Assert-ACRNoReparse $root;[IO.Directory]::Delete($root,$false)}
 $r.State='Discarded';$r.Files=@();Save-ACRJson (Join-Path $TaskDirectory 'recording-last.json') $r
}
function Publish-ACRRecordingTake([string]$TaskDirectory,[string]$TakeId,[bool]$Success) {
 $root=Get-ACRRecordingRoot $TaskDirectory $TakeId;$r=Get-ACRRecordingReceipt $TaskDirectory
 if($r.TakeId -cne $TakeId){throw 'Current recording identity changed before publication.'}
 $outputs=New-Object 'Collections.Generic.List[string]';$exports=New-Object 'Collections.Generic.List[object]'
 $items=@(if($Success){Get-ChildItem -LiteralPath $root -File -Filter '*.zip'}else{Get-ChildItem -LiteralPath $root -File -Filter '*.txt'})
 if($Success -and $items.Count -ne 1){throw 'Recording did not create exactly one ZIP.'}
 if(-not $Success -and $items.Count -gt 1){throw 'Ambiguous recording error reports.'}
 foreach($f in $items){
  Assert-ACRNoReparse $f.FullName
  $name=if($Success){$f.Name}else{'Grip_Happens_Recording_Error_'+$TakeId+'.txt'}
  $dest=Get-ACRRecordingExportPath $name $TakeId
  [IO.Directory]::CreateDirectory((Get-ACRDownloads))|Out-Null;Assert-ACRNoReparse (Get-ACRDownloads)
  if([IO.File]::Exists($dest)){throw 'Recording output already exists; refusing to overwrite.'}
  $exports.Add([pscustomobject]@{Name=$name;Length=$f.Length;SHA256=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()})
  $r.Files=$exports.ToArray();$r.State='Publishing';Save-ACRJson (Join-Path $TaskDirectory 'recording-last.json') $r
  [IO.Directory]::CreateDirectory((Get-ACRDownloads))|Out-Null
  [IO.File]::Copy($f.FullName,$dest,$false);$outputs.Add($dest)
 }
 $r.State=if($Success){'Saved'}else{'Failed'};Save-ACRJson (Join-Path $TaskDirectory 'recording-last.json') $r
 return ,$outputs.ToArray()
}
function Invoke-ACRRecordingLoop([string]$TaskDirectory,[scriptblock]$Capture,[scriptblock]$Status) {
 $resets=0
 while($true){
  $take=[Guid]::NewGuid().ToString('N');$root=Get-ACRRecordingRoot $TaskDirectory $take
  [IO.Directory]::CreateDirectory($root)|Out-Null
  $receipt=[ordered]@{Schema=1;TaskId=[IO.Path]::GetFileName($TaskDirectory.TrimEnd('\'));TakeId=$take;State='Preparing';Files=@()}
  Save-ACRJson (Join-Path $TaskDirectory 'recording-last.json') $receipt
  & $Status $take 'Preparing a fresh recording. Keep ACR paused in the loaded stage.'
  $captured=& $Capture $root $take
  if($null -eq $captured -or $null -eq $captured.PSObject.Properties['ExitCode']){throw 'Recording capture did not return its completion state.'}
  $reset=Test-ACRRecordingReset $TaskDirectory $take
  if(-not $reset){
   $ok=($captured.ExitCode -eq 0 -and $captured.ErrorCount -eq 0)
   $outputs=Publish-ACRRecordingTake $TaskDirectory $take $ok
   # Covers Reset clicked during ZIP packing/copying; discarded exports do not accumulate.
   $reset=Test-ACRRecordingReset $TaskDirectory $take
   if(-not $reset){return [pscustomobject]@{Success=$ok;OutputFiles=$outputs;TakeId=$take;Resets=$resets;ExitCode=$captured.ExitCode}}
  }
  Remove-ACRRecordingTake $TaskDirectory $take
  foreach($name in @('reset-recording.request','stop-recording.request')){$p=Join-Path $TaskDirectory $name;if([IO.File]::Exists($p)){Assert-ACRNoReparse $p;[IO.File]::Delete($p)}}
  $resets++; & $Status $take 'Recording discarded. Preparing a fresh snapshot and countdown...'
 }
}
Export-ModuleMember -Function *-ACRRecording*

function Get-ACRRecordingCompletion([string]$TaskDirectory,[string]$TakeId) {
 try {
  $root=Get-ACRRecordingRoot $TaskDirectory $TakeId
  $files=@(Get-ChildItem -LiteralPath $root -File -Filter '*.zip')
  if($files.Count -ne 1){throw 'No unique recording ZIP.'}
  $null=Get-ACRRecordingExportPath $files[0].Name $TakeId;Assert-ACRNoReparse $files[0].FullName
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip=[IO.Compression.ZipFile]::OpenRead($files[0].FullName);$reader=$null
  try {
   $entries=@($zip.Entries|Where-Object {$_.FullName -ceq 'driving-trace-summary.json'})
   if($entries.Count -ne 1 -or $entries[0].Length -lt 2 -or $entries[0].Length -gt 65536){throw 'Unexpected recording summary extent.'}
   $reader=New-Object IO.StreamReader($entries[0].Open());$buffer=New-Object char[] 65537;$n=$reader.ReadBlock($buffer,0,$buffer.Length)
   if($n -gt 65536){throw 'Recording summary exceeds its limit.'}
   $s=(-join $buffer[0..($n-1)])|ConvertFrom-Json
   foreach($key in @('Samples','Complete','StoppedByUser','StopReason')){if($null -eq $s.PSObject.Properties[$key]){throw 'Missing recording summary field.'}}
   if($s.Samples -isnot [int] -and $s.Samples -isnot [long]){throw 'Sample count is not an integer.'}
   if($s.Samples -lt 0 -or $s.Samples -gt 18000 -or $s.Complete -isnot [bool] -or $s.StoppedByUser -isnot [bool] -or $s.StopReason -isnot [string] -or $s.StopReason.Length -gt 4000){throw 'Invalid recording summary.'}
   $state=if($s.Complete){'Complete'}elseif($s.StoppedByUser){'StoppedByUser'}else{'Partial'}
   return [pscustomobject]@{Status=$state;Samples=[int]$s.Samples;Complete=$s.Complete;StopReason=[string]$s.StopReason}
  }finally{if($null -ne $reader){$reader.Dispose()};$zip.Dispose()}
 }catch{return [pscustomobject]@{Status='SummaryUnavailable';Samples=$null;Complete=$false;StopReason=$_.Exception.Message}}
}
Export-ModuleMember -Function *-ACRRecording*
