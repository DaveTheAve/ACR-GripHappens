#Requires -Version 5.1
<# Recovery entrypoint independent of WPF and the DesktopTask log pipeline.
Uses the unchanged, exact-build core Restore action, never blind backup copies.
Existing backups are retained. Unknown builds/edits are not force-overwritten. #>
[CmdletBinding()]
param([string]$GameRoot='', [string]$RequestOwnerSid='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$code=1;$core=$null;$delegated=$false
try {
    Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Common.psm1') -ErrorAction Stop
    Assert-ACRWindows
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try {$sid=$identity.User.Value} finally {$identity.Dispose()}
    if($RequestOwnerSid -and $RequestOwnerSid -cne $sid) {throw 'Windows selected a different administrator account. Open the entire utility using that account so the backups stay together.'}
    if(-not (Test-ACRAdministrator)) {
        Write-Host 'Windows will ask for permission to restore the protected game files.'
        Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Desktop.psm1') -ErrorAction Stop
        $ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $args='-NoProfile -ExecutionPolicy Bypass -File '+(ConvertTo-ACRDesktopArgument $PSCommandPath)+' -RequestOwnerSid '+(ConvertTo-ACRDesktopArgument $sid)
        if($GameRoot){$args+=' -GameRoot '+(ConvertTo-ACRDesktopArgument $GameRoot)}
        $p=Start-Process -FilePath $ps -ArgumentList $args -Verb RunAs -Wait -PassThru -ErrorAction Stop
        $delegated=$true
        exit $p.ExitCode
    }
    & (Join-Path $PSScriptRoot 'Verify-Package.ps1') -Quiet
    if($LASTEXITCODE -ne 0){throw 'Package verification failed. Extract the complete ZIP into a new folder.'}
    Import-Module (Join-Path $PSScriptRoot 'modules\ACR.Desktop.psm1') -ErrorAction Stop
    Write-Host '';Write-Host 'Grip Happens - Restore original game files' -ForegroundColor Cyan
    Write-Host 'Close ACR. Steam may stay open. Saves and existing backups are NOT deleted.'
    Write-Host 'This removes every mod patch, including the startup and HTTP guards.'
    Write-Host 'It does not change firewall rules or Steam settings.'
    $location=$null
    try {$location=Resolve-ACRInstall $GameRoot ''} catch {Write-Warning 'Choose the installation to restore below.'}
    while($true) {
        if($null -eq $location) {
            $answer=Read-Host 'Paste the Assetto Corsa Rally folder, or press Enter to cancel'
            if([string]::IsNullOrWhiteSpace($answer)){$code=0;break}
            try {$location=Resolve-ACRInstall $answer ''} catch {Write-Warning $_.Exception.Message;continue}
        }
        $GameRoot=$location.GameRoot
        Write-Host '';Write-Host ('Game folder: '+$GameRoot)
        Write-Host ('Backups: '+(Get-ACRDesktopBackupFolder $GameRoot))
        Write-Host '1. Restore ORIGINAL game files now'
        Write-Host '2. Choose a different game folder'
        Write-Host 'Anything else cancels without changing game files.'
        $answer=(Read-Host 'Choose').Trim()
        if($answer -eq '2'){$location=$null;continue}
        if($answer -ne '1'){$code=0;break}
        # No preflight requirement: recovery must remain accessible if optional
        # desktop diagnostics fail. The core still validates all game bytes.
        $core=& (Join-Path $PSScriptRoot 'Grip-Happens.Core.ps1') -Action Restore -GameRoot $GameRoot
        if($null -eq $core -or $core.Status -notin @('Restored','AlreadyStock')) {
            if($null -ne $core -and $null -ne $core.PSObject.Properties['Error']){throw ([string]$core.Error)}
            throw 'The engine did not verify restoration.'
        }
        $settings=Get-ACRDesktopSettingsFromReport $core
        if(-not (Test-ACRDesktopStockSelection $settings) -or $core.VerifiedConfiguration.GameLocalStartupGuard -or $core.VerifiedConfiguration.NativeHTTPRejection){throw 'Original state was not fully verified. Do not start ACR.'}
        $code=0
        Write-Host '';Write-Host 'Original game files restored and verified.' -ForegroundColor Green
        Write-Host 'All Grip Happens patches are removed. Your saves and backups were kept.'
        break
    }
} catch {
    Write-Host '';Write-Host ('Recovery stopped: '+$_.Exception.Message) -ForegroundColor Red
    Write-Host 'Do not assume the game is restored. Do not copy old backups over an updated game.'
    Write-Host 'Use Steam file-integrity verification if the supported original state cannot be verified.'
} finally {
    if($null -ne $core) {
        try {Save-ACRJson (Join-Path (Get-ACRUserStateRoot) 'latest-diagnostic.json') ([ordered]@{Tool='Grip_Happens_Launcher';Version='1.0.1';Action='Restore';Status=$(if($code -eq 0){'Success'}else{'Failed'});Phase='Restore';Core=$core})}
        catch {Write-Warning 'The additional launcher summary could not be saved; the core printed its own report location.'}
    }
    # A successfully delegated child displays its own result. Startup/UAC
    # failures in this process remain visible instead of closing immediately.
    if(-not $delegated){[void](Read-Host 'Press Enter to close')}
}
exit $code
