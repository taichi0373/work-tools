"""DDL ALT SQL ジェネレーター。"""
from __future__ import annotations

from alt_generator.sql_parser import DDLTable


def generate_ddl_alt(
    table_name: str,
    old_ddl: DDLTable | None,
    new_ddl: DDLTable | None,
) -> str:
    """DDL ALT SQL を生成して返す。
    old_ddl=None は新規テーブル、new_ddl=None は削除テーブル。
    """
    change_type = _classify_change(table_name, old_ddl, new_ddl)

    if change_type == "new_table":
        return new_ddl.full_sql  # type: ignore[union-attr]

    if change_type == "deleted_table":
        return f"DROP TABLE IF EXISTS {table_name};"

    if change_type == "wk_table":
        return f"DROP TABLE IF EXISTS {table_name};\n\n{new_ddl.full_sql}"  # type: ignore[union-attr]

    if change_type == "columns_added_only":
        return _generate_modify(table_name, old_ddl, new_ddl)  # type: ignore[arg-type]

    if change_type == "no_change":
        return f"-- {table_name}: 構造変更なし（COMMENT ON などの変更のみ）。DDL ALT は不要です。"

    # structural_change
    return _generate_bk_copy(table_name, old_ddl, new_ddl)  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# 内部ヘルパー
# ---------------------------------------------------------------------------

def _classify_change(
    table_name: str,
    old_ddl: DDLTable | None,
    new_ddl: DDLTable | None,
) -> str:
    if old_ddl is None:
        return "new_table"
    if new_ddl is None:
        return "deleted_table"
    if "_WK_" in table_name.upper():
        return "wk_table"

    old_col_names = {c.name for c in old_ddl.columns}
    new_col_names = {c.name for c in new_ddl.columns}

    # 削除カラムがある場合
    if old_col_names - new_col_names:
        return "structural_change"

    # 型変更または制約変更がある場合
    old_col_map = {c.name: c for c in old_ddl.columns}
    new_col_map = {c.name: c for c in new_ddl.columns}
    for name in old_col_names & new_col_names:
        if old_col_map[name].type_def != new_col_map[name].type_def:
            return "structural_change"

    # PKの変更
    if old_ddl.primary_keys != new_ddl.primary_keys:
        return "structural_change"

    # 追加カラムのみ
    if new_col_names - old_col_names:
        return "columns_added_only"

    # 変更なし（COMMENT ON のみの変更など）
    return "no_change"


def _generate_modify(table_name: str, old_ddl: DDLTable, new_ddl: DDLTable) -> str:
    """カラム追加のみの変更に対して ALTER TABLE ... MODIFY ... を生成する。"""
    old_col_names = {c.name for c in old_ddl.columns}
    added_cols = [c for c in new_ddl.columns if c.name not in old_col_names]

    lines: list[str] = []
    for col in added_cols:
        if col.is_not_null:
            lines.append(
                f"-- WARNING: {col.name} is NOT NULL. "
                "Please set an appropriate default value before executing."
            )
        lines.append(f"ALTER TABLE {table_name} MODIFY {col.name} {col.type_def};")

    return "\n".join(lines)


def _generate_bk_copy(table_name: str, old_ddl: DDLTable, new_ddl: DDLTable) -> str:
    """構造変更に対して BKコピー方式の SQL を生成する。"""
    bk_name = f"{table_name}_BK"
    old_col_names = {c.name for c in old_ddl.columns}

    # 全挿入カラム（新DDLの定義順）と SELECT 節を構築する
    insert_cols: list[str] = []
    select_exprs: list[str] = []
    for col in new_ddl.columns:
        insert_cols.append(col.name)
        if col.name in old_col_names:
            select_exprs.append(col.name)
        else:
            # 新規追加カラム: BKには存在しないため NULL プレースホルダー
            if col.is_not_null:
                select_exprs.append(
                    f"  NULL"
                    f" -- WARNING: {col.name} is NOT NULL."
                    " Please set an appropriate default value before executing."
                )
            else:
                select_exprs.append("  NULL")

    cols_str = ", ".join(insert_cols)
    select_str = ",\n".join(select_exprs)

    lines: list[str] = [
        f"-- 既存データのバックアップ",
        f"CREATE TABLE {bk_name} AS SELECT * FROM {table_name};",
        "",
        f"-- テーブルの再作成",
        f"DROP TABLE {table_name};",
        "",
        new_ddl.full_sql,
        "",
        f"-- バックアップからデータ復元",
        f"INSERT INTO {table_name} ({cols_str})",
        f"SELECT {select_str}",
        f"FROM {bk_name};",
        "",
        f"-- バックアップテーブルの削除",
        f"DROP TABLE {bk_name};",
    ]
    return "\n".join(lines)
