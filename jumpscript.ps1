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

    # Optional: if CloudLabs passes a service principal, it is used instead of the user
    # credential for Azure sign-in (user password sign-in does not work when the lab user
    # authenticates with a Temporary Access Pass / MFA).
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

# --------------------------------------------------------------------------------------
# Helper functions
# --------------------------------------------------------------------------------------

# Polls an ARM deployment until it reaches a terminal state or the timeout expires.
# Returns: Succeeded | Failed | Canceled | TimedOut
function Wait-ArmDeployment {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutMinutes = 60,
        [int]$PollSeconds = 30
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $dep = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
        $state = if ($dep) { $dep.ProvisioningState } else { 'NotFound' }
        Write-Host "[$Name] provisioning state: $state"
        if ($state -in @('Succeeded', 'Failed', 'Canceled')) { return $state }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)
    return 'TimedOut'
}

# Signs in to Azure. Uses a service principal when one is supplied, otherwise the lab user credential.
function Connect-LabAzure {
    if ($ServicePrincipalId -and $ServicePrincipalSecret) {
        $spSecret = ConvertTo-SecureString -String $ServicePrincipalSecret -AsPlainText -Force
        $spCred = New-Object System.Management.Automation.PSCredential($ServicePrincipalId, $spSecret)
        Connect-AzAccount -ServicePrincipal -Tenant $AzureTenantID -Credential $spCred -ErrorAction Stop | Out-Null
        return 'ServicePrincipal'
    }
    $userSecret = ConvertTo-SecureString -String $AzurePassword -AsPlainText -Force
    $userCred = New-Object System.Management.Automation.PSCredential($AzureUserName, $userSecret)
    Connect-AzAccount -Credential $userCred -ErrorAction Stop | Out-Null
    return 'UserCredential'
}

# --------------------------------------------------------------------------------------
# VM setup
# --------------------------------------------------------------------------------------

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

# Keep a stable copy of the common functions for logontask.ps1 (the extension download folder name can change)
Copy-Item -Path $commonscriptpath -Destination "$LabFilesDirectory\cloudlabs-windows-functions.ps1" -Force

# If a service principal was supplied, make it available to logontask.ps1 through AzureCreds.ps1
# (same variable names as SPtoAzureCredFiles in the common library; the desktop .txt copy is not touched)
if ($ServicePrincipalId -and $ServicePrincipalSecret -and (Test-Path "$LabFilesDirectory\AzureCreds.ps1")) {
    $spAppLine = '$AzureServicePrincipalAppID = ''' + ($ServicePrincipalId -replace "'", "''") + ''''
    $spKeyLine = '$AzureServicePrincipalSecretKey = ''' + ($ServicePrincipalSecret -replace "'", "''") + ''''
    Add-Content -Path "$LabFilesDirectory\AzureCreds.ps1" -Value $spAppLine
    Add-Content -Path "$LabFilesDirectory\AzureCreds.ps1" -Value $spKeyLine
}

$WebClient = New-Object System.Net.WebClient
$WebClient.DownloadFile("https://raw.githubusercontent.com/vishalv-spektra/Test-Script/refs/heads/main/logontask.ps1", "$LabFilesDirectory\logontask.ps1")

# The Remote Desktop (MSRDC) client install was removed: that client is retired and the lab uses the web client.

# --------------------------------------------------------------------------------------
# Sign in to Azure
# --------------------------------------------------------------------------------------
try {
    $signInMethod = Connect-LabAzure
    Write-Host "Signed in to Azure using: $signInMethod"
    Set-AzContext -SubscriptionId $AzureSubscriptionID | Out-Null
}
catch {
    Write-Error "Azure sign-in failed: $_"
    $Validstatus = "Failed"
    $Validmessage = "Azure sign-in failed in jumpvmscript.ps1. If the lab user uses a Temporary Access Pass, supply a service principal."
    CloudlabsManualAgent setStatus
    Stop-Transcript
    exit 1
}

$domainName = $AzureUserName.Split("@")[1]
$VnetName = "aadds-vnet"
$templateSourceLocation = "https://experienceazure.blob.core.windows.net/templates/nerdio/deploy-01.json"

# --------------------------------------------------------------------------------------
# Prerequisites for Microsoft Entra Domain Services
# --------------------------------------------------------------------------------------
# The Microsoft.AAD resource provider is still the namespace for Microsoft Entra Domain Services.
Register-AzResourceProvider -ProviderNamespace Microsoft.AAD | Out-Null

# Domain Controller Services first-party application
if (!($AADDSServicePrincipal = Get-AzADServicePrincipal -ApplicationId "2565bd9d-da50-47d4-8b85-4c97f669dc36")) {
    $AADDSServicePrincipal = New-AzADServicePrincipal -ApplicationId "2565bd9d-da50-47d4-8b85-4c97f669dc36" -ErrorAction SilentlyContinue
}

# The group name 'AAD DC Administrators' is required by the service - do not rename it.
if (!($AADDSGroup = Get-AzADGroup -DisplayName "AAD DC Administrators")) {
    $AADDSGroup = New-AzADGroup -DisplayName "AAD DC Administrators" -Description "Delegated group to administer Microsoft Entra Domain Services" -MailNickName "AADDCAdministrators" -ErrorAction SilentlyContinue
}

# Add the user to the 'AAD DC Administrators' group.
Add-AzADGroupMember -MemberUserPrincipalName $AzureUserName -TargetGroupObjectId $($AADDSGroup).Id -ErrorAction SilentlyContinue

#Get RG Name
$resourceGroup = (Get-AzResourceGroup -Name "AVD-*")
$resourceGroupName = $resourceGroup[0].ResourceGroupName
$location = $resourceGroup[0].Location
$Params = @{
    "domainName" = $domainName
}

# Deploy the Microsoft Entra Domain Services template (explicit name so it can be polled)
try {
    New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName -Name "deploy-01" -TemplateUri $templateSourceLocation -TemplateParameterObject $Params -ErrorAction Stop | Out-Null
}
catch {
    Write-Warning "deploy-01 (Microsoft Entra Domain Services) threw: $_"
}

# Wait for the domain controllers to settle
Start-Sleep -Seconds 300

#Update Virtual Network DNS servers
$Vnet = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $resourceGroupName
$Vnet.DhcpOptions.DnsServers = @()
$NICs = Get-AzResource -ResourceGroupName $resourceGroupName -ResourceType "Microsoft.Network/networkInterfaces" -Name "aadds*"
if (-not $NICs) { Write-Warning "No 'aadds*' network interfaces found - DNS servers will not be updated." }
ForEach ($NIC in $NICs) {
    $Nicip = (Get-AzNetworkInterface -Name $($NIC.Name) -ResourceGroupName $resourceGroupName).IpConfigurations[0].PrivateIpAddress
    ($Vnet.DhcpOptions.DnsServers).Add($Nicip)
}
$Vnet | Set-AzVirtualNetwork | Out-Null

# Confirm the Entra Domain Services deployment reached a terminal state (no more endless loop)
$aaddsStatus = Wait-ArmDeployment -ResourceGroupName $resourceGroupName -Name "deploy-01" -TimeoutMinutes 60

# --------------------------------------------------------------------------------------
# Nerdio Manager for MSP deployment
# --------------------------------------------------------------------------------------
$deploymentFailed = $false
$nerdioStatus = 'Skipped'

if ($aaddsStatus -eq 'Succeeded') {
    $nerdioresourceGroup = (Get-AzResourceGroup -Name "NMM-*")
    $nerdioresourceGroupName = $nerdioresourceGroup[0].ResourceGroupName
    $location = $nerdioresourceGroup[0].Location

    $nerdiotemplateSourceLocation = "https://experienceazure.blob.core.windows.net/templates/nerdio/deploy-02.json"

    try {
        Set-AzMarketplaceTerms -Publisher 'nerdio' -Product 'nmm' -Name 'nmm-plan' -Accept | Out-Null
    }
    catch {
        Write-Warning "Accepting Nerdio Marketplace terms failed (check that plan 'nmm-plan' still exists): $_"
    }

    try {
        New-AzResourceGroupDeployment -ResourceGroupName $nerdioresourceGroupName -TemplateUri $nerdiotemplateSourceLocation -Name "deploynerdio" -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warning "deploynerdio threw: $_"
    }

    $nerdioStatus = Wait-ArmDeployment -ResourceGroupName $nerdioresourceGroupName -Name "deploynerdio" -TimeoutMinutes 45
}
else {
    Write-Warning "Microsoft Entra Domain Services deployment ended as '$aaddsStatus' - skipping Nerdio deployment."
}

if ($aaddsStatus -eq 'Succeeded' -and $nerdioStatus -eq 'Succeeded') {
    $Validstatus = "Pending"
    $Validmessage = "Main Deployment is successful, logontask is pending"

    # Scheduled Task for the post-logon configuration
    $Username = if ($jvmadminUsername) { $jvmadminUsername } else { "demouser" }
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $User = "$($env:ComputerName)\$Username"
    $Action = New-ScheduledTaskAction -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\Powershell.exe" -Argument "-executionPolicy Unrestricted -File $LabFilesDirectory\logontask.ps1"
    Register-ScheduledTask -TaskName "Setup" -Trigger $Trigger -User $User -Action $Action -RunLevel Highest -Force | Out-Null
}
else {
    Write-Warning "Validation Failed - see log output (Entra Domain Services: $aaddsStatus, Nerdio: $nerdioStatus)"
    $deploymentFailed = $true
    $Validstatus = "Failed"
    $Validmessage = "ARM template deployment failed (Entra Domain Services: $aaddsStatus, Nerdio: $nerdioStatus)"
}

# Auto logon for the VM admin user
$Username = if ($jvmadminUsername) { $jvmadminUsername } else { "demouser" }
$RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $RegistryPath 'AutoAdminLogon' -Value "1" -Type String
Set-ItemProperty $RegistryPath 'DefaultUsername' -Value "$Username" -Type String
Set-ItemProperty $RegistryPath 'DefaultPassword' -Value "$jvmadminPassword" -Type String

# Report status to the CloudLabs agent (keeps 'Failed' if the deployment failed)
if (-not $deploymentFailed) {
    $Validstatus = "Pending"
    $Validmessage = "Post Deployment is Pending"
}
CloudlabsManualAgent setStatus

# --------------------------------------------------------------------------------------
# Reset the lab user password (Az module; the deprecated AzureAD module is no longer used)
# Non-fatal: a failure here is logged but does not fail the deployment.
# --------------------------------------------------------------------------------------
try {
    $resetSecret = ConvertTo-SecureString -String $AzurePassword -AsPlainText -Force
    $labUser = Get-AzADUser -UserPrincipalName $AzureUserName
    if ($labUser) {
        Update-AzADUser -ObjectId $labUser.Id -Password $resetSecret -ErrorAction Stop
        Write-Host "Lab user password reset completed."
    }
    else {
        Write-Warning "Lab user $AzureUserName not found - password reset skipped."
    }
}
catch {
    Write-Warning "Lab user password reset skipped/failed: $_"
}

Stop-Transcript
Start-Sleep -Seconds 10
Restart-Computer -Force
