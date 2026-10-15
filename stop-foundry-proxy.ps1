#Requires -Version 7.2

[CmdletBinding()]
param(
    [AllowNull()]
    [string]$StatePath,

    [ValidateRange(5, 120)]
    [int]$TimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSCommandPath
. (Join-Path $repoRoot 'foundry-proxy-control.ps1')

if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Join-Path $repoRoot 'run-logs\proxy\state.json'
}
$StatePath = [IO.Path]::GetFullPath($StatePath)

if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
    Write-Host 'No deploy-owned Foundry proxy is running.'
    return
}

$state = Read-FoundryProxyJson `
    -Path $StatePath `
    -Description 'Foundry proxy state'
$state = Assert-FoundryProxyState `
    -State $state `
    -StatePath $StatePath
$hostProcess = Get-FoundryProxyHostProcess -State $state

$socksListener = Get-FoundryProxyListener -Port ([int]$state.socks_port)
$tunnelListener = Get-FoundryProxyListener -Port ([int]$state.tunnel_port)

if ($null -eq $hostProcess) {
    if ($null -ne $socksListener -or $null -ne $tunnelListener) {
        throw (
            'The recorded proxy host is not running, but one or more ' +
            'recorded ports still have listeners. Refusing an unowned stop.'
        )
    }

    Remove-Item -LiteralPath $StatePath -Force
    if (
        Test-Path -LiteralPath $state.stop_signal_path -PathType Leaf
    ) {
        Remove-Item -LiteralPath $state.stop_signal_path -Force
    }
    Write-Host 'Removed stale Foundry proxy state; no tunnel was running.'
    return
}

try {
    if (
        $null -eq $socksListener -or
        $socksListener.LocalAddress -cne '127.0.0.1' -or
        $socksListener.OwningProcess -ne [int]$state.socks_listener_pid
    ) {
        throw 'The SOCKS listener no longer matches the recorded owner.'
    }
    if (
        $null -eq $tunnelListener -or
        $tunnelListener.LocalAddress -cne '127.0.0.1' -or
        $tunnelListener.OwningProcess -ne [int]$state.tunnel_listener_pid
    ) {
        throw 'The Bastion listener no longer matches the recorded owner.'
    }

    Write-FoundryProxyJsonAtomically `
        -Path $state.stop_signal_path `
        -Value ([ordered]@{
            schema_version = 1
            session_id = $state.session_id
            requested_utc = [DateTimeOffset]::UtcNow.ToString(
                'o',
                [Globalization.CultureInfo]::InvariantCulture
            )
        })

    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $currentHost = Get-FoundryProxyHostProcess -State $state
        if ($null -eq $currentHost) {
            break
        }

        $currentHost.Dispose()
        Start-Sleep -Milliseconds 200
    }

    $currentHost = Get-FoundryProxyHostProcess -State $state
    if ($null -ne $currentHost) {
        $currentHost.Dispose()
        throw (
            'Timed out waiting for the deploy-owned proxy host to stop. ' +
            'No process was forcibly terminated.'
        )
    }

    foreach ($port in @(
        [int]$state.socks_port
        [int]$state.tunnel_port
    )) {
        if ($null -ne (Get-FoundryProxyListener -Port $port)) {
            throw "A listener remains on local port $port."
        }
    }

    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        throw 'The proxy host exited without removing its owned state.'
    }

    Write-Host 'Stopped the deploy-owned SSH SOCKS proxy and Azure Bastion tunnel.'
}
finally {
    $hostProcess.Dispose()
}
