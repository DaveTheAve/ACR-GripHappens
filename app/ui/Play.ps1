Import-Module (Join-Path $PSScriptRoot '..\modules\ACR.Play.psm1') -ErrorAction Stop
# Play is intentionally separate from Apply and from the read-only driving recorder.
$script:PlayWaiting=$false;$script:PlayDeadline=[DateTime]::MinValue
$script:PlayTimer=$null;$script:PlaySawGame=$false
function Update-DesktopPlayButton {
 if($null -eq $script:UI -or -not $script:UI.ContainsKey('PlayButton')){return}
 $running=Get-ACRPlayProcessRunning
 if($running){
  $wasWaiting=$script:PlayWaiting;$script:PlayWaiting=$false;$script:PlaySawGame=$true
  if($wasWaiting){Set-DesktopBusy $false;Set-DesktopStatus 'ACR is running. Your installed setup is unchanged.'}
  $script:UI.PlayButton.IsEnabled=$false;$script:UI.PlayButtonLabel.Text='ACR is running'
  $script:UI.PlayButton.ToolTip='ACR is running. Snapshot and recording remain available in Advanced.'
  return
 }
 if($script:PlaySawGame){$script:PlaySawGame=$false;if(-not $script:Busy){Set-DesktopStatus 'ACR closed. Your installed setup is unchanged.'}}
 if($script:PlayWaiting -and [DateTime]::UtcNow -ge $script:PlayDeadline){
  $script:PlayWaiting=$false;Set-DesktopBusy $false
  if(-not $script:Busy){Set-DesktopStatus 'No ACR process detected yet. Check Steam for a prompt or a launch error.'}
 }
 $script:UI.PlayButton.IsEnabled=(-not $script:Busy -and -not $script:PlayWaiting -and -not [string]::IsNullOrWhiteSpace($script:GameRoot))
 $checking=$script:Busy -and $null -ne $script:Task -and $null -ne $script:Task.PSObject.Properties['PlayAfterCheck'] -and $script:Task.PlayAfterCheck
 $script:UI.PlayButtonLabel.Text=if($script:PlayWaiting){'Starting ACR...'}elseif($checking){'Checking files...'}else{'Play ACR'}
 $script:UI.PlayButton.ToolTip='Check the installed files, then launch ACR through Steam in Offline Mode. Pending choices are never applied by Play.'
}
function Request-DesktopPlay {
 if($script:Busy -or $script:PlayWaiting){return}
 try {
  $null=Get-ACRPlayContext $script:GameRoot
  if($script:ChoicesDirty -and -not (Confirm-Desktop 'Play uses your currently installed setup. The pending choices in this window will remain unapplied. Continue without applying them?' 'Play installed setup?')){return}
  Start-DesktopTask 'Check' $null $false $false $true
  Update-DesktopPlayButton
 }catch{Set-DesktopStatus 'ACR was not launched.';Show-DesktopMessage $_.Exception.Message 'Play ACR'}
}
function Complete-DesktopPlay($Task,$Core) {
 if($null -eq $Task -or $Task.Action -ne 'Check' -or $null -eq $Task.PSObject.Properties['PlayAfterCheck'] -or -not $Task.PlayAfterCheck){return}
 try {
  $null=Invoke-ACRVerifiedPlay $Core $script:GameRoot
  $script:PlayWaiting=$true;$script:PlayDeadline=[DateTime]::UtcNow.AddSeconds(45)
  Set-DesktopStatus 'Launch requested through Steam. Waiting for ACR...'
 }catch{Set-DesktopStatus 'ACR was not launched. Your installed settings were not changed.';Show-DesktopMessage $_.Exception.Message 'Play ACR'}
}
function Initialize-DesktopPlay {
 $script:UI.PlayButton.Add_Click({Request-DesktopPlay})
 $script:PlayTimer=New-Object Windows.Threading.DispatcherTimer
 $script:PlayTimer.Interval=[TimeSpan]::FromSeconds(1)
 $script:PlayTimer.Add_Tick({try{Update-DesktopPlayButton}catch{$script:UI.PlayButton.IsEnabled=$false;$script:UI.PlayButton.ToolTip='Play state could not be read. Reopen Grip Happens to retry.'}})
 $script:PlayTimer.Start()
 Update-DesktopPlayButton
}
