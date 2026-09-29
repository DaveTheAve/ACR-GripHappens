# Normal player workflow; developer controls are deliberately opt-in per window.
$script:DeveloperToolsVisible=$false
function Stage-PlayerPreset([string]$Name) {
 if($script:Busy){return}
 Set-DesktopChoices (Get-ACRPlayerPreset $Name) ((Get-ACRPlayerProfileName (Get-ACRPlayerPreset $Name))+' selected. Review & apply is required.')
 $script:ChoicesDirty=$true;Set-DesktopStatus 'Setup selected only. Review & apply, then Play.'
 $script:UI.Pages.SelectedItem=$script:UI.ReviewTab
}
function Reset-PlayerGroup([string]$Group) {
 if($script:Busy){return}
 Set-DesktopChoices (Get-ACRPlayerGroupReset (Read-DesktopChoices) $Group) 'This section reset to Recommended. Other pending settings are unchanged.'
 $script:ChoicesDirty=$true;Set-DesktopStatus 'Section reset in pending choices only. Review & apply when ready.'
}
function Show-PlayerSupportPreview([string]$OutputDirectory='') {
 if($script:Busy){return}
 Import-Module (Join-Path $PSScriptRoot '..\modules\ACR.Support.psm1') -ErrorAction Stop
 $source=Get-ACRSupportDiagnostic;$report=New-ACRSanitizedReport $source;$json=$report|ConvertTo-Json -Depth 12
 $dialog=New-Object Windows.Window;$dialog.Owner=$script:Window;$dialog.Title='Preview sanitized support report';$dialog.ShowInTaskbar=$false;$dialog.WindowStartupLocation='CenterOwner'
 $dialog.Width=[math]::Min(720,[Windows.SystemParameters]::WorkArea.Width-40);$dialog.Height=[math]::Min(610,[Windows.SystemParameters]::WorkArea.Height-50)
 $dialog.Background=$script:Window.Background;$dialog.Foreground=$script:Window.Foreground;$dialog.Resources=$script:Window.Resources;$dialog.FontSize=14
 $grid=New-Object Windows.Controls.Grid;$grid.Margin='20';foreach($height in @('Auto','*','Auto')){$r=New-Object Windows.Controls.RowDefinition;$r.Height=$height;$grid.RowDefinitions.Add($r)}
 $intro=New-Object Windows.Controls.TextBlock;$intro.Text='This is the complete JSON that will be saved locally. No usernames, local paths, Steam IDs, saves, raw logs or memory snapshots. Nothing is uploaded.';$intro.TextWrapping='Wrap';$intro.Margin='0,0,0,12';[void]$grid.Children.Add($intro)
 $box=New-Object Windows.Controls.TextBox;$box.IsReadOnly=$true;$box.Text=$json;$box.FontFamily='Consolas';$box.FontSize=12;$box.TextWrapping='Wrap';$box.VerticalScrollBarVisibility='Auto';[Windows.Controls.Grid]::SetRow($box,1);[void]$grid.Children.Add($box)
 $buttons=New-Object Windows.Controls.StackPanel;$buttons.Orientation='Horizontal';$buttons.HorizontalAlignment='Right';$buttons.Margin='0,12,0,0';[Windows.Controls.Grid]::SetRow($buttons,2)
 $cancel=New-Object Windows.Controls.Button;$cancel.Content='Cancel';$cancel.IsCancel=$true
 $save=New-Object Windows.Controls.Button;$save.Content='Save this report';$save.Style=$script:Window.Resources['PrimaryButton'];$save.IsDefault=$true
 $save.Add_Click({$dialog.DialogResult=$true;$dialog.Close()}.GetNewClosure());[void]$buttons.Children.Add($cancel);[void]$buttons.Children.Add($save);[void]$grid.Children.Add($buttons);$dialog.Content=$grid
 Initialize-ACRDarkWindow $dialog
 if($dialog.ShowDialog() -eq $true){
  if(-not $OutputDirectory){$OutputDirectory=Get-ACRDownloads}
  $out=Export-ACRSanitizedSupport $OutputDirectory -PreparedReport $report
  $script:LastOutput=$out;$script:UI.OutputText.Text=$out;$script:UI.ShowOutputButton.IsEnabled=$true;Set-DesktopStatus 'Support report saved locally. Review it before sharing; nothing was uploaded.'
 }
}
function Initialize-Player {
 $script:UI.RecommendedButton.Add_Click({Stage-PlayerPreset 'Recommended'})
 $script:UI.ResetChoicesButton.Add_Click({Stage-PlayerPreset 'Recommended'})
 $script:UI.TyresOnlyButton.Add_Click({Stage-PlayerPreset 'TyresOnly'})
 foreach($c in $script:WorkspaceCards){$button=$script:UI['Reset_'+$c.Key];$button.Add_Click({param($sender,$e)try{Reset-PlayerGroup ([string]$sender.Tag)}catch{Show-DesktopMessage $_.Exception.Message}})}
 $script:UI.Reset_DrivetrainWear.Add_Click({Reset-PlayerGroup 'DrivetrainWear'})
 $script:UI.KnownIssuesButton.Add_Click({Invoke-Item -LiteralPath (Join-Path (Split-Path (Get-Module ACR.Player).ModuleBase) 'docs\KNOWN ISSUES.txt')})
 $script:UI.BuyCoffeeButton.Add_Click({try{Open-ACRBuyMeACoffee}catch{Show-DesktopMessage ('Could not open Buy Me a Coffee: '+$_.Exception.Message)}})
}
