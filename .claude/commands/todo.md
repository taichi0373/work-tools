---
description: 課題対応ワークフロー（Google Sheets取得 → worktree作成 → ブレインストーミング）
argument-hint: [課題番号]
allowed-tools: Bash, Read, Write, Edit
---

課題番号 $ARGUMENTS の対応を開始する。以下のステップを順番に実行すること。

## Step 0: 設定ファイルを読み込む

まず `~/.claude/todo-config.json` を Read ツールで読み込み、以下の値を取得する:

- `scriptPath` → 課題取得スクリプトのパス
- `repoPath`   → 対象リポジトリのパス
- `baseBranch` → ベースブランチ名（例: develop）
- `branchPrefix` → ブランチ名プレフィックス（例: feature/develop-）
- `claudeMdPath` → 元リポジトリの CLAUDE.md パス（省略可）
- `knowledgePaths` → 業務知識フォルダのパス配列（省略可）
- `spreadsheetUrl` → 課題管理スプレッドシートの URL（プルリクリンク用）

以降のステップでは取得した値を使用する。

worktree のパスは `repoPath` の親ディレクトリ + `\` + リポジトリ名 + `-$ARGUMENTS` で導出する。
（例: repoPath が `C:\work\my-repo` なら worktree は `C:\work\my-repo-$ARGUMENTS`）

## Step 1: Google Sheets から課題詳細を取得

以下のコマンドを実行して課題情報を取得する（`{scriptPath}` は Step 0 の値に置き換える）:

```
powershell -File "{scriptPath}" -IssueNo $ARGUMENTS
```

出力された JSON をパースして課題情報を保持する。`行番号` フィールドも取得しておく（プルリクのスプレッドシートリンク生成に使用）。エラーが発生した場合はユーザーに報告して中断する。

## Step 2: worktree を作成してブランチを準備

`{repoPath}`, `{baseBranch}`, `{branchPrefix}`, worktree パスは Step 0 の値を使う。

まずベースブランチを最新にする:
```
git -C "{repoPath}" fetch origin {baseBranch}
```

ワークツリーが既に存在するか確認:
```
git -C "{repoPath}" worktree list
```

ワークツリーが存在しない場合は以下を実行する:
```
git -C "{repoPath}" worktree add "{worktreePath}" -b "{branchPrefix}$ARGUMENTS" origin/{baseBranch}
```

ブランチ `{branchPrefix}$ARGUMENTS` が既に存在する場合は `-b` を除いて実行する:
```
git -C "{repoPath}" worktree add "{worktreePath}" "{branchPrefix}$ARGUMENTS"
```

ワークツリーが既に存在する場合はそのまま続行し、ユーザーに通知する。

## Step 2.5: worktree にセッション設定を書き込む

worktree に Claude Code 用の設定ファイルを作成し、以下を自動構成する。

### .claude/settings.local.json を作成

`{worktreePath}/.claude/settings.local.json` を作成する（ディレクトリがなければ作成）:

```json
{
  "permissions": {
    "defaultMode": "acceptEdits",
    "allow": [
      "Read(//c/Users/{username}/**)",
      "Read(~/**)",
      "Edit(//c/Users/{username}/**)",
      "Edit(~/**)",
      "Bash(mkdir:*)",
      "Bash(mkdir -p:*)",
      "Bash(git:*)",
      "Bash(ls:*)",
      "Bash(find:*)",
      "Bash(grep:*)",
      "Bash(cat:*)",
      "Bash(head:*)",
      "Bash(tail:*)",
      "Bash(sort:*)",
      "Bash(wc:*)",
      "Bash(echo:*)",
      "Bash(powershell:*)",
      "Bash(bash:*)",
      "Bash(python:*)",
      "Bash(python3:*)",
      "Search(**)",
      "WebSearch(**)",
      "WebFetch(**)"
    ]
  }
}
```

これによりこの worktree のセッションでは、allowリストに列挙したファイル操作・検索・git操作等を確認なしで自動実行する。

### CLAUDE.md にセッションルールを追記

`{worktreePath}/CLAUDE.md` を以下の手順で作成する:

**1. 元リポジトリの CLAUDE.md を取り込む（`claudeMdPath` が設定されている場合）**

`{claudeMdPath}` を Read ツールで読み込み、その内容を `{worktreePath}/CLAUDE.md` の冒頭に書き込む。
設定されていない場合はこの手順をスキップする。

**2. 業務知識フォルダの内容を取り込む（`knowledgePaths` が空でない場合）**

`knowledgePaths` の各フォルダに含まれる `.md` ファイルを Glob で列挙し、Read ツールで読み込む。
読み込んだ内容を以下の形式で `{worktreePath}/CLAUDE.md` に追記する:

```
---
## 業務知識: {フォルダ名}

### {ファイル名}

{ファイル内容}
```

**3. セッションルールを追記する**

上記の内容の末尾に以下を追記する（ファイルがなければ新規作成）:

```
---
## 検証指摘No.$ARGUMENTS 対応セッション

### このセッションのルール

- **ファイルの作成・編集は確認なしで自動実行する**（settings.local.json で設定済み）
- **対応方針はユーザーの承認を得てから実装に進む**
- **コミットはすべての修正が完了してから1回だけ行う**（途中でコミットしない）
- コミットメッセージの形式: `【検証指摘：No.{課題No}　{画面処理}　{対応内容}】`

### 課題情報

| 項目     | 内容           |
|----------|----------------|
| 課題No   | $ARGUMENTS     |
| 業務     | {業務}         |
| 画面処理 | {画面処理}     |
| 事象詳細 | {事象詳細}     |
| 対応者   | {対応者}       |
| 対応期限 | {対応期限}     |
| ブランチ | {branchPrefix}$ARGUMENTS |
```

## Step 3: セッション名と課題サマリーを表示

以下の形式で表示する（セッション名が UI に反映されるよう、H1 見出しで始める）:

```
# 検証指摘No.$ARGUMENTS

| 項目       | 内容           |
|------------|----------------|
| 業務       | {業務}         |
| 画面処理   | {画面処理}     |
| 事象詳細   | {事象詳細}     |
| 対応者     | {対応者}       |
| 対応期限   | {対応期限}     |
| 対応状況   | {対応状況}     |
| プルリク   | {プルリク番号} |

作業ディレクトリ: {worktreePath}
ブランチ: {branchPrefix}$ARGUMENTS
```

## Step 4: superpowers:brainstorming スキルを起動

課題内容（課題No・業務・画面処理・事象詳細・対応期限）と作業ディレクトリをコンテキストとして、`superpowers:brainstorming` スキルを起動して対応方針のブレインストーミングを行う。

**調査方針（brainstorming の質問ルールを上書き）:**
コードを調べれば答えられる質問（「どのファイルで管理しているか」「どこに実装されているか」など）は、ユーザーに聞かずに自分でコードを調査・確認してから提案すること。ユーザーへの質問は、コードを読んでも判断できない要件・仕様・優先度に関するものだけに限定する。

**実装方針（brainstorming の "how it gets made" を上書き）:**
実装の進め方は常に **Native**（既存コードベースの言語・フレームワーク・ライブラリをそのまま使ったネイティブ実装）とする。外部サービス・新規ライブラリ導入・代替アプローチをユーザーに提示する際も、Native 実装を第一案とすること。

ブレインストーミング完了後、実装に入る前に **必ずユーザーの承認を得ること**。

## Step 5（実装完了後）: コミット

**すべての修正が完了した後に1回だけ**コミットする。途中でコミットしない。

コミットメッセージの形式:
```
【検証指摘：No.{課題No}　{画面処理}　{対応内容}】
```

例:
```
【検証指摘：No.1721　注文画面　金額計算の誤りを修正】
```

実行コマンド（`{worktreePath}` 内で実行）:
```
git -C "{worktreePath}" add .
git -C "{worktreePath}" commit -m "【検証指摘：No.$ARGUMENTS　{画面処理}　{対応内容}】"
```

## Step 6（コミット完了後）: push・プルリク作成・ワークツリー削除

コミット完了後、以下を実行する前に**必ずユーザーに確認を取ること**:

> 「push・プルリク作成・ワークツリー削除を実行してよいですか？」

承認を得た場合のみ、以下の順で実行する。

### 1. push

```
git -C "{worktreePath}" push -u origin {branchPrefix}$ARGUMENTS
```

### 2. プルリク作成

`gh` コマンドでプルリクを作成する。タイトルはコミットメッセージと同じ形式にする。

```
gh pr create \
  --repo "{repoPath}" \
  --base {baseBranch} \
  --head {branchPrefix}$ARGUMENTS \
  --title "【検証指摘：No.$ARGUMENTS　{画面処理}　{対応内容}】" \
  --body "$(cat <<'EOF'
### 課題番号
[No.$ARGUMENTS]({spreadsheetUrl}?gid=0#gid=0&range={行番号}:{行番号})

### 対応内容
{対応内容}
EOF
)"
```

作成されたプルリク URL をユーザーに表示する。

### 3. 設計書を元リポジトリにコピー

ワークツリーの `docs/superpowers` が存在する場合、元リポジトリの同じパスにコピーする。

```
robocopy "{worktreePath}\docs\superpowers" "{repoPath}\docs\superpowers" /E /NJH /NJS
```

`robocopy` の終了コードは 0〜7 が正常（差分コピー成功）のため、それ以外の場合のみエラーとして扱う。

ワークツリーに `docs/superpowers` が存在しない場合はこの手順をスキップする。

### 4. ワークツリーを削除

```
git -C "{repoPath}" worktree remove "{worktreePath}" --force
```

削除後、元リポジトリのディレクトリに切り替えて動作確認を促すメッセージを表示する:

```
ワークツリー削除完了。
設計書は {repoPath}\docs\superpowers に保存されました。
動作確認は元リポジトリで行ってください: {repoPath}
プルリク: {プルリクURL}
```
