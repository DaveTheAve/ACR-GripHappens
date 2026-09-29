# Play submits only the fixed ACR Steam launch request after a fresh read-only check.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Initialize-ACRPlayTokenReader {
 if('GripHappensPlayToken' -as [type]){return}
 Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class GripHappensPlayToken {
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr p,uint access,out IntPtr t);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(IntPtr t,int cls,out int value,int size,out int used);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 public static bool Elevated(int pid) {
  IntPtr p=OpenProcess(0x1000,false,pid),t=IntPtr.Zero;
  if(p==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
  try {
   if(!OpenProcessToken(p,8,out t))throw new Win32Exception(Marshal.GetLastWin32Error());
   int flag,used;if(!GetTokenInformation(t,20,out flag,4,out used))throw new Win32Exception(Marshal.GetLastWin32Error());
   return flag!=0;
  }finally{if(t!=IntPtr.Zero)CloseHandle(t);CloseHandle(p);}
 }
}
'@
}
function Get-ACRPlayProcessRunning {
 return (@(Get-Process -Name 'acr' -ErrorAction SilentlyContinue).Count -gt 0)
}
function Test-ACRPlayOfflinePreference($Users,[uint32]$ActiveAccount) {
 if($ActiveAccount -eq 0 -or $Users -isnot [Collections.IDictionary]){return $false}
 $matches=@($Users.Keys|Where-Object {$_ -match '^7656119[0-9]{10}$' -and ([uint64]$_ -band [uint64]4294967295) -eq $ActiveAccount})
 if($matches.Count -ne 1){return $false}
 $entry=$Users[$matches[0]]
 return ($entry -is [Collections.IDictionary] -and $entry.Contains('WantsOfflineMode') -and [string]$entry['WantsOfflineMode'] -ceq '1')
}
function Get-ACRPlayContext([string]$GameRoot) {
 Assert-ACRWindows
 if(Test-ACRAdministrator){throw 'Open Grip Happens normally, not as administrator, to use Play. Apply and Restore still request permission separately.'}
 if(Get-ACRPlayProcessRunning){throw 'ACR is already running. No second launch was requested.'}
 $game=ConvertTo-ACRLocalPath $GameRoot;Assert-ACRNoReparse $game
 $steamReg=Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction Stop
 if($null -eq $steamReg.PSObject.Properties['SteamPath']){throw 'Steam is not registered for this Windows account.'}
 $steam=ConvertTo-ACRLocalPath ([string]$steamReg.SteamPath)
 $exe=Join-Path $steam 'steam.exe';Assert-ACRNoReparse $exe
 $active=Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam\ActiveProcess' -ErrorAction Stop
 if($null -eq $active.PSObject.Properties['pid'] -or $null -eq $active.PSObject.Properties['ActiveUser']){throw 'Open Steam and sign in using Offline Mode before playing.'}
 if([int]$active.pid -le 0){throw 'Open Steam in Offline Mode first, then click Play ACR.'}
 $client=Get-Process -Id ([int]$active.pid) -ErrorAction Stop
 if(-not [string]::Equals($client.MainModule.FileName,$exe,[StringComparison]::OrdinalIgnoreCase)){throw 'The active Steam client does not match its registered installation.'}
 Initialize-ACRPlayTokenReader
 if([GripHappensPlayToken]::Elevated($client.Id)){throw 'Restart Steam normally, not as administrator, before using Play ACR.'}
 $libraries=New-Object 'Collections.Generic.List[string]';$libraries.Add($steam)
 $vdf=Join-Path $steam 'steamapps\libraryfolders.vdf'
 if([IO.File]::Exists($vdf)){
  Assert-ACRNoReparse $vdf
  $all=ConvertFrom-ACRValveText ([IO.File]::ReadAllText($vdf))
  if($all.Contains('libraryfolders')){foreach($item in $all['libraryfolders'].GetEnumerator()){
   if($item.Key -notmatch '^\d+$'){continue};$lib=$item.Value
   if($lib -is [Collections.IDictionary]){if(-not $lib.Contains('path')){continue};$lib=$lib['path']}
   $path=ConvertTo-ACRLocalPath ([string]$lib);if(-not $libraries.Contains($path)){$libraries.Add($path)}
  }}
 }
 $registered=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
 foreach($lib in $libraries){
  $acf=Join-Path $lib 'steamapps\appmanifest_3917090.acf'
  if(-not [IO.File]::Exists($acf)){continue};Assert-ACRNoReparse $acf
  if((Get-Item -LiteralPath $acf).Length -gt 2097152){throw 'Steam app manifest is unexpectedly large.'}
  $kv=ConvertFrom-ACRValveText ([IO.File]::ReadAllText($acf))
  if(-not $kv.Contains('AppState')){throw 'Steam app registration is incomplete.'};$a=$kv['AppState']
  if(-not $a.Contains('appid') -or [string]$a['appid'] -cne '3917090' -or -not $a.Contains('installdir')){throw 'Steam app registration does not identify ACR.'}
  $common=Join-Path $lib 'steamapps\common';$installed=ConvertTo-ACRLocalPath (Join-Path $common ([string]$a['installdir']))
  if(-not (Test-ACRUnderPath $installed $common)){throw 'Invalid Steam installation path.'}
  if(Test-ACRGameRoot $installed){[void]$registered.Add($installed)}
 }
 if($registered.Count -ne 1 -or -not $registered.Contains($game)){throw 'Play requires the selected folder to be the single ACR installation registered with this Steam client. Choose its Steam-library folder.'}
 $login=Join-Path $steam 'config\loginusers.vdf';Assert-ACRNoReparse $login
 $users=ConvertFrom-ACRValveText ([IO.File]::ReadAllText($login))
 if(-not $users.Contains('users') -or -not (Test-ACRPlayOfflinePreference $users['users'] ([uint32]$active.ActiveUser))){throw 'Choose Steam > Go Offline first, then click Play ACR. The tool does not change Steam or network settings.'}
 return [pscustomobject]@{GameRoot=$game;SteamExe=$exe;AppId='3917090';Arguments='-applaunch 3917090';OfflinePreferenceConfirmed=$true}
}
function Assert-ACRPlayReport($Core,[string]$GameRoot) {
 if($null -ne $Core){$Core=$Core|ConvertTo-Json -Depth 16|ConvertFrom-Json}
 if($null -eq $Core -or $Core.Status -cne 'Checked' -or $Core.Action -cne 'Check' -or $Core.Tool -cne 'GripHappens'){throw 'Play requires a successful fresh read-only file check.'}
 if(-not [string]::Equals($Core.GameRoot,$GameRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'The launch folder differs from the verified game folder.'}
 if($Core.PreviousWriteJournalPresent -or $Core.Before.State -eq 'MixedOrInterrupted' -or $Core.Before.NativeModules -eq 'MixedOrInterrupted'){throw 'Restore the interrupted installation before playing.'}
 $settings=Get-ACRDesktopSettingsFromReport $Core
 if($null -eq $settings){throw 'The installed settings could not be verified for Play.'}
 if(-not (Test-ACRDesktopStockSelection $settings) -and -not $Core.VerifiedConfiguration.GameLocalStartupGuard){throw 'The installed modification lacks its game-local startup guard. Apply the current release or Restore before playing.'}
 if($Core.ExecutableSHA256 -notmatch '^[a-f0-9]{64}$' -or $Core.IndexSHA256 -notmatch '^[a-f0-9]{64}$'){throw 'The file check did not return complete fingerprints.'}
}
function Submit-ACRSteamPlay([string]$SteamExe) {
 # User-requested Play button: launch only the registered ACR app through Steam.
 $start=New-Object Diagnostics.ProcessStartInfo
 $start.FileName=$SteamExe
 $start.Arguments='-applaunch 3917090'
 $start.WorkingDirectory=Split-Path -Parent $SteamExe
 $start.UseShellExecute=$false
 $process=[Diagnostics.Process]::Start($start)
 if($null -eq $process){throw 'Steam did not accept the launch request.'}
 $process.Dispose()
}
function Invoke-ACRVerifiedPlay($Core,[string]$GameRoot) {
 $lock=$null
 try {
  $lock=Enter-ACROperation
  Assert-ACRPlayReport $Core $GameRoot
  $context=Get-ACRPlayContext $GameRoot
  $exe=Join-Path $context.GameRoot 'acr\Binaries\Win64\acr.exe'
  $index=Join-Path $context.GameRoot 'acr\Content\Paks\pakchunk1-Windows.utoc'
  if((Get-ACRFileHash $exe) -cne $Core.ExecutableSHA256 -or (Get-ACRFileHash $index) -cne $Core.IndexSHA256){throw 'Game files changed after the check. Nothing was launched; click Play again after Steam finishes its work.'}
  Submit-ACRSteamPlay $context.SteamExe
  return [pscustomobject]@{Requested=$true;AppId='3917090';GameRoot=$context.GameRoot}
 } finally {Exit-ACROperation $lock}
}
Export-ModuleMember -Function Get-ACRPlay*,Test-ACRPlay*,Assert-ACRPlay*,Invoke-ACRVerifiedPlay
