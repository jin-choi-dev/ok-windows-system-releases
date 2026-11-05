param(
    [Parameter(Mandatory)][ValidateSet('Fresh', 'ManualUpgrade', 'HelperUpgrade')][string]$Scenario,
    [Parameter(Mandatory)][string]$CandidateInstaller,
    [string]$BaselineInstaller
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# This script installs software. It must never run against a personal PC.
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Requires a disposable GitHub-hosted Windows runner.'
}
if ($env:GITHUB_REPOSITORY -ne 'jin-choi-dev/ok-windows-system-releases') {
    throw 'Unexpected QA repository.'
}
$candidateHash = 'C88409B64FE8F54908B9641E37F0190EBC2C34E62B5ADE56A8470A72AA588DBF'
$baselineHash = '3EC592F233D74E28CB2179A732820D3754B537E4074C73DE321E031B6F014EA2'
$appName = 'OK사업단 보험센터'
$appDirectory = Join-Path $env:ProgramFiles 'OKInsuranceCenter'
$appExe = Join-Path $appDirectory ($appName + '.exe')
$dataDirectory = Join-Path $env:LOCALAPPDATA $appName
$orderDirectory = Join-Path $env:LOCALAPPDATA 'InsurancePortal'
$resultDirectory = Join-Path $env:RUNNER_TEMP ('ok-installer-' + $Scenario)
$checks = [Collections.Generic.List[object]]::new()
New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null

function Assert-QA([bool]$Condition, [string]$Name) {
    $checks.Add([pscustomobject]@{Name=$Name;Passed=$Condition})
    if (!$Condition) { throw "FAILED: $Name" }
    Write-Host "PASS $Name"
}
function Test-InstallerHash([string]$Path, [string]$Hash) {
    Assert-QA ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Hash) ('Installer SHA256 ' + (Split-Path $Path -Leaf))
}
function Install-QA([string]$Path, [string]$Stage) {
    $logPath = Join-Path $resultDirectory ($Stage + '.log')
    $process = Start-Process -FilePath $Path -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/TASKS=desktopicon',('/LOG="' + $logPath + '"')) -PassThru -WindowStyle Hidden
    Assert-QA ($process.WaitForExit(180000)) ($Stage + ' installer finishes within 180 seconds')
    Assert-QA ($process.ExitCode -eq 0) ($Stage + ' installer exit code 0')
}
function Get-ProductProcesses {
    @(Get-Process -Name $appName -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $appExe })
}
function Start-QAApp {
    $process = Start-Process -FilePath $appExe -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 4
    $process.Refresh()
    Assert-QA (!$process.HasExited) 'Installed app remains running after startup'
    return $process
}
function Close-QAApp($Process) {
    $Process.Refresh()
    if (!$Process.HasExited) {
        Assert-QA ($Process.CloseMainWindow()) 'App accepts normal close request'
        Assert-QA ($Process.WaitForExit(20000)) 'App exits normally within 20 seconds'
    }
}
function Assert-Installed([string]$Version) {
    Assert-QA (Test-Path -LiteralPath $appExe) 'Product executable installed in Program Files'
    Assert-QA ((Get-Item -LiteralPath $appExe).VersionInfo.FileVersion -eq ($Version + '.0')) ('Installed file version ' + $Version)
    $key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{A6E55E6A-7E91-4A7C-A9A8-0F6D3D0A0C11}_is1'
    Assert-QA ((Get-ItemProperty -LiteralPath $key).DisplayVersion -eq $Version) ('Uninstall registry version ' + $Version)
    Assert-QA (Test-Path -LiteralPath (Join-Path $appDirectory ('app_icon_' + $Version + '.ico'))) 'Versioned shortcut icon installed'
    Assert-QA (!(Test-Path -LiteralPath (Join-Path $appDirectory ($appName + '.r2r.dll')))) 'No legacy composite R2R image'
    $shell = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $shortcutPath = Join-Path $desktop ($appName + '.lnk')
    Assert-QA (Test-Path -LiteralPath $shortcutPath) 'Desktop shortcut exists'
    $shortcut = $shell.CreateShortcut($shortcutPath)
    Assert-QA ($shortcut.TargetPath -eq $appExe) 'Desktop shortcut targets installed executable'
    Assert-QA ($shortcut.IconLocation -like ('*app_icon_' + $Version + '.ico*')) 'Desktop shortcut uses current version icon'
}
function Write-Fixtures {
    New-Item -ItemType Directory -Path $dataDirectory,$orderDirectory -Force | Out-Null
    $settings = [ordered]@{ThemeId='purple';CustomThemeColor='#ABCDEF';IsTopmost=$true;IsMemoEnabled=$false;MemoText='QA legacy fixture';MainWindowHeight=720;MemoMode=0}
    $note = [ordered]@{
        Id='b893ae58-cdcb-49e2-b632-e2e893a6b4c5';Text="QA preservation fixture`nNot customer data";ColorKey='Blue';IsTopmost=$true;IsCollapsed=$false;IsOpen=$false
        Placement=@{Left=$null;Top=$null;Width=320;Height=360;Monitor=$null;RelativeLeft=$null;RelativeTop=$null;RelativeWidth=$null;RelativeHeight=$null}
        ModifiedAt=[DateTimeOffset]::UtcNow.ToString('o');DeletedAt=$null
    }
    [ordered]@{FormatVersion=1;Notes=@($note);Workspace=$null} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $dataDirectory 'notes.json') -Encoding utf8
    $settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dataDirectory 'settings.dat') -Encoding utf8
    [ordered]@{Version=1;Links=@(@{Id='4dc306e3-82b4-4bd1-901b-ec63ee1ba899';Name='QA link';Url='https://example.com/'})} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $dataDirectory 'custom-links.json') -Encoding utf8
    @('흥국화재','삼성화재') | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $orderDirectory 'order_nonlife.json') -Encoding utf8
}
function Read-Fixtures {
    [ordered]@{
        Settings=(Get-Content -LiteralPath (Join-Path $dataDirectory 'settings.dat') -Raw | ConvertFrom-Json)
        Notes=(Get-Content -LiteralPath (Join-Path $dataDirectory 'notes.json') -Raw | ConvertFrom-Json).Notes
        LinksHash=(Get-FileHash -LiteralPath (Join-Path $dataDirectory 'custom-links.json')).Hash
        OrderHash=(Get-FileHash -LiteralPath (Join-Path $orderDirectory 'order_nonlife.json')).Hash
    }
}
function Assert-Fixtures($Before, $After) {
    foreach ($name in @('ThemeId','CustomThemeColor','IsTopmost','MemoText')) {
        Assert-QA ($Before.Settings.$name -ceq $After.Settings.$name) ('Preserved setting ' + $name)
    }
    # Windows work-area clamping can legitimately change MainWindowHeight.
    Assert-QA ($After.Settings.MainWindowHeight -gt 0) 'Saved window height remains valid'
    Assert-QA (($Before.Notes | ConvertTo-Json -Depth 20 -Compress) -ceq ($After.Notes | ConvertTo-Json -Depth 20 -Compress)) 'All note fields preserved'
    Assert-QA ($Before.LinksHash -ceq $After.LinksHash) 'Custom links file hash preserved'
    Assert-QA ($Before.OrderHash -ceq $After.OrderHash) 'Company order file hash preserved'
}

try {
    Assert-QA (!(Test-Path -LiteralPath $appExe)) 'Disposable VM has no existing product installation'
    Assert-QA (!(Test-Path -LiteralPath $dataDirectory)) 'Disposable VM has no existing product data'
    Test-InstallerHash $CandidateInstaller $candidateHash
    if ($Scenario -eq 'Fresh') {
        Install-QA $CandidateInstaller 'fresh-1.2.8'
        Assert-Installed '1.2.8'
        $process = Start-QAApp
        Close-QAApp $process
    } else {
        Test-InstallerHash $BaselineInstaller $baselineHash
        Install-QA $BaselineInstaller 'baseline-1.2.3'
        Assert-Installed '1.2.3'
        Write-Fixtures
        $before = Read-Fixtures
        $oldProcess = Start-QAApp
        if ($Scenario -eq 'ManualUpgrade') {
            Close-QAApp $oldProcess
            Install-QA $CandidateInstaller 'manual-1.2.8'
            $newProcess = Start-QAApp
        } else {
            $helper = Join-Path $appDirectory 'UpdateHelper.exe'
            $helperLog = Join-Path $env:TEMP 'UpdateHelper.log'
            Assert-QA (Test-Path -LiteralPath $helper) 'Original installed UpdateHelper exists'
            $helperProcess = Start-Process -FilePath $helper -ArgumentList @('--installer',('"'+$CandidateInstaller+'"'),'--restart',('"'+$appExe+'"')) -PassThru -WindowStyle Hidden
            Assert-QA ($helperProcess.WaitForExit(15000)) 'Original UpdateHelper exits promptly to release file locks'
            $deadline = [DateTime]::UtcNow.AddSeconds(200)
            $newProcess = $null
            do {
                Start-Sleep -Seconds 2
                $oldProcess.Refresh()
                $running = @(Get-ProductProcesses | Where-Object {$_.Id -ne $oldProcess.Id})
                if ($oldProcess.HasExited -and $running.Count -eq 1 -and (Get-Item -LiteralPath $appExe).VersionInfo.FileVersion -eq '1.2.8.0') {
                    $newProcess = $running[0]
                    break
                }
            } while ([DateTime]::UtcNow -lt $deadline)
            Assert-QA ($null -ne $newProcess) 'Helper upgrades 1.2.3 and automatically restarts 1.2.8 with a new PID'
            $log = Get-Content -LiteralPath $helperLog -Raw
            Assert-QA ($log.Contains('Installer launched PID=') -and !$log.Contains('failed:')) 'Original helper log confirms installer launch without failure'
        }
        Start-Sleep -Seconds 4
        Assert-Installed '1.2.8'
        Close-QAApp $newProcess
        $after = Read-Fixtures
        Assert-Fixtures $before $after
        $restart = Start-QAApp
        Close-QAApp $restart
        Assert-Fixtures $after (Read-Fixtures)
    }
    $status = 'passed'
} catch {
    $status = 'failed'
    Write-Output $_.ToString()
    throw
} finally {
    $result = [ordered]@{Scenario=$Scenario;Status=$status;OS=[Environment]::OSVersion.VersionString;CandidateSHA256=$candidateHash;Checks=@($checks.ToArray());Scope='Installer and original UpdateHelper; not production manifest UI or Smart App Control acceptance'}
    $json = $result | ConvertTo-Json -Depth 10
    $json | Set-Content -LiteralPath (Join-Path $resultDirectory 'result.json') -Encoding utf8
    Write-Output $json
    if ($env:GITHUB_STEP_SUMMARY) {
        "## $Scenario : $status`n`n``````json`n$json`n```````n" | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
    }
    Get-ChildItem -LiteralPath $resultDirectory -Filter '*.log' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Tail 25 }
}
