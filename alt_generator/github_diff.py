"""GitHub PR差分取得モジュール。"""
from __future__ import annotations

import subprocess

from github import Github

from alt_generator.git_diff import DiffedFile, _DDL_PATTERN, _DML_PATTERN


def _get_file_content_at_commit(
    repo_path: str, commit_sha: str, file_path: str
) -> str | None:
    """ローカルcloneから指定コミット・ファイルのコンテンツを返す。
    ファイルが存在しない場合は None を返す。
    """
    result = subprocess.run(
        ["git", "show", f"{commit_sha}:{file_path}"],
        cwd=repo_path,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if result.returncode != 0:
        return None
    return result.stdout


def get_pr_diff(
    repo_path: str,
    pr_number: int,
    github_token: str,
    github_repo: str,
) -> list[DiffedFile]:
    """GitHub PRの変更SQLファイルリストを返す。
    ファイル内容はローカルcloneのgitコマンドから取得する。
    """
    gh = Github(github_token)
    repo = gh.get_repo(github_repo)
    pr = repo.get_pull(pr_number)

    base_sha = pr.base.sha
    head_sha = pr.head.sha

    diffed: list[DiffedFile] = []
    for changed_file in pr.get_files():
        file_path = changed_file.filename
        status = changed_file.status  # "added", "modified", "removed", "renamed"

        ddl_m = _DDL_PATTERN.search(file_path)
        dml_m = _DML_PATTERN.search(file_path)
        if not ddl_m and not dml_m:
            continue

        table_name = (ddl_m or dml_m).group(1).upper()  # type: ignore[union-attr]
        sql_type = "DDL" if ddl_m else "DML"

        old_content: str | None = None
        new_content: str | None = None

        if status != "added":
            old_content = _get_file_content_at_commit(repo_path, base_sha, file_path)

        if status != "removed":
            new_content = _get_file_content_at_commit(repo_path, head_sha, file_path)

        diffed.append(DiffedFile(
            table_name=table_name,
            sql_type=sql_type,
            old_content=old_content,
            new_content=new_content,
        ))

    return diffed
