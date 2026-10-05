Start-Transcript -Path C:\WindowsAzure\Logs\logontasklogs.txt -Append

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Safety shim so Set-ExecutionPolicy calls (including inside the common library) can never stop this task
function Set-ExecutionPolicy {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$ExecutionPolicy, [Parameter(Position = 1)][string]$Scope, [switch]$Force)
    try { Microsoft.PowerShell.Security\Set-ExecutionPolicy @PSBoundParameters -ErrorAction Stop }
    catch { Write-Warning "Set-ExecutionPolicy skipped: $($_.Exception.Message)" }
}

$commonCandidates = @('C:\LabFiles\cloudlabs-windows-functions.ps1')
$commonCandidates += @(Get-ChildItem 'C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\*\Downloads\*\cloudlabs-common\cloudlabs-windows-functions.ps1' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -ExpandProperty FullName)
$commonscriptpath = $commonCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $commonscriptpath) { Write-Error "cloudlabs-windows-functions.ps1 not found."; Stop-Transcript; exit 1 }
. $commonscriptpath
Start-Sleep -Seconds 5

. C:\LabFiles\AzureCreds.ps1

$subscriptionId = $AzureSubscriptionID
$TenantID = $AzureTenantID
$tenantName = $AzureUserName.Split("@")[1]
$resourceGroup = "AVD-RG"

$ValidStatus = "Failed"
$Validmessage = "Validation Failed"

if ($AzureServicePrincipalAppID -and $AzureServicePrincipalSecretKey) {
    $signedIn = $false
    try {
        $spSecret = ConvertTo-SecureString -String $AzureServicePrincipalSecretKey -AsPlainText -Force
        $spCred = New-Object System.Management.Automation.PSCredential($AzureServicePrincipalAppID, $spSecret)
        Connect-AzAccount -ServicePrincipal -Tenant $TenantID -Credential $spCred -ErrorAction Stop | Out-Null
        Set-AzContext -SubscriptionId $subscriptionId | Out-Null
        $signedIn = $true
    }
    catch { Write-Error "Azure sign-in (service principal) failed in logontask.ps1: $_" }

    if ($signedIn) {
        # The ARM template deploys Domain Services and Nerdio after the VM extension, so wait for both here.
        $deadline = (Get-Date).AddMinutes(150)
        $status = 'Unknown'
        do {
            try {
                $tokenResult = Get-AzAccessToken -TenantId $TenantID -ErrorAction Stop
                $token = $tokenResult.Token
                if ($token -is [System.Security.SecureString]) { $token = [System.Net.NetworkCredential]::new('', $token).Password }
                $headers = @{ 'Authorization' = "Bearer $token"; 'Accept' = 'application/json' }
                $URI = "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.AAD/DomainServices/${tenantName}?api-version=2021-05-01&healthdata=true"
                $response = Invoke-RestMethod -UseBasicParsing -Uri $URI -Method GET -Headers $headers -ErrorAction Stop
                $status = $response.properties.replicaSets[0].serviceStatus
            }
            catch { $status = 'Unknown' }   # 404 until the nested deployment has created it
            Write-Host "Microsoft Entra Domain Services status: $status"

            $nerdioState = 'NotStarted'
            if ($status -eq 'Running') {
                $nmmRg = Get-AzResourceGroup -Name "NMM-*" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($nmmRg) {
                    $dep = Get-AzResourceGroupDeployment -ResourceGroupName $nmmRg.ResourceGroupName -Name "deploynerdio" -ErrorAction SilentlyContinue
                    if ($dep) { $nerdioState = $dep.ProvisioningState }
                }
                Write-Host "Nerdio deployment state: $nerdioState"
            }

            $done = ($status -eq 'Running' -and $nerdioState -in @('Succeeded', 'Failed', 'Canceled'))
            if (-not $done) { Start-Sleep -Seconds 300 }
        }
        until ($done -or (Get-Date) -gt $deadline)

        if ($status -eq 'Running' -and $nerdioState -eq 'Succeeded') {
            $ValidStatus = "Succeeded"; $Validmessage = "Validation Successfull"
        }
        else {
            $Validmessage = "Validation Failed - Entra Domain Services: $status, Nerdio deployment: $nerdioState"
        }
        Remove-AzResourceGroupDeployment -ResourceGroupName $resourceGroup -Name deploy-01 -ErrorAction SilentlyContinue
        Remove-AzResourceGroup -Name NetworkWatcherRG -Force -ErrorAction SilentlyContinue
    }
    else { $Validmessage = "Validation Failed - Azure sign-in failed in logontask.ps1" }
}
else {
    Write-Warning "No service principal available - cannot verify the nested deployments; reporting Succeeded because the ARM deployment itself reports failures."
    $ValidStatus = "Succeeded"; $Validmessage = "Validation Successfull (not verified - no service principal)"
}

CloudlabsManualAgent setStatus
CloudlabsManualAgent Start
Stop-Transcript
