# work-tools

業務効率化ツール集。各ツールは独立して使用できます。

## ツール一覧

| ツール | 概要 | README |
|--------|------|--------|
| `issue_tracker` | Google Sheets 課題管理シートから担当課題を抽出して TSV 出力 | [issue_tracker/README.md](issue_tracker/README.md) |
| `alt_generator` | Git 差分から ALT SQL を自動生成 | [alt_generator/README.md](alt_generator/README.md) |

---

## `/todo` コマンド（Claude Code 連携）

Claude Code で `/todo {課題番号}` と入力すると以下を自動実行します。

1. Google Sheets から課題詳細を取得
2. 指定リポジトリに `feature/develop-{番号}` ブランチの worktree を作成
3. 課題内容をコンテキストにブレインストーミングを起動

### 前提条件

- [Claude Code](https://claude.ai/claude-code) がインストールされていること
- `issue_tracker` のセットアップが完了していること（Google 認証・`config.json`）

### セットアップ

**1. コマンドファイルを配置**

`~/.claude/commands/` ディレクトリに `todo.md` を配置します（Claude Code のパーソナルコマンド）。

```powershell
# ディレクトリがなければ作成
New-Item -ItemType Directory -Force -Path "$HOME\.claude\commands"

# コマンドファイルをコピー（または手動で ~/.claude/commands/todo.md を作成）
Copy-Item ".claude-commands\todo.md" "$HOME\.claude\commands\todo.md"
```

**2. 設定ファイルを作成**

`todo-config.example.json` を `~/.claude/todo-config.json` にコピーして編集します。

```powershell
Copy-Item "todo-config.example.json" "$HOME\.claude\todo-config.json"
```

`~/.claude/todo-config.json` の各項目を設定します。

```json
{
  "scriptPath": "C:\\path\\to\\work_tools\\issue_tracker\\read_issue.ps1",
  "repoPath":   "C:\\path\\to\\your-repo",
  "baseBranch": "develop",
  "branchPrefix": "feature/develop-"
}
```

| 項目 | 説明 |
|------|------|
| `scriptPath` | `read_issue.ps1` の絶対パス |
| `repoPath` | 作業対象リポジトリの絶対パス |
| `baseBranch` | worktree のベースブランチ |
| `branchPrefix` | 作成するブランチ名のプレフィックス |

**3. 動作確認**

Claude Code を再起動後、`/todo 1234` と入力してコマンドが起動することを確認します。

---

## セットアップ順序（新規環境）

新しい環境でセットアップする場合は以下の順序で行います。

1. **issue_tracker** のセットアップ
   - GCP で OAuth クライアント ID を作成
   - `issue_tracker/config.json` を作成・編集
   - 詳細: [issue_tracker/README.md](issue_tracker/README.md)

2. **alt_generator** のセットアップ（使用する場合）
   - `alt_generator/.env` を作成・編集
   - 詳細: [alt_generator/README.md](alt_generator/README.md)

3. **`/todo` コマンド**のセットアップ（Claude Code 使用時）
   - `~/.claude/commands/todo.md` を配置
   - `~/.claude/todo-config.json` を作成・編集
   - 詳細: 上記「`/todo` コマンド」セクションを参照
