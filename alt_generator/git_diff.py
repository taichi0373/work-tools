"""Gitタグ間の差分取得モジュール。"""
from __future__ import annotations

import re
from dataclasses import dataclass

import git


@dataclass
class DiffedFile:
    table_name: str        # 例: "BENEFIT"
    sql_type: str          # "DDL" または "DML"
    old_content: str | None  # None = 新規追加
    new_content: str | None  # None = 削除


# DDL/DML パスのパターン
_DDL_PATTERN = re.compile(
    r'config/database/DDL/TABLE/([A-Z0-9_]+)\.SQL', re.IGNORECASE
)
_DML_PATTERN = re.compile(
    r'config/database/DML/TABLE/([A-Z0-9_]+)\.SQL', re.IGNORECASE
)

_SEMVER_RE = re.compile(r'^v(\d+)\.(\d+)\.(\d+)$')


def _find_previous_version(version: str, tags: list[str]) -> str:
    """セマンティックバージョン順で直前のタグを返す。
    非semverタグ（v1.0.0-rc1 など）は無視する。
    """
    semver_tags = [t for t in tags if _SEMVER_RE.match(t)]
    semver_tags.sort(key=lambda t: tuple(int(x) for x in _SEMVER_RE.match(t).groups()))  # type: ignore[union-attr]

    target_m = _SEMVER_RE.match(version)
    if not target_m:
        raise ValueError(f"指定バージョン '{version}' は semver 形式ではありません")
    target_tuple = tuple(int(x) for x in target_m.groups())

    previous = None
    for tag in semver_tags:
        m = _SEMVER_RE.match(tag)
        assert m
        t = tuple(int(x) for x in m.groups())
        if t < target_tuple:
            previous = tag

    if previous is None:
        raise ValueError(f"'{version}' の previous version が見つかりません")
    return previous


def get_previous_version(repo_path: str, version: str) -> str:
    """リポジトリのタグからセマンティックバージョン順で直前のタグを返す。"""
    repo = git.Repo(repo_path)
    tag_names = [t.name for t in repo.tags]
    return _find_previous_version(version, tag_names)


def get_version_diff(repo_path: str, version: str) -> tuple[str, list[DiffedFile]]:
    """(previous_version, [DiffedFile]) を返す。"""
    repo = git.Repo(repo_path)
    prev_version = get_previous_version(repo_path, version)

    # 変更ファイルリスト取得
    diff_output = repo.git.diff(prev_version, version, "--name-status")
    diffed: list[DiffedFile] = []

    for line in diff_output.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t", 1)
        if len(parts) < 2:
            continue
        status, file_path = parts[0].strip(), parts[1].strip()

        ddl_m = _DDL_PATTERN.search(file_path)
        dml_m = _DML_PATTERN.search(file_path)
        if not ddl_m and not dml_m:
            continue

        table_name = (ddl_m or dml_m).group(1).upper()  # type: ignore[union-attr]
        sql_type = "DDL" if ddl_m else "DML"

        old_content: str | None = None
        new_content: str | None = None

        if status != "A":  # Added の場合は旧コンテンツなし
            try:
                old_content = repo.git.show(f"{prev_version}:{file_path}")
            except git.GitCommandError:
                old_content = None

        if status != "D":  # Deleted の場合は新コンテンツなし
            try:
                new_content = repo.git.show(f"{version}:{file_path}")
            except git.GitCommandError:
                new_content = None

        diffed.append(DiffedFile(
            table_name=table_name,
            sql_type=sql_type,
            old_content=old_content,
            new_content=new_content,
        ))

    return prev_version, diffed
