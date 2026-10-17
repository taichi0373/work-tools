"""DML ALT SQL ジェネレーター。"""
from __future__ import annotations

from alt_generator.sql_parser import Records


def generate_dml_alt(
    table_name: str,
    old_records: Records,
    new_records: Records,
    pk_columns: list[str],
    all_columns: list[str],
) -> str:
    """DML ALT SQL を生成して返す。変更なしの場合は空文字列を返す。"""
    lines: list[str] = []

    old_keys = set(old_records.keys())
    new_keys = set(new_records.keys())

    # DELETE: 旧にあるが新にない
    for pk_key in sorted(old_keys - new_keys):
        where = _pk_where(pk_columns, pk_key)
        lines.append(f"DELETE FROM {table_name} WHERE {where};")

    # UPDATE: 両方にあるが値が異なる
    for pk_key in sorted(old_keys & new_keys):
        old_row = old_records[pk_key]
        new_row = new_records[pk_key]
        changed = {
            col: new_row[col]
            for col in all_columns
            if col not in pk_columns and old_row.get(col) != new_row.get(col)
        }
        if changed:
            set_clause = ", ".join(f"{col} = {val}" for col, val in changed.items())
            where = _pk_where(pk_columns, pk_key)
            lines.append(f"UPDATE {table_name} SET {set_clause} WHERE {where};")

    # INSERT: 新にあるが旧にない
    for pk_key in sorted(new_keys - old_keys):
        row = new_records[pk_key]
        values = ", ".join(row[col] for col in all_columns)
        lines.append(f"INSERT INTO {table_name} VALUES ({values});")

    return "\n".join(lines)


def _pk_where(pk_columns: list[str], pk_key: tuple[str, ...]) -> str:
    """WHERE 句の条件文字列を生成する。"""
    parts = [f"{col} = {val}" for col, val in zip(pk_columns, pk_key)]
    return " AND ".join(parts)
