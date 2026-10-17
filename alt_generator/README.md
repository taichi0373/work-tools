# ALT SQL 自動生成ツール (PowerShell版)

kumamoto-henno-map プロジェクトのバージョンアップ時に必要な **ALT SQL** を、Gitの差分から自動生成するPowerShellスクリプトです。

**pip install 不要** — Windows 標準の PowerShell (5.1以上) で動作します。

---

## 概要

Python版 (`alt_generator/`) と同等の機能を持ちますが、**外部ライブラリ不要**なため他メンバーへの配布が簡単です。

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

### GitHub Token の設定（PRモード使用時のみ）

`.env.example` をコピーして `.env` を作成し、Personal Access Token を設定します。

```powershell
Copy-Item .env.example .env
```

`.env` を編集：

```
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxx
```

### 実行ポリシーの確認

初回実行時、PowerShell の実行ポリシーが制限されている場合は以下を実行してください。

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

---

## 使い方

### バージョン指定モード

```powershell
.\alt_generator.ps1 version <バージョン> -RepoPath <リポジトリのパス>
```

**例:**

```powershell
.\alt_generator.ps1 version v1.1.5 -RepoPath C:\Users\ta9ns\kumamoto-henno-map
```

実行結果：

```
差分: v1.1.4 → v1.1.5 (2 ファイル)
生成: C:\Users\ta9ns\kumamoto-henno-map\config\database\Alt\v1.1.5\DDL\Alt_BENEFIT.SQL
```

---

### PRモード

```powershell
.\alt_generator.ps1 pr <PR番号> -RepoPath <リポジトリのパス>
```

**例:**

```powershell
.\alt_generator.ps1 pr 42 -RepoPath C:\Users\ta9ns\kumamoto-henno-map
```

> **注意:** GitHub Token（`.env` の `GITHUB_TOKEN`）が必要です。

---

### オプション一覧

| オプション | 説明 | デフォルト |
|-----------|------|-----------|
| `-RepoPath` | 対象リポジトリのパス | カレントディレクトリ |
| `-OutputBase` | ALTファイルの出力先ベースパス | `{RepoPath}\config\database\Alt` |
| `-GithubRepo` | GitHubリポジトリ名（`owner/repo`） | `taichi0373/kumamoto-henno-map` |
| `-GithubToken` | GitHub Token（コマンドライン直接指定も可） | `.env` ファイルから読み込み |

---

## 生成SQLの仕様

Python版と同一です。詳細は `alt_generator/README.md` を参照してください。

---

## 注意事項

- **対象ファイル:** `config/database/DDL/TABLE/*.SQL` と `config/database/DML/TABLE/*.SQL`
- **バージョンタグ形式:** `vX.Y.Z`（セマンティックバージョニング）。`v1.0.0-rc1` のような非semverタグは自動的に除外されます。
- **git.exe** がインストールされていること（PATH に通っていること）が必要です。
- **生成SQLは必ずレビューしてから実行してください。** 特にNOT NULL警告のある箇所は実行前に値を確認・修正してください。
