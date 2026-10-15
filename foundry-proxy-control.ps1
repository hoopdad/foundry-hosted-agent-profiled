function Write-FoundryProxyJsonAtomically {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$Value
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    $null = New-Item -ItemType Directory -Path $directory -Force
    $temporaryPath = Join-Path $directory (
        '.{0}.{1}.tmp' -f
            [IO.Path]::GetFileName($fullPath),
            [guid]::NewGuid().ToString('N')
    )

    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            (($Value | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporaryPath -Destination $fullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Read-FoundryProxyJson {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    try {
        $text = [IO.File]::ReadAllText([IO.Path]::GetFullPath($Path))
        return $text | ConvertFrom-Json
    }
    catch {
        throw "$Description is unreadable or invalid. $($_.Exception.Message)"
    }
}

function Assert-FoundryProxyState {
    param(
        [Parameter(Mandatory)]
        [object]$State,

        [Parameter(Mandatory)]
        [string]$StatePath
    )

    $requiredProperties = @(
        'schema_version'
        'status'
        'session_id'
        'host_process_id'
        'host_process_start_utc'
        'host_executable_path'
        'proxy_uri'
        'socks_port'
        'socks_listener_pid'
        'tunnel_port'
        'tunnel_listener_pid'
        'stop_signal_path'
        'started_utc'
    )
    foreach ($property in $requiredProperties) {
        if ($property -notin $State.PSObject.Properties.Name) {
            throw "Proxy state is missing $property."
        }
    }

    if ($State.schema_version -ne 1 -or $State.status -cne 'running') {
        throw 'Proxy state has an unsupported schema or status.'
    }

    $sessionId = [guid]::Empty
    if (-not [guid]::TryParse($State.session_id, [ref]$sessionId)) {
        throw 'Proxy state contains an invalid session ID.'
    }

    foreach ($property in @(
        'host_process_id'
        'socks_port'
        'socks_listener_pid'
        'tunnel_port'
        'tunnel_listener_pid'
    )) {
        $value = 0
        if (
            -not [int]::TryParse(
                $State.$property.ToString(),
                [ref]$value
            ) -or
            $value -le 0
        ) {
            throw "Proxy state contains an invalid $property."
        }
    }

    $proxyUri = $null
    if (
        -not [uri]::TryCreate(
            $State.proxy_uri,
            [UriKind]::Absolute,
            [ref]$proxyUri
        ) -or
        $proxyUri.Scheme -ine 'socks5' -or
        $proxyUri.Host -notin @('127.0.0.1', 'localhost') -or
        $proxyUri.Port -ne [int]$State.socks_port
    ) {
        throw 'Proxy state contains an invalid loopback SOCKS URI.'
    }

    $hostStart = [DateTimeOffset]::MinValue
    $started = [DateTimeOffset]::MinValue
    if (
        -not [DateTimeOffset]::TryParse(
            $State.host_process_start_utc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$hostStart
        ) -or
        -not [DateTimeOffset]::TryParse(
            $State.started_utc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$started
        )
    ) {
        throw 'Proxy state contains an invalid timestamp.'
    }

    $stateDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($StatePath))
    $stopSignalPath = [IO.Path]::GetFullPath($State.stop_signal_path)
    if (
        (Split-Path -Parent $stopSignalPath) -ine $stateDirectory -or
        [IO.Path]::GetFileName($stopSignalPath) -ine
            "stop-$($sessionId.ToString('N')).json"
    ) {
        throw 'Proxy state contains an invalid stop-signal path.'
    }

    $hostExecutablePath = [IO.Path]::GetFullPath(
        $State.host_executable_path
    )
    if (
        -not (Test-Path -LiteralPath $hostExecutablePath -PathType Leaf)
    ) {
        throw 'Proxy state references a missing host executable.'
    }

    return $State
}

function Get-FoundryProxyHostProcess {
    param(
        [Parameter(Mandatory)]
        [object]$State
    )

    $process = Get-Process -Id ([int]$State.host_process_id) `
        -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return $null
    }

    try {
        $expectedStart = [DateTimeOffset]::Parse(
            $State.host_process_start_utc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
        $actualStart = [DateTimeOffset]$process.StartTime.ToUniversalTime()
        $startDelta = [Math]::Abs(
            ($actualStart - $expectedStart.ToUniversalTime()).TotalSeconds
        )
        if ($startDelta -gt 2) {
            $process.Dispose()
            return $null
        }

        if (
            [IO.Path]::GetFullPath($process.Path) -ine
            [IO.Path]::GetFullPath($State.host_executable_path)
        ) {
            $process.Dispose()
            return $null
        }

        return $process
    }
    catch {
        $process.Dispose()
        return $null
    }
}

function Get-FoundryProxyListener {
    param(
        [Parameter(Mandatory)]
        [int]$Port
    )

    $listeners = @(
        Get-NetTCPConnection -State Listen -LocalPort $Port `
            -ErrorAction SilentlyContinue
    )
    if ($listeners.Count -eq 0) {
        return $null
    }

    if ($listeners.Count -ne 1) {
        throw "Expected exactly one listener on local port $Port."
    }

    return $listeners[0]
}
