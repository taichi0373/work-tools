"""ALT SQL 自動生成ツール — CLIエントリーポイント。"""
from __future__ import annotations

import argparse
import os
from pathlib import Path

from dotenv import load_dotenv

from alt_generator.ddl_alt_generator import generate_ddl_alt
from alt_generator.dml_alt_generator import generate_dml_alt
from alt_generator.git_diff import DiffedFile, get_version_diff
from alt_generator.github_diff import get_pr_diff
from alt_generator.sql_parser import parse_ddl, parse_dml

load_dotenv()

# プロジェクト内 DDL TABLE ディレクトリの相対パス
_DDL_TABLE_DIR = Path("config/database/DDL/TABLE")


def _process_diff_files(
    diff_files: list[DiffedFile],
    repo_path: str,
    output_base: str,
    identifier: str,
    version: str | None = None,
    prev_version: str | None = None,
) -> None:
    """差分ファイルリストから ALT SQL ファイルを生成して出力する。
    version/prev_version が指定された場合、DML-only テーブルのDDLをgitから取得する。
    """
    base = Path(output_base) / identifier

    # DDL差分を先にビルドし、旧/新のDDLTableをテーブル名ごとに記録する
    old_ddl_map: dict[str, object] = {}
    new_ddl_map: dict[str, object] = {}
    for df in diff_files:
        if df.sql_type == "DDL":
            old_ddl = parse_ddl(df.old_content) if df.old_content else None
            new_ddl = parse_ddl(df.new_content) if df.new_content else None
            old_ddl_map[df.table_name] = old_ddl
            new_ddl_map[df.table_name] = new_ddl
            sql = generate_ddl_alt(df.table_name, old_ddl, new_ddl)
            _write_alt(base / "DDL", df.table_name, sql)

    for df in diff_files:
        if df.sql_type == "DML":
            # DDLがdiff内にある場合は旧/新DDLを使い分ける
            if df.table_name in old_ddl_map:
                old_ddl_table = old_ddl_map.get(df.table_name)
                new_ddl_table = new_ddl_map.get(df.table_name)
            else:
                # DDLが差分に含まれない（変更なし）: gitまたはディスクからDDLを取得
                ddl_rel = str(_DDL_TABLE_DIR / f"{df.table_name}.SQL").replace("\\", "/")
                if version and prev_version:
                    try:
                        import git as _git
                        _repo = _git.Repo(repo_path)
                        old_content = _repo.git.show(f"{prev_version}:{ddl_rel}")
                        new_content = _repo.git.show(f"{version}:{ddl_rel}")
                        old_ddl_table = parse_ddl(old_content)
                        new_ddl_table = parse_ddl(new_content)
                    except Exception as e:
                        print(f"[WARNING] git から DDL を取得できません ({e})。ディスクを使用します。")
                        old_ddl_table = new_ddl_table = _read_disk_ddl(repo_path, df.table_name)
                else:
                    old_ddl_table = new_ddl_table = _read_disk_ddl(repo_path, df.table_name)

            if old_ddl_table is None or new_ddl_table is None:
                print(f"[WARNING] {df.table_name} の DDL が取得できませんでした。スキップします。")
                continue

            old_columns = [c.name for c in old_ddl_table.columns]
            new_columns = [c.name for c in new_ddl_table.columns]
            pk_columns = new_ddl_table.primary_keys  # PKは新DDL基準

            old_records = parse_dml(df.old_content or "", old_columns, pk_columns)
            new_records = parse_dml(df.new_content or "", new_columns, pk_columns)

            # DML比較は新DDLのカラム順で実施（共通カラムのみ）
            all_columns = new_columns
            # 旧レコードを新カラム構造に揃える（追加カラムはNULLで補完）
            aligned_old: dict = {}
            for pk_key, row in old_records.items():
                aligned_row = {col: row.get(col, "NULL") for col in all_columns}
                aligned_old[pk_key] = aligned_row

            old_columns = [c.name for c in old_ddl_table.columns]
            new_columns = [c.name for c in new_ddl_table.columns]
            pk_columns = new_ddl_table.primary_keys  # PKは新DDL基準

            old_records = parse_dml(df.old_content or "", old_columns, pk_columns)
            new_records = parse_dml(df.new_content or "", new_columns, pk_columns)

            # DML比較は新DDLのカラム順で実施（共通カラムのみ）
            all_columns = new_columns
            # 旧レコードを新カラム構造に揃える（追加カラムはNULLで補完）
            aligned_old: dict = {}
            for pk_key, row in old_records.items():
                aligned_row = {col: row.get(col, "NULL") for col in all_columns}
                aligned_old[pk_key] = aligned_row

            sql = generate_dml_alt(df.table_name, aligned_old, new_records, pk_columns, all_columns)
            if sql:
                _write_alt(base / "DML", df.table_name, sql)


def _read_disk_ddl(repo_path: str, table_name: str):
    """ディスク上の DDL ファイルを読み込んで DDLTable を返す。"""
    ddl_path = Path(repo_path) / _DDL_TABLE_DIR / f"{table_name}.SQL"
    if not ddl_path.exists():
        print(f"[WARNING] DDLファイルが見つかりません: {ddl_path}")
        return None
    return parse_ddl(ddl_path.read_text(encoding="utf-8"))


def _write_alt(output_dir: Path, table_name: str, sql: str) -> None:
    """ALT SQLファイルを指定ディレクトリに書き出す。"""
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"Alt_{table_name}.SQL"
    output_path.write_text(sql, encoding="utf-8")
    print(f"生成: {output_path}")


def run_version(
    repo_path: str,
    version: str,
    output_base: str | None = None,
) -> None:
    """バージョン指定で ALT SQL を生成する。"""
    if output_base is None:
        output_base = str(Path(repo_path) / "config/database/Alt")

    prev_version, diff_files = get_version_diff(repo_path, version)
    print(f"差分: {prev_version} → {version} ({len(diff_files)} ファイル)")
    _process_diff_files(diff_files, repo_path, output_base, version,
                        version=version, prev_version=prev_version)


def run_pr(
    repo_path: str,
    pr_number: int,
    github_token: str,
    github_repo: str,
    output_base: str | None = None,
) -> None:
    """PR番号指定で ALT SQL を生成する。"""
    if output_base is None:
        output_base = str(Path(repo_path) / "config/database/Alt")

    diff_files = get_pr_diff(repo_path, pr_number, github_token, github_repo)
    identifier = f"PR-{pr_number}"
    print(f"PR #{pr_number}: {len(diff_files)} ファイルの差分")
    _process_diff_files(diff_files, repo_path, output_base, identifier)


def main() -> None:
    parser = argparse.ArgumentParser(description="ALT SQL 自動生成ツール")
    parser.add_argument(
        "--github-repo",
        default="taichi0373/kumamoto-henno-map",
        help="GitHubリポジトリ名 (owner/repo)",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    # version サブコマンド
    version_parser = subparsers.add_parser("version", help="バージョン指定で差分生成")
    version_parser.add_argument("version", help="バージョンタグ (例: v1.1.5)")
    version_parser.add_argument(
        "--repo-path", default=".", help="対象リポジトリのパス (default: カレントディレクトリ)"
    )
    version_parser.add_argument("--output-base", default=None, help="ALTファイル出力先")

    # pr サブコマンド
    pr_parser = subparsers.add_parser("pr", help="PR番号指定で差分生成")
    pr_parser.add_argument("pr_number", type=int, help="PR番号")
    pr_parser.add_argument(
        "--repo-path", default=".", help="対象リポジトリのパス (default: カレントディレクトリ)"
    )
    pr_parser.add_argument("--output-base", default=None, help="ALTファイル出力先")

    args = parser.parse_args()

    repo_path = args.repo_path
    output_base = args.output_base

    if args.command == "version":
        run_version(
            repo_path=repo_path,
            version=args.version,
            output_base=output_base,
        )
    elif args.command == "pr":
        github_token = os.environ.get("GITHUB_TOKEN", "")
        if not github_token:
            parser.error("GITHUB_TOKEN 環境変数が設定されていません (.env ファイルを確認してください)")
        run_pr(
            repo_path=repo_path,
            pr_number=args.pr_number,
            github_token=github_token,
            github_repo=args.github_repo,
            output_base=output_base,
        )


if __name__ == "__main__":
    main()
