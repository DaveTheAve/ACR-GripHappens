Import-Module (Join-Path $PSScriptRoot 'ACR.Custom.psm1') -ErrorAction Stop
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:ValidationValues=$null
function Get-ACRDesktopDefaults {
    return [pscustomobject]@{RateScale='0.005';WetTarmac='Moderate';VisualDamage='Off';CollisionDamage='Stock';TyreDamage='Stock';MechanicalFailures='Stock';BrakeWear='Stock';Detachment='Stock';CriticalDamage='Stock';CoolingRouting='Stock';EngineImpact='Stock';PowerResponse='Stock';WheelImpact='Stock';GearboxDamage='Stock'}
}
function Get-ACRDesktopChoices {
    # Labels express the actual parameter being scaled, never a promised
    # percentage of extra grip/dent depth or a guarantee of tyre lifetime.
    return @{
      RateScale=@(
        [pscustomobject]@{Value='0';Label='Off - 0x wear (original game)';RecommendedMultiplier=0},
        [pscustomobject]@{Value='0.00025';Label='Minimum - 0.05x recommended (scale 0.00025)';RecommendedMultiplier=0.05},
        [pscustomobject]@{Value='0.0005';Label='Very slow - 0.10x recommended (scale 0.0005)';RecommendedMultiplier=0.10},
        [pscustomobject]@{Value='0.001';Label='Slower - 0.20x recommended (scale 0.001)';RecommendedMultiplier=0.20},
        [pscustomobject]@{Value='0.002';Label='Slow - 0.40x recommended (scale 0.002)';RecommendedMultiplier=0.40},
        [pscustomobject]@{Value='0.005';Label='Recommended - 1.00x (scale 0.005)';RecommendedMultiplier=1.00},
        [pscustomobject]@{Value='0.01';Label='Faster - 2.00x recommended (scale 0.01)';RecommendedMultiplier=2.00},
        [pscustomobject]@{Value='0.02';Label='Fast - 4.00x recommended (scale 0.02)';RecommendedMultiplier=4.00},
        [pscustomobject]@{Value='0.05';Label='Very fast - 10.00x recommended (scale 0.05)';RecommendedMultiplier=10.00},
        [pscustomobject]@{Value='0.1';Label='Maximum - 20.00x recommended (scale 0.1)';RecommendedMultiplier=20.00})
      WetTarmac=@(
        [pscustomobject]@{Value='Off';Label='Stock - 0% wet-loss reduction (1.00x)';LossReductionPercent=0;Multiplier=1.00},
        [pscustomobject]@{Value='VeryLight';Label='Very light - 5% wet-loss reduction (0.95x)';LossReductionPercent=5;Multiplier=0.95},
        [pscustomobject]@{Value='Light';Label='Light - 10% wet-loss reduction (0.90x)';LossReductionPercent=10;Multiplier=0.90},
        [pscustomobject]@{Value='Mild';Label='Mild - 15% wet-loss reduction (0.85x)';LossReductionPercent=15;Multiplier=0.85},
        [pscustomobject]@{Value='Balanced';Label='Balanced - 20% wet-loss reduction (0.80x)';LossReductionPercent=20;Multiplier=0.80},
        [pscustomobject]@{Value='Moderate';Label='Moderate - 30% wet-loss reduction (0.70x, recommended)';LossReductionPercent=30;Multiplier=0.70},
        [pscustomobject]@{Value='Firm';Label='Firm - 40% wet-loss reduction (0.60x)';LossReductionPercent=40;Multiplier=0.60},
        [pscustomobject]@{Value='Strong';Label='Strong - 50% wet-loss reduction (0.50x, experimental)';LossReductionPercent=50;Multiplier=0.50},
        [pscustomobject]@{Value='Maximum';Label='Maximum - 60% wet-loss reduction (0.40x, experimental)';LossReductionPercent=60;Multiplier=0.40})
      VisualDamage=@(
        [pscustomobject]@{Value='Off';Label='Stock - 1.00x input (+0%, recommended)';Multiplier=1.00;IncreasePercent=0},
        [pscustomobject]@{Value='Enhanced';Label='Enhanced - 1.50x input (+50%)';Multiplier=1.50;IncreasePercent=50},
        [pscustomobject]@{Value='Strong';Label='Strong - 2.00x input (+100%)';Multiplier=2.00;IncreasePercent=100})
      TyreDamage=@(
        [pscustomobject]@{Value='Stock';Label='Stock - game compression rate (captured 0.00)'},
        [pscustomobject]@{Value='Native';Label='Enabled - compression damage rate 1.00 (experimental)'})
      MechanicalFailures=@(
        [pscustomobject]@{Value='Stock';Label='Stock - authored health threshold (captured 75%)'},
        [pscustomobject]@{Value='Earlier85';Label='Earlier - failure eligibility threshold 85% health'},
        [pscustomobject]@{Value='Earlier90';Label='Earlier still - failure eligibility threshold 90% health'})
      BrakeWear=@(
        [pscustomobject]@{Value='Stock';Label='Stock - game consumption gate (captured 0 / off)'},
        [pscustomobject]@{Value='Native';Label='Enabled - native disc/pad wear (gate 1 / on)'})
      Detachment=@(
        [pscustomobject]@{Value='Stock';Label='Stock - game attachment threshold factor (default 1.00x)'},
        [pscustomobject]@{Value='Easier';Label='Easier - 0.75x global thresholds (-25%)'},
        [pscustomobject]@{Value='Aggressive';Label='Aggressive - 0.50x global thresholds (-50%)'})
      CoolingRouting=@(
        [pscustomobject]@{Value='Stock';Label='Stock - 0 added cooling socket aliases'},
        [pscustomobject]@{Value='EngineBay';Label='Engine-bay fallback - 1 / on (missing cooling sockets)'})
      PowerResponse=@(
        [pscustomobject]@{Value='Stock';Label='Stock - native engine/turbo response (0 added caps)'},
        [pscustomobject]@{Value='Progressive';Label='Progressive - engine below 85% health; turbo below 70%'})
      GearboxDamage=@(
        [pscustomobject]@{Value='Stock';Label='Stock - 0 gearbox overrides'},
        [pscustomobject]@{Value='Grinding';Label='Native grinding - local damage rate 1.00'},
        [pscustomobject]@{Value='Impact';Label='Grinding + impacts - 1.00 rate; 50% engine-hit transfer'},
        [pscustomobject]@{Value='Responsive';Label='Responsive - 50% hit transfer; health-linked shift admission'},
        [pscustomobject]@{Value='Mechanical';Label='Mechanical - both paths; 0.25s recovery; risky downshifts'},
        [pscustomobject]@{Value='Engagement';Label='Engagement - up to +0.75s; over-rev 0.02s/rev, wear input 100x'},
        [pscustomobject]@{Value='Consequences';Label='Consequences - health squared; +1.50s max; stress 0.50s/rev'})
      WheelImpact=@(
        [pscustomobject]@{Value='Stock';Label='Stock - uniform 1.00x within collision radius'},
        [pscustomobject]@{Value='Localized';Label='Localized - 2.00x at contact to 0.00x at radius'},
        [pscustomobject]@{Value='Bent';Label='Localized + bending - 3.00x damage deformation; boost limit 0.020'})
      EngineImpact=@(
        [pscustomobject]@{Value='Stock';Label='Stock - engine collision coefficient 1.00x'},
        [pscustomobject]@{Value='Matched';Label='Stronger - engine collision coefficient 4.00x (+300%)'})
      CriticalDamage=@(
        [pscustomobject]@{Value='Stock';Label='Stock - 0 added overrides (native Critical-state protection)'},
        [pscustomobject]@{Value='Cumulative';Label='Cumulative - 1 / on (allow native Critical failures)'})
      CollisionDamage=@(
        [pscustomobject]@{Value='Stock';Label='Stock - 1.00x health loss (+0%, recommended)';Multiplier=1.00;IncreasePercent=0},
        [pscustomobject]@{Value='Sensitive';Label='Sensitive - 2.00x health loss (+100%)';Multiplier=2.00;IncreasePercent=100},
        [pscustomobject]@{Value='Strong';Label='Strong - 3.00x health loss (+200%)';Multiplier=3.00;IncreasePercent=200})
    }
}
function Get-ACRDesktopDescription([string]$Name,[string]$Value) {
    $choices=Get-ACRDesktopChoices
    if(-not $choices.ContainsKey($Name)){return 'Choose a setting.'}
    $items=@($choices[$Name] | Where-Object {$_.Value -eq $Value})
    if($items.Count -ne 1){return 'Choose a setting.'}
    $item=$items[0];$culture=[Globalization.CultureInfo]::InvariantCulture
    switch($Name) {
        'TyreDamage' {
            if($Value -eq 'Stock'){return 'No puncture-code change. The captured global compression rate was 0; other native puncture paths may still operate.'}
            return 'Overrides the two CompressionDamageRate reads in the native puncture routine with 1.00. Leaves the other impact/speed, probability and deflation code unchanged; bypasses this zero-rate stop. This is NOT a 100% puncture chance and not a guaranteed puncture after a hit. Experimental.'
        }
        'MechanicalFailures' {
            if($Value -eq 'Stock'){return 'No failure-eligibility change. The collected native policy uses a 0.75 health threshold; stock mechanical failures are not universally disabled.'}
            $percent=85;if($Value -eq 'Earlier90'){$percent=90}
            return ('Sets the native eligibility threshold to '+$percent+'% remaining component health. Higher thresholds allow checks after less damage. Does NOT set failure chance to '+$percent+'%. Native distance, resistance and chance remain. This setting alone leaves Critical-state protection in place; the separate Critical component failures control governs that. Experimental.')
        }
        'BrakeWear' {
            if($Value -eq 'Stock'){return 'No brake-consumption gate change. The captured global gate was 0/off.'}
            return 'Opens the native brake disc/pad consumption routine with gate value 1. This is an enable/disable switch, not a direct wear-rate multiplier. Native temperatures, forces, material settings and limits determine wear. Clutch/differential wear is NOT added. Clutch consumption and temperature-dependent brake friction were observed in the supplied captures; no duplicate fade penalty is applied. Experimental.'
        }
        'Detachment' {
            if($Value -eq 'Stock'){return 'Leaves the native global constrained-component threshold factor alone (constructor default 1.00). Normal authored detachment remains.'}
            $factor='0.75';if($Value -eq 'Aggressive'){$factor='0.50'}
            return ('Overrides the global factor with '+$factor+' for attachment accumulation/break thresholds. Per-car and per-component scales remain. Unbreakable parts stay unbreakable; no panel is forcibly detached. Affects configured breakable constraints, not only bonnets. Experimental.')
        }
        'CoolingRouting' {
            if($Value -eq 'Stock'){return 'Uses only the original configured collision-socket registrations. No alias is added.'}
            return 'For a compact single radiator/intercooler socket name absent on the currently enumerated mesh component, accepts its existing engine socket as a fallback. Dedicated sockets on that component take precedence. This is approximate engine-bay impact coverage, NOT a new leak/coolant model. Other components may still have dedicated sockets; not an actor-wide search. Requires a fresh stage. Experimental.'
        }
        'PowerResponse' {
            if($Value -eq 'Stock'){return 'No extra response cap. The original health-to-performance curves remain.'}
            return 'Makes existing engine/turbo damage effects more noticeable before total failure. At 50% component health: torque-control cap 0.588 and turbo-efficiency cap 0.714. Never increases the original value. No extra health loss, new cooling model, or random misfires. These are control values, not measured horsepower or boost. Experimental tuning.'
        }
        'GearboxDamage' {
            if($Value -eq 'Consequences'){return 'Progressive damaged-shift behavior: gearbox health and internal wear can delay or reject ordinary shifts, with recovery time after failed engagement. Coupled downshift over-rev can add gearbox stress only when the lower gear actually engages. Healthy controls are unchanged. Native grinding and 50% engine-hit transfer remain; severe abuse can disable the gearbox.'}

            if($Value -eq 'Engagement'){return 'Includes native grinding, 50% engine-hit transfer, health-linked admission and 0.25s minimum rejection recovery. Damaged ordinary shifts WAIT for native engagement: adds 0.75 x (1 - gearbox control) seconds; healthy timing stays unchanged. Actual coupled over-rev after a lower gear engages adds 0.02 exposure seconds per excess revolution; component-wear input uses x100 before the original coefficient. No extra damage just for pressing downshift. Neutral/forced paths remain exceptions. Unsafe downshifts may overrev. Experimental new tuning, not an original hidden option.'}
            if($Value -eq 'Stock'){return 'Original grinding rate and damage policy; no engine-impact transfer.'}
            $text='Uses native grinding wear with effective local rate 1.00 only while simulation and native damage are enabled. No penalty for a clean shift. With Cumulative selected, accumulated gearbox damage may enter its native Critical state. Existing native shifting and lock effects remain in charge.'
            if($Value -in @('Impact','Responsive','Mechanical','Engagement')){$text+=' Also transfers 50% of the engine ACTUAL collision health-fraction loss to the gearbox through native component health/effects. For example, 20 engine health percentage points lost requests 10 gearbox points. New approximate tuning, not an original collision socket or a guaranteed failure. Engine wear and repairs do not transfer. No additional gearbox hit when the engine loses no further collision health.'}
            if($Value -in @('Responsive','Mechanical','Engagement')){$text+=' Caps the active gearbox shift-admission control at remaining component-health fraction, never above the native value. Timed direct requests also consult native admission/cooldown. Original neutral/force/lock checks and shift durations remain. No additional engine-power penalty. Native grinding life remains a separate counter.'}
            if($Value -in @('Mechanical','Engagement')){$text+=' Extends native damage admission and cooldown to BOTH ordinary direct-request branches. A native rejection retains a minimum 0.25-second cooldown, preserving a longer native value. Explicitly bypasses the sequential downshift RPM veto: an unsafe downshift may overrev the engine. Does not add fixed gearbox damage per shift. Retains neutral, force, lock and clean-shift behavior; native damage remains conditional. Bounded observations record admission, grinding and actual over-threshold updates for the next snapshot.'}
            if($Value -eq 'Engagement'){$text+=' Worn ordinary shifts now wait for actual native engagement: adds 0.75 x (1 - health-linked control) seconds to the vehicle duration; healthy timing is unchanged. Also converts actual above-threshold engine revolutions into gearbox wear at 0.02 equivalent grinding seconds per excess revolution, ONLY after a lower forward gear has engaged, with clutch coupling >=0.5, no pending shift, and simulation/damage enabled. Native gearbox life uses the authored grinding coefficient; the component-wear input receives that exposure x100 before its original wear coefficient. Ordinary grinding is unchanged. This is new experimental stress tuning, not fixed damage per downshift request. Neutral, forced changes and clean shifts retain their intended exceptions.'}
            return $text+' Experimental.'
        }
        'WheelImpact' {
            if($Value -eq 'Stock'){return 'The native socket policy supplies the same event amount to each eligible hub inside its radius; this does not mean every collision reaches every wheel.'}
            $text='For the four recognized suspension hub sockets only, weights existing collision input by 2*max(0,1-distance/radius). Nearer hubs receive more, distant hubs less. No left/right bias or invented steering input. Shares the native event position/radius and pending-maximum policy; saturation can still hide asymmetry. Experimental tuning; fresh car advised.'
            if($Value -eq 'Bent'){$text+=' Also amplifies the actual damage-only steering-joint displacement by 3.00x, with the boosted magnitude capped at 0.020 native length units. An original displacement already above that limit is not reduced. Normal steering input and undamaged wheels are unchanged; no forced pull. Final handling is not yet calibrated.'}
            return $text
        }
        'EngineImpact' {
            if($Value -eq 'Stock'){return 'Keeps the engine collision coefficient unchanged (1.00x; captured coefficient 0.05). Normal native health and power curves remain.'}
            return 'Engine part only: collision coefficient 4.00x (+300%); the captured 0.05 becomes 0.20. Stacks with the separate collision-damage scale (4x then Sensitive 2x = 8x). Also influences native per-hit Critical eligibility. Does NOT directly multiply horsepower loss, add misfires, or force damage in a collision that missed the engine. Experimental; not realism-calibrated.'
        }
        'CriticalDamage' {
            if($Value -eq 'Stock'){return 'Keeps the game''s separate per-hit Critical admission and mechanical-failure protection. This does not disable ordinary damage.'}
            return 'Allows existing collision and mechanical-failure updates to enter each part''s authored Critical state. Removes the protected health floor on those paths without adding health loss or a random failure chance. Does NOT guarantee a 100% failure probability, stronger dents, or a radiator/transmission simulation. Can end a run. Experimental.'
        }
        'RateScale' {
            if($Value -eq '0'){return '0x wear: restores the stock disabled tyre-consumption setting. No extra grip penalty is added.'}
            $factor=([double]$item.RecommendedMultiplier).ToString('0.00',$culture)
            $scale=[double]::Parse($Value,$culture)
            $coefficient=($scale*2.5).ToString('0.######',$culture)
            return ($factor+'x the recommended consumption coefficient. Scale '+$Value+' sets TreadConsumptionK to '+$coefficient+'. This is not a guaranteed tyre lifetime. Stock wear-to-grip behavior is unchanged.')
        }
        'WetTarmac' {
            if($Value -eq 'Off'){return '1.00x stock wet-loss coefficient (0% reduction): original wet-road behavior. No extra grip is added.'}
            $factor=([double]$item.Multiplier).ToString('0.00',$culture)
            $text=([string]$item.LossReductionPercent)+'% lower wet-loss coefficient ('+$factor+'x stock). Higher reductions weaken this part of the wet-road grip-loss calculation; this is NOT that percentage of extra grip. Weather and tyre slip curves are unchanged.'
            if($Value -in @('Strong','Maximum')){$text+=' Experimental: may reduce wet-road difficulty too much.'}
            return $text
        }
        'VisualDamage' {
            if($Value -eq 'Off'){return '1.00x (+0%): normal game bodywork deformation. Stock does not disable damage.'}
            return (([double]$item.Multiplier).ToString('0.00',$culture)+'x the native deformation input (+'+$item.IncreasePercent+'%). This is NOT the same percentage of deeper dents. Original deformation limits and damage-enable checks remain. Experimental.')
        }
        'CollisionDamage' {
            if($Value -eq 'Stock'){return '1.00x (+0%): normal collision-related component-health loss. Stock does not disable mechanical damage.'}
            return (([double]$item.Multiplier).ToString('0.00',$culture)+'x eligible collision-related part-health loss (+'+$item.IncreasePercent+'%). A stock loss of 10 health points becomes '+([int](10*$item.Multiplier))+' before native clamping. This does not multiply crash forces or guarantee proportional handling damage. Experimental.')
        }
    }
}
function Get-ACRDesktopWetDescription([string]$Value) {
    return (Get-ACRDesktopDescription 'WetTarmac' $Value)
}
function Test-ACRDesktopSettings($Settings) {
    if ($null -eq $Settings) {return $false}
    if($null -eq $script:ValidationValues) {
        $script:ValidationValues=@{};$choices=Get-ACRDesktopChoices
        foreach($key in $choices.Keys){$script:ValidationValues[$key]=[string[]]@($choices[$key]|ForEach-Object{[string]$_.Value})}
    }
    foreach($name in @('RateScale','WetTarmac','VisualDamage','CollisionDamage','TyreDamage','MechanicalFailures','BrakeWear','Detachment','CriticalDamage','CoolingRouting','EngineImpact','PowerResponse','WheelImpact','GearboxDamage')) {
        if ($null -eq $Settings.PSObject.Properties[$name]) {return $false}
        if ($script:ValidationValues[$name] -notcontains [string]$Settings.$name) {return $false}
    }
    return $true
}
function Get-ACRDesktopLabel([string]$Name,[string]$Value) {
    $c=Get-ACRDesktopChoices
    if (-not $c.ContainsKey($Name)) {return 'Unknown'}
    $item=@($c[$Name] | Where-Object {$_.Value -eq $Value})
    if($item.Count -eq 1) {return $item[0].Label}
    return 'Unknown - check installation'
}
function Get-ACRDesktopSettingsFromReport($Report) {
    if ($null -eq $Report) {return $null}
    $p=$Report.PSObject.Properties['VerifiedConfiguration']; if($null -eq $p) {return $null}
    $v=$p.Value
    if($null -eq $v) {return $null}
    foreach($n in @('WearRateScale','WetTarmac','VisualDamage','CollisionDamage','TyreDamage','MechanicalFailures','BrakeWear','Detachment','CriticalDamage','CoolingRouting','EngineImpact','PowerResponse','WheelImpact','GearboxDamage')) {if($null -eq $v.PSObject.Properties[$n]) {return $null}}
    $s=[pscustomobject]@{RateScale=[string]$v.WearRateScale;WetTarmac=[string]$v.WetTarmac;VisualDamage=[string]$v.VisualDamage;CollisionDamage=[string]$v.CollisionDamage;TyreDamage=[string]$v.TyreDamage;MechanicalFailures=[string]$v.MechanicalFailures;BrakeWear=[string]$v.BrakeWear;Detachment=[string]$v.Detachment;CriticalDamage=[string]$v.CriticalDamage;CoolingRouting=[string]$v.CoolingRouting;EngineImpact=[string]$v.EngineImpact;PowerResponse=[string]$v.PowerResponse;WheelImpact=[string]$v.WheelImpact;GearboxDamage=[string]$v.GearboxDamage}
    if($null -ne $v.PSObject.Properties['CustomValues']){try{$cv=ConvertTo-ACRCustomMap $v.CustomValues;if($cv.Count){$s|Add-Member NoteProperty CustomValues $cv}}catch{return $null}}
        if(Test-ACRDesktopSettings $s) {return $s}
    return $null # Unknown values are never silently coerced to the defaults.
}
function Test-ACRDesktopStockSelection($Settings) {
    return ((Test-ACRDesktopSettings $Settings) -and $Settings.RateScale -eq '0' -and $Settings.WetTarmac -eq 'Off' -and $Settings.VisualDamage -eq 'Off' -and $Settings.CollisionDamage -eq 'Stock' -and $Settings.TyreDamage -eq 'Stock' -and $Settings.MechanicalFailures -eq 'Stock' -and $Settings.BrakeWear -eq 'Stock' -and $Settings.Detachment -eq 'Stock' -and $Settings.CriticalDamage -eq 'Stock' -and $Settings.CoolingRouting -eq 'Stock' -and $Settings.EngineImpact -eq 'Stock' -and $Settings.PowerResponse -eq 'Stock' -and $Settings.WheelImpact -eq 'Stock' -and $Settings.GearboxDamage -eq 'Stock' -and (Get-ACRCustomValuesFromSettings $Settings).Count -eq 0)
}
function Get-ACRDesktopSummary($Settings) {
    if(-not (Test-ACRDesktopSettings $Settings)) {return 'Unknown configuration'}
    return ('Tyre wear: '+(Get-ACRDesktopLabel 'RateScale' $Settings.RateScale)+"`nWet-road grip: "+(Get-ACRDesktopLabel 'WetTarmac' $Settings.WetTarmac)+"`nVisual damage: "+(Get-ACRDesktopLabel 'VisualDamage' $Settings.VisualDamage)+"`nCollision damage: "+(Get-ACRDesktopLabel 'CollisionDamage' $Settings.CollisionDamage)+"`nTyre impact damage: "+(Get-ACRDesktopLabel 'TyreDamage' $Settings.TyreDamage)+"`nMechanical failure eligibility: "+(Get-ACRDesktopLabel 'MechanicalFailures' $Settings.MechanicalFailures)+"`nBrake disc/pad wear: "+(Get-ACRDesktopLabel 'BrakeWear' $Settings.BrakeWear)+"`nAttachment thresholds: "+(Get-ACRDesktopLabel 'Detachment' $Settings.Detachment)+"`nCritical component failures: "+(Get-ACRDesktopLabel 'CriticalDamage' $Settings.CriticalDamage)+"`nCooling collision routing: "+(Get-ACRDesktopLabel 'CoolingRouting' $Settings.CoolingRouting)+"`nEngine impact weighting: "+(Get-ACRDesktopLabel 'EngineImpact' $Settings.EngineImpact)+"`nEngine/turbo response: "+(Get-ACRDesktopLabel 'PowerResponse' $Settings.PowerResponse)+"`nWheel collision distribution: "+(Get-ACRDesktopLabel 'WheelImpact' $Settings.WheelImpact)+"`nGearbox damage: "+(Get-ACRDesktopLabel 'GearboxDamage' $Settings.GearboxDamage))
}
function Get-ACRDesktopFailureText([string]$ErrorText,$Core) {
    if($null -ne $Core -and $null -ne $Core.PSObject.Properties['RollbackToStockVerified']) {
        if($Core.RollbackToStockVerified -eq $true) {return 'The change failed, but restoration to the original game files was verified. Your requested settings were NOT installed. See Advanced for details.'}
        return 'Restoration could not be verified. DO NOT start ACR. Use Restore original game files. If that fails, verify the game files through Steam.'
    }
    if($ErrorText -match '(?i)game is running|close ACR|running ACR|ACR is running') {return 'Close Assetto Corsa Rally completely, then try again. Steam can stay open.'}
    if($ErrorText -match '(?i)length mismatch|different build|another game build|unknown changes|outside the audited|unexpected patch-range|unknown executable|unrecognized build') {return 'These game files do not match the supported build or a recognized mod state. No new patch was applied. Do not force installation. See Advanced for the exact reason.'}
    if($ErrorText -match '(?i)Mixed|interrupted|incomplete.write') {return 'An unfinished or mixed installation was found. Do not start ACR. Use Restore original game files before installing again.'}
    if($ErrorText -match '(?i)access.*denied|permission|administrator') {return 'Windows did not allow access. Close ACR and approve the administrator request. Do not change game-file permissions or disable protection.'}
    if($ErrorText -match '(?i)package|manifest.*changed|integrity') {return 'The mod package is missing a file or has changed. Extract the complete new ZIP into its own folder and try again.'}
    return 'The operation could not finish. Open Advanced for the local details or create a support report. Do not assume your requested changes were applied.'
}
function Get-ACRDesktopBackupFolder([string]$GameRoot) {
    return (Get-ACRBackupStateRoot $GameRoot)
}
function ConvertTo-ACRDesktopArgument([string]$Value) {
    if($Value -match '["\r\n\x00]') {throw 'Invalid command argument.'}
    # Windows command-line quoting: double trailing backslashes before the closing quote.
    $trailing=[regex]::Match($Value,'\\+$').Value
    return '"'+$Value+$trailing+'"'
}
function Test-ACRDesktopReply($Reply,[string]$TaskId,[string]$Action) {
    if($null -eq $Reply) {return $false}
    foreach($n in @('Schema','TaskId','Action','Status')) {if($null -eq $Reply.PSObject.Properties[$n]) {return $false}}
    return ($Reply.Schema -eq 1 -and $Reply.TaskId -ceq $TaskId -and $Reply.Action -ceq $Action -and $Reply.Status -in @('Success','Failed'))
}

function Test-ACRDesktopConfigurationMatch($Expected,$Actual) {
 if(-not (Test-ACRDesktopSettings $Expected) -or -not (Test-ACRDesktopSettings $Actual)){return $false}
 foreach($name in @('RateScale','WetTarmac','VisualDamage','CollisionDamage','TyreDamage','MechanicalFailures','BrakeWear','Detachment','CriticalDamage','CoolingRouting','EngineImpact','PowerResponse','WheelImpact','GearboxDamage')) {
  if([string]$Expected.$name -cne [string]$Actual.$name){return $false}
 }
 if($null -ne $Expected.PSObject.Properties['CustomValues'] -or $null -ne $Actual.PSObject.Properties['CustomValues']){
  $a=Get-ACRCustomValuesFromSettings $Expected;$b=Get-ACRCustomValuesFromSettings $Actual
  if($a.Count -ne $b.Count){return $false};foreach($k in $a.Keys){if(-not $b.Contains($k) -or $a[$k] -cne $b[$k]){return $false}}
 }
 return $true
}
function Get-ACRDesktopVerifiedInstallSettings($Core,$Expected) {
 $actual=Get-ACRDesktopSettingsFromReport $Core
 if(-not (Test-ACRDesktopConfigurationMatch $Expected $actual)) {
  throw 'The verified installed settings do not match the settings you confirmed. The current test is NOT verified. Check the installation before driving; do not assume the requested setup was installed.'
 }
 return $actual
}

Export-ModuleMember -Function *-ACRDesktop*
