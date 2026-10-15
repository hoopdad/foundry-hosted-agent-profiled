#Requires -Version 7.2

[CmdletBinding()]
param(
    [AllowNull()]
    [string]$WorkspaceId,

    [AllowNull()]
    [string]$AccountName,

    [AllowNull()]
    [string]$OperationName,

    [ValidateRange(0, 300)]
    [int]$StorageTimePaddingSeconds = 30,

    [AllowNull()]
    [Nullable[DateTimeOffset]]$StartTimeUtc,

    [AllowNull()]
    [Nullable[DateTimeOffset]]$EndTimeUtc,

    [AllowNull()]
    [string]$RunMetadataPath,

    [AllowNull()]
    [string]$OutputDirectory,

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
    [string]$InvocationId,

    [AllowNull()]
    [string]$SessionId,

    [ValidateRange(1, 300)]
    [int]$FoundryLogTail = 300,

    [ValidateRange(0, 1800)]
    [int]$WaitForIngestionSeconds = 0,

    [switch]$RefreshAzureLogin,

    [switch]$SkipFoundryLogs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSCommandPath
$collectorLogPath = $null
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

function Initialize-FoundryAzdAccessToken {
    param(
        [Parameter(Mandatory)]
        [string]$AzdPath,

        [Parameter(Mandatory)]
        [string]$TenantId,

        [AllowNull()]
        [object]$DirectHttpsProxy,

        [AllowNull()]
        [object]$DirectNoProxy
    )

    $foundryHttpsProxy = [Environment]::GetEnvironmentVariable(
        'HTTPS_PROXY',
        'Process'
    )
    $foundryNoProxy = [Environment]::GetEnvironmentVariable(
        'NO_PROXY',
        'Process'
    )

    try {
        Restore-ProcessEnvironmentVariable `
            -Name 'HTTPS_PROXY' `
            -Value $DirectHttpsProxy
        Restore-ProcessEnvironmentVariable `
            -Name 'NO_PROXY' `
            -Value $DirectNoProxy
        Initialize-AzdAccessToken `
            -AzdPath $AzdPath `
            -TenantId $TenantId `
            -Scope 'https://ai.azure.com/.default'
    }
    finally {
        Restore-ProcessEnvironmentVariable `
            -Name 'HTTPS_PROXY' `
            -Value $foundryHttpsProxy
        Restore-ProcessEnvironmentVariable `
            -Name 'NO_PROXY' `
            -Value $foundryNoProxy
    }
}

function Enable-FoundryAzdTokenBridge {
    param(
        [Parameter(Mandatory)]
        [string]$AzPath,

        [Parameter(Mandatory)]
        [string]$AzdPath,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [AllowNull()]
        [object]$DirectHttpsProxy,

        [AllowNull()]
        [object]$DirectNoProxy
    )

    $foundryHttpsProxy = [Environment]::GetEnvironmentVariable(
        'HTTPS_PROXY',
        'Process'
    )
    $foundryNoProxy = [Environment]::GetEnvironmentVariable(
        'NO_PROXY',
        'Process'
    )

    try {
        Restore-ProcessEnvironmentVariable `
            -Name 'HTTPS_PROXY' `
            -Value $DirectHttpsProxy
        Restore-ProcessEnvironmentVariable `
            -Name 'NO_PROXY' `
            -Value $DirectNoProxy
        return Enable-AzdExtensionTokenBridge `
            -AzPath $AzPath `
            -AzdPath $AzdPath `
            -SubscriptionId $SubscriptionId `
            -Scopes @('https://ai.azure.com/.default')
    }
    finally {
        Restore-ProcessEnvironmentVariable `
            -Name 'HTTPS_PROXY' `
            -Value $foundryHttpsProxy
        Restore-ProcessEnvironmentVariable `
            -Name 'NO_PROXY' `
            -Value $foundryNoProxy
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

function Write-Utf8File {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [AllowEmptyString()]
        [Parameter(Mandatory)]
        [string]$Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Write-CollectorLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = [DateTimeOffset]::UtcNow.ToString(
        'yyyy-MM-ddTHH:mm:ss.fffZ',
        [Globalization.CultureInfo]::InvariantCulture
    )
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -LiteralPath $collectorLogPath -Value $line -Encoding utf8
    Write-Host $line
}

function Invoke-CapturedCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [string]$CommandPath,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$StandardOutputPath,

        [Parameter(Mandatory)]
        [string]$StandardErrorPath
    )

    Write-CollectorLog -Message "Starting $Label."
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()

    & $CommandPath @Arguments 1> $StandardOutputPath 2> $StandardErrorPath
    $exitCode = $LASTEXITCODE
    $stopwatch.Stop()

    Write-CollectorLog -Message (
        "$Label finished with exit code $exitCode in " +
        "$($stopwatch.ElapsedMilliseconds) ms."
    )

    if ($exitCode -ne 0) {
        $standardError = if (
            Test-Path -LiteralPath $StandardErrorPath -PathType Leaf
        ) {
            [System.IO.File]::ReadAllText($StandardErrorPath).Trim()
        }
        else {
            ''
        }

        $failureOutput = $standardError
        $failureStream = 'stderr'

        if ([string]::IsNullOrWhiteSpace($failureOutput)) {
            $failureOutput = if (
                Test-Path -LiteralPath $StandardOutputPath -PathType Leaf
            ) {
                [System.IO.File]::ReadAllText($StandardOutputPath).Trim()
            }
            else {
                ''
            }
            $failureStream = 'stdout'
        }

        if ($failureOutput.Length -gt 1000) {
            $failureOutput = $failureOutput.Substring(0, 1000) + '...'
        }

        $errorDetail = if ($failureOutput) {
            " ${failureStream}: $failureOutput"
        }
        else {
            ''
        }

        $exception = [InvalidOperationException]::new(
            "$Label failed with exit code $exitCode. See output files " +
            "$StandardOutputPath and $StandardErrorPath.$errorDetail"
        )
        $exception.Data['ExitCode'] = $exitCode
        $exception.Data['DurationMs'] = $stopwatch.ElapsedMilliseconds
        throw $exception
    }

    return [ordered]@{
        exit_code = $exitCode
        duration_ms = $stopwatch.ElapsedMilliseconds
    }
}

function Convert-JsonResultsToCsv {
    param(
        [Parameter(Mandatory)]
        [string]$JsonPath,

        [Parameter(Mandatory)]
        [string]$CsvPath,

        [Parameter(Mandatory)]
        [string[]]$Columns
    )

    $jsonText = Get-Content -LiteralPath $JsonPath -Raw

    try {
        $parsed = $jsonText | ConvertFrom-Json
    }
    catch {
        throw "Azure CLI returned invalid JSON in $JsonPath. $($_.Exception.Message)"
    }

    $rows = @($parsed)

    if ($rows.Count -eq 0) {
        $header = (
            $Columns |
                ForEach-Object { '"{0}"' -f $_.Replace('"', '""') }
        ) -join ','
        Write-Utf8File -Path $CsvPath -Content ($header + [Environment]::NewLine)
        return 0
    }

    $rows |
        Select-Object -Property $Columns |
        Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding utf8

    return $rows.Count
}

function Resolve-InputStorageAccountName {
    $inputBlobPath = [Environment]::GetEnvironmentVariable(
        'FOUNDRY_INPUT_BLOB_PATH',
        'Process'
    )
    $inputBlobUri = $null

    if (
        [string]::IsNullOrWhiteSpace($inputBlobPath) -or
        -not [uri]::TryCreate(
            $inputBlobPath,
            [UriKind]::Absolute,
            [ref]$inputBlobUri
        ) -or
        [string]::IsNullOrWhiteSpace($inputBlobUri.Host)
    ) {
        return $null
    }

    return $inputBlobUri.Host.Split('.')[0]
}

function Resolve-StorageAccount {
    param(
        [AllowNull()]
        [string]$ConfiguredAccountName
    )

    $inputAccountName = Resolve-InputStorageAccountName

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredAccountName)) {
        return [ordered]@{
            name = $ConfiguredAccountName.Trim()
            source = 'parameter'
            input_account_name = $inputAccountName
        }
    }

    $environmentAccountName = [Environment]::GetEnvironmentVariable(
        'STORAGE_LOG_ACCOUNT_NAME',
        'Process'
    )

    if (-not [string]::IsNullOrWhiteSpace($environmentAccountName)) {
        return [ordered]@{
            name = $environmentAccountName.Trim()
            source = 'environment'
            input_account_name = $inputAccountName
        }
    }

    if ([string]::IsNullOrWhiteSpace($inputAccountName)) {
        throw (
            'Set STORAGE_LOG_ACCOUNT_NAME in .env, pass -AccountName, or ' +
            'configure a valid FOUNDRY_INPUT_BLOB_PATH.'
        )
    }

    return [ordered]@{
        name = $inputAccountName
        source = 'input_blob_path'
        input_account_name = $inputAccountName
    }
}

function Resolve-CollectionWindow {
    param(
        [AllowNull()]
        [Nullable[DateTimeOffset]]$RequestedStartTimeUtc,

        [AllowNull()]
        [Nullable[DateTimeOffset]]$RequestedEndTimeUtc,

        [Parameter(Mandatory)]
        [string]$MetadataPath
    )

    $hasStartTime = $null -ne $RequestedStartTimeUtc
    $hasEndTime = $null -ne $RequestedEndTimeUtc

    if ($hasStartTime -xor $hasEndTime) {
        throw 'Pass both StartTimeUtc and EndTimeUtc, or omit both.'
    }

    if ($hasStartTime) {
        return [ordered]@{
            start_time_utc = $RequestedStartTimeUtc.ToUniversalTime()
            end_time_utc = $RequestedEndTimeUtc.ToUniversalTime()
            source = 'parameters'
        }
    }

    if (-not (Test-Path -LiteralPath $MetadataPath -PathType Leaf)) {
        throw (
            "Invocation metadata not found at $MetadataPath. Run " +
            'invoke-hosted-agent.ps1 first, or pass StartTimeUtc and EndTimeUtc.'
        )
    }

    $metadataDocument = $null

    try {
        $metadataJson = Get-Content -LiteralPath $MetadataPath -Raw
        $metadataDocument = [System.Text.Json.JsonDocument]::Parse($metadataJson)
        $metadataRoot = $metadataDocument.RootElement
        $metadataStartTime = $metadataRoot.GetProperty(
            'start_time_utc'
        ).GetString()
        $metadataEndTime = $metadataRoot.GetProperty(
            'end_time_utc'
        ).GetString()
        $metadataStatus = $metadataRoot.GetProperty('status').GetString()
    }
    catch {
        throw "Invocation metadata is invalid JSON: $MetadataPath. $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $metadataDocument) {
            $metadataDocument.Dispose()
        }
    }

    if (
        [string]::IsNullOrWhiteSpace($metadataStartTime) -or
        [string]::IsNullOrWhiteSpace($metadataEndTime)
    ) {
        throw "Invocation metadata is missing UTC time bounds: $MetadataPath"
    }

    try {
        $resolvedStartTime = [DateTimeOffset]::Parse(
            $metadataStartTime,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None
        ).ToUniversalTime()
        $resolvedEndTime = [DateTimeOffset]::Parse(
            $metadataEndTime,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None
        ).ToUniversalTime()
    }
    catch {
        throw "Invocation metadata has invalid UTC time bounds: $MetadataPath"
    }

    return [ordered]@{
        start_time_utc = $resolvedStartTime
        end_time_utc = $resolvedEndTime
        source = 'invocation_metadata'
        invocation_status = $metadataStatus
    }
}

Import-DotEnv -Path (Join-Path $repoRoot '.env')

$WorkspaceId = Resolve-RequiredSetting `
    -ParameterValue $WorkspaceId `
    -EnvironmentVariable 'LOG_ANALYTICS_WORKSPACE_ID' `
    -ParameterName 'WorkspaceId'
$storageAccount = Resolve-StorageAccount `
    -ConfiguredAccountName $AccountName
$AccountName = $storageAccount.name
$OperationName = Resolve-Setting -ParameterValue $OperationName `
    -EnvironmentVariable 'STORAGE_LOG_OPERATION_NAME' `
    -DefaultValue 'GetBlob'
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
$collectionWindow = Resolve-CollectionWindow `
    -RequestedStartTimeUtc $StartTimeUtc `
    -RequestedEndTimeUtc $EndTimeUtc `
    -MetadataPath $RunMetadataPath
$invocationStartTime = $collectionWindow.start_time_utc
$invocationEndTime = $collectionWindow.end_time_utc
$normalizedStartTime = $invocationStartTime.AddSeconds(
    -$StorageTimePaddingSeconds
)
$normalizedEndTime = $invocationEndTime.AddSeconds(
    $StorageTimePaddingSeconds
)
$collectionStartedAt = [DateTimeOffset]::UtcNow

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $directoryName = $collectionStartedAt.ToString(
        'yyyyMMddTHHmmssfffZ',
        [Globalization.CultureInfo]::InvariantCulture
    )
    $OutputDirectory = Join-Path $repoRoot "run-logs\$directoryName"
}
elseif (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path (Get-Location).Path $OutputDirectory
}

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

if (
    (Test-Path -LiteralPath $OutputDirectory -PathType Container) -and
    (Get-ChildItem -LiteralPath $OutputDirectory -Force |
        Select-Object -First 1)
) {
    throw "OutputDirectory must be new or empty: $OutputDirectory"
}

$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$collectorLogPath = Join-Path $OutputDirectory 'collector.log'
Write-Utf8File -Path $collectorLogPath -Content ''

$manifestPath = Join-Path $OutputDirectory 'manifest.json'
$collectorStopwatch = [Diagnostics.Stopwatch]::StartNew()
$manifest = [ordered]@{
    schema_version = 1
    status = 'running'
    collection_started_utc = $collectionStartedAt.ToString(
        'o',
        [Globalization.CultureInfo]::InvariantCulture
    )
    collection_completed_utc = $null
    duration_ms = $null
    workspace_id = $WorkspaceId
    time_window_source = $collectionWindow.source
    storage_filter = [ordered]@{
        account_name = $AccountName
        account_name_source = $storageAccount.source
        input_account_name = $storageAccount.input_account_name
        operation_name = $OperationName
        invocation_start_time_utc = $invocationStartTime.ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture
        )
        invocation_end_time_utc = $invocationEndTime.ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture
        )
        time_padding_seconds = $StorageTimePaddingSeconds
        start_time_utc = $normalizedStartTime.ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture
        )
        end_time_utc = $normalizedEndTime.ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    foundry = [ordered]@{
        collected = -not $SkipFoundryLogs
        agent_name = $AgentName
        environment_name = $EnvironmentName
        invocation_id = $InvocationId
        session_id = $SessionId
        log_tail = $FoundryLogTail
        proxy_configured = -not [string]::IsNullOrWhiteSpace($AzdHttpsProxy)
    }
    azure_auth = [ordered]@{
        mode = $null
        tenant_id = $null
        subscription_id = $null
        device_code_login_used = $false
        context_switched = $false
    }
    result_counts = [ordered]@{
        storage_detail_rows = $null
        storage_statistics_rows = $null
    }
    commands = [ordered]@{}
    artifacts = [ordered]@{
        collector_log = 'collector.log'
        manifest = 'manifest.json'
    }
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
$usesAzureCliAuth = $false
$completedWithWarnings = $false

try {
    Write-CollectorLog -Message "Collecting evidence in $OutputDirectory."

    if (
        -not [string]::IsNullOrWhiteSpace(
            $storageAccount.input_account_name
        ) -and
        $AccountName -ine $storageAccount.input_account_name
    ) {
        $completedWithWarnings = $true
        Write-CollectorLog -Level 'WARN' -Message (
            "Storage log account '$AccountName' does not match input Blob " +
            "account '$($storageAccount.input_account_name)'. The explicit " +
            'override is being honored; verify it is intentional and that ' +
            'its Blob service sends resource logs to the selected workspace.'
        )
    }

    $parsedWorkspaceId = [guid]::Empty
    if (-not [guid]::TryParse($WorkspaceId, [ref]$parsedWorkspaceId)) {
        throw 'WorkspaceId must be the Log Analytics workspace customer ID GUID.'
    }
    $WorkspaceId = $parsedWorkspaceId.ToString()
    $manifest['workspace_id'] = $WorkspaceId

    if ($AccountName -notmatch '^[a-z0-9]{3,24}$') {
        throw 'AccountName must be a valid lowercase Azure Storage account name.'
    }

    if ($OperationName -notmatch '^[A-Za-z][A-Za-z0-9]{0,63}$') {
        throw 'OperationName must start with a letter and contain only letters or numbers.'
    }

    if ($AgentName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$') {
        throw 'AgentName must contain only letters, numbers, hyphens, or underscores.'
    }

    if ($EnvironmentName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$') {
        throw 'EnvironmentName must contain only letters, numbers, hyphens, or underscores.'
    }

    if ($invocationStartTime -ge $invocationEndTime) {
        throw 'StartTimeUtc must be earlier than EndTimeUtc.'
    }

    $azCommand = Get-Command az -CommandType Application `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $azCommand) {
        throw 'Azure CLI (az) is required to query Log Analytics.'
    }

    $azdCommand = Get-Command azd -CommandType Application `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $SkipFoundryLogs) {
        if (-not $azdCommand) {
            throw 'Azure Developer CLI (azd) is required to retrieve Foundry logs.'
        }
    }

    $activeAzureContext = Get-AzureCliAccountContext `
        -AzPath $azCommand.Source
    $AzureTenantId = Resolve-AzureTargetGuid `
        -ConfiguredValue $AzureTenantId `
        -EnvironmentVariable 'FOUNDRY_AZURE_TENANT_ID' `
        -AzdEnvironmentKey 'AZURE_TENANT_ID' `
        -AzdPath $(if ($azdCommand) { $azdCommand.Source } else { $null }) `
        -EnvironmentName $EnvironmentName `
        -RepoRoot $repoRoot `
        -FallbackValue $(if ($activeAzureContext) {
            $activeAzureContext.tenant_id
        })
    $AzureSubscriptionId = Resolve-AzureTargetGuid `
        -ConfiguredValue $AzureSubscriptionId `
        -EnvironmentVariable 'FOUNDRY_AZURE_SUBSCRIPTION_ID' `
        -AzdEnvironmentKey 'AZURE_SUBSCRIPTION_ID' `
        -AzdPath $(if ($azdCommand) { $azdCommand.Source } else { $null }) `
        -EnvironmentName $EnvironmentName `
        -RepoRoot $repoRoot `
        -FallbackValue $(if ($activeAzureContext) {
            $activeAzureContext.subscription_id
        })
    $usesAzureCliAuth = (
        -not $SkipFoundryLogs -and
        (Test-AzdUsesAzureCliAuth -AzdPath $azdCommand.Source)
    )
    $tokenScopes = @('https://management.azure.com/.default')
    if ($usesAzureCliAuth) {
        $tokenScopes += 'https://ai.azure.com/.default'
    }

    $azureAuthState = Ensure-AzureCliAuthentication `
        -AzPath $azCommand.Source `
        -TenantId $AzureTenantId `
        -SubscriptionId $AzureSubscriptionId `
        -Scopes $tokenScopes `
        -ForceDeviceCodeLogin:$RefreshAzureLogin
    $manifest.azure_auth['mode'] = if ($usesAzureCliAuth) {
        'azure_cli'
    }
    else {
        'azure_cli_storage'
    }
    $manifest.azure_auth['tenant_id'] = $AzureTenantId
    $manifest.azure_auth['subscription_id'] = $AzureSubscriptionId
    $manifest.azure_auth['device_code_login_used'] = (
        $azureAuthState.device_code_login_used
    )
    $manifest.azure_auth['context_switched'] = (
        $azureAuthState.context_switched
    )
    if (
        -not $SkipFoundryLogs -and
        -not [string]::IsNullOrWhiteSpace($AzdHttpsProxy)
    ) {
        Assert-LoopbackSocksProxy -Proxy $AzdHttpsProxy
    }

    $startLiteral = $normalizedStartTime.ToString(
        'yyyy-MM-ddTHH:mm:ss.fffffffZ',
        [Globalization.CultureInfo]::InvariantCulture
    )
    $endLiteral = $normalizedEndTime.ToString(
        'yyyy-MM-ddTHH:mm:ss.fffffffZ',
        [Globalization.CultureInfo]::InvariantCulture
    )

    $baseQuery = @"
StorageBlobLogs
| where TimeGenerated between (
    datetime($startLiteral) ..
    datetime($endLiteral)
)
| where AccountName == '$AccountName'
| where OperationName == '$OperationName'
"@
    $baseQuery = $baseQuery.Trim()

    $detailsQuery = @"
$baseQuery
| project TimeGenerated, OperationName, StatusCode,
          DurationMs, ServerLatencyMs, ClientRequestId
| order by TimeGenerated asc
"@
    $detailsQuery = $detailsQuery.Trim()

    $statisticsQuery = @"
$baseQuery
| summarize
    RequestCount = count(),
    SuccessCount = countif(toint(StatusCode) between (200 .. 299)),
    NonSuccessCount = countif(
        isnull(toint(StatusCode)) or
        toint(StatusCode) < 200 or
        toint(StatusCode) >= 300
    ),
    AverageDurationMs = round(avg(todouble(DurationMs)), 2),
    P50DurationMs = round(percentile(todouble(DurationMs), 50), 2),
    P95DurationMs = round(percentile(todouble(DurationMs), 95), 2),
    P99DurationMs = round(percentile(todouble(DurationMs), 99), 2),
    MaximumDurationMs = max(todouble(DurationMs)),
    AverageServerLatencyMs = round(avg(todouble(ServerLatencyMs)), 2),
    P95ServerLatencyMs = round(percentile(todouble(ServerLatencyMs), 95), 2),
    AverageClientOverheadMs = round(
        avg(todouble(DurationMs) - todouble(ServerLatencyMs)),
        2
    )
"@
    $statisticsQuery = $statisticsQuery.Trim()
    $detailsQueryArgument = (
        $detailsQuery -replace '\s*\r?\n\s*', ' '
    ).Trim()
    $statisticsQueryArgument = (
        $statisticsQuery -replace '\s*\r?\n\s*', ' '
    ).Trim()

    $detailsQueryPath = Join-Path $OutputDirectory 'storage-blob-details.kql'
    $statisticsQueryPath = Join-Path $OutputDirectory 'storage-blob-statistics.kql'
    Write-Utf8File -Path $detailsQueryPath `
        -Content ($detailsQuery + [Environment]::NewLine)
    Write-Utf8File -Path $statisticsQueryPath `
        -Content ($statisticsQuery + [Environment]::NewLine)
    $manifest.artifacts['storage_details_query'] = 'storage-blob-details.kql'
    $manifest.artifacts['storage_statistics_query'] = 'storage-blob-statistics.kql'

    if ($WaitForIngestionSeconds -gt 0) {
        Write-CollectorLog -Message (
            "Waiting $WaitForIngestionSeconds seconds for Azure Monitor ingestion."
        )
        Start-Sleep -Seconds $WaitForIngestionSeconds
    }

    $detailsJsonPath = Join-Path $OutputDirectory 'storage-blob-details.json'
    $detailsCsvPath = Join-Path $OutputDirectory 'storage-blob-details.csv'
    $detailsErrorPath = Join-Path $OutputDirectory 'storage-blob-details.stderr.log'
    $detailsCommand = Invoke-CapturedCommand `
        -Label 'Storage Blob detail query' `
        -CommandPath $azCommand.Source `
        -Arguments @(
            'monitor', 'log-analytics', 'query',
            '--workspace', $WorkspaceId,
            '--analytics-query', $detailsQueryArgument,
            '--subscription', $AzureSubscriptionId,
            '--output', 'json',
            '--only-show-errors'
        ) `
        -StandardOutputPath $detailsJsonPath `
        -StandardErrorPath $detailsErrorPath
    $manifest.commands['storage_details_query'] = $detailsCommand

    $detailColumns = @(
        'TimeGenerated'
        'OperationName'
        'StatusCode'
        'DurationMs'
        'ServerLatencyMs'
        'ClientRequestId'
    )
    $detailRowCount = Convert-JsonResultsToCsv `
        -JsonPath $detailsJsonPath `
        -CsvPath $detailsCsvPath `
        -Columns $detailColumns
    $manifest.result_counts['storage_detail_rows'] = $detailRowCount
    $manifest.artifacts['storage_details_json'] = 'storage-blob-details.json'
    $manifest.artifacts['storage_details_csv'] = 'storage-blob-details.csv'
    $manifest.artifacts['storage_details_stderr'] = 'storage-blob-details.stderr.log'

    if ($detailRowCount -eq 0) {
        $completedWithWarnings = $true
        Write-CollectorLog -Level 'WARN' -Message (
            'The Storage Blob detail query returned no matching rows. ' +
            "Verify the '$AccountName' Blob service diagnostic settings, " +
            'the account and operation filters, and the ingestion delay.'
        )
    }
    else {
        Write-CollectorLog -Message (
            "The Storage Blob detail query returned $detailRowCount row(s)."
        )
    }

    $statisticsJsonPath = Join-Path $OutputDirectory 'storage-blob-statistics.json'
    $statisticsCsvPath = Join-Path $OutputDirectory 'storage-blob-statistics.csv'
    $statisticsErrorPath = Join-Path $OutputDirectory 'storage-blob-statistics.stderr.log'
    $statisticsCommand = Invoke-CapturedCommand `
        -Label 'Storage Blob statistics query' `
        -CommandPath $azCommand.Source `
        -Arguments @(
            'monitor', 'log-analytics', 'query',
            '--workspace', $WorkspaceId,
            '--analytics-query', $statisticsQueryArgument,
            '--subscription', $AzureSubscriptionId,
            '--output', 'json',
            '--only-show-errors'
        ) `
        -StandardOutputPath $statisticsJsonPath `
        -StandardErrorPath $statisticsErrorPath
    $manifest.commands['storage_statistics_query'] = $statisticsCommand

    $statisticsColumns = @(
        'RequestCount'
        'SuccessCount'
        'NonSuccessCount'
        'AverageDurationMs'
        'P50DurationMs'
        'P95DurationMs'
        'P99DurationMs'
        'MaximumDurationMs'
        'AverageServerLatencyMs'
        'P95ServerLatencyMs'
        'AverageClientOverheadMs'
    )
    $statisticsRowCount = Convert-JsonResultsToCsv `
        -JsonPath $statisticsJsonPath `
        -CsvPath $statisticsCsvPath `
        -Columns $statisticsColumns
    $manifest.result_counts['storage_statistics_rows'] = $statisticsRowCount
    $manifest.artifacts['storage_statistics_json'] = 'storage-blob-statistics.json'
    $manifest.artifacts['storage_statistics_csv'] = 'storage-blob-statistics.csv'
    $manifest.artifacts['storage_statistics_stderr'] = 'storage-blob-statistics.stderr.log'

    if (-not $SkipFoundryLogs) {
        if ($usesAzureCliAuth) {
            $azdTokenBridgeState = Enable-FoundryAzdTokenBridge `
                -AzPath $azCommand.Source `
                -AzdPath $azdCommand.Source `
                -SubscriptionId $AzureSubscriptionId `
                -DirectHttpsProxy $previousHttpsProxy `
                -DirectNoProxy $previousNoProxy
            $manifest.azure_auth['token_bridge_used'] = (
                $null -ne $azdTokenBridgeState
            )
        }

        if (-not [string]::IsNullOrWhiteSpace($AzdHttpsProxy)) {
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

        $invocationJsonPath = Join-Path $OutputDirectory 'foundry-invocation.json'
        $invocationErrorPath = Join-Path $OutputDirectory 'foundry-invocation.stderr.log'
        $invocationArguments = @(
            'ai', 'agent', 'invocations', 'show',
            '--agent-name', $AgentName,
            '--protocol', 'invocations',
            '--environment', $EnvironmentName,
            '--no-prompt',
            '--output', 'json',
            '--cwd', $repoRoot
        )

        if (-not [string]::IsNullOrWhiteSpace($InvocationId)) {
            $invocationArguments += @('--id', $InvocationId)
        }

        if ($usesAzureCliAuth -and $null -eq $azdTokenBridgeState) {
            Initialize-FoundryAzdAccessToken `
                -AzdPath $azdCommand.Source `
                -TenantId $AzureTenantId `
                -DirectHttpsProxy $previousHttpsProxy `
                -DirectNoProxy $previousNoProxy
        }

        $invocationFailure = $null
        try {
            $invocationCommand = Invoke-CapturedCommand `
                -Label 'Foundry invocation result retrieval' `
                -CommandPath $azdCommand.Source `
                -Arguments $invocationArguments `
                -StandardOutputPath $invocationJsonPath `
                -StandardErrorPath $invocationErrorPath
        }
        catch {
            $invocationFailure = $_
            $isAuthenticationFailure = (
                $_.Exception.Message -match
                '(?i)(AzureDeveloperCLICredential|failed to get auth token)'
            )
            if ($usesAzureCliAuth -and $isAuthenticationFailure) {
                $tokensAvailable = Test-AzureCliAccessTokens `
                    -AzPath $azCommand.Source `
                    -SubscriptionId $AzureSubscriptionId `
                    -Scopes $tokenScopes
                $retryAuthentication = $tokensAvailable

                if ($tokensAvailable) {
                    $completedWithWarnings = $true
                    Write-CollectorLog -Level 'WARN' -Message (
                        'Foundry delegated authentication failed even though ' +
                        'the required Azure CLI tokens are valid. Re-priming ' +
                        'the azd token directly, then retrying the read-only ' +
                        'query once.'
                    )
                }
                elseif (-not $azureAuthState.device_code_login_used) {
                    $completedWithWarnings = $true
                    Write-CollectorLog -Level 'WARN' -Message (
                        'Required Azure CLI tokens are unavailable. Starting ' +
                        'Azure CLI device-code login, then retrying the ' +
                        'read-only query once.'
                    )
                    Invoke-AzureCliDeviceCodeLogin `
                        -AzPath $azCommand.Source `
                        -TenantId $AzureTenantId `
                        -SubscriptionId $AzureSubscriptionId `
                        -Scopes $tokenScopes
                    $azureAuthState['device_code_login_used'] = $true
                    $manifest.azure_auth['device_code_login_used'] = $true
                    $retryAuthentication = $true
                }

                if ($retryAuthentication) {
                    try {
                        if ($null -ne $azdTokenBridgeState) {
                            Restore-AzdExtensionTokenBridge `
                                -State $azdTokenBridgeState
                            $azdTokenBridgeState = $null
                            $azdTokenBridgeState = (
                                Enable-FoundryAzdTokenBridge `
                                    -AzPath $azCommand.Source `
                                    -AzdPath $azdCommand.Source `
                                    -SubscriptionId $AzureSubscriptionId `
                                    -DirectHttpsProxy $previousHttpsProxy `
                                    -DirectNoProxy $previousNoProxy
                            )
                        }
                        else {
                            Initialize-FoundryAzdAccessToken `
                                -AzdPath $azdCommand.Source `
                                -TenantId $AzureTenantId `
                                -DirectHttpsProxy $previousHttpsProxy `
                                -DirectNoProxy $previousNoProxy
                        }
                        $invocationCommand = Invoke-CapturedCommand `
                            -Label 'Foundry invocation result retrieval retry' `
                            -CommandPath $azdCommand.Source `
                            -Arguments $invocationArguments `
                            -StandardOutputPath $invocationJsonPath `
                            -StandardErrorPath $invocationErrorPath
                        $invocationFailure = $null
                    }
                    catch {
                        $invocationFailure = $_
                    }
                }
            }
        }

        if ($null -ne $invocationFailure) {
            if (
                $invocationFailure.Exception.Message -notmatch
                '(?i)(HTTP 404|no current invocation is saved)'
            ) {
                throw $invocationFailure
            }

            $completedWithWarnings = $true
            Write-CollectorLog -Level 'WARN' -Message (
                'The saved or current Foundry invocation result is not ' +
                'available. Continuing with console and system log retrieval.'
            )
            $invocationCommand = [ordered]@{
                exit_code = $invocationFailure.Exception.Data['ExitCode']
                duration_ms = $invocationFailure.Exception.Data['DurationMs']
                continued_after_not_found = $true
                error = $invocationFailure.Exception.Message
            }
        }
        $manifest.commands['foundry_invocation'] = $invocationCommand
        $manifest.artifacts['foundry_invocation_json'] = 'foundry-invocation.json'
        $manifest.artifacts['foundry_invocation_stderr'] = 'foundry-invocation.stderr.log'

        foreach ($logType in @('console', 'system')) {
            $logPath = Join-Path $OutputDirectory "foundry-$logType.log"
            $logErrorPath = Join-Path $OutputDirectory "foundry-$logType.stderr.log"
            $monitorArguments = @(
                'ai', 'agent', 'monitor', $AgentName,
                '--type', $logType,
                '--tail', $FoundryLogTail.ToString(),
                '--utc',
                '--environment', $EnvironmentName,
                '--no-prompt',
                '--cwd', $repoRoot
            )

            if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
                $monitorArguments += @('--session-id', $SessionId)
            }

            if ($usesAzureCliAuth -and $null -eq $azdTokenBridgeState) {
                Initialize-FoundryAzdAccessToken `
                    -AzdPath $azdCommand.Source `
                    -TenantId $AzureTenantId `
                    -DirectHttpsProxy $previousHttpsProxy `
                    -DirectNoProxy $previousNoProxy
            }

            $monitorCommand = Invoke-CapturedCommand `
                -Label "Foundry $logType log retrieval" `
                -CommandPath $azdCommand.Source `
                -Arguments $monitorArguments `
                -StandardOutputPath $logPath `
                -StandardErrorPath $logErrorPath
            $manifest.commands["foundry_${logType}_logs"] = $monitorCommand
            $manifest.artifacts["foundry_${logType}_log"] = "foundry-$logType.log"
            $manifest.artifacts["foundry_${logType}_stderr"] = "foundry-$logType.stderr.log"
        }
    }

    $manifest['status'] = if ($completedWithWarnings) {
        'completed_with_warnings'
    }
    else {
        'completed'
    }
    Write-CollectorLog -Message (
        'Post-run evidence collection completed' +
        $(if ($completedWithWarnings) { ' with warnings.' } else { '.' })
    )
}
catch {
    $manifest['status'] = 'failed'
    $manifest['error'] = $_.Exception.Message
    Write-CollectorLog -Level 'ERROR' -Message $_.Exception.Message
    throw
}
finally {
    try {
        $collectorStopwatch.Stop()
        $manifest['collection_completed_utc'] = [DateTimeOffset]::UtcNow.ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture
        )
        $manifest['duration_ms'] = $collectorStopwatch.ElapsedMilliseconds
        Write-Utf8File -Path $manifestPath -Content (
            ($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine
        )
    }
    finally {
        Restore-AzdExtensionTokenBridge -State $azdTokenBridgeState

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

Write-Host "Evidence saved to: $OutputDirectory"
