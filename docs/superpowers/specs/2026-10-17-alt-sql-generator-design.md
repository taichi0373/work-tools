# ALT SQL 自動生成ツール 設計書

**日付:** 2026-10-17
**対象プロジェクト:** kumamoto-henno-map (`taichi0373/kumamoto-henno-map`)
**リポジトリ配置:** `C:\Users\ta9ns\work_tools\alt_generator\`

---

## 1. 目的・背景

バージョンアップリリース時、既に稼働中の環境のDBを安全にバージョンアップするためのSQL資産（ALT）を、毎回手動で作成している。これを自動化し、作業コストと人的ミスを削減する。

**ALTとは：** 既存DBのテーブル構造とデータを、前バージョンから新バージョンへ安全に移行するためのSQLファイル群。

---

## 2. ゴール・非ゴール・アンチゴール

### ゴール
- Gitの差分（PR間 or バージョンタグ間）を自動検出し、ALT SQLファイルを生成する
- DDL差分：テーブル構造変更のSQLを生成（WKテーブル／マスタテーブルで戦略を分ける）
- DML差分：データ変更のSQLを生成（INSERT / UPDATE / DELETE）

### 非ゴール
- SQLをDBに対して実行すること
- VIEWの変更対応（TABLEのみ対象）
- PostgreSQL以外のDB対応

### アンチゴール
- BKテーブルなしで既存データを破壊するDDLを生成すること

---

## 3. 対象プロジェクトのSQL仕様

**DDLファイル例（`DDL/TABLE/BENEFIT.SQL`）:**
```sql
CREATE TABLE BENEFIT (
  BENEFIT_ID  VARCHAR(20) NOT NULL,
  ...
  CONSTRAINT BENEFIT_PK PRIMARY KEY (BENEFIT_ID),
  CONSTRAINT BENEFIT_FK_MUNICIPALITY FOREIGN KEY (MUNICIPALITY_CD) REFERENCES MUNICIPALITY (MUNICIPALITY_CD)
);
COMMENT ON TABLE BENEFIT IS '...';
COMMENT ON COLUMN BENEFIT.BENEFIT_ID IS '...';
```

**DMLファイル例（`DML/TABLE/BENEFIT.SQL`）:**
```sql
INSERT INTO BENEFIT VALUES ('BEN-000001', '43', 'TR001', '...', ..., CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
```
- カラム名なしのポジショナル形式 (`INSERT INTO TABLE VALUES (...)`)
- カラム順はDDLの定義順に対応

**ファイル構成:**
```
config/database/
  DDL/TABLE/{TABLE_NAME}.SQL
  DML/TABLE/{TABLE_NAME}.SQL
```

---

## 4. 機能仕様

### 機能1：PRベースのALT生成

**入力:** GitHubのPR番号
**処理:**
1. GitHub API経由でPRの変更ファイルリストを取得
2. DDL/DML配下のSQLファイルを対象として抽出
3. PRのベースブランチ（旧）とHEAD（新）のSQLファイルを取得
4. ALT SQLを生成

**出力先:**
```
config/database/Alt/PR-{PR番号}/DDL/Alt_{テーブル名}.SQL
config/database/Alt/PR-{PR番号}/DML/Alt_{テーブル名}.SQL
```

---

### 機能2：バージョン間のALT生成

**入力:** バージョンタグ（例: `v1.1.5`）
**処理:**
1. 指定バージョンの直前のタグを自動検出（例: `v1.1.4`）
2. 2つのタグ間でGit差分を取得
3. DDL/DML配下のSQLファイルを対象として抽出
4. ALT SQLを生成

**出力先:**
```
config/database/Alt/{バージョン}/DDL/Alt_{テーブル名}.SQL
config/database/Alt/{バージョン}/DML/Alt_{テーブル名}.SQL
```

---

### 5. DDL ALT 生成ロジック

#### WKテーブル（ファイル名に `_WK_` を含む）
WKテーブルは一時作業用テーブルのため、既存データの保全不要。

```sql
-- Alt_TABLE_WK_NAME.SQL
DROP TABLE IF EXISTS TABLE_WK_NAME;

CREATE TABLE TABLE_WK_NAME (
  ...
);
```

#### マスタテーブル（`_WK_` を含まない通常テーブル）— カラム追加のみの変更

旧DDLと新DDLを比較し、**カラムが追加されただけ**（削除・型変更・制約変更なし）の場合は `ALTER TABLE ... MODIFY` を使用する。

```sql
-- Alt_BENEFIT.SQL
ALTER TABLE BENEFIT MODIFY NEW_COLUMN VARCHAR(100);
ALTER TABLE BENEFIT MODIFY ANOTHER_COLUMN DATE;
```

複数カラムが追加された場合は `MODIFY` 文を追加カラム分だけ並べる。
`NOT NULL` 制約付きの新規カラムは以下の形式で警告コメントを出力する：

```sql
-- WARNING: NEW_COLUMN is NOT NULL. Please set an appropriate default value before executing.
ALTER TABLE BENEFIT MODIFY NEW_COLUMN VARCHAR(100) NOT NULL;
```

#### マスタテーブル（`_WK_` を含まない通常テーブル）— 構造変更（カラム削除・型変更・制約変更など）

カラムの削除・型変更・制約変更など、`MODIFY` で対応できない構造変更がある場合は BKコピー方式を使用する。

```sql
-- Alt_BENEFIT.SQL
-- 既存データのバックアップ
CREATE TABLE BENEFIT_BK AS SELECT * FROM BENEFIT;

-- テーブルの再作成
DROP TABLE BENEFIT;

CREATE TABLE BENEFIT (
  BENEFIT_ID  VARCHAR(20) NOT NULL,
  ...
  CONSTRAINT BENEFIT_PK PRIMARY KEY (BENEFIT_ID),
  ...
);

COMMENT ON TABLE BENEFIT IS '...';
COMMENT ON COLUMN BENEFIT.BENEFIT_ID IS '...';

-- バックアップからデータ復元（共通カラムのみ）
INSERT INTO BENEFIT (col1, col2, ...)
SELECT col1, col2, ...
FROM BENEFIT_BK;

-- バックアップテーブルの削除
DROP TABLE BENEFIT_BK;
```

**共通カラムの判定:** 旧DDLと新DDLを比較し、両方に存在するカラム名を `INSERT INTO ... SELECT ...` に使用する。
**削除カラム:** 無視（BKには残るがINSERT対象から除外）。

#### DDL変更の種別判定ロジック

| 変更内容 | 判定 | 生成するSQL |
|---------|------|-----------|
| カラム追加のみ | MODIFY方式 | `ALTER TABLE ... MODIFY ...` |
| カラム削除あり | BKコピー方式 | CREATE BK → DROP → CREATE → INSERT FROM BK |
| カラム型変更あり | BKコピー方式 | 同上 |
| 制約変更あり（PK/FK/NOT NULL） | BKコピー方式 | 同上 |
| 新規テーブル | CREATEのみ | `CREATE TABLE ...` |
| テーブル削除 | DROPのみ | `DROP TABLE IF EXISTS ...` |

---

### 6. DML ALT 生成ロジック

**前提:** DMLファイルは全て `INSERT INTO TABLE VALUES (...)` 形式。

**処理ステップ:**

1. 対応するDDLから主キーカラム名とカラム順序を取得
2. 旧バージョンのDMLをパースし、PKをキーとしたレコードマップを作成
3. 新バージョンのDMLをパースし、PKをキーとしたレコードマップを作成
4. 差分を判定して各SQL文を生成

**差分判定ルール:**

| 状態 | 生成SQL |
|------|---------|
| 旧にあり新にもあり、値が異なる | `UPDATE TABLE SET col=val, ... WHERE pk=val;` |
| 旧にあるが新にない | `DELETE FROM TABLE WHERE pk=val;` |
| 旧にないが新にある | `INSERT INTO TABLE VALUES (...);` |
| 旧にも新にも同じ値 | 生成しない |

**主キーが複合の場合:** `WHERE pk1=val1 AND pk2=val2` の形式

---

## 7. ファイル名規則

| 種別 | ファイル名 |
|------|-----------|
| DDL ALT | `Alt_{TABLE_NAME}.SQL` |
| DML ALT | `Alt_{TABLE_NAME}.SQL` |

テーブル名はDDLファイル名の大文字スネークケース（`BENEFIT.SQL` → `Alt_BENEFIT.SQL`）

---

## 8. 実装方針

**言語:** PowerShell 5.1+（Windows標準、pip install 不要）
**配置先:** `C:\Users\ta9ns\work_tools\alt_generator\`

**依存ライブラリ:** なし（外部ライブラリ不要）
- Git操作 — `git.exe` コマンドを呼び出し（PATH に通っていること）
- GitHub API — `Invoke-RestMethod`（PowerShell標準）
- 環境変数 — `.env` ファイルを起動時に読み込み

**CLIインターフェース:**
```powershell
# 機能1: PRベース
.\alt_generator.ps1 pr <PR番号> -RepoPath C:\path\to\kumamoto-henno-map

# 機能2: バージョンベース
.\alt_generator.ps1 version v1.1.5 -RepoPath C:\path\to\kumamoto-henno-map

# ダブルクリック起動（対話型）
run_alt_generator.bat
```

**ディレクトリ構成:**
```
work_tools/alt_generator/
  alt_generator.ps1        # メインスクリプト（全機能入り1ファイル）
  run_alt_generator.bat    # ダブルクリック起動用ランチャー
  run_alt_generator.ps1    # 対話型入力ランチャー
  test_alt_ps.ps1          # 動作テスト
  .env.example             # GITHUB_TOKEN=xxx
  README.md
```

---

## 9. 設計上の判断（ビルダーへの注意事項）

- DMLのINSERT文にはカラム名がないため、DDLのカラム定義順でマッピングする
- `CURRENT_TIMESTAMP` は文字列として保持し、そのまま出力する
- NULL値は `NULL` として出力する
- シングルクォートを含む文字列値はそのまま保持する（エスケープ処理は行わない）
- PRアクセスにはGitHub Personal Access Token (PAT)が必要（`.env`ファイルで管理）
- 現時点でWKテーブルはプロジェクトに存在しないが、将来の追加に備えてファイル名で判定する
- ALTファイルの出力先は対象リポジトリ内の `config/database/Alt/...`
- 直前バージョンの判定はセマンティックバージョン順（数値比較）で1つ前のタグ
- SQLパーサーはクォート文字列・入れ子括弧を正しく扱うトークナイザーを実装する
- PRモードのファイル内容取得はローカルクローンのgitコマンドを使用（GitHub APIはPRメタデータのみ）

### NOT NULL 新規カラムの扱い
マスタテーブルに `NOT NULL` 制約付きの新規カラムが追加された場合、BKからの `INSERT INTO ... SELECT` は実行不能となる。以下の形式で警告コメントを出力し、`NULL` プレースホルダーで生成する（開発者が実行前に手動修正する運用）：

```sql
INSERT INTO BENEFIT (BENEFIT_ID, ..., NEW_COLUMN, ...)
SELECT BENEFIT_ID, ...,
  NULL -- WARNING: NEW_COLUMN is NOT NULL. Please set an appropriate default value before executing.
  , ...
FROM BENEFIT_BK;
```

### 新規テーブル・削除テーブルの扱い
- **新規テーブル（DDLファイル新規追加）:** BKコピー不要のため `CREATE TABLE` のみ生成
- **削除テーブル（DDLファイル完全削除）:** `DROP TABLE IF EXISTS {テーブル名};` を生成

---

## 10. 制約・前提

- 対象リポジトリ: `taichi0373/kumamoto-henno-map`
- 対象SQL: `config/database/DDL/TABLE/*.SQL` と `config/database/DML/TABLE/*.SQL`
- DDLファイルとDMLファイルはテーブル名が同一（`BENEFIT.SQL` 同士で対応）
- バージョンタグは `vX.Y.Z` 形式でセマンティックバージョニング
