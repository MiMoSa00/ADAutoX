<#
.SYNOPSIS
    Performs user lifecycle administration (Enable, Disable, Unlock, ResetPassword, Move, Terminate).

.EXAMPLE
    .\Manage-ADAutoXUser.ps1 -Identity 'chinedu.okafor' -Action Disable

.EXAMPLE
    .\Manage-ADAutoXUser.ps1 -Identity 'chinedu.okafor' -Action Terminate -TargetOU 'OU=Disabled,DC=lab,DC=local'
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [string]$Identity,

    [Parameter(Mandatory = $true)]
    # Bug #18: all 6 actions listed including Move
    [ValidateSet('Enable', 'Disable', 'Unlock', 'ResetPassword', 'Move', 'Terminate')]
    [string]$Action,

    [string]$TargetOU = '',

    [string]$Reason = '',

    [string]$AuditLogPath = '',

    [string]$Server,

    [PSCredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$rootDir   = Split-Path -Parent $scriptDir

# Load Module
Import-Module (Join-Path -Path $rootDir -ChildPath 'ADAutoX.psd1') -Force

if ([string]::IsNullOrWhiteSpace($AuditLogPath)) {
    $AuditLogPath = Join-Path -Path $rootDir -ChildPath 'ADAutoX-Audit.jsonl'
}

$correlationId = New-ADAutoXCorrelationId
Write-ADAutoXConsole -Message "Lifecycle Action '$Action' requested for '$Identity' [CorrelationID: $correlationId]" -Level Info

try {
    # Bug #15: always connect and look up the user, even in -WhatIf mode, to validate the identity
    $adInfo = Initialize-ADAutoXContext -Server $Server -Credential $Credential
    $user   = Get-ADUser -Identity $Identity -Properties Description -ErrorAction Stop

    if ($WhatIfPreference) {
        Write-ADAutoXConsole -Message "[WhatIf Mode] Would perform '$Action' on: $($user.DistinguishedName) (Account enabled: $($user.Enabled))" -Level Warning
        return
    }

    switch ($Action) {
        'Enable' {
            if ($PSCmdlet.ShouldProcess($user.DistinguishedName, 'Enable AD User')) {
                Enable-ADAccount -Identity $user.DistinguishedName -ErrorAction Stop
                Write-ADAutoXConsole -Message "Account enabled for '$Identity'." -Level Success
                Write-ADAutoXLogRecord -LogPath $AuditLogPath -Action 'EnableUser' -Target $user.DistinguishedName -Status 'Succeeded' -CorrelationId $correlationId
            }
        }
        'Disable' {
            if ($PSCmdlet.ShouldProcess($user.DistinguishedName, 'Disable AD User')) {
                Disable-ADAccount -Identity $user.DistinguishedName -ErrorAction Stop
                Write-ADAutoXConsole -Message "Account disabled for '$Identity'." -Level Success
                Write-ADAutoXLogRecord -LogPath $AuditLogPath -Action 'DisableUser' -Target $user.DistinguishedName -Status 'Succeeded' -CorrelationId $correlationId
            }
        }
        'Unlock' {
            if ($PSCmdlet.ShouldProcess($user.DistinguishedName, 'Unlock AD User')) {
                Unlock-ADAccount -Identity $user.DistinguishedName -ErrorAction Stop
                Write-ADAutoXConsole -Message "Account unlocked for '$Identity'." -Level Success
                Write-ADAutoXLogRecord -LogPath $AuditLogPath -Action 'UnlockUser' -Target $user.DistinguishedName -Status 'Succeeded' -CorrelationId $correlationId
            }
        }
        'ResetPassword' {
            if ($PSCmdlet.ShouldProcess($user.DistinguishedName, 'Reset AD User Password')) {
                $newPwd = New-ADAutoXRandomPassword -Length 20
                $secPwd = ConvertTo-SecureString $newPwd -AsPlainText -Force
                # BUG-06: Force password change at logon
                Set-ADAccountPassword -Identity $user.DistinguishedName -NewPassword $secPwd -Reset -ErrorAction Stop
                Set-ADUser -Identity $user.DistinguishedName -ChangePasswordAtLogon $true -ErrorAction Stop
                
                # BUG-06: Do NOT print the password to the console. Hand it over securely.
                # In a real script, this would go to a vault or a secured file.
                $pwdPath = Join-Path -Path $env:TEMP -ChildPath "ResetPwd-$Identity.txt"
                $newPwd | Out-File -FilePath $pwdPath -Encoding UTF8
                Protect-ADAutoXFileAcl -Path $pwdPath | Out-Null
                
                Write-ADAutoXConsole -Message "Password reset for '$Identity'. Password saved to secure file: $pwdPath (User must change at logon)." -Level Success
                Write-ADAutoXLogRecord -LogPath $AuditLogPath -Action 'ResetPassword' -Target $user.DistinguishedName -Status 'Succeeded' -CorrelationId $correlationId
            }
        }
        'Move' {
            if ([string]::IsNullOrWhiteSpace($TargetOU)) {
                throw 'Move action requires -TargetOU parameter.'
            }
            if ($PSCmdlet.ShouldProcess($user.DistinguishedName, "Move User to $TargetOU")) {
                Move-ADObject -Identity $user.DistinguishedName -TargetPath $TargetOU -ErrorAction Stop
                Write-ADAutoXConsole -Message "User '$Identity' moved to '$TargetOU'." -Level Success
                Write-ADAutoXLogRecord -LogPath $AuditLogPath -Action 'MoveUser' -Target $user.DistinguishedName -Status 'Succeeded' -Details "Moved to $TargetOU" -CorrelationId $correlationId
            }
        }
        'Terminate' {
            if ($PSCmdlet.ShouldProcess($user.DistinguishedName, 'Terminate AD User')) {
                # BUG-11 (Guardrails): Prevent terminating privileged accounts
                $userGroups = @(Get-ADPrincipalGroupMembership -Identity $user.DistinguishedName -ErrorAction SilentlyContinue)
                if ($userGroups.Name -contains 'Domain Admins' -or $userGroups.Name -contains 'Enterprise Admins') {
                    throw "GUARDRAIL BLOCK: Cannot terminate highly privileged account '$Identity'."
                }

                # BUG-12 (Proper Offboarding): 
                # 1. Disable account
                Disable-ADAccount -Identity $user.DistinguishedName -ErrorAction Stop
                
                # 2. Randomize password to kill active sessions/prevent re-use
                $killPwd = New-ADAutoXRandomPassword -Length 30
                $secKillPwd = ConvertTo-SecureString $killPwd -AsPlainText -Force
                Set-ADAccountPassword -Identity $user.DistinguishedName -NewPassword $secKillPwd -Reset -ErrorAction SilentlyContinue

                # 3. Hide from Exchange GAL
                try {
                    Set-ADUser -Identity $user.DistinguishedName -Replace @{msExchHideFromAddressLists=$true} -ErrorAction SilentlyContinue
                } catch {}

                # 4. Remove from all groups except Primary Group (Domain Users)
                foreach ($g in $userGroups) {
                    # Do not attempt to remove from Primary Group
                    if ($g.ObjectGUID -ne $user.PrimaryGroup) {
                        Remove-ADGroupMember -Identity $g -Members $user.DistinguishedName -Confirm:$false -ErrorAction SilentlyContinue
                    }
                }

                $existingDescription = if ($null -ne $user.Description -and $user.Description.Length -gt 0) {
                    "$($user.Description) | "
                } else { '' }
                $terminationNote = "${existingDescription}TERMINATED on $((Get-Date).ToString('yyyy-MM-dd'))" + $(if ($Reason) { " - Reason: $Reason" } else { '' })
                Set-ADUser -Identity $user.DistinguishedName -Description $terminationNote -ErrorAction Stop

                if ($TargetOU) {
                    Move-ADObject -Identity $user.DistinguishedName -TargetPath $TargetOU -ErrorAction Stop
                }
                Write-ADAutoXConsole -Message "User '$Identity' terminated and fully offboarded (Disabled, Groups Removed, GAL Hidden)." -Level Success
                Write-ADAutoXLogRecord -LogPath $AuditLogPath -Action 'TerminateUser' -Target $user.DistinguishedName -Status 'Succeeded' -Details $terminationNote -CorrelationId $correlationId
            }
        }
    }
}
catch {
    Write-ADAutoXConsole -Message "Error during Lifecycle Action '$Action': $($_.Exception.Message)" -Level Error
    throw
}
finally {
    Clear-ADAutoXContext
}
