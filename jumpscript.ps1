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
    $trainerUserPassword,

    [string]
    $ServicePrincipalId,

    [string]
    $ServicePrincipalSecret
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

# --------------------------------------------------------------------------------------
# One-time prerequisites that ARM cannot create (service principal sign-in; user/TAP sign-in is blocked by MFA)
#   - Microsoft.AAD resource provider
#   - Domain Controller Services application (2565bd9d-...)
#   - 'AAD DC Administrators' group (+ the lab user as member)
#   - Nerdio Marketplace terms
# The Domain Services and Nerdio deployments themselves run as nested deployments in the ARM template
# after this extension finishes.
# --------------------------------------------------------------------------------------
$prereqFailed = $false
if ($ServicePrincipalId -and $ServicePrincipalSecret) {
    # Make the service principal available to logontask.ps1 (same variable names as the common library)
    if (Test-Path "$LabFilesDirectory\AzureCreds.ps1") {
        $q = [char]39
        Add-Content -Path "$LabFilesDirectory\AzureCreds.ps1" -Value ('$AzureServicePrincipalAppID = ' + $q + ($ServicePrincipalId -replace $q, "$q$q") + $q)
        Add-Content -Path "$LabFilesDirectory\AzureCreds.ps1" -Value ('$AzureServicePrincipalSecretKey = ' + $q + ($ServicePrincipalSecret -replace $q, "$q$q") + $q)
    }

    try {
        $spSecret = ConvertTo-SecureString -String $ServicePrincipalSecret -AsPlainText -Force
        $spCred = New-Object System.Management.Automation.PSCredential($ServicePrincipalId, $spSecret)
        Connect-AzAccount -ServicePrincipal -Tenant $AzureTenantID -Credential $spCred -ErrorAction Stop | Out-Null
        Set-AzContext -SubscriptionId $AzureSubscriptionID | Out-Null

        Register-AzResourceProvider -ProviderNamespace Microsoft.AAD | Out-Null

        $created = $false
        if (!($AADDSServicePrincipal = Get-AzADServicePrincipal -ApplicationId "2565bd9d-da50-47d4-8b85-4c97f669dc36")) {
            $AADDSServicePrincipal = New-AzADServicePrincipal -ApplicationId "2565bd9d-da50-47d4-8b85-4c97f669dc36" -ErrorAction Stop
            $created = $true
        }
        # The group name 'AAD DC Administrators' is required by the service - do not rename it.
        if (!($AADDSGroup = Get-AzADGroup -DisplayName "AAD DC Administrators")) {
            $AADDSGroup = New-AzADGroup -DisplayName "AAD DC Administrators" -Description "Delegated group to administer Microsoft Entra Domain Services" -MailNickName "AADDCAdministrators" -ErrorAction Stop
            $created = $true
        }
        Add-AzADGroupMember -MemberUserPrincipalName $AzureUserName -TargetGroupObjectId $($AADDSGroup).Id -ErrorAction SilentlyContinue

        try { Set-AzMarketplaceTerms -Publisher 'nerdio' -Product 'nmm' -Name 'nmm-plan' -Accept | Out-Null }
        catch { Write-Warning "Accepting Nerdio Marketplace terms failed (check that plan 'nmm-plan' still exists): $_" }

        # Give directory replication a moment before Domain Services is deployed
        if ($created) { Start-Sleep -Seconds 90 }
    }
    catch {
        Write-Error "Prerequisite setup with the service principal failed: $_"
        $prereqFailed = $true
    }
}
else {
    Write-Warning "No service principal supplied - assuming the Domain Services application, the 'AAD DC Administrators' group and the Nerdio Marketplace terms already exist."
}

if ($prereqFailed) {
    $Validstatus = "Failed"
    $Validmessage = "Prerequisite setup failed (service principal sign-in or directory permissions) - see CloudLabsCustomScriptExtension.txt"
    CloudlabsManualAgent setStatus
    Stop-Transcript
    exit 1
}

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
