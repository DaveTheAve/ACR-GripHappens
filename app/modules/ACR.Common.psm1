#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ACRVersion = '1.0.1'
$script:RuntimeManifestHash = 'cdbb1c1d823a91030c5e9a731f440c7db8d4038966d1641c86b98943c056b28d'
$script:RuntimeNativeHash = 'b01f676796632e9bd2c41e4270eb0121918b44af3ab7230f0531ec41a6be97c1'

function Get-ACRHash([byte[]]$Bytes) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($h.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $h.Dispose() }
}
function Get-ACRFileHash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}
function Assert-ACRWindows {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) {
        throw 'This tool requires 64-bit Windows PowerShell 5.1 on Windows. No changes were made.'
    }
}
function Test-ACRAdministrator {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $id.Dispose() }
}
function Assert-ACRAdministrator {
    Assert-ACRWindows
    if (-not (Test-ACRAdministrator)) { throw 'Administrator approval is required to update protected game files. Run Grip Happens.cmd.' }
}
function ConvertTo-ACRLocalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An empty path is not a game location.' }
    $p = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ($p -notmatch '^[A-Za-z]:[\\/]') { throw 'Select an absolute local drive path, not a network share or device path.' }
    $p = [IO.Path]::GetFullPath($p).TrimEnd('\')
    if ($p -match '[\*\?\[\]]') { throw 'Wildcard characters in installation paths are not supported.' }
    if ($p -match '^\\\\' -or $p.Length -lt 4) { throw 'A whole drive or network path is not a valid installation folder.' }
    return $p
}
function Test-ACRUnderPath([string]$Path, [string]$Root) {
    $p = [IO.Path]::GetFullPath($Path); $r = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return $p.StartsWith(($r+'\'), [StringComparison]::OrdinalIgnoreCase)
}
function Assert-ACRNoReparse([string]$Path) {
    # Refuse ambiguous link aliases for exact-file patching and recovery.
    $p = [IO.Path]::GetFullPath($Path)
    while ($p -and [IO.Path]::GetPathRoot($p) -ne $p) {
        $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Junctions/symlinks are not supported for protected game or Steam paths. Select the physical installation path.'
        }
        $p = Split-Path -Parent $p
    }
}
# Decode authenticated, deduplicated patch tables. Never caches game-file trust.
function Expand-ACRNativeByteTables($Manifest) {
    $n=$Manifest.native_modules
    if($null -eq $n.PSObject.Properties['byte_table_encoding']){return}
    if($n.byte_table_encoding -cne 'pool-v1'){throw 'Unsupported native-byte table encoding.'}
    if(-not ('GripHappensBytePoolV1' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
public static class GripHappensBytePoolV1 {
 public static string[] Expand(object[] indices,object[] pool,int count) {
  if(count<1||count>1000000||indices==null||indices.Length!=count||pool==null||pool.Length<1||pool.Length>count)
   throw new ArgumentException("Native byte table dimensions rejected.");
  string[] choices=new string[pool.Length];int width=-1;
  for(int i=0;i<pool.Length;i++) {
   string s=pool[i] as string;
   if(s==null||s.Length<2||s.Length>131072||(s.Length&1)!=0||(width!=-1&&s.Length!=width))
    throw new ArgumentException("Native byte choice extent rejected.");
   for(int j=0;j<s.Length;j++)if(!((s[j]>='0'&&s[j]<='9')||(s[j]>='a'&&s[j]<='f')))
    throw new ArgumentException("Native byte choice is not canonical hexadecimal.");
   choices[i]=s;width=s.Length;
  }
  string[] result=new string[count];
  for(int i=0;i<count;i++) {
   if(!(indices[i] is Int32))throw new ArgumentException("Native byte index type rejected.");
   int k=(Int32)indices[i];if(k<0||k>=choices.Length)throw new ArgumentException("Native byte index outside pool.");
   result[i]=choices[k];
  }
  return result;
 }
}
'@
    }
    foreach($p in $n.patches){$p.bytes=[GripHappensBytePoolV1]::Expand([object[]]$p.bytes,[object[]]$p.byte_pool,[int]$n.states.Count)}
    $n.byte_table_encoding='expanded-pool-v1'
}

function Initialize-ACRRuntimeNative([string]$PackageRoot,$Manifest) {
    if($null -eq $Manifest.runtime_native){throw 'Runtime native catalogue metadata is missing.'}
    $path=Join-Path $PackageRoot ([string]$Manifest.runtime_native.file)
    [byte[]]$bytes=[IO.File]::ReadAllBytes($path)
    if((Get-ACRHash $bytes) -cne $script:RuntimeNativeHash -or $script:RuntimeNativeHash -cne [string]$Manifest.runtime_native.sha256){throw 'Runtime native catalogue integrity failure.'}
    if(-not ('GripHappensRuntimeNativeV1' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class GripHappensRuntimeNativeV1 {
 static byte[] data; static int count,patches; const int Header=16,Record=36;
 public static void Load(byte[] b,int expectedCount,int expectedPatches) {
  if(b==null||b.Length<Header||b[0]!='G'||b[1]!='H'||b[2]!='R'||b[3]!='N'||b[4]!='1'||b[5]!='9'||b[6]!='0'||b[7]!='1')throw new ArgumentException("Runtime native header rejected.");
  count=BitConverter.ToInt32(b,8);patches=BitConverter.ToInt32(b,12);
  long expected=Header+(long)count*Record+(long)count*patches*2;
  if(count!=expectedCount||patches!=expectedPatches||expected!=b.LongLength)throw new ArgumentException("Runtime native dimensions rejected.");
  data=b;
 }
 static void State(int i){if(data==null||i<0||i>=count)throw new ArgumentOutOfRangeException("i");}
 public static int Count {get{return count;}} public static int PatchCount {get{return patches;}}
 public static uint Code(int i){State(i);return BitConverter.ToUInt32(data,Header+i*Record+32);}
 public static string Hash(int i){State(i);char[] c=new char[64];const string h="0123456789abcdef";int o=Header+i*Record;for(int j=0;j<32;j++){byte v=data[o+j];c[j*2]=h[v>>4];c[j*2+1]=h[v&15];}return new string(c);}
 static int Nib(char c){if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;return -1;}
 public static int FindHash(string hex){
  if(hex==null||hex.Length!=64)return -1;byte[] q=new byte[32];
  for(int j=0;j<32;j++){int a=Nib(hex[j*2]),b=Nib(hex[j*2+1]);if(a<0||b<0)return -1;q[j]=(byte)((a<<4)|b);}
  for(int i=0;i<count;i++){int o=Header+i*Record;bool ok=true;for(int j=0;j<32;j++)if(data[o+j]!=q[j]){ok=false;break;}if(ok)return i;}return -1;
 }
 public static int FindCode(uint code){for(int i=0;i<count;i++)if(Code(i)==code)return i;return -1;}
 public static int Choice(int patch,int state){State(state);if(patch<0||patch>=patches)throw new ArgumentOutOfRangeException("patch");long o=Header+(long)count*Record+((long)patch*count+state)*2;return data[o]|(data[o+1]<<8);}
 public static bool UniqueHashes(){var set=new HashSet<string>(StringComparer.Ordinal);for(int i=0;i<count;i++)if(!set.Add(Hash(i)))return false;return true;}
}
'@
    }
    [GripHappensRuntimeNativeV1]::Load($bytes,[int]$Manifest.runtime_native.count,[int]$Manifest.runtime_native.patch_count)
    $script:RuntimeNativeBaseCount=[GripHappensRuntimeNativeV1]::Count
    $Manifest.native_modules|Add-Member NoteProperty runtime_custom_states (New-Object 'Collections.Generic.List[object]') -Force
    foreach($patch in $Manifest.native_modules.patches){
        $patch|Add-Member NoteProperty runtime_custom_bytes (New-Object 'Collections.Generic.List[string]') -Force
    }
}
function Get-ACRRuntimeManifest([string]$PackageRoot) {
    [byte[]]$bytes=[IO.File]::ReadAllBytes((Join-Path $PackageRoot 'runtime-manifest.json'))
    if((Get-ACRHash $bytes) -cne $script:RuntimeManifestHash){throw 'Runtime manifest integrity failure. Re-extract the complete package.'}
    $m=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json
    if($m.schema -ne 6 -or $m.version -ne '1.0.1' -or $m.regions.Count -ne 114 -or $m.states.Count -ne 91 -or $m.runtime_native.schema -ne 1){throw 'Unexpected runtime manifest.'}
    if($m.native_modules.patches.Count -ne $m.runtime_native.patch_count){throw 'Runtime native patch table is incomplete.'}
    Initialize-ACRRuntimeNative $PackageRoot $m
    if([GripHappensRuntimeNativeV1]::Hash(0) -cne [string]$m.exe.sha256){throw 'Runtime original executable fingerprint is missing.'}
    return $m
}
function Get-ACRPatchHex($Patch,[int]$StateIndex) {
    if($null -eq $Patch -or $StateIndex -lt 0){throw 'Patch state index outside table.'}
    if($null -ne $Patch.PSObject.Properties['runtime_patch_index']){
        if($StateIndex -lt $script:RuntimeNativeBaseCount){
            $choice=[GripHappensRuntimeNativeV1]::Choice([int]$Patch.runtime_patch_index,$StateIndex)
            if($choice -lt 0 -or $choice -ge $Patch.byte_pool.Count){throw 'Runtime native byte-pool index outside table.'}
            $hex=[string]$Patch.byte_pool[$choice]
        } else {
            $custom=$StateIndex-$script:RuntimeNativeBaseCount
            if($custom -lt 0 -or $custom -ge $Patch.runtime_custom_bytes.Count){throw 'Runtime custom patch state outside table.'}
            $hex=[string]$Patch.runtime_custom_bytes[$custom]
        }
    } else {
        if($StateIndex -ge $Patch.bytes.Count){throw 'Patch state index outside table.'}
        $value=$Patch.bytes[$StateIndex]
        if($value -is [string]){$hex=[string]$value}
        elseif($null -ne $Patch.PSObject.Properties['byte_pool']){
            $index=[int]$value
            if($index -lt 0 -or $index -ge $Patch.byte_pool.Count){throw 'Native byte-pool index outside table.'}
            $hex=[string]$Patch.byte_pool[$index]
        } else {$hex=[string]$value}
    }
    if($hex.Length -lt 2 -or ($hex.Length%2) -ne 0 -or $hex -notmatch '^[0-9a-f]+$'){throw 'Patch byte value is not canonical hexadecimal.'}
    return $hex
}
function Get-ACRPatchVariantHexes($Patch) {
    $seen=New-Object 'Collections.Generic.HashSet[string]'
    $out=New-Object 'Collections.Generic.List[string]'
    if($null -ne $Patch.PSObject.Properties['runtime_patch_index']){
        foreach($hex in $Patch.byte_pool){$v=[string]$hex;if($seen.Add($v)){$out.Add($v)}}
        foreach($hex in $Patch.runtime_custom_bytes){$v=[string]$hex;if($seen.Add($v)){$out.Add($v)}}
    } elseif($null -ne $Patch.PSObject.Properties['byte_pool']){
        foreach($hex in $Patch.byte_pool){$v=[string]$hex;if($seen.Add($v)){$out.Add($v)}}
        foreach($value in $Patch.bytes){if($value -is [string]){$v=[string]$value;if($seen.Add($v)){$out.Add($v)}}}
    } else {
        foreach($hex in $Patch.bytes){$v=[string]$hex;if($seen.Add($v)){$out.Add($v)}}
    }
    return $out.ToArray()
}
function Get-ACRNativeStateCount($Manifest) {
    if($null -ne $Manifest.runtime_native){return ([GripHappensRuntimeNativeV1]::Count+$Manifest.native_modules.runtime_custom_states.Count)}
    return $Manifest.native_modules.states.Count
}
function Get-ACRNativeState($Manifest,[int]$Index) {
    if($null -eq $Manifest.runtime_native){return $Manifest.native_modules.states[$Index]}
    $base=[GripHappensRuntimeNativeV1]::Count
    if($Index -ge $base){
        $custom=$Index-$base
        if($custom -lt 0 -or $custom -ge $Manifest.native_modules.runtime_custom_states.Count){throw 'Runtime custom native-state index outside table.'}
        return $Manifest.native_modules.runtime_custom_states[$custom]
    }
    if($Index -lt 0){throw 'Runtime native-state index outside table.'}
    [uint32]$code=[GripHappensRuntimeNativeV1]::Code($Index)
    [uint32]$raw=$code -band 0x0fffffff
    $defs=@(
      @('visual_damage',@('Off','Enhanced','Strong')),
      @('collision_damage',@('Stock','Sensitive','Strong')),
      @('startup_guard',@($false,$true)),
      @('tyre_damage',@('Stock','Native')),
      @('mechanical_failures',@('Stock','Earlier85','Earlier90')),
      @('brake_wear',@('Stock','Native')),
      @('detachment',@('Stock','Easier','Aggressive')),
      @('critical_damage',@('Stock','Cumulative')),
      @('cooling_routing',@('Stock','EngineBay')),
      @('engine_impact',@('Stock','Matched')),
      @('power_response',@('Stock','Progressive')),
      @('wheel_impact',@('Stock','Localized','Bent')),
      @('gearbox_damage',@('Stock','Grinding','Impact','Responsive','Mechanical','Engagement','Consequences'))
    )
    $v=[ordered]@{}
    foreach($def in $defs){$choices=@($def[1]);$pick=[int]($raw % $choices.Count);$raw=[uint32][math]::Floor($raw/$choices.Count);$v[[string]$def[0]]=$choices[$pick]}
    $installable=($code -band 0x10000000) -ne 0
    $visualMult=@{Off=1.0;Enhanced=1.5;Strong=2.0}[$v.visual_damage]
    $collisionMult=@{Stock=1.0;Sensitive=2.0;Strong=3.0}[$v.collision_damage]
    $tyreRate=if($v.tyre_damage -eq 'Native'){1.0}else{$null}
    $failure=if($v.mechanical_failures -eq 'Earlier85'){0.85}elseif($v.mechanical_failures -eq 'Earlier90'){0.9}else{$null}
    $brake=if($v.brake_wear -eq 'Native'){1.0}else{$null}
    $attach=if($v.detachment -eq 'Easier'){0.75}elseif($v.detachment -eq 'Aggressive'){0.5}else{$null}
    $critical=if($v.critical_damage -eq 'Cumulative'){$true}else{$null}
    $engineFactor=if($v.engine_impact -eq 'Matched'){4.0}else{1.0}
    $gearImpact=if($v.gearbox_damage -in @('Impact','Responsive','Mechanical','Engagement','Consequences')){0.5}else{0.0}
    $gearGrind=if($v.gearbox_damage -ne 'Stock'){1.0}else{$null}
    $id='RuntimeNative='+$Index+';Visual='+$v.visual_damage+';Collision='+$v.collision_damage+';Guard='+$(if($v.startup_guard){'On'}else{'Off'})+';Tyre='+$v.tyre_damage+';Mechanical='+$v.mechanical_failures+';Brake='+$v.brake_wear+';Detach='+$v.detachment+';Critical='+$v.critical_damage+';Cooling='+$v.cooling_routing+';Engine='+$v.engine_impact+';Power='+$v.power_response+';Wheel='+$v.wheel_impact+';Gearbox='+$v.gearbox_damage
    return [pscustomobject]@{
      id=$id;visual_damage=$v.visual_damage;collision_damage=$v.collision_damage;visual_multiplier=$visualMult;collision_multiplier=$collisionMult
      exe_sha256=[GripHappensRuntimeNativeV1]::Hash($Index);startup_guard=[bool]$v.startup_guard;http_request_block=[bool]$v.startup_guard
      tyre_damage=$v.tyre_damage;mechanical_failures=$v.mechanical_failures;brake_wear=$v.brake_wear;detachment=$v.detachment
      tyre_compression_rate_override=$tyreRate;failure_health_threshold_override=$failure;brake_consumption_gate_override=$brake;attachment_global_threshold_override=$attach
      installable=$installable
      critical_damage=$v.critical_damage;critical_admission_override=$critical;cooling_routing=$v.cooling_routing;engine_impact=$v.engine_impact
      engine_collision_factor=$engineFactor;power_response=$v.power_response;wheel_impact=$v.wheel_impact;gearbox_damage=$v.gearbox_damage
      gearbox_impact_fraction=$gearImpact;gearbox_grinding_rate_override=$gearGrind
    }
}
function Find-ACRNativeStateHash($Manifest,[string]$Hash) {
    if($null -eq $Manifest.runtime_native){
        for($i=0;$i -lt $Manifest.native_modules.states.Count;$i++){if($Manifest.native_modules.states[$i].exe_sha256 -ceq $Hash){return $i}}
        return -1
    }
    $index=[GripHappensRuntimeNativeV1]::FindHash($Hash)
    if($index -ge 0){return $index}
    $base=[GripHappensRuntimeNativeV1]::Count
    for($i=0;$i -lt $Manifest.native_modules.runtime_custom_states.Count;$i++){if($Manifest.native_modules.runtime_custom_states[$i].exe_sha256 -ceq $Hash){return ($base+$i)}}
    return -1
}
function Get-ACRNativeSelectionCode([string]$Visual,[string]$Collision,[bool]$Guard,[string]$Tyre,[string]$Mechanical,[string]$Brake,[string]$Detach,[string]$Critical,[string]$Cooling,[string]$Engine,[string]$Power,[string]$Wheel,[string]$Gearbox) {
    $pairs=@(
      @($Visual,@('Off','Enhanced','Strong')),@($Collision,@('Stock','Sensitive','Strong')),@($Guard,@($false,$true)),
      @($Tyre,@('Stock','Native')),@($Mechanical,@('Stock','Earlier85','Earlier90')),@($Brake,@('Stock','Native')),
      @($Detach,@('Stock','Easier','Aggressive')),@($Critical,@('Stock','Cumulative')),@($Cooling,@('Stock','EngineBay')),
      @($Engine,@('Stock','Matched')),@($Power,@('Stock','Progressive')),@($Wheel,@('Stock','Localized','Bent')),
      @($Gearbox,@('Stock','Grinding','Impact','Responsive','Mechanical','Engagement','Consequences'))
    )
    [uint32]$code=0;[uint32]$mul=1
    foreach($pair in $pairs){$choices=@($pair[1]);$idx=[array]::IndexOf($choices,$pair[0]);if($idx -lt 0){throw 'Unknown native selection value.'};$code+=[uint32]($idx*$mul);$mul*=$choices.Count}
    return [uint32]($code -bor 0x10000000)
}
function Find-ACRNativeSelection($Manifest,[string]$Visual,[string]$Collision,[bool]$Guard,[string]$Tyre,[string]$Mechanical,[string]$Brake,[string]$Detach,[string]$Critical,[string]$Cooling,[string]$Engine,[string]$Power,[string]$Wheel,[string]$Gearbox) {
    if($null -eq $Manifest.runtime_native){
        for($i=0;$i -lt $Manifest.native_modules.states.Count;$i++){
            $n=$Manifest.native_modules.states[$i]
            if($n.installable -and $n.visual_damage -eq $Visual -and $n.collision_damage -eq $Collision -and [bool]$n.startup_guard -eq $Guard -and $n.tyre_damage -eq $Tyre -and $n.mechanical_failures -eq $Mechanical -and $n.brake_wear -eq $Brake -and $n.detachment -eq $Detach -and $n.critical_damage -eq $Critical -and $n.cooling_routing -eq $Cooling -and $n.engine_impact -eq $Engine -and $n.power_response -eq $Power -and $n.wheel_impact -eq $Wheel -and $n.gearbox_damage -eq $Gearbox){return $i}
        }
        return -1
    }
    [uint32]$code=Get-ACRNativeSelectionCode $Visual $Collision $Guard $Tyre $Mechanical $Brake $Detach $Critical $Cooling $Engine $Power $Wheel $Gearbox
    return [GripHappensRuntimeNativeV1]::FindCode($code)
}
function Add-ACRNativeCustomState($Manifest,$State) {
    if($null -eq $Manifest.runtime_native){$Manifest.native_modules.states+=@($State);return ($Manifest.native_modules.states.Count-1)}
    $Manifest.native_modules.runtime_custom_states.Add($State)
    return ([GripHappensRuntimeNativeV1]::Count+$Manifest.native_modules.runtime_custom_states.Count-1)
}
function Add-ACRNativeCustomPatchHex($Patch,[string]$Hex) {
    if($null -ne $Patch.PSObject.Properties['runtime_patch_index']){$Patch.runtime_custom_bytes.Add($Hex);return}
    $Patch.bytes+=@($Hex)
}

function Test-ACRGameRoot([string]$Path) {
    try {
        $p=ConvertTo-ACRLocalPath $Path
        foreach ($r in @('acr\Binaries\Win64\acr.exe','acr\Content\Paks\pakchunk1-Windows.utoc','acr\Content\Paks\pakchunk1-Windows.ucas')) {
            if (-not [IO.File]::Exists((Join-Path $p $r))) { return $false }
        }
        return $true
    } catch { return $false }
}
function Get-ACRUserStateRoot {
    $p = Join-Path $env:LOCALAPPDATA 'ACRMods\GripHappens\Launcher'
    [IO.Directory]::CreateDirectory($p) | Out-Null
    return $p
}
function Get-ACRBackupStateRoot([string]$GameRoot) {
    $normalized=ConvertTo-ACRLocalPath $GameRoot
    $key=(Get-ACRHash ([Text.Encoding]::UTF8.GetBytes($normalized.ToLowerInvariant()))).Substring(0,12)
    $current=Join-Path $env:LOCALAPPDATA ('ACRMods\GripHappens\Backups\'+$key)
    if ([IO.Directory]::Exists($current)) { return $current }
    return $current
}
function Get-ACRDownloads {
    try {
        $p=(Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($p) { return [Environment]::ExpandEnvironmentVariables($p) }
    } catch { }
    return (Join-Path $env:USERPROFILE 'Downloads')
}
function Save-ACRJson([string]$Path, $Value) {
    # PowerShell's $null can bind to String as an empty string. File.Replace
    # rejects that as a backup path. NullString supplies an actual CLR null on
    # Windows PowerShell 5.1 too. Keep the replace atomic; never delete-then-move.
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A JSON output path is required.' }
    $Path=[IO.Path]::GetFullPath($Path)
    $parent=Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temp=$Path+'.tmp.'+[Guid]::NewGuid().ToString('N')
    try {
        $json=$Value | ConvertTo-Json -Depth 32
        $encoding=New-Object Text.UTF8Encoding($false)
        [byte[]]$b=$encoding.GetBytes($json)
        $f=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $f.Write($b,0,$b.Length); $f.Flush($true) } finally { $f.Dispose() }
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,[System.Management.Automation.Language.NullString]::Value) } else { [IO.File]::Move($temp,$Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function ConvertFrom-ACRValveText([string]$Text) {
    # Valve KeyValues text: quoted/bare tokens, braces, // comments, \\ and \" escapes.
    # No eval, regex replacement script, binary VDF, conditionals or duplicate-key guessing.
    if ($Text.Length -gt 4194304) { throw 'Valve metadata is unexpectedly large.' }
    $tokens=New-Object 'Collections.Generic.List[string]'
    $i=0
    while ($i -lt $Text.Length) {
        $c=$Text[$i]
        if ([char]::IsWhiteSpace($c) -or [int]$c -eq 65279) { $i++; continue }
        if ($c -eq '/' -and $i+1 -lt $Text.Length -and $Text[$i+1] -eq '/') {
            while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }; continue
        }
        if ($c -eq '{' -or $c -eq '}') { $tokens.Add([string]$c); $i++; continue }
        if ($c -eq '"') {
            $i++; $s=New-Object Text.StringBuilder; $closed=$false
            while ($i -lt $Text.Length) {
                $c=$Text[$i]; $i++
                if ($c -eq '"') { $closed=$true; break }
                if ($c -eq '\' -and $i -lt $Text.Length -and ($Text[$i] -eq '\' -or $Text[$i] -eq '"')) {
                    [void]$s.Append($Text[$i]); $i++
                } else { [void]$s.Append($c) }
            }
            if (-not $closed) { throw 'Unterminated Valve metadata string.' }
            $tokens.Add($s.ToString()); continue
        }
        $start=$i
        while ($i -lt $Text.Length -and -not [char]::IsWhiteSpace($Text[$i]) -and $Text[$i] -ne '{' -and $Text[$i] -ne '}') { $i++ }
        if ($start -eq $i) { throw 'Invalid Valve metadata token.' }
        $tokens.Add($Text.Substring($start,$i-$start))
    }
    $cursor=@{ Position=0 }
    function Read-ACRValveBlock($Tokens,$Cursor,[int]$Depth,[bool]$Nested) {
        if ($Depth -gt 32) { throw 'Valve metadata nesting exceeds limit.' }
        $result=@{}
        while ($Cursor.Position -lt $Tokens.Count) {
            $key=$Tokens[$Cursor.Position]; $Cursor.Position++
            if ($key -eq '}') { if (-not $Nested) { throw 'Unexpected closing brace.' }; return $result }
            if ($key -eq '{' -or $Cursor.Position -ge $Tokens.Count) { throw 'Malformed Valve key/value pair.' }
            $value=$Tokens[$Cursor.Position]; $Cursor.Position++
            if ($value -eq '}') { throw 'Missing Valve value.' }
            if ($value -eq '{') { $value=Read-ACRValveBlock $Tokens $Cursor ($Depth+1) $true }
            if ($result.ContainsKey($key)) { throw 'Ambiguous duplicate Valve metadata key.' }
            $result[$key]=$value
        }
        if ($Nested) { throw 'Missing closing Valve metadata brace.' }
        return $result
    }
    return (Read-ACRValveBlock $tokens $cursor 0 $false)
}
function Get-ACRSteamRoots([string]$Preferred) {
    $candidates=New-Object 'Collections.Generic.List[string]'
    if ($Preferred) { $candidates.Add($Preferred) }
    foreach ($r in @(
        @('HKCU:\Software\Valve\Steam','SteamPath'),
        @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','InstallPath'),
        @('HKLM:\SOFTWARE\Valve\Steam','InstallPath'))) {
        try { $o=Get-ItemProperty -LiteralPath $r[0] -Name $r[1] -ErrorAction Stop; $v=$o.($r[1]); if ($v) { $candidates.Add([string]$v) } } catch { }
    }
    foreach ($pf in @(${env:ProgramFiles(x86)},$env:ProgramFiles)) { if ($pf) { $candidates.Add((Join-Path $pf 'Steam')) } }
    $out=New-Object 'Collections.Generic.List[string]'
    foreach ($c in $candidates) {
        try {
            $p=ConvertTo-ACRLocalPath $c
            if ([IO.File]::Exists((Join-Path $p 'steam.exe')) -and -not ($out -contains $p)) { $out.Add($p) }
        } catch { }
    }
    return $out.ToArray()
}
function Get-ACRInstalledGames([string[]]$SteamRoots) {
    $found=New-Object 'Collections.Generic.List[object]'
    foreach ($steam in $SteamRoots) {
        $libraries=New-Object 'Collections.Generic.List[string]'; $libraries.Add($steam)
        $vdf=Join-Path $steam 'steamapps\libraryfolders.vdf'
        if ([IO.File]::Exists($vdf)) {
            try {
                $kv=ConvertFrom-ACRValveText ([IO.File]::ReadAllText($vdf))
                if ($kv.ContainsKey('libraryfolders')) {
                    foreach ($entry in $kv['libraryfolders'].GetEnumerator()) {
                        if ($entry.Key -notmatch '^\d+$') { continue }
                        $v=$entry.Value
                        if ($v -is [Collections.IDictionary]) { if (-not $v.Contains('path')) { continue }; $v=$v['path'] }
                        $lib=ConvertTo-ACRLocalPath ([string]$v)
                        if (-not ($libraries -contains $lib)) { $libraries.Add($lib) }
                    }
                }
            } catch { Write-Warning 'A Steam library metadata file could not be parsed. Manual game-folder selection remains available.' }
        }
        foreach ($lib in $libraries) {
            $apps=Join-Path $lib 'steamapps'
            if (-not [IO.Directory]::Exists($apps)) { continue }
            $default=Join-Path $apps 'common\Assetto Corsa Rally'
            if (Test-ACRGameRoot $default) { $found.Add([pscustomobject]@{GameRoot=$default; SteamRoot=$steam; Source='Steam library'; AppId=$null}) }
            foreach ($acf in @(Get-ChildItem -LiteralPath $apps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue)) {
                try {
                    if ($acf.Length -gt 2097152) { continue }
                    $kv=ConvertFrom-ACRValveText ([IO.File]::ReadAllText($acf.FullName))
                    if (-not $kv.ContainsKey('AppState')) { continue }; $a=$kv['AppState']
                    if (-not $a.Contains('name') -or [string]$a['name'] -ine 'Assetto Corsa Rally' -or -not $a.Contains('installdir')) { continue }
                    $common=Join-Path $apps 'common'
                    $candidate=ConvertTo-ACRLocalPath (Join-Path $common ([string]$a['installdir']))
                    if (-not (Test-ACRUnderPath $candidate $common) -or -not (Test-ACRGameRoot $candidate)) { continue }
                    $id=$null; if ($a.Contains('appid') -and [string]$a['appid'] -match '^\d+$') { $id=[string]$a['appid'] }
                    $found.Add([pscustomobject]@{GameRoot=$candidate; SteamRoot=$steam; Source='Steam app manifest'; AppId=$id})
                } catch { }
            }
        }
    }
    return @($found.ToArray() | Sort-Object GameRoot -Unique)
}
function Add-ACRInstallCandidate($List,[string]$Path,[string]$SteamRoot,[string]$Source,[int]$Priority) {
    try {
        if (-not (Test-ACRGameRoot $Path)) { return }
        $p=ConvertTo-ACRLocalPath $Path
        Assert-ACRNoReparse $p
        if (@($List | Where-Object {$_.GameRoot -ieq $p}).Count -gt 0) { return }
        $steam=''
        if ($SteamRoot) {
            try { $s=ConvertTo-ACRLocalPath $SteamRoot; if ([IO.File]::Exists((Join-Path $s 'steam.exe'))) { $steam=$s } } catch { }
        }
        $List.Add([pscustomobject]@{GameRoot=$p;SteamRoot=$steam;Source=$Source;Priority=$Priority;Label=($p+'  ('+$Source+')')})
    } catch { } # Unusable locations must not hide another valid library or the fallback.
}
function Get-ACRInstallCandidates([string]$SteamRoot='', [switch]$IgnoreSaved) {
    $found=New-Object 'Collections.Generic.List[object]'
    if (-not $IgnoreSaved) {
        try {
            $settings=Join-Path (Get-ACRUserStateRoot) 'location.json'
            if ([IO.File]::Exists($settings)) {
                $saved=[IO.File]::ReadAllText($settings)|ConvertFrom-Json
                $savedSteam='';if ($null -ne $saved.PSObject.Properties['SteamRoot']) {$savedSteam=[string]$saved.SteamRoot}
                Add-ACRInstallCandidate $found ([string]$saved.GameRoot) $savedSteam 'Remembered folder' 0
            }
        } catch { }
    }
    try {
        $roots=@(Get-ACRSteamRoots $SteamRoot)
        foreach($g in @(Get-ACRInstalledGames $roots)) {Add-ACRInstallCandidate $found $g.GameRoot $g.SteamRoot $g.Source 10}
    } catch { Write-Warning 'Steam discovery was unavailable. Checking the standard game folder next.' }
    # Explicit fallback requested by the user. Never accept it merely because the directory exists:
    # require the actual EXE, UTOC and UCAS first, then the patcher validates their fingerprints.
    Add-ACRInstallCandidate $found 'C:\Program Files\Steam\steamapps\common\Assetto Corsa Rally' '' 'Standard Steam folder' 20
    Add-ACRInstallCandidate $found 'C:\Program Files (x86)\Steam\steamapps\common\Assetto Corsa Rally' '' 'Standard Steam folder' 21
    return @($found.ToArray() | Sort-Object Priority,GameRoot)
}
function Select-ACRInstallCandidate([object[]]$Candidates) {
    # Pure selection policy. Discovery has already validated presence and deduplicated paths.
    # More than one library is not an error: pick deterministically and keep Change folder available.
    $ordered=@($Candidates | Sort-Object Priority,GameRoot)
    if ($ordered.Count -eq 0) { return $null }
    return $ordered[0]
}
function Resolve-ACRInstall([string]$GameRoot,[string]$SteamRoot,[switch]$Interactive,[switch]$IgnoreSaved) {
    $games=@(Get-ACRInstallCandidates -SteamRoot $SteamRoot -IgnoreSaved:$IgnoreSaved)
    $source='Your selected folder'
    if (-not $GameRoot) {
        $selected=Select-ACRInstallCandidate $games
        if ($null -ne $selected) { $GameRoot=$selected.GameRoot; $source=$selected.Source; if(-not $SteamRoot){$SteamRoot=$selected.SteamRoot} }
        elseif($Interactive) { $GameRoot=Read-Host 'Paste the Assetto Corsa Rally installation folder' }
        else { throw 'No usable ACR installation was found. Choose the game folder; no files were changed.' }
    }
    $GameRoot=ConvertTo-ACRLocalPath $GameRoot
    if (-not (Test-ACRGameRoot $GameRoot)) {throw 'This folder does not contain the expected ACR executable and containers.'}
    Assert-ACRNoReparse $GameRoot
    if(-not $SteamRoot) {
        $match=@($games | Where-Object {$_.GameRoot -ieq $GameRoot})
        if($match.Count -gt 0){$SteamRoot=$match[0].SteamRoot}
    }
    # Steam metadata is a discovery hint, not a dependency of manual game-folder selection.
    if($SteamRoot) {
        try {$SteamRoot=ConvertTo-ACRLocalPath $SteamRoot;Assert-ACRNoReparse $SteamRoot;if(-not [IO.File]::Exists((Join-Path $SteamRoot 'steam.exe'))){$SteamRoot=''}}
        catch {$SteamRoot=''}
    }
    $result=[pscustomobject]@{GameRoot=$GameRoot;SteamRoot=$SteamRoot;Source=$source;CandidateCount=$games.Count;LocationSaved=$false;LocationSaveError=''}
    # Remembering a valid location is optional. A preferences-write problem
    # must not be misreported as an invalid game folder. Game/file verification
    # remains mandatory in the worker before any patching.
    try {
        Save-ACRJson (Join-Path (Get-ACRUserStateRoot) 'location.json') ([ordered]@{GameRoot=$GameRoot;SteamRoot=$SteamRoot})
        $result.LocationSaved=$true
    } catch { $result.LocationSaveError=$_.Exception.Message }
    return $result
}

function Enter-ACROperation {
    $mutex=New-Object Threading.Mutex($false,'Global\GripHappens_OfflineRelease_v1')
    try {
        $ok=$false
        try { $ok=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ok=$true }
        if (-not $ok) { throw 'Another Grip Happens operation is active. Close it before proceeding.' }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}
function Exit-ACROperation($Mutex) { if ($null -ne $Mutex) { try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() } } }
Export-ModuleMember -Function *-ACR*
