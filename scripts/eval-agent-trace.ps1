# scripts/eval-agent-trace.ps1
# Deterministic offline evaluator for swarm agent execution traces against ready-frontier DAG scenarios.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$TracePath = '',

    [Parameter(Mandatory = $false, Position = 1)]
    [string]$FrontierPath = '',

    [Parameter(Mandatory = $false)]
    [string]$ScenarioPath = '',

    [Parameter(Mandatory = $false)]
    [string]$ExpectedThreadId = '',

    [Parameter(Mandatory = $false)]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir '..'))

# Resolve scenario/frontier path
$resolvedFrontier = if ($FrontierPath) {
    if ([IO.Path]::IsPathRooted($FrontierPath)) { $FrontierPath } else { [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $FrontierPath)) }
} elseif ($ScenarioPath) {
    if ([IO.Path]::IsPathRooted($ScenarioPath)) { $ScenarioPath } else { [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $ScenarioPath)) }
} else {
    Join-Path $repoRoot 'tests\fixtures\swarm-ready-frontier.json'
}

$violations = [System.Collections.Generic.List[string]]::new()
$idempotentAdmissions = [System.Collections.Generic.List[object]]::new()
$dispatchedJobs = @{}
$admittedNodes = @{}
$activeAgents = @{}
$consumedJobs = @{}
$completedNodes = @{}
$logicalOverlapBtailC = $false
$physicalOverlapStatus = 'unproven'
$physicalOverlapReason = 'absent physical timing (startedAt is null or absent; legitimate bridge receipt)'

function Create-Report {
    param([bool]$IsPass, [string]$ScenarioId = 'unknown')

    return [PSCustomObject]@{
        Pass = $IsPass
        TracePath = $TracePath
        ScenarioId = $ScenarioId
        Violations = @($violations)
        ConcurrencyProof = [PSCustomObject]@{
            LogicalOverlap = $logicalOverlapBtailC
            PhysicalOverlap = $physicalOverlapStatus
            Reason = $physicalOverlapReason
        }
        IdempotentAdmissions = @($idempotentAdmissions)
        DispatchedCount = $dispatchedJobs.Count
        ConsumedCount = $consumedJobs.Count
        ClosedAgentCount = @($activeAgents.Values | Where-Object { $_.closed }).Count
    }
}

# 1. Trace existence and non-empty check
if ([string]::IsNullOrWhiteSpace($TracePath) -or -not (Test-Path -LiteralPath $TracePath -PathType Leaf)) {
    $violations.Add("MissingTrace: Trace file is missing or not a leaf file: '$TracePath'")
    Write-Host "[FAIL] MissingTrace: Trace file is missing or not a leaf file: '$TracePath'" -ForegroundColor Red
    $rep = Create-Report -IsPass $false
    if ($PassThru) { return $rep }
    exit 1
}

$rawContent = Get-Content -LiteralPath $TracePath -Raw -Encoding UTF8
if ([string]::IsNullOrWhiteSpace($rawContent)) {
    $violations.Add("EmptyTrace: Trace file is empty: '$TracePath'")
    Write-Host "[FAIL] EmptyTrace: Trace file is empty: '$TracePath'" -ForegroundColor Red
    $rep = Create-Report -IsPass $false
    if ($PassThru) { return $rep }
    exit 1
}

# 2. Scenario loading
if (-not (Test-Path -LiteralPath $resolvedFrontier -PathType Leaf)) {
    $violations.Add("MissingScenario: Scenario frontier fixture not found: '$resolvedFrontier'")
    Write-Host "[FAIL] MissingScenario: Scenario frontier fixture not found: '$resolvedFrontier'" -ForegroundColor Red
    $rep = Create-Report -IsPass $false
    if ($PassThru) { return $rep }
    exit 1
}

$scenario = Get-Content -LiteralPath $resolvedFrontier -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop

# Map logical node + revision + attempt to existing request_id strings
$requestMap = @{}
$mandatoryNodes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$requiredInitialBatch = if ($scenario.PSObject.Properties['initial_batch']) { @($scenario.initial_batch) } else { @() }

foreach ($node in $scenario.nodes) {
    $nodeId = [string]$node.node_id
    $null = $mandatoryNodes.Add($nodeId)
    $op = [string]$node.operation
    $deps = @($node.dependencies)
    foreach ($rev in $node.revisions) {
        $revNum = [int]$rev.revision
        $stimulus = if ($rev.PSObject.Properties['invalidation_stimulus']) { $rev.invalidation_stimulus } else { $null }
        $depRevs = if ($rev.PSObject.Properties['dependency_revisions']) { $rev.dependency_revisions } else { $null }
        foreach ($att in $rev.attempts) {
            $attNum = [int]$att.attempt
            $reqId = [string]$att.request_id
            $requestMap[$reqId] = @{
                node_id = $nodeId
                operation = $op
                revision = $revNum
                attempt = $attNum
                dependencies = $deps
                dependency_revisions = $depRevs
                invalidation_stimulus = $stimulus
            }
        }
    }
}

$targetThread = if ($ExpectedThreadId) {
    $ExpectedThreadId
} elseif ($scenario.PSObject.Properties['thread_id']) {
    [string]$scenario.thread_id
} else {
    ''
}

# 3. Parse events (JSON Lines or JSON Array)
$events = [System.Collections.Generic.List[object]]::new()
$trimmedContent = $rawContent.Trim()

if ($trimmedContent.StartsWith('[') -and $trimmedContent.EndsWith(']')) {
    try {
        $arr = ConvertFrom-Json -InputObject $trimmedContent -ErrorAction Stop
        foreach ($item in $arr) { $events.Add($item) }
    } catch {
        $violations.Add("MalformedResult: Failed to parse trace JSON array: $($_.Exception.Message)")
    }
} else {
    $lines = Get-Content -LiteralPath $TracePath -Encoding UTF8
    $lineNum = 0
    foreach ($line in $lines) {
        $lineNum++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $parsedLine = ConvertFrom-Json -InputObject $line -ErrorAction Stop
            $events.Add($parsedLine)
        } catch {
            $violations.Add("MalformedResult: Trace line $lineNum is not valid JSON: $($_.Exception.Message)")
        }
    }
}

if ($events.Count -eq 0 -and $violations.Count -eq 0) {
    $violations.Add("EmptyTrace: Trace contains no parseable events: '$TracePath'")
}

# 4. Evaluate event stream
$seenEventIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$observedMarkers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$initialBatchDispatched = $false
$anchoredThreadId = ''

foreach ($evt in $events) {
    # 4.1 Event ID and envelope ordinal deduplication
    $idCandidates = [System.Collections.Generic.List[string]]::new()
    if ($evt.PSObject.Properties['event_id'] -and -not [string]::IsNullOrWhiteSpace([string]$evt.event_id)) {
        $idCandidates.Add("evt:$([string]$evt.event_id)")
    }
    if ($evt.PSObject.Properties['ordinal']) {
        $idCandidates.Add("ord:$([string]$evt.ordinal)")
    }
    if ($evt.PSObject.Properties['payload'] -and $evt.payload.PSObject.Properties['id'] -and -not [string]::IsNullOrWhiteSpace([string]$evt.payload.id)) {
        $idCandidates.Add("pid:$([string]$evt.payload.id)")
    }
    if ($evt.PSObject.Properties['payload'] -and $evt.payload.PSObject.Properties['item'] -and $evt.payload.item.PSObject.Properties['id'] -and -not [string]::IsNullOrWhiteSpace([string]$evt.payload.item.id)) {
        $idCandidates.Add("item:$([string]$evt.payload.item.id)")
    }

    foreach ($candidateId in $idCandidates) {
        if (-not $seenEventIds.Add($candidateId)) {
            $violations.Add("DuplicateEvents: Duplicate event ID observed: '$candidateId'")
        }
    }

    # Handle session_meta event for thread provenance anchoring
    if ($evt.PSObject.Properties['type'] -and $evt.type -eq 'session_meta') {
        $p = $evt.payload
        $smTid = if ($p.PSObject.Properties['session_id']) { [string]$p.session_id }
                 elseif ($p.PSObject.Properties['id']) { [string]$p.id }
                 else { '' }
        if (-not [string]::IsNullOrWhiteSpace($smTid)) {
            if (-not [string]::IsNullOrWhiteSpace($targetThread) -and $smTid -ne $targetThread) {
                $violations.Add("WrongThread: Session meta thread '$smTid' does not match expected thread '$targetThread'")
            } else {
                $anchoredThreadId = $smTid
            }
        }
        continue
    }

    # 4.2 Thread integrity check (supports payload.thread_id or top-level thread_id)
    $tid = if ($evt.PSObject.Properties['thread_id']) {
        [string]$evt.thread_id
    } elseif ($evt.PSObject.Properties['payload'] -and $evt.payload.PSObject.Properties['thread_id']) {
        [string]$evt.payload.thread_id
    } elseif ($evt.PSObject.Properties['payload'] -and $evt.payload.PSObject.Properties['session_id']) {
        [string]$evt.payload.session_id
    } else {
        ''
    }

    if (-not [string]::IsNullOrWhiteSpace($tid) -and -not [string]::IsNullOrWhiteSpace($targetThread)) {
        if ($tid -ne $targetThread) {
            $violations.Add("WrongThread: Event thread '$tid' does not match expected thread '$targetThread'")
        }
    }

    # 4.3 Locate tool call or executable item in event
    $item = $null
    if ($evt.PSObject.Properties['type'] -and $evt.type -eq 'event_msg' -and $evt.PSObject.Properties['payload']) {
        $p = $evt.payload
        if ($p.PSObject.Properties['item']) {
            $item = $p.item
        } else {
            # Structural check: event_msg without payload.item is a non-executable notification/session envelope
            # (e.g. token_count, task_started, task_complete, thread_settings_applied, turn_context).
            # These are non-executable metadata and MUST NOT be evaluated as executable commands.
            continue
        }
    } elseif ($evt.PSObject.Properties['type'] -and $evt.type -eq 'item_completed' -and $evt.PSObject.Properties['item']) {
        $item = $evt.item
    } elseif ($evt.PSObject.Properties['type'] -and $evt.type -in @('McpToolCall', 'CommandExecution')) {
        $item = $evt
    } elseif ($evt.PSObject.Properties['name'] -or $evt.PSObject.Properties['tool'] -or $evt.PSObject.Properties['command']) {
        $item = $evt
    }

    if ($null -eq $item) { continue }

    # Thread provenance check for executable items: mandatory via per-event thread_id or validated session_meta anchor
    if ([string]::IsNullOrWhiteSpace($tid) -and [string]::IsNullOrWhiteSpace($anchoredThreadId) -and -not [string]::IsNullOrWhiteSpace($targetThread)) {
        $violations.Add("MissingThreadProvenance: Executable item is missing thread_id and no valid session_meta anchor exists.")
    }

    # Non-executable items in native traces (messages, reasoning, compactions, meta)
    $itemType = if ($item.PSObject.Properties['type']) { [string]$item.type } else { '' }
    if ($itemType -in @('Reasoning', 'AgentMessage', 'UserMessage', 'ContextCompaction', 'session_meta', 'thread_settings_applied', 'task_started', 'FileChange')) {
        continue
    }

    $toolName = ''
    if ($itemType -eq 'CommandExecution' -or ($null -ne $item.PSObject.Properties['command'] -and -not $item.PSObject.Properties['tool'] -and -not $item.PSObject.Properties['name'])) {
        $toolName = 'CommandExecution'
    } else {
        $toolName = if ($item.PSObject.Properties['name']) { [string]$item.name } elseif ($item.PSObject.Properties['tool']) { [string]$item.tool } else { '' }
    }

    if ([string]::IsNullOrWhiteSpace($toolName)) {
        $violations.Add("UnknownCommand: Executable item type '$itemType' is not authorized in canary allowlist.")
        continue
    }

    # Parse arguments
    $argsObj = $null
    if ($toolName -eq 'CommandExecution') {
        $argsObj = @{ command = $item.command }
    } elseif ($item.PSObject.Properties['arguments']) {
        $rawArgs = $item.arguments
        if ($rawArgs -is [string]) {
            try { $argsObj = ConvertFrom-Json -InputObject $rawArgs -ErrorAction Stop } catch { $argsObj = $rawArgs }
        } else {
            $argsObj = $rawArgs
        }
    }

    # Parse result
    $resObj = $null
    if ($item.PSObject.Properties['result']) {
        $rawRes = $item.result
        if ($rawRes -is [string]) {
            $trimmedRes = $rawRes.Trim()
            if ($trimmedRes.StartsWith('{') -or $trimmedRes.StartsWith('[')) {
                try { $resObj = ConvertFrom-Json -InputObject $trimmedRes -ErrorAction Stop } catch { $resObj = $rawRes }
            } else {
                $resObj = $rawRes
            }
        } else {
            $resObj = $rawRes
        }
    } elseif ($item.PSObject.Properties['stdout']) {
        $parsedExit = $null
        if ($item.PSObject.Properties['exit_code'] -and $null -ne $item.exit_code -and $item.exit_code -isnot [bool]) {
            $refExit = 0
            if ([int]::TryParse([string]$item.exit_code, [ref]$refExit)) {
                $parsedExit = $refExit
            }
        }
        $resObj = @{
            stdout = [string]$item.stdout
            stderr = if ($item.PSObject.Properties['stderr'] -and $null -ne $item.stderr) { [string]$item.stderr } else { '' }
            exit_code = $parsedExit
            status = if ($item.PSObject.Properties['status'] -and $null -ne $item.status) { [string]$item.status } else { $null }
        }
    }

    # Extract structuredContent if present (native McpToolCall format)
    $structRes = if ($null -ne $resObj -and $resObj -isnot [string] -and $resObj.PSObject.Properties['structuredContent']) {
        $resObj.structuredContent
    } else {
        $resObj
    }

    # 4.4 Readonly canary check (tools and commands)
    $allowedTools = @($scenario.canary_allowlist.tools)
    if ($allowedTools -notcontains $toolName -and -not ($toolName -eq 'CommandExecution' -and $allowedTools -contains 'run_command')) {
        $violations.Add("UnknownCommand: Tool '$toolName' is not in the canary allowlist.")
    }

    $cmd = ''
    if ($toolName -in @('run_command', 'CommandExecution')) {
        if ($toolName -eq 'CommandExecution') {
            if ($item.PSObject.Properties['command']) {
                if ($item.command -is [System.Collections.IEnumerable] -and $item.command -isnot [string]) {
                    $cmdList = @($item.command)
                    $cmdIdx = $cmdList.IndexOf('-Command')
                    if ($cmdIdx -ge 0 -and $cmdIdx -lt ($cmdList.Count - 1)) {
                        $cmd = [string]$cmdList[$cmdIdx + 1]
                    } else {
                        $cmd = $cmdList -join ' '
                    }
                } else {
                    $cmd = [string]$item.command
                }
            }
            if ([string]::IsNullOrWhiteSpace($cmd) -and $item.PSObject.Properties['parsed_cmd']) {
                $cmd = [string]($item.parsed_cmd | ForEach-Object { $_.cmd } | Select-Object -First 1)
            }
        } else {
            if ($null -ne $argsObj) {
                $cmd = if ($argsObj.PSObject.Properties['CommandLine']) {
                    [string]$argsObj.CommandLine
                } elseif ($argsObj.PSObject.Properties['command']) {
                    [string]$argsObj.command
                } elseif ($argsObj.PSObject.Properties['cmd']) {
                    [string]$argsObj.cmd
                } else {
                    ''
                }
            }
        }

        $allowedCmds = @($scenario.canary_allowlist.commands)
        $isCmdAllowed = $false
        foreach ($ac in $allowedCmds) {
            if ($cmd.Trim() -eq $ac.Trim()) {
                $isCmdAllowed = $true
                break
            }
        }
        if (-not $isCmdAllowed) {
            $violations.Add("UnknownCommand: Command '$cmd' is not in the canary allowlist.")
        }
    }

    # 4.5 Authoritative marker harvesting for selective invalidation
    # Binds marker to declared tool + exact args + successful result exact field
    foreach ($n in $scenario.nodes) {
        foreach ($r in $n.revisions) {
            if ($r.PSObject.Properties['invalidation_stimulus'] -and $null -ne $r.invalidation_stimulus) {
                $stimDecl = $r.invalidation_stimulus
                if ($stimDecl -is [string]) {
                    # Arbitrary un-bound string stimulus cannot be authoritatively harvested
                    continue
                }

                $declTool = if ($stimDecl.PSObject.Properties['tool']) { [string]$stimDecl.tool } else { '' }
                $declField = if ($stimDecl.PSObject.Properties['field']) { [string]$stimDecl.field } else { 'stdout' }
                $declMarker = if ($stimDecl.PSObject.Properties['marker']) { [string]$stimDecl.marker } else { '' }
                $declCmd = if ($stimDecl.PSObject.Properties['command']) {
                    [string]$stimDecl.command
                } elseif ($stimDecl.PSObject.Properties['arguments'] -and $stimDecl.arguments.PSObject.Properties['CommandLine']) {
                    [string]$stimDecl.arguments.CommandLine
                } elseif ($stimDecl.PSObject.Properties['arguments'] -and $stimDecl.arguments.PSObject.Properties['command']) {
                    [string]$stimDecl.arguments.command
                } else {
                    ''
                }

                if ([string]::IsNullOrWhiteSpace($declMarker)) { continue }

                # Verify tool match
                $toolMatches = ($toolName -eq $declTool) -or
                    ($toolName -in @('CommandExecution', 'run_command') -and $declTool -in @('CommandExecution', 'run_command'))
                if (-not $toolMatches) { continue }

                # Verify command match
                if (-not [string]::IsNullOrWhiteSpace($declCmd)) {
                    if ($cmd.Trim() -ne $declCmd.Trim()) { continue }
                }

                # Verify execution success
                $isSuccess = $false
                if ($toolName -eq 'CommandExecution') {
                    $hasExplicitExit = $item.PSObject.Properties['exit_code'] -and ($null -ne $item.exit_code) -and ($item.exit_code -isnot [bool])
                    $exitVal = -1
                    $validExitCode = if ($hasExplicitExit) { [int]::TryParse([string]$item.exit_code, [ref]$exitVal) } else { $false }
                    $hasCompletedStatus = $item.PSObject.Properties['status'] -and ($null -ne $item.status) -and ([string]$item.status -in @('completed', 'success'))
                    if ($validExitCode -and ($exitVal -eq 0) -and $hasCompletedStatus) {
                        $isSuccess = $true
                    }
                } else {
                    $isSuccess = $true
                }
                if (-not $isSuccess) { continue }

                # Verify exact field in result contains marker
                $targetFields = @($declField)
                if ($declField -in @('stdout', 'output')) {
                    $targetFields = @('stdout', 'output', 'formatted_output')
                }
                $fieldVal = ''
                foreach ($tf in $targetFields) {
                    if ($item.PSObject.Properties[$tf]) {
                        $fieldVal = [string]$item.$tf
                        if ($fieldVal.Contains($declMarker)) { break }
                    } elseif ($null -ne $resObj -and $resObj -isnot [string] -and $resObj.PSObject.Properties[$tf]) {
                        $fieldVal = [string]$resObj.$tf
                        if ($fieldVal.Contains($declMarker)) { break }
                    } elseif ($null -ne $structRes -and $structRes -isnot [string] -and $structRes.PSObject.Properties[$tf]) {
                        $fieldVal = [string]$structRes.$tf
                        if ($fieldVal.Contains($declMarker)) { break }
                    }
                }

                if ($fieldVal.Contains($declMarker)) {
                    $null = $observedMarkers.Add($declMarker)
                }
            }
        }
    }

    # 4.6 Result schema validation for spawn, spawn_batch, continue, and follow
    if ($toolName -in @('subagents_spawn', 'subagents_spawn_batch', 'subagents_continue')) {
        if ($null -eq $structRes -or ($structRes -is [string] -and -not ($structRes.Trim().StartsWith('{') -or $structRes.Trim().StartsWith('[')))) {
            $violations.Add("MalformedResult: Tool '$toolName' emitted malformed result: '$structRes'")
        } elseif ($structRes -isnot [string]) {
            $hasItems = $structRes.PSObject.Properties['items'] -or $structRes.PSObject.Properties['receipts']
            $hasSingle = ($structRes.PSObject.Properties['jobId'] -or $structRes.PSObject.Properties['job_id']) -and ($structRes.PSObject.Properties['status'])
            if (-not $hasItems -and -not $hasSingle) {
                $violations.Add("MalformedResult: Tool '$toolName' result is missing items or jobId property.")
            }

            # Enforce real admission accepted:true (Point 3)
            $isAccepted = if ($structRes.PSObject.Properties['accepted']) { [bool]$structRes.accepted } else { $false }
            if (-not $isAccepted) {
                $violations.Add("UnacceptedAdmission: Tool '$toolName' call rejected or missing required accepted=true.")
            }
        }
    }

    if ($toolName -eq 'subagents_follow') {
        if ($null -eq $structRes -or ($structRes -is [string] -and -not ($structRes.Trim().StartsWith('{') -or $structRes.Trim().StartsWith('[')))) {
            $violations.Add("MalformedResult: Tool '$toolName' emitted malformed result: '$structRes'")
        } elseif ($structRes -isnot [string]) {
            $hasItems = $structRes.PSObject.Properties['items'] -or $structRes.PSObject.Properties['receipts']
            $hasSingle = ($structRes.PSObject.Properties['receipt'] -or $structRes.PSObject.Properties['jobId'] -or $structRes.PSObject.Properties['job_id'])
            if (-not $hasItems -and -not $hasSingle) {
                $violations.Add("MalformedResult: Tool '$toolName' result is missing receipt or items property.")
            }
        }
    }

    # 4.7 Handle subagents_spawn, subagents_spawn_batch, and subagents_continue
    if ($toolName -in @('subagents_spawn', 'subagents_spawn_batch', 'subagents_continue') -and $null -ne $argsObj) {
        $requests = @()
        if ($toolName -eq 'subagents_spawn_batch') {
            # Point 1: real batch arguments.items not requests
            if ($argsObj.PSObject.Properties['items']) {
                $requests = @($argsObj.items)
            } elseif ($argsObj.PSObject.Properties['requests']) {
                $requests = @($argsObj.requests)
            } elseif ($argsObj.PSObject.Properties['request_id'] -or $argsObj.PSObject.Properties['requestId']) {
                $requests = @($argsObj)
            }
        } else {
            # Single subagents_spawn or subagents_continue
            $rId = if ($argsObj.PSObject.Properties['request_id']) {
                [string]$argsObj.request_id
            } elseif ($argsObj.PSObject.Properties['requestId']) {
                [string]$argsObj.requestId
            } else {
                ''
            }
            $agId = if ($argsObj.PSObject.Properties['agent_id']) {
                [string]$argsObj.agent_id
            } elseif ($argsObj.PSObject.Properties['agentId']) {
                [string]$argsObj.agentId
            } else {
                ''
            }
            $requests = @( [PSCustomObject]@{ request_id = $rId; agent_id = $agId } )
        }

        # Verify initial ready batch requirement before any follow
        if (-not $initialBatchDispatched) {
            if ($toolName -ne 'subagents_spawn_batch') {
                $violations.Add("InvalidInitialBatch: Scenario requires initial single ready batch containing [$($requiredInitialBatch -join ', ')] before first follow.")
            } else {
                $batchNodes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($rq in $requests) {
                    $rqId = if ($rq.PSObject.Properties['request_id']) { [string]$rq.request_id } elseif ($rq.PSObject.Properties['requestId']) { [string]$rq.requestId } else { '' }
                    if ($requestMap.ContainsKey($rqId)) {
                        $null = $batchNodes.Add($requestMap[$rqId].node_id)
                    }
                }
                foreach ($reqInit in $requiredInitialBatch) {
                    if (-not $batchNodes.Contains($reqInit)) {
                        $violations.Add("InvalidInitialBatch: Initial ready batch missing required initial node '$reqInit'.")
                    }
                }
                $initialBatchDispatched = $true
            }
        }

        # Extract admitted items
        $admittedItems = @()
        if ($null -ne $structRes -and $structRes -isnot [string]) {
            if ($structRes.PSObject.Properties['items']) {
                $admittedItems = @($structRes.items)
            } elseif ($structRes.PSObject.Properties['receipts']) {
                $admittedItems = @($structRes.receipts)
            } elseif ($structRes.PSObject.Properties['jobId'] -or $structRes.PSObject.Properties['job_id']) {
                $admittedItems = @($structRes)
            }
        }

        foreach ($req in $requests) {
            $reqId = if ($req.PSObject.Properties['request_id']) { [string]$req.request_id } elseif ($req.PSObject.Properties['requestId']) { [string]$req.requestId } else { '' }
            $reqAgentId = if ($req.PSObject.Properties['agent_id']) { [string]$req.agent_id } elseif ($req.PSObject.Properties['agentId']) { [string]$req.agentId } else { '' }

            if (-not $requestMap.ContainsKey($reqId)) {
                $violations.Add("UnknownRequest: request_id '$reqId' is not declared in scenario frontier.")
                continue
            }

            $nodeInfo = $requestMap[$reqId]
            $nodeId = [string]$nodeInfo.node_id
            $rev = [int]$nodeInfo.revision
            $deps = @($nodeInfo.dependencies)
            $stimulusObj = $nodeInfo.invalidation_stimulus
            $depRevs = $nodeInfo.dependency_revisions

            # Selective invalidation check: revision > 1 requires observed stimulus
            if ($rev -gt 1) {
                $markerExpected = if ($stimulusObj -and $stimulusObj -isnot [string] -and $stimulusObj.PSObject.Properties['marker']) {
                    [string]$stimulusObj.marker
                } elseif ($stimulusObj -is [string]) {
                    [string]$stimulusObj
                } else {
                    ''
                }

                if (-not [string]::IsNullOrWhiteSpace($markerExpected)) {
                    if (-not $observedMarkers.Contains($markerExpected)) {
                        $violations.Add("InvalidRevisionStimulus: Revision $rev for node '$nodeId' admitted without observed stimulus '$markerExpected' (unproven fail-closed).")
                    }
                }
            }

            # Dependency and revision checks
            $depRevEntries = @()
            if ($null -ne $depRevs) {
                if ($depRevs -is [System.Collections.IDictionary]) {
                    foreach ($k in $depRevs.Keys) {
                        $depRevEntries += @([PSCustomObject]@{ Node = [string]$k; Rev = [int]$depRevs[$k] })
                    }
                } elseif ($depRevs.PSObject.Properties) {
                    foreach ($p in $depRevs.PSObject.Properties) {
                        $depRevEntries += @([PSCustomObject]@{ Node = [string]$p.Name; Rev = [int]$p.Value })
                    }
                }
            }

            if ($depRevEntries.Count -gt 0) {
                foreach ($entry in $depRevEntries) {
                    $depNode = [string]$entry.Node
                    $reqRev = [int]$entry.Rev
                    if (-not $completedNodes.ContainsKey($depNode)) {
                        $violations.Add("PrematureAdmission: Node '$nodeId' admitted prematurely before dependency '$depNode' completed.")
                    } else {
                        $depStatus = [string]$completedNodes[$depNode].status
                        $actualDepRev = [int]$completedNodes[$depNode].revision
                        if ($depStatus -ne 'completed' -and $depStatus -ne 'success') {
                            $violations.Add("DependencyFailed: Node '$nodeId' dependency '$depNode' ended with non-success status '$depStatus'.")
                        } elseif ($actualDepRev -lt $reqRev) {
                            $violations.Add("StaleDependencyRevision: Node '$nodeId' revision $rev requires dependency '$depNode' at revision $reqRev, but '$depNode' is at stale revision $actualDepRev.")
                        }
                    }

                    # Verify no in-flight newer revision of dependency is unconsumed
                    $latestAdmitted = 0
                    foreach ($adKey in $admittedNodes.Keys) {
                        if ($adKey.StartsWith("$($depNode):")) {
                            $ar = [int]($adKey.Split(':')[1])
                            if ($ar -gt $latestAdmitted) { $latestAdmitted = $ar }
                        }
                    }
                    if ($latestAdmitted -gt $reqRev -and (-not $completedNodes.ContainsKey($depNode) -or [int]$completedNodes[$depNode].revision -lt $latestAdmitted)) {
                        $violations.Add("StaleDependencyRevision: Node '$nodeId' revision $rev depends on '$depNode', but a newer revision $latestAdmitted of '$depNode' is in-flight/unconsumed.")
                    }
                }
            } elseif ($deps.Count -gt 0) {
                foreach ($dep in $deps) {
                    if (-not $completedNodes.ContainsKey($dep)) {
                        $violations.Add("PrematureAdmission: Node '$nodeId' admitted prematurely before dependency '$dep' completed.")
                    } else {
                        $depStatus = [string]$completedNodes[$dep].status
                        if ($depStatus -ne 'completed' -and $depStatus -ne 'success') {
                            $violations.Add("DependencyFailed: Node '$nodeId' dependency '$dep' ended with non-success status '$depStatus'.")
                        }
                    }

                    $latestAdmitted = 0
                    foreach ($adKey in $admittedNodes.Keys) {
                        if ($adKey.StartsWith("$($dep):")) {
                            $ar = [int]($adKey.Split(':')[1])
                            if ($ar -gt $latestAdmitted) { $latestAdmitted = $ar }
                        }
                    }
                    if ($latestAdmitted -gt 1 -and (-not $completedNodes.ContainsKey($dep) -or [int]$completedNodes[$dep].revision -lt $latestAdmitted)) {
                        $violations.Add("StaleDependencyRevision: Node '$nodeId' revision $rev depends on '$dep', but a newer revision $latestAdmitted of '$dep' is in-flight/unconsumed.")
                    }
                }
            }

            # Match receipt / item for this reqId
            # Point 5: requestId explicit mismatch cannot count-fallback; mismatched result receipt ids reject.
            $rcpt = $null
            foreach ($it in $admittedItems) {
                $itReqId = if ($it.PSObject.Properties['requestId']) { [string]$it.requestId } elseif ($it.PSObject.Properties['request_id']) { [string]$it.request_id } else { '' }
                if (-not [string]::IsNullOrWhiteSpace($itReqId) -and $itReqId -eq $reqId) {
                    $rcpt = $it
                    break
                }
            }

            if ($null -eq $rcpt -and $admittedItems.Count -eq 1 -and $requests.Count -eq 1) {
                $singleItem = $admittedItems[0]
                $singleReqId = if ($singleItem.PSObject.Properties['requestId']) { [string]$singleItem.requestId } elseif ($singleItem.PSObject.Properties['request_id']) { [string]$singleItem.request_id } else { '' }
                if ([string]::IsNullOrWhiteSpace($singleReqId)) {
                    $rcpt = $singleItem
                } else {
                    $violations.Add("MismatchedReceiptId: Admission receipt requestId '$singleReqId' does not match requested requestId '$reqId'.")
                }
            }

            if ($null -eq $rcpt) {
                $hasExplicitOtherIds = $false
                foreach ($it in $admittedItems) {
                    $itReqId = if ($it.PSObject.Properties['requestId']) { [string]$it.requestId } elseif ($it.PSObject.Properties['request_id']) { [string]$it.request_id } else { '' }
                    if (-not [string]::IsNullOrWhiteSpace($itReqId) -and $itReqId -ne $reqId) {
                        $hasExplicitOtherIds = $true
                    }
                }
                if ($hasExplicitOtherIds) {
                    $violations.Add("MismatchedReceiptId: No matching admission receipt found for request '$reqId'.")
                } else {
                    $violations.Add("MissingAdmissionReceipt: No admission receipt returned for request '$reqId'.")
                }
                continue
            }

            # Check admission status on the item (Point 3: require real admission accepted:true and accepted status)
            $rcptStatus = if ($rcpt.PSObject.Properties['status']) { [string]$rcpt.status } else { '' }
            if ($rcptStatus -notin @('accepted', 'admitted')) {
                $violations.Add("UnacceptedAdmission: Admission receipt for request '$reqId' has non-accepted status '$rcptStatus'.")
                continue
            }

            # Check agent identity matching (Point 5)
            $jobId = if ($rcpt.PSObject.Properties['jobId']) { [string]$rcpt.jobId } elseif ($rcpt.PSObject.Properties['job_id']) { [string]$rcpt.job_id } else { '' }
            $agentId = if ($rcpt.PSObject.Properties['agentId']) { [string]$rcpt.agentId } elseif ($rcpt.PSObject.Properties['agent_id']) { [string]$rcpt.agent_id } else { '' }
            if ([string]::IsNullOrWhiteSpace($agentId) -and -not [string]::IsNullOrWhiteSpace($reqAgentId)) {
                $agentId = $reqAgentId
            }

            if (-not [string]::IsNullOrWhiteSpace($reqAgentId) -and -not [string]::IsNullOrWhiteSpace($agentId) -and $agentId -ne $reqAgentId) {
                $violations.Add("AgentIdentityMismatch: Admitted agentId '$agentId' does not match requested agent_id '$reqAgentId'.")
            }

            $attemptVal = if ($rcpt.PSObject.Properties['attempt']) { $rcpt.attempt } else { $null }
            $fenceVal = if ($rcpt.PSObject.Properties['fence']) { $rcpt.fence } else { $null }

            $nodeKey = "$($nodeId):$($rev)"
            if ($admittedNodes.ContainsKey($nodeKey)) {
                $prevJobId = $admittedNodes[$nodeKey]
                if ($prevJobId -eq $jobId) {
                    # Repeated identical idempotent admission receipt same job no effect
                    $idempotentAdmissions.Add([PSCustomObject]@{
                        JobId = $jobId
                        NodeId = $nodeId
                        Revision = $rev
                    })
                } else {
                    # Distinct job same operation reject
                    $violations.Add("DuplicateSameOperation: Distinct job '$jobId' attempted same operation/revision for node '$nodeId' (already held by '$prevJobId').")
                }
            } else {
                $admittedNodes[$nodeKey] = $jobId
            }

            if (-not [string]::IsNullOrWhiteSpace($jobId)) {
                $dispatchedJobs[$jobId] = @{
                    requestId = $reqId
                    nodeId = $nodeId
                    revision = $rev
                    agentId = $agentId
                    attempt = $attemptVal
                    fence = $fenceVal
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($agentId)) {
                if (-not $activeAgents.ContainsKey($agentId)) {
                    $activeAgents[$agentId] = @{ jobId = $jobId; closed = $false }
                }
            }

            # Concurrency assertion: check Btail admission relative to initial C (Point 4)
            if ($nodeId -eq 'Btail') {
                $cJobId = if ($admittedNodes.ContainsKey("C:1")) { $admittedNodes["C:1"] } else { $null }
                if ($null -eq $cJobId) {
                    $physicalOverlapReason = "C was never admitted; logical concurrency unproven"
                    $physicalOverlapStatus = 'unproven'
                    $logicalOverlapBtailC = $false
                    $violations.Add("MissingLogicalConcurrency: Scenario requires Btail dispatched while C unconsumed, but C was never admitted.")
                } elseif ($consumedJobs.ContainsKey($cJobId)) {
                    $physicalOverlapReason = "C finished before Btail was admitted; physical overlap unproven"
                    $physicalOverlapStatus = 'unproven'
                    $logicalOverlapBtailC = $false
                    $violations.Add("MissingLogicalConcurrency: Scenario requires Btail dispatched while C unconsumed, but C was already consumed.")
                } else {
                    $logicalOverlapBtailC = $true
                }
            }
        }
    }

    # 4.8 Handle subagents_follow
    if ($toolName -eq 'subagents_follow') {
        if (-not $initialBatchDispatched) {
            $violations.Add("PrematureFollow: subagents_follow occurred before initial ready batch was dispatched.")
        }

        # Check requested job_ids in arguments (Point 5)
        if ($null -ne $argsObj) {
            $reqJobIds = @()
            if ($argsObj.PSObject.Properties['job_ids']) {
                $reqJobIds += @($argsObj.job_ids)
            } elseif ($argsObj.PSObject.Properties['job_id']) {
                $reqJobIds += @($argsObj.job_id)
            } elseif ($argsObj.PSObject.Properties['jobId']) {
                $reqJobIds += @($argsObj.jobId)
            }

            foreach ($rjId in $reqJobIds) {
                $rStr = [string]$rjId
                if (-not $dispatchedJobs.ContainsKey($rStr)) {
                    $violations.Add("UnknownJobFollow: Follow requested for unknown job '$rStr' which was not dispatched in this scenario.")
                }
            }
        }

        $followedItems = @()
        if ($null -ne $structRes -and $structRes -isnot [string]) {
            if ($structRes.PSObject.Properties['items']) {
                $followedItems = @($structRes.items)
            } elseif ($structRes.PSObject.Properties['receipts']) {
                $followedItems = @($structRes.receipts)
            } elseif ($structRes.PSObject.Properties['receipt']) {
                $rc = $structRes.receipt
                $followedItems = @( [PSCustomObject]@{
                    jobId = if ($rc.PSObject.Properties['jobId']) { [string]$rc.jobId } else { [string]$structRes.jobId }
                    agentId = if ($rc.PSObject.Properties['agentId']) { [string]$rc.agentId } else { [string]$structRes.agentId }
                    status = if ($rc.PSObject.Properties['status']) { [string]$rc.status } else { [string]$structRes.status }
                    startedAt = if ($rc.PSObject.Properties['startedAt']) { $rc.startedAt } else { $null }
                    completedAt = if ($rc.PSObject.Properties['completedAt']) { $rc.completedAt } else { $null }
                } )
            } elseif ($structRes.PSObject.Properties['jobId'] -or $structRes.PSObject.Properties['job_id']) {
                $followedItems = @($structRes)
            }
        }

        foreach ($rcpt in $followedItems) {
            $jobId = if ($rcpt.PSObject.Properties['jobId']) { [string]$rcpt.jobId } elseif ($rcpt.PSObject.Properties['job_id']) { [string]$rcpt.job_id } else { '' }
            $followedAgentId = if ($rcpt.PSObject.Properties['agentId']) { [string]$rcpt.agentId } elseif ($rcpt.PSObject.Properties['agent_id']) { [string]$rcpt.agent_id } else { '' }
            $status = if ($rcpt.PSObject.Properties['status']) { [string]$rcpt.status } else { '' }
            $startedAt = if ($rcpt.PSObject.Properties['startedAt']) { $rcpt.startedAt } else { $null }
            $completedAt = if ($rcpt.PSObject.Properties['completedAt']) { $rcpt.completedAt } else { $null }

            if (-not [string]::IsNullOrWhiteSpace($jobId)) {
                if (-not $dispatchedJobs.ContainsKey($jobId)) {
                    $violations.Add("UnknownJobFollow: Follow result contains unknown job '$jobId' not dispatched in this scenario.")
                    continue
                }

                # Validate agent identity against admission (Point 5)
                $admittedAgentId = [string]$dispatchedJobs[$jobId].agentId
                if (-not [string]::IsNullOrWhiteSpace($followedAgentId) -and -not [string]::IsNullOrWhiteSpace($admittedAgentId) -and $followedAgentId -ne $admittedAgentId) {
                    $violations.Add("AgentIdentityMismatch: Followed job '$jobId' agentId '$followedAgentId' does not match admitted agentId '$admittedAgentId'.")
                }

                $consumedJobs[$jobId] = @{
                    status = $status
                    startedAt = $startedAt
                    completedAt = $completedAt
                }

                $nId = [string]$dispatchedJobs[$jobId].nodeId
                $r = [int]$dispatchedJobs[$jobId].revision
                $completedNodes[$nId] = @{ status = $status; revision = $r }
            }
        }
    }

    # 4.9 Handle subagents_close
    if ($toolName -eq 'subagents_close') {
        $requestedAgents = @()
        if ($null -ne $argsObj) {
            if ($argsObj.PSObject.Properties['agent_ids']) {
                $requestedAgents += @($argsObj.agent_ids)
            } elseif ($argsObj.PSObject.Properties['agent_id']) {
                $requestedAgents += @($argsObj.agent_id)
            } elseif ($argsObj.PSObject.Properties['agentId']) {
                $requestedAgents += @($argsObj.agentId)
            }
        }

        # Point 5: Orphan close fail-closed within declared slice
        foreach ($reqAg in $requestedAgents) {
            $reqAgStr = [string]$reqAg
            if (-not $activeAgents.ContainsKey($reqAgStr)) {
                $violations.Add("UnknownAgentClose: Close requested for agent '$reqAgStr' which was not spawned in this scenario.")
            }
        }

        if ($null -eq $structRes -or ($structRes -is [string] -and [string]::IsNullOrWhiteSpace($structRes))) {
            $violations.Add("FailedClose: subagents_close returned empty or null result.")
        } else {
            $confirmedClosed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

            # Single agent close check
            if ($structRes.PSObject.Properties['agentId'] -or $structRes.PSObject.Properties['agent_id']) {
                $agId = if ($structRes.PSObject.Properties['agentId']) { [string]$structRes.agentId } else { [string]$structRes.agent_id }
                $st = if ($structRes.PSObject.Properties['status']) { [string]$structRes.status } else { '' }
                # Point 7: quiescent absent CANNOT default to true!
                $isQuiescent = if ($structRes.PSObject.Properties['quiescent']) { [bool]$structRes.quiescent } else { $false }
                if ($st -eq 'closed' -and $isQuiescent) {
                    if ($activeAgents.ContainsKey($agId)) {
                        $null = $confirmedClosed.Add($agId)
                        $activeAgents[$agId].closed = $true
                    } else {
                        $violations.Add("UnknownAgentClose: Closed agent '$agId' was not spawned in this scenario.")
                    }
                } else {
                    $violations.Add("FailedClose: subagents_close failed for agent '$agId' with status '$st' (quiescent=$isQuiescent).")
                }
            }

            # Batch items close check
            if ($structRes.PSObject.Properties['items']) {
                foreach ($it in $structRes.items) {
                    $itAgId = if ($it.PSObject.Properties['agentId']) { [string]$it.agentId } elseif ($it.PSObject.Properties['agent_id']) { [string]$it.agent_id } else { '' }
                    $itSt = if ($it.PSObject.Properties['status']) { [string]$it.status } else { '' }
                    $itQuiescent = if ($it.PSObject.Properties['quiescent']) { [bool]$it.quiescent } elseif ($structRes.PSObject.Properties['quiescent']) { [bool]$structRes.quiescent } else { $false }
                    if ($itSt -eq 'closed' -and $itQuiescent) {
                        if ($activeAgents.ContainsKey($itAgId)) {
                            $null = $confirmedClosed.Add($itAgId)
                            $activeAgents[$itAgId].closed = $true
                        } else {
                            $violations.Add("UnknownAgentClose: Closed agent '$itAgId' was not spawned in this scenario.")
                        }
                    } else {
                        $violations.Add("FailedClose: subagents_close failed for agent '$itAgId' with status '$itSt' (quiescent=$itQuiescent).")
                    }
                }
            } elseif ($structRes.PSObject.Properties['closed']) {
                # Point 7: no fictional batchclosed bypass; validate actual quiescent confirmation!
                $batchQuiescent = if ($structRes.PSObject.Properties['quiescent']) { [bool]$structRes.quiescent } else { $false }
                if (-not $batchQuiescent) {
                    $violations.Add("FailedClose: Batch close result is missing required quiescent=true confirmation.")
                } else {
                    foreach ($ag in $structRes.closed) {
                        $agStr = [string]$ag
                        if ($activeAgents.ContainsKey($agStr)) {
                            $null = $confirmedClosed.Add($agStr)
                            $activeAgents[$agStr].closed = $true
                        } else {
                            $violations.Add("UnknownAgentClose: Closed agent '$agStr' was not spawned in this scenario.")
                        }
                    }
                }
            }

            foreach ($reqAg in $requestedAgents) {
                $reqAgStr = [string]$reqAg
                if (-not $confirmedClosed.Contains($reqAgStr)) {
                    $violations.Add("FailedClose: Agent '$reqAgStr' requested for close was not confirmed closed by result.")
                }
            }
        }
    }
}

# 5. Lifecycle & scenario completion obligations
if ($dispatchedJobs.Count -eq 0) {
    $violations.Add("EmptyTrace: No scenario jobs were dispatched in trace.")
}

foreach ($mId in $mandatoryNodes) {
    if (-not $completedNodes.ContainsKey($mId)) {
        $violations.Add("MissingMandatoryNode: Mandatory scenario node '$mId' was never completed.")
    } else {
        $st = [string]$completedNodes[$mId].status
        if ($st -ne 'completed' -and $st -ne 'success') {
            $violations.Add("MissingMandatoryNode: Mandatory scenario node '$mId' ended with non-success status '$st'.")
        }
    }
}

foreach ($jId in $dispatchedJobs.Keys) {
    if (-not $consumedJobs.ContainsKey($jId)) {
        $violations.Add("PendingFollow: Dispatched job '$jId' was not consumed via terminal follow.")
    } else {
        $st = [string]$consumedJobs[$jId].status
        if ($st -ne 'completed' -and $st -ne 'success') {
            $violations.Add("JobFailedOrPending: Job '$jId' ended with non-success status '$st'.")
        }
    }
}

foreach ($agId in $activeAgents.Keys) {
    if (-not $activeAgents[$agId].closed) {
        $violations.Add("UnclosedAgent: Spawned agent '$agId' was never closed via subagents_close.")
    }
}

# 6. Concurrency and physical timing verification
$anyNullStartedAt = $false
foreach ($c in $consumedJobs.Values) {
    if ($null -eq $c.startedAt -or [string]::IsNullOrWhiteSpace([string]$c.startedAt)) {
        $anyNullStartedAt = $true
        break
    }
}

if ($anyNullStartedAt) {
    $physicalOverlapStatus = 'unproven'
    if ($physicalOverlapReason -notmatch 'finished before' -and $physicalOverlapReason -notmatch 'never admitted') {
        $physicalOverlapReason = 'absent physical timing (startedAt is null or absent; legitimate bridge receipt)'
    }
}

$scenarioId = if ($scenario.PSObject.Properties['scenario_id']) { [string]$scenario.scenario_id } else { 'unknown' }
$isPass = ($violations.Count -eq 0)
$report = Create-Report -IsPass $isPass -ScenarioId $scenarioId

# 7. Print summary and return / exit
if ($isPass) {
    Write-Host "[PASS] Swarm agent trace evaluation passed for scenario '$scenarioId'." -ForegroundColor Green
    Write-Host "       Dispatched: $($report.DispatchedCount) | Consumed: $($report.ConsumedCount) | Closed Agents: $($report.ClosedAgentCount)"
    Write-Host "       Logical Overlap: $($report.ConcurrencyProof.LogicalOverlap) | Physical Overlap: $($report.ConcurrencyProof.PhysicalOverlap) ($($report.ConcurrencyProof.Reason))"
    if ($report.IdempotentAdmissions.Count -gt 0) {
        Write-Host "       Idempotent admissions: $($report.IdempotentAdmissions.Count) (no effect)"
    }
    if ($PassThru) { return $report }
    exit 0
} else {
    Write-Host "[FAIL] Swarm agent trace evaluation failed with $($violations.Count) violation(s):" -ForegroundColor Red
    foreach ($v in $violations) {
        Write-Host " - $v" -ForegroundColor Red
    }
    if ($PassThru) { return $report }
    exit 1
}
