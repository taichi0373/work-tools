# PowerShell版ALT SQLジェネレーターの動作テスト
# 使い方: .\test_alt_ps.ps1

$ErrorActionPreference = 'Stop'

# ---- コア関数をインライン定義（スクリプト本体から抜粋） ----

function Normalize-LineEndings { param([string]$Text); return $Text -replace "`r`n", "`n" -replace "`r", "`n" }

function Get-SqlParenBlock {
    param([string]$Text, [int]$Start)
    $depth = 0; $sb = [System.Text.StringBuilder]::new()
    for ($i = $Start; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($ch -eq '(') { $depth++; if ($depth -eq 1) { continue } }
        elseif ($ch -eq ')') { $depth--; if ($depth -eq 0) { break } }
        if ($depth -ge 1) { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Split-SqlValueTokens {
    param([string]$ValuesStr)
    $s = $ValuesStr.Trim()
    if ($s.StartsWith('(') -and $s.EndsWith(')')) { $s = $s.Substring(1, $s.Length - 2) }
    $tokens = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $inQuote = $false; $i = 0
    while ($i -lt $s.Length) {
        $ch = $s[$i]
        if ($ch -eq "'" -and -not $inQuote) { $inQuote = $true; [void]$current.Append($ch) }
        elseif ($ch -eq "'" -and $inQuote) {
            if (($i + 1) -lt $s.Length -and $s[$i + 1] -eq "'") { [void]$current.Append("''"); $i += 2; continue }
            $inQuote = $false; [void]$current.Append($ch)
        }
        elseif ($ch -eq ',' -and -not $inQuote) { $tokens.Add($current.ToString().Trim()); $current = [System.Text.StringBuilder]::new() }
        else { [void]$current.Append($ch) }
        $i++
    }
    if ($current.Length -gt 0 -or $tokens.Count -eq 0) { $tokens.Add($current.ToString().Trim()) }
    return @($tokens.ToArray())
}

function ConvertTo-DdlTable {
    param([string]$SqlContent)
    $sql = Normalize-LineEndings $SqlContent
    if ($sql -notmatch '(?i)CREATE\s+TABLE\s+(\w+)\s*\(') { throw "CREATE TABLE not found" }
    $tableName = $Matches[1]
    $matchObj = [regex]::Match($sql, '(?i)CREATE\s+TABLE\s+\w+\s*\(')
    $start = $matchObj.Index + $matchObj.Length - 1
    $block = Get-SqlParenBlock -Text $sql -Start $start
    $columns = [System.Collections.Generic.List[hashtable]]::new()
    $primaryKeys = [string[]]@()
    foreach ($rawLine in $block.Split("`n")) {
        $line = $rawLine.Trim().TrimEnd(',')
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '(?i)CONSTRAINT\s+\w+\s+PRIMARY\s+KEY\s*\(([^)]+)\)') {
            $primaryKeys = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() }); continue
        }
        if ($line -match '(?i)^\s*CONSTRAINT\b') { continue }
        if ($line -match '^(\w+)\s+(.+)') {
            $columns.Add(@{ Name = $Matches[1]; TypeDef = $Matches[2].Trim(); IsNotNull = [bool]($Matches[2] -match '(?i)\bNOT\s+NULL\b') })
        }
    }
    return @{ TableName = $tableName; Columns = $columns.ToArray(); PrimaryKeys = $primaryKeys; FullSql = $sql.Trim() }
}

function ConvertTo-DmlRecords {
    param([string]$SqlContent, [string[]]$Columns, [string[]]$PkColumns)
    $records = @{}
    if ([string]::IsNullOrEmpty($SqlContent)) { return $records }
    $sql = Normalize-LineEndings $SqlContent
    $pattern = [regex]::new('(?i)(?s)INSERT\s+INTO\s+\w+\s+VALUES\s*(\(.*?\))\s*;')
    foreach ($m in $pattern.Matches($sql)) {
        $values = Split-SqlValueTokens -ValuesStr $m.Groups[1].Value
        if ($values.Count -ne $Columns.Count) { throw "Column count mismatch: $($Columns.Count) vs $($values.Count)" }
        $row = @{}
        for ($i = 0; $i -lt $Columns.Count; $i++) { $row[$Columns[$i]] = $values[$i] }
        $pkKey = ($PkColumns | ForEach-Object { $row[$_] }) -join "`t"
        $records[$pkKey] = $row
    }
    return $records
}

function Get-DdlChangeType {
    param($TableName, $OldDdl, $NewDdl)
    if ($null -eq $OldDdl) { return "new_table" }
    if ($null -eq $NewDdl) { return "deleted_table" }
    if ($TableName.ToUpper() -match '_WK_') { return "wk_table" }
    $oldColNames = @($OldDdl.Columns | ForEach-Object { $_.Name })
    $newColNames = @($NewDdl.Columns | ForEach-Object { $_.Name })
    if (@($oldColNames | Where-Object { $_ -notin $newColNames }).Count -gt 0) { return "structural_change" }
    $oldColMap = @{}; $OldDdl.Columns | ForEach-Object { $oldColMap[$_.Name] = $_ }
    $newColMap = @{}; $NewDdl.Columns | ForEach-Object { $newColMap[$_.Name] = $_ }
    foreach ($name in ($oldColNames | Where-Object { $_ -in $newColNames })) {
        if ($oldColMap[$name].TypeDef -ne $newColMap[$name].TypeDef) { return "structural_change" }
    }
    if (($OldDdl.PrimaryKeys -join ',') -ne ($NewDdl.PrimaryKeys -join ',')) { return "structural_change" }
    if (@($newColNames | Where-Object { $_ -notin $oldColNames }).Count -gt 0) { return "columns_added_only" }
    return "no_change"
}

function New-DdlModifySql {
    param([string]$TableName, $OldDdl, $NewDdl)
    $oldColNames = @($OldDdl.Columns | ForEach-Object { $_.Name })
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($col in @($NewDdl.Columns | Where-Object { $_.Name -notin $oldColNames })) {
        if ($col.IsNotNull) { $lines.Add("-- WARNING: $($col.Name) is NOT NULL. Please set an appropriate default value before executing.") }
        $lines.Add("ALTER TABLE $TableName MODIFY $($col.Name) $($col.TypeDef);")
    }
    return $lines -join "`n"
}

function New-DdlBkCopySql {
    param([string]$TableName, $OldDdl, $NewDdl)
    $bkName = "${TableName}_BK"
    $oldColNames = @($OldDdl.Columns | ForEach-Object { $_.Name })
    $insertCols = [System.Collections.Generic.List[string]]::new()
    $selectExprs = [System.Collections.Generic.List[string]]::new()
    foreach ($col in $NewDdl.Columns) {
        $insertCols.Add($col.Name)
        if ($col.Name -in $oldColNames) { $selectExprs.Add($col.Name) }
        elseif ($col.IsNotNull) { $selectExprs.Add("  NULL -- WARNING: $($col.Name) is NOT NULL. Please set an appropriate default value before executing.") }
        else { $selectExprs.Add("  NULL") }
    }
    $lines = @(
        "-- existing data backup",
        "CREATE TABLE $bkName AS SELECT * FROM ${TableName};",
        "",
        "-- recreate table",
        "DROP TABLE ${TableName};",
        "",
        $NewDdl.FullSql,
        "",
        "-- restore from backup",
        "INSERT INTO ${TableName} ($($insertCols -join ', '))",
        "SELECT $($selectExprs -join ",`n")",
        "FROM ${bkName};",
        "",
        "-- drop backup",
        "DROP TABLE ${bkName};"
    )
    return $lines -join "`n"
}

function New-DdlAltSql {
    param([string]$TableName, $OldDdl, $NewDdl)
    switch (Get-DdlChangeType -TableName $TableName -OldDdl $OldDdl -NewDdl $NewDdl) {
        "new_table"          { return $NewDdl.FullSql }
        "deleted_table"      { return "DROP TABLE IF EXISTS ${TableName};" }
        "wk_table"           { return "DROP TABLE IF EXISTS ${TableName};`n`n$($NewDdl.FullSql)" }
        "columns_added_only" { return New-DdlModifySql -TableName $TableName -OldDdl $OldDdl -NewDdl $NewDdl }
        "no_change"          { return "-- ${TableName}: no structural change" }
        default              { return New-DdlBkCopySql -TableName $TableName -OldDdl $OldDdl -NewDdl $NewDdl }
    }
}

function Get-PkWhereSql {
    param([string[]]$PkColumns, [string]$PkKey)
    $pkValues = @($PkKey -split "`t")
    $parts = for ($i = 0; $i -lt $PkColumns.Count; $i++) { "$($PkColumns[$i]) = $($pkValues[$i])" }
    return $parts -join " AND "
}

function New-DmlAltSql {
    param([string]$TableName, [hashtable]$OldRecords, [hashtable]$NewRecords, [string[]]$PkColumns, [string[]]$AllColumns)
    $lines     = [System.Collections.Generic.List[string]]::new()
    $newKeyArr = @($NewRecords.Keys)
    $oldKeyArr = @($OldRecords.Keys)
    foreach ($key in @($oldKeyArr | Where-Object { $newKeyArr -notcontains $_ } | Sort-Object)) {
        $lines.Add("DELETE FROM $TableName WHERE $(Get-PkWhereSql -PkColumns $PkColumns -PkKey $key);")
    }
    foreach ($key in @($oldKeyArr | Where-Object { $newKeyArr -contains $_ } | Sort-Object)) {
        $setClauses = [System.Collections.Generic.List[string]]::new()
        foreach ($col in $AllColumns) {
            if ($col -in $PkColumns) { continue }
            $oldVal = if ($OldRecords[$key].ContainsKey($col)) { $OldRecords[$key][$col] } else { "NULL" }
            $newVal = if ($NewRecords[$key].ContainsKey($col)) { $NewRecords[$key][$col] } else { "NULL" }
            if ($oldVal -ne $newVal) { $setClauses.Add("$col = $newVal") }
        }
        if ($setClauses.Count -gt 0) { $lines.Add("UPDATE $TableName SET $($setClauses -join ', ') WHERE $(Get-PkWhereSql -PkColumns $PkColumns -PkKey $key);") }
    }
    foreach ($key in @($newKeyArr | Where-Object { $oldKeyArr -notcontains $_ } | Sort-Object)) {
        $row = $NewRecords[$key]
        $lines.Add("INSERT INTO $TableName VALUES ($( ($AllColumns | ForEach-Object { $row[$_] }) -join ', ' ));")
    }
    return $lines -join "`n"
}

# ---- テスト実行 ----
$passed = 0; $failed = 0
function Test-Contains($h, $n, $t) {
    if ($h -like "*$n*") { Write-Host "PASS: $t"; $script:passed++ }
    else { Write-Host "FAIL: $t (expected to contain: $n)"; $script:failed++ }
}
function Test-NotContains($h, $n, $t) {
    if ($h -notlike "*$n*") { Write-Host "PASS: $t"; $script:passed++ }
    else { Write-Host "FAIL: $t (should NOT contain: $n)"; $script:failed++ }
}
function Test-Equal($a, $e, $t) {
    if ($a -eq $e) { Write-Host "PASS: $t"; $script:passed++ }
    else { Write-Host "FAIL: $t`n  expected=$e`n  actual=$a"; $script:failed++ }
}

# DDL テストデータ
$DDL_BASE = @"
CREATE TABLE BENEFIT (
  BENEFIT_ID  VARCHAR(20) NOT NULL,
  NAME        VARCHAR(400),
  CONSTRAINT BENEFIT_PK PRIMARY KEY (BENEFIT_ID)
);
"@
$DDL_ADDED = @"
CREATE TABLE BENEFIT (
  BENEFIT_ID   VARCHAR(20) NOT NULL,
  NAME         VARCHAR(400),
  NEW_COL      VARCHAR(100),
  CONSTRAINT BENEFIT_PK PRIMARY KEY (BENEFIT_ID)
);
"@
$DDL_NOTNULL = @"
CREATE TABLE BENEFIT (
  BENEFIT_ID   VARCHAR(20) NOT NULL,
  NAME         VARCHAR(400),
  NEW_REQUIRED VARCHAR(50) NOT NULL,
  CONSTRAINT BENEFIT_PK PRIMARY KEY (BENEFIT_ID)
);
"@
$DDL_DELETED_COL = @"
CREATE TABLE BENEFIT (
  BENEFIT_ID  VARCHAR(20) NOT NULL,
  CONSTRAINT BENEFIT_PK PRIMARY KEY (BENEFIT_ID)
);
"@
$WK_DDL = @"
CREATE TABLE IMPORT_WK_BENEFIT (
  WK_ID VARCHAR(10) NOT NULL
);
"@

# DDL テスト
Write-Host "`n-- DDL ALT テスト --"

$old = ConvertTo-DdlTable -SqlContent $WK_DDL
$new = ConvertTo-DdlTable -SqlContent ($WK_DDL -replace "VARCHAR\(10\)", "VARCHAR(20)")
$r = New-DdlAltSql -TableName "IMPORT_WK_BENEFIT" -OldDdl $old -NewDdl $new
Test-Contains $r "DROP TABLE IF EXISTS IMPORT_WK_BENEFIT" "WK: DROP"
Test-Contains $r "CREATE TABLE IMPORT_WK_BENEFIT" "WK: CREATE"
Test-NotContains $r "IMPORT_WK_BENEFIT_BK" "WK: no BK"

$old = ConvertTo-DdlTable -SqlContent $DDL_BASE
$new = ConvertTo-DdlTable -SqlContent $DDL_ADDED
$r = New-DdlAltSql -TableName "BENEFIT" -OldDdl $old -NewDdl $new
Test-Contains $r "ALTER TABLE BENEFIT MODIFY NEW_COL VARCHAR(100)" "col add: MODIFY"
Test-NotContains $r "CREATE TABLE BENEFIT_BK" "col add: no BK"

$old = ConvertTo-DdlTable -SqlContent $DDL_BASE
$new = ConvertTo-DdlTable -SqlContent $DDL_DELETED_COL
$r = New-DdlAltSql -TableName "BENEFIT" -OldDdl $old -NewDdl $new
Test-Contains $r "CREATE TABLE BENEFIT_BK AS SELECT * FROM BENEFIT" "del col: BK"
Test-Contains $r "DROP TABLE BENEFIT;" "del col: DROP"
Test-Contains $r "INSERT INTO BENEFIT" "del col: INSERT"
Test-Contains $r "FROM BENEFIT_BK" "del col: FROM BK"
Test-Contains $r "DROP TABLE BENEFIT_BK" "del col: DROP BK"

$insertPart = ($r -split "INSERT INTO BENEFIT")[1]
Test-Contains $insertPart "BENEFIT_ID" "del col: common col in INSERT"
Test-NotContains $insertPart "NAME" "del col: deleted col not in INSERT"

$old = ConvertTo-DdlTable -SqlContent $DDL_BASE
$new = ConvertTo-DdlTable -SqlContent $DDL_NOTNULL
$r = New-DdlAltSql -TableName "BENEFIT" -OldDdl $old -NewDdl $new
Test-Contains $r "WARNING: NEW_REQUIRED is NOT NULL" "NOT NULL: warning"
Test-Contains $r "ALTER TABLE BENEFIT MODIFY NEW_REQUIRED" "NOT NULL: MODIFY"

$old = ConvertTo-DdlTable -SqlContent $DDL_BASE
$new = ConvertTo-DdlTable -SqlContent $DDL_BASE
$r = New-DdlAltSql -TableName "BENEFIT" -OldDdl $old -NewDdl $new
Test-NotContains $r "CREATE TABLE BENEFIT_BK" "no change: no BK"
Test-Contains $r "no structural change" "no change: comment"

$new = ConvertTo-DdlTable -SqlContent $DDL_BASE
$r = New-DdlAltSql -TableName "BENEFIT" -OldDdl $null -NewDdl $new
Test-Contains $r "CREATE TABLE BENEFIT" "new table: CREATE"
Test-NotContains $r "DROP TABLE" "new table: no DROP"

$old = ConvertTo-DdlTable -SqlContent $DDL_BASE
$r = New-DdlAltSql -TableName "BENEFIT" -OldDdl $old -NewDdl $null
Test-Equal $r.Trim() "DROP TABLE IF EXISTS BENEFIT;" "deleted table: DROP only"

# DML テスト
Write-Host "`n-- DML ALT テスト --"

$ddlTable = ConvertTo-DdlTable -SqlContent $DDL_BASE
$cols = @($ddlTable.Columns | ForEach-Object { $_.Name })
$pks  = $ddlTable.PrimaryKeys

$oldDml = "INSERT INTO BENEFIT VALUES ('BEN-001', 'old name');`nINSERT INTO BENEFIT VALUES ('BEN-003', 'to delete');"
$newDml = "INSERT INTO BENEFIT VALUES ('BEN-001', 'new name');`nINSERT INTO BENEFIT VALUES ('BEN-002', 'new record');"

$oldRec = ConvertTo-DmlRecords -SqlContent $oldDml -Columns $cols -PkColumns $pks
$newRec = ConvertTo-DmlRecords -SqlContent $newDml -Columns $cols -PkColumns $pks
$r = New-DmlAltSql -TableName "BENEFIT" -OldRecords $oldRec -NewRecords $newRec -PkColumns $pks -AllColumns $cols

Test-Contains $r "DELETE FROM BENEFIT WHERE BENEFIT_ID = 'BEN-003'" "DML: DELETE"
Test-Contains $r "UPDATE BENEFIT SET NAME = 'new name' WHERE BENEFIT_ID = 'BEN-001'" "DML: UPDATE"
Test-Contains $r "INSERT INTO BENEFIT VALUES ('BEN-002', 'new record')" "DML: INSERT"

# 変更なしの場合は空文字列
$sameRec = ConvertTo-DmlRecords -SqlContent $oldDml -Columns $cols -PkColumns $pks
$r = New-DmlAltSql -TableName "BENEFIT" -OldRecords $sameRec -NewRecords $sameRec -PkColumns $pks -AllColumns $cols
Test-Equal $r "" "DML no change: empty result"

Write-Host "`n=============================="
Write-Host "Results: $passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
