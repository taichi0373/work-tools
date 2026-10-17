#Requires -Version 5.1
<#
.SYNOPSIS
    ALT SQL 自動生成ツール (PowerShell版)

.DESCRIPTION
    kumamoto-henno-map プロジェクトのバージョンアップ時に必要な ALT SQL を
    Git の差分から自動生成する PowerShell スクリプトです。
    pip install 不要、Windows 標準の PowerShell で動作します。

.PARAMETER Command
    実行モード: 'version' または 'pr'

.PARAMETER Target
    バージョンモード: バージョンタグ (例: v1.1.5)
    PRモード: PR番号 (例: 42)

.PARAMETER RepoPath
    対象リポジトリのパス (デフォルト: カレントディレクトリ)

.PARAMETER OutputBase
    ALTファイル出力先ベースパス (デフォルト: {RepoPath}/config/database/Alt)

.PARAMETER GithubRepo
    GitHubリポジトリ名 owner/repo形式 (デフォルト: taichi0373/kumamoto-henno-map)

.PARAMETER GithubToken
    GitHub Personal Access Token (PRモードのみ必要。.envファイルでも設定可能)

.EXAMPLE
    .\alt_generator.ps1 version v1.1.5 -RepoPath C:\Users\ta9ns\kumamoto-henno-map

.EXAMPLE
    .\alt_generator.ps1 pr 42 -RepoPath C:\Users\ta9ns\kumamoto-henno-map
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('version', 'pr')]
    [string]$Command,

    [Parameter(Position = 1, Mandatory = $true)]
    [string]$Target,

    [string]$RepoPath    = ".",
    [string]$OutputBase  = "",
    [string]$GithubRepo  = "taichi0373/kumamoto-henno-map",
    [string]$GithubToken = ""
)

$ErrorActionPreference = 'Stop'

# ============================================================
# ユーティリティ
# ============================================================

function Normalize-LineEndings {
    param([string]$Text)
    return $Text -replace "`r`n", "`n" -replace "`r", "`n"
}

function Load-EnvFile {
    $envFile = Join-Path $PSScriptRoot ".env"
    if (-not (Test-Path $envFile)) { return }
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
            $key = $Matches[1].Trim()
            $val = $Matches[2].Trim()
            $existing = [System.Environment]::GetEnvironmentVariable($key, "Process")
            if ([string]::IsNullOrEmpty($existing)) {
                [System.Environment]::SetEnvironmentVariable($key, $val, "Process")
            }
        }
    }
}

# ============================================================
# SQL パーサー
# ============================================================

function Get-SqlParenBlock {
    <#
    .SYNOPSIS
        指定位置の ( から対応する ) までの内側テキストを返す
    #>
    param([string]$Text, [int]$Start)

    $depth = 0
    $sb = [System.Text.StringBuilder]::new()
    for ($i = $Start; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($ch -eq '(') {
            $depth++
            if ($depth -eq 1) { continue }
        }
        elseif ($ch -eq ')') {
            $depth--
            if ($depth -eq 0) { break }
        }
        if ($depth -ge 1) { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Split-SqlValueTokens {
    <#
    .SYNOPSIS
        VALUES (...) 文字列をトークン配列に分解する
        シングルクォート内のカンマは区切りとして扱わない
    #>
    param([string]$ValuesStr)

    $s = $ValuesStr.Trim()
    if ($s.StartsWith('(') -and $s.EndsWith(')')) {
        $s = $s.Substring(1, $s.Length - 2)
    }

    $tokens  = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $inQuote = $false

    $i = 0
    while ($i -lt $s.Length) {
        $ch = $s[$i]
        if ($ch -eq "'" -and -not $inQuote) {
            $inQuote = $true
            [void]$current.Append($ch)
        }
        elseif ($ch -eq "'" -and $inQuote) {
            # エスケープされたシングルクォート ''
            if (($i + 1) -lt $s.Length -and $s[$i + 1] -eq "'") {
                [void]$current.Append("''")
                $i += 2
                continue
            }
            $inQuote = $false
            [void]$current.Append($ch)
        }
        elseif ($ch -eq ',' -and -not $inQuote) {
            $tokens.Add($current.ToString().Trim())
            $current = [System.Text.StringBuilder]::new()
        }
        else {
            [void]$current.Append($ch)
        }
        $i++
    }

    if ($current.Length -gt 0 -or $tokens.Count -eq 0) {
        $tokens.Add($current.ToString().Trim())
    }

    # 単一要素のアンラップを防ぐため配列として返す
    return @($tokens.ToArray())
}

function ConvertTo-DdlTable {
    <#
    .SYNOPSIS
        DDL SQL の内容をパースして DDLTable ハッシュテーブルを返す
    .OUTPUTS
        @{
            TableName   = string
            Columns     = @(@{Name; TypeDef; IsNotNull})[]
            PrimaryKeys = string[]
            FullSql     = string
        }
    #>
    param([string]$SqlContent)

    $sql = Normalize-LineEndings $SqlContent

    if ($sql -notmatch '(?i)CREATE\s+TABLE\s+(\w+)\s*\(') {
        throw "CREATE TABLE 文が見つかりません"
    }
    $tableName = $Matches[1]

    # CREATE TABLE (...) ブロック抽出
    $matchObj = [regex]::Match($sql, '(?i)CREATE\s+TABLE\s+\w+\s*\(')
    $start    = $matchObj.Index + $matchObj.Length - 1  # '(' の位置
    $block    = Get-SqlParenBlock -Text $sql -Start $start

    $columns     = [System.Collections.Generic.List[hashtable]]::new()
    $primaryKeys = [string[]]@()

    foreach ($rawLine in $block.Split("`n")) {
        $line = $rawLine.Trim().TrimEnd(',')
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # PRIMARY KEY 制約
        if ($line -match '(?i)CONSTRAINT\s+\w+\s+PRIMARY\s+KEY\s*\(([^)]+)\)') {
            $primaryKeys = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() })
            continue
        }

        # CONSTRAINT 行 (FK など) はスキップ
        if ($line -match '(?i)^\s*CONSTRAINT\b') { continue }

        # カラム行: COLUMN_NAME TYPE_DEF...
        if ($line -match '^(\w+)\s+(.+)') {
            $colName   = $Matches[1]
            $typeDef   = $Matches[2].Trim()
            $isNotNull = ($typeDef -match '(?i)\bNOT\s+NULL\b')
            $columns.Add(@{
                Name      = $colName
                TypeDef   = $typeDef
                IsNotNull = [bool]$isNotNull
            })
        }
    }

    return @{
        TableName   = $tableName
        Columns     = $columns.ToArray()
        PrimaryKeys = $primaryKeys
        FullSql     = $sql.Trim()
    }
}

function ConvertTo-DmlRecords {
    <#
    .SYNOPSIS
        DML SQL の内容をパースしてレコードのハッシュテーブルを返す
        キー: PK カラム値をタブ区切りで連結した文字列
        値:   {カラム名: 値} のハッシュテーブル
    #>
    param(
        [string]   $SqlContent,
        [string[]] $Columns,
        [string[]] $PkColumns
    )

    $records = @{}
    if ([string]::IsNullOrEmpty($SqlContent)) { return $records }

    $sql     = Normalize-LineEndings $SqlContent
    $pattern = [regex]::new('(?i)(?s)INSERT\s+INTO\s+\w+\s+VALUES\s*(\(.*?\))\s*;')

    foreach ($m in $pattern.Matches($sql)) {
        $valuesStr = $m.Groups[1].Value
        $values    = Split-SqlValueTokens -ValuesStr $valuesStr

        if ($values.Count -ne $Columns.Count) {
            Write-Warning "カラム数 $($Columns.Count) とVALUES数 $($values.Count) が一致しません（スキップ）: $($values -join ', ')"
            continue
        }

        $row = @{}
        for ($i = 0; $i -lt $Columns.Count; $i++) {
            $row[$Columns[$i]] = $values[$i]
        }

        $pkKey = ($PkColumns | ForEach-Object { $row[$_] }) -join "`t"
        $records[$pkKey] = $row
    }

    return $records
}

# ============================================================
# DDL ALT ジェネレーター
# ============================================================

function Get-DdlChangeType {
    param($TableName, $OldDdl, $NewDdl)

    if ($null -eq $OldDdl) { return "new_table" }
    if ($null -eq $NewDdl) { return "deleted_table" }
    if ($TableName.ToUpper() -match '_WK_') { return "wk_table" }

    $oldColNames = @($OldDdl.Columns | ForEach-Object { $_.Name })
    $newColNames = @($NewDdl.Columns | ForEach-Object { $_.Name })

    # 削除カラム
    $deletedCols = @($oldColNames | Where-Object { $_ -notin $newColNames })
    if ($deletedCols.Count -gt 0) { return "structural_change" }

    # 型変更 / 制約変更
    $oldColMap = @{}; $OldDdl.Columns | ForEach-Object { $oldColMap[$_.Name] = $_ }
    $newColMap = @{}; $NewDdl.Columns | ForEach-Object { $newColMap[$_.Name] = $_ }

    foreach ($name in $oldColNames) {
        if ($name -notin $newColNames) { continue }
        if ($oldColMap[$name].TypeDef -ne $newColMap[$name].TypeDef) {
            return "structural_change"
        }
    }

    # PK 変更
    if (($OldDdl.PrimaryKeys -join ',') -ne ($NewDdl.PrimaryKeys -join ',')) {
        return "structural_change"
    }

    # 追加カラムのみ
    $addedCols = @($newColNames | Where-Object { $_ -notin $oldColNames })
    if ($addedCols.Count -gt 0) { return "columns_added_only" }

    return "no_change"
}

function New-DdlModifySql {
    param([string]$TableName, $OldDdl, $NewDdl)

    $oldColNames = @($OldDdl.Columns | ForEach-Object { $_.Name })
    $addedCols   = @($NewDdl.Columns | Where-Object { $_.Name -notin $oldColNames })

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($col in $addedCols) {
        if ($col.IsNotNull) {
            $lines.Add("-- WARNING: $($col.Name) is NOT NULL. Please set an appropriate default value before executing.")
        }
        $lines.Add("ALTER TABLE $TableName MODIFY $($col.Name) $($col.TypeDef);")
    }

    return $lines -join "`n"
}

function New-DdlBkCopySql {
    param([string]$TableName, $OldDdl, $NewDdl)

    $bkName      = "${TableName}_BK"
    $oldColNames = @($OldDdl.Columns | ForEach-Object { $_.Name })

    $insertCols  = [System.Collections.Generic.List[string]]::new()
    $selectExprs = [System.Collections.Generic.List[string]]::new()

    foreach ($col in $NewDdl.Columns) {
        $insertCols.Add($col.Name)
        if ($col.Name -in $oldColNames) {
            $selectExprs.Add($col.Name)
        }
        elseif ($col.IsNotNull) {
            $selectExprs.Add("  NULL -- WARNING: $($col.Name) is NOT NULL. Please set an appropriate default value before executing.")
        }
        else {
            $selectExprs.Add("  NULL")
        }
    }

    $colsStr   = $insertCols -join ", "
    $selectStr = $selectExprs -join ",`n"

    $lines = @(
        "-- 既存データのバックアップ",
        "CREATE TABLE $bkName AS SELECT * FROM ${TableName};",
        "",
        "-- テーブルの再作成",
        "DROP TABLE ${TableName};",
        "",
        $NewDdl.FullSql,
        "",
        "-- バックアップからデータ復元",
        "INSERT INTO ${TableName} ($colsStr)",
        "SELECT $selectStr",
        "FROM ${bkName};",
        "",
        "-- バックアップテーブルの削除",
        "DROP TABLE ${bkName};"
    )

    return $lines -join "`n"
}

function New-DdlAltSql {
    <#
    .SYNOPSIS
        DDL ALT SQL を生成して返す
        OldDdl=$null は新規テーブル、NewDdl=$null は削除テーブル
    #>
    param([string]$TableName, $OldDdl, $NewDdl)

    $changeType = Get-DdlChangeType -TableName $TableName -OldDdl $OldDdl -NewDdl $NewDdl

    switch ($changeType) {
        "new_table"          { return $NewDdl.FullSql }
        "deleted_table"      { return "DROP TABLE IF EXISTS ${TableName};" }
        "wk_table"           { return "DROP TABLE IF EXISTS ${TableName};`n`n$($NewDdl.FullSql)" }
        "columns_added_only" { return New-DdlModifySql -TableName $TableName -OldDdl $OldDdl -NewDdl $NewDdl }
        "no_change"          { return "-- ${TableName}: 構造変更なし（COMMENT ON などの変更のみ）。DDL ALT は不要です。" }
        default              { return New-DdlBkCopySql -TableName $TableName -OldDdl $OldDdl -NewDdl $NewDdl }
    }
}

# ============================================================
# DML ALT ジェネレーター
# ============================================================

function Get-PkWhereSql {
    param([string[]]$PkColumns, [string]$PkKey)
    $pkValues = @($PkKey -split "`t")
    $parts = for ($i = 0; $i -lt $PkColumns.Count; $i++) {
        "$($PkColumns[$i]) = $($pkValues[$i])"
    }
    return $parts -join " AND "
}

function New-DmlAltSql {
    <#
    .SYNOPSIS
        DML ALT SQL を生成して返す。変更なしの場合は空文字列を返す。
    #>
    param(
        [string]    $TableName,
        [hashtable] $OldRecords,
        [hashtable] $NewRecords,
        [string[]]  $PkColumns,
        [string[]]  $AllColumns
    )

    $lines      = [System.Collections.Generic.List[string]]::new()
    $newKeyArr  = @($NewRecords.Keys)
    $oldKeyArr  = @($OldRecords.Keys)

    # DELETE: 旧にあるが新にない
    $deleteKeys = @($oldKeyArr | Where-Object { $newKeyArr -notcontains $_ } | Sort-Object)
    foreach ($key in $deleteKeys) {
        $where = Get-PkWhereSql -PkColumns $PkColumns -PkKey $key
        $lines.Add("DELETE FROM $TableName WHERE $where;")
    }

    # UPDATE: 両方にあるが値が異なる
    $updateKeys = @($oldKeyArr | Where-Object { $newKeyArr -contains $_ } | Sort-Object)
    foreach ($key in $updateKeys) {
        $oldRow = $OldRecords[$key]
        $newRow = $NewRecords[$key]

        $setClauses = [System.Collections.Generic.List[string]]::new()
        foreach ($col in $AllColumns) {
            if ($col -in $PkColumns) { continue }
            $oldVal = if ($oldRow.ContainsKey($col)) { $oldRow[$col] } else { "NULL" }
            $newVal = if ($newRow.ContainsKey($col)) { $newRow[$col] } else { "NULL" }
            if ($oldVal -ne $newVal) {
                $setClauses.Add("$col = $newVal")
            }
        }

        if ($setClauses.Count -gt 0) {
            $setClause = $setClauses -join ", "
            $where     = Get-PkWhereSql -PkColumns $PkColumns -PkKey $key
            $lines.Add("UPDATE $TableName SET $setClause WHERE $where;")
        }
    }

    # INSERT: 新にあるが旧にない
    $insertKeys = @($newKeyArr | Where-Object { $oldKeyArr -notcontains $_ } | Sort-Object)
    foreach ($key in $insertKeys) {
        $row    = $NewRecords[$key]
        $values = ($AllColumns | ForEach-Object { $row[$_] }) -join ", "
        $lines.Add("INSERT INTO $TableName VALUES ($values);")
    }

    return $lines -join "`n"
}

# ============================================================
# Git 差分取得
# ============================================================

$script:DDL_PATTERN  = [regex]::new('(?i)config/database/DDL/TABLE/([A-Z0-9_]+)\.SQL')
$script:DML_PATTERN  = [regex]::new('(?i)config/database/DML/TABLE/([A-Z0-9_]+)\.SQL')
$script:VIEW_PATTERN = [regex]::new('(?i)config/database/DDL/VIEW/([A-Z0-9_]+)\.SQL')
$script:SEMVER_RE    = [regex]::new('^v(\d+)\.(\d+)\.(\d+)$')

function Get-SemverInt {
    param([string]$Tag)
    $m = $script:SEMVER_RE.Match($Tag)
    return [int]$m.Groups[1].Value * 1000000 + [int]$m.Groups[2].Value * 1000 + [int]$m.Groups[3].Value
}

function Get-PreviousVersion {
    param([string]$Version, [string[]]$Tags)

    $semverTags = @($Tags | Where-Object { $script:SEMVER_RE.IsMatch($_) })
    $semverTags = @($semverTags | Sort-Object { Get-SemverInt $_ })

    if (-not $script:SEMVER_RE.IsMatch($Version)) {
        throw "指定バージョン '$Version' は semver 形式ではありません"
    }
    $targetVal = Get-SemverInt $Version

    $previous = $null
    foreach ($tag in $semverTags) {
        if ((Get-SemverInt $tag) -lt $targetVal) {
            $previous = $tag
        }
    }

    if ($null -eq $previous) {
        throw "'$Version' の previous version が見つかりません"
    }
    return $previous
}

function Get-GitFileContent {
    <#
    .SYNOPSIS
        git show <ref>:<path> でファイル内容を取得する。失敗時は $null を返す。
    #>
    param([string]$RepoPath, [string]$Ref, [string]$FilePath)

    $output = & git -C $RepoPath show "${Ref}:${FilePath}" 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $lines = @($output | Where-Object { $_ -is [string] })
    return Normalize-LineEndings ($lines -join "`n")
}

function Get-VersionDiff {
    <#
    .SYNOPSIS
        バージョン差分を取得する
    .OUTPUTS
        @{ PreviousVersion = string; DiffFiles = hashtable[] }
    #>
    param([string]$RepoPath, [string]$Version)

    $rawTags = & git -C $RepoPath tag 2>&1
    $tags    = @($rawTags | Where-Object { $_ -is [string] -and $_ -ne '' })
    $prevVersion = Get-PreviousVersion -Version $Version -Tags $tags

    $rawDiff   = & git -C $RepoPath diff $prevVersion $Version '--name-status' 2>&1
    $diffLines = @($rawDiff | Where-Object { $_ -is [string] })

    $diffedFiles = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($line in $diffLines) {
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $parts = $line.Split("`t", 2)
        if ($parts.Count -lt 2) { continue }
        $status   = $parts[0].Trim()
        $filePath = $parts[1].Trim()

        $ddlMatch  = $script:DDL_PATTERN.Match($filePath)
        $dmlMatch  = $script:DML_PATTERN.Match($filePath)
        $viewMatch = $script:VIEW_PATTERN.Match($filePath)
        if (-not $ddlMatch.Success -and -not $dmlMatch.Success -and -not $viewMatch.Success) { continue }

        $tableName = if ($ddlMatch.Success)  { $ddlMatch.Groups[1].Value.ToUpper()  }
                     elseif ($dmlMatch.Success)  { $dmlMatch.Groups[1].Value.ToUpper()  }
                     else                        { $viewMatch.Groups[1].Value.ToUpper() }
        $sqlType   = if ($ddlMatch.Success)  { "DDL" }
                     elseif ($dmlMatch.Success)  { "DML" }
                     else                        { "VIEW" }

        $oldContent = if ($status -ne "A") { Get-GitFileContent -RepoPath $RepoPath -Ref $prevVersion -FilePath $filePath } else { $null }
        $newContent = if ($status -ne "D") { Get-GitFileContent -RepoPath $RepoPath -Ref $Version     -FilePath $filePath } else { $null }

        $diffedFiles.Add(@{
            TableName  = $tableName
            SqlType    = $sqlType
            OldContent = $oldContent
            NewContent = $newContent
        })
    }

    return @{
        PreviousVersion = $prevVersion
        DiffFiles       = $diffedFiles.ToArray()
    }
}

# ============================================================
# GitHub PR 差分取得
# ============================================================

function Get-PrDiff {
    <#
    .SYNOPSIS
        GitHub PR の変更 SQL ファイルリストを返す
    .OUTPUTS
        hashtable[]
    #>
    param(
        [string] $RepoPath,
        [int]    $PrNumber,
        [string] $GithubToken,
        [string] $GithubRepo
    )

    $headers = @{
        "Authorization" = "Bearer $GithubToken"
        "Accept"        = "application/vnd.github.v3+json"
        "User-Agent"    = "alt-generator-ps/1.0"
    }

    # PR 情報取得
    $prInfo  = Invoke-RestMethod -Uri "https://api.github.com/repos/$GithubRepo/pulls/$PrNumber" -Headers $headers
    $baseSha = $prInfo.base.sha
    $headSha = $prInfo.head.sha

    # 変更ファイル取得（ページネーション対応）
    $allFiles = [System.Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $batch = @(Invoke-RestMethod -Uri "https://api.github.com/repos/$GithubRepo/pulls/$PrNumber/files?per_page=100&page=$page" -Headers $headers)
        foreach ($f in $batch) { $allFiles.Add($f) }
        $page++
    } while ($batch.Count -eq 100)

    $diffedFiles = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($file in $allFiles) {
        $filePath = $file.filename
        $status   = $file.status  # "added", "modified", "removed", "renamed"

        $ddlMatch  = $script:DDL_PATTERN.Match($filePath)
        $dmlMatch  = $script:DML_PATTERN.Match($filePath)
        $viewMatch = $script:VIEW_PATTERN.Match($filePath)
        if (-not $ddlMatch.Success -and -not $dmlMatch.Success -and -not $viewMatch.Success) { continue }

        $tableName = if ($ddlMatch.Success)      { $ddlMatch.Groups[1].Value.ToUpper()  }
                     elseif ($dmlMatch.Success)  { $dmlMatch.Groups[1].Value.ToUpper()  }
                     else                        { $viewMatch.Groups[1].Value.ToUpper() }
        $sqlType   = if ($ddlMatch.Success)      { "DDL" }
                     elseif ($dmlMatch.Success)  { "DML" }
                     else                        { "VIEW" }

        $oldContent = if ($status -ne "added")   { Get-GitFileContent -RepoPath $RepoPath -Ref $baseSha -FilePath $filePath } else { $null }
        $newContent = if ($status -ne "removed") { Get-GitFileContent -RepoPath $RepoPath -Ref $headSha -FilePath $filePath } else { $null }

        $diffedFiles.Add(@{
            TableName  = $tableName
            SqlType    = $sqlType
            OldContent = $oldContent
            NewContent = $newContent
        })
    }

    return @{
        BaseSha   = $baseSha
        HeadSha   = $headSha
        DiffFiles = $diffedFiles.ToArray()
    }
}

# ============================================================
# ファイル入出力
# ============================================================

function Write-AltFile {
    param([string]$OutputDir, [string]$TableName, [string]$Sql)

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    $outputPath = Join-Path $OutputDir "Alt_${TableName}.SQL"
    $encoding   = [System.Text.UTF8Encoding]::new($false)  # BOM なし UTF-8
    [System.IO.File]::WriteAllText($outputPath, $Sql, $encoding)
    Write-Host "生成: $outputPath"
}

function Read-DiskDdl {
    param([string]$RepoPath, [string]$TableName)

    $ddlPath = Join-Path $RepoPath "config\database\DDL\TABLE\${TableName}.SQL"
    if (-not (Test-Path $ddlPath)) {
        Write-Warning "DDLファイルが見つかりません: $ddlPath"
        return $null
    }
    $content = [System.IO.File]::ReadAllText($ddlPath, [System.Text.Encoding]::UTF8)
    return ConvertTo-DdlTable -SqlContent $content
}

# ============================================================
# 差分処理メイン
# ============================================================

function Invoke-ProcessDiffFiles {
    param(
        [hashtable[]] $DiffFiles,
        [string]      $RepoPath,
        [string]      $OutputBase,
        [string]      $Identifier,
        [string]      $Version     = "",
        [string]      $PrevVersion = ""
    )

    $basePath = Join-Path $OutputBase $Identifier

    # ---- DDL 差分処理 ----
    $oldDdlMap = @{}
    $newDdlMap = @{}

    foreach ($df in @($DiffFiles | Where-Object { $_.SqlType -eq "DDL" })) {
        $oldDdl = if ($null -ne $df.OldContent) { ConvertTo-DdlTable -SqlContent $df.OldContent } else { $null }
        $newDdl = if ($null -ne $df.NewContent) { ConvertTo-DdlTable -SqlContent $df.NewContent } else { $null }

        $oldDdlMap[$df.TableName] = $oldDdl
        $newDdlMap[$df.TableName] = $newDdl

        $sql = New-DdlAltSql -TableName $df.TableName -OldDdl $oldDdl -NewDdl $newDdl
        Write-AltFile -OutputDir (Join-Path $basePath "DDL\TABLE") -TableName $df.TableName -Sql $sql
    }

    # ---- VIEW 差分処理 ----
    foreach ($df in @($DiffFiles | Where-Object { $_.SqlType -eq "VIEW" })) {
        if ($null -eq $df.NewContent) {
            # VIEW削除の場合
            $sql = "DROP VIEW IF EXISTS $($df.TableName);"
        }
        else {
            # CREATE OR REPLACE VIEW をそのまま出力
            $sql = $df.NewContent.Trim()
        }
        Write-AltFile -OutputDir (Join-Path $basePath "DDL\VIEW") -TableName $df.TableName -Sql $sql
    }

    # ---- DML 差分処理 ----
    foreach ($df in @($DiffFiles | Where-Object { $_.SqlType -eq "DML" })) {
        $oldDdlTable = $null
        $newDdlTable = $null

        if ($oldDdlMap.ContainsKey($df.TableName)) {
            # DDL も同時に変更された場合: 差分から取得した旧/新 DDL を使用
            $oldDdlTable = $oldDdlMap[$df.TableName]
            $newDdlTable = $newDdlMap[$df.TableName]
        }
        elseif ($Version -ne "" -and $PrevVersion -ne "") {
            # DDL が差分に含まれない場合: git show で各バージョンの DDL を取得
            $ddlRel = "config/database/DDL/TABLE/$($df.TableName).SQL"
            try {
                $oldContent = Get-GitFileContent -RepoPath $RepoPath -Ref $PrevVersion -FilePath $ddlRel
                $newContent = Get-GitFileContent -RepoPath $RepoPath -Ref $Version     -FilePath $ddlRel
                if ($null -ne $oldContent) { $oldDdlTable = ConvertTo-DdlTable -SqlContent $oldContent }
                if ($null -ne $newContent) { $newDdlTable = ConvertTo-DdlTable -SqlContent $newContent }
            }
            catch {
                Write-Warning "git から DDL を取得できません ($_)。ディスクを使用します。"
                $diskDdl     = Read-DiskDdl -RepoPath $RepoPath -TableName $df.TableName
                $oldDdlTable = $diskDdl
                $newDdlTable = $diskDdl
            }
        }
        else {
            # PR モードで DDL が変更されていない場合: ディスクから取得
            $diskDdl     = Read-DiskDdl -RepoPath $RepoPath -TableName $df.TableName
            $oldDdlTable = $diskDdl
            $newDdlTable = $diskDdl
        }

        if ($null -eq $oldDdlTable -or $null -eq $newDdlTable) {
            Write-Warning "$($df.TableName) の DDL が取得できませんでした。スキップします。"
            continue
        }

        $oldColumns = @($oldDdlTable.Columns | ForEach-Object { $_.Name })
        $newColumns = @($newDdlTable.Columns | ForEach-Object { $_.Name })
        $pkColumns  = $newDdlTable.PrimaryKeys

        $oldSqlContent = if ($null -ne $df.OldContent) { $df.OldContent } else { "" }
        $newSqlContent = if ($null -ne $df.NewContent) { $df.NewContent } else { "" }

        $oldRecords = ConvertTo-DmlRecords -SqlContent $oldSqlContent -Columns $oldColumns -PkColumns $pkColumns
        $newRecords = ConvertTo-DmlRecords -SqlContent $newSqlContent -Columns $newColumns -PkColumns $pkColumns

        # 旧レコードを新カラム構造に揃える（追加カラムは NULL で補完）
        $alignedOld = @{}
        foreach ($key in $oldRecords.Keys) {
            $row        = $oldRecords[$key]
            $alignedRow = @{}
            foreach ($col in $newColumns) {
                $alignedRow[$col] = if ($row.ContainsKey($col)) { $row[$col] } else { "NULL" }
            }
            $alignedOld[$key] = $alignedRow
        }

        $sql = New-DmlAltSql -TableName $df.TableName -OldRecords $alignedOld -NewRecords $newRecords -PkColumns $pkColumns -AllColumns $newColumns
        if (-not [string]::IsNullOrEmpty($sql)) {
            Write-AltFile -OutputDir (Join-Path $basePath "DML") -TableName $df.TableName -Sql $sql
        }
    }
}

# ============================================================
# エントリーポイント
# ============================================================

Load-EnvFile

$RepoPath = (Resolve-Path $RepoPath).Path

if ($Command -eq "version") {
    if ([string]::IsNullOrEmpty($OutputBase)) {
        $OutputBase = Join-Path $PSScriptRoot "output"
    }

    $result    = Get-VersionDiff -RepoPath $RepoPath -Version $Target
    $prevVer   = $result.PreviousVersion
    $diffFiles = @($result.DiffFiles)
    Write-Host "差分: $prevVer → $Target ($($diffFiles.Count) ファイル)"

    if ($diffFiles.Count -eq 0) {
        Write-Host "ALT対象の差分がありません。" -ForegroundColor Yellow
        exit 0
    }

    Invoke-ProcessDiffFiles `
        -DiffFiles    $diffFiles `
        -RepoPath     $RepoPath `
        -OutputBase   $OutputBase `
        -Identifier   $Target `
        -Version      $Target `
        -PrevVersion  $prevVer
}
elseif ($Command -eq "pr") {
    if ([string]::IsNullOrEmpty($OutputBase)) {
        $OutputBase = Join-Path $PSScriptRoot "output"
    }

    $token = $GithubToken
    if ([string]::IsNullOrEmpty($token)) {
        $token = [System.Environment]::GetEnvironmentVariable("GITHUB_TOKEN", "Process")
    }
    if ([string]::IsNullOrEmpty($token)) {
        Write-Error "GITHUB_TOKEN が設定されていません (.env ファイルを確認してください)"
        exit 1
    }

    $prNum      = [int]$Target
    $prResult   = Get-PrDiff -RepoPath $RepoPath -PrNumber $prNum -GithubToken $token -GithubRepo $GithubRepo
    $baseSha    = $prResult.BaseSha
    $headSha    = $prResult.HeadSha
    $diffFiles  = @($prResult.DiffFiles)
    $identifier = "PR-$prNum"
    Write-Host "PR #${prNum}: $($diffFiles.Count) ファイルの差分 (base: $($baseSha.Substring(0,7)), head: $($headSha.Substring(0,7)))"

    if ($diffFiles.Count -eq 0) {
        Write-Host "ALT対象の差分がありません。" -ForegroundColor Yellow
        exit 0
    }

    Invoke-ProcessDiffFiles `
        -DiffFiles   $diffFiles `
        -RepoPath    $RepoPath `
        -OutputBase  $OutputBase `
        -Identifier  $identifier `
        -PrevVersion $baseSha `
        -Version     $headSha
}
