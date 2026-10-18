#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [switch]$Scheduled   # タスクスケジューラからの実行時に指定。前週シート名を自動計算する
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
#   OAuth 2.0 ユーザー認証。初回はブラウザでログイン、以降はリフレッシュトークンで自動更新。
#   トークンは $TokenStorePath に保存される。
# ---------------------------------------------------------------------------
function Get-GoogleAccessToken {
    param(
        [string]$ClientSecretPath,
        [string]$TokenStorePath,
        [string[]]$Scopes
    )

    $json        = Get-Content -Path $ClientSecretPath -Raw | ConvertFrom-Json
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

    # ローカルHTTPリスナーでコールバックを受け取る
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add('http://localhost:8765/')
    $listener.Start()

    Write-Host "ブラウザが開きます。Googleアカウントでログインしてください..." -ForegroundColor Cyan
    Start-Process $authUrl

    $context = $listener.GetContext()

    # クエリ文字列から code を取得
    $query  = $context.Request.Url.Query.TrimStart('?')
    $params = @{}
    foreach ($pair in $query.Split('&')) {
        $kv = $pair.Split('=', 2)
        if ($kv.Count -eq 2) {
            $params[$kv[0]] = [Uri]::UnescapeDataString($kv[1].Replace('+', ' '))
        }
    }
    $authCode = $params['code']

    # ブラウザに完了メッセージを返す
    $html = '<html><meta charset="utf-8"><body><h2>認証完了。このウィンドウを閉じてください。</h2></body></html>'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
    $context.Response.ContentType = 'text/html; charset=utf-8'
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.Close()
    $listener.Stop()

    if (-not $authCode) {
        Write-Error "認証コードを取得できませんでした。"
    }

    # 認証コード → アクセストークン + リフレッシュトークン
    $body = "code=$authCode" +
            "&client_id=$clientId" +
            "&client_secret=$clientSecret" +
            "&redirect_uri=$encodedUri" +
            "&grant_type=authorization_code"
    $response = Invoke-RestMethod -Uri $tokenUri -Method Post `
        -ContentType 'application/x-www-form-urlencoded' -Body $body

    # リフレッシュトークンを保存
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
# Get-SheetRowsWithFormatting
#   spreadsheets.get?includeGridData=true でセル値と書式を同時に取得する。
#   返り値: rowData の配列（各要素に .values[] が含まれ、
#           values[n].userEnteredValue.stringValue と
#           values[n].effectiveFormat.textFormat.strikethrough が使える）
# ---------------------------------------------------------------------------
function Get-SheetRowsWithFormatting {
    param(
        [string]$SpreadsheetId,
        [string]$AccessToken,
        [string]$SheetName,
        [string]$Range
    )

    $encodedRange = [Uri]::EscapeDataString("$SheetName!$Range")
    $uri = "https://sheets.googleapis.com/v4/spreadsheets/$SpreadsheetId" +
           "?ranges=$encodedRange&includeGridData=true" +
           "&fields=sheets.data.rowData.values(userEnteredValue,userEnteredFormat.textFormat.strikethrough,effectiveFormat.textFormat.strikethrough)"

    $response = Invoke-RestMethod `
        -Uri $uri `
        -Method Get `
        -Headers @{ Authorization = "Bearer $AccessToken" }

    $rowData = $response.sheets[0].data[0].rowData
    if ($null -eq $rowData) { return @() }
    return $rowData
}

# ---------------------------------------------------------------------------
# Get-PreviousWeekExcludedNumbers
#   前週シートの行データ（書式付き）から「取り消し線あり」の課題番号を収集する。
#   収集した番号は今週のTSV出力から除外するために使う。
#   - B列(index 0): 対応者名でフィルタ
#   - D列(index 2): 取り消し線ありの行の課題番号を収集
# ---------------------------------------------------------------------------
function Get-PreviousWeekExcludedNumbers {
    param(
        [object[]]$PreviousSheetRows,
        [string[]]$TargetPersons
    )

    $numbers = @()
    $currentPerson = ''
    foreach ($rowData in $PreviousSheetRows) {
        if ($null -eq $rowData.values) { continue }
        $cells = $rowData.values

        # B列(index 0): 対応者名
        # 結合セルのため値があるのは先頭行のみ。空の場合は直前の担当者名を引き継ぐ
        if ($cells.Count -gt 0 -and $null -ne $cells[0].userEnteredValue) {
            $bValue = [string]$cells[0].userEnteredValue.stringValue
            if ($bValue -ne '') { $currentPerson = $bValue }
        }
        if ($currentPerson -notin $TargetPersons) { continue }

        # D列(index 2): 課題番号を取得
        if ($cells.Count -le 2) { continue }
        $dCell = $cells[2]

        $content = ''
        if ($null -ne $dCell.userEnteredValue) {
            $content = [string]$dCell.userEnteredValue.stringValue
        }
        if ($content -notmatch 'No\.(\d+)：') { continue }

        # 取り消し線ありの課題番号を除外リストに追加
        $strikethrough = $dCell.effectiveFormat.textFormat.strikethrough -eq $true -or
                         $dCell.userEnteredFormat.textFormat.strikethrough -eq $true
        if ($strikethrough) {
            $numbers += $Matches[1]
        }
    }
    return ,$numbers  # カンマで配列のまま返す（PS5.1での展開防止）
}

# ---------------------------------------------------------------------------
# Select-IssuesToWrite
# ---------------------------------------------------------------------------
function Select-IssuesToWrite {
    param(
        [object[]]$SourceRows,
        [string[]]$ExcludedIssueNumbers,
        [string[]]$TargetPersons,
        [datetime]$CutoffDate
    )

    $excludedStatuses = @('対応完了', '対応不要', '保留')
    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $SourceRows) {
        $person = Get-CellValue -Row $row -Index $COL_M
        if ($person -notin $TargetPersons) { continue }

        $issueNo = Get-CellValue -Row $row -Index $COL_A

        # 前週シートで取り消し線がついていた課題は除外
        if ($ExcludedIssueNumbers -contains $issueNo) { continue }

        # 対応状況が対応完了・対応不要・保留は除外
        $status = Get-CellValue -Row $row -Index $COL_N
        if ($excludedStatuses -contains $status) { continue }

        # 対応期限が未設定または締切日より後の課題は除外
        $deadline = Get-CellValue -Row $row -Index $COL_O
        if ($deadline -eq '') { continue }
        $deadlineDate = $null
        try { $deadlineDate = [datetime]::Parse($deadline) } catch { continue }
        if ($deadlineDate -gt $CutoffDate) { continue }

        $result.Add($row)
    }

    return $result.ToArray()
}

# ---------------------------------------------------------------------------
# Export-ToTsv
#   出力形式（タブ区切り、2列）:
#     列1: No.{A}：【{F}】{G} {I}
#     列2: 対応期限（O列）
#
#   Sheetsに貼り付ける際の色分け参考用として、先頭に状態マーカーを付与:
#     [完了] 対応完了（グレー+取り消し線）
#     [PR]   プルリク番号あり（グレー）
#     （なし）未対応（黒）
# ---------------------------------------------------------------------------
function Export-ToTsv {
    param(
        [object[]]$Issues,
        [string]$OutputPath
    )

    $lines = [System.Collections.Generic.List[string]]::new()

    foreach ($row in $Issues) {
        $issueNo  = Get-CellValue -Row $row -Index $COL_A
        $business = Get-CellValue -Row $row -Index $COL_F
        $screen   = Get-CellValue -Row $row -Index $COL_G
        $detail   = Get-CellValue -Row $row -Index $COL_I
        $status   = Get-CellValue -Row $row -Index $COL_N
        $deadline = Get-CellValue -Row $row -Index $COL_O

        $col1 = "　└ No.${issueNo}：【${business}】${screen} ${detail}"
        $col2 = $deadline

        $lines.Add("$col1`t$col2")
    }

    $outputDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir | Out-Null
    }

    # BOM付きUTF-8で保存（Excelやメモ帳で文字化けしないよう）
    [System.IO.File]::WriteAllLines($OutputPath, $lines, [System.Text.UTF8Encoding]::new($true))
}

# ---------------------------------------------------------------------------
# メイン処理
# ---------------------------------------------------------------------------
try {
    # 1. config.json 読み込み
    if ($ConfigPath -eq '') {
        $ConfigPath = Join-Path $PSScriptRoot 'config.json'
    }

    if (-not (Test-Path $ConfigPath)) {
        Write-Host "エラー: config.json が見つかりません。" -ForegroundColor Red
        Write-Host "config.json.example をコピーして config.json を作成し、各IDを設定してください。" -ForegroundColor Yellow
        exit 1
    }

    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

    # バリデーション
    $required = @(
        'sourceSpreadsheetId', 'previousWeekSpreadsheetId',
        'sourceSheetName', 'oauthClientSecretPath', 'targetPersons'
    )
    foreach ($key in $required) {
        if (-not $config.PSObject.Properties[$key]) {
            Write-Error "config.json に '$key' が見つかりません。"
        }
    }

    Write-Host "設定読み込み完了" -ForegroundColor Cyan

    # 2. OAuth認証
    Write-Host "Google認証中..." -ForegroundColor Cyan
    $tokenStorePath = Join-Path $PSScriptRoot 'credentials\token.json'
    $scopes = @('https://www.googleapis.com/auth/spreadsheets.readonly')
    $accessToken = Get-GoogleAccessToken `
        -ClientSecretPath $config.oauthClientSecretPath `
        -TokenStorePath $tokenStorePath `
        -Scopes $scopes
    Write-Host "認証完了" -ForegroundColor Green

    # 3. 担当者リストを先に確定
    $targetPersons = @($config.targetPersons)

    # 4. 前週シート名の決定 → 取得 → 不正な場合は再入力（手動実行時のみ）
    $defaultSheetName = (Get-Date).AddDays(-7).ToString('yyyyMMdd')
    $excludedIssueNumbers = $null

    do {
        if ($Scheduled) {
            $previousWeekSheetName = $defaultSheetName
            Write-Host "前週シート名（自動）: $previousWeekSheetName" -ForegroundColor Cyan
        } else {
            $userInput = Read-Host "前週シート名を入力してください [Enter で $defaultSheetName]"
            $previousWeekSheetName = if ($userInput -ne '') { $userInput } else { $defaultSheetName }
            Write-Host "前週シート名: $previousWeekSheetName" -ForegroundColor Cyan
        }

        try {
            Write-Host "共有進捗管理シートから前週課題番号を取得中..." -ForegroundColor Cyan
            $prevRows = Get-SheetRowsWithFormatting `
                -SpreadsheetId $config.previousWeekSpreadsheetId `
                -AccessToken $accessToken `
                -SheetName $previousWeekSheetName `
                -Range 'B:E'
            $excludedIssueNumbers = @(Get-PreviousWeekExcludedNumbers -PreviousSheetRows $prevRows -TargetPersons $targetPersons)
            Write-Host "前週取り消し線あり（除外）: $($excludedIssueNumbers.Count) 件" -ForegroundColor Cyan
        }
        catch {
            Write-Host "シート '$previousWeekSheetName' が見つかりません。" -ForegroundColor Red
            if ($Scheduled) { exit 1 }
            $excludedIssueNumbers = $null
        }
    } while ($null -eq $excludedIssueNumbers)

    # 6. 課題管理シート全行取得（1行目はヘッダーとしてスキップ）
    Write-Host "課題管理シートを取得中..." -ForegroundColor Cyan
    $sourceValues = Get-SheetValues `
        -SpreadsheetId $config.sourceSpreadsheetId `
        -AccessToken $accessToken `
        -SheetName $config.sourceSheetName `
        -Range 'A:T'

    if ($sourceValues.Count -le 1) {
        Write-Host "課題管理シートにデータ行がありません。" -ForegroundColor Yellow
        exit 0
    }

    $sourceRows = $sourceValues[1..($sourceValues.Count - 1)]
    Write-Host "課題管理シート: $($sourceRows.Count) 行" -ForegroundColor Cyan

    # 7. 締切日の入力（スケジュール実行時は当日から2週間後をデフォルト）
    $defaultCutoff = (Get-Date).AddDays(14).ToString('yyyyMMdd')
    $cutoffDate = $null
    do {
        if ($Scheduled) {
            $cutoffInput = $defaultCutoff
        } else {
            $cutoffInput = Read-Host "抽出する対応期限の上限を入力してください [Enter で $defaultCutoff]"
            if ($cutoffInput -eq '') { $cutoffInput = $defaultCutoff }
        }
        $cutoffDate = $null
        try {
            $cutoffDate = [datetime]::ParseExact($cutoffInput, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
        } catch {
            Write-Host "日付の形式が正しくありません。YYYYMMDDで入力してください。" -ForegroundColor Red
            if ($Scheduled) { exit 1 }
        }
    } while ($null -eq $cutoffDate)
    Write-Host "対応期限の上限: $($cutoffDate.ToString('yyyy/MM/dd'))" -ForegroundColor Cyan

    # 8. 担当者フィルタ・状況フィルタ・期限フィルタ + 前週差分除外
    $issuesToWrite = Select-IssuesToWrite `
        -SourceRows $sourceRows `
        -ExcludedIssueNumbers $excludedIssueNumbers `
        -TargetPersons $targetPersons `
        -CutoffDate $cutoffDate

    Write-Host "出力対象: $($issuesToWrite.Count) 件" -ForegroundColor Cyan

    if ($issuesToWrite.Count -eq 0) {
        Write-Host "出力対象の課題がありません。" -ForegroundColor Yellow
        exit 0
    }

    # 9. TSVファイルに出力
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmm'
    $outputPath = Join-Path $PSScriptRoot "output\issues_${timestamp}.tsv"
    Export-ToTsv -Issues $issuesToWrite -OutputPath $outputPath

    Write-Host "完了: $($issuesToWrite.Count) 件を出力しました" -ForegroundColor Green
    Write-Host "出力ファイル: $outputPath" -ForegroundColor Green
    Write-Host ""
    Write-Host "【Sheetsへの貼り付け手順】" -ForegroundColor Yellow
    Write-Host "  1. 上記ファイルをメモ帳で開く" -ForegroundColor Yellow
    Write-Host "  2. Ctrl+A → Ctrl+C でコピー" -ForegroundColor Yellow
    Write-Host "  3. 共有進捗管理シートの貼り付けたいセルを選択" -ForegroundColor Yellow
    Write-Host "  4. Ctrl+V で貼り付け（タブ区切りで列が分かれます）" -ForegroundColor Yellow
    Write-Host "  ※ 書式（グレー文字、取り消し線など）は手動で適用してください" -ForegroundColor Yellow
}
catch {
    Write-Host "エラー: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
