# Per-window current/last take only. Reset never searches or deletes older recordings.
$script:LastRecordingTask=$null
function Update-DesktopRecordingButtons {
 if(-not $script:UI.ContainsKey('ResetRecordingButton')){return}
 $active=($script:Busy -and $null -ne $script:Task -and $script:Task.Action -eq 'DriveTrace')
 $last=($null -ne $script:LastRecordingTask -and -not $script:Busy -and $script:LastRecordingTask.GameRoot -ceq $script:GameRoot)
 $script:UI.ResetRecordingButton.Visibility=if($active -or $last){'Visible'}else{'Collapsed'}
 $script:UI.ApplyButton.Visibility=if($active){'Collapsed'}else{'Visible'}
 $script:UI.ResetRecordingButton.Content=if($active){'Reset recording'}else{'Reset last recording'}
 $script:UI.ResetRecordingButton.IsEnabled=($active -or $last)
 if($active){
  $pending=($null -ne $script:Task.PSObject.Properties['ResetPendingTakeId'] -and [bool]$script:Task.ResetPendingTakeId)
  if($pending){$script:UI.ResetRecordingButton.Content='Resetting...';$script:UI.ResetRecordingButton.IsEnabled=$false;$script:UI.StopRecordingButton.IsEnabled=$false}
 }
}
function Start-DesktopRecordingAgain($Previous) {
 if($script:GameRoot -cne $Previous.GameRoot){throw 'The selected game folder changed. Start a new recording explicitly.'}
 $script:LastRecordingTask=$null
 Start-DesktopTask 'DriveTrace' $Previous.ExpectedSettings $true $false $false
}
function Reset-DesktopRecording {
 try {
  if($script:Busy){
   if($null -eq $script:Task -or $script:Task.Action -ne 'DriveTrace'){return}
   if($script:Task.ResetPendingTakeId){return}
   $r=Get-ACRRecordingReceipt $script:Task.Directory
   if($null -eq $r){Set-DesktopStatus 'Recording is still starting; Reset will be ready shortly.';return}
   Request-ACRRecordingReset $script:Task.Directory $r.TakeId
   $script:Task.ResetPendingTakeId=$r.TakeId
   Set-DesktopStatus 'Discarding this take. Keep the restarted car paused; a fresh snapshot and countdown will follow.'
  } else {
   $last=$script:LastRecordingTask
   if($null -eq $last -or $last.GameRoot -cne $script:GameRoot){return}
   Remove-ACRRecordingTake $last.Directory $last.TakeId
   $script:LastOutput='';$script:UI.ShowOutputButton.IsEnabled=$false;$script:UI.OutputText.Text='Last recording discarded. Earlier recordings are untouched.'
   Start-DesktopRecordingAgain $last
  }
 } catch {Show-DesktopMessage ('Recording could not be reset: '+$_.Exception.Message) 'Reset recording'}
 finally {Update-DesktopRecordingButtons}
}
function Update-DesktopRecordingProgress($Task,$Progress) {
 if($Task.Action -ne 'DriveTrace' -or $null -eq $Progress.PSObject.Properties['RecordingTakeId']){return}
 $id=[string]$Progress.RecordingTakeId
 if($id -cnotmatch '^[a-f0-9]{32}$'){return}
 if($Task.TakeId -cne $id){
  $Task.TakeId=$id;$Task.Started=[DateTime]::UtcNow
  if($Task.ResetPendingTakeId -and $Task.ResetPendingTakeId -cne $id){$Task.ResetPendingTakeId='';$script:UI.StopRecordingButton.IsEnabled=$true;$script:UI.StopRecordingButton.Content='Stop & save recording'}
 }
 Update-DesktopRecordingButtons
}
function Complete-DesktopRecordingReset($Task) {
 if($Task.Action -ne 'DriveTrace'){return $false}
 $r=Get-ACRRecordingReceipt $Task.Directory
 if($null -eq $r){return $false}
 $Task.TakeId=$r.TakeId;$script:LastRecordingTask=$Task
 if($Task.ResetPendingTakeId -and $Task.ResetPendingTakeId -ceq $r.TakeId){
  Remove-ACRRecordingTake $Task.Directory $r.TakeId;$Task.RestartAfterExit=$true
  $script:LastOutput='';$script:UI.OutputText.Text='Recording discarded. Starting a fresh capture.';$script:UI.ShowOutputButton.IsEnabled=$false
  return $true
 }
 $Task.ResetPendingTakeId='';return $false
}
