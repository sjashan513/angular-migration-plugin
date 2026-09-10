#Requires -Version 5.1
param([ValidateSet('preToolUse', 'subagentStop')][string]$Event)
Set-StrictMode -Version 2.0

function Resolve-RepairPath {
    param([string]$Root, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Invalid repair path.' }
    $relative = $Path.Replace('\', '/')
    if ([IO.Path]::IsPathRooted($Path)) {
        $prefix = $Root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $full = [IO.Path]::GetFullPath($Path)
        if (-not $full.StartsWith($prefix, [StringComparison]::Ordinal)) { throw 'Invalid repair path.' }
        $relative = $Path.Substring($prefix.Length).Replace('\', '/')
    }
    if ($relative -match '[:*?\[\]"<>|\x00-\x1f]' -or $relative -match '(^|/)(\.{1,2}|[^/]*[. ])(/|$)' -or
        $relative -match '(^|/)(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|/|$)' -or $relative -match '//|/$') {
        throw 'Invalid repair path.'
    }
    $ancestor = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    while ($ancestor) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked repair path.' }
        $ancestor = $ancestor.Parent
    }
    $current = $Root
    foreach ($segment in $relative.Split('/')) {
        if (Test-Path -LiteralPath $current -PathType Container) {
            $entry = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop | Where-Object { $_.Name -ieq $segment })
            if ($entry.Count -gt 0) {
                if ($entry.Count -ne 1 -or $entry[0].Name -cne $segment -or ($entry[0].Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Noncanonical repair path.' }
            }
        }
        $current = Join-Path $current $segment
    }
    return [IO.Path]::GetFullPath($current)
}

function Test-RepairGlob {
    param([string]$Path, [string]$Glob)
    $pattern = [regex]::Escape($Glob).Replace('\*\*/', '(?:.*/)?').Replace('\*\*', '.*').Replace('\*', '[^/]*')
    return $Path -cmatch ('^' + $pattern + '$')
}

function Test-RepairAllowedPath {
    param([string]$Path, $Context)
    foreach ($glob in @($Context.forbiddenPaths)) { if (Test-RepairGlob $Path $glob) { return $false } }
    foreach ($glob in @($Context.allowedPaths)) { if (Test-RepairGlob $Path $glob) { return $true } }
    return $false
}

function Protect-RepairText {
    param([string]$Text, [string]$Root)
    $value = $Text
    if ($Root) { $value = $value.Replace($Root, '<project>') }
    $value = [regex]::Replace($value, '(?im)^.*(?:authorization|proxy-authorization|cookie|set-cookie|_auth|password|token|secret|\.npmrc).*(?:\r?\n|$)', '[redacted]' + "`n")
    $value = [regex]::Replace($value, '(?i)https?://[^\s]+', '[redacted-url]')
    $value = [regex]::Replace($value, '(?i)\b(?:gh[pousr]_[a-z0-9_]+|github_pat_[a-z0-9_]+|npm_[a-z0-9]+|eyJ[a-z0-9_.-]+)\b', '[redacted]')
    if ($Root) {
        $npmrc = Join-Path $Root '.npmrc'
        if (Test-Path -LiteralPath $npmrc -PathType Leaf) {
            foreach ($line in [IO.File]::ReadAllLines($npmrc)) {
                if ($line -match '^\s*[^#;][^=]*=\s*(.+?)\s*$') {
                    $secret = $Matches[1].Trim('"', "'")
                    if ($secret) { $value = $value.Replace($secret, '[redacted]') }
                }
            }
        }
    }
    return $value
}

if ($MyInvocation.InvocationName -eq '.') { return }
$ErrorActionPreference = 'Stop'
try {
    $root = (Get-Location).Path
    $lockPath = Resolve-RepairPath $root '.angular-migration/active.lock'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { [Console]::Out.Write('{}'); exit 0 }
    $active = [IO.File]::ReadAllText($lockPath) | ConvertFrom-Json
    if ($active.schemaVersion -ne 5) { [Console]::Out.Write('{}'); exit 0 }
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
    if ($Event -eq 'subagentStop' -and $payload.agentName -cne 'migration-implementer') { [Console]::Out.Write('{}'); exit 0 }
    if ($active.runId -cnotmatch '^[a-z0-9TZ]+(?:-[a-z0-9TZ]+)*$') { throw 'Invalid run.' }
    $statePath = Resolve-RepairPath $root ('.angular-migration/runs/' + $active.runId + '/state.json')
    $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    if ($state.runId -cne $active.runId -or $state.schemaVersion -ne 5) { throw 'Invalid state.' }
    if ($Event -eq 'subagentStop') {
        if ($payload.agentName -cne 'migration-implementer') { [Console]::Out.Write('{}'); exit 0 }
        $accepted = $state.PSObject.Properties['repair'] -and $state.repair -and $state.repair.accepted
        if ($accepted) {
            $accepted = $state.repair.accepted.fingerprint -ceq $state.repair.context.fingerprint -and $state.repair.accepted.attempt -eq $state.repair.context.attempt
        }
        if ($accepted) {
            $reportPath = Resolve-RepairPath $root $state.repair.accepted.report
            if ($reportPath.Length -ge 248 -and $reportPath -match '^[A-Za-z]:\\') { $reportPath = '\\?\' + $reportPath }
            $accepted = (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $state.repair.accepted.reportSha256
            $eventPath = Resolve-RepairPath $root ('.angular-migration/runs/' + $active.runId + '/events.jsonl')
            $registered = $false
            foreach ($line in [IO.File]::ReadLines($eventPath)) {
                $entry = $line | ConvertFrom-Json
                if ($entry.type -ceq 'repair-accepted' -and $entry.runId -ceq $active.runId -and
                    $entry.data.fingerprint -ceq $state.repair.context.fingerprint -and $entry.data.attempt -eq $state.repair.context.attempt -and
                    $entry.data.reportSha256 -ceq $state.repair.accepted.reportSha256 -and $entry.data.commit -ceq $state.repair.accepted.commit) { $registered = $true }
            }
            $accepted = $accepted -and $registered
        }
        if ($accepted) { [Console]::Out.Write('{"decision":"allow"}') }
        else { [Console]::Out.Write('{"decision":"block","reason":"Entrega repair.json y registralo mediante record-repair antes de finalizar."}') }
        exit 0
    }
    if ($state.status -cne 'needs-repair') { [Console]::Out.Write('{}'); exit 0 }
    if ((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $state.runtimeSha256) { throw 'Invalid runtime.' }
    $context = $state.repair.context
    if ($context.runId -cne $active.runId -or $context.status -cne 'needs-repair') { throw 'Invalid context.' }
    $arguments = $payload.toolArgs
    if ($arguments -is [string]) { $arguments = $arguments | ConvertFrom-Json }
    $allowed = $false
    $tool = [string]$payload.toolName
    if ($tool -in @('execute', 'powershell')) {
        $keys = @($arguments.PSObject.Properties.Name)
        if (@($keys | Where-Object { $_ -notin @('command', 'description', 'initial_wait') }).Count -eq 0 -and $keys -contains 'command') {
            $command = [string]$arguments.command
            $facade = [string]$state.repair.facadePath
            $expectedContext = "& '$facade' repair-context -RunId $($context.runId)"
            $expectedRecord = "& '$facade' record-repair -RunId $($context.runId) -InputFile '$($context.submissionPath)'"
            $allowed = ($command -ceq $expectedContext -or $command -ceq $expectedRecord) -and $facade -notmatch '[\x00-\x1f''"`;|&<>$]'
        }
    }
    elseif ($tool -in @('edit', 'create', 'read', 'view', 'search', 'grep', 'rg', 'glob')) {
        $paths = @()
        $known = @('path', 'paths', 'filePath', 'old_str', 'new_str', 'content', 'file_text', 'view_range', 'pattern', 'glob', 'output_mode', 'head_limit', '-n', 'multiline')
        if (@($arguments.PSObject.Properties.Name | Where-Object { $_ -notin $known }).Count -eq 0) {
            foreach ($name in @('path', 'paths', 'filePath')) {
                if ($arguments.PSObject.Properties[$name]) { $paths += @($arguments.$name) }
            }
            $allowed = $paths.Count -gt 0
            foreach ($path in $paths) {
                try {
                    if ($path -isnot [string]) { throw 'Invalid path.' }
                    $full = Resolve-RepairPath $root $path
                    $relative = $full.Substring($root.TrimEnd('\', '/').Length + 1).Replace('\', '/')
                    if ($tool -in @('edit', 'create')) {
                        if ($relative -cne $context.submissionPath -and -not (Test-RepairAllowedPath $relative $context)) { $allowed = $false }
                    }
                    else {
                        $credentialPattern = '(?i)(^|/)(\.npmrc|\.env[^/]*|\.ssh|\.git|id_rsa[^/]*|id_ed25519[^/]*|[^/]*\.(pem|key|pfx|p12))(/|$)'
                        if ($relative -match $credentialPattern) { $allowed = $false }
                        if (Test-Path -LiteralPath $full -PathType Container) {
                            $pending = New-Object 'Collections.Generic.Queue[string]'
                            $pending.Enqueue($full)
                            while ($pending.Count -gt 0 -and $allowed) {
                                foreach ($entry in Get-ChildItem -LiteralPath $pending.Dequeue() -Force) {
                                    if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint -or $entry.FullName.Replace('\', '/') -match $credentialPattern) { $allowed = $false; break }
                                    if ($entry.PSIsContainer) { $pending.Enqueue($entry.FullName) }
                                }
                            }
                        }
                        if ($tool -eq 'glob' -and $arguments.PSObject.Properties['pattern'] -and
                            ([string]$arguments.pattern -match '(^|[\\/])\.\.([\\/]|$)|:' -or [IO.Path]::IsPathRooted([string]$arguments.pattern))) { $allowed = $false }
                    }
                }
                catch { $allowed = $false }
            }
            if ($allowed -and $tool -in @('edit', 'create')) {
                $inventoryPath = Resolve-RepairPath $root ('.angular-migration/runs/' + $context.runId + '/inbox/edit-inventory.json')
                $inventory = @()
                if (Test-Path -LiteralPath $inventoryPath) { $inventory = @([IO.File]::ReadAllText($inventoryPath) | ConvertFrom-Json) }
                foreach ($path in $paths) {
                    $full = Resolve-RepairPath $root $path
                    if (-not (Test-Path -LiteralPath $full)) { $inventory += $full.Substring($root.Length + 1).Replace('\', '/') }
                }
                [IO.File]::WriteAllText($inventoryPath, (ConvertTo-Json -InputObject @($inventory | Sort-Object -Unique) -Compress))
            }
        }
    }
    $decision = if ($allowed) { 'allow' } else { 'deny' }
    $reason = if ($allowed) { 'angular-migration-v5: operation is inside active repair contract' } else { 'angular-migration-v5: operation outside active repair contract' }
    [Console]::Out.Write((@{ permissionDecision = $decision; permissionDecisionReason = $reason } | ConvertTo-Json -Compress))
}
catch {
    [Console]::Error.WriteLine('angular-migration-v5: policy validation failed')
    if ($Event -eq 'subagentStop') { [Console]::Out.Write('{"decision":"block","reason":"Repair registration could not be validated."}') }
    else { [Console]::Out.Write('{"permissionDecision":"deny","permissionDecisionReason":"angular-migration-v5: policy validation failed"}') }
    exit 2
}