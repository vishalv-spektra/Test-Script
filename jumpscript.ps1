Param (
    [Parameter(Mandatory = $true)]
    [string]
    $AzureUserName,

    [string]
    $AzurePassword,

    [string]
    $AzureTenantID,

    [string]
    $AzureSubscriptionID,

    [string]
    $ODLID,

    [string]
    $DeploymentID,

    [string]
    $InstallCloudLabsShadow,

    [string]
    $jvmadminUsername,

    [string]
    $jvmadminPassword,

    [string]
    $trainerUserName,

    [string]
    $trainerUserPassword
)

Start-Transcript -Path C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension.txt -Append

# TLS 1.2 only
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Safety shim: the extension starts this script with "-ExecutionPolicy Unrestricted" (process scope).
# Any Set-ExecutionPolicy call at a less specific scope - including the ones inside the shared
# cloudlabs-windows-functions.ps1 library - can raise "overridden by a policy defined at a more specific
# scope" and stop the script. This function shadows the cmdlet so such a call can never fail the deployment.
function Set-ExecutionPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$ExecutionPolicy,
        [Parameter(Position = 1)][string]$Scope,
        [switch]$Force
    )
    try {
        Microsoft.PowerShell.Security\Set-ExecutionPolicy @PSBoundParameters -ErrorAction Stop
    }
    catch {
        Write-Warning "Set-ExecutionPolicy skipped: $($_.Exception.Message)"
    }
}

# NOTE: Do NOT call Set-ExecutionPolicy -Scope CurrentUser here. The extension starts this script with
# "-ExecutionPolicy Unrestricted" (process scope), which overrides user scope and makes that call
# throw "overridden by a policy defined at a more specific scope".

# tls issue fix
If (-Not (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319'))
{
    New-Item 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319' -Force | Out-Null
}
New-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319' -Name 'SystemDefaultTlsVersions' -Value '1' -PropertyType 'DWord' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319' -Name 'SchUseStrongCrypto' -Value '1' -PropertyType 'DWord' -Force | Out-Null

If (-Not (Test-Path 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319'))
{
    New-Item 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' -Force | Out-Null
}
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' -Name 'SystemDefaultTlsVersions' -Value '1' -PropertyType 'DWord' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' -Name 'SchUseStrongCrypto' -Value '1' -PropertyType 'DWord' -Force | Out-Null

If (-Not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server'))
{
    New-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server' -Force | Out-Null
}
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server' -Name 'Enabled' -Value '1' -PropertyType 'DWord' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server' -Name 'DisabledByDefault' -Value '0' -PropertyType 'DWord' -Force | Out-Null

If (-Not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client'))
{
    New-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client' -Force | Out-Null
}
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client' -Name 'Enabled' -Value '1' -PropertyType 'DWord' -Force | Out-Null

#Import Common Functions
$path = (Get-Location).Path
$commonscriptpath = Join-Path $path "cloudlabs-common\cloudlabs-windows-functions.ps1"
if (-not (Test-Path $commonscriptpath)) {
    Write-Error "Common functions file not found at $commonscriptpath"
    Stop-Transcript
    exit 1
}
. $commonscriptpath

#Use the commonfunction to install the required files for cloudlabsagent service
CloudlabsManualAgent Install

# Run Imported functions from cloudlabs-windows-functions.ps1
# (WindowsServerCommon already runs InstallChocolatey and InstallEdgeChromium - do not call them again)
WindowsServerCommon
InstallAzPowerShellModule

# Safety net: make sure the Az module is really there before using it
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Warning "Az module not found after InstallAzPowerShellModule - retrying install."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction SilentlyContinue | Out-Null
    Install-Module -Name Az -Repository PSGallery -Scope AllUsers -AllowClobber -Force
}

Start-Sleep -Seconds 30

#ENABLE VM SHADOW
CreateCredFile $AzureUserName $AzurePassword $AzureTenantID $AzureSubscriptionID $DeploymentID
#Enable Cloudlabs Embedded Shadow Feature (pass the real VM admin username, the old call used an undefined variable)
Enable-CloudLabsEmbeddedShadow $jvmadminUsername $trainerUserName $trainerUserPassword

New-Item -ItemType directory -Path C:\LabFiles -Force | Out-Null
$LabFilesDirectory = "C:\LabFiles"

# Stable copy of the common functions for logontask.ps1
Copy-Item -Path $commonscriptpath -Destination "$LabFilesDirectory\cloudlabs-windows-functions.ps1" -Force

$WebClient = New-Object System.Net.WebClient
$WebClient.DownloadFile("https://raw.githubusercontent.com/vishalv-spektra/Test-Script/refs/heads/main/logontask.ps1", "$LabFilesDirectory\logontask.ps1")

# No Azure sign-in in this script: Microsoft Entra Domain Services and Nerdio are deployed by the ARM template,
# and this extension only runs after both succeed.
$Username = if ($jvmadminUsername) { $jvmadminUsername } else { "demouser" }
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$User = "$($env:ComputerName)\$Username"
$Action = New-ScheduledTaskAction -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\Powershell.exe" -Argument "-executionPolicy Unrestricted -File $LabFilesDirectory\logontask.ps1"
Register-ScheduledTask -TaskName "Setup" -Trigger $Trigger -User $User -Action $Action -RunLevel Highest -Force | Out-Null

# Auto logon for the VM admin user
$RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $RegistryPath 'AutoAdminLogon' -Value "1" -Type String
Set-ItemProperty $RegistryPath 'DefaultUsername' -Value "$Username" -Type String
Set-ItemProperty $RegistryPath 'DefaultPassword' -Value "$jvmadminPassword" -Type String

$Validstatus = "Pending"
$Validmessage = "Post Deployment is Pending"
CloudlabsManualAgent setStatus

Stop-Transcript
Start-Sleep -Seconds 10
Restart-Computer -Force
