#Requires -Version 5.1
<#
.SYNOPSIS
    ALT SQL 自動生成ツール 対話型ランチャー
    run_alt_generator.bat からダブルクリックで起動する用
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$PSScriptPath = Join-Path $PSScriptRoot "alt_generator.ps1"

# --- .env 読み込み ---
$envFile = Join-Path $PSScriptRoot ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
            $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
            if ([string]::IsNullOrEmpty([System.Environment]::GetEnvironmentVariable($k, "Process"))) {
                [System.Environment]::SetEnvironmentVariable($k, $v, "Process")
            }
        }
    }
}

$githubRepo  = [System.Environment]::GetEnvironmentVariable("GITHUB_REPO",  "Process")
$defaultRepo = [System.Environment]::GetEnvironmentVariable("REPO_PATH", "Process")

# --- PR番号の存在確認（open / closed / merged すべて対象）---
function Test-PrExists {
    param([string]$PrNumber, [string]$GithubRepo)
    $token = [System.Environment]::GetEnvironmentVariable("GITHUB_TOKEN", "Process")
    if ([string]::IsNullOrEmpty($token)) { return $true }  # トークン未設定時はスキップ
    try {
        $headers = @{
            "Authorization" = "Bearer $token"
            "Accept"        = "application/vnd.github.v3+json"
            "User-Agent"    = "alt-generator-ps/1.0"
        }
        # issues エンドポイントは state に関係なく PR を返す
        $issue = Invoke-RestMethod -Uri "https://api.github.com/repos/$GithubRepo/issues/$PrNumber" -Headers $headers
        # PR でない issue（通常の Issue）を除外
        return $null -ne $issue.pull_request
    }
    catch {
        return $false
    }
}

# --- バージョンタグの存在確認 ---
function Test-VersionExists {
    param([string]$Version, [string]$RepoPath)
    $tags = & git -C $RepoPath tag 2>&1
    return @($tags | Where-Object { $_ -eq $Version }).Count -gt 0
}

Write-Host "============================================"
Write-Host " ALT SQL 自動生成ツール"
Write-Host "============================================"
Write-Host ""

# --- モード選択 ---
Write-Host "実行モードを選んでください:"
Write-Host "  1. バージョン指定モード (例: v1.1.5)"
Write-Host "  2. PR番号モード          (例: 42)"
Write-Host ""

while ($true) {
    $modeChoice = Read-Host "番号を入力してください (1 or 2)"
    if ($modeChoice -eq "1" -or $modeChoice -eq "2") { break }
    Write-Host "無効な入力です。1 または 2 を入力してください。" -ForegroundColor Red
}

# --- リポジトリパス入力 ---
Write-Host ""
while ($true) {
    if ([string]::IsNullOrEmpty($defaultRepo)) {
        $repoInput = Read-Host "リポジトリのパスを入力してください"
    } else {
        $repoInput = Read-Host "リポジトリのパスを入力してください (Enter でデフォルト: $defaultRepo)"
    }
    if ([string]::IsNullOrWhiteSpace($repoInput)) {
        if ([string]::IsNullOrEmpty($defaultRepo)) {
            Write-Host "パスを入力してください。.env の REPO_PATH にデフォルトを設定できます。" -ForegroundColor Yellow
            continue
        }
        $repoPath = $defaultRepo
        break
    }
    if (Test-Path $repoInput) {
        $repoPath = $repoInput
        break
    }
    Write-Host "指定されたパスが見つかりません。再度入力してください。" -ForegroundColor Red
}

# --- バージョン / PR番号入力 ---
Write-Host ""
if ($modeChoice -eq "1") {
    while ($true) {
        $target = Read-Host "バージョンを入力してください (例: v1.1.5)"
        if ([string]::IsNullOrWhiteSpace($target)) {
            Write-Host "バージョンが入力されていません。再度入力してください。" -ForegroundColor Red
            continue
        }
        Write-Host "タグ $target を確認中..." -ForegroundColor Cyan
        if (Test-VersionExists -Version $target -RepoPath $repoPath) { break }
        Write-Host "タグ '$target' がリポジトリに見つかりません。バージョンを確認して再度入力してください。" -ForegroundColor Red
    }
    $command = "version"
}
else {
    while ($true) {
        $target = Read-Host "PR番号を入力してください (例: 42)"
        if ([string]::IsNullOrWhiteSpace($target)) {
            Write-Host "PR番号が入力されていません。再度入力してください。" -ForegroundColor Red
            continue
        }
        if ($target -notmatch '^\d+$') {
            Write-Host "PR番号は数値で入力してください。" -ForegroundColor Red
            continue
        }
        Write-Host "PR #$target を確認中..." -ForegroundColor Cyan
        if (Test-PrExists -PrNumber $target -GithubRepo $githubRepo) { break }
        Write-Host "PR #$target が見つかりません。番号を確認して再度入力してください。" -ForegroundColor Red
    }
    $command = "pr"
}

# --- 実行確認 ---
Write-Host ""
Write-Host "============================================"
Write-Host "実行内容:"
Write-Host "  モード    : $command"
Write-Host "  対象      : $target"
Write-Host "  リポジトリ: $repoPath"
Write-Host "============================================"
Write-Host ""

# --- 実行 ---
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSScriptPath $command $target -RepoPath $repoPath -GithubRepo $githubRepo
    Write-Host ""
    Write-Host "完了しました。" -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "エラーが発生しました: $_" -ForegroundColor Red
    exit 1
}
