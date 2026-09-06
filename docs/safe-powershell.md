# Safe PowerShell Invocation Guide

## 1. Overview & Problem Statement

When automated AI agents (such as Codex, GPT, Gemini, or Antigravity) execute PowerShell commands, a recurring pattern of execution defects and hangs occurs when constructing nested `-Command` invocations:

1. **Disappearing Variable Defect**: When an agent executes `powershell -Command "..."` or string-built commands, variable expressions like `$variable`, `$env:VAR`, or `$100` are evaluated and expanded by the parent shell prior to invocation. In the child session, the variable evaluates to empty string or disappears entirely.
2. **Quote Stripping & Argument Corruption**: Nested `-Command` quoting rules in Windows command-line parsing strip quotes, split arguments containing spaces, or introduce syntax errors.
3. **Indefinite Interactive Stdin Hangs**: If a script invokes `Read-Host`, `[Console]::ReadLine()`, or fails to supply a mandatory parameter (`[Parameter(Mandatory=$true)]`), PowerShell blocks indefinitely waiting for standard input. In automated agent environments, this hangs the entire turn or subagent run until an external abort occurs.
4. **Silent False Greens**: By default, PowerShell `-File` executions ignore non-terminating errors (`Write-Error`, cmdlet errors) and native executable failures (`$LASTEXITCODE != 0`), exiting with code 0 unless explicitly intercepted.
5. **Output Buffering Progress Starvation**: Buffering child stdout and stderr until process exit hides real-time progress from host bridges and stall detectors.

`scripts/invoke-safe-powershell.ps1` resolves these issues deterministically.

---

## 2. Architecture & Design Principles

`invoke-safe-powershell.ps1` implements the following invariants:

- **Strict `-File` Based Invocation**: Invokes child PowerShell processes using the `-File` parameter exclusively. Never generates string-built nested `-Command` strings and never calls `Invoke-Expression`.
- **Closed Child Standard Input**: Standard input of the child process is redirected and closed immediately upon startup (`$process.StandardInput.Close()`). `Read-Host` and missing mandatory parameter prompts fail fast with non-zero exit codes (1). `[Console]::ReadLine()` receives EOF (`$null`) immediately, preventing indefinite interactive hangs.
- **Headless Automation**: Configures `CreateNoWindow = $true` on `ProcessStartInfo` to guarantee headless background execution without window creation or console attachment artifacts.
- **Literal Argument Preservation**: Arguments are passed via direct positional arguments or structured `-ArgsJson` and serialized via compressed JSON environment transport (`__SAFE_PS_ARGS_JSON`), preserving literal dollar signs (`$var`), single and double quotes, spaces, switch-like flags (`-Verbose`, `-Debug`), and Unicode characters (`🚀`, `Café`, `日本語`).
- **Structured Named Parameters & Safe Splatting**: Scripts requiring named parameters (such as `scripts/install.ps1` with `-Profile` and `-Force`) must use `-ParametersJson` (CLI) or `-Parameters` (PowerShell hashtable/object). In PowerShell, array splatting (`@arr`) only binds positional parameters; named parameter binding requires hashtable splatting (`@params`). The helper validates parameter keys against valid identifier syntax (`^[a-zA-Z_][a-zA-Z0-9_]*$`) and enforces supported primitive types (strings, boolean switches `$true`/`$false`, and numerics), failing closed before launch on null values, malformed JSON, or nested objects.
- **Fail-Closed Input Validation**: Malformed `-ArgsJson` or `-ParametersJson`, wrong container types (e.g., passing a JSON object to `-ArgsJson` or a JSON array to `-ParametersJson`), null arguments, or conflicting parameters fail fast and closed before the child process starts, guaranteeing that target script side effects (such as marker file creation or state mutations) never execute on invalid input.
- **Real-Time Live Streaming**: Reads standard output and standard error concurrently using non-blocking asynchronous streaming (`WaitAny`) while the child process runs. Output is immediately flushed to the host console so bridge monitors see progress in real time without deadlock or buffering until exit.
- **Bounded PassThru Buffering**: Output capture is retained in memory only when `-PassThru` is explicitly requested, and capped at a bounded limit (10MB) to prevent unbounded silent memory accumulation. Output is never duplicated after process exit.
- **Child ErrorActionPreference Stop**: The internal runner sets `$ErrorActionPreference = 'Stop'`, guaranteeing that terminating runtime exceptions and non-terminating pipeline errors (`Write-Error`, missing file cmdlets) immediately halt execution rather than continuing with unmanaged side effects.
- **Narrow Honest Native Exit Contract**: The wrapper captures the script's final `$LASTEXITCODE`. However, early native command failures followed by subsequent successful native commands cannot be universally halted or captured by final `$LASTEXITCODE` in PowerShell. Scripts/callers requiring early stop on native failure must explicitly check `$LASTEXITCODE` after each native command.
- **No Execution Timeout or Process Kill**: Complies with the liveness contract: healthy jobs run to completion under caller authority without arbitrary execution deadlines or generic process kill branches.
- **Neutral Authority & Path Validation**: Executes scripts with caller authority only (no elevation, no RunAs). Validates that `-ScriptPath` exists, is a leaf file, and has a `.ps1` extension.
- **Dual-Engine Support**: Operates identically on both PowerShell 7 (`pwsh.exe`) and Windows PowerShell 5.1 (`powershell.exe`).

---

## 3. How GPT / Gemini / Codex Should Use the Helper

### Executing Scripts with Named Parameters (e.g. `install.ps1`)

In PowerShell, passing array arguments (e.g. `-ArgsJson '["-Profile", "safe", "-Force"]'`) splats positionally and does **NOT** bind named parameters. To invoke scripts with named parameters, pass structured JSON via `-ParametersJson`:

```pwsh
pwsh -NoProfile -NonInteractive -File scripts/invoke-safe-powershell.ps1 -ScriptPath "scripts/install.ps1" -ParametersJson '{"Profile":"safe","Force":true}'
```

Or from a PowerShell script, pass a hashtable via `-Parameters`:

```powershell
& (Join-Path $PSScriptRoot 'invoke-safe-powershell.ps1') `
    -ScriptPath 'scripts/install.ps1' `
    -Parameters @{ Profile = 'safe'; Force = $true }
```

Named parameters and positional arguments can also be combined:

```pwsh
pwsh -NoProfile -NonInteractive -File scripts/invoke-safe-powershell.ps1 -ScriptPath "scripts/my-script.ps1" -ParametersJson '{"Profile":"safe","Enabled":true}' "posArg1" "posArg2"
```

### Executing Scripts with Positional Arguments

From Shell / Tool Calls (`run_command`), invoke `invoke-safe-powershell.ps1` via `-File` with positional arguments:

```pwsh
pwsh -NoProfile -NonInteractive -File scripts/invoke-safe-powershell.ps1 -ScriptPath "scripts/my-script.ps1" "param1" '$literalVariable' "arg with space" "unicøde 🚀"
```

Or pass structured positional JSON via `-ArgsJson`:

```pwsh
pwsh -NoProfile -NonInteractive -File scripts/invoke-safe-powershell.ps1 -ScriptPath "scripts/my-script.ps1" -ArgsJson '["param1", "$literalVariable", "arg with space", "unicøde 🚀"]'
```

### From PowerShell Scripts with Positional Arguments

```powershell
& (Join-Path $PSScriptRoot 'invoke-safe-powershell.ps1') `
    -ScriptPath 'path/to/target.ps1' `
    -ArgumentList @('arg1', '$literalDollar', 'spaced arg')
```

### Structured Output with `-PassThru`

To programmatically capture results without exiting the host session:

```powershell
$result = & (Join-Path $PSScriptRoot 'invoke-safe-powershell.ps1') `
    -ScriptPath 'scripts/validate.ps1' `
    -PassThru

Write-Host "Success: $($result.Success)"
Write-Host "ExitCode: $($result.ExitCode)"
Write-Host "StdOut: $($result.StdOut)"
Write-Host "StdErr: $($result.StdErr)"
```

### Selecting Engine

To explicitly target Windows PowerShell 5.1:

```powershell
& ./scripts/invoke-safe-powershell.ps1 `
    -PowerShellExe 'powershell.exe' `
    -ScriptPath 'scripts/my-script.ps1'
```

---

## 4. Scope & Limitations

1. **Third-Party RunCommand Scope Boundary**: `invoke-safe-powershell.ps1` cannot magically intercept or enforce safety on arbitrary third-party tools or commands that bypass it. Agent instructions and orchestration policies must explicitly route PowerShell script executions through this helper.
2. **Script Files Only (`.ps1`)**: The helper strictly executes validated `.ps1` files. It deliberately does not accept arbitrary inline script blocks or raw code strings from command-line arguments to prevent escaping and injection vulnerabilities.
3. **Native Command Failure Scope**: PowerShell does not convert native application exit codes into pipeline errors by default. If a script executes an early native command that exits non-zero and subsequently executes another native command that exits 0 without inspecting `$LASTEXITCODE`, the final `$LASTEXITCODE` will be 0. Scripts requiring fail-stop behavior on native command failures must inspect `$LASTEXITCODE` immediately after each native command.
4. **Console.ReadLine Semantics**: Closed child stdin causes `[Console]::ReadLine()` to return EOF (`$null`) immediately, preventing hangs. Unlike `Read-Host` (which throws when stdin is closed in non-interactive mode), `[Console]::ReadLine()` returning `$null` does not inherently fail the process unless the script explicitly checks for null or throws on EOF.
5. **Intentional Error Handling & Explicit Exit Contract**: If a script internally catches an error or runs a native command or helper on expected negative cases that record errors in `$global:Error`, but subsequently handles the failure and explicitly executes `exit 0`, `invoke-safe-powershell.ps1` honors the explicit `exit 0` contract and reports success. The child runner cleanly scopes and resets `$LASTEXITCODE` prior to script execution so explicit exits (`exit 0`, `exit 7`, native failure 42) are observable without clearing arbitrary errors globally. Unhandled terminating exceptions (`throw`, `Stop`) are never masked, and unhandled non-terminating errors (`Write-Error` with Continue override) without explicit `exit 0` fail closed with exit code 1.
