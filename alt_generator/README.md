# ALT SQL 自動生成ツール (PowerShell版)

kumamoto-henno-map プロジェクトのバージョンアップ時に必要な **ALT SQL** を、Gitの差分から自動生成するPowerShellスクリプトです。

---

## 概要

**外部ライブラリ不要**なため、追加インストールなしで使用できます。

### 出力先

```
alt_generator/output/
  {バージョン or PR-番号}/
    DDL/
      TABLE/
        Alt_{テーブル名}.SQL
      VIEW/
        Alt_{ビュー名}.SQL
    DML/
      Alt_{テーブル名}.SQL
```

---

## セットアップ

### 1. 設定ファイルの作成

`.env.example` をコピーして `.env` を作成します。

```powershell
Copy-Item .env.example .env
```

`.env` を編集して各項目を設定します：

```
# GitHub リポジトリ (owner/repo 形式)
GITHUB_REPO=your-org/your-repo

# 対象リポジトリのローカルパス（起動時にEnterで確定するデフォルト値）
REPO_PATH=C:\path\to\your-repo

# GitHub Personal Access Token (PRモード使用時のみ必要)
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxx
```

| 項目 | 必須 | 説明 |
|------|------|------|
| `GITHUB_REPO` | PRモード時 | GitHub の `owner/repo` 形式のリポジトリ名 |
| `REPO_PATH` | 任意 | ローカルリポジトリのパス。未設定時は起動ごとに入力が必要 |
| `GITHUB_TOKEN` | PRモード時 | GitHub Personal Access Token（`repo` スコープ） |

> `GITHUB_TOKEN` の取得: GitHub → Settings → Developer settings → Personal access tokens

### 2. 実行ポリシーの確認

初回実行時、PowerShell の実行ポリシーが制限されている場合は以下を実行してください。

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

---

## 使い方

`run_alt_generator.bat` をダブルクリックすると対話形式で実行できます。

### 手順

**1. `run_alt_generator.bat` をダブルクリック**

コンソール画面が開きます。

**2. 実行モードを選択**

```
============================================
 ALT SQL 自動生成ツール
============================================

実行モードを選んでください:
  1. バージョン指定モード (例: v1.1.5)
  2. PR番号モード          (例: 42)

番号を入力してください (1 or 2):
```

**3. バージョン or PR番号を入力**

- モード `1` を選んだ場合 → バージョンタグを入力（例: `v1.1.5`）
- モード `2` を選んだ場合 → PR番号を入力（例: `42`）

**4. リポジトリのパスを入力**

`.env` に `REPO_PATH` を設定している場合は Enter のみで確定できます。

```
リポジトリのパスを入力してください (Enter でデフォルト: C:\path\to\your-repo):
```

未設定の場合はパスの入力が必須になります。

**5. 実行結果の確認**

```
差分: v1.1.4 → v1.1.5 (2 ファイル)
生成: ...\alt_generator\output\v1.1.5\DDL\Alt_BENEFIT.SQL
完了しました。
```

---


## 注意事項

- **対象ファイル:** `config/database/DDL/TABLE/*.SQL` と `config/database/DML/TABLE/*.SQL`
- **バージョンタグ形式:** `vX.Y.Z`（セマンティックバージョニング）。`v1.0.0-rc1` のような非semverタグは自動的に除外されます。
- **git.exe** がインストールされていること（PATH に通っていること）が必要です。
- **生成SQLは必ずレビューしてから実行してください。** 特にNOT NULL警告のある箇所は実行前に値を確認・修正してください。
