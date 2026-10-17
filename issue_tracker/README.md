# 課題管理シート → 進捗管理シート 自動転記ツール

課題管理のGoogleスプレッドシートから指定担当者の課題を抽出し、ローカルのTSVファイルに出力する。
出力ファイルをメモ帳で開いてコピペすることで、共有の進捗管理シートへ転記できる。

**認証は自分のGoogleアカウントのOAuth 2.0を使用する。** 共有スプレッドシートへの既存アクセス権限がそのまま使われるため、サービスアカウントへの共有設定は不要。

## ワークフロー

```
[共有] 課題管理シート  ──→  フィルタ・差分除外  ──→  output/issues_YYYYMMDD_HHmm.tsv
[共有] 進捗管理シート  ──→  前週課題番号の抽出  ──┘          ↓
                                                     メモ帳で開いてCtrl+A → Ctrl+C
                                                          ↓
                                                [共有] 進捗管理シートにCtrl+V
```

## 前提条件

- PowerShell 7.0 以上（`pwsh.exe`）
- 自分のGoogleアカウントが対象スプレッドシートの閲覧権限を持っていること

## セットアップ

### 1. GCPでOAuthクライアントIDを作成

1. [GCPコンソール](https://console.cloud.google.com/) でプロジェクトを選択
2. 「APIとサービス」→「ライブラリ」→ **Google Sheets API** を有効化
3. 「APIとサービス」→「認証情報」→「認証情報を作成」→「OAuthクライアントID」
4. アプリケーションの種類: **デスクトップアプリ**
5. 作成後、**JSONをダウンロード**（ファイル名: `client_secret_xxx.json`）

> 初回のみ「OAuth同意画面」の設定も必要。「APIとサービス」→「OAuth同意画面」→「対象」→「テストユーザー」に自分のGoogleアカウントを追加する。

### 2. 設定ファイルの作成

`config.json.example` を `config.json` にコピーし、各項目を設定する。

```json
{
  "sourceSpreadsheetId": "課題管理シートのID（URLの /d/〇〇〇/edit の〇〇〇）",
  "previousWeekSpreadsheetId": "共有の進捗管理シートのID",
  "sourceSheetName": "課題管理シートのシート名",
  "oauthClientSecretPath": "C:\\path\\to\\client_secret_xxx.json",
  "targetPersons": ["担当者A", "担当者B"]
}
```

## 実行方法

### 手動実行

`run_issue_tracker.bat` をダブルクリック。

**初回のみ**: ブラウザが開いてGoogleアカウントのログイン・許可画面が表示される。
許可後、リフレッシュトークンが `credentials/token.json` に保存され、次回以降はブラウザ不要。

### 自動実行（毎週木曜日 09:00）

`setup_schedule.bat` をダブルクリックして、Windowsタスクスケジューラに登録する。
※ 事前に手動実行を1回行い、`credentials/token.json` を作成しておくこと。

登録確認:
```
schtasks /query /tn "IssueTracker_Weekly" /fo list
```

登録解除:
```
schtasks /delete /tn "IssueTracker_Weekly" /f
```

## 出力ファイルの使い方

実行すると `output/issues_YYYYMMDD_HHmm.tsv` が生成される。

```
      No.1：【業務A】画面X 事象の詳細テキスト    2026/10/31
[PR]  No.2：【業務B】画面Y 事象の詳細テキスト    2026/11/07
[完了]No.3：【業務C】画面Z 事象の詳細テキスト    2026/10/24
```

**Sheetsへの貼り付け手順:**
1. 出力ファイルをメモ帳で開く
2. Ctrl+A → Ctrl+C でコピー
3. 共有進捗管理シートの貼り付けたいセルを選択
4. Ctrl+V で貼り付け（タブ区切りで2列に分かれて貼られる）

**貼り付け後の手動書式適用:**

| マーカー | 書式 |
|---|---|
| `[完了]` | グレー文字 + 取り消し線 |
| `[PR]` | グレー文字 |
| （なし） | そのまま（黒文字） |

## 動作仕様

### 課題管理シートの列構成

| 列 | 内容 |
|----|------|
| A  | 課題No |
| F  | 業務 |
| G  | 画面/処理 |
| I  | 事象詳細 |
| M  | 対応者 |
| N  | 対応状況 |
| O  | 対応期限 |
| T  | プルリク番号 |

### 差分ロジック

- M列が `targetPersons` に一致する行を対象とする
- **共有進捗シートに存在し、かつN列が「対応完了」の課題は除外**（前週完了扱い）
- 今週初めて「対応完了」になった課題は含める

## ファイル構成

```
issue_tracker/
├── issue_tracker.ps1        # メインスクリプト
├── run_issue_tracker.bat    # 手動実行用
├── setup_schedule.bat       # タスクスケジューラ登録用
├── config.json.example      # 設定テンプレート
├── config.json              # 本番設定（.gitignore対象）
├── credentials/             # トークン保存先（.gitignore対象）
│   └── token.json           # リフレッシュトークン（初回認証後に自動生成）
├── output/                  # 出力先（.gitignore対象）
└── README.md
```

## 注意事項

- `config.json`、`credentials/`、`output/` は `.gitignore` により管理外
- PowerShell 5.1（`powershell.exe`）では動作しない。`pwsh.exe`（PowerShell 7）が必要
- スケジューラ登録前に手動実行で初回認証（`token.json` の生成）を済ませておくこと
