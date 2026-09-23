# run_all.ps1 -- run every headless test driver and report PASS/FAIL per test.
# Gate: build.ps1 -All (size budgets) must pass first, else stop. Then each
# run_*.ps1 in $tests runs in its own child pwsh (so a script's `exit` can't kill
# the runner), sequentially (they share the one DOSBox + cc.com/scratch files).
# Output of each goes to _testlogs\<name>.log; verdict = child exit code
# (0 = pass). run_cc.ps1 is interactive and deliberately NOT in the list.
#   -Only <pattern> : run only tests whose name matches (wildcards ok; bare
#                     text = substring), e.g. -Only hex  /  -Only 'run_t*'
#   -ShowLog        : echo the log of every failing test after the summary
param(
    [string]$Only = "",
    [switch]$ShowLog
)
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\DOS\cc"
$logs = "$dir\_testlogs"
New-Item -ItemType Directory -Path $logs -Force | Out-Null

# explicit list (alphabetical, repo-root relative). run_test.ps1 = generic
# driver: /D smoke that asserts the first frame (panels, footer, prompt, F-key bar).
# wincc\run_test.ps1 = Windows console port suite (no DOSBox).
$tests = @(
    "run_attr.ps1", "run_configurator.ps1", "run_czip_safety.ps1", "run_discover.ps1",
    "run_editor.ps1", "run_fileops_safety.ps1", "run_find.ps1", "run_grep.ps1",
    "run_grepresults.ps1", "run_hex.ps1", "run_hexed.ps1", "run_hexview.ps1",
    "run_img.ps1", "run_lfn.ps1", "run_parsers_safety.ps1", "run_results.ps1",
    "run_safety.ps1", "run_test.ps1", "run_test_edit.ps1", "run_tools.ps1", "run_tools_menu.ps1",
    "run_toolsini.ps1", "run_touch.ps1", "run_vedit.ps1",
    "run_wav.ps1", "run_zip.ps1",
    "wincc\run_test.ps1"
)
if ($Only -ne "") {
    $pat = if ($Only -match '[\*\?\[]') { $Only } else { "*$Only*" }
    $tests = @($tests | Where-Object { $_ -like $pat })
    if ($tests.Count -eq 0) { Write-Host "no test matches -Only '$Only'"; exit 1 }
}

function Run-One([string]$name, [string[]]$extra) {
    $log = Join-Path $logs (($name -replace '[\\/]', '_') -replace '\.ps1$', '.log')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Push-Location $dir
    try { & pwsh -NoProfile -File "$dir\$name" @extra *> $log; $ec = $LASTEXITCODE }
    finally { Pop-Location }
    $sw.Stop()
    return [pscustomobject]@{ Name=$name; Exit=$ec; Secs=$sw.Elapsed.TotalSeconds; Log=$log }
}

# ---- budget gate --------------------------------------------------------------
$b = Run-One "build.ps1" @("-All")
if ($b.Exit -ne 0) {
    Write-Host ("BUILD GATE FAIL (exit {0}) -- see {1}" -f $b.Exit, $b.Log)
    if ($ShowLog) { Get-Content $b.Log | Write-Host }
    exit 1
}
Write-Host ("BUILD GATE PASS  {0,5:N1}s" -f $b.Secs)

# ---- tests --------------------------------------------------------------------
$t0 = Get-Date
$results = foreach ($t in $tests) {
    $r = Run-One $t @()
    Write-Host ("{0,-4} {1,-24} {2,5:N1}s{3}" -f $(if ($r.Exit -eq 0) {"PASS"} else {"FAIL"}), $t, $r.Secs,
        $(if ($r.Exit -ne 0) { "  (exit $($r.Exit))" } else { "" }))
    $r
}
$failed = @($results | Where-Object { $_.Exit -ne 0 })
$total  = ((Get-Date) - $t0).TotalSeconds

Write-Host ""
Write-Host ("SUMMARY: {0} passed, {1} failed, {2} total in {3:N0}s   (logs: {4})" -f
    ($results.Count - $failed.Count), $failed.Count, $results.Count, $total, $logs)
if ($failed.Count -gt 0) {
    Write-Host ("FAILED : " + (($failed | ForEach-Object Name) -join ", "))
    if ($ShowLog) {
        foreach ($f in $failed) {
            Write-Host "`n===== $($f.Name) (exit $($f.Exit)) ====="
            Get-Content $f.Log | Write-Host
        }
    }
    exit 1
}
exit 0
