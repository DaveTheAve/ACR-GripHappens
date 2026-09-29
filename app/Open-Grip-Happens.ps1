#Requires -Version 5.1
<# Windows-only WPF interface. Optional native-system tuning; no system-network controls.
Every long operation runs in a separate PowerShell process; the dispatcher only
polls progress/results. Elevated workers are requested only for writes/snapshot.
Play ACR submits a fixed Steam launch request from the non-elevated UI, after a fresh read-only Check. Never launch from an elevated worker. #>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$script:Window=$null;$script:Task=$null;$script:LastTaskDirectory='';$script:LastOutput=''
$script:GameRoot='';$script:Busy=$false;$script:ChoicesDirty=$false;$script:UpdatingChoices=$false
$script:UI=@{};$script:Timer=$null;$script:Initialised=$false
function Show-DesktopMessage([string]$Text,[string]$Title='Grip Happens') {
 if($null -ne $script:Window) {[void](Show-ACRDarkPrompt $script:Window $Text $Title)}
 else {[void][Windows.MessageBox]::Show($Text,$Title)}
}
function Confirm-Desktop([string]$Text,[string]$Title) {
 return (Show-ACRDarkPrompt $script:Window $Text $Title -Confirm)
}
function Set-DesktopStatus([string]$Text) {$script:UI.StatusText.Text=$Text}
function Set-DesktopBusy([bool]$Busy) {
 $Busy=$Busy -or $script:PlayWaiting
 $script:Busy=$Busy
 foreach($n in @('PlayButton','BrowseButton','DetectButton','RecommendedButton','ApplyButton','RestoreButton','OpenBackupsButton','ResetChoicesButton','TyresOnlyButton','CheckButton','SupportButton','SnapshotButton','DrivingTraceButton','WearChoice','WetChoice','VisualChoice','CollisionChoice','TyreDamageChoice','FailuresChoice','BrakeChoice','DetachChoice','CriticalChoice','CoolingChoice','EngineChoice','PowerChoice','WheelImpactChoice','GearboxChoice')) {$script:UI[$n].IsEnabled=(-not $Busy)}
 if($Busy) {$script:UI.TaskProgress.Visibility='Visible'} else {$script:UI.TaskProgress.Visibility='Collapsed'}
 foreach($key in @($script:UI.Keys)){if(($key.StartsWith('Tune_') -or $key.StartsWith('Reset_')) -or $key -in @('UndoChoicesButton','StockChoicesButton')){$script:UI[$key].IsEnabled=(-not $Busy)}} $script:UI.StopRecordingButton.Visibility=if($Busy -and $null -ne $script:Task -and $script:Task.Action -eq 'DriveTrace'){'Visible'}else{'Collapsed'} Update-DesktopRecordingButtons
 # Navigation remains available. Buttons never allow parallel game operations.
 if(-not $Busy -and -not $script:GameRoot) {
  foreach($n in @('PlayButton','RecommendedButton','ApplyButton','CheckButton','SnapshotButton','DrivingTraceButton')) {$script:UI[$n].IsEnabled=$false}
 }
}
function Read-DesktopChoices {
 $s=[pscustomobject]@{RateScale=[string]$script:UI.WearChoice.SelectedValue;WetTarmac=[string]$script:UI.WetChoice.SelectedValue;VisualDamage=[string]$script:UI.VisualChoice.SelectedValue;CollisionDamage=[string]$script:UI.CollisionChoice.SelectedValue;TyreDamage=[string]$script:UI.TyreDamageChoice.SelectedValue;MechanicalFailures=[string]$script:UI.FailuresChoice.SelectedValue;BrakeWear=[string]$script:UI.BrakeChoice.SelectedValue;Detachment=[string]$script:UI.DetachChoice.SelectedValue;CriticalDamage=[string]$script:UI.CriticalChoice.SelectedValue;CoolingRouting=[string]$script:UI.CoolingChoice.SelectedValue;EngineImpact=[string]$script:UI.EngineChoice.SelectedValue;PowerResponse=[string]$script:UI.PowerChoice.SelectedValue;WheelImpact=[string]$script:UI.WheelImpactChoice.SelectedValue;GearboxDamage=[string]$script:UI.GearboxChoice.SelectedValue}
 if(-not (Test-ACRDesktopSettings $s)) {throw 'Choose a valid setting in each of the settings lists.'}
 if($script:CustomValues.Count){$s|Add-Member NoteProperty CustomValues (ConvertTo-ACRCustomMap $script:CustomValues)}
 return $s
}
function Update-ExactSettings {Update-Workspace}
function Set-DesktopChoices($Settings,[string]$Origin) {
 if(-not (Test-ACRDesktopSettings $Settings)) {return}
 $script:CustomValues=Get-ACRCustomValuesFromSettings $Settings
 $script:UpdatingChoices=$true
 try {
  $script:UI.WearChoice.SelectedValue=$Settings.RateScale;$script:UI.WetChoice.SelectedValue=$Settings.WetTarmac
  $script:UI.VisualChoice.SelectedValue=$Settings.VisualDamage;$script:UI.CollisionChoice.SelectedValue=$Settings.CollisionDamage
  $script:UI.TyreDamageChoice.SelectedValue=$Settings.TyreDamage
  $script:UI.FailuresChoice.SelectedValue=$Settings.MechanicalFailures
  $script:UI.BrakeChoice.SelectedValue=$Settings.BrakeWear
  $script:UI.DetachChoice.SelectedValue=$Settings.Detachment
  $script:UI.CriticalChoice.SelectedValue=$Settings.CriticalDamage
  $script:UI.CoolingChoice.SelectedValue=$Settings.CoolingRouting
  $script:UI.EngineChoice.SelectedValue=$Settings.EngineImpact
  $script:UI.PowerChoice.SelectedValue=$Settings.PowerResponse
  $script:UI.WheelImpactChoice.SelectedValue=$Settings.WheelImpact
  $script:UI.GearboxChoice.SelectedValue=$Settings.GearboxDamage
  $script:ChoicesDirty=$false;$script:UI.SettingsOriginText.Text=$Origin
 } finally {$script:UpdatingChoices=$false}
 Update-ExactSettings
}
function Update-DesktopInstalled($Core,[bool]$ResetChoices=$false) {
 $s=Get-ACRDesktopSettingsFromReport $Core
 $script:InstalledChoices=$s
 if($null -eq $s) {
  $script:UI.InstallStateTitle.Text='Earlier or unknown settings'
  $script:UI.InstalledSummary.Text='The exact settings could not be displayed. Check Advanced for details. Recommended installation and full removal still perform their own compatibility checks.'
  return
 }
 try{Save-ACRJson (Join-Path (Get-ACRUserStateRoot) 'last-file-check.json') ([ordered]@{Core=$Core;CheckedUtc=[DateTime]::UtcNow.ToString('o')})}catch{}
 $config=$Core.VerifiedConfiguration
 $guard=[bool]$config.GameLocalStartupGuard
 if((Test-ACRDesktopStockSelection $s) -and -not $guard) {
  $script:UI.InstallStateTitle.Text='Original game files verified'
  $script:UI.InstalledSummary.Text='No Grip Happens changes remain in the checked game files. Install the recommended setup below when you are ready.'
 } else {
  if($guard) {$script:UI.InstallStateTitle.Text='Mod settings verified'} else {$script:UI.InstallStateTitle.Text='Previous mod configuration detected'}
  $script:UI.InstalledSummary.Text='Your installed settings were verified. Use the system pages to tune, or Review changes to compare exact values.'
 }
 Update-Workspace
 if($ResetChoices -or (-not $script:ChoicesDirty -and -not (Test-ACRDesktopStockSelection $s))) {Set-DesktopChoices $s 'Loaded from your verified game files. Changes below are not applied until you click Apply.'}
}
function Request-DesktopInstall($Settings) {
 if($script:Busy) {return}
 if(-not $script:GameRoot) {Show-DesktopMessage 'Choose the game folder first.';return}
 $script:UI.Pages.SelectedItem=$script:UI.ReviewTab
 $summary=Get-WorkspaceSummary $Settings
 if(Test-ACRDesktopStockSelection $Settings) {
  $message="All fourteen settings are at stock/off. This removes the mod's game-file changes, including the startup and HTTP guards.`n`nYour saves and network settings are not changed.`n`nRestore the original game?"
 } else {
  $message=$summary+"`n`nThis updates your selected ACR installation and backs up the originals (about 190 MB). ACR must be closed. Windows may ask for administrator approval.`n`nThe existing game-local startup check requires no live Steam connection. Select Steam > Go Offline yourself. The HTTP guard is not a proven block of every server or later result upload. Use local, noncompetitive play.`n`nCritical failures can end a run. Recommended is a tested gameplay setup, not a realistic lifespan guarantee. Diagnostic accounting is off. Stock wear-to-grip behavior is retained.`n`nNo firewall rules or Steam settings are changed.`n`nApply this setup?"
 }
 if(Confirm-Desktop $message 'Apply mod settings?') {Start-DesktopTask 'Install' $Settings $true}
}
function Start-DesktopTask([string]$Action,$Settings=$null,[bool]$Consent=$false,[bool]$Automatic=$false,[bool]$PlayAfterCheck=$false) {
 if($script:Busy) {return}
 if($Action -ne 'Support' -and -not $script:GameRoot) {Show-DesktopMessage 'Choose the game folder first.';return}
 if($null -eq $Settings) {$Settings=Get-ACRDesktopDefaults}
 $expected=$Settings | ConvertTo-Json -Depth 4 -Compress | ConvertFrom-Json
 $id=[Guid]::NewGuid().ToString('N')
 Set-DesktopBusy $true
 Set-DesktopStatus 'Starting... Windows may ask for permission.'
 try {
  $dir=Join-Path (Join-Path (Get-ACRUserStateRoot) 'DesktopTasks') $id
  [IO.Directory]::CreateDirectory($dir)|Out-Null
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  try {$sid=$identity.User.Value} finally {$identity.Dispose()}
  $worker=Join-Path $PSScriptRoot 'Invoke-ACR-DesktopTask.ps1'
  $ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $arg='-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File '+(ConvertTo-ACRDesktopArgument $worker)
  foreach($pair in @(@('Action',$Action),@('TaskId',$id),@('TaskDirectory',$dir),@('RequestOwnerSid',$sid),@('GameRoot',$script:GameRoot),@('RateScale',$Settings.RateScale),@('WetTarmac',$Settings.WetTarmac),@('VisualDamage',$Settings.VisualDamage),@('CollisionDamage',$Settings.CollisionDamage),@('TyreDamage',$Settings.TyreDamage),@('MechanicalFailures',$Settings.MechanicalFailures),@('BrakeWear',$Settings.BrakeWear),@('Detachment',$Settings.Detachment),@('CriticalDamage',$Settings.CriticalDamage),@('CoolingRouting',$Settings.CoolingRouting),@('EngineImpact',$Settings.EngineImpact),@('PowerResponse',$Settings.PowerResponse),@('WheelImpact',$Settings.WheelImpact),@('GearboxDamage',$Settings.GearboxDamage),@('CustomJsonBase64',(ConvertTo-ACRCustomBase64 (Get-ACRCustomValuesFromSettings $Settings))))) {
   if($pair[0] -eq 'GameRoot' -and [string]::IsNullOrWhiteSpace([string]$pair[1])) {continue}
   $arg+=' -'+$pair[0]+' '+(ConvertTo-ACRDesktopArgument ([string]$pair[1]))
  }
  if($Consent) {$arg+=' -Consent'}
  $start=@{FilePath=$ps;ArgumentList=$arg;WindowStyle='Hidden';PassThru=$true;ErrorAction='Stop'}
  if($Action -in @('Install','Restore','Snapshot','DriveTrace') -and -not (Test-ACRAdministrator)) {$start.Verb='RunAs'}
  $process=Start-Process @start
  $script:Task=[pscustomobject]@{Id=$id;Action=$Action;Directory=$dir;Process=$process;ExpectedSettings=$expected;Automatic=$Automatic;PlayAfterCheck=($PlayAfterCheck -and $Action -eq 'Check');Started=[DateTime]::UtcNow;GameRoot=$script:GameRoot;TakeId='';ResetPendingTakeId='';RestartAfterExit=$false}
  Set-DesktopBusy $true
  $script:UI.StopRecordingButton.IsEnabled=$true;$script:UI.StopRecordingButton.Content='Stop & save recording'
  $script:LastTaskDirectory=$dir;$script:UI.OpenTaskButton.IsEnabled=$true
  $script:UI.DetailsText.Text='Running. Progress is shown below; the complete log is in the task folder.'
  $script:UI.OutputText.Text='Working...';$script:UI.ShowOutputButton.IsEnabled=$false;$script:LastOutput=''
  $script:Timer.Start()
 } catch {
  Set-DesktopBusy $false
  if($_.Exception.ToString() -match '(?i)canceled|cancelled|1223') {
   Set-DesktopStatus 'Permission request cancelled. No operation was started.'
  } else {
   $script:UI.DetailsText.Text=$_.Exception.ToString()
   Set-DesktopStatus 'The operation could not start. See Advanced for details.'
   Show-DesktopMessage ('The operation could not start. No new game-file operation was started.'+"`n`n"+$_.Exception.Message)
  }
 }
}
function Stop-DesktopRecording {
 if(-not $script:Busy -or $null -eq $script:Task -or $script:Task.Action -ne 'DriveTrace'){return}
 $path=Join-Path $script:Task.Directory 'stop-recording.request'
 try {
  if(-not [IO.File]::Exists($path)){$marker=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);$marker.Dispose()}
  $script:UI.StopRecordingButton.IsEnabled=$false;$script:UI.StopRecordingButton.Content='Saving recording...'
  Set-DesktopStatus 'Stop requested. Keeping all captured samples and finishing the ZIP.'
 } catch {Show-DesktopMessage ('The stop request could not be saved: '+$_.Exception.Message)}
}
function Complete-DesktopTask {
 $t=$script:Task
 if($null -eq $t) {return}
 $progress=Join-Path $t.Directory 'progress.json'
 if([IO.File]::Exists($progress)) {
  try {
   $p=[IO.File]::ReadAllText($progress)|ConvertFrom-Json
   if($p.TaskId -ceq $t.Id) {Set-DesktopStatus ([string]$p.Text);Update-DesktopRecordingProgress $t $p}
  } catch { } # An in-flight atomic replace is retried at the next tick.
 }
 $elapsed=[DateTime]::UtcNow-$t.Started
 $script:UI.ElapsedText.Text=('Elapsed '+$elapsed.ToString('mm\:ss'))
 if(-not $t.Process.HasExited) {return}
 $script:Timer.Stop();$script:Task=$null
 $code=$t.Process.ExitCode;$t.Process.Dispose()
 $r=$null
 try {
  $responsePath=Join-Path $t.Directory 'response.json'
  if(-not [IO.File]::Exists($responsePath)) {
   if($code -eq 5) {throw 'Administrator credentials switched to another account. Open the entire mod utility using that account, then try again.'}
   throw ('The task closed without a result (exit '+$code+'). Do not assume it finished. Check or restore before starting ACR.')
  }
  if((Get-Item -LiteralPath $responsePath).Length -gt 2097152) {throw 'Unexpected response size.'}
  $r=[IO.File]::ReadAllText($responsePath)|ConvertFrom-Json
  if(-not (Test-ACRDesktopReply $r $t.Id $t.Action)) {throw 'Task result did not match this operation.'}
  if(Complete-DesktopRecordingReset $t){return}
  $log=Join-Path $t.Directory 'details.log'
  $details=''
  if([IO.File]::Exists($log)) {
   # Keep the full log on disk; show a bounded tail in the UI.
   try {$details=(@(Get-Content -LiteralPath $log -Tail 120 -ErrorAction Stop) -join "`n")}
   catch {$details='The diagnostic log could not be displayed: '+$_.Exception.Message+' The structured operation result is shown separately.'}
  }
  if($null -ne $r.PSObject.Properties['LoggingError'] -and $r.LoggingError){$details="Diagnostic logging was incomplete: "+$r.LoggingError+"`n`n"+$details}
  $script:UI.DetailsText.Text=$details
  if($r.Error) {$script:UI.DetailsText.Text=([string]$r.Error)+"`n`n"+$details}
  if(@($r.OutputFiles).Count -gt 0) {
   $script:LastOutput=[string]$r.OutputFiles[0]
   $script:UI.OutputText.Text=(@($r.OutputFiles) -join "`n")
   $script:UI.ShowOutputButton.IsEnabled=([IO.File]::Exists($script:LastOutput))
  } else {$script:UI.OutputText.Text='Local details are saved with this task. Nothing was uploaded.'}
  if($r.Status -ne 'Success' -or $code -ne 0) {
   $text=Get-ACRDesktopFailureText ([string]$r.Error) $r.Core
   if($t.Action -in @('Install','Restore','Check')) {
    $script:UI.InstallStateTitle.Text='Installation not verified'
    $script:UI.InstalledSummary.Text=$text
   }
   Set-DesktopStatus $text
   if(-not $t.Automatic) {Show-DesktopMessage $text 'Operation stopped'}
   return
  }
  switch($t.Action) {
   'Check' {Update-DesktopInstalled $r.Core;Set-DesktopStatus ('Game files checked at '+[DateTime]::Now.ToString('t')+'. This is a file check, not a live network test.');Complete-DesktopPlay $t $r.Core}
   'Install' {
    $s=Get-ACRDesktopVerifiedInstallSettings $r.Core $t.ExpectedSettings
    Update-DesktopInstalled $r.Core $true
    if((Test-ACRDesktopStockSelection $s) -and -not $r.Core.VerifiedConfiguration.GameLocalStartupGuard) {Set-DesktopStatus 'Original game files restored and verified.'}
    else {Set-DesktopStatus ((Get-ACRPlayerProfileName $s)+' installed and verified. Play uses this installed setup; custom choices are valid too.')}
   }
   'Restore' {Update-DesktopInstalled $r.Core $true;Set-DesktopStatus 'Mod removed. Original game files restored and verified. Your saves were not deleted.'}
   'Support' {Set-DesktopStatus 'Sanitized support ZIP created. Use Show report in folder to find it. Nothing was uploaded.';$script:UI.Pages.SelectedItem=$script:UI.AdvancedTab}
   'DriveTrace' {
    $text='Driving recording saved. Review its summary for duration or early-stop reason.'
    if($null -ne $r.PSObject.Properties['RecordingCompletion'] -and $r.RecordingCompletion.Status -ne 'SummaryUnavailable'){
     $done=$r.RecordingCompletion;$text=if($done.Status -eq 'Partial'){('Partial recording saved: '+$done.Samples+' samples. Game-state reads stopped; the captured data were kept. See Advanced for the reason.')}else{('Recording saved: '+$done.Samples+' samples. '+$done.StopReason)}
    };Set-DesktopStatus $text
   }
        'Snapshot' {Set-DesktopStatus 'Damage snapshot saved. Nothing was uploaded.';$script:UI.Pages.SelectedItem=$script:UI.AdvancedTab}
  }
 } catch {
  $script:UI.DetailsText.Text=$_.Exception.ToString()
  if($t.Action -in @('Install','Restore','Check')){
   $script:UI.InstallStateTitle.Text='Check the result before playing'
   Set-DesktopStatus 'The file-operation result could not be read. Check or restore before playing.'
  }else{Set-DesktopStatus 'The diagnostic result could not be read. No game settings were changed; local details and any saved data remain in Advanced.'}
  if(-not $t.Automatic -and $t.Action -ne 'DriveTrace'){Show-DesktopMessage $_.Exception.Message 'Result unavailable'}

 } finally {
  Set-DesktopBusy $false
  if($null -ne $t.PSObject.Properties['RestartAfterExit'] -and $t.RestartAfterExit){Start-DesktopRecordingAgain $t}
 }
}
function Use-DesktopLocation($Location) {
 $script:GameRoot=$Location.GameRoot;$script:UI.GamePathText.Text=$Location.GameRoot;$script:UI.GamePathText.ToolTip=$Location.GameRoot
 $script:UI.GameSourceText.Text=$Location.Source+'. You can choose a different folder.'
 if($Location.CandidateCount -gt 1){$script:UI.GameSourceText.Text+=' Multiple installations found.'}
 if($null -ne $Location.PSObject.Properties['LocationSaved'] -and -not $Location.LocationSaved){
  $script:UI.GameSourceText.Text+=' This selection could not be remembered for next time.'
  $script:UI.GameSourceText.ToolTip=$Location.LocationSaveError
 } else {$script:UI.GameSourceText.ToolTip=$null}
 $script:ChoicesDirty=$false;Set-DesktopBusy $false
 if(@(Get-Process -Name 'acr' -ErrorAction SilentlyContinue).Count -gt 0) {
  $script:UI.InstallStateTitle.Text='Close ACR to check installed settings'
  $script:UI.InstalledSummary.Text='Game folder selected. Close ACR before checking or changing game files.'
  Set-DesktopStatus 'ACR is running. Damage snapshots are available in Advanced.'
 } else {Start-DesktopTask 'Check' $null $false $true}
}
function Select-DesktopGame {
 if($script:Busy){return}
 try {
  if($script:ChoicesDirty -and -not (Confirm-Desktop 'Switching the game folder discards the unapplied choices in this window. No game files will be changed. Continue?' 'Change game folder?')){return}
  $selected=Show-ACRDarkFolderPicker $script:Window $script:GameRoot
  if(-not $selected){return}
  Use-DesktopLocation (Resolve-ACRInstall $selected '')
 } catch {Show-DesktopMessage ('That folder could not be selected.'+"`n`n"+$_.Exception.Message)}
}
function Detect-DesktopGame {
 if($script:Busy){return}
 try {
  if($script:ChoicesDirty -and -not (Confirm-Desktop 'Searching again can select a different installation and discard unapplied choices. No game files will be changed. Continue?' 'Find game again?')){return}
  Use-DesktopLocation (Resolve-ACRInstall '' '' -IgnoreSaved)
 } catch {Show-DesktopMessage ('No usable game folder was found. Change folder is still available.'+"`n`n"+$_.Exception.Message)}
}

try {
 Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Common.psm1') -ErrorAction Stop
 Assert-ACRWindows
 if([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {throw 'Open the supplied .cmd launcher. The interface needs an STA PowerShell process.'}
 Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
 & (Join-Path $PSScriptRoot 'Verify-Package.ps1') -Quiet *> $null
 if($LASTEXITCODE -ne 0) {throw 'Package verification failed. Extract the complete ZIP into a new folder, then open its launcher.'}
 Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Desktop.psm1') -ErrorAction Stop
 Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Player.psm1') -ErrorAction Stop
 Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Theme.psm1') -ErrorAction Stop
 $xml=New-Object Xml.XmlDocument;$xml.XmlResolver=$null
 $xml.LoadXml([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ui\Main.xaml')))
 $reader=New-Object Xml.XmlNodeReader($xml)
 try {$script:Window=[Windows.Markup.XamlReader]::Load($reader)} finally {$reader.Close()}
 Initialize-ACRDarkWindow $script:Window
 $work=[Windows.SystemParameters]::WorkArea
 $script:Window.Width=[Math]::Min(1120,[Math]::Max(840,$work.Width-32))
 $script:Window.Height=[Math]::Min(820,[Math]::Max(540,$work.Height-32))
 $ns=New-Object Xml.XmlNamespaceManager($xml.NameTable);$ns.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')
 foreach($node in $xml.SelectNodes('//*[@x:Name]',$ns)) {
  $name=$node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
  $control=$script:Window.FindName($name);if($null -ne $control){$script:UI[$name]=$control}
 }
 Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Custom.psm1') -ErrorAction Stop
 . (Join-Path $PSScriptRoot 'ui\Workspace.ps1')
 . (Join-Path $PSScriptRoot 'ui\Player.ps1')
 . (Join-Path $PSScriptRoot 'ui\Play.ps1')
Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Recording.psm1') -ErrorAction Stop
. (Join-Path $PSScriptRoot 'ui\Recording.ps1')
 $choices=Get-ACRDesktopChoices
 $script:UI.WearChoice.ItemsSource=$choices.RateScale;$script:UI.WetChoice.ItemsSource=$choices.WetTarmac
 $script:UI.VisualChoice.ItemsSource=$choices.VisualDamage;$script:UI.CollisionChoice.ItemsSource=$choices.CollisionDamage
 $script:UI.TyreDamageChoice.ItemsSource=$choices.TyreDamage
 $script:UI.FailuresChoice.ItemsSource=$choices.MechanicalFailures
 $script:UI.BrakeChoice.ItemsSource=$choices.BrakeWear
 $script:UI.DetachChoice.ItemsSource=$choices.Detachment
 $script:UI.CriticalChoice.ItemsSource=$choices.CriticalDamage
 $script:UI.CoolingChoice.ItemsSource=$choices.CoolingRouting
 $script:UI.EngineChoice.ItemsSource=$choices.EngineImpact
 $script:UI.PowerChoice.ItemsSource=$choices.PowerResponse
 $script:UI.WheelImpactChoice.ItemsSource=$choices.WheelImpact
 $script:UI.GearboxChoice.ItemsSource=$choices.GearboxDamage
 Set-DesktopChoices (Get-ACRPlayerPreset 'Recommended') 'Recommended choices. Nothing is applied until you confirm.'
 $script:Timer=New-Object Windows.Threading.DispatcherTimer
 $script:Timer.Interval=[TimeSpan]::FromMilliseconds(400)
 $script:Timer.Add_Tick({try {Complete-DesktopTask} catch {Set-DesktopStatus ('Unable to read task status: '+$_.Exception.Message)}})
 $script:UI.BrowseButton.Add_Click({Select-DesktopGame})
 $script:UI.DetectButton.Add_Click({Detect-DesktopGame})
 $script:UI.OpenSettingsButton.Add_Click({$script:UI.Pages.SelectedItem=$script:UI.SettingsTab})
 $script:UI.ApplyButton.Add_Click({try {Request-DesktopInstall (Read-DesktopChoices)} catch {Show-DesktopMessage $_.Exception.Message}})
 foreach($name in @('WearChoice','WetChoice','VisualChoice','CollisionChoice','TyreDamageChoice','FailuresChoice','BrakeChoice','DetachChoice','CriticalChoice','CoolingChoice','EngineChoice','PowerChoice','WheelImpactChoice','GearboxChoice')) {
  $script:UI[$name].Add_SelectionChanged({param($sender,$e) if(-not $script:UpdatingChoices){
   foreach($field in (Get-ACRCustomSchema).Fields){if($field.Group -eq [string]$sender.Tag -and $script:CustomValues.Contains($field.Key)){$script:CustomValues.Remove($field.Key)}}
   $script:ChoicesDirty=$true;$script:UI.SettingsOriginText.Text='Pending choices. Review and Apply when ready.';Update-ExactSettings
  }})
  # A closed dropdown must never change from ordinary page scrolling. If the
  # list is open, the wheel remains available for browsing its options.
  $script:UI[$name].Add_PreviewMouseWheel({param($sender,$e) Invoke-WorkspaceWheel $sender $e})
 }
 $script:UI.RestoreButton.Add_Click({try {
  if(-not $script:GameRoot) {Show-DesktopMessage 'Choose the game folder above first. Then select Restore original game files.';return}
  $folder=Get-ACRDesktopBackupFolder $script:GameRoot
  $message="Restore the ORIGINAL game files for:`n"+$script:GameRoot+"`n`nThis removes tyre-wear changes, wet-road tuning, extra damage scaling, and the Steam-startup / HTTP guards. It restores the supported original file values, not just the dropdown choices.`n`nYour saves and existing backups are kept. ACR must be closed. Unknown builds or unrelated edits are never force-overwritten.`n`nBackups for this installation:`n"+$folder+"`n`nRestore now?"
  if(Confirm-Desktop $message 'Restore original game files?') {Start-DesktopTask 'Restore' $null $true}
 } catch {Show-DesktopMessage $_.Exception.Message}})
 $script:UI.OpenBackupsButton.Add_Click({try {
  if(-not $script:GameRoot) {Show-DesktopMessage 'Choose the game folder above first.';return}
  $folder=Get-ACRDesktopBackupFolder $script:GameRoot
  if([IO.Directory]::Exists($folder)) {Assert-ACRNoReparse $folder;Invoke-Item -LiteralPath $folder}
  else {Show-DesktopMessage ("No backup folder exists for this installation yet. Backups are created before the first patch is written.`n`nExpected location:`n"+$folder) 'Original-file backups'}
 } catch {Show-DesktopMessage $_.Exception.Message}})
 $script:UI.CheckButton.Add_Click({try {Start-DesktopTask 'Check'} catch {Show-DesktopMessage $_.Exception.Message}})
 $script:UI.SupportButton.Add_Click({try {Show-PlayerSupportPreview} catch {Show-DesktopMessage $_.Exception.Message}})
 $script:UI.DrivingTraceButton.Add_Click({try {
  if(Confirm-Desktop "Start with ACR paused in a loaded local offline stage.`n`nAfter the status says Recorder ready, return to ACR and unpause. The recorder waits 8 seconds, then reads driving data for up to 5 minutes. Stop & save recording ends it early without losing captured data. Drive normally, include a clear straight section, and try manual shifts after some damage. Do not change cars or reload mid-recording.`n`nThis only reads game data. Nothing is uploaded and no game memory is written. Start recording?" 'Record driving data?') {Start-DesktopTask 'DriveTrace' $null $true}
 } catch {Show-DesktopMessage $_.Exception.Message}})
 $script:UI.SnapshotButton.Add_Click({try {
  if(Confirm-Desktop "Leave ACR running and paused inside a loaded, local offline stage.`n`nThis read-only snapshot records part health and game-object data. It is NOT the sanitized support report. No data is uploaded and no game memory is written.`n`nCapture now?" 'Take damage snapshot?') {Start-DesktopTask 'Snapshot' $null $true}
 } catch {Show-DesktopMessage $_.Exception.Message}})
 $script:UI.ShowOutputButton.Add_Click({try {
  if([IO.File]::Exists($script:LastOutput)) {Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('/select,'+(ConvertTo-ACRDesktopArgument $script:LastOutput))|Out-Null}
 } catch {Show-DesktopMessage $_.Exception.Message}})
 $script:UI.StopRecordingButton.Add_Click({Stop-DesktopRecording})
 $script:UI.ResetRecordingButton.Add_Click({Reset-DesktopRecording})
 $script:UI.OpenTaskButton.Add_Click({try {if([IO.Directory]::Exists($script:LastTaskDirectory)){Invoke-Item -LiteralPath $script:LastTaskDirectory}} catch {Show-DesktopMessage $_.Exception.Message}})
 $script:UI.ReadHelpButton.Add_Click({try {Invoke-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'README.md')} catch {Show-DesktopMessage $_.Exception.Message}})
 Initialize-Workspace
 Initialize-Player
 Initialize-DesktopPlay
 $script:Window.Add_Closing({param($sender,$eventArgs)
  if($script:Busy) {$eventArgs.Cancel=$true;Set-DesktopStatus 'An operation is running. Keep this window open; use Stop & save recording to end a driving test, or wait for it to finish.'}
  elseif($script:ChoicesDirty -and -not (Confirm-Desktop 'Close without applying your pending choices? The installed game will not change.' 'Discard pending choices?')){$eventArgs.Cancel=$true}
 })
 $script:Window.Add_ContentRendered({
  if($script:Initialised) {return};$script:Initialised=$true
  try {
   Use-DesktopLocation (Resolve-ACRInstall '' '')
  } catch {
   $script:UI.GamePathText.Text='Choose your Assetto Corsa Rally folder';$script:UI.InstallStateTitle.Text='Choose the game folder to begin'
   $script:UI.InstalledSummary.Text='No usable installation was found in Steam libraries or the standard fallback folders. Click Change folder above. No game files were changed.'
   $script:UI.GameSourceText.Text='Automatic detection found no usable folder.'
   $script:UI.DetailsText.Text=$_.Exception.Message;Set-DesktopBusy $false;Set-DesktopStatus 'Game folder needed. Use Change folder above.'
  }
 })
 [void]$script:Window.ShowDialog()
 if($null -ne $script:Timer){$script:Timer.Stop()}
 if($null -ne $script:PlayTimer){$script:PlayTimer.Stop()}
 exit 0
} catch {
 $text='Grip Happens could not open.'+"`n`n"+$_.Exception.Message+"`n`nExtract the complete ZIP into a new folder and open its launcher. Do not disable Windows protection."
 try {
  $dir=Join-Path $env:LOCALAPPDATA 'ACRMods\GripHappens\Launcher';[IO.Directory]::CreateDirectory($dir)|Out-Null
  $path=Join-Path $dir ('DesktopStartup_'+[DateTime]::Now.ToString('yyyyMMdd_HHmmss')+'.txt')
  ($_|Out-String)|Set-Content -LiteralPath $path -Encoding UTF8
  $text+="`n`nLocal error report: "+$path
 } catch { }
 try {[void][Windows.MessageBox]::Show($text,'Grip Happens')} catch {try {$shell=New-Object -ComObject WScript.Shell;[void]$shell.Popup($text,0,'Grip Happens',16)} catch {Write-Error $text}}
 exit 1
}
