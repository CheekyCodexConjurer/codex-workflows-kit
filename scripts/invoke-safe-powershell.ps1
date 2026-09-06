<#
.SYNOPSIS
    Executes PowerShell scripts deterministically and safely, eliminating malformed
    nested -Command string bugs, disappearing variables, quote corruption, and interactive stdin hangs.

.DESCRIPTION
    invoke-safe-powershell provides a secure, deterministic wrapper for executing .ps1 scripts:
    - -File based invocation exclusively (never string-built -Command, never Invoke-Expression).
    - Preserves literal arguments verbatim (dollar signs, double/single quotes, spaces, unicode) via
      JSON environment transport, direct array passing, or -ArgsJson structured input.
    - Forces -NoProfile and -NonInteractive flags.
    - Sets CreateNoWindow = $true for headless automation.
    - Closes child process standard input immediately, preventing interactive prompt hangs (Read-Host
      fails fast non-zero, [Console]::ReadLine() returns EOF/null immediately, missing mandatory parameters fail fast).
    - Sets child ErrorActionPreference = 'Stop' so terminating and non-terminating errors (Write-Error, cmdlet errors)
      halt execution immediately without continuing side effects.
    - Captures final native exit code ($LASTEXITCODE). Early native failures followed by later successes
      are not auto-halted by PowerShell; caller/script must check $LASTEXITCODE after native commands if required.
    - Streams stdout and stderr concurrently in real-time while the child process runs (no buffering until exit,
      preventing progress starvation and false stalls).
    - Retains captures only when -PassThru is explicitly requested, subject to a bounded buffer limit to prevent
      unbounded silent memory buffering; never duplicates output.
    - Validates script path and leaf existence, enforcing .ps1 extension and neutral caller authority (no elevation).
    - No default job execution timeout or forced kill on healthy jobs; healthy jobs run to completion under caller authority.
    - Compatible with both PowerShell 7 (pwsh) and Windows PowerShell 5.1 (powershell.exe).
#>

[CmdletBinding(DefaultParameterSetName = 'Launcher')]
param(
    [Parameter(Mandatory = $false, Position = 0, ParameterSetName = 'Launcher')]
    [Alias('FilePath', 'File', 'Path')]
    [string]$ScriptPath,

    [Parameter(Mandatory = $false, Position = 1, ValueFromRemainingArguments = $true, ParameterSetName = 'Launcher')]
    [Alias('Args', 'Arguments')]
    [object[]]$ArgumentList = @(),

    [Parameter(Mandatory = $false, ParameterSetName = 'Launcher')]
    [string]$ArgsJson = '',

    [Parameter(Mandatory = $false, ParameterSetName = 'Launcher')]
    [Alias('ParamsJson', 'NamedParametersJson', 'NamedArgsJson')]
    [string]$ParametersJson = '',

    [Parameter(Mandatory = $false, ParameterSetName = 'Launcher')]
    [Alias('Params', 'NamedParameters')]
    [object]$Parameters = $null,

    [Parameter(Mandatory = $false, ParameterSetName = 'Launcher')]
    [string]$WorkingDirectory = '',

    [Parameter(Mandatory = $false, ParameterSetName = 'Launcher')]
    [string]$PowerShellExe = '',

    [Parameter(Mandatory = $false, ParameterSetName = 'Launcher')]
    [switch]$PassThru,

    # Internal runner mode executed inside the child PowerShell process
    [Parameter(Mandatory = $false, ParameterSetName = 'InternalRunner')]
    [switch]$InternalRunner
)

Set-StrictMode -Version Latest

function Convert-Json-Internal([string]$json) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return ,(ConvertFrom-Json -InputObject $json -NoEnumerate -ErrorAction Stop)
    } else {
        return ,(ConvertFrom-Json -InputObject $json -ErrorAction Stop)
    }
}

function Validate-And-Parse-ArgsJson([string]$json) {
    if ([string]::IsNullOrWhiteSpace($json)) { return ,@() }
    $trimmed = $json.Trim()
    if ($trimmed -eq '[]') { return ,@() }
    if (-not ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
        throw "Invalid -ArgsJson: Expected a JSON array, got non-array JSON."
    }
    $raw = $null
    try {
        $raw = Convert-Json-Internal $json
    } catch {
        if ($json.Contains('\"')) {
            $cleaned = $json.Replace('\"', '"')
            try {
                $raw = Convert-Json-Internal $cleaned
            } catch {
                throw "Invalid -ArgsJson: JSON parsing failed: $($_.Exception.Message)"
            }
        } else {
            throw "Invalid -ArgsJson: JSON parsing failed: $($_.Exception.Message)"
        }
    }
    if ($null -eq $raw) {
        throw "Invalid -ArgsJson: Expected a JSON array, got null."
    }
    if (-not ($raw -is [System.Array])) {
        throw "Invalid -ArgsJson: Expected a JSON array, got $($raw.GetType().FullName)."
    }
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($item in $raw) {
        if ($null -eq $item) {
            throw "Invalid -ArgsJson: Array elements cannot be null."
        }
        if ($item -is [System.Array] -or $item -is [System.Collections.IDictionary] -or $item -is [System.Management.Automation.PSCustomObject]) {
            throw "Invalid -ArgsJson: Nested containers are not supported as positional arguments."
        }
        $list.Add([string]$item)
    }
    $arr = $list.ToArray()
    return ,$arr
}

function Deserialize-ArgsJson([string]$json) {
    return (Validate-And-Parse-ArgsJson $json)
}

function Validate-And-Normalize-Parameters($params) {
    $result = @{}
    if ($null -eq $params) { return $result }

    $entries = @()
    if ($params -is [System.Management.Automation.PSCustomObject]) {
        $entries = $params.PSObject.Properties
    } elseif ($params -is [System.Collections.IDictionary]) {
        $entries = $params.GetEnumerator()
    } else {
        throw "Invalid -Parameters: Expected a hashtable/dictionary or PSCustomObject, got $($params.GetType().FullName)."
    }

    foreach ($entry in $entries) {
        $key = if ($entry -is [System.Management.Automation.PSPropertyInfo]) { $entry.Name } else { $entry.Key }
        $val = if ($entry -is [System.Management.Automation.PSPropertyInfo]) { $entry.Value } else { $entry.Value }

        # Validate Key
        if ($null -eq $key) {
            throw "Invalid parameter key: Parameter name cannot be null."
        }
        $keyStr = ([string]$key).Trim()
        if ([string]::IsNullOrWhiteSpace($keyStr)) {
            throw "Invalid parameter key: Parameter name cannot be empty or whitespace."
        }
        $cleanKey = if ($keyStr.StartsWith('-')) { $keyStr.Substring(1) } else { $keyStr }
        if ($cleanKey -notmatch '^[a-zA-Z_][a-zA-Z0-9_]*$') {
            throw "Invalid parameter key '$keyStr': Parameter name must match '^[a-zA-Z_][a-zA-Z0-9_]*$'."
        }
        if ($result.ContainsKey($cleanKey)) {
            throw "Duplicate parameter key '$cleanKey' detected."
        }

        # Validate Value
        if ($null -eq $val) {
            throw "Invalid parameter value for '$cleanKey': Null values are not supported."
        }

        # Check supported types: string, bool, numeric
        if ($val -is [string]) {
            $result[$cleanKey] = [string]$val
        } elseif ($val -is [bool]) {
            $result[$cleanKey] = [bool]$val
        } elseif ($val -is [int] -or $val -is [long] -or $val -is [double] -or $val -is [decimal] -or $val -is [int16] -or $val -is [byte] -or $val -is [float] -or $val -is [uint32] -or $val -is [uint64]) {
            $result[$cleanKey] = $val
        } else {
            throw "Invalid parameter value for '$cleanKey': Type '$($val.GetType().FullName)' is not supported. Supported types are string, boolean (switch), and numeric."
        }
    }
    return $result
}

function Validate-And-Parse-ParametersJson([string]$json) {
    if ([string]::IsNullOrWhiteSpace($json)) { return @{} }
    $trimmed = $json.Trim()
    if ($trimmed -eq '{}') { return @{} }
    if (-not ($trimmed.StartsWith('{') -and $trimmed.EndsWith('}'))) {
        throw "Invalid -ParametersJson: Expected a JSON object, got non-object JSON."
    }
    $raw = $null
    try {
        $raw = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    } catch {
        if ($json.Contains('\"')) {
            $cleaned = $json.Replace('\"', '"')
            try {
                $raw = ConvertFrom-Json -InputObject $cleaned -ErrorAction Stop
            } catch {
                throw "Invalid -ParametersJson: JSON parsing failed: $($_.Exception.Message)"
            }
        } else {
            throw "Invalid -ParametersJson: JSON parsing failed: $($_.Exception.Message)"
        }
    }
    if ($null -eq $raw) {
        throw "Invalid -ParametersJson: Expected a JSON object, got null."
    }
    if ($raw -is [System.Array]) {
        throw "Invalid -ParametersJson: Expected a JSON object, got an array."
    }
    if (-not ($raw -is [System.Management.Automation.PSCustomObject])) {
        throw "Invalid -ParametersJson: Expected a JSON object, got $($raw.GetType().FullName)."
    }
    return (Validate-And-Normalize-Parameters $raw)
}

# ==============================================================================
# Internal Runner Mode (Child Process)
# ==============================================================================
if ($InternalRunner) {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $ErrorActionPreference = 'Stop'

    $target = $env:__SAFE_PS_TARGET
    $targetArgs = @()
    if ($env:__SAFE_PS_ARGS_JSON) {
        try {
            $parsed = Validate-And-Parse-ArgsJson $env:__SAFE_PS_ARGS_JSON
            if ($null -ne $parsed) {
                $targetArgs = @($parsed)
            } else {
                $targetArgs = @()
            }
        } catch {
            [Console]::Error.WriteLine("invoke-safe-powershell runner: $($_.Exception.Message)")
            exit 1
        }
    }

    $targetParams = @{}
    if ($env:__SAFE_PS_PARAMS_JSON) {
        try {
            $parsedP = Validate-And-Parse-ParametersJson $env:__SAFE_PS_PARAMS_JSON
            if ($null -ne $parsedP) {
                $targetParams = $parsedP
            } else {
                $targetParams = @{}
            }
        } catch {
            [Console]::Error.WriteLine("invoke-safe-powershell runner: $($_.Exception.Message)")
            exit 1
        }
    }

    if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path -LiteralPath $target -PathType Leaf)) {
        [Console]::Error.WriteLine("invoke-safe-powershell runner: Target script missing or invalid: '$target'")
        exit 1
    }

    $hasStreamError = $false
    # Reset LASTEXITCODE in global and local scopes to null so explicit script
    # exit codes (e.g. exit 0 or exit 7) and native commands are cleanly observable
    # without polluting $global:Error
    $global:LASTEXITCODE = $null
    $LASTEXITCODE = $null
    $priorErrorCount = $global:Error.Count

    try {
        if ($targetParams.Count -gt 0 -and $targetArgs.Count -gt 0) {
            & $target @targetParams @targetArgs
        } elseif ($targetParams.Count -gt 0) {
            & $target @targetParams
        } elseif ($targetArgs.Count -gt 0) {
            & $target @targetArgs
        } else {
            & $target
        }
    }
    catch {
        $hasStreamError = $true
        [Console]::Error.WriteLine($_)
    }

    $lastExit = if ($null -ne $global:LASTEXITCODE) { [int]$global:LASTEXITCODE } elseif ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { $null }

    # 1. Unhandled terminating exceptions must never be masked
    if ($hasStreamError) {
        if ($null -ne $lastExit -and $lastExit -ne 0) {
            exit $lastExit
        }
        exit 1
    }

    # 2. Explicit non-zero exit or native executable failure
    if ($null -ne $lastExit -and $lastExit -ne 0) {
        exit $lastExit
    }

    # 3. Explicit successful exit (exit 0) takes precedence over historical caught/polluted errors
    if ($null -ne $lastExit -and $lastExit -eq 0) {
        exit 0
    }

    # 4. No explicit exit called: check for unhandled non-terminating errors (e.g. Write-Error with Continue)
    if ($global:Error.Count -gt $priorErrorCount) {
        exit 1
    }

    # 5. Clean execution with no errors
    exit 0
}

# ==============================================================================
# Launcher Mode (Validates Input & Launches Isolated Safe Process)
# ==============================================================================

function Fail-Launcher([string]$message, [int]$code = 1) {
    [Console]::Error.WriteLine($message)
    $global:LASTEXITCODE = $code
    if ($PassThru) {
        return [PSCustomObject]@{
            ExitCode = $code
            StdOut   = ''
            StdErr   = $message
            Success  = ($code -eq 0)
        }
    }
    exit $code
}

# Fast validation of mandatory parameter
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $r = Fail-Launcher "invoke-safe-powershell: Missing mandatory parameter '-ScriptPath'." 1
    if ($PassThru) { return $r }
}

$loc = (Get-Location).Path
$resolvedScript = if ([System.IO.Path]::IsPathRooted($ScriptPath)) {
    [System.IO.Path]::GetFullPath($ScriptPath)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $loc $ScriptPath))
}

if (-not (Test-Path -LiteralPath $resolvedScript -PathType Leaf)) {
    $r = Fail-Launcher "invoke-safe-powershell: Script not found or not a leaf file: '$ScriptPath'" 1
    if ($PassThru) { return $r }
}

$ext = [System.IO.Path]::GetExtension($resolvedScript).ToLowerInvariant()
if ($ext -ne '.ps1') {
    $r = Fail-Launcher "invoke-safe-powershell: Target script must be a '.ps1' file: '$ScriptPath'" 1
    if ($PassThru) { return $r }
}

# Resolve PowerShell executable (neutral authority, current process default)
$targetPwsh = if ($PowerShellExe) {
    if (Test-Path -LiteralPath $PowerShellExe -PathType Leaf) {
        [System.IO.Path]::GetFullPath($PowerShellExe)
    } else {
        $cmd = Get-Command -Name $PowerShellExe -ErrorAction SilentlyContinue
        if ($cmd) { $cmd.Source } else { $PowerShellExe }
    }
} else {
    (Get-Process -Id $PID).Path
}

$thisScript = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($thisScript)) {
    $thisScript = $MyInvocation.MyCommand.Definition
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $targetPwsh
$psi.Arguments = "-NoProfile -NonInteractive -File `"$thisScript`" -InternalRunner"

if ($WorkingDirectory) {
    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        $r = Fail-Launcher "invoke-safe-powershell: Working directory not found: '$WorkingDirectory'" 1
        if ($PassThru) { return $r }
    }
    $psi.WorkingDirectory = [System.IO.Path]::GetFullPath($WorkingDirectory)
} else {
    $psi.WorkingDirectory = $loc
}

# Strict validation of Arguments and Parameters BEFORE process launch
$effectiveArgs = @()
if (-not [string]::IsNullOrWhiteSpace($ArgsJson)) {
    if ($null -ne $ArgumentList -and $ArgumentList.Count -gt 0) {
        $r = Fail-Launcher "invoke-safe-powershell: Cannot specify both -ArgsJson and positional arguments (-ArgumentList)." 1
        if ($PassThru) { return $r }
    }
    try {
        $parsed = Validate-And-Parse-ArgsJson $ArgsJson
        if ($null -ne $parsed) {
            $effectiveArgs = @($parsed)
        } else {
            $effectiveArgs = @()
        }
    } catch {
        $r = Fail-Launcher "invoke-safe-powershell: $($_.Exception.Message)" 1
        if ($PassThru) { return $r }
    }
} elseif ($null -ne $ArgumentList -and $ArgumentList.Count -gt 0) {
    foreach ($arg in $ArgumentList) {
        if ($null -eq $arg) {
            $r = Fail-Launcher "invoke-safe-powershell: Positional argument cannot be null." 1
            if ($PassThru) { return $r }
        }
    }
    $effectiveArgs = $ArgumentList
}

$effectiveParams = @{}
if (-not [string]::IsNullOrWhiteSpace($ParametersJson) -and $null -ne $Parameters) {
    $r = Fail-Launcher "invoke-safe-powershell: Cannot specify both -Parameters and -ParametersJson." 1
    if ($PassThru) { return $r }
}

if (-not [string]::IsNullOrWhiteSpace($ParametersJson)) {
    try {
        $effectiveParams = Validate-And-Parse-ParametersJson $ParametersJson
    } catch {
        $r = Fail-Launcher "invoke-safe-powershell: $($_.Exception.Message)" 1
        if ($PassThru) { return $r }
    }
} elseif ($null -ne $Parameters) {
    try {
        $effectiveParams = Validate-And-Normalize-Parameters $Parameters
    } catch {
        $r = Fail-Launcher "invoke-safe-powershell: $($_.Exception.Message)" 1
        if ($PassThru) { return $r }
    }
}

# Environment payload preserves arguments, parameters, and target path verbatim
$psi.EnvironmentVariables['__SAFE_PS_TARGET'] = $resolvedScript
$psi.EnvironmentVariables['__SAFE_PS_ARGS_JSON'] = ConvertTo-Json -InputObject @($effectiveArgs) -Compress
$psi.EnvironmentVariables['__SAFE_PS_PARAMS_JSON'] = ConvertTo-Json -InputObject $effectiveParams -Compress
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.RedirectStandardInput = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true

$process = [System.Diagnostics.Process]::Start($psi)

# Crucial: Close child standard input immediately to guarantee no interactive hangs
$process.StandardInput.Close()

$maxCaptureChars = 10485760 # Bounded capture buffer (10MB) for -PassThru to prevent unbounded silent buffering
$capturedOutBuilder = if ($PassThru) { New-Object System.Text.StringBuilder } else { $null }
$capturedErrBuilder = if ($PassThru) { New-Object System.Text.StringBuilder } else { $null }

$outReader = $process.StandardOutput
$errReader = $process.StandardError
$outBuf = New-Object char[] 4096
$errBuf = New-Object char[] 4096

$outTask = $outReader.ReadAsync($outBuf, 0, $outBuf.Length)
$errTask = $errReader.ReadAsync($errBuf, 0, $errBuf.Length)

$outOpen = $true
$errOpen = $true

while ($outOpen -or $errOpen) {
    $activeTasks = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
    if ($outOpen) { $activeTasks.Add($outTask) }
    if ($errOpen) { $activeTasks.Add($errTask) }

    $idx = [System.Threading.Tasks.Task]::WaitAny($activeTasks.ToArray())
    $completedTask = $activeTasks[$idx]

    if ($outOpen -and ($completedTask -eq $outTask)) {
        $readCount = $outTask.Result
        if ($readCount -gt 0) {
            [Console]::Out.Write($outBuf, 0, $readCount)
            if ($PassThru -and $capturedOutBuilder.Length -lt $maxCaptureChars) {
                $appendCount = [Math]::Min($readCount, $maxCaptureChars - $capturedOutBuilder.Length)
                $capturedOutBuilder.Append($outBuf, 0, $appendCount) | Out-Null
            }
            $outTask = $outReader.ReadAsync($outBuf, 0, $outBuf.Length)
        } else {
            $outOpen = $false
        }
    }
    elseif ($errOpen -and ($completedTask -eq $errTask)) {
        $readCount = $errTask.Result
        if ($readCount -gt 0) {
            [Console]::Error.Write($errBuf, 0, $readCount)
            if ($PassThru -and $capturedErrBuilder.Length -lt $maxCaptureChars) {
                $appendCount = [Math]::Min($readCount, $maxCaptureChars - $capturedErrBuilder.Length)
                $capturedErrBuilder.Append($errBuf, 0, $appendCount) | Out-Null
            }
            $errTask = $errReader.ReadAsync($errBuf, 0, $errBuf.Length)
        } else {
            $errOpen = $false
        }
    }
}

$process.WaitForExit()

$exitCode = $process.ExitCode
$global:LASTEXITCODE = $exitCode

if ($PassThru) {
    return [PSCustomObject]@{
        ExitCode = $exitCode
        StdOut   = if ($capturedOutBuilder) { $capturedOutBuilder.ToString() } else { '' }
        StdErr   = if ($capturedErrBuilder) { $capturedErrBuilder.ToString() } else { '' }
        Success  = ($exitCode -eq 0)
    }
}

exit $exitCode
