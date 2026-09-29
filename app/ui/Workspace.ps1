# All edits are pending until the existing Apply transaction.
$script:WorkspaceCards=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'workspace-cards.json') -Raw|ConvertFrom-Json
$script:CustomValues=[ordered]@{};$script:InstalledChoices=$null
function Get-WorkspaceLabel([string]$Name,[string]$Value) {
 $full=Get-ACRDesktopLabel $Name $Value
 if($Name -eq 'RateScale'){if($Value -eq '0'){return 'Off - 0x wear (original game)'};return (($full -split ' - ')[0]+'  /  '+$Value+'x coefficient')}
 if($Name -eq 'WetTarmac'){$item=@((Get-ACRDesktopChoices).WetTarmac|Where-Object {$_.Value -eq $Value})[0];return (($full -split ' - ')[0]+'  /  '+$item.LossReductionPercent+'% less wet loss')}
 $labels=@{
  TyreDamage=@{Stock='Stock - game rate (captured 0.00)';Native='Enabled - compression rate 1.00'}
  BrakeWear=@{Stock='Stock - game gate (captured 0 / off)';Native='Native disc/pad wear - gate 1 / on'}
  MechanicalFailures=@{Stock='Stock - authored threshold (captured 75%)';Earlier85='Earlier - eligibility at 85% health';Earlier90='Earlier still - eligibility at 90% health'}
  Detachment=@{Stock='Stock - attachment threshold 1.00x';Easier='Easier - attachment threshold 0.75x';Aggressive='Aggressive - attachment threshold 0.50x'}
  PowerResponse=@{Stock='Stock - native curves, 0 added caps';Progressive='Progressive - engine 85% / turbo 70%'}
  GearboxDamage=@{Stock='Stock - 0 gearbox overrides';Grinding='Grinding - native rate 1.00x';Impact='Grinding + impacts - 50% transfer';Responsive='Responsive - 50% hit transfer, health-linked shifts';Mechanical='Mechanical - 0.25s recovery';Engagement='Engagement - up to +0.75s';Consequences='Progressive shifting - damage can delay or reject shifts'}
  WheelImpact=@{Stock='Stock - uniform 1.00x impact input';Localized='Localized - 0.00x to 2.00x by distance';Bent='Localized + bending - 3.00x, limit 0.020'}
  CoolingRouting=@{Stock='Stock - 0 added socket aliases';EngineBay='Engine-bay fallback - 1 / on'}
  CriticalDamage=@{Stock='Stock - 0 added overrides';Cumulative='Cumulative - 1 / on, terminal failures'}
 }
 if($labels.ContainsKey($Name)-and $labels[$Name].ContainsKey($Value)){return $labels[$Name][$Value]}
 return ($full -replace '\s*\([^)]*\)','' -replace 'engine collision coefficient','weighting' -replace 'game compression rate','compression rate' -replace 'failure eligibility threshold','threshold' -replace 'game attachment threshold factor','attachment thresholds').Trim()
}
function Get-WorkspaceCustomForGroup($Map,[string]$Group) {
 $r=[ordered]@{};foreach($f in (Get-ACRCustomSchema).Fields){if($f.Group -eq $Group -and $Map.Contains($f.Key)){$r[$f.Key]=$Map[$f.Key]}};return ,$r
}
function Get-WorkspaceSummary($Settings) {
 $lines=@();foreach($c in $script:WorkspaceCards){$lines+=($c.Title+': '+(Get-WorkspaceLabel $c.Key $Settings.($c.Key)))}
 $custom=Get-ACRCustomValuesFromSettings $Settings
 if($custom.Count){$lines+='';$lines+='CUSTOM VALUES';$lines+=Get-ACRCustomSummary $custom}
 return ($lines -join "`n")
}
function Update-Workspace {
 try {
  $s=Read-DesktopChoices;$cv=Get-ACRCustomValuesFromSettings $s;$iv=Get-ACRCustomValuesFromSettings $script:InstalledChoices
  $rows=New-Object 'Collections.Generic.List[object]';$changed=0
  foreach($c in $script:WorkspaceCards){
   $pending=Get-WorkspaceLabel $c.Key $s.($c.Key);$installed='Not verified yet';$different=$true
   $newValues=Get-WorkspaceCustomForGroup $cv $c.Key;$oldValues=Get-WorkspaceCustomForGroup $iv $c.Key
   if($null -ne $script:InstalledChoices){$installed=Get-WorkspaceLabel $c.Key $script:InstalledChoices.($c.Key);$different=($s.($c.Key) -cne $script:InstalledChoices.($c.Key))}
   if($newValues.Count){$pending+="`n"+(Get-ACRCustomSummary $newValues)}
   if($oldValues.Count){$installed+="`n"+(Get-ACRCustomSummary $oldValues)}
   if(($newValues|ConvertTo-Json -Compress) -cne ($oldValues|ConvertTo-Json -Compress)){$different=$true}
   if($different){$changed++};$ink='#EEF0F8';if($different){$ink='#C5A9FF'}
   $rows.Add([pscustomobject]@{Name=$c.Title;Installed=$installed;Pending=$pending;Ink=$ink})
   $description=Get-ACRPlayerSystemHelp $c.Key
   $script:UI[($c.Control+'DescriptionText')].Text=$description
   $script:UI[('Help_'+$c.Key)].ToolTip=$description
   $note=$script:UI[('Custom_'+$c.Key)];$note.Text=Get-ACRCustomSummary $newValues
   $note.Visibility=if($newValues.Count){'Visible'}else{'Collapsed'}
  }
  $diff=Get-WorkspaceCustomForGroup $cv 'DrivetrainWear';$oldDiff=Get-WorkspaceCustomForGroup $iv 'DrivetrainWear'
  $diffText=if($diff.Count){Get-ACRCustomSummary $diff}else{'Off - authored differential rates unchanged'}
  $oldDiffText=if($null -eq $script:InstalledChoices){'Not verified yet'}elseif($oldDiff.Count){Get-ACRCustomSummary $oldDiff}else{'Off - authored differential rates unchanged'}
  $diffChanged=($diffText -cne $oldDiffText);if($diffChanged){$changed++}
  $rows.Add([pscustomobject]@{Name='Differential material wear';Installed=$oldDiffText;Pending=$diffText;Ink=$(if($diffChanged){'#C5A9FF'}else{'#EEF0F8'})})
  $script:UI.DifferentialSummary.Text=$diffText
  $script:UI.ReviewRows.ItemsSource=$rows.ToArray()
  $script:UI.ExactSettingsText.Text=Get-WorkspaceSummary $s
  $script:UI.ChangeCountText.Text=if($null -eq $script:InstalledChoices){'Pending setup - not yet verified'}elseif($changed -eq 0){'Selections match your game'}else{[string]$changed+' system'+$(if($changed -ne 1){'s'})+' changed'}
  $script:UI.ChangeHintText.Text=if($cv.Count){[string]$cv.Count+' custom value'+$(if($cv.Count -ne 1){'s'})+' included. Review compares exact settings.'}else{'Presets only. Use Tune numbers for a custom value.'}
  $script:UI.UndoChoicesButton.IsEnabled=($null -ne $script:InstalledChoices -and -not $script:Busy)
 } catch {$script:UI.ChangeCountText.Text='Check your pending values';$script:UI.ChangeHintText.Text=$_.Exception.Message}
}
function Get-WorkspaceNumericDefault($Field,$Settings) {
 if($Field.Mode -eq 'Always'){return [ACRCustomBytes]::Number([double]$Field.Defaults.Enabled)}
 if($Field.Key -eq 'WearScale'){return [string]$Settings.RateScale}
 if($Field.Key -eq 'WetLossScale'){return [ACRCustomBytes]::Number(@((Get-ACRDesktopChoices).WetTarmac|Where-Object {$_.Value -eq $Settings.WetTarmac})[0].Multiplier)}
 if($null -eq $Field.Defaults.PSObject.Properties[[string]$Settings.($Field.Group)]){return ''}
 return [ACRCustomBytes]::Number([double]$Field.Defaults.($Settings.($Field.Group)))
}
function Show-WorkspaceNumericEditor([string]$Group) {
 if($script:Busy){return};$settings=Read-DesktopChoices;$fields=@((Get-ACRCustomSchema).Fields|Where-Object {$_.Group -eq $Group})
 if($fields.Count -eq 0){return}
 $map=Get-ACRCustomValuesFromSettings $settings;$card=if($Group -eq 'DrivetrainWear'){[pscustomobject]@{Title='Differential material wear'}}else{@($script:WorkspaceCards|Where-Object {$_.Key -eq $Group})[0]}
 $dialog=New-Object Windows.Window;$dialog.Owner=$script:Window;$dialog.Title='Tune numbers - '+$card.Title
 $dialog.Width=[Math]::Min(650,[Windows.SystemParameters]::WorkArea.Width-32);$dialog.SizeToContent='Height';$dialog.MaxHeight=[Math]::Max(280,[Windows.SystemParameters]::WorkArea.Height-40);$dialog.ShowInTaskbar=$false
 $dialog.MinHeight=0;$dialog.MinWidth=[Math]::Min(420,$dialog.Width);$dialog.WindowStartupLocation='CenterOwner'
 $dialog.Background=$script:Window.Background;$dialog.Foreground=$script:Window.Foreground;$dialog.FontFamily=$script:Window.FontFamily;$dialog.FontSize=14
 $dialog.Resources=$script:Window.Resources;$dialog.UseLayoutRounding=$true
 $grid=New-Object Windows.Controls.Grid;$grid.Margin='22'
 foreach($height in @('Auto','*','Auto')){$row=New-Object Windows.Controls.RowDefinition;$row.Height=$height;$grid.RowDefinitions.Add($row)}
 $intro=New-Object Windows.Controls.TextBlock;$intro.Text=$card.Title+"`nCustom values override numbers, not the native mode. Uncheck Override to use the selected preset. Supported ranges are not gameplay guarantees."
 $intro.TextWrapping='Wrap';$intro.Margin='0,0,0,16';$grid.Children.Add($intro)|Out-Null
 $scroll=New-Object Windows.Controls.ScrollViewer;$scroll.VerticalScrollBarVisibility='Auto';$scroll.HorizontalScrollBarVisibility='Disabled';$scroll.MaxHeight=[Math]::Max(80,$dialog.MaxHeight-240);[Windows.Controls.Grid]::SetRow($scroll,1)
 $stack=New-Object Windows.Controls.StackPanel;$scroll.Content=$stack;$grid.Children.Add($scroll)|Out-Null
 $editRows=New-Object 'Collections.Generic.List[object]'
 foreach($field in $fields){
  $default=Get-WorkspaceNumericDefault $field $settings;$active=($default -ne '' -and -not ($field.Key -eq 'WearScale' -and $settings.RateScale -eq '0'))
  $panel=New-Object Windows.Controls.StackPanel;$panel.Margin='0,0,0,18'
  $label=New-Object Windows.Controls.TextBlock;$label.Text=$field.Label;$label.FontWeight='SemiBold';$panel.Children.Add($label)|Out-Null
  $explain=New-Object Windows.Controls.TextBlock;$explain.Text=Get-ACRPlayerControlHelp $field.Key;$explain.TextWrapping='Wrap';$explain.FontSize=12;$explain.Foreground=$script:Window.Resources['MutedBrush'];$explain.Margin='0,4,0,4';$panel.Children.Add($explain)|Out-Null
  $range=New-Object Windows.Controls.TextBlock;$range.FontSize=12;$range.Foreground=$script:Window.Resources['MutedBrush'];$range.Margin='0,5,0,8'
  $range.Text=('Supported: '+([ACRCustomBytes]::Number([double]$field.Min))+' to '+([ACRCustomBytes]::Number([double]$field.Max))+' '+$field.Unit+'   |   Preset: '+$default)
  if(-not $active){$range.Text='Choose an enabled preset for this system first. No number is active in the selected mode.'}
  $range.TextWrapping='Wrap';$panel.Children.Add($range)|Out-Null
  $line=New-Object Windows.Controls.DockPanel
  $check=New-Object Windows.Controls.CheckBox;$check.Content='Override';$check.Foreground=$dialog.Foreground;$check.VerticalAlignment='Center';$check.Margin='0,0,14,0';$check.IsChecked=$map.Contains($field.Key);$check.IsEnabled=$active
  $box=New-Object Windows.Controls.TextBox;$box.MinWidth=180;$box.IsEnabled=$active;$box.Text=if($map.Contains($field.Key)){$map[$field.Key]}else{$default}
  if($null -ne $field.PSObject.Properties['Kind'] -and $field.Kind -eq 'Switch'){$check.Content='Enable this extension';$box.Visibility='Collapsed';$box.Text='1';$check.IsChecked=($map.Contains($field.Key) -and $map[$field.Key] -eq '1');$range.Text='Optional modeled/native-path extension. Off keeps the selected preset behavior.'}
  $line.Children.Add($check)|Out-Null;$line.Children.Add($box)|Out-Null;$panel.Children.Add($line)|Out-Null
  $error=New-Object Windows.Controls.TextBlock;$error.Foreground='#F2A8AD';$error.FontSize=12;$error.TextWrapping='Wrap';$error.Margin='0,4,0,0';$panel.Children.Add($error)|Out-Null
  $editRows.Add([pscustomobject]@{Field=$field;Check=$check;Box=$box;Error=$error;Active=$active})
  $stack.Children.Add($panel)|Out-Null
 }
 $buttons=New-Object Windows.Controls.StackPanel;$buttons.Orientation='Horizontal';$buttons.HorizontalAlignment='Right';$buttons.Margin='0,12,0,0';[Windows.Controls.Grid]::SetRow($buttons,2)
 $cancel=New-Object Windows.Controls.Button;$cancel.Content='Cancel';$cancel.IsCancel=$true
 $save=New-Object Windows.Controls.Button;$save.Content='Use these values';$save.Style=$dialog.Resources['PrimaryButton'];$save.IsDefault=$true
 $buttons.Children.Add($cancel)|Out-Null;$buttons.Children.Add($save)|Out-Null;$grid.Children.Add($buttons)|Out-Null
 $dialog.Content=$grid;$dialog.Tag=$null
 $save.Add_Click({
  $next=ConvertTo-ACRCustomMap $map;$ok=$true
  foreach($r in $editRows){
   $r.Error.Text='';$key=$r.Field.Key
   if(-not $r.Active -or -not $r.Check.IsChecked){if($next.Contains($key)){$next.Remove($key)};continue}
   $value=$r.Box.Text.Trim();$separator=[Globalization.CultureInfo]::CurrentCulture.NumberFormat.NumberDecimalSeparator
   if($separator -eq ',' -and $value -notmatch '\.'){$value=$value.Replace(',','.')}
   try {$one=ConvertTo-ACRCustomMap @{$key=$value};$next[$key]=$one[$key]}
   catch {$ok=$false;$r.Error.Text=$_.Exception.Message}
  }
  if($ok){$dialog.Tag=$next;$dialog.DialogResult=$true;$dialog.Close()}
 }.GetNewClosure())
 Initialize-ACRDarkWindow $dialog
 if($dialog.ShowDialog() -eq $true){$script:CustomValues=ConvertTo-ACRCustomMap $dialog.Tag;$script:ChoicesDirty=$true;Update-ExactSettings;Set-DesktopStatus 'Custom values staged. Review and Apply to change game files.'}
}
function Initialize-Workspace {
 $script:UI.Tune_DrivetrainWear.Add_Click({Show-WorkspaceNumericEditor 'DrivetrainWear'})
 foreach($c in $script:WorkspaceCards){
  $choice=$script:UI[($c.Control+'Choice')]
  foreach($item in $choice.ItemsSource){$item.Label=Get-WorkspaceLabel $c.Key $item.Value}
  $script:UI[('Help_'+$c.Key)].Add_Click({param($sender,$eventArgs)
   $card=@($script:WorkspaceCards|Where-Object {$_.Key -eq [string]$sender.Tag})[0];$s=Read-DesktopChoices
   Show-DesktopMessage (Get-ACRPlayerSystemHelp $card.Key) $card.Title
  })
  if($script:UI.ContainsKey('Tune_'+$c.Key)){$script:UI[('Tune_'+$c.Key)].Add_Click({param($sender,$eventArgs)Show-WorkspaceNumericEditor ([string]$sender.Tag)})}
 }
 $script:UI.UndoChoicesButton.Add_Click({if($null -ne $script:InstalledChoices){Set-DesktopChoices $script:InstalledChoices 'Pending changes discarded. Selections match the last verified game files.'}})
 $script:UI.Pages.Add_SelectionChanged({if($null -ne $script:UI.ReviewRows){Update-Workspace}})
 Update-Workspace
}
function Invoke-WorkspaceWheel($Sender,$Event) {
 if($Sender.IsDropDownOpen){return};$Event.Handled=$true;$parent=$Sender
 while($null -ne $parent -and $parent -isnot [Windows.Controls.ScrollViewer]){$parent=[Windows.Media.VisualTreeHelper]::GetParent($parent)}
 if($null -ne $parent){$parent.ScrollToVerticalOffset([Math]::Max(0,$parent.VerticalOffset-([double]$Event.Delta/3)))}
}
