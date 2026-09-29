#Requires -Version 5.1
<# One log writer per invocation. All redirectable streams merge IN MEMORY;
no separate Out-File instances compete for details.log. Success objects are
captured separately from messages, without parsing their formatted text.
This module never reads or writes game files. #>
Set-StrictMode -Version Latest
function New-ACRLoggedCall {
    return @{
        Output=(New-Object 'Collections.Generic.List[object]')
        ExitCode=0; ErrorCount=0; FirstError=''; LoggingError=''; CommandStarted=$false
    }
}
function Invoke-ACRLoggedCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$LogPath,
        [Parameter(Mandatory=$true)][scriptblock]$Command,
        [Parameter(Mandatory=$true)][hashtable]$State,
        [switch]$CaptureOutput
    )
    if([string]::IsNullOrWhiteSpace($LogPath)) {throw 'A diagnostic log path is required.'}
    $stream=$null;$writer=$null
    try {
        # Open once BEFORE calling the task. Concurrent readers must allow writes.
        # Only this invocation owns a writer; a second writer is refused.
        $stream=[IO.File]::Open($LogPath,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $encoding=New-Object Text.UTF8Encoding($false)
        $writer=New-Object IO.StreamWriter($stream,$encoding)
        $writer.AutoFlush=$true
        $State.CommandStarted=$true
        & $Command *>&1 | ForEach-Object {
            $record=$_;$message=$null;$isMessage=$true
            if($record -is [Management.Automation.ErrorRecord]) {
                $State.ErrorCount++
                if(-not $State.FirstError){$State.FirstError=$record.ToString()}
                $message='ERROR: '+($record | Out-String -Width 240)
            } elseif($record -is [Management.Automation.WarningRecord]) {
                $message='WARNING: '+$record.Message
            } elseif($record -is [Management.Automation.VerboseRecord]) {
                $message='VERBOSE: '+$record.Message
            } elseif($record -is [Management.Automation.DebugRecord]) {
                $message='DEBUG: '+$record.Message
            } elseif($record -is [Management.Automation.InformationRecord]) {
                $message=[string]$record.MessageData
            } else {
                $isMessage=$false
                if($CaptureOutput) {[void]$State.Output.Add($record)}
                else {$message=($record | Out-String -Width 240).TrimEnd()}
            }
            if($null -ne $message -and -not $State.LoggingError) {
                # A late logging failure must not abort a running game-file
                # transaction or replace its verified success/rollback report.
                try {$writer.WriteLine($message)}
                catch {$State.LoggingError=$_.Exception.Message}
            }
        }
    } catch {
        $caught=$_
        if($null -ne $writer) {
            try {$writer.WriteLine(($caught | Out-String -Width 240))}
            catch {if(-not $State.LoggingError){$State.LoggingError=$_.Exception.Message}}
        }
        throw
    } finally {
        # Dispose even when a command throws. Never mask its original error.
        if($null -ne $writer) {
            try {$writer.Dispose()} catch {if(-not $State.LoggingError){$State.LoggingError=$_.Exception.Message}}
        }
        if($null -ne $stream) {
            try {$stream.Dispose()} catch {if(-not $State.LoggingError){$State.LoggingError=$_.Exception.Message}}
        }
    }
}
function Assert-ACRLoggedCallSucceeded {
    param([Parameter(Mandatory=$true)][hashtable]$State,[string]$Context='Task')
    if($State.ErrorCount -gt 0) {throw ($Context+' reported an error: '+$State.FirstError)}
    if($State.ExitCode -ne 0) {throw ($Context+' failed (exit '+$State.ExitCode+'). See the local task log.')}
}
Export-ModuleMember -Function New-ACRLoggedCall,Invoke-ACRLoggedCommand,Assert-ACRLoggedCallSucceeded
