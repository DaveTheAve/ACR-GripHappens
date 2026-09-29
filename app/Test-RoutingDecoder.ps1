#Requires -Version 5.1
# Pure byte-array regression tests. No process is opened by these tests.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not ('ACRDamageProbe' -as [type])){throw 'Compile the pinned read-only decoder before running its tests.'}
$script:routingAssertions=0
function Assert-Routing([bool]$Condition,[string]$Message) {
    if(-not $Condition){throw ('Routing decoder test failed: '+$Message)}
    $script:routingAssertions++
}
function Put-I([byte[]]$B,[int]$O,[int]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$B,$O,4)}
function Put-F([byte[]]$B,[int]$O,[single]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$B,$O,4)}
function Put-D([byte[]]$B,[int]$O,[double]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$B,$O,8)}
[byte[]]$bag=New-Object byte[] 64
Put-F $bag 8 0.125
Put-D $bag 24 0.25
$r=[ACRDamageProbe]::DecodeRoutingField($bag,8,4,5,0)
Assert-Routing ($r['decodedAs'] -eq 'Float32' -and [double]$r['value'] -eq 0.125) 'Float coefficient decoded exactly'
$r=[ACRDamageProbe]::DecodeRoutingField($bag,24,8,6,0)
Assert-Routing ($r['decodedAs'] -eq 'Float64' -and [double]$r['value'] -eq 0.25) 'Double coefficient decoded exactly'
$r=[ACRDamageProbe]::DecodeRoutingField($bag,0,8,99,0)
Assert-Routing (-not $r.ContainsKey('value')) 'Unknown property type is not fabricated as zero'
Put-F $bag 8 ([single]::NaN)
$r=[ACRDamageProbe]::DecodeRoutingField($bag,8,4,5,0)
Assert-Routing ($r['value'] -is [string]) 'Nonfinite property is explicit'
foreach($off in @(-1,63,64,1000000)) {
    $caught=$false
    try{[void][ACRDamageProbe]::DecodeRoutingField($bag,$off,4,5,0)}catch{$caught=$true}
    Assert-Routing $caught 'Out-of-bounds coefficient refused'
}
[byte[]]$set=New-Object byte[] 0x50
Put-I $set 8 6;Put-I $set 12 6;Put-I $set 0x28 6;Put-I $set 0x2c 128;Put-I $set 0x34 2
[byte[]]$mask=0x2d,0,0,0
$slots=[ACRDamageProbe]::DecodeAllocatedSocketSlots($set,$mask)
Assert-Routing (($slots -join ',') -eq '0,2,3,5') 'Freed sparse slots excluded from socket names'
Put-I $set 0x34 0
$caught=$false
try{[void][ACRDamageProbe]::DecodeAllocatedSocketSlots($set,$mask)}catch{$caught=$true}
Assert-Routing $caught 'Allocation mask and free count must agree'
Put-I $set 0x34 2;Put-I $set 0x28 7
$caught=$false
try{[void][ACRDamageProbe]::DecodeAllocatedSocketSlots($set,$mask)}catch{$caught=$true}
Assert-Routing $caught 'Sparse count and mask length must agree'
[byte[]]$empty=New-Object byte[] 0x50
Put-I $empty 0x2c 128
Assert-Routing ([ACRDamageProbe]::DecodeAllocatedSocketSlots($empty,(New-Object byte[] 0)).Count -eq 0) 'Empty socket set is supported'
# Larger masks exercise the externally allocated bitset branch's pure decoder.
[byte[]]$larger=New-Object byte[] 0x50
Put-I $larger 8 160;Put-I $larger 12 160;Put-I $larger 0x28 160;Put-I $larger 0x2c 160;Put-I $larger 0x34 158
[byte[]]$bits=New-Object byte[] 20;$bits[0]=1;$bits[19]=128
Assert-Routing (([ACRDamageProbe]::DecodeAllocatedSocketSlots($larger,$bits) -join ',') -eq '0,159') 'External mask indices preserved'

[byte[]]$car=New-Object byte[] 0x2c48
[byte[]]$susp=New-Object byte[] 0x820
[byte[]]$record=New-Object byte[] 0xb0
for($w=0;$w -lt 4;$w++) {
    Put-I $susp 0x10 $w;Put-I $susp 0x660 0
    Put-F $car (0x850+0xe0*$w) 0.005;Put-F $car (0x1280+4*$w) 0.55
    Put-F $car (0x1270+4*$w) 0.49
    foreach($sign in @(-1,0,1)) {
        Put-D $record 0x90 ([double]$sign)
        foreach($flag in @(0,1)) {
            $car[0xb4]=[byte]$flag
            foreach($present in @($true,$false)) {
                $before=[Convert]::ToBase64String($susp)+[Convert]::ToBase64String($record)+[Convert]::ToBase64String($car)
                $v=[ACRDamageProbe]::DecodeConstraintRoute($susp,$record,$car,1,1,$present)
                $side=if($w -eq 0 -or $w -eq 2){1}else{-1}
                $product=[single]([single]0.005*[single]0.55)
                $expected=[double]$product*$side*$sign
                Assert-Routing ([Math]::Abs([double]$v['calculatedSignedDamageTerm']-$expected) -lt 1e-12) 'Signed native offset arithmetic'
                Assert-Routing ($v['wouldPassRecordedPreconditions'] -eq ($flag -eq 0 -and $present)) 'Recorded gate and backend conditions'
                Assert-Routing ($v['nativeWheelIndex'] -eq $w) 'Native index preserved'
                Assert-Routing ($before -ceq ([Convert]::ToBase64String($susp)+[Convert]::ToBase64String($record)+[Convert]::ToBase64String($car))) 'Pure decoder leaves input buffers unchanged'
            }
        }
    }
}
$car[0xb4]=0;Put-I $susp 0x660 -1
$v=[ACRDamageProbe]::DecodeConstraintRoute($susp,$null,$car,1,1,$true)
Assert-Routing ($v['routeAtCapture'] -eq 'No eligible steering constraint index') 'Absent steering linkage is explicit'
Put-I $susp 0x660 1
$v=[ACRDamageProbe]::DecodeConstraintRoute($susp,$null,$car,1,1,$true)
Assert-Routing ($v['routeAtCapture'] -eq 'No eligible steering constraint index') 'Out-of-range steering index is explicit'
Put-I $susp 0x660 0;Put-F $car (0x850+3*0xe0) ([single]::NaN)
$v=[ACRDamageProbe]::DecodeConstraintRoute($susp,$record,$car,1,1,$true)
Assert-Routing (-not $v['calculationInputsFinite'] -and -not $v.ContainsKey('calculatedSignedDamageTerm')) 'Nonfinite input not presented as zero displacement'
foreach($badIndex in @(-1,4)) {
    Put-I $susp 0x10 $badIndex
    $caught=$false
    try{[void][ACRDamageProbe]::DecodeConstraintRoute($susp,$record,$car,1,1,$true)}catch{$caught=$true}
    Assert-Routing $caught 'Invalid native wheel rejected'
}
Put-I $susp 0x10 0
$caught=$false
try{[void][ACRDamageProbe]::DecodeConstraintRoute($susp,$null,$car,1,1,$true)}catch{$caught=$true}
Assert-Routing $caught 'Inconsistent record/index refused'


# Regression for the actual 0.2.0 failure: flag words must NOT be used as sizes.
function Put-Q([byte[]]$B,[int]$O,[System.UInt64]$V){[Array]::Copy([BitConverter]::GetBytes($V),0,$B,$O,8)}
[byte[]]$ph=New-Object byte[] 0x48
Put-I $ph 0x30 1; Put-I $ph 0x34 4; Put-I $ph 0x44 12
Put-Q $ph 0x38 ([Convert]::ToUInt64('8000000010000021',16))
$m=[ACRDamageProbe]::DecodeCachedRoutingProperty($ph,104)
Assert-Routing ($m['arrayDim'] -eq 1 -and $m['elementSize'] -eq 4 -and $m['offsetInternal'] -eq 12) 'Correct cached property extent ignores both halves of flags'
Assert-Routing ($m['propertyFlagsHex'] -eq '0x8000000010000021') 'Flags retained independently as diagnostic evidence'
Assert-Routing ([BitConverter]::ToInt32($ph,0x38) -ne 1 -and [BitConverter]::ToInt32($ph,0x3c) -lt 0) 'Fixture would fail the erroneous 0.2.0 layout'
[byte[]]$storage=New-Object byte[] 104
Put-F $storage 12 0.125
$v=[ACRDamageProbe]::DecodeRoutingField($storage,[int]$m['offsetInternal'],[int]$m['elementSize'],5,0)
Assert-Routing ([double]$v['value'] -eq 0.125) 'Actual metadata-to-value path decodes nonzero coefficient'
Put-I $ph 0x34 0x50; Put-I $ph 0x44 24
$m=[ACRDamageProbe]::DecodeCachedRoutingProperty($ph,104)
Assert-Routing ($m['elementSize'] -eq 80 -and $m['offsetInternal'] -eq 24) 'Socket metadata can occupy exactly the remaining bag extent'
foreach($dim in @(0,2,-1,2147483647)) {
    Put-I $ph 0x30 $dim
    $caught=$false;try{[void][ACRDamageProbe]::DecodeCachedRoutingProperty($ph,104)}catch{$caught=$true}
    Assert-Routing $caught 'Unsupported array dimensions explicitly rejected'
}
Put-I $ph 0x30 1
foreach($offset in @(-1,25,104,2147483647)) {
    Put-I $ph 0x44 $offset
    $caught=$false;try{[void][ACRDamageProbe]::DecodeCachedRoutingProperty($ph,104)}catch{$caught=$true}
    Assert-Routing $caught 'Extent overflow/out-of-bounds rejected before property read'
}
Put-I $ph 0x44 0
foreach($size in @(0,-1,4097,2147483647)) {
    Put-I $ph 0x34 $size
    $caught=$false;try{[void][ACRDamageProbe]::DecodeCachedRoutingProperty($ph,104)}catch{$caught=$true}
    Assert-Routing $caught 'Invalid element sizes rejected'
}
Assert-Routing ([ACRDamageProbe]::IsEmptyRoutingBag(0,0,0)) 'Valid empty property schema does not require imaginary byte storage'
Assert-Routing ([ACRDamageProbe]::IsEmptyRoutingBag(1,0,0)) 'Padded empty schema supported'
Assert-Routing (-not [ACRDamageProbe]::IsEmptyRoutingBag(104,7,7)) 'Nonempty schema distinct from missing keys'
$caught=$false;try{[void][ACRDamageProbe]::IsEmptyRoutingBag(0,1,1)}catch{$caught=$true}
Assert-Routing $caught 'Zero storage cannot host a described property'

# Same backend decoder used by the live trace. Both body orders and absent bodies.
[System.UInt64]$jointVt=[Convert]::ToUInt64('14a8d9990',16)
[byte[]]$joint=New-Object byte[] 0xf8
[byte[]]$anchorSusp=New-Object byte[] 0x820
Put-Q $joint 0 $jointVt
Put-D $joint 0xa0 0.29;Put-D $joint 0xa8 -0.2;Put-D $joint 0xb0 1.2
Put-D $joint 0xc0 -0.4;Put-D $joint 0xc8 0.1;Put-D $joint 0xd0 -1.3
Put-D $joint 0xf0 0.42
Put-D $anchorSusp 0x668 0.30;Put-D $anchorSusp 0x670 -0.2;Put-D $anchorSusp 0x678 1.2
foreach($flag in @(0,2,3)) {
    Put-I $joint 0x30 $flag
    foreach($body0 in @([System.UInt64]0,[System.UInt64]0x200000)) {
        foreach($body1 in @([System.UInt64]0,[System.UInt64]0x300000)) {
            Put-Q $joint 0x40 $body0;Put-Q $joint 0x58 $body1
            $saved=[Convert]::ToBase64String($joint)+[Convert]::ToBase64String($anchorSusp)
            $v=[ACRDamageProbe]::DecodeStoredSteeringJoint($joint,$anchorSusp,$jointVt)
            $reverse=($flag -band 2) -ne 0
            $expectedX=if($reverse){-0.4}else{0.29}
            $expectedBody=if($reverse){$body1}else{$body0}
            Assert-Routing ([Math]::Abs([double]$v['storedFirstAnchorX']-$expectedX) -lt 1e-12) 'Actual first anchor follows native reverse-body flag'
            Assert-Routing ($v['firstBodyAddress'] -eq ('0x'+$expectedBody.ToString('x'))) 'Recorded coordinate body agrees with native body selection'
            Assert-Routing ([Math]::Abs([double]$v['referenceMinusStoredAnchorX']-(0.30-$expectedX)) -lt 1e-12) 'Reference minus stored anchor includes total, not assumed damage only'
            Assert-Routing ([double]$v['storedJointDistance'] -eq 0.42) 'Independent joint-distance field decoded'
            Assert-Routing ($saved -ceq ([Convert]::ToBase64String($joint)+[Convert]::ToBase64String($anchorSusp))) 'Anchor decoder leaves both inputs unchanged'
        }
    }
}
[byte[]]$j2=$joint.Clone()
Assert-Routing ([ACRDamageProbe]::SameSteeringJointMeasurement($joint,$j2)) 'Identical joint footprint accepted'
$j2[0x20]=1
Assert-Routing ([ACRDamageProbe]::SameSteeringJointMeasurement($joint,$j2)) 'Unrelated solver bookkeeping does not invent anchor instability'
foreach($offset in @(0,0x30,0x40,0x58,0xa0,0xc0,0xf0)) {
    [byte[]]$j2=$joint.Clone();$j2[$offset]=$j2[$offset] -bxor 1
    Assert-Routing (-not [ACRDamageProbe]::SameSteeringJointMeasurement($joint,$j2)) 'Each joint identity/anchor measurement range must remain stable'
}
$caught=$false;try{[void][ACRDamageProbe]::DecodeStoredSteeringJoint($joint,$anchorSusp,([System.UInt64]$jointVt+1))}catch{$caught=$true}
Assert-Routing $caught 'Unexpected backend joint class not force-decoded'
Put-I $joint 0x30 0;Put-D $joint 0xa0 ([double]::NaN)
$caught=$false;try{[void][ACRDamageProbe]::DecodeStoredSteeringJoint($joint,$anchorSusp,$jointVt)}catch{$caught=$true}
Assert-Routing $caught 'Nonfinite actual anchor not presented as zero'
Put-D $joint 0xa0 0.29;Put-D $joint 0xf0 -1
$caught=$false;try{[void][ACRDamageProbe]::DecodeStoredSteeringJoint($joint,$anchorSusp,$jointVt)}catch{$caught=$true}
Assert-Routing $caught 'Negative distance invalidity is explicit'

Import-Module (Join-Path $PSScriptRoot 'modules\Routing.Coverage.psm1') -Force -ErrorAction Stop
$brokenRows=@(for($i=0;$i -lt 13;$i++) {foreach($key in @('CollisionsResistance','CollisionsSockets')) {
    [pscustomobject]@{Key=$key;BagStatus='Captured';BagStable=$true;FieldStatus='Not decoded';SocketSetStatus=''}
}})
$steeringRows=@(for($i=0;$i -lt 4;$i++){[pscustomobject]@{Status='Captured';Stable=$true;CollectionStable=$true}})
$coverage=Get-RoutingCoverage -RoutingRows $brokenRows -SteeringRows $steeringRows
Assert-Routing ($coverage.Status -like 'Partial*' -and $coverage.FailedOrUnstableCollisionFields -eq 26 -and $coverage.CollisionResistanceRows -eq 0 -and $coverage.CollisionSocketSetRows -eq 0) 'User-reported 0.2.0 nested failures cannot be labeled a complete routing capture'
$goodRows=@([pscustomobject]@{Key='CollisionsResistance';BagStatus='Captured';BagStable=$true;FieldStatus='Captured';SocketSetStatus=''},[pscustomobject]@{Key='CollisionsSockets';BagStatus='Captured';BagStable=$true;FieldStatus='Captured';SocketSetStatus='Captured'})
$jointRows=@(for($i=0;$i -lt 4;$i++){[pscustomobject]@{Status='Captured';Stable=$true;ParentStable=$true}})
$coverage=Get-RoutingCoverage -RoutingRows $goodRows -SteeringRows $steeringRows -JointRows $jointRows
Assert-Routing ($coverage.Status -eq 'Complete requested routing chapters' -and $coverage.StoredJointAnchorRows -eq 4) 'Complete chapter classification uses actual nested successes'
$steeringRows[0].CollectionStable=$false;$jointRows[0].ParentStable=$false
$coverage=Get-RoutingCoverage -RoutingRows $goodRows -SteeringRows $steeringRows -JointRows $jointRows
Assert-Routing ($coverage.Status -like 'Partial*' -and $coverage.StableSteeringRows -eq 3 -and $coverage.StoredJointAnchorRows -eq 3) 'Changed parent identity invalidates otherwise stable local reads'
$coverage=Get-RoutingCoverage
Assert-Routing ($coverage.Status -like 'Partial*') 'Empty output cannot pass coverage'
# New pure decoders require no process access.
[byte[]]$gb=0xcd,0xcc,0x4c,0x3d,3,0,0,0,0x0a,0xd7,0xa3,0x3c,0xcd,0xcc,0x4c,0x3d
$selector=[ACRDamageProbe]::DecodePhysicsDamageSelector($gb,4)
Assert-Routing ($selector['value'] -eq 3 -and $selector['enumName'] -eq 'GearboxGrinding') 'Real supplied gearbox selector is enum three, not missing scalar'
$enumNames=@('EngineTurboAboveThresh','EngineRpmAboveThresh','EngineThrottleRevs','GearboxGrinding')
for($i=0;$i -lt 4;$i++){$gb[4]=[byte]$i;$selector=[ACRDamageProbe]::DecodePhysicsDamageSelector($gb,4);Assert-Routing ($selector['enumName'] -ceq $enumNames[$i]) 'Audited enum order preserved'}
$gb[4]=255;$caught=$false;try{[void][ACRDamageProbe]::DecodePhysicsDamageSelector($gb,4)}catch{$caught=$true};Assert-Routing $caught 'Unknown enum refused'
[byte[]]$entry=New-Object byte[] 0x68;Put-Q $entry 0 ([System.UInt64]0x10000);Put-I $entry 8 123;Put-I $entry 12 7
$key=[ACRDamageProbe]::DecodeRegisteredSocketKey($entry)
Assert-Routing ($key['componentAddress'] -eq 0x10000 -and $key['nameIndex'] -eq 123 -and $key['nameNumber'] -eq 7) 'Socket map component and FName fields use audited stride'
Put-Q $entry 0 ([System.UInt64]0);$caught=$false;try{[void][ACRDamageProbe]::DecodeRegisteredSocketKey($entry)}catch{$caught=$true};Assert-Routing $caught 'Null active socket component refused'
$caught=$false;try{[void][ACRDamageProbe]::DecodeRegisteredSocketKey((New-Object byte[] 0x60))}catch{$caught=$true};Assert-Routing $caught 'Wrong map entry size refused'
Write-Host ('PASS Read-only routing decoder: '+$script:routingAssertions+' byte-array assertions; no game process opened.')
