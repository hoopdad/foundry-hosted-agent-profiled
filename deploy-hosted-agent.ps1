#Requires -Version 7.2

[CmdletBinding()]
param(
    [string]$ProjectId,

    [string]$AgentName,

    [string]$EnvironmentName,

    [string]$Runtime,

    [string]$AzureTenantId,

    [string]$AzureSubscriptionId,

    [string]$AzdHttpsProxy,

    [string]$ProxyStatePath,

    [ValidateRange(60, 7200)]
    [int]$TimeoutSeconds = 1200,

    [switch]$RefreshAzureLogin,

    [switch]$Preview,

    [switch]$VerifyOnly,

    [Parameter(DontShow)]
    [switch]$ProxyHost,

    [Parameter(DontShow)]
    [string]$ProxyHostSessionId,

    [Parameter(DontShow)]
    [string]$ProxyStopSignalPath,

    [Parameter(DontShow)]
    [string]$ProxyStartupResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSCommandPath
$azureYamlPath = Join-Path $repoRoot 'azure.yaml'
$entryPointPath = Join-Path $repoRoot 'server_host.py'
$requirementsPath = Join-Path $repoRoot 'requirements.txt'
$agentIgnorePath = Join-Path $repoRoot '.agentignore'
$ownedProcessPath = Join-Path $repoRoot 'BastionOwnedProcess.cs'
. (Join-Path $repoRoot 'azure-cli-auth.ps1')
. (Join-Path $repoRoot 'foundry-proxy-control.ps1')

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

Import-DotEnv -Path (Join-Path $repoRoot '.env')

$ProjectId = Resolve-Setting -ParameterValue $ProjectId `
    -EnvironmentVariable 'FOUNDRY_PROJECT_ID'
$AgentName = Resolve-Setting -ParameterValue $AgentName `
    -EnvironmentVariable 'FOUNDRY_AGENT_NAME' `
    -DefaultValue 'foundry-hosted-agent-profiled'
$EnvironmentName = Resolve-Setting -ParameterValue $EnvironmentName `
    -EnvironmentVariable 'AZD_ENVIRONMENT_NAME' `
    -DefaultValue 'foundry-hosted-agent-profiled'
$Runtime = Resolve-Setting -ParameterValue $Runtime `
    -EnvironmentVariable 'FOUNDRY_AGENT_RUNTIME' `
    -DefaultValue 'python_3_14'
$AzdHttpsProxy = Resolve-Setting -ParameterValue $AzdHttpsProxy `
    -EnvironmentVariable 'FOUNDRY_AZD_HTTPS_PROXY'
$ProxyStatePath = Resolve-Setting -ParameterValue $ProxyStatePath `
    -EnvironmentVariable 'FOUNDRY_PROXY_STATE_PATH' `
    -DefaultValue (Join-Path $repoRoot 'run-logs\proxy\state.json')
$ProxyStatePath = [IO.Path]::GetFullPath($ProxyStatePath)
$BastionAzureConfigDir = Resolve-Setting -ParameterValue $null `
    -EnvironmentVariable 'FOUNDRY_BASTION_AZURE_CONFIG_DIR'
$BastionSubscriptionId = Resolve-Setting -ParameterValue $null `
    -EnvironmentVariable 'FOUNDRY_BASTION_SUBSCRIPTION_ID'
$BastionTenantId = Resolve-Setting -ParameterValue $null `
    -EnvironmentVariable 'FOUNDRY_BASTION_TENANT_ID'
$BastionResourceGroup = Resolve-Setting -ParameterValue $null `
    -EnvironmentVariable 'FOUNDRY_BASTION_RESOURCE_GROUP'
$BastionName = Resolve-Setting -ParameterValue $null `
    -EnvironmentVariable 'FOUNDRY_BASTION_NAME'
$BastionVmResourceId = Resolve-Setting -ParameterValue $null `
    -EnvironmentVariable 'FOUNDRY_BASTION_VM_RESOURCE_ID'
$BastionVmUser = Resolve-Setting -ParameterValue $null `
    -EnvironmentVariable 'FOUNDRY_BASTION_VM_USER' `
    -DefaultValue 'azureuser'
$BastionIdentityFile = Resolve-Setting -ParameterValue $null `
    -EnvironmentVariable 'FOUNDRY_BASTION_IDENTITY_FILE'
$BastionKnownHostsFile = Resolve-Setting -ParameterValue $null `
    -EnvironmentVariable 'FOUNDRY_BASTION_KNOWN_HOSTS_FILE' `
    -DefaultValue (Join-Path $HOME '.ssh\known_hosts')
$BastionHostKeyAlias = Resolve-Setting -ParameterValue $null `
    -EnvironmentVariable 'FOUNDRY_BASTION_HOST_KEY_ALIAS'
$bastionTunnelPortText = Resolve-Setting -ParameterValue $null `
    -EnvironmentVariable 'FOUNDRY_BASTION_TUNNEL_PORT' `
    -DefaultValue '2222'

$BastionTunnelPort = 0
if (
    -not [int]::TryParse($bastionTunnelPortText, [ref]$BastionTunnelPort) -or
    $BastionTunnelPort -lt 1 -or
    $BastionTunnelPort -gt 65535
) {
    throw 'FOUNDRY_BASTION_TUNNEL_PORT must be an integer from 1 through 65535.'
}

if ([string]::IsNullOrWhiteSpace($ProjectId)) {
    throw 'Set FOUNDRY_PROJECT_ID in .env or pass -ProjectId.'
}

if ($ProjectId -match '[<>]') {
    throw 'Replace the FOUNDRY_PROJECT_ID placeholder in .env with your real Foundry project ARM resource ID.'
}

if ($AgentName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$') {
    throw 'FOUNDRY_AGENT_NAME must contain only letters, numbers, hyphens, or underscores.'
}

if ($EnvironmentName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$') {
    throw 'AZD_ENVIRONMENT_NAME must contain only letters, numbers, hyphens, or underscores.'
}

if ($Runtime -notin @('python_3_13', 'python_3_14')) {
    throw 'FOUNDRY_AGENT_RUNTIME must be python_3_13 or python_3_14.'
}

if ($Preview -and $VerifyOnly) {
    throw 'Use either -Preview or -VerifyOnly, not both.'
}

function Resolve-LocalPath {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path.Trim())

    if ($expandedPath -eq '~') {
        $expandedPath = $HOME
    }
    elseif ($expandedPath.StartsWith('~\')) {
        $expandedPath = Join-Path $HOME $expandedPath.Substring(2)
    }

    try {
        return [System.IO.Path]::GetFullPath($expandedPath)
    }
    catch {
        throw "$Name must be a valid local path. $($_.Exception.Message)"
    }
}

function Resolve-LoopbackSocksProxyUri {
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

    return $proxyUri
}

function Test-TcpListener {
    param(
        [Parameter(Mandatory)]
        [string]$HostName,

        [Parameter(Mandatory)]
        [int]$Port,

        [ValidateRange(1, 30)]
        [int]$TimeoutSeconds = 2
    )

    $client = [System.Net.Sockets.TcpClient]::new()

    try {
        $connectTask = $client.ConnectAsync($HostName, $Port)
        if (-not $connectTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            return $false
        }

        $connectTask.GetAwaiter().GetResult()
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Assert-LoopbackSocksProxy {
    param(
        [Parameter(Mandatory)]
        [string]$Proxy
    )

    $proxyUri = Resolve-LoopbackSocksProxyUri -Proxy $Proxy
    $listeners = @(
        Get-NetTCPConnection -State Listen -LocalPort $proxyUri.Port `
            -ErrorAction SilentlyContinue
    )

    if (
        $listeners.Count -ne 1 -or
        $listeners[0].LocalAddress -cne '127.0.0.1'
    ) {
        throw (
            "The SSH SOCKS proxy at $Proxy must have exactly one " +
            '127.0.0.1 listener.'
        )
    }

    if (
        -not (Test-TcpListener -HostName $proxyUri.Host -Port $proxyUri.Port)
    ) {
        throw "The SSH SOCKS proxy is not reachable at $Proxy."
    }
}

function Get-FreeLoopbackPort {
    param(
        [Parameter(Mandatory)]
        [int]$Preferred,

        [int[]]$Exclude = @()
    )

    $listeningPorts = @(
        Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty LocalPort -Unique
    )

    if (
        $Preferred -notin $listeningPorts -and
        $Preferred -notin $Exclude
    ) {
        return $Preferred
    }

    foreach ($port in 20000..24000) {
        if ($port -notin $listeningPorts -and $port -notin $Exclude) {
            return $port
        }
    }

    throw 'No free local loopback port was found from 20000 through 24000.'
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)]
        [string]$AzPath,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$Operation
    )

    $output = @(& $AzPath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { $_.ToString() }) -join (
        [Environment]::NewLine
    )

    if ($exitCode -ne 0) {
        $detail = $text.Trim()
        if ($detail.Length -gt 1000) {
            $detail = $detail.Substring(0, 1000)
        }

        throw "$Operation failed with exit code $exitCode. $detail"
    }

    try {
        return $text | ConvertFrom-Json
    }
    catch {
        throw "$Operation returned invalid JSON. $($_.Exception.Message)"
    }
}

function Get-BastionSocksConfiguration {
    param(
        [Parameter(Mandatory)]
        [uri]$ProxyUri
    )

    $requiredSettings = [ordered]@{
        FOUNDRY_BASTION_AZURE_CONFIG_DIR = $BastionAzureConfigDir
        FOUNDRY_BASTION_SUBSCRIPTION_ID = $BastionSubscriptionId
        FOUNDRY_BASTION_TENANT_ID = $BastionTenantId
        FOUNDRY_BASTION_RESOURCE_GROUP = $BastionResourceGroup
        FOUNDRY_BASTION_NAME = $BastionName
        FOUNDRY_BASTION_VM_RESOURCE_ID = $BastionVmResourceId
        FOUNDRY_BASTION_VM_USER = $BastionVmUser
        FOUNDRY_BASTION_IDENTITY_FILE = $BastionIdentityFile
        FOUNDRY_BASTION_KNOWN_HOSTS_FILE = $BastionKnownHostsFile
        FOUNDRY_BASTION_HOST_KEY_ALIAS = $BastionHostKeyAlias
    }
    $missingSettings = @(
        $requiredSettings.GetEnumerator() |
            Where-Object { [string]::IsNullOrWhiteSpace($_.Value) } |
            ForEach-Object { $_.Key }
    )

    if ($missingSettings.Count -gt 0) {
        throw (
            "The SSH SOCKS proxy is not reachable at $($ProxyUri.AbsoluteUri), " +
            'and automatic Bastion startup is not configured. Set: ' +
            ($missingSettings -join ', ')
        )
    }

    $subscriptionGuid = [guid]::Empty
    if (
        -not [guid]::TryParse(
            $BastionSubscriptionId,
            [ref]$subscriptionGuid
        )
    ) {
        throw 'FOUNDRY_BASTION_SUBSCRIPTION_ID must be a GUID.'
    }

    $tenantGuid = [guid]::Empty
    if (-not [guid]::TryParse($BastionTenantId, [ref]$tenantGuid)) {
        throw 'FOUNDRY_BASTION_TENANT_ID must be a GUID.'
    }

    $vmResourceIdMatch = [regex]::Match(
        $BastionVmResourceId,
        '(?i)^/subscriptions/(?<subscription>[^/]+)/resourceGroups/[^/]+/providers/Microsoft\.Compute/virtualMachines/[^/]+/?$'
    )
    if (-not $vmResourceIdMatch.Success) {
        throw 'FOUNDRY_BASTION_VM_RESOURCE_ID must be a virtual-machine ARM resource ID.'
    }

    if (
        $vmResourceIdMatch.Groups['subscription'].Value -ine
        $subscriptionGuid.ToString()
    ) {
        throw 'The Bastion VM resource ID must use FOUNDRY_BASTION_SUBSCRIPTION_ID.'
    }

    $azureConfigDir = Resolve-LocalPath `
        -Name 'FOUNDRY_BASTION_AZURE_CONFIG_DIR' `
        -Path $BastionAzureConfigDir
    $identityFile = Resolve-LocalPath `
        -Name 'FOUNDRY_BASTION_IDENTITY_FILE' `
        -Path $BastionIdentityFile
    $knownHostsFile = Resolve-LocalPath `
        -Name 'FOUNDRY_BASTION_KNOWN_HOSTS_FILE' `
        -Path $BastionKnownHostsFile

    if (-not (Test-Path -LiteralPath $azureConfigDir -PathType Container)) {
        throw "The isolated Azure CLI profile directory was not found: $azureConfigDir"
    }

    foreach ($requiredFile in @($identityFile, $knownHostsFile)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Required SSH file not found: $requiredFile"
        }
    }

    foreach ($setting in $requiredSettings.GetEnumerator()) {
        if ($setting.Value -match '[\r\n]') {
            throw "$($setting.Key) must be a single-line value."
        }
    }

    if ($BastionVmUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$') {
        throw 'FOUNDRY_BASTION_VM_USER must be a valid Linux user name.'
    }

    return [pscustomobject]@{
        AzureConfigDir = $azureConfigDir
        SubscriptionId = $subscriptionGuid.ToString()
        TenantId = $tenantGuid.ToString()
        ResourceGroup = $BastionResourceGroup
        Name = $BastionName
        VmResourceId = $BastionVmResourceId.TrimEnd('/')
        VmUser = $BastionVmUser
        IdentityFile = $identityFile
        KnownHostsFile = $knownHostsFile
        HostKeyAlias = $BastionHostKeyAlias
        TunnelPort = $BastionTunnelPort
    }
}

function Assert-BastionSocksPrerequisites {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Configuration
    )

    if (-not $IsWindows) {
        throw 'Automatic Bastion SOCKS startup currently requires Windows.'
    }

    if (-not (Test-Path -LiteralPath $ownedProcessPath -PathType Leaf)) {
        throw "Required owned-process helper not found: $ownedProcessPath"
    }

    $azCommand = Get-Command az -CommandType Application `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $sshCommand = Get-Command ssh.exe -CommandType Application `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $sshKeygenCommand = Get-Command ssh-keygen.exe -CommandType Application `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $pwshPath = Join-Path $PSHOME 'pwsh.exe'

    if (-not $azCommand) {
        throw 'Azure CLI (az) is required for automatic Bastion startup.'
    }

    if (-not $sshCommand -or -not $sshKeygenCommand) {
        throw 'Windows OpenSSH (ssh.exe and ssh-keygen.exe) is required for automatic Bastion startup.'
    }

    if (-not (Test-Path -LiteralPath $pwshPath -PathType Leaf)) {
        throw "PowerShell executable not found: $pwshPath"
    }

    $null = & $sshKeygenCommand.Source -F $Configuration.HostKeyAlias `
        -f $Configuration.KnownHostsFile 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw (
            "The trusted host alias '$($Configuration.HostKeyAlias)' was not " +
            "found in $($Configuration.KnownHostsFile)."
        )
    }

    $previousAzureConfigDir = [Environment]::GetEnvironmentVariable(
        'AZURE_CONFIG_DIR',
        'Process'
    )
    $previousDynamicInstall = [Environment]::GetEnvironmentVariable(
        'AZURE_EXTENSION_USE_DYNAMIC_INSTALL',
        'Process'
    )

    try {
        $env:AZURE_CONFIG_DIR = $Configuration.AzureConfigDir
        $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'no'

        $account = Invoke-AzJson `
            -AzPath $azCommand.Source `
            -Arguments @(
                'account', 'show',
                '--subscription', $Configuration.SubscriptionId,
                '--query', '{subscription:id,tenant:tenantId}',
                '--output', 'json',
                '--only-show-errors'
            ) `
            -Operation 'Azure CLI lab-context validation'
        if (
            $account.subscription -ine $Configuration.SubscriptionId -or
            $account.tenant -ine $Configuration.TenantId
        ) {
            throw 'The isolated Azure CLI profile resolved the wrong subscription or tenant.'
        }

        $extension = Invoke-AzJson `
            -AzPath $azCommand.Source `
            -Arguments @(
                'extension', 'show',
                '--name', 'bastion',
                '--query', '{name:name,version:version}',
                '--output', 'json',
                '--only-show-errors'
            ) `
            -Operation 'Azure CLI Bastion extension validation'
        if (
            $extension.name -cne 'bastion' -or
            [string]::IsNullOrWhiteSpace($extension.version)
        ) {
            throw 'The installed Azure CLI Bastion extension is invalid.'
        }

        $bastion = Invoke-AzJson `
            -AzPath $azCommand.Source `
            -Arguments @(
                'network', 'bastion', 'show',
                '--subscription', $Configuration.SubscriptionId,
                '--resource-group', $Configuration.ResourceGroup,
                '--name', $Configuration.Name,
                '--query',
                '{id:id,sku:sku.name,enableTunneling:enableTunneling,provisioningState:provisioningState}',
                '--output', 'json',
                '--only-show-errors'
            ) `
            -Operation 'Azure Bastion validation'
        if (
            $bastion.provisioningState -cne 'Succeeded' -or
            $bastion.enableTunneling -ne $true -or
            $bastion.sku -notin @('Standard', 'Premium')
        ) {
            throw 'Azure Bastion must be Succeeded, Standard or Premium, with native tunneling enabled.'
        }

        $vm = Invoke-AzJson `
            -AzPath $azCommand.Source `
            -Arguments @(
                'vm', 'show',
                '--ids', $Configuration.VmResourceId,
                '--query', '{id:id,provisioningState:provisioningState}',
                '--output', 'json',
                '--only-show-errors'
            ) `
            -Operation 'Bastion target VM validation'
        if (
            $vm.id.TrimEnd('/') -ine $Configuration.VmResourceId -or
            $vm.provisioningState -cne 'Succeeded'
        ) {
            throw 'The Bastion target VM is missing, changed, or not provisioned.'
        }
    }
    finally {
        Restore-ProcessEnvironmentVariable `
            -Name 'AZURE_CONFIG_DIR' `
            -Value $previousAzureConfigDir
        Restore-ProcessEnvironmentVariable `
            -Name 'AZURE_EXTENSION_USE_DYNAMIC_INSTALL' `
            -Value $previousDynamicInstall
    }

    return [pscustomobject]@{
        AzPath = $azCommand.Source
        SshPath = $sshCommand.Source
        PwshPath = $pwshPath
    }
}

function Initialize-OwnedProcessType {
    if (-not ('ThinkFast.Bastion.OwnedProcess' -as [type])) {
        Add-Type -Path $ownedProcessPath
    }
}

function Wait-OwnedLoopbackListener {
    param(
        [Parameter(Mandatory)]
        [object]$Owner,

        [Parameter(Mandatory)]
        [int]$Port,

        [Parameter(Mandatory)]
        [string]$Name,

        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()

    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($Owner.Process.HasExited) {
            throw (
                "$Name exited before opening 127.0.0.1:$Port " +
                "(exit code $($Owner.Process.ExitCode))."
            )
        }

        $listeners = @(
            Get-NetTCPConnection -State Listen -LocalPort $Port `
                -ErrorAction SilentlyContinue
        )

        if ($listeners.Count -gt 0) {
            if (
                $listeners.Count -ne 1 -or
                $listeners[0].LocalAddress -cne '127.0.0.1' -or
                -not $Owner.ContainsPid($listeners[0].OwningProcess)
            ) {
                throw (
                    "$Name did not exclusively own a 127.0.0.1:$Port " +
                    'listener.'
                )
            }

            return
        }

        Start-Sleep -Milliseconds 200
    }

    throw "Timed out waiting for $Name on 127.0.0.1:$Port."
}

function Stop-BastionSocksProxy {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session
    )

    $closureFailures = [Collections.Generic.List[string]]::new()

    foreach ($ownedProcess in @($Session.Ssh, $Session.Tunnel)) {
        if ($null -eq $ownedProcess) {
            continue
        }

        try {
            $ownedProcess.Dispose()
        }
        catch {
            $closureFailures.Add($_.Exception.Message)
        }
    }

    foreach ($port in @($Session.SocksPort, $Session.TunnelPort)) {
        if (
            Get-NetTCPConnection -State Listen -LocalPort $port `
                -ErrorAction SilentlyContinue
        ) {
            $closureFailures.Add(
                "A listener remains on local port $port."
            )
        }
    }

    if ($closureFailures.Count -gt 0) {
        throw (
            'CLOSURE_UNKNOWN: ' +
            ($closureFailures -join ' ')
        )
    }

    Write-Host 'Stopped the owned SSH SOCKS proxy and Azure Bastion tunnel.'
}

function Start-BastionSocksProxy {
    param(
        [Parameter(Mandatory)]
        [uri]$ProxyUri
    )

    $configuration = Get-BastionSocksConfiguration -ProxyUri $ProxyUri
    $prerequisites = Assert-BastionSocksPrerequisites `
        -Configuration $configuration
    Initialize-OwnedProcessType

    $tunnelPort = Get-FreeLoopbackPort `
        -Preferred $configuration.TunnelPort `
        -Exclude @($ProxyUri.Port)
    if ($tunnelPort -ne $configuration.TunnelPort) {
        Write-Host (
            "Bastion tunnel port $($configuration.TunnelPort) is busy; " +
            "using $tunnelPort."
        )
    }

    $tunnelArguments = @(
        'network', 'bastion', 'tunnel',
        '--subscription', $configuration.SubscriptionId,
        '--resource-group', $configuration.ResourceGroup,
        '--name', $configuration.Name,
        '--target-resource-id', $configuration.VmResourceId,
        '--resource-port', '22',
        '--port', $tunnelPort.ToString(),
        '--only-show-errors'
    )
    $commandPayload = [ordered]@{
        application = $prerequisites.AzPath
        arguments = $tunnelArguments
    } | ConvertTo-Json -Depth 3 -Compress
    $payloadBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($commandPayload)
    )
    $tunnelCommand = @"
`$payloadJson = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String('$payloadBase64')
)
`$payload = `$payloadJson | ConvertFrom-Json
& ([string]`$payload.application) @(`$payload.arguments)
exit `$LASTEXITCODE
"@
    $encodedTunnelCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($tunnelCommand)
    )

    $tunnelOwner = $null
    $sshOwner = $null
    $previousAzureConfigDir = [Environment]::GetEnvironmentVariable(
        'AZURE_CONFIG_DIR',
        'Process'
    )
    $previousDynamicInstall = [Environment]::GetEnvironmentVariable(
        'AZURE_EXTENSION_USE_DYNAMIC_INSTALL',
        'Process'
    )

    try {
        Write-Host (
            "Starting Azure Bastion tunnel on 127.0.0.1:$tunnelPort."
        )
        $env:AZURE_CONFIG_DIR = $configuration.AzureConfigDir
        $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'no'
        $tunnelOwner = [ThinkFast.Bastion.OwnedProcess]::Launch(
            $prerequisites.PwshPath,
            [string[]]@(
                '-NoProfile',
                '-NonInteractive',
                '-EncodedCommand',
                $encodedTunnelCommand
            )
        )
    }
    finally {
        Restore-ProcessEnvironmentVariable `
            -Name 'AZURE_CONFIG_DIR' `
            -Value $previousAzureConfigDir
        Restore-ProcessEnvironmentVariable `
            -Name 'AZURE_EXTENSION_USE_DYNAMIC_INSTALL' `
            -Value $previousDynamicInstall
    }

    try {
        Wait-OwnedLoopbackListener `
            -Owner $tunnelOwner `
            -Port $tunnelPort `
            -Name 'Azure Bastion tunnel' `
            -TimeoutSeconds 60

        $sshArguments = @(
            '-F', 'none',
            '-N',
            '-T',
            '-D', "127.0.0.1:$($ProxyUri.Port)",
            '-p', $tunnelPort.ToString(),
            '-i', $configuration.IdentityFile,
            '-o', "UserKnownHostsFile=$($configuration.KnownHostsFile)",
            '-o', 'GlobalKnownHostsFile=none',
            '-o', "HostKeyAlias=$($configuration.HostKeyAlias)",
            '-o', 'StrictHostKeyChecking=yes',
            '-o', 'IdentitiesOnly=yes',
            '-o', 'ForwardAgent=no',
            '-o', 'PasswordAuthentication=no',
            '-o', 'KbdInteractiveAuthentication=no',
            '-o', 'BatchMode=yes',
            '-o', 'ExitOnForwardFailure=yes',
            '-o', 'ConnectTimeout=20',
            '-o', 'ServerAliveInterval=30',
            '-o', 'ServerAliveCountMax=2',
            "$($configuration.VmUser)@127.0.0.1"
        )

        Write-Host (
            "Starting strict SSH SOCKS proxy on 127.0.0.1:$($ProxyUri.Port)."
        )
        $sshOwner = [ThinkFast.Bastion.OwnedProcess]::Launch(
            $prerequisites.SshPath,
            [string[]]$sshArguments
        )
        Wait-OwnedLoopbackListener `
            -Owner $sshOwner `
            -Port $ProxyUri.Port `
            -Name 'SSH SOCKS proxy' `
            -TimeoutSeconds 30
        Assert-LoopbackSocksProxy -Proxy $ProxyUri.AbsoluteUri

        Write-Host "SSH SOCKS proxy is ready at $($ProxyUri.AbsoluteUri)."
        return [pscustomobject]@{
            Tunnel = $tunnelOwner
            Ssh = $sshOwner
            TunnelPort = $tunnelPort
            SocksPort = $ProxyUri.Port
        }
    }
    catch {
        $primaryFailure = $_
        $partialSession = [pscustomobject]@{
            Tunnel = $tunnelOwner
            Ssh = $sshOwner
            TunnelPort = $tunnelPort
            SocksPort = $ProxyUri.Port
        }

        try {
            Stop-BastionSocksProxy -Session $partialSession
        }
        catch {
            throw [InvalidOperationException]::new(
                (
                    "$($primaryFailure.Exception.Message) " +
                    "Proxy cleanup also failed: $($_.Exception.Message)"
                ),
                $primaryFailure.Exception
            )
        }

        throw $primaryFailure
    }
}

function Invoke-PersistentProxyHost {
    param(
        [Parameter(Mandatory)]
        [uri]$ProxyUri,

        [Parameter(Mandatory)]
        [string]$StatePath,

        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [string]$StopSignalPath,

        [Parameter(Mandatory)]
        [string]$StartupResultPath
    )

    $sessionGuid = [guid]::Empty
    if (-not [guid]::TryParse($SessionId, [ref]$sessionGuid)) {
        throw 'The persistent proxy host session ID is invalid.'
    }
    $normalizedSessionId = $sessionGuid.ToString('N')
    $StatePath = [IO.Path]::GetFullPath($StatePath)
    $StopSignalPath = [IO.Path]::GetFullPath($StopSignalPath)
    $StartupResultPath = [IO.Path]::GetFullPath($StartupResultPath)
    $stateDirectory = Split-Path -Parent $StatePath

    foreach ($controlPath in @($StopSignalPath, $StartupResultPath)) {
        if ((Split-Path -Parent $controlPath) -ine $stateDirectory) {
            throw 'Persistent proxy control files must share one directory.'
        }
    }
    if (
        [IO.Path]::GetFileName($StopSignalPath) -ine
            "stop-$normalizedSessionId.json"
    ) {
        throw 'The persistent proxy stop-signal name is invalid.'
    }

    $session = $null
    $stateWritten = $false
    $startupReady = $false
    $primaryFailure = $null
    $cleanupFailure = $null

    try {
        if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
            throw "Persistent proxy state already exists at $StatePath."
        }

        $session = Start-BastionSocksProxy -ProxyUri $ProxyUri
        $socksListener = Get-FoundryProxyListener -Port $session.SocksPort
        $tunnelListener = Get-FoundryProxyListener -Port $session.TunnelPort
        if ($null -eq $socksListener -or $null -eq $tunnelListener) {
            throw 'A proxy listener disappeared during host startup.'
        }

        $hostProcess = Get-Process -Id $PID -ErrorAction Stop
        try {
            $now = [DateTimeOffset]::UtcNow.ToString(
                'o',
                [Globalization.CultureInfo]::InvariantCulture
            )
            $state = [ordered]@{
                schema_version = 1
                status = 'running'
                session_id = $normalizedSessionId
                host_process_id = $PID
                host_process_start_utc = (
                    [DateTimeOffset]$hostProcess.StartTime.ToUniversalTime()
                ).ToString(
                    'o',
                    [Globalization.CultureInfo]::InvariantCulture
                )
                host_executable_path = $hostProcess.Path
                proxy_uri = $ProxyUri.AbsoluteUri
                socks_port = $session.SocksPort
                socks_listener_pid = $socksListener.OwningProcess
                tunnel_port = $session.TunnelPort
                tunnel_listener_pid = $tunnelListener.OwningProcess
                stop_signal_path = $StopSignalPath
                started_utc = $now
            }
        }
        finally {
            $hostProcess.Dispose()
        }

        Write-FoundryProxyJsonAtomically -Path $StatePath -Value $state
        $stateWritten = $true
        Write-FoundryProxyJsonAtomically `
            -Path $StartupResultPath `
            -Value ([ordered]@{
                schema_version = 1
                status = 'ready'
                session_id = $normalizedSessionId
                ready_utc = [DateTimeOffset]::UtcNow.ToString(
                    'o',
                    [Globalization.CultureInfo]::InvariantCulture
                )
            })
        $startupReady = $true

        while ($true) {
            if (
                $session.Tunnel.Process.HasExited -or
                $session.Ssh.Process.HasExited
            ) {
                throw 'An owned proxy process exited unexpectedly.'
            }

            if (Test-Path -LiteralPath $StopSignalPath -PathType Leaf) {
                $signal = Read-FoundryProxyJson `
                    -Path $StopSignalPath `
                    -Description 'Foundry proxy stop signal'
                if ($signal.session_id -cne $normalizedSessionId) {
                    throw 'The proxy stop signal has a different session ID.'
                }

                break
            }

            Start-Sleep -Milliseconds 500
        }
    }
    catch {
        $primaryFailure = $_
        if (-not $startupReady) {
            try {
                Write-FoundryProxyJsonAtomically `
                    -Path $StartupResultPath `
                    -Value ([ordered]@{
                        schema_version = 1
                        status = 'failed'
                        session_id = $normalizedSessionId
                        failed_utc = [DateTimeOffset]::UtcNow.ToString(
                            'o',
                            [Globalization.CultureInfo]::InvariantCulture
                        )
                        error = $_.Exception.Message
                    })
            }
            catch {
                $cleanupFailure = $_
            }
        }
    }
    finally {
        if ($null -ne $session) {
            try {
                Stop-BastionSocksProxy -Session $session
            }
            catch {
                $cleanupFailure = $_
            }
        }

        if ($null -eq $cleanupFailure) {
            foreach ($controlPath in @($StatePath, $StopSignalPath)) {
                if (-not (Test-Path -LiteralPath $controlPath -PathType Leaf)) {
                    continue
                }

                try {
                    $control = Read-FoundryProxyJson `
                        -Path $controlPath `
                        -Description 'Foundry proxy control file'
                    if ($control.session_id -ceq $normalizedSessionId) {
                        Remove-Item -LiteralPath $controlPath -Force
                    }
                }
                catch {
                    $cleanupFailure = $_
                    break
                }
            }
        }
    }

    if ($null -ne $primaryFailure -and $null -ne $cleanupFailure) {
        throw [InvalidOperationException]::new(
            (
                "$($primaryFailure.Exception.Message) " +
                "Proxy host cleanup also failed: " +
                $cleanupFailure.Exception.Message
            ),
            $primaryFailure.Exception
        )
    }
    if ($null -ne $cleanupFailure) {
        throw $cleanupFailure
    }
    if ($null -ne $primaryFailure) {
        throw $primaryFailure
    }
}

function Start-PersistentBastionSocksProxy {
    param(
        [Parameter(Mandatory)]
        [uri]$ProxyUri,

        [Parameter(Mandatory)]
        [string]$StatePath
    )

    $StatePath = [IO.Path]::GetFullPath($StatePath)
    $stateDirectory = Split-Path -Parent $StatePath
    $null = New-Item -ItemType Directory -Path $stateDirectory -Force

    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        $existingState = Read-FoundryProxyJson `
            -Path $StatePath `
            -Description 'Foundry proxy state'
        $existingState = Assert-FoundryProxyState `
            -State $existingState `
            -StatePath $StatePath
        $existingHost = Get-FoundryProxyHostProcess -State $existingState

        if ($null -ne $existingHost) {
            try {
                Assert-LoopbackSocksProxy -Proxy $existingState.proxy_uri
                Write-Host (
                    'Reusing the deploy-owned persistent SSH SOCKS proxy ' +
                    "at $($existingState.proxy_uri)."
                )
                return $existingState
            }
            finally {
                $existingHost.Dispose()
            }
        }

        foreach ($port in @(
            [int]$existingState.socks_port
            [int]$existingState.tunnel_port
        )) {
            if ($null -ne (Get-FoundryProxyListener -Port $port)) {
                throw (
                    'Stale proxy state references a port that still has a ' +
                    'listener. Refusing to claim or stop an unowned process.'
                )
            }
        }

        Remove-Item -LiteralPath $StatePath -Force
        if (
            Test-Path -LiteralPath $existingState.stop_signal_path `
                -PathType Leaf
        ) {
            Remove-Item -LiteralPath $existingState.stop_signal_path -Force
        }
    }

    $sessionId = [guid]::NewGuid().ToString('N')
    $stopSignalPath = Join-Path `
        $stateDirectory `
        "stop-$sessionId.json"
    $startupResultPath = Join-Path `
        $stateDirectory `
        "startup-$sessionId.json"
    $stdoutPath = Join-Path $stateDirectory "host-$sessionId.stdout.log"
    $stderrPath = Join-Path $stateDirectory "host-$sessionId.stderr.log"
    foreach ($path in @(
        $stopSignalPath
        $startupResultPath
        $stdoutPath
        $stderrPath
    )) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }

    $pwshCommand = Get-Command pwsh -CommandType Application `
        -ErrorAction Stop |
        Select-Object -First 1
    $hostPayload = [ordered]@{
        script_path = $PSCommandPath
        project_id = $ProjectId
        proxy_uri = $ProxyUri.AbsoluteUri
        state_path = $StatePath
        session_id = $sessionId
        stop_signal_path = $stopSignalPath
        startup_result_path = $startupResultPath
    } | ConvertTo-Json -Compress
    $hostPayloadBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($hostPayload)
    )
    $hostCommand = @"
try {
    `$payloadText = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('$hostPayloadBase64')
    )
    `$payload = `$payloadText | ConvertFrom-Json
    & ([string]`$payload.script_path) ``
        -ProjectId ([string]`$payload.project_id) ``
        -AzdHttpsProxy ([string]`$payload.proxy_uri) ``
        -ProxyStatePath ([string]`$payload.state_path) ``
        -ProxyHost ``
        -ProxyHostSessionId ([string]`$payload.session_id) ``
        -ProxyStopSignalPath ([string]`$payload.stop_signal_path) ``
        -ProxyStartupResultPath ([string]`$payload.startup_result_path)
    exit 0
}
catch {
    Write-Error `$_
    exit 1
}
"@
    $encodedHostCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($hostCommand)
    )

    Write-Host 'Starting a persistent deploy-owned Foundry proxy host.'
    $hostProcess = Start-Process `
        -FilePath $pwshCommand.Source `
        -ArgumentList @(
            '-NoProfile'
            '-NonInteractive'
            '-EncodedCommand'
            $encodedHostCommand
        ) `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden `
        -PassThru

    try {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($watch.Elapsed.TotalSeconds -lt 120) {
            if (
                Test-Path -LiteralPath $startupResultPath -PathType Leaf
            ) {
                $startup = Read-FoundryProxyJson `
                    -Path $startupResultPath `
                    -Description 'Foundry proxy startup result'
                if ($startup.session_id -cne $sessionId) {
                    throw 'The proxy startup result has a different session ID.'
                }
                if ($startup.status -ceq 'failed') {
                    throw "Persistent proxy startup failed. $($startup.error)"
                }
                if ($startup.status -cne 'ready') {
                    throw 'The proxy startup result has an invalid status.'
                }

                $state = Read-FoundryProxyJson `
                    -Path $StatePath `
                    -Description 'Foundry proxy state'
                $state = Assert-FoundryProxyState `
                    -State $state `
                    -StatePath $StatePath
                if ($state.session_id -cne $sessionId) {
                    throw 'The proxy state has a different session ID.'
                }

                $verifiedHost = Get-FoundryProxyHostProcess -State $state
                if ($null -eq $verifiedHost) {
                    throw 'The persistent proxy host identity could not be verified.'
                }
                $verifiedHost.Dispose()
                Assert-LoopbackSocksProxy -Proxy $ProxyUri.AbsoluteUri

                Write-Host (
                    'The deploy-owned SSH SOCKS proxy will remain available ' +
                    'for invoke and collect commands.'
                )
                Write-Host (
                    'Run .\stop-foundry-proxy.ps1 to stop the owned tunnel.'
                )
                return $state
            }

            if ($hostProcess.HasExited) {
                throw (
                    'The persistent proxy host exited before becoming ready. ' +
                    "See $stderrPath."
                )
            }

            Start-Sleep -Milliseconds 200
        }

        throw (
            'Timed out waiting for the persistent proxy host. ' +
            "See $stderrPath."
        )
    }
    catch {
        try {
            Write-FoundryProxyJsonAtomically `
                -Path $stopSignalPath `
                -Value ([ordered]@{
                    schema_version = 1
                    session_id = $sessionId
                    requested_utc = [DateTimeOffset]::UtcNow.ToString(
                        'o',
                        [Globalization.CultureInfo]::InvariantCulture
                    )
                })
        }
        catch {
            Write-Warning (
                'Could not write the failed proxy startup stop signal. ' +
                $_.Exception.Message
            )
        }

        $stopWatch = [Diagnostics.Stopwatch]::StartNew()
        while (
            -not $hostProcess.HasExited -and
            $stopWatch.Elapsed.TotalSeconds -lt 5
        ) {
            Start-Sleep -Milliseconds 100
            $hostProcess.Refresh()
        }
        if (
            $hostProcess.HasExited -and
            (Test-Path -LiteralPath $stopSignalPath -PathType Leaf)
        ) {
            Remove-Item -LiteralPath $stopSignalPath -Force
        }

        throw
    }
    finally {
        $hostProcess.Dispose()
    }
}

function Invoke-Azd {
    param(
        [Parameter(Mandatory)]
        [string[]]$AzdArguments
    )

    & azd @AzdArguments
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $commandName = ($AzdArguments | Select-Object -First 3) -join ' '
        throw "azd $commandName failed with exit code $exitCode."
    }
}

function Invoke-AzdText {
    param(
        [Parameter(Mandatory)]
        [string[]]$AzdArguments
    )

    $output = & azd @AzdArguments
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $commandName = ($AzdArguments | Select-Object -First 3) -join ' '
        throw "azd $commandName failed with exit code $exitCode."
    }

    return ($output -join [Environment]::NewLine).Trim()
}

function Assert-CodeDeploymentConfiguration {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $configuration = Get-Content -LiteralPath $Path -Raw
    $escapedAgentName = [regex]::Escape($AgentName)
    $escapedRuntime = [regex]::Escape($Runtime)

    $requiredPatterns = [ordered]@{
        'agent service'         = "(?m)^[ \t]+$escapedAgentName\s*:\s*(?:#.*)?$"
        'hosted-agent host'     = '(?m)^\s*host\s*:\s*azure\.ai\.agent\s*(?:#.*)?$'
        'hosted-agent kind'     = '(?m)^\s*kind\s*:\s*hosted\s*(?:#.*)?$'
        'code configuration'    = '(?m)^\s*codeConfiguration\s*:\s*(?:#.*)?$'
        'selected runtime'      = "(?m)^\s*runtime\s*:\s*$escapedRuntime\s*(?:#.*)?$"
        'remote dependency build' = '(?m)^\s*dependencyResolution\s*:\s*remote_build\s*(?:#.*)?$'
        'invocations protocol'  = '(?m)^[ \t]*-\s*protocol\s*:\s*invocations\s*(?:#.*)?$'
    }

    foreach ($requirement in $requiredPatterns.GetEnumerator()) {
        if ($configuration -notmatch $requirement.Value) {
            throw "azure.yaml is missing the expected $($requirement.Key) configuration."
        }
    }

    $hasInlineEntryPoint =
        $configuration -match '(?m)^\s*entryPoint\s*:\s*server_host\.py\s*(?:#.*)?$'
    $hasListEntryPoint =
        $configuration -match '(?m)^\s*entryPoint\s*:\s*(?:#.*)?$' -and
        $configuration -match '(?m)^\s*-\s*server_host\.py\s*(?:#.*)?$'

    if (-not ($hasInlineEntryPoint -or $hasListEntryPoint)) {
        throw 'azure.yaml must use server_host.py as the code deployment entry point.'
    }

    $containerPatterns = @(
        '(?im)^\s*language\s*:\s*docker\s*(?:#.*)?$',
        '(?im)^\s*(?:image|docker|acrConnection|registryConnection)\s*:',
        '(?i)azurecr\.io',
        '(?i)AZURE_CONTAINER_REGISTRY'
    )

    foreach ($pattern in $containerPatterns) {
        if ($configuration -match $pattern) {
            throw 'Container or Azure Container Registry configuration was found. This script only allows source ZIP deployment.'
        }
    }
}

function Get-AzdEnvironmentValue {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    try {
        $value = Invoke-AzdText -AzdArguments @(
            'env', 'get-value', $Name,
            '--environment', $EnvironmentName,
            '--no-prompt'
        )
    }
    catch {
        throw "The azd environment '$EnvironmentName' is missing $Name. $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "The azd environment '$EnvironmentName' has an empty $Name value."
    }

    return $value.Trim().Trim('"')
}

function Get-ProjectEndpointFromAzureYaml {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $configuration = Get-Content -LiteralPath $Path -Raw
    $endpointMatch = [regex]::Match(
        $configuration,
        '(?m)^[ \t]+endpoint\s*:\s*[''"]?(?<endpoint>https://[^''"\s]+)[''"]?\s*(?:#.*)?$'
    )

    if (-not $endpointMatch.Success) {
        throw 'Could not resolve the Foundry project endpoint from azure.yaml.'
    }

    return $endpointMatch.Groups['endpoint'].Value.TrimEnd('/')
}

function Get-AgentJsonFromFoundryRest {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectEndpoint,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$TenantId,

        [AllowNull()]
        [string]$Proxy
    )

    $curlCommand = Get-Command curl.exe -CommandType Application `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $curlCommand) {
        throw 'curl.exe is required for the Foundry REST status fallback.'
    }

    $token = Invoke-AzdText -AzdArguments @(
        'auth', 'token',
        '--scope', 'https://ai.azure.com/.default',
        '--tenant-id', $TenantId,
        '--no-prompt'
    )

    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'azd returned an empty Foundry access token.'
    }

    $escapedName = [uri]::EscapeDataString($Name)
    $agentUrl = "$ProjectEndpoint/agents/$escapedName`?api-version=v1"
    $curlConfig = @(
        "url = `"$agentUrl`""
        "header = `"Authorization: Bearer $token`""
    )

    if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
        $curlProxy = $Proxy -replace '^socks5://', 'socks5h://'
        $curlConfig += "proxy = `"$curlProxy`""
    }

    $response = (
        ($curlConfig -join [Environment]::NewLine) |
            & $curlCommand.Source --config - --silent --show-error `
                --max-time 30 --write-out "`n__HTTP_STATUS__:%{http_code}"
    ) | Out-String
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "Foundry REST status request failed with curl exit code $exitCode."
    }

    $statusMarker = '__HTTP_STATUS__:'
    $markerIndex = $response.LastIndexOf($statusMarker)
    if ($markerIndex -lt 0) {
        throw 'Foundry REST status response did not include an HTTP status.'
    }

    $body = $response.Substring(0, $markerIndex).Trim()
    $httpStatus = $response.Substring(
        $markerIndex + $statusMarker.Length
    ).Trim()

    if ($httpStatus -notmatch '^2\d\d$') {
        throw "Foundry REST status request returned HTTP $httpStatus."
    }

    $null = $body | ConvertFrom-Json
    return $body
}

if ($ProxyHost) {
    foreach ($name in @(
        'FOUNDRY_AZD_TOKEN_BRIDGE_AI_JSON'
        'FOUNDRY_AZD_TOKEN_BRIDGE_ARM_JSON'
        'FOUNDRY_AZD_TOKEN_BRIDGE_REAL_PATH'
    )) {
        $environmentPath = "Env:$name"
        if (Test-Path -LiteralPath $environmentPath) {
            Remove-Item -LiteralPath $environmentPath
        }
    }

    foreach ($requiredValue in ([ordered]@{
        ProxyHostSessionId = $ProxyHostSessionId
        ProxyStopSignalPath = $ProxyStopSignalPath
        ProxyStartupResultPath = $ProxyStartupResultPath
    }).GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($requiredValue.Value)) {
            throw "$($requiredValue.Key) is required in proxy-host mode."
        }
    }

    if ([string]::IsNullOrWhiteSpace($AzdHttpsProxy)) {
        throw 'AzdHttpsProxy is required in proxy-host mode.'
    }

    $hostProxyUri = Resolve-LoopbackSocksProxyUri -Proxy $AzdHttpsProxy
    Invoke-PersistentProxyHost `
        -ProxyUri $hostProxyUri `
        -StatePath $ProxyStatePath `
        -SessionId $ProxyHostSessionId `
        -StopSignalPath $ProxyStopSignalPath `
        -StartupResultPath $ProxyStartupResultPath
    return
}

$azdCommand = Get-Command azd -CommandType Application `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $azdCommand) {
    throw 'Azure Developer CLI (azd) is required. Install azd and the microsoft.foundry extension before running this script.'
}

foreach ($requiredPath in @($entryPointPath, $requirementsPath, $agentIgnorePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required deployment file not found: $requiredPath"
    }
}

$projectIdMatch = [regex]::Match(
    $ProjectId,
    '(?i)^/subscriptions/(?<subscription>[^/]+)/.+/projects/[^/]+/?$'
)

if (-not $projectIdMatch.Success) {
    throw 'ProjectId must be the full ARM resource ID of an existing Microsoft Foundry project.'
}

$normalizedProjectId = $ProjectId.TrimEnd('/')
$expectedSubscriptionId = $projectIdMatch.Groups['subscription'].Value
$usesAzureCliAuth = Test-AzdUsesAzureCliAuth -AzdPath $azdCommand.Source
$azCommand = $null
if ($usesAzureCliAuth) {
    $azCommand = Get-Command az -CommandType Application `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $azCommand) {
        throw 'Azure CLI (az) is required because azd delegates authentication to it.'
    }

    $targetAzureContext = Get-AzureCliAccountContext `
        -AzPath $azCommand.Source `
        -SubscriptionId $expectedSubscriptionId
    $AzureTenantId = Resolve-AzureTargetGuid `
        -ConfiguredValue $AzureTenantId `
        -EnvironmentVariable 'FOUNDRY_AZURE_TENANT_ID' `
        -AzdEnvironmentKey 'AZURE_TENANT_ID' `
        -AzdPath $azdCommand.Source `
        -EnvironmentName $EnvironmentName `
        -RepoRoot $repoRoot `
        -FallbackValue $(if ($targetAzureContext) {
            $targetAzureContext.tenant_id
        })
    $AzureSubscriptionId = Resolve-AzureTargetGuid `
        -ConfiguredValue $AzureSubscriptionId `
        -EnvironmentVariable 'FOUNDRY_AZURE_SUBSCRIPTION_ID' `
        -AzdEnvironmentKey 'AZURE_SUBSCRIPTION_ID' `
        -AzdPath $azdCommand.Source `
        -EnvironmentName $EnvironmentName `
        -RepoRoot $repoRoot `
        -FallbackValue $expectedSubscriptionId

    if ($AzureSubscriptionId -ine $expectedSubscriptionId) {
        throw 'The configured Azure subscription does not match FOUNDRY_PROJECT_ID.'
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
$locationPushed = $false
$primaryFailure = $null

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
    }

    if (-not [string]::IsNullOrWhiteSpace($AzdHttpsProxy)) {
        $proxyUri = Resolve-LoopbackSocksProxyUri -Proxy $AzdHttpsProxy

        if (
            -not (
                Test-TcpListener `
                    -HostName $proxyUri.Host `
                    -Port $proxyUri.Port
            )
        ) {
            $null = Start-PersistentBastionSocksProxy `
                -ProxyUri $proxyUri `
                -StatePath $ProxyStatePath
        }
        else {
            Write-Host "Reusing the SSH SOCKS proxy at $AzdHttpsProxy."
        }

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

    if ($usesAzureCliAuth) {
        $azdTokenBridgeState = Enable-AzdExtensionTokenBridge `
            -AzPath $azCommand.Source `
            -AzdPath $azdCommand.Source `
            -SubscriptionId $AzureSubscriptionId `
            -Scopes @(
                'https://management.azure.com/.default'
                'https://ai.azure.com/.default'
            )
        if ($null -eq $azdTokenBridgeState) {
            Initialize-AzdAccessToken `
                -AzdPath $azdCommand.Source `
                -TenantId $AzureTenantId `
                -Scope 'https://ai.azure.com/.default'
        }
    }

    Push-Location $repoRoot
    $locationPushed = $true

    Invoke-Azd -AzdArguments @('ai', 'agent', 'version')

    if (-not (Test-Path -LiteralPath $azureYamlPath -PathType Leaf)) {
        Invoke-Azd -AzdArguments @(
            'ai', 'agent', 'init',
            '--no-prompt',
            '--project-id', $normalizedProjectId,
            '--kind', 'hosted',
            '--agent-name', $AgentName,
            '--src', $repoRoot,
            '--deploy-mode', 'code',
            '--runtime', $Runtime,
            '--entry-point', 'server_host.py',
            '--dep-resolution', 'remote_build',
            '--protocol', 'invocations',
            '--environment', $EnvironmentName
        )
    }
    else {
        try {
            Invoke-Azd -AzdArguments @(
                'env', 'select', $EnvironmentName,
                '--no-prompt'
            )
        }
        catch {
            throw "azure.yaml already exists, but azd environment '$EnvironmentName' could not be selected. Refusing to overwrite or retarget the existing configuration."
        }
    }

    Assert-CodeDeploymentConfiguration -Path $azureYamlPath

    $configuredProjectId = Get-AzdEnvironmentValue -Name 'AZURE_AI_PROJECT_ID'
    if ($configuredProjectId.TrimEnd('/') -ine $normalizedProjectId) {
        throw "Environment '$EnvironmentName' targets a different Foundry project. Refusing to deploy."
    }

    $configuredSubscriptionId = Get-AzdEnvironmentValue -Name 'AZURE_SUBSCRIPTION_ID'
    if ($configuredSubscriptionId -ine $expectedSubscriptionId) {
        throw "Environment '$EnvironmentName' targets a different Azure subscription. Refusing to deploy."
    }

    $tenantId = Get-AzdEnvironmentValue -Name 'AZURE_TENANT_ID'

    $projectJson = Invoke-AzdText -AzdArguments @(
        'ai', 'project', 'show',
        '--output', 'json',
        '--environment', $EnvironmentName,
        '--no-prompt'
    )
    $null = $projectJson | ConvertFrom-Json

    if (-not $VerifyOnly) {
        $deployArguments = @(
            'deploy', $AgentName,
            '--environment', $EnvironmentName,
            '--no-prompt'
        )

        if ($Preview) {
            $deployArguments += '--preview'
        }
        else {
            $deployArguments += @('--timeout', $TimeoutSeconds.ToString())
        }

        Invoke-Azd -AzdArguments $deployArguments

        if ($Preview) {
            Write-Host 'Deployment preview completed. No package was uploaded.'
            return
        }
    }
    else {
        Write-Host 'Skipping deployment and verifying the existing agent.'
    }

    try {
        $agentJson = Invoke-AzdText -AzdArguments @(
            'ai', 'agent', 'show', $AgentName,
            '--output', 'json',
            '--environment', $EnvironmentName,
            '--no-prompt'
        )
    }
    catch {
        Write-Warning (
            'azd ai agent show failed after deployment; ' +
            'verifying the existing agent through the Foundry REST API.'
        )
        $projectEndpoint = Get-ProjectEndpointFromAzureYaml `
            -Path $azureYamlPath
        $agentJson = Get-AgentJsonFromFoundryRest `
            -ProjectEndpoint $projectEndpoint `
            -Name $AgentName `
            -TenantId $tenantId `
            -Proxy $AzdHttpsProxy
    }

    $null = $agentJson | ConvertFrom-Json

    if ($agentJson -notmatch '(?i)"status"\s*:\s*"(?:active|deployed)"') {
        throw 'The deployment command completed, but the agent did not report an active or deployed status.'
    }

    Write-Host "Agent '$AgentName' is active in azd environment '$EnvironmentName'."
    Write-Output $agentJson
}
catch {
    $primaryFailure = $_
    throw
}
finally {
    $cleanupFailures = [Collections.Generic.List[string]]::new()

    if ($locationPushed) {
        try {
            Pop-Location
        }
        catch {
            $cleanupFailures.Add(
                "Could not restore the working directory: $($_.Exception.Message)"
            )
        }
    }

    if ($null -ne $azureAuthState) {
        try {
            Restore-AzureCliAuthentication `
                -AzPath $azCommand.Source `
                -State $azureAuthState
        }
        catch {
            $cleanupFailures.Add(
                "Could not restore Azure CLI context: $($_.Exception.Message)"
            )
        }
    }

    try {
        Restore-AzdExtensionTokenBridge -State $azdTokenBridgeState
    }
    catch {
        $cleanupFailures.Add(
            "Could not restore azd token bridge environment: " +
            $_.Exception.Message
        )
    }

    foreach ($environmentVariable in @(
        [pscustomobject]@{
            Name = 'HTTPS_PROXY'
            Value = $previousHttpsProxy
        }
        [pscustomobject]@{
            Name = 'NO_PROXY'
            Value = $previousNoProxy
        }
    )) {
        try {
            Restore-ProcessEnvironmentVariable `
                -Name $environmentVariable.Name `
                -Value $environmentVariable.Value
        }
        catch {
            $cleanupFailures.Add(
                "Could not restore $($environmentVariable.Name): " +
                $_.Exception.Message
            )
        }
    }

    if ($cleanupFailures.Count -gt 0) {
        $cleanupMessage = (
            'CLOSURE_UNKNOWN: ' +
            ($cleanupFailures -join ' ')
        )

        if ($null -ne $primaryFailure) {
            Write-Warning $cleanupMessage
        }
        else {
            throw $cleanupMessage
        }
    }
}
