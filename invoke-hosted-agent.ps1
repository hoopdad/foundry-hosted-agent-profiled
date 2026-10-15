#Requires -Version 7.2

[CmdletBinding()]
param(
    [AllowNull()]
    [string]$InputBlobPath,

    [AllowNull()]
    [string]$OutputBlobPath,

    [AllowNull()]
    [string]$ManagedIdentityClientId,

    [AllowNull()]
    [string]$AgentName,

    [AllowNull()]
    [string]$EnvironmentName,

    [AllowNull()]
    [string]$AzureTenantId,

    [AllowNull()]
    [string]$AzureSubscriptionId,

    [AllowNull()]
    [string]$AzdHttpsProxy,

    [AllowNull()]
    [string]$RunMetadataPath,

    [ValidateRange(1, 7200)]
    [int]$RequestTimeoutSeconds = 1800,

    [switch]$RefreshAzureLogin,

    [switch]$Raw
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSCommandPath
$azureYamlPath = Join-Path $repoRoot 'azure.yaml'
. (Join-Path $repoRoot 'azure-cli-auth.ps1')

function Import-DotEnv {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $lineNumber = 0

    foreach ($line in Get-Content -LiteralPath $Path) {
        $lineNumber++
        $trimmedLine = $line.Trim()

        if (-not $trimmedLine -or $trimmedLine.StartsWith('#')) {
            continue
        }

        if ($trimmedLine -notmatch '^(?:export\s+)?(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<value>.*)$') {
            throw "Invalid .env entry on line $lineNumber."
        }

        $name = $Matches['name']
        $value = $Matches['value'].Trim()

        if ($value.Length -ge 2) {
            $firstCharacter = $value[0]
            $lastCharacter = $value[$value.Length - 1]

            if (
                ($firstCharacter -eq '"' -and $lastCharacter -eq '"') -or
                ($firstCharacter -eq "'" -and $lastCharacter -eq "'")
            ) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        if ($null -eq [Environment]::GetEnvironmentVariable($name, 'Process')) {
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}

function Resolve-Setting {
    param(
        [AllowNull()]
        [string]$ParameterValue,

        [Parameter(Mandatory)]
        [string]$EnvironmentVariable,

        [AllowNull()]
        [string]$DefaultValue
    )

    if (-not [string]::IsNullOrWhiteSpace($ParameterValue)) {
        return $ParameterValue
    }

    $environmentValue = [Environment]::GetEnvironmentVariable(
        $EnvironmentVariable,
        'Process'
    )

    if (-not [string]::IsNullOrWhiteSpace($environmentValue)) {
        return $environmentValue
    }

    return $DefaultValue
}

function Resolve-RequiredSetting {
    param(
        [AllowNull()]
        [string]$ParameterValue,

        [Parameter(Mandatory)]
        [string]$EnvironmentVariable,

        [Parameter(Mandatory)]
        [string]$ParameterName
    )

    $value = Resolve-Setting `
        -ParameterValue $ParameterValue `
        -EnvironmentVariable $EnvironmentVariable

    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Set $EnvironmentVariable in .env or pass -$ParameterName."
    }

    return $value
}

function Restore-ProcessEnvironmentVariable {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        $environmentPath = "Env:$Name"
        if (Test-Path -LiteralPath $environmentPath) {
            Remove-Item -LiteralPath $environmentPath
        }

        return
    }

    [Environment]::SetEnvironmentVariable(
        $Name,
        $Value.ToString(),
        'Process'
    )
}

function Write-JsonAtomically {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Value
    )

    $directory = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Path $directory -Force
    $temporaryPath = Join-Path $directory (
        '.last-invocation-{0}.tmp' -f [guid]::NewGuid().ToString('N')
    )

    try {
        $json = ($Value | ConvertTo-Json -Depth 5) + [Environment]::NewLine
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $json,
            [System.Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Assert-LoopbackSocksProxy {
    param(
        [Parameter(Mandatory)]
        [string]$Proxy
    )

    $proxyUri = $null
    if (-not [uri]::TryCreate($Proxy, [UriKind]::Absolute, [ref]$proxyUri)) {
        throw 'FOUNDRY_AZD_HTTPS_PROXY must be an absolute proxy URI.'
    }

    if (
        $proxyUri.Scheme -ine 'socks5' -or
        $proxyUri.Host -notin @('127.0.0.1', 'localhost') -or
        $proxyUri.Port -le 0 -or
        $proxyUri.UserInfo
    ) {
        throw 'FOUNDRY_AZD_HTTPS_PROXY must use socks5://127.0.0.1:<port> without credentials.'
    }

    $client = [System.Net.Sockets.TcpClient]::new()

    try {
        $connectTask = $client.ConnectAsync($proxyUri.Host, $proxyUri.Port)
        if (-not $connectTask.Wait([TimeSpan]::FromSeconds(2))) {
            throw 'Timed out waiting for the local proxy listener.'
        }
    }
    catch {
        throw (
            "The SSH SOCKS proxy is not reachable at $Proxy. " +
            'Start the tunnel configured for this listener, or clear ' +
            'FOUNDRY_AZD_HTTPS_PROXY when direct connectivity is supported.'
        )
    }
    finally {
        $client.Dispose()
    }
}

function Assert-HttpsBlobPath {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Value
    )

    $blobUri = $null
    $trimmedValue = $Value.Trim()

    if (
        -not [uri]::TryCreate(
            $trimmedValue,
            [UriKind]::Absolute,
            [ref]$blobUri
        ) -or
        $blobUri.Scheme -ine 'https' -or
        [string]::IsNullOrWhiteSpace($blobUri.Host) -or
        $blobUri.UserInfo -or
        $blobUri.Fragment
    ) {
        throw "$Name must be an absolute HTTPS Blob URL without user information or a fragment."
    }

    return $trimmedValue
}

Import-DotEnv -Path (Join-Path $repoRoot '.env')

$InputBlobPath = Resolve-RequiredSetting `
    -ParameterValue $InputBlobPath `
    -EnvironmentVariable 'FOUNDRY_INPUT_BLOB_PATH' `
    -ParameterName 'InputBlobPath'
$OutputBlobPath = Resolve-RequiredSetting `
    -ParameterValue $OutputBlobPath `
    -EnvironmentVariable 'FOUNDRY_OUTPUT_BLOB_PATH' `
    -ParameterName 'OutputBlobPath'
$AgentName = Resolve-Setting -ParameterValue $AgentName `
    -EnvironmentVariable 'FOUNDRY_AGENT_NAME' `
    -DefaultValue 'foundry-hosted-agent-profiled'
$EnvironmentName = Resolve-Setting -ParameterValue $EnvironmentName `
    -EnvironmentVariable 'AZD_ENVIRONMENT_NAME' `
    -DefaultValue 'foundry-hosted-agent-profiled'
$AzdHttpsProxy = Resolve-Setting -ParameterValue $AzdHttpsProxy `
    -EnvironmentVariable 'FOUNDRY_AZD_HTTPS_PROXY'
$RunMetadataPath = Resolve-Setting -ParameterValue $RunMetadataPath `
    -EnvironmentVariable 'FOUNDRY_LAST_RUN_METADATA_PATH' `
    -DefaultValue (Join-Path $repoRoot 'run-logs\last-invocation.json')

if (-not [System.IO.Path]::IsPathRooted($RunMetadataPath)) {
    $RunMetadataPath = Join-Path $repoRoot $RunMetadataPath
}

$RunMetadataPath = [System.IO.Path]::GetFullPath($RunMetadataPath)

if ($AgentName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$') {
    throw 'FOUNDRY_AGENT_NAME must contain only letters, numbers, hyphens, or underscores.'
}

if ($EnvironmentName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$') {
    throw 'AZD_ENVIRONMENT_NAME must contain only letters, numbers, hyphens, or underscores.'
}

$InputBlobPath = Assert-HttpsBlobPath `
    -Name 'InputBlobPath' `
    -Value $InputBlobPath
$OutputBlobPath = Assert-HttpsBlobPath `
    -Name 'OutputBlobPath' `
    -Value $OutputBlobPath

if (-not [string]::IsNullOrWhiteSpace($ManagedIdentityClientId)) {
    $parsedClientId = [guid]::Empty
    if (-not [guid]::TryParse($ManagedIdentityClientId, [ref]$parsedClientId)) {
        throw 'ManagedIdentityClientId must be a GUID.'
    }

    $ManagedIdentityClientId = $parsedClientId.ToString()
}

if (-not (Test-Path -LiteralPath $azureYamlPath -PathType Leaf)) {
    throw "Required azd configuration not found: $azureYamlPath"
}

$azdCommand = Get-Command azd -CommandType Application `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1

if (-not $azdCommand) {
    throw 'Azure Developer CLI (azd) is required. Install azd and the microsoft.foundry extension before invoking the agent.'
}

$usesAzureCliAuth = Test-AzdUsesAzureCliAuth -AzdPath $azdCommand.Source
$azCommand = $null
if ($usesAzureCliAuth) {
    $azCommand = Get-Command az -CommandType Application `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $azCommand) {
        throw 'Azure CLI (az) is required because azd delegates authentication to it.'
    }

    $AzureTenantId = Resolve-AzureTargetGuid `
        -ConfiguredValue $AzureTenantId `
        -EnvironmentVariable 'FOUNDRY_AZURE_TENANT_ID' `
        -AzdEnvironmentKey 'AZURE_TENANT_ID' `
        -AzdPath $azdCommand.Source `
        -EnvironmentName $EnvironmentName `
        -RepoRoot $repoRoot
    $AzureSubscriptionId = Resolve-AzureTargetGuid `
        -ConfiguredValue $AzureSubscriptionId `
        -EnvironmentVariable 'FOUNDRY_AZURE_SUBSCRIPTION_ID' `
        -AzdEnvironmentKey 'AZURE_SUBSCRIPTION_ID' `
        -AzdPath $azdCommand.Source `
        -EnvironmentName $EnvironmentName `
        -RepoRoot $repoRoot
}

$previousHttpsProxy = [Environment]::GetEnvironmentVariable(
    'HTTPS_PROXY',
    'Process'
)
$previousNoProxy = [Environment]::GetEnvironmentVariable(
    'NO_PROXY',
    'Process'
)
$azureAuthState = $null
$azdTokenBridgeState = $null
$requestFilePath = $null
$locationPushed = $false
$invocationStartedAt = $null
$invocationEndedAt = $null
$invocationExitCode = $null
$invocationError = $null

try {
    if ($usesAzureCliAuth) {
        $azureAuthState = Ensure-AzureCliAuthentication `
            -AzPath $azCommand.Source `
            -TenantId $AzureTenantId `
            -SubscriptionId $AzureSubscriptionId `
            -Scopes @(
                'https://management.azure.com/.default'
                'https://ai.azure.com/.default'
            ) `
            -ForceDeviceCodeLogin:$RefreshAzureLogin
        $azdTokenBridgeState = Enable-AzdExtensionTokenBridge `
            -AzPath $azCommand.Source `
            -AzdPath $azdCommand.Source `
            -SubscriptionId $AzureSubscriptionId `
            -Scopes @('https://ai.azure.com/.default')
        if ($null -eq $azdTokenBridgeState) {
            Initialize-AzdAccessToken `
                -AzdPath $azdCommand.Source `
                -TenantId $AzureTenantId `
                -Scope 'https://ai.azure.com/.default'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($AzdHttpsProxy)) {
        Assert-LoopbackSocksProxy -Proxy $AzdHttpsProxy

        $env:HTTPS_PROXY = $AzdHttpsProxy
        $env:NO_PROXY = @(
            '127.0.0.1'
            'localhost'
            'login.microsoftonline.com'
            'login.microsoft.com'
            'login.windows.net'
            'management.azure.com'
            'management.core.windows.net'
            'graph.microsoft.com'
        ) -join ','
    }

    $requestPayload = [ordered]@{
        input_blob_path = $InputBlobPath
        output_blob_path = $OutputBlobPath
    }

    if (-not [string]::IsNullOrWhiteSpace($ManagedIdentityClientId)) {
        $requestPayload['managed_identity_client_id'] = $ManagedIdentityClientId
    }

    $requestFilePath = Join-Path (
        [System.IO.Path]::GetTempPath()
    ) (
        'foundry-agent-request-{0}.json' -f
            [guid]::NewGuid().ToString('N')
    )
    $requestJson = $requestPayload | ConvertTo-Json -Depth 3 -Compress
    [System.IO.File]::WriteAllText(
        $requestFilePath,
        $requestJson,
        [System.Text.UTF8Encoding]::new($false)
    )

    $invokeArguments = @(
        'ai', 'agent', 'invoke', $AgentName,
        '--input-file', $requestFilePath,
        '--protocol', 'invocations',
        '--timeout', $RequestTimeoutSeconds.ToString(),
        '--environment', $EnvironmentName,
        '--no-prompt'
    )

    if ($Raw) {
        $invokeArguments += @('--output', 'raw')
    }

    Push-Location $repoRoot
    $locationPushed = $true

    $invocationStartedAt = [DateTimeOffset]::UtcNow
    Write-Host (
        'StartTimeUtc={0}' -f
            $invocationStartedAt.ToString(
                'o',
                [Globalization.CultureInfo]::InvariantCulture
            )
    )

    & $azdCommand.Source @invokeArguments
    $invocationExitCode = $LASTEXITCODE
    $invocationEndedAt = [DateTimeOffset]::UtcNow
    Write-Host (
        'EndTimeUtc={0}' -f
            $invocationEndedAt.ToString(
                'o',
                [Globalization.CultureInfo]::InvariantCulture
            )
    )

    if ($invocationExitCode -ne 0) {
        throw "azd ai agent invoke failed with exit code $invocationExitCode."
    }
}
catch {
    $invocationError = $_.Exception.Message

    if ($null -ne $invocationStartedAt -and $null -eq $invocationEndedAt) {
        $invocationEndedAt = [DateTimeOffset]::UtcNow
        Write-Host (
            'EndTimeUtc={0}' -f
                $invocationEndedAt.ToString(
                    'o',
                    [Globalization.CultureInfo]::InvariantCulture
                )
        )
    }

    throw
}
finally {
    if ($null -ne $invocationStartedAt) {
        $invocationStatus = if (
            $invocationExitCode -eq 0 -and
            [string]::IsNullOrWhiteSpace($invocationError)
        ) {
            'completed'
        }
        else {
            'failed'
        }
        $metadata = [ordered]@{
            schema_version = 1
            status = $invocationStatus
            start_time_utc = $invocationStartedAt.ToString(
                'o',
                [Globalization.CultureInfo]::InvariantCulture
            )
            end_time_utc = $invocationEndedAt.ToString(
                'o',
                [Globalization.CultureInfo]::InvariantCulture
            )
            exit_code = $invocationExitCode
            error = $invocationError
            agent_name = $AgentName
            environment_name = $EnvironmentName
            azure_auth = [ordered]@{
                mode = if ($usesAzureCliAuth) {
                    'azure_cli'
                }
                else {
                    'azd'
                }
                tenant_id = $AzureTenantId
                subscription_id = $AzureSubscriptionId
                device_code_login_used = (
                    $null -ne $azureAuthState -and
                    $azureAuthState.device_code_login_used
                )
                context_switched = (
                    $null -ne $azureAuthState -and
                    $azureAuthState.context_switched
                )
                token_bridge_used = $null -ne $azdTokenBridgeState
            }
        }
        Write-JsonAtomically -Path $RunMetadataPath -Value $metadata
        Write-Host "RunMetadataPath=$RunMetadataPath"
    }

    try {
        if (
            -not [string]::IsNullOrWhiteSpace($requestFilePath) -and
            (Test-Path -LiteralPath $requestFilePath -PathType Leaf)
        ) {
            Remove-Item -LiteralPath $requestFilePath -Force
        }
    }
    finally {
        Restore-AzdExtensionTokenBridge -State $azdTokenBridgeState

        if ($locationPushed) {
            Pop-Location
        }

        if ($null -ne $azureAuthState) {
            Restore-AzureCliAuthentication `
                -AzPath $azCommand.Source `
                -State $azureAuthState
        }

        Restore-ProcessEnvironmentVariable `
            -Name 'HTTPS_PROXY' `
            -Value $previousHttpsProxy
        Restore-ProcessEnvironmentVariable `
            -Name 'NO_PROXY' `
            -Value $previousNoProxy
    }
}
