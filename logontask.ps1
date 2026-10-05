Start-Transcript -Path C:\WindowsAzure\Logs\logontasklogs.txt -Append

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Safety shim: never let Set-ExecutionPolicy ("overridden by a policy defined at a more specific scope")
# stop this task, including calls made inside the shared common-functions library.
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

# The Remote Desktop (MSRDC) client install was removed: that client is retired and the lab uses the web client.

#Import Common Functions (stable copy first, then the extension download folder)
$commonCandidates = @('C:\LabFiles\cloudlabs-windows-functions.ps1')
$commonCandidates += @(Get-ChildItem 'C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\*\Downloads\*\cloudlabs-common\cloudlabs-windows-functions.ps1' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -ExpandProperty FullName)
$commonscriptpath = $commonCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $commonscriptpath) {
    Write-Error "cloudlabs-windows-functions.ps1 not found."
    Stop-Transcript
    exit 1
}
. $commonscriptpath
Start-Sleep -Seconds 5

. C:\LabFiles\AzureCreds.ps1

$userName = $AzureUserName
$password = $AzurePassword
$subscriptionId = $AzureSubscriptionID
$TenantID = $AzureTenantID
$resourceGroup = "AVD-RG"

# --------------------------------------------------------------------------------------
# Sign in to Azure (service principal when available, otherwise the lab user credential)
# --------------------------------------------------------------------------------------
$signedIn = $false
try {
    if ($AzureServicePrincipalAppID -and $AzureServicePrincipalSecretKey) {
        $spSecret = ConvertTo-SecureString -String $AzureServicePrincipalSecretKey -AsPlainText -Force
        $spCred = New-Object System.Management.Automation.PSCredential($AzureServicePrincipalAppID, $spSecret)
        Connect-AzAccount -ServicePrincipal -Tenant $TenantID -Credential $spCred -ErrorAction Stop | Out-Null
    }
    else {
        $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($userName, $securePassword)
        Connect-AzAccount -Credential $cred -ErrorAction Stop | Out-Null
    }
    Set-AzContext -SubscriptionId $subscriptionId | Out-Null
    $signedIn = $true
}
catch {
    Write-Error "Azure sign-in failed in logontask.ps1: $_"
}

$tenantName = $AzureUserName.Split("@")[1]
$ValidStatus = "Failed"
$Validmessage = "Validation Failed"

if ($signedIn) {
    # ----------------------------------------------------------------------------------
    # Wait for Microsoft Entra Domain Services to report 'Running' (with a timeout)
    # ----------------------------------------------------------------------------------
    $timeoutMinutes = 120
    $deadline = (Get-Date).AddMinutes($timeoutMinutes)
    $status = 'Unknown'

    do {
        try {
            $tokenResult = Get-AzAccessToken -TenantId $TenantID -ErrorAction Stop
            $token = $tokenResult.Token
            # Newer Az versions return the token as a SecureString
            if ($token -is [System.Security.SecureString]) {
                $token = [System.Net.NetworkCredential]::new('', $token).Password
            }
            $headers = @{ 'Authorization' = "Bearer $token"; 'Accept' = 'application/json' }
            $URI = "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.AAD/DomainServices/${tenantName}?api-version=2021-05-01&healthdata=true"
            $response = Invoke-RestMethod -UseBasicParsing -Uri $URI -Method GET -Headers $headers -ErrorAction Stop
            $status = $response.properties.replicaSets[0].serviceStatus
        }
        catch {
            Write-Warning "Could not read Entra Domain Services status: $_"
            $status = 'Unknown'
        }

        Write-Host "Microsoft Entra Domain Services status: $status"
        if ($status -ne 'Running') { Start-Sleep -Seconds 300 }
    }
    until ($status -eq 'Running' -or (Get-Date) -gt $deadline)

    if ($status -eq 'Running') {
        $ValidStatus = "Succeeded"
        $Validmessage = "Validation Successfull"
    }
    else {
        $ValidStatus = "Failed"
        $Validmessage = "Validation Failed - Entra Domain Services did not reach 'Running' (last status: $status)"
    }
}
else {
    $Validmessage = "Validation Failed - Azure sign-in failed in logontask.ps1"
}

#Set the final deployment status
CloudlabsManualAgent setStatus

#Start the cloudlabs agent service
CloudlabsManualAgent Start

Stop-Transcript

# Cleanup (best effort - these must never fail the task)
if ($signedIn) {
    Remove-AzResourceGroupDeployment -ResourceGroupName $resourceGroup -Name deploy-01 -ErrorAction SilentlyContinue
    Remove-AzResourceGroup -Name NetworkWatcherRG -Force -ErrorAction SilentlyContinue
}
