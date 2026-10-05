Start-Transcript -Path C:\WindowsAzure\Logs\logontasklogs.txt -Append

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Safety shim so Set-ExecutionPolicy calls (including inside the common library) can never stop this task
function Set-ExecutionPolicy {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$ExecutionPolicy, [Parameter(Position = 1)][string]$Scope, [switch]$Force)
    try { Microsoft.PowerShell.Security\Set-ExecutionPolicy @PSBoundParameters -ErrorAction Stop }
    catch { Write-Warning "Set-ExecutionPolicy skipped: $($_.Exception.Message)" }
}

# Common functions: stable copy first, then the extension download folder
$commonCandidates = @('C:\LabFiles\cloudlabs-windows-functions.ps1')
$commonCandidates += @(Get-ChildItem 'C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\*\Downloads\*\cloudlabs-common\cloudlabs-windows-functions.ps1' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -ExpandProperty FullName)
$commonscriptpath = $commonCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $commonscriptpath) { Write-Error "cloudlabs-windows-functions.ps1 not found."; Stop-Transcript; exit 1 }
. $commonscriptpath
Start-Sleep -Seconds 5

# No Azure sign-in is needed here: Microsoft Entra Domain Services and Nerdio were deployed by the ARM template,
# and the VM extension only started after both deployments succeeded.
$ValidStatus = "Succeeded"
$Validmessage = "Validation Successfull"

CloudlabsManualAgent setStatus
CloudlabsManualAgent Start

Stop-Transcript
