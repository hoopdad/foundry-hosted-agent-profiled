$script:AzureCliAuthRoot = $PSScriptRoot

function ConvertTo-NativeOutputText {
    param(
        [AllowNull()]
        [object[]]$Output
    )

    return (
        $Output |
            ForEach-Object { $_.ToString() }
    ) -join [Environment]::NewLine
}

function Set-AuthProcessEnvironmentValue {
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

function Get-AzureCliTokenBridgePayload {
    param(
        [Parameter(Mandatory)]
        [string]$AzPath,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$Scope
    )

    $output = @(
        & $AzPath account get-access-token `
            --subscription $SubscriptionId `
            --scope $Scope `
            --query (
                '{accessToken:accessToken,' +
                'expiresOn:expiresOn,expires_on:expires_on}'
            ) `
            --output json `
            --only-show-errors `
            2>&1
    )
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw (
            "Azure CLI access-token acquisition failed for $Scope " +
            "with exit code $exitCode."
        )
    }

    $text = (ConvertTo-NativeOutputText -Output $output).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "Azure CLI returned an empty access-token response for $Scope."
    }

    try {
        $tokenResult = $text | ConvertFrom-Json
    }
    catch {
        throw "Azure CLI returned invalid access-token JSON for $Scope."
    }

    if ([string]::IsNullOrWhiteSpace($tokenResult.accessToken)) {
        throw "Azure CLI returned no access token for $Scope."
    }

    $expiresOn = [DateTimeOffset]::MinValue
    $expiresOnEpoch = 0L
    if (
        -not [string]::IsNullOrWhiteSpace($tokenResult.expires_on) -and
        [long]::TryParse(
            $tokenResult.expires_on.ToString(),
            [ref]$expiresOnEpoch
        )
    ) {
        $expiresOn = [DateTimeOffset]::FromUnixTimeSeconds($expiresOnEpoch)
    }
    elseif (
        [string]::IsNullOrWhiteSpace($tokenResult.expiresOn) -or
        -not [DateTimeOffset]::TryParse(
            $tokenResult.expiresOn.ToString(),
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeLocal,
            [ref]$expiresOn
        )
    ) {
        throw "Azure CLI returned an invalid access-token expiry for $Scope."
    }

    if ($expiresOn -le [DateTimeOffset]::UtcNow.AddMinutes(2)) {
        throw "Azure CLI returned an access token near expiry for $Scope."
    }

    return (
        [ordered]@{
            token = $tokenResult.accessToken.ToString()
            expiresOn = $expiresOn.UtcDateTime.ToString(
                'yyyy-MM-ddTHH:mm:ssZ',
                [Globalization.CultureInfo]::InvariantCulture
            )
        } |
            ConvertTo-Json -Compress
    )
}

function Enable-AzdExtensionTokenBridge {
    param(
        [Parameter(Mandatory)]
        [string]$AzPath,

        [Parameter(Mandatory)]
        [string]$AzdPath,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string[]]$Scopes
    )

    if (-not $IsWindows) {
        return $null
    }

    $resolvedAzdPath = [IO.Path]::GetFullPath($AzdPath)
    if (
        -not (Test-Path -LiteralPath $resolvedAzdPath -PathType Leaf) -or
        $resolvedAzdPath -match '["\r\n]'
    ) {
        throw 'The Azure Developer CLI path is invalid for token bridging.'
    }

    $bridgeDirectory = Join-Path `
        $script:AzureCliAuthRoot `
        'tools\azd-token-bridge'
    $bridgePath = Join-Path $bridgeDirectory 'azd.cmd'
    if (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) {
        throw "Required azd token bridge not found: $bridgePath"
    }

    $supportedScopes = [ordered]@{
        'https://ai.azure.com/.default' = (
            'FOUNDRY_AZD_TOKEN_BRIDGE_AI_JSON'
        )
        'https://management.azure.com/.default' = (
            'FOUNDRY_AZD_TOKEN_BRIDGE_ARM_JSON'
        )
    }
    $payloads = [ordered]@{}
    foreach ($scope in @($Scopes | Select-Object -Unique)) {
        if (-not $supportedScopes.Contains($scope)) {
            throw "The azd token bridge does not support scope $scope."
        }

        $payloads[$supportedScopes[$scope]] = Get-AzureCliTokenBridgePayload `
            -AzPath $AzPath `
            -SubscriptionId $SubscriptionId `
            -Scope $scope
    }

    $variableNames = @(
        'PATH'
        'FOUNDRY_AZD_TOKEN_BRIDGE_REAL_PATH'
        'FOUNDRY_AZD_TOKEN_BRIDGE_AI_JSON'
        'FOUNDRY_AZD_TOKEN_BRIDGE_ARM_JSON'
    )
    $previousValues = [ordered]@{}
    foreach ($variableName in $variableNames) {
        $previousValues[$variableName] = (
            [Environment]::GetEnvironmentVariable(
                $variableName,
                'Process'
            )
        )
    }

    foreach ($payload in $payloads.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable(
            $payload.Key,
            $payload.Value,
            'Process'
        )
    }
    $env:FOUNDRY_AZD_TOKEN_BRIDGE_REAL_PATH = $resolvedAzdPath
    $env:PATH = if ([string]::IsNullOrWhiteSpace($previousValues['PATH'])) {
        $bridgeDirectory
    }
    else {
        $bridgeDirectory +
            [IO.Path]::PathSeparator +
            $previousValues['PATH']
    }

    return [ordered]@{
        enabled = $true
        previous_values = $previousValues
    }
}

function Restore-AzdExtensionTokenBridge {
    param(
        [AllowNull()]
        [System.Collections.IDictionary]$State
    )

    if ($null -eq $State -or -not $State.enabled) {
        return
    }

    foreach ($variable in $State.previous_values.GetEnumerator()) {
        Set-AuthProcessEnvironmentValue `
            -Name $variable.Key `
            -Value $variable.Value
    }
}

function Test-AzdUsesAzureCliAuth {
    param(
        [Parameter(Mandatory)]
        [string]$AzdPath
    )

    $output = @(
        & $AzdPath config get auth.useAzCliAuth 2> $null
    )
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        return $false
    }

    $text = (ConvertTo-NativeOutputText -Output $output).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }

    try {
        return [bool]($text | ConvertFrom-Json)
    }
    catch {
        return $text.Trim('"') -ieq 'true'
    }
}

function Get-AzureCliAccountContext {
    param(
        [Parameter(Mandatory)]
        [string]$AzPath,

        [AllowNull()]
        [string]$SubscriptionId
    )

    $arguments = @(
        'account', 'show',
        '--query', '{subscription_id:id,tenant_id:tenantId}',
        '--output', 'json',
        '--only-show-errors'
    )
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $arguments += @('--subscription', $SubscriptionId)
    }

    $output = @(
        & $AzPath @arguments 2> $null
    )
    $exitCode = $LASTEXITCODE
    $text = (ConvertTo-NativeOutputText -Output $output).Trim()

    if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        $account = $text | ConvertFrom-Json
    }
    catch {
        throw "Azure CLI returned invalid account context. $($_.Exception.Message)"
    }

    $subscriptionId = [guid]::Empty
    $tenantId = [guid]::Empty
    if (
        -not [guid]::TryParse(
            $account.subscription_id,
            [ref]$subscriptionId
        ) -or
        -not [guid]::TryParse($account.tenant_id, [ref]$tenantId)
    ) {
        throw 'Azure CLI returned an account context without valid subscription and tenant IDs.'
    }

    return [ordered]@{
        subscription_id = $subscriptionId.ToString()
        tenant_id = $tenantId.ToString()
    }
}

function Resolve-AzureTargetGuid {
    param(
        [AllowNull()]
        [string]$ConfiguredValue,

        [Parameter(Mandatory)]
        [string]$EnvironmentVariable,

        [Parameter(Mandatory)]
        [string]$AzdEnvironmentKey,

        [AllowNull()]
        [string]$AzdPath,

        [Parameter(Mandatory)]
        [string]$EnvironmentName,

        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [AllowNull()]
        [string]$FallbackValue
    )

    $value = $ConfiguredValue

    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [Environment]::GetEnvironmentVariable(
            $EnvironmentVariable,
            'Process'
        )
    }

    if (
        [string]::IsNullOrWhiteSpace($value) -and
        -not [string]::IsNullOrWhiteSpace($AzdPath)
    ) {
        $output = @(
            & $AzdPath env get-value $AzdEnvironmentKey `
                --environment $EnvironmentName `
                --cwd $RepoRoot `
                2> $null
        )
        if ($LASTEXITCODE -eq 0) {
            $value = (ConvertTo-NativeOutputText -Output $output).Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = $FallbackValue
    }

    $parsedValue = [guid]::Empty
    if (
        [string]::IsNullOrWhiteSpace($value) -or
        -not [guid]::TryParse($value, [ref]$parsedValue)
    ) {
        throw (
            "Set $EnvironmentVariable in .env, pass the corresponding " +
            "parameter, or configure $AzdEnvironmentKey in azd environment " +
            "'$EnvironmentName'."
        )
    }

    return $parsedValue.ToString()
}

function Test-AzureCliAccessTokens {
    param(
        [Parameter(Mandatory)]
        [string]$AzPath,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string[]]$Scopes
    )

    foreach ($scope in $Scopes) {
        & $AzPath account get-access-token `
            --subscription $SubscriptionId `
            --scope $scope `
            --output none `
            --only-show-errors `
            1> $null `
            2> $null

        if ($LASTEXITCODE -ne 0) {
            return $false
        }
    }

    return $true
}

function Initialize-AzdAccessToken {
    param(
        [Parameter(Mandatory)]
        [string]$AzdPath,

        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$Scope
    )

    & $AzdPath auth token `
        --tenant-id $TenantId `
        --scope $Scope `
        --output json `
        --no-prompt `
        1> $null

    if ($LASTEXITCODE -ne 0) {
        throw "azd could not acquire the required access token for $Scope."
    }
}

function Set-AzureCliSubscription {
    param(
        [Parameter(Mandatory)]
        [string]$AzPath,

        [Parameter(Mandatory)]
        [string]$SubscriptionId
    )

    & $AzPath account set `
        --subscription $SubscriptionId `
        --only-show-errors `
        1> $null `
        2> $null

    return $LASTEXITCODE -eq 0
}

function Invoke-AzureCliDeviceCodeLogin {
    param(
        [Parameter(Mandatory)]
        [string]$AzPath,

        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string[]]$Scopes
    )

    Write-Host (
        'Refreshing Azure CLI authentication for the configured Foundry ' +
        'tenant with device code.'
    )
    & $AzPath login `
        --use-device-code `
        --tenant $TenantId `
        --skip-subscription-discovery `
        --subscription $SubscriptionId `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw 'Azure CLI device-code login failed.'
    }

    if (
        -not (Set-AzureCliSubscription `
            -AzPath $AzPath `
            -SubscriptionId $SubscriptionId)
    ) {
        throw 'Azure CLI login completed, but the target subscription could not be selected.'
    }

    if (
        -not (Test-AzureCliAccessTokens `
            -AzPath $AzPath `
            -SubscriptionId $SubscriptionId `
            -Scopes $Scopes)
    ) {
        throw 'Azure CLI login completed, but required access tokens could not be acquired.'
    }
}

function Ensure-AzureCliAuthentication {
    param(
        [Parameter(Mandatory)]
        [string]$AzPath,

        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string[]]$Scopes,

        [switch]$ForceDeviceCodeLogin
    )

    $originalContext = Get-AzureCliAccountContext -AzPath $AzPath
    $contextChanged = $false

    try {
        $targetSelected = (
            $null -ne $originalContext -and
            $originalContext.tenant_id -eq $TenantId -and
            $originalContext.subscription_id -eq $SubscriptionId
        )

        if (-not $targetSelected -and -not $ForceDeviceCodeLogin) {
            $targetSelected = Set-AzureCliSubscription `
                -AzPath $AzPath `
                -SubscriptionId $SubscriptionId
            $contextChanged = $targetSelected
        }

        $tokensAvailable = (
            $targetSelected -and
            (Test-AzureCliAccessTokens `
                -AzPath $AzPath `
                -SubscriptionId $SubscriptionId `
                -Scopes $Scopes)
        )
        $deviceCodeLoginUsed = (
            $ForceDeviceCodeLogin -or
            -not $targetSelected -or
            -not $tokensAvailable
        )

        if ($deviceCodeLoginUsed) {
            Invoke-AzureCliDeviceCodeLogin `
                -AzPath $AzPath `
                -TenantId $TenantId `
                -SubscriptionId $SubscriptionId `
                -Scopes $Scopes
            $contextChanged = (
                $null -eq $originalContext -or
                $originalContext.subscription_id -ne $SubscriptionId
            )
        }

        return [ordered]@{
            tenant_id = $TenantId
            subscription_id = $SubscriptionId
            device_code_login_used = $deviceCodeLoginUsed
            context_switched = $contextChanged
            original_subscription_id = if ($null -eq $originalContext) {
                $null
            }
            else {
                $originalContext.subscription_id
            }
        }
    }
    catch {
        if (
            $contextChanged -and
            $null -ne $originalContext
        ) {
            $null = Set-AzureCliSubscription `
                -AzPath $AzPath `
                -SubscriptionId $originalContext.subscription_id
        }

        throw
    }
}

function Restore-AzureCliAuthentication {
    param(
        [Parameter(Mandatory)]
        [string]$AzPath,

        [AllowNull()]
        [System.Collections.IDictionary]$State
    )

    if (
        $null -eq $State -or
        -not $State.context_switched -or
        [string]::IsNullOrWhiteSpace($State.original_subscription_id)
    ) {
        return
    }

    if (
        -not (Set-AzureCliSubscription `
            -AzPath $AzPath `
            -SubscriptionId $State.original_subscription_id)
    ) {
        Write-Warning 'Could not restore the original Azure CLI subscription context.'
    }
}
