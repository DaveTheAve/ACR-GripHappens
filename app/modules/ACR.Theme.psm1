#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Initialize-ACRDarkWindow($Window) {
    # Only the utility's own window chrome. No system theme or registry changes.
    try {
        if (-not ('ACRDarkWindow' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ACRDarkWindow {
 [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
 public static void Apply(IntPtr hwnd) {
  int dark=1; DwmSetWindowAttribute(hwnd,20,ref dark,4);
  int caption=0x00181211; DwmSetWindowAttribute(hwnd,35,ref caption,4);
  int text=0x00F8F0EE; DwmSetWindowAttribute(hwnd,36,ref text,4);
 }
}
'@ -ErrorAction Stop
        }
        $Window.Add_SourceInitialized({param($sender,$eventArgs)
            try {$helper=New-Object Windows.Interop.WindowInteropHelper -ArgumentList $sender;[ACRDarkWindow]::Apply($helper.Handle)} catch { }
        })
    } catch { } # Older Windows versions may keep the OS titlebar; content remains dark.
}
function New-ACRDarkDialog($Owner,[string]$Title,[double]$Width=660) {
    $d=New-Object Windows.Window
    $d.Owner=$Owner;$d.Title=$Title;$d.WindowStartupLocation='CenterOwner';$d.ShowInTaskbar=$false
    $d.Width=[Math]::Min($Width,[Windows.SystemParameters]::WorkArea.Width-32)
    $d.MinWidth=[Math]::Min(420,$d.Width);$d.SizeToContent='Height';$d.ResizeMode='CanResize'
    $d.MaxHeight=[Math]::Max(280,[Windows.SystemParameters]::WorkArea.Height-40)
    $d.Background=$Owner.Resources['WindowBrush'];$d.Foreground=$Owner.Resources['TextBrush']
    $d.FontFamily='Segoe UI';$d.FontSize=14;$d.UseLayoutRounding=$true
    $d.Resources.MergedDictionaries.Add($Owner.Resources)
    Initialize-ACRDarkWindow $d
    return $d
}
function Show-ACRDarkPrompt($Owner,[string]$Text,[string]$Title='Grip Happens',[switch]$Confirm) {
    $d=New-ACRDarkDialog $Owner $Title
    $grid=New-Object Windows.Controls.Grid;$grid.Margin='24'
    foreach($height in @('Auto','*','Auto')) {$r=New-Object Windows.Controls.RowDefinition;$r.Height=$height;$grid.RowDefinitions.Add($r)}
    $heading=New-Object Windows.Controls.TextBlock;$heading.Text=$Title;$heading.FontSize=21;$heading.FontWeight='SemiBold';$heading.Margin='0,0,0,16';$grid.Children.Add($heading)|Out-Null
    $scroll=New-Object Windows.Controls.ScrollViewer;$scroll.VerticalScrollBarVisibility='Auto';$scroll.HorizontalScrollBarVisibility='Disabled';$scroll.MaxHeight=[Math]::Max(140,$d.MaxHeight-180)
    $body=New-Object Windows.Controls.TextBlock;$body.Text=$Text;$body.TextWrapping='Wrap';$body.Margin='0,0,12,12';$scroll.Content=$body
    [Windows.Controls.Grid]::SetRow($scroll,1);$grid.Children.Add($scroll)|Out-Null
    $buttons=New-Object Windows.Controls.StackPanel;$buttons.Orientation='Horizontal';$buttons.HorizontalAlignment='Right';[Windows.Controls.Grid]::SetRow($buttons,2)
    $ok=New-Object Windows.Controls.Button;$ok.Content='OK';$ok.MinWidth=110;$ok.Style=$Owner.Resources['PrimaryButton']
    if($Confirm){
        $ok.Content='Continue'
        switch($Title){'Apply mod settings?' {$ok.Content='Apply settings'} 'Remove mod?' {$ok.Content='Restore game'} 'Take damage snapshot?' {$ok.Content='Take snapshot'} 'Change game folder?' {$ok.Content='Change folder'} 'Find game again?' {$ok.Content='Find game'}}
    } else {$ok.IsDefault=$true;$ok.IsCancel=$true}
    $ok.Add_Click({$d.DialogResult=$true}.GetNewClosure());$buttons.Children.Add($ok)|Out-Null
    if($Confirm) {
        $cancel=New-Object Windows.Controls.Button;$cancel.Content='Cancel';$cancel.MinWidth=110;$cancel.IsDefault=$true;$cancel.IsCancel=$true
        $cancel.Add_Click({$d.DialogResult=$false}.GetNewClosure());$buttons.Children.Add($cancel)|Out-Null
        $d.Add_ContentRendered({[void]$cancel.Focus()}.GetNewClosure())
    }
    $grid.Children.Add($buttons)|Out-Null;$d.Content=$grid
    return ($d.ShowDialog() -eq $true)
}
function Show-ACRDarkFolderPicker($Owner,[string]$CurrentPath) {
    $d=New-ACRDarkDialog $Owner 'Choose game folder' 760
    $stack=New-Object Windows.Controls.StackPanel;$stack.Margin='24'
    $title=New-Object Windows.Controls.TextBlock;$title.Text='Choose your ACR installation';$title.FontSize=21;$title.FontWeight='SemiBold';$stack.Children.Add($title)|Out-Null
    $help=New-Object Windows.Controls.TextBlock;$help.Text='Use a detected installation, paste a folder, or browse. Choosing a folder does not install or remove anything.';$help.Style=$Owner.Resources['HelpText'];$stack.Children.Add($help)|Out-Null
    $found=@(Get-ACRInstallCandidates)
    $list=New-Object Windows.Controls.ComboBox;$list.ItemsSource=$found;$list.DisplayMemberPath='Label';$list.SelectedValuePath='GameRoot';$list.ToolTip='Detected installations; your saved folder is listed first.'
    $stack.Children.Add($list)|Out-Null
    $label=New-Object Windows.Controls.TextBlock;$label.Text='Game folder';$label.FontWeight='SemiBold';$stack.Children.Add($label)|Out-Null
    $box=New-Object Windows.Controls.TextBox;$box.Text=$CurrentPath;$box.Margin='0,6,0,12';$box.MinHeight=42;$stack.Children.Add($box)|Out-Null
    if($found.Count -eq 0){$list.Visibility='Collapsed'}
    elseif($CurrentPath){$list.SelectedValue=$CurrentPath}
    else {$list.SelectedIndex=0;$box.Text=[string]$list.SelectedValue}
    $list.Add_SelectionChanged({if($null -ne $list.SelectedValue){$box.Text=[string]$list.SelectedValue}}.GetNewClosure())
    $errorText=New-Object Windows.Controls.TextBlock;$errorText.Foreground='#FFB3AF';$errorText.TextWrapping='Wrap';$errorText.Margin='0,0,0,12';$stack.Children.Add($errorText)|Out-Null
    $buttons=New-Object Windows.Controls.WrapPanel
    $browse=New-Object Windows.Controls.Button;$browse.Content='Browse folders...'
    $browse.Add_Click({
        $picker=New-Object Windows.Forms.FolderBrowserDialog
        try {
            $picker.Description='Select the Assetto Corsa Rally game folder.';$picker.ShowNewFolderButton=$false
            if([IO.Directory]::Exists($box.Text)){$picker.SelectedPath=$box.Text}
            if($picker.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){$box.Text=$picker.SelectedPath;$errorText.Text=''}
        } catch {$errorText.Text=$_.Exception.Message} finally {$picker.Dispose()}
    }.GetNewClosure());$buttons.Children.Add($browse)|Out-Null
    $use=New-Object Windows.Controls.Button;$use.Content='Use this folder';$use.Style=$Owner.Resources['PrimaryButton'];$use.IsDefault=$true
    $use.Add_Click({
        try {
            $p=ConvertTo-ACRLocalPath $box.Text
            if(-not (Test-ACRGameRoot $p)){throw 'This folder is missing the expected ACR executable or game containers. Choose the main Assetto Corsa Rally folder.'}
            Assert-ACRNoReparse $p
            $d.Tag=$p;$d.DialogResult=$true
        } catch {$errorText.Text=$_.Exception.Message}
    }.GetNewClosure());$buttons.Children.Add($use)|Out-Null
    $cancel=New-Object Windows.Controls.Button;$cancel.Content='Cancel';$cancel.IsCancel=$true
    $cancel.Add_Click({$d.DialogResult=$false}.GetNewClosure());$buttons.Children.Add($cancel)|Out-Null
    $stack.Children.Add($buttons)|Out-Null
    $scroll=New-Object Windows.Controls.ScrollViewer;$scroll.VerticalScrollBarVisibility='Auto';$scroll.HorizontalScrollBarVisibility='Disabled';$scroll.Content=$stack;$d.Content=$scroll
    if($d.ShowDialog() -eq $true){return [string]$d.Tag}
    return $null
}
Export-ModuleMember -Function Initialize-ACRDarkWindow,Show-ACRDarkPrompt,Show-ACRDarkFolderPicker
