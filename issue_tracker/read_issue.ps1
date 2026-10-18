#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IssueNo
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# 列インデックス定数（0-based）
# ---------------------------------------------------------------------------
$COL_A = 0   # 課題No
$COL_F = 5   # 業務
$COL_G = 6   # 画面/処理
$COL_I = 8   # 事象詳細
$COL_M = 12  # 対応者
$COL_N = 13  # 対応状況
$COL_O = 14  # 対応期限
$COL_T = 19  # プルリク番号

# ---------------------------------------------------------------------------
# Get-GoogleAccessToken
# ---------------------------------------------------------------------------
function Get-GoogleAccessToken {
    param(
        [string]$ClientSecretPath,
        [string]$TokenStorePath,
        [string[]]$Scopes
    )

    $json         = Get-Content -Path $ClientSecretPath -Raw | ConvertFrom-Json
    $clientId     = $json.installed.client_id
    $clientSecret = $json.installed.client_secret
    $tokenUri     = 'https://oauth2.googleapis.com/token'
    $redirectUri  = 'http://localhost:8765/callback'

    # --- 保存済みリフレッシュトークンがあれば使う ---
    if (Test-Path $TokenStorePath) {
        $stored = Get-Content -Path $TokenStorePath -Raw | ConvertFrom-Json
        if ($stored.refresh_token) {
            try {
                $body = "client_id=$clientId" +
                        "&client_secret=$clientSecret" +
                        "&refresh_token=$($stored.refresh_token)" +
                        "&grant_type=refresh_token"
                $response = Invoke-RestMethod -Uri $tokenUri -Method Post `
                    -ContentType 'application/x-www-form-urlencoded' -Body $body
                return $response.access_token
            }
            catch {
                Write-Host "リフレッシュトークンが無効です。再認証します..." -ForegroundColor Yellow
            }
        }
    }

    # --- 初回: ブラウザで認証 ---
    $scope       = [Uri]::EscapeDataString($Scopes -join ' ')
    $encodedUri  = [Uri]::EscapeDataString($redirectUri)
    $authUrl     = "https://accounts.google.com/o/oauth2/auth" +
                   "?client_id=$clientId" +
                   "&redirect_uri=$encodedUri" +
                   "&scope=$scope" +
                   "&response_type=code" +
                   "&access_type=offline" +
                   "&prompt=consent"

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add('http://localhost:8765/')
    $listener.Start()

    Write-Host "ブラウザが開きます。Googleアカウントでログインしてください..." -ForegroundColor Cyan
    Start-Process $authUrl

    $context = $listener.GetContext()

    $query  = $context.Request.Url.Query.TrimStart('?')
    $params = @{}
    foreach ($pair in $query.Split('&')) {
        $kv = $pair.Split('=', 2)
        if ($kv.Count -eq 2) {
            $params[$kv[0]] = [Uri]::UnescapeDataString($kv[1].Replace('+', ' '))
        }
    }
    $authCode = $params['code']

    $html  = '<html><meta charset="utf-8"><body><h2>認証完了。このウィンドウを閉じてください。</h2></body></html>'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
    $context.Response.ContentType = 'text/html; charset=utf-8'
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.Close()
    $listener.Stop()

    if (-not $authCode) {
        Write-Error "認証コードを取得できませんでした。"
    }

    $body = "code=$authCode" +
            "&client_id=$clientId" +
            "&client_secret=$clientSecret" +
            "&redirect_uri=$encodedUri" +
            "&grant_type=authorization_code"
    $response = Invoke-RestMethod -Uri $tokenUri -Method Post `
        -ContentType 'application/x-www-form-urlencoded' -Body $body

    $tokenDir = Split-Path -Parent $TokenStorePath
    if (-not (Test-Path $tokenDir)) {
        New-Item -ItemType Directory -Path $tokenDir | Out-Null
    }
    @{ refresh_token = $response.refresh_token } | ConvertTo-Json | `
        Set-Content -Path $TokenStorePath -Encoding UTF8

    Write-Host "認証情報を保存しました: $TokenStorePath" -ForegroundColor Green
    return $response.access_token
}

# ---------------------------------------------------------------------------
# Get-SheetValues
# ---------------------------------------------------------------------------
function Get-SheetValues {
    param(
        [string]$SpreadsheetId,
        [string]$AccessToken,
        [string]$SheetName,
        [string]$Range
    )

    $encodedRange = [Uri]::EscapeDataString("$SheetName!$Range")
    $uri = "https://sheets.googleapis.com/v4/spreadsheets/$SpreadsheetId/values/$encodedRange"
    $response = Invoke-RestMethod `
        -Uri $uri `
        -Method Get `
        -Headers @{ Authorization = "Bearer $AccessToken" }

    if ($null -eq $response.values) {
        return @()
    }
    return $response.values
}

# ---------------------------------------------------------------------------
# Get-CellValue
# ---------------------------------------------------------------------------
function Get-CellValue {
    param(
        [object[]]$Row,
        [int]$Index
    )

    if ($null -eq $Row -or $Index -ge $Row.Count) {
        return ''
    }
    return [string]$Row[$Index]
}

# ---------------------------------------------------------------------------
# メイン処理
# ---------------------------------------------------------------------------
try {
    # 1. config.json 読み込み
    $ConfigPath = Join-Path $PSScriptRoot 'config.json'
    if (-not (Test-Path $ConfigPath)) {
        Write-Error "config.json が見つかりません: $ConfigPath"
    }
    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

    # 2. OAuth 認証
    $tokenStorePath = Join-Path $PSScriptRoot 'credentials\token.json'
    $scopes = @('https://www.googleapis.com/auth/spreadsheets.readonly')
    $accessToken = Get-GoogleAccessToken `
        -ClientSecretPath $config.oauthClientSecretPath `
        -TokenStorePath $tokenStorePath `
        -Scopes $scopes

    # 3. 課題管理シート全行取得（1行目はヘッダーとしてスキップ）
    $allValues = Get-SheetValues `
        -SpreadsheetId $config.sourceSpreadsheetId `
        -AccessToken $accessToken `
        -SheetName $config.sourceSheetName `
        -Range 'A:T'

    if ($allValues.Count -le 1) {
        Write-Error "課題管理シートにデータ行がありません。"
    }

    $dataRows = $allValues[1..($allValues.Count - 1)]

    # 4. 課題番号が一致する行を検索
    $targetRow = $null
    foreach ($row in $dataRows) {
        $cellA = Get-CellValue -Row $row -Index $COL_A
        if ($cellA -eq $IssueNo) {
            $targetRow = $row
            break
        }
    }

    if ($null -eq $targetRow) {
        Write-Error "課題No '$IssueNo' が見つかりませんでした。"
    }

    # 5. JSON 出力
    $result = [ordered]@{
        '課題No'      = Get-CellValue -Row $targetRow -Index $COL_A
        '業務'        = Get-CellValue -Row $targetRow -Index $COL_F
        '画面処理'    = Get-CellValue -Row $targetRow -Index $COL_G
        '事象詳細'    = Get-CellValue -Row $targetRow -Index $COL_I
        '対応者'      = Get-CellValue -Row $targetRow -Index $COL_M
        '対応状況'    = Get-CellValue -Row $targetRow -Index $COL_N
        '対応期限'    = Get-CellValue -Row $targetRow -Index $COL_O
        'プルリク番号' = Get-CellValue -Row $targetRow -Index $COL_T
    }

    $result | ConvertTo-Json -Depth 3
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
