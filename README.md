# work-tools

業務効率化ツール集。各ツールは独立して使用できます。

## ツール一覧

| ツール | 概要 | README |
|--------|------|--------|
| `issue_tracker` | Google Sheets 課題管理シートから担当課題を抽出して TSV 出力 | [issue_tracker/README.md](issue_tracker/README.md) |
| `alt_generator` | Git 差分から ALT SQL を自動生成 | [alt_generator/README.md](alt_generator/README.md) |

---

## `/todo` コマンド（Claude Code 連携）

Claude Code で `/todo {課題番号}` と入力すると以下を自動実行するスラッシュコマンドです。

1. Google Sheets から課題詳細を取得
2. 指定リポジトリに `feature/develop-{番号}` ブランチの worktree を作成
3. 課題内容をコンテキストにブレインストーミングを起動

### 前提条件

- [Claude Code](https://claude.ai/claude-code) がインストールされていること
- `issue_tracker` のセットアップが完了していること（Google 認証・`config.json`）

### セットアップ

**1. コマンドファイルをコピー**

`~/.claude/commands/todo.md` として配置します（Claude Code のパーソナルコマンド）。

```powershell
# ~/.claude/commands/ ディレクトリがなければ作成
New-Item -ItemType Directory -Force -Path "$HOME\.claude\commands"

# コマンドファイルはリポジトリ内の .claude-commands/todo.md を参照
# または手動で ~/.claude/commands/todo.md を作成
```

**2. 設定ファイルを作成**

`todo-config.example.json` を `~/.claude/todo-config.json` にコピーして編集します。

```powershell
Copy-Item "todo-config.example.json" "$HOME\.claude\todo-config.json"
```

`~/.claude/todo-config.json` を編集：

```json
{
  "scriptPath": "C:\\path\\to\\work_tools\\issue_tracker\\read_issue.ps1",
  "repoPath":   "C:\\path\\to\\your-repo",
  "baseBranch": "develop",
  "branchPrefix": "feature/develop-"
}
```

| 項目 | 説明 | 例 |
|------|------|----|
| `scriptPath` | `read_issue.ps1` の絶対パス | `C:\work\work_tools\issue_tracker\read_issue.ps1` |
| `repoPath` | 作業対象リポジトリの絶対パス | `C:\work\your-repo` |
| `baseBranch` | worktree のベースブランチ | `develop` |
| `branchPrefix` | 作成するブランチ名のプレフィックス | `feature/develop-` |

**3. 動作確認**

Claude Code を再起動後、`/todo 1234` と入力してスキルが起動することを確認します。

---

## セットアップ全体の順序

新しい環境でセットアップする場合、以下の順序で行ってください。

```
1. issue_tracker のセットアップ
   └─ GCP で OAuth クライアント ID を作成
   └─ issue_tracker/config.json を作成・編集

2. alt_generator のセットアップ（使用する場合）
   └─ alt_generator/.env を作成・編集

3. /todo コマンドのセットアップ（Claude Code 使用時）
   └─ ~/.claude/commands/todo.md を配置
   └─ ~/.claude/todo-config.json を作成・編集
```
