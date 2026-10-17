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

```
リポジトリのパスを入力してください (Enter でデフォルト: C:\Users\ta9ns\kumamoto-henno-map):
```

Enter のみで既定パスを使用します。

**5. 実行結果の確認**

```
差分: v1.1.4 → v1.1.5 (2 ファイル)
生成: C:\Users\ta9ns\work_tools\alt_generator\output\v1.1.5\DDL\Alt_BENEFIT.SQL
完了しました。
```

---

## 生成SQLの仕様

詳細は設計書 `docs/superpowers/specs/2026-10-17-alt-sql-generator-design.md` を参照してください。

---

## 注意事項

- **対象ファイル:** `config/database/DDL/TABLE/*.SQL` と `config/database/DML/TABLE/*.SQL`
- **バージョンタグ形式:** `vX.Y.Z`（セマンティックバージョニング）。`v1.0.0-rc1` のような非semverタグは自動的に除外されます。
- **git.exe** がインストールされていること（PATH に通っていること）が必要です。
- **生成SQLは必ずレビューしてから実行してください。** 特にNOT NULL警告のある箇所は実行前に値を確認・修正してください。
