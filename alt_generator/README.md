# ALT SQL 自動生成ツール

kumamoto-henno-map プロジェクトのバージョンアップ時に必要な **ALT SQL**（既存DBマイグレーション用SQL）を、Gitの差分から自動生成するCLIツールです。

---

## 概要

### ALTとは

既に稼働中の環境のDBを、データを保持したままバージョンアップするためのSQLファイル群です。

### 生成されるファイル

| 種別 | ファイル名 | 内容 |
|------|-----------|------|
| DDL ALT | `Alt_{テーブル名}.SQL` | テーブル構造の変更SQL |
| DML ALT | `Alt_{テーブル名}.SQL` | データの追加・更新・削除SQL |

### 出力先

```
config/database/Alt/
  {バージョン or PR-番号}/
    DDL/
      Alt_{テーブル名}.SQL
    DML/
      Alt_{テーブル名}.SQL
```

---

## セットアップ

### 1. 依存ライブラリのインストール

```bash
cd work_tools/alt_generator
pip install -r requirements.txt
```

### 2. GitHub Token の設定（PRモード使用時のみ）

`.env.example` をコピーして `.env` を作成し、Personal Access Token を設定します。

```bash
cp .env.example .env
```

`.env` を編集：

```
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxx
```

---

## 使い方

### バージョン指定モード

指定バージョンと直前バージョン（セマンティックバージョン順で自動検出）の差分からALT SQLを生成します。

```bash
python -m alt_generator.alt_generator version <バージョン> \
  --repo-path <リポジトリのパス>
```

**例:**

```bash
python -m alt_generator.alt_generator version v1.1.5 \
  --repo-path C:/Users/ta9ns/kumamoto-henno-map
```

実行結果：

```
差分: v1.1.4 → v1.1.5 (2 ファイル)
生成: C:\Users\ta9ns\kumamoto-henno-map\config\database\Alt\v1.1.5\DDL\Alt_BENEFIT.SQL
```

---

### PRモード

指定したプルリクエストの差分からALT SQLを生成します。

```bash
python -m alt_generator.alt_generator pr <PR番号> \
  --repo-path <リポジトリのパス>
```

**例:**

```bash
python -m alt_generator.alt_generator pr 42 \
  --repo-path C:/Users/ta9ns/kumamoto-henno-map
```

> **注意:** GitHub Token（`.env` の `GITHUB_TOKEN`）が必要です。

---

### オプション一覧

| オプション | 説明 | デフォルト |
|-----------|------|-----------|
| `--repo-path` | 対象リポジトリのパス | カレントディレクトリ |
| `--output-base` | ALTファイルの出力先ベースパス | `{repo-path}/config/database/Alt` |
| `--github-repo` | GitHubリポジトリ名（`owner/repo`） | `taichi0373/kumamoto-henno-map` |

---

## 生成SQLの仕様

### DDL ALT

| 変更内容 | 生成SQL |
|---------|---------|
| **カラム追加のみ** | `ALTER TABLE テーブル名 MODIFY カラム名 型;` を追加カラム分生成 |
| **カラム削除・型変更・制約変更** | BKコピー方式（後述） |
| **新規テーブル** | `CREATE TABLE` のみ |
| **テーブル削除** | `DROP TABLE IF EXISTS` |
| **WKテーブル**（名前に `_WK_` を含む） | `DROP TABLE IF EXISTS` → `CREATE TABLE` |

**BKコピー方式（マスタテーブルの構造変更）:**

```sql
-- 既存データのバックアップ
CREATE TABLE BENEFIT_BK AS SELECT * FROM BENEFIT;

-- テーブルの再作成
DROP TABLE BENEFIT;
CREATE TABLE BENEFIT ( ... );

-- バックアップからデータ復元
INSERT INTO BENEFIT (COL1, COL2, ...)
SELECT COL1, COL2, ...
FROM BENEFIT_BK;

-- バックアップテーブルの削除
DROP TABLE BENEFIT_BK;
```

> **NOT NULL の新規カラムが追加された場合:** INSERT SELECT に `NULL` プレースホルダーと WARNING コメントが出力されます。実行前に適切な値に書き換えてください。

### DML ALT

DMLファイル（INSERTの集合）を主キーで比較し、差分を生成します。

| 状態 | 生成SQL |
|------|---------|
| 旧にあるが新にない | `DELETE FROM テーブル WHERE pk = ...` |
| 旧にも新にもあるが値が異なる | `UPDATE テーブル SET ... WHERE pk = ...` |
| 新にあるが旧にない | `INSERT INTO テーブル VALUES (...)` |
| 変更なし | 生成しない（ファイルも作成しない） |

---

## 注意事項

- **対象ファイル:** `config/database/DDL/TABLE/*.SQL` と `config/database/DML/TABLE/*.SQL`
- **バージョンタグ形式:** `vX.Y.Z`（セマンティックバージョニング）。`v1.0.0-rc1` のような非semverタグは自動的に除外されます。
- **PRモードのファイル取得:** ローカルのリポジトリクローンから `git show` でファイル内容を取得します。PRのベースブランチ・HEADコミットがローカルに存在している必要があります（`git fetch` 済みであること）。
- **生成SQLは必ずレビューしてから実行してください。** 特にNOT NULL警告のある箇所は実行前に値を確認・修正してください。
