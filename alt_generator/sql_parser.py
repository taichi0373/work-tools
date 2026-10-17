"""DDL/DML SQL ファイルのパーサー。"""
from __future__ import annotations

import re
from dataclasses import dataclass, field


@dataclass
class DDLColumn:
    name: str
    type_def: str      # 例: "VARCHAR(20) NOT NULL"
    is_not_null: bool


@dataclass
class DDLTable:
    table_name: str
    columns: list[DDLColumn]   # DDL 定義順
    primary_keys: list[str]    # 例: ["BENEFIT_ID"] or ["BENEFIT_ID", "CONDITION_CD"]
    full_sql: str              # 元の CREATE TABLE 文（COMMENT ON 含む）


# Records: {(pk_val,) または (pk_val1, pk_val2, ...): {"COL": "val", ...}}
Records = dict[tuple[str, ...], dict[str, str]]


def parse_ddl(sql_content: str) -> DDLTable:
    """DDL SQL ファイルの内容をパースして DDLTable を返す。"""
    # テーブル名
    m = re.search(r'CREATE\s+TABLE\s+(\w+)\s*\(', sql_content, re.IGNORECASE)
    if not m:
        raise ValueError("CREATE TABLE 文が見つかりません")
    table_name = m.group(1)

    # CREATE TABLE (...) のブロックを抽出
    start = sql_content.index('(', m.start())
    block = _extract_paren_block(sql_content, start)

    columns: list[DDLColumn] = []
    primary_keys: list[str] = []

    for line in block.splitlines():
        line = line.strip().rstrip(',')
        if not line:
            continue

        # PRIMARY KEY 制約
        pk_m = re.match(
            r'CONSTRAINT\s+\w+\s+PRIMARY\s+KEY\s*\(([^)]+)\)',
            line, re.IGNORECASE
        )
        if pk_m:
            primary_keys = [c.strip() for c in pk_m.group(1).split(',')]
            continue

        # CONSTRAINT 行（FK など）はスキップ
        if re.match(r'CONSTRAINT\b', line, re.IGNORECASE):
            continue

        # カラム行: COLUMN_NAME TYPE_DEF...
        col_m = re.match(r'(\w+)\s+(.+)', line)
        if col_m:
            col_name = col_m.group(1)
            type_def = col_m.group(2).strip()
            is_not_null = bool(re.search(r'\bNOT\s+NULL\b', type_def, re.IGNORECASE))
            columns.append(DDLColumn(name=col_name, type_def=type_def, is_not_null=is_not_null))

    return DDLTable(
        table_name=table_name,
        columns=columns,
        primary_keys=primary_keys,
        full_sql=sql_content.strip(),
    )


def _extract_paren_block(text: str, start: int) -> str:
    """start 位置の '(' から対応する ')' までの内側テキストを返す。"""
    depth = 0
    result = []
    for i in range(start, len(text)):
        ch = text[i]
        if ch == '(':
            depth += 1
            if depth == 1:
                continue
        elif ch == ')':
            depth -= 1
            if depth == 0:
                break
        if depth >= 1:
            result.append(ch)
    return ''.join(result)


def tokenize_values(values_str: str) -> list[str]:
    """VALUES (…) 文字列をトークンのリストに分解する。
    シングルクォート内のカンマは区切りとして扱わない。
    先頭・末尾の括弧は含んでいてもいなくてもよい。
    """
    s = values_str.strip()
    if s.startswith('(') and s.endswith(')'):
        s = s[1:-1]

    tokens: list[str] = []
    current: list[str] = []
    in_quote = False

    i = 0
    while i < len(s):
        ch = s[i]
        if ch == "'" and not in_quote:
            in_quote = True
            current.append(ch)
        elif ch == "'" and in_quote:
            # エスケープされたシングルクォート ('')
            if i + 1 < len(s) and s[i + 1] == "'":
                current.append("''")
                i += 2
                continue
            in_quote = False
            current.append(ch)
        elif ch == ',' and not in_quote:
            tokens.append(''.join(current).strip())
            current = []
        else:
            current.append(ch)
        i += 1

    if current or not tokens:
        tokens.append(''.join(current).strip())

    return tokens


def parse_dml(sql_content: str, columns: list[str], pk_columns: list[str]) -> Records:
    """DML SQL ファイルの内容をパースして Records を返す。
    INSERT INTO table VALUES (...); 形式を前提とする。
    """
    records: Records = {}
    pattern = re.compile(
        r'INSERT\s+INTO\s+\w+\s+VALUES\s*(\(.*?\))\s*;',
        re.IGNORECASE | re.DOTALL,
    )
    for m in pattern.finditer(sql_content):
        values_str = m.group(1)
        values = tokenize_values(values_str)
        if len(values) != len(columns):
            raise ValueError(
                f"カラム数 {len(columns)} とVALUES数 {len(values)} が一致しません: {values}"
            )
        row = dict(zip(columns, values))
        pk_key = tuple(row[pk] for pk in pk_columns)
        records[pk_key] = row
    return records
