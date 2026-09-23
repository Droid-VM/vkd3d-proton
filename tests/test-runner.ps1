# Windows counterpart of test-runner.sh: runs tests/d3d12.exe one test per process with a timeout.
# Rows are appended to <Out>\results.csv as tests finish, so an interrupted run resumes where it stopped.
# A test that was started but never finished (the guest went down under it) is recorded as LOST and not
# retried, so a test that kills the machine cannot do it twice; rerun it on purpose with -Match.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test-runner.ps1 -Dir C:\path\to\arm64 [-Jobs 2]
#
# -Dir holds d3d12.exe plus, for an app-local run, vkd3d-proton's d3d12.dll / d3d12core.dll and a dxgi.dll;
# without them the same exe goes through the system d3d12.dll and the installed driver.
param(
    [string]$Dir = $PSScriptRoot,
    [string]$Out = '',
    [int]$Timeout = 120,
    [int]$Jobs = 1,
    [string]$Match = '',
    [switch]$Stress,
    [switch]$Summary
)
$ErrorActionPreference = 'Stop'
if (-not $Out) { $Out = Join-Path $Dir 'results' }
$exe = Join-Path $Dir 'd3d12.exe'
$logs = Join-Path $Out 'logs'
$csv = Join-Path $Out 'results.csv'
$started = Join-Path $Out 'started.txt'
New-Item -ItemType Directory -Force $logs | Out-Null
$counts = '(\d+) tests executed \((\d+) failures, (\d+) successful todo, (\d+) skipped, (\d+) todo, (\d+) bugs\)'

function New-Row([string]$test, [string]$status) {
    [ordered]@{ test = $test; status = $status; exit = ''; executed = ''; failures = ''; skipped = ''; todo = '';
        bugs = ''; seconds = ''; detail = '' }
}

function Save-Result($run, [string]$status) {
    $log = Join-Path $logs "$($run.Test).log"
    $row = New-Row $run.Test $status
    $row.seconds = [math]::Round(([DateTime]::UtcNow - $run.Start).TotalSeconds, 1)
    if ($status -ne 'TIMEOUT') {
        $row.exit = '0x{0:X}' -f $run.Proc.ExitCode
        $m = Select-String -Path $log -Pattern $counts | Select-Object -Last 1
        if ($m) {
            $g = $m.Matches[0].Groups
            $row.executed = $g[1].Value; $row.failures = $g[2].Value; $row.skipped = $g[4].Value
            $row.todo = $g[5].Value; $row.bugs = $g[6].Value
            $row.status = if ([int]$g[2].Value -gt 0 -or $run.Proc.ExitCode -ne 0) { 'FAIL' } else { 'PASS' }
        } else {
            $row.status = 'CRASH'
        }
    }
    $first = Select-String -Path $log -Pattern 'Test failed' | Select-Object -First 1
    if ($first) { $row.detail = $first.Line.Substring(0, [math]::Min(160, $first.Line.Length)) }
    [pscustomobject]$row | Export-Csv -Path $csv -Append -NoTypeInformation -Encoding UTF8
    '{0,-8} {1,6}s  {2}' -f $row.status, $row.seconds, $run.Test
}

if (-not $Summary) {
    $done = @{}
    if (Test-Path $csv) { Import-Csv $csv | ForEach-Object { $done[$_.test] = $true } }
    if (Test-Path $started) {
        foreach ($test in Get-Content $started) {
            if ($test -and -not $done.ContainsKey($test)) {
                $row = New-Row $test 'LOST'
                $row.detail = 'started but never finished: the previous run ended under it'
                [pscustomobject]$row | Export-Csv -Path $csv -Append -NoTypeInformation -Encoding UTF8
                $done[$test] = $true
            }
        }
    }
    $tests = @(& $exe --list-tests | Where-Object { $_ -and -not $done.ContainsKey($_) })
    if (-not $Stress) { $tests = @($tests | Where-Object { $_ -notmatch 'stress' }) }
    if ($Match) { $tests = @($tests | Where-Object { $_ -match $Match }) }
    "{0} tests to run in {1}, {2} job(s), {3}s timeout" -f $tests.Count, $Dir, $Jobs, $Timeout
    # Same as test-runner.sh: the disk cache thread can keep a PSO alive and make test_object_interface flaky.
    $env:VKD3D_SHADER_CACHE_PATH = '0'
    $queue = [System.Collections.Queue]::new($tests)
    $running = [System.Collections.ArrayList]::new()
    while ($queue.Count -or $running.Count) {
        while ($running.Count -lt $Jobs -and $queue.Count) {
            $test = $queue.Dequeue()
            Add-Content -Path $started -Value $test
            $env:VKD3D_TEST_MATCH = $test
            $proc = Start-Process -FilePath $exe -WorkingDirectory $Dir -NoNewWindow -PassThru `
                -RedirectStandardOutput (Join-Path $logs "$test.log") -RedirectStandardError (Join-Path $logs "$test.err")
            $null = $proc.Handle  # keeps ExitCode readable after the process is gone
            [void]$running.Add([pscustomobject]@{ Test = $test; Proc = $proc; Start = [DateTime]::UtcNow })
        }
        Start-Sleep -Milliseconds 100
        foreach ($run in @($running)) {
            if ($run.Proc.HasExited) {
                Save-Result $run 'DONE'
            } elseif (([DateTime]::UtcNow - $run.Start).TotalSeconds -gt $Timeout) {
                try { $run.Proc.Kill() } catch { }
                $run.Proc.WaitForExit()
                Save-Result $run 'TIMEOUT'
            } else {
                continue
            }
            $running.Remove($run)
        }
    }
}

$rows = @(Import-Csv $csv)
''
'== {0} tests, {1}' -f $rows.Count, $Dir
$rows | Group-Object status | Sort-Object Name | ForEach-Object { '{0,-8} {1}' -f $_.Name, $_.Count }
$sum = { param($f) ($rows | Where-Object { $_.$f } | Measure-Object -Property $f -Sum).Sum }
'checks: {0} executed, {1} failures, {2} skipped, {3} todo, {4} bugs; {5}s total' -f (& $sum executed),
    (& $sum failures), (& $sum skipped), (& $sum todo), (& $sum bugs), (& $sum seconds)
$rows | Where-Object status -ne 'PASS' | Sort-Object status, test |
    ForEach-Object { '{0,-8} {1} {2}' -f $_.status, $_.test, $_.detail }
