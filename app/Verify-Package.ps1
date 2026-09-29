# Integrity checking detects incomplete/changed files; it is not a publisher signature.
[CmdletBinding()]param([switch]$Quiet)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
try {
 $root=[IO.Path]::GetFullPath($PSScriptRoot);$manifest=Join-Path $root 'package-integrity.json'
 if((Get-Item -LiteralPath $manifest).Length -gt 2097152){throw 'Invalid package inventory size.'}
 $m=[IO.File]::ReadAllText($manifest)|ConvertFrom-Json
 if($m.Tool -cne 'GripHappens' -or $m.Version -cne '1.0.1' -or @($m.Files).Count -lt 20 -or @($m.Files).Count -gt 2000){throw 'Wrong or incomplete package inventory.'}
 $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
 foreach($f in $m.Files){
  $relative=[string]$f.Path
  if($relative -match '(^[\\/]|:|(^|[\\/])\.\.([\\/]|$))' -or -not $seen.Add($relative)){throw 'Unsafe or duplicate package entry.'}
  $p=[IO.Path]::GetFullPath((Join-Path $root $relative));if(-not $p.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Package entry escaped its folder.'}
  $item=Get-Item -LiteralPath $p -Force
  if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -ne [long]$f.Length -or $f.SHA256 -cnotmatch '^[a-f0-9]{64}$'){throw ('Package file missing or changed: '+$relative)}
  if((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() -cne $f.SHA256){throw ('Package file changed: '+$relative)}
 }
 $parent=Split-Path $root
 foreach($f in $m.RootFiles){
  if([IO.Path]::GetFileName([string]$f.Path) -cne [string]$f.Path -or $f.Path -match '[:\\/]'){throw 'Unsafe launcher inventory.'}
  $p=Join-Path $parent $f.Path;$item=Get-Item -LiteralPath $p -Force
  if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -ne [long]$f.Length -or (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() -cne $f.SHA256){throw ('Launcher or guide changed: '+$f.Path)}
 }
 if(-not $Quiet){Write-Host ('PASS package integrity: '+$m.Files.Count+' application files and '+$m.RootFiles.Count+' launchers/guides.')}
 exit 0
} catch {Write-Host ('Package verification failed: '+$_.Exception.Message);exit 1}
