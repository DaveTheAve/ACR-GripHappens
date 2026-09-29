#Requires -Version 5.1
# Pure coverage calculation shared by live export and synthetic regression tests.
Set-StrictMode -Version Latest
function Get-RoutingCoverage {
    param([object[]]$RoutingRows=@(),[object[]]$SteeringRows=@(),[object[]]$JointRows=@())
    $selected=@($RoutingRows | Where-Object { $_.Key -in @('CollisionsResistance','CollisionsSockets') })
    $res=@($selected | Where-Object { $_.Key -eq 'CollisionsResistance' -and $_.BagStable -eq $true -and $_.FieldStatus -eq 'Captured' }).Count
    $sockets=@($selected | Where-Object { $_.Key -eq 'CollisionsSockets' -and $_.BagStable -eq $true -and $_.FieldStatus -eq 'Captured' -and $_.SocketSetStatus -eq 'Captured' }).Count
    $badBags=@($RoutingRows | Where-Object { $_.Key -eq '' -and ($_.BagStatus -ne 'Captured' -or $_.BagStable -ne $true) }).Count
    $noKeys=@($RoutingRows | Where-Object { $_.Key -eq '' -and $_.BagStatus -eq 'Captured' -and $_.BagStable -eq $true }).Count
    $steering=@($SteeringRows | Where-Object { $_.Status -eq 'Captured' -and $_.Stable -eq $true -and $_.CollectionStable -eq $true }).Count
    $joints=@($JointRows | Where-Object { $_.Status -eq 'Captured' -and $_.Stable -eq $true -and $_.ParentStable -eq $true }).Count
    $aux=@($RoutingRows | Where-Object { $_.Key -ne '' -and $_.Key -notin @('CollisionsResistance','CollisionsSockets') })
    $badAux=@($aux | Where-Object { $_.BagStable -ne $true -or $_.FieldStatus -ne 'Captured' }).Count
    $badFields=$selected.Count-$res-$sockets
    $badJoints=$JointRows.Count-$joints
    $complete=($badFields -eq 0 -and $badAux -eq 0 -and $badBags -eq 0 -and $res -gt 0 -and $sockets -gt 0 -and $steering -eq 4 -and $joints -eq 4 -and $badJoints -eq 0)
    [pscustomobject]@{
        Status=$(if($complete){'Complete requested routing chapters'}else{'Partial routing capture - inspect missing/failed fields'})
        CollisionResistanceRows=$res; CollisionSocketSetRows=$sockets
        SelectedCollisionFields=$selected.Count; FailedOrUnstableCollisionFields=$badFields
        OtherRequestedScalarFields=$aux.Count; FailedOtherScalarFields=$badAux
        UncapturedBagRows=$badBags; ValidBagsWithoutCollisionKeys=$noKeys
        StableSteeringRows=$steering; StoredJointAnchorRows=$joints; FailedOrUnstableJointRows=$badJoints
        ReadOnly=$true
        Meaning='Complete refers to the requested read-only chapters for one four-wheel car, not measured handling or proof every native callback ran. Missing keys and rejected fields are different conditions. A stored anchor offset also includes normal steering.'
    }
}
Export-ModuleMember -Function Get-RoutingCoverage


# Report actual observed associations, not inferred leak/cooling functionality.
function Get-ACRCoolingRegistrationSummary {
 param([object[]]$Checks,[object[]]$Rows,[string]$Selection)
 foreach($check in @($Checks)) {
  if($null -eq $check -or $check.Part -notin @('Radiator','Intercooler')){continue}
  $valid=@($Rows | Where-Object {$_.Owner -eq $check.Owner -and $_.PartAddress -eq $check.PartAddress -and $_.CacheStable -eq $true -and $_.EntryStatus -eq 'Captured'})
  $dedicated=@($valid | Where-Object {$_.Socket -ceq $check.ConfiguredSocket})
  $engine=@($valid | Where-Object {$_.Socket -ceq 'Socket_Audio_Engine'})
  $state='Unknown - registration coverage incomplete'
  if($dedicated.Count -gt 0){$state='Dedicated socket association observed'}
  elseif($engine.Count -gt 0){$state='Engine-bay association observed'}
  elseif($check.CoverageComplete -eq $true){$state='No dedicated or engine-bay association observed'}
  [pscustomobject]@{Part=$check.Part;PartAddress=$check.PartAddress;Owner=$check.Owner;Selection=$Selection;ConfiguredSocket=$check.ConfiguredSocket;DedicatedAssociations=$dedicated.Count;EngineBayAssociations=$engine.Count;Result=$state;CoverageComplete=$check.CoverageComplete;Meaning='Observed registration, not a measured impact or coolant/engine consequence. EngineBay is an approximate fallback; dedicated-name checks remain unchanged.'}
 }
}
Export-ModuleMember -Function Get-RoutingCoverage,Get-ACRCoolingRegistrationSummary
