# ALT SQL 自動生成ツール 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** kumamoto-henno-map プロジェクトのGit差分（PRまたはバージョンタグ間）からALT SQLファイルを自動生成するPython CLIツールを作成する。

**Architecture:** SQL パーサーが DDL/DML ファイルを解析し、DDL差分分類器が変更種別を判定して適切なALT戦略（MODIFY / BKコピー）を選択する。DML ALT ジェネレーターは主キーで旧新レコードを比較し INSERT/UPDATE/DELETE を生成する。Git/GitHub モジュールがファイルの旧新コンテンツを取得し、CLIが全体を統合する。

**Tech Stack:** Python 3.9+, gitpython >= 3.1, PyGithub >= 1.59, python-dotenv >= 1.0, pytest

**Spec:** `docs/superpowers/specs/2026-10-17-alt-sql-generator-design.md`

## Global Constraints

- Python 3.9+ を使用する
- 出力ファイル名は `Alt_{TABLE_NAME}.SQL`（大文字）
- DDL/DML の対象パスは `config/database/DDL/TABLE/*.SQL` と `config/database/DML/TABLE/*.SQL`
- ALT出力先: `config/database/Alt/{識別子}/DDL/` および `config/database/Alt/{識別子}/DML/`（識別子はバージョン名または `PR-{番号}`）
- WKテーブル判定: ファイル名（テーブル名）に `_WK_` を含む場合
- カラム追加のみの変更: `ALTER TABLE {table} MODIFY {col} {type};` を使用
- その他の構造変更: BKコピー方式（CREATE BK AS SELECT * → DROP → CREATE → INSERT FROM BK → DROP BK）
- NOT NULL 新規カラムには `-- WARNING: {col} is NOT NULL. Please set an appropriate default value before executing.` コメントを出力
- バージョン直前タグの判定: セマンティックバージョン順（数値比較）

## Review Focus

1. **カンマを含む文字列値のDMLパース** — `'九州産交バス / コミュニティバス'` のような値が正しく1トークンとして取得されること
2. **複合主キーのDML ALT生成** — `WHERE pk1 = val1 AND pk2 = val2` の形式で全PK列を含むこと（Task 4）
3. **CURRENT_TIMESTAMP のDML比較** — クォートなしキーワードとして保持され、UPDATE文に `CURRENT_TIMESTAMP` のまま出力されること（Task 4）
4. **DML変更のみ（DDL未変更）のケース** — DDLがdiffに含まれないテーブルのDML ALT生成時、ディスク上のDDLファイルから主キーを読み込めること（Task 6, 7）
5. **非semverタグの存在** — `v1.0.0-rc1` のようなタグが混在しても直前バージョン検出が誤らないこと（Task 5）

---

## ファイル構成

```
work_tools/alt_generator/
  __init__.py
  alt_generator.py          # CLIエントリーポイント
  sql_parser.py             # DDL/DMLパーサー + トークナイザー
  ddl_alt_generator.py      # DDL ALT生成（MODIFY / BKコピー判定含む）
  dml_alt_generator.py      # DML ALT生成（INSERT/UPDATE/DELETE）
  git_diff.py               # Gitタグ間差分取得
  github_diff.py            # GitHub PR差分取得
  requirements.txt
  .env.example
  tests/
    __init__.py
    test_sql_parser.py
    test_ddl_alt_generator.py
    test_dml_alt_generator.py
    test_git_diff.py
    test_github_diff.py
    conftest.py             # フィクスチャ（サンプルSQL文字列）
```

---

## Task 1: プロジェクトスキャフォールド

**Files:**
- Create: `alt_generator/__init__.py`
- Create: `alt_generator/requirements.txt`
- Create: `alt_generator/.env.example`
- Create: `alt_generator/tests/__init__.py`
- Create: `alt_generator/tests/conftest.py`

**Interfaces:**
- Produces: `conftest.py` の `BENEFIT_DDL_SQL: str` および `BENEFIT_DML_SQL: str` フィクスチャ（後続タスクのテストで共用）

- [ ] **Step 1: `requirements.txt` を作成する**

```
gitpython>=3.1.0
PyGithub>=1.59.0
python-dotenv>=1.0.0
pytest>=7.0.0
```

- [ ] **Step 2: `.env.example` を作成する**

```
GITHUB_TOKEN=your_personal_access_token_here
```

- [ ] **Step 3: `tests/conftest.py` にサンプルSQL文字列フィクスチャを定義する**

以下のフィクスチャを定義する（実際のBENEFIT.SQLと一致する内容）:

```python
import pytest

@pytest.fixture
def benefit_ddl_sql() -> str:
    return """CREATE TABLE BENEFIT (
  BENEFIT_ID            VARCHAR(20) NOT NULL,
  MUNICIPALITY_CD       VARCHAR(6) NOT NULL,
  CATEGORY_CD           VARCHAR(20) NOT NULL,
  BENEFIT_NAME          VARCHAR(400),
  SYS_CREATED_AT        TIMESTAMP,
  SYS_UPDATED_AT        TIMESTAMP,
  CONSTRAINT BENEFIT_PK PRIMARY KEY (BENEFIT_ID),
  CONSTRAINT BENEFIT_FK_MUN FOREIGN KEY (MUNICIPALITY_CD) REFERENCES MUNICIPALITY (MUNICIPALITY_CD)
);
COMMENT ON TABLE BENEFIT IS '運転免許返納特典テーブル';
COMMENT ON COLUMN BENEFIT.BENEFIT_ID IS '特典ID';
"""

@pytest.fixture
def benefit_dml_sql() -> str:
    return """INSERT INTO BENEFIT VALUES ('BEN-000001', '43', 'TR001', '九州産交バス / コミュニティバス', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
INSERT INTO BENEFIT VALUES ('BEN-000002', '43', 'TR002', '熊本電鉄バス', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
INSERT INTO BENEFIT VALUES ('BEN-000003', '43', 'TR003', NULL, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
"""

@pytest.fixture
def composite_pk_ddl_sql() -> str:
    return """CREATE TABLE BENEFIT_ELIGIBILITY (
  BENEFIT_ID    VARCHAR(20) NOT NULL,
  CONDITION_CD  VARCHAR(20) NOT NULL,
  DETAIL        VARCHAR(200),
  CONSTRAINT BENEFIT_ELIGIBILITY_PK PRIMARY KEY (BENEFIT_ID, CONDITION_CD)
);
"""
```

- [ ] **Step 4: 依存ライブラリをインストールする**

```bash
cd /c/Users/ta9ns/work_tools/alt_generator
pip install -r requirements.txt
```

- [ ] **Step 5: Commit**

```bash
git add alt_generator/
git commit -m "chore: scaffold alt_generator project structure"
```

---

## Task 2: SQLパーサー

**Files:**
- Create: `alt_generator/sql_parser.py`
- Create: `alt_generator/tests/test_sql_parser.py`

**Interfaces:**
- Produces:
  ```python
  @dataclass
  class DDLColumn:
      name: str          # 例: "BENEFIT_ID"
      type_def: str      # 例: "VARCHAR(20) NOT NULL"
      is_not_null: bool

  @dataclass
  class DDLTable:
      table_name: str
      columns: list[DDLColumn]   # DDL定義順
      primary_keys: list[str]    # 例: ["BENEFIT_ID"] or ["BENEFIT_ID", "CONDITION_CD"]
      full_sql: str              # 元のCREATE TABLE文（COMMENT ON含む）

  def parse_ddl(sql_content: str) -> DDLTable: ...

  # Records: {(pk_val,) または (pk_val1, pk_val2): {"COL": "val", ...}}
  Records = dict[tuple[str, ...], dict[str, str]]

  def parse_dml(sql_content: str, columns: list[str], pk_columns: list[str]) -> Records: ...

  def tokenize_values(values_str: str) -> list[str]: ...
  ```

- [ ] **Step 1: `test_sql_parser.py` に失敗テストを書く**

```python
from alt_generator.sql_parser import parse_ddl, parse_dml, tokenize_values

def test_parse_ddl_single_pk(benefit_ddl_sql):
    table = parse_ddl(benefit_ddl_sql)
    assert table.table_name == "BENEFIT"
    assert table.primary_keys == ["BENEFIT_ID"]
    assert table.columns[0].name == "BENEFIT_ID"
    assert table.columns[0].is_not_null is True
    assert table.columns[3].name == "BENEFIT_NAME"
    assert table.columns[3].is_not_null is False

def test_parse_ddl_composite_pk(composite_pk_ddl_sql):
    table = parse_ddl(composite_pk_ddl_sql)
    assert table.primary_keys == ["BENEFIT_ID", "CONDITION_CD"]

def test_tokenize_values_with_comma_in_string():
    result = tokenize_values("('BEN-001', '九州産交 / コミュニティ', NULL, CURRENT_TIMESTAMP)")
    assert result == ["'BEN-001'", "'九州産交 / コミュニティ'", "NULL", "CURRENT_TIMESTAMP"]

def test_tokenize_values_null_and_timestamp():
    result = tokenize_values("('BEN-001', NULL, CURRENT_TIMESTAMP)")
    assert result == ["'BEN-001'", "NULL", "CURRENT_TIMESTAMP"]

def test_parse_dml_maps_columns(benefit_dml_sql):
    columns = ["BENEFIT_ID", "MUNICIPALITY_CD", "CATEGORY_CD", "BENEFIT_NAME",
               "SYS_CREATED_AT", "SYS_UPDATED_AT"]
    records = parse_dml(benefit_dml_sql, columns, ["BENEFIT_ID"])
    assert ("'BEN-000001'",) in records
    rec = records[("'BEN-000001'",)]
    assert rec["BENEFIT_NAME"] == "'九州産交バス / コミュニティバス'"
    assert rec["SYS_CREATED_AT"] == "CURRENT_TIMESTAMP"

def test_parse_dml_null_value(benefit_dml_sql):
    columns = ["BENEFIT_ID", "MUNICIPALITY_CD", "CATEGORY_CD", "BENEFIT_NAME",
               "SYS_CREATED_AT", "SYS_UPDATED_AT"]
    records = parse_dml(benefit_dml_sql, columns, ["BENEFIT_ID"])
    assert records[("'BEN-000003'",)]["BENEFIT_NAME"] == "NULL"

def test_parse_dml_composite_pk(composite_pk_ddl_sql):
    dml = "INSERT INTO BENEFIT_ELIGIBILITY VALUES ('BEN-001', 'CD-01', '詳細1');\n"
    columns = ["BENEFIT_ID", "CONDITION_CD", "DETAIL"]
    records = parse_dml(dml, columns, ["BENEFIT_ID", "CONDITION_CD"])
    assert ("'BEN-001'", "'CD-01'") in records
```

- [ ] **Step 2: テストを実行して失敗を確認する**

```bash
cd /c/Users/ta9ns/work_tools
pytest alt_generator/tests/test_sql_parser.py -v
```
Expected: FAIL（ImportError または AttributeError）

- [ ] **Step 3: `sql_parser.py` に `DDLColumn`, `DDLTable`, `parse_ddl`, `tokenize_values`, `parse_dml` を実装する**

- `parse_ddl`: 正規表現で `CREATE TABLE (\w+)` からテーブル名取得、カラム行は `^\s+(\w+)\s+(.+?),$` パターンで抽出、`CONSTRAINT \w+ PRIMARY KEY \(([^)]+)\)` でPK取得
- `tokenize_values`: 文字列全体を1文字ずつ走査しシングルクォート内フラグを管理、クォート外のカンマで分割
- `parse_dml`: `INSERT INTO \w+ VALUES \((.+)\);` で各行のVALUES部分を抽出し `tokenize_values` でトークン化、`columns` と zip してdict化、PKカラムのタプルをキーとする

- [ ] **Step 4: テストを実行して全て通ることを確認する**

```bash
pytest alt_generator/tests/test_sql_parser.py -v
```
Expected: 全テスト PASS

- [ ] **Step 5: Commit**

```bash
git add alt_generator/sql_parser.py alt_generator/tests/test_sql_parser.py alt_generator/tests/conftest.py
git commit -m "feat: implement SQL DDL/DML parser with value tokenizer"
```

---

## Task 3: DDL ALT ジェネレーター

**Files:**
- Create: `alt_generator/ddl_alt_generator.py`
- Create: `alt_generator/tests/test_ddl_alt_generator.py`

**Interfaces:**
- Consumes: `DDLTable`, `DDLColumn` from `sql_parser`
- Produces:
  ```python
  def generate_ddl_alt(
      table_name: str,
      old_ddl: DDLTable | None,
      new_ddl: DDLTable | None,
  ) -> str:
      """DDL ALT SQLを生成して返す。old_ddl=Noneは新規テーブル、new_ddl=Noneは削除テーブル。"""
  ```

- [ ] **Step 1: `test_ddl_alt_generator.py` に失敗テストを書く**

```python
from alt_generator.ddl_alt_generator import generate_ddl_alt
from alt_generator.sql_parser import parse_ddl

BENEFIT_DDL = """CREATE TABLE BENEFIT (
  BENEFIT_ID  VARCHAR(20) NOT NULL,
  NAME        VARCHAR(400),
  CONSTRAINT BENEFIT_PK PRIMARY KEY (BENEFIT_ID)
);
COMMENT ON TABLE BENEFIT IS 'test';
"""

BENEFIT_DDL_ADDED = """CREATE TABLE BENEFIT (
  BENEFIT_ID   VARCHAR(20) NOT NULL,
  NAME         VARCHAR(400),
  NEW_COL      VARCHAR(100),
  CONSTRAINT BENEFIT_PK PRIMARY KEY (BENEFIT_ID)
);
COMMENT ON TABLE BENEFIT IS 'test';
"""

BENEFIT_DDL_NOTNULL = """CREATE TABLE BENEFIT (
  BENEFIT_ID   VARCHAR(20) NOT NULL,
  NEW_REQUIRED VARCHAR(50) NOT NULL,
  CONSTRAINT BENEFIT_PK PRIMARY KEY (BENEFIT_ID)
);
"""

BENEFIT_DDL_DELETED_COL = """CREATE TABLE BENEFIT (
  BENEFIT_ID  VARCHAR(20) NOT NULL,
  CONSTRAINT BENEFIT_PK PRIMARY KEY (BENEFIT_ID)
);
"""

WK_DDL = """CREATE TABLE IMPORT_WK_BENEFIT (
  WK_ID VARCHAR(10) NOT NULL
);
"""

def test_wk_table_uses_drop_create():
    old = parse_ddl(WK_DDL)
    new = parse_ddl(WK_DDL.replace("VARCHAR(10)", "VARCHAR(20)"))
    result = generate_ddl_alt("IMPORT_WK_BENEFIT", old, new)
    assert "DROP TABLE IF EXISTS IMPORT_WK_BENEFIT" in result
    assert "CREATE TABLE IMPORT_WK_BENEFIT" in result
    assert "CREATE TABLE IMPORT_WK_BENEFIT_BK" not in result

def test_column_add_only_uses_modify():
    old = parse_ddl(BENEFIT_DDL)
    new = parse_ddl(BENEFIT_DDL_ADDED)
    result = generate_ddl_alt("BENEFIT", old, new)
    assert "ALTER TABLE BENEFIT MODIFY NEW_COL VARCHAR(100)" in result
    assert "CREATE TABLE BENEFIT_BK" not in result

def test_column_delete_uses_bk_copy():
    old = parse_ddl(BENEFIT_DDL)
    new = parse_ddl(BENEFIT_DDL_DELETED_COL)
    result = generate_ddl_alt("BENEFIT", old, new)
    assert "CREATE TABLE BENEFIT_BK AS SELECT * FROM BENEFIT" in result
    assert "DROP TABLE BENEFIT;" in result
    assert "INSERT INTO BENEFIT" in result
    assert "FROM BENEFIT_BK" in result
    assert "DROP TABLE BENEFIT_BK" in result

def test_bk_copy_uses_common_columns_only():
    old = parse_ddl(BENEFIT_DDL)
    new = parse_ddl(BENEFIT_DDL_DELETED_COL)
    result = generate_ddl_alt("BENEFIT", old, new)
    assert "BENEFIT_ID" in result
    assert "NAME" not in result.split("INSERT INTO BENEFIT")[1]

def test_not_null_column_added_warning():
    old = parse_ddl(BENEFIT_DDL)
    new = parse_ddl(BENEFIT_DDL_NOTNULL)
    result = generate_ddl_alt("BENEFIT", old, new)
    assert "WARNING: NEW_REQUIRED is NOT NULL" in result
    assert "ALTER TABLE BENEFIT MODIFY NEW_REQUIRED" in result

def test_new_table_create_only():
    new = parse_ddl(BENEFIT_DDL)
    result = generate_ddl_alt("BENEFIT", None, new)
    assert result.startswith("CREATE TABLE BENEFIT")
    assert "BENEFIT_BK" not in result
    assert "DROP TABLE" not in result

def test_deleted_table_drop_only():
    old = parse_ddl(BENEFIT_DDL)
    result = generate_ddl_alt("BENEFIT", old, None)
    assert result.strip() == "DROP TABLE IF EXISTS BENEFIT;"
```

- [ ] **Step 2: テストを実行して失敗を確認する**

```bash
pytest alt_generator/tests/test_ddl_alt_generator.py -v
```
Expected: FAIL

- [ ] **Step 3: `ddl_alt_generator.py` に `generate_ddl_alt` を実装する**

判定ロジック（`_classify_change` ヘルパーを実装）:
1. `old_ddl is None` → `"new_table"`
2. `new_ddl is None` → `"deleted_table"`
3. テーブル名に `_WK_` → `"wk_table"`
4. 旧カラム名セットと新カラム名セットを比較: 削除・型変更・制約変更がなく追加のみ → `"columns_added_only"`
5. その他 → `"structural_change"`

各ケースの生成内容:
- `"new_table"`: `new_ddl.full_sql` をそのまま出力
- `"deleted_table"`: `DROP TABLE IF EXISTS {table_name};`
- `"wk_table"`: `DROP TABLE IF EXISTS {table_name};\n\n{new_ddl.full_sql}`
- `"columns_added_only"`: 追加カラムごとに `ALTER TABLE {table} MODIFY {col} {type_def};`（NOT NULL列にはWARNINGコメントを前置）
- `"structural_change"`: BKコピー方式のSQL文を組み立てる。共通カラムは `old_columns ∩ new_columns` のうち新DDLの定義順で並べる

- [ ] **Step 4: テストを実行して全て通ることを確認する**

```bash
pytest alt_generator/tests/test_ddl_alt_generator.py -v
```
Expected: 全テスト PASS

- [ ] **Step 5: Commit**

```bash
git add alt_generator/ddl_alt_generator.py alt_generator/tests/test_ddl_alt_generator.py
git commit -m "feat: implement DDL ALT generator (MODIFY / BK copy strategy)"
```

---

## Task 4: DML ALT ジェネレーター

**Files:**
- Create: `alt_generator/dml_alt_generator.py`
- Create: `alt_generator/tests/test_dml_alt_generator.py`

**Interfaces:**
- Consumes: `Records` (= `dict[tuple[str,...], dict[str, str]]`) from `sql_parser.parse_dml`
- Produces:
  ```python
  def generate_dml_alt(
      table_name: str,
      old_records: Records,
      new_records: Records,
      pk_columns: list[str],
      all_columns: list[str],
  ) -> str:
      """DML ALT SQLを生成して返す。変更なしの場合は空文字列を返す。"""
  ```

- [ ] **Step 1: `test_dml_alt_generator.py` に失敗テストを書く**

```python
from alt_generator.dml_alt_generator import generate_dml_alt

PK = ["BENEFIT_ID"]
COLS = ["BENEFIT_ID", "MUNICIPALITY_CD", "BENEFIT_NAME", "SYS_CREATED_AT", "SYS_UPDATED_AT"]

OLD = {
    ("'BEN-001'",): {"BENEFIT_ID": "'BEN-001'", "MUNICIPALITY_CD": "'43'", "BENEFIT_NAME": "'名前A'", "SYS_CREATED_AT": "CURRENT_TIMESTAMP", "SYS_UPDATED_AT": "CURRENT_TIMESTAMP"},
    ("'BEN-002'",): {"BENEFIT_ID": "'BEN-002'", "MUNICIPALITY_CD": "'43'", "BENEFIT_NAME": "'名前B'", "SYS_CREATED_AT": "CURRENT_TIMESTAMP", "SYS_UPDATED_AT": "CURRENT_TIMESTAMP"},
}
NEW = {
    ("'BEN-001'",): {"BENEFIT_ID": "'BEN-001'", "MUNICIPALITY_CD": "'43'", "BENEFIT_NAME": "'名前A改'", "SYS_CREATED_AT": "CURRENT_TIMESTAMP", "SYS_UPDATED_AT": "CURRENT_TIMESTAMP"},
    ("'BEN-003'",): {"BENEFIT_ID": "'BEN-003'", "MUNICIPALITY_CD": "'44'", "BENEFIT_NAME": "'名前C'", "SYS_CREATED_AT": "CURRENT_TIMESTAMP", "SYS_UPDATED_AT": "CURRENT_TIMESTAMP"},
}

def test_update_changed_record():
    result = generate_dml_alt("BENEFIT", OLD, NEW, PK, COLS)
    assert "UPDATE BENEFIT SET" in result
    assert "BENEFIT_NAME = '名前A改'" in result
    assert "WHERE BENEFIT_ID = 'BEN-001'" in result

def test_delete_removed_record():
    result = generate_dml_alt("BENEFIT", OLD, NEW, PK, COLS)
    assert "DELETE FROM BENEFIT WHERE BENEFIT_ID = 'BEN-002'" in result

def test_insert_new_record():
    result = generate_dml_alt("BENEFIT", OLD, NEW, PK, COLS)
    assert "INSERT INTO BENEFIT VALUES ('BEN-003'" in result

def test_no_changes_returns_empty():
    result = generate_dml_alt("BENEFIT", OLD, OLD, PK, COLS)
    assert result == ""

def test_composite_pk_where_clause():
    pk = ["BENEFIT_ID", "CONDITION_CD"]
    cols = ["BENEFIT_ID", "CONDITION_CD", "DETAIL"]
    old = {("'B-001'", "'CD-01'"): {"BENEFIT_ID": "'B-001'", "CONDITION_CD": "'CD-01'", "DETAIL": "'旧詳細'"}}
    new = {("'B-001'", "'CD-01'"): {"BENEFIT_ID": "'B-001'", "CONDITION_CD": "'CD-01'", "DETAIL": "'新詳細'"}}
    result = generate_dml_alt("BENEFIT_ELIGIBILITY", old, new, pk, cols)
    assert "WHERE BENEFIT_ID = 'B-001' AND CONDITION_CD = 'CD-01'" in result

def test_current_timestamp_preserved_in_update():
    old = {("'BEN-001'",): {"BENEFIT_ID": "'BEN-001'", "BENEFIT_NAME": "'旧名前'", "SYS_UPDATED_AT": "CURRENT_TIMESTAMP"}}
    new = {("'BEN-001'",): {"BENEFIT_ID": "'BEN-001'", "BENEFIT_NAME": "'新名前'", "SYS_UPDATED_AT": "CURRENT_TIMESTAMP"}}
    result = generate_dml_alt("BENEFIT", old, new, ["BENEFIT_ID"], ["BENEFIT_ID", "BENEFIT_NAME", "SYS_UPDATED_AT"])
    assert "SYS_UPDATED_AT = CURRENT_TIMESTAMP" in result
```

- [ ] **Step 2: テストを実行して失敗を確認する**

```bash
pytest alt_generator/tests/test_dml_alt_generator.py -v
```
Expected: FAIL

- [ ] **Step 3: `dml_alt_generator.py` に `generate_dml_alt` を実装する**

- DELETE: `old_records.keys() - new_records.keys()` のキーについて `DELETE FROM {table} WHERE {pk_clause};` を生成
- INSERT: `new_records.keys() - old_records.keys()` のキーについて `INSERT INTO {table} VALUES ({all_columns_values});` を生成（`all_columns` 順でカラム値を並べる）
- UPDATE: 両方に存在するキーで値が異なる場合 `UPDATE {table} SET {changed_cols} WHERE {pk_clause};`
  - `pk_clause`: `" AND ".join(f"{col} = {val}" for col, val in zip(pk_columns, pk_tuple))`（値はクォート付きのまま出力）
  - SET節: PK以外の変更カラムのみ対象

- [ ] **Step 4: テストを実行して全て通ることを確認する**

```bash
pytest alt_generator/tests/test_dml_alt_generator.py -v
```
Expected: 全テスト PASS

- [ ] **Step 5: Commit**

```bash
git add alt_generator/dml_alt_generator.py alt_generator/tests/test_dml_alt_generator.py
git commit -m "feat: implement DML ALT generator (INSERT/UPDATE/DELETE)"
```

---

## Task 5: Gitタグ間差分取得

**Files:**
- Create: `alt_generator/git_diff.py`
- Create: `alt_generator/tests/test_git_diff.py`

**Interfaces:**
- Produces:
  ```python
  @dataclass
  class DiffedFile:
      table_name: str        # 例: "BENEFIT"
      sql_type: str          # "DDL" または "DML"
      old_content: str | None  # None = 新規追加
      new_content: str | None  # None = 削除

  def get_previous_version(repo_path: str, version: str) -> str:
      """セマンティックバージョン順で直前のタグを返す。"""

  def get_version_diff(repo_path: str, version: str) -> tuple[str, list[DiffedFile]]:
      """(previous_version, [DiffedFile]) を返す。"""
  ```

- [ ] **Step 1: `test_git_diff.py` に失敗テストを書く**

```python
from alt_generator.git_diff import get_previous_version

def test_get_previous_version_basic():
    # タグリストを直接渡して単体テストする補助関数でテスト
    from alt_generator.git_diff import _find_previous_version
    tags = ["v1.0.0", "v1.1.0", "v1.1.3", "v1.2.0"]
    assert _find_previous_version("v1.1.3", tags) == "v1.1.0"

def test_get_previous_version_skips_non_semver():
    from alt_generator.git_diff import _find_previous_version
    tags = ["v1.0.0", "v1.0.0-rc1", "v1.1.0", "v1.1.3"]
    assert _find_previous_version("v1.1.3", tags) == "v1.1.0"

def test_get_previous_version_first_version():
    from alt_generator.git_diff import _find_previous_version
    tags = ["v0.1.0", "v1.0.0"]
    # v0.1.0 の前バージョンは存在しない
    import pytest
    with pytest.raises(ValueError, match="previous version"):
        _find_previous_version("v0.1.0", tags)
```

- [ ] **Step 2: テストを実行して失敗を確認する**

```bash
pytest alt_generator/tests/test_git_diff.py -v
```
Expected: FAIL

- [ ] **Step 3: `git_diff.py` に `_find_previous_version`, `get_previous_version`, `get_version_diff` を実装する**

- `_find_previous_version(version: str, tags: list[str]) -> str`: `vX.Y.Z` 形式のタグのみ対象（`re.match(r'^v\d+\.\d+\.\d+$', tag)`）。タプル `(X, Y, Z)` で数値比較ソートし、指定バージョンの直前を返す。存在しなければ `ValueError`
- `get_previous_version`: `git.Repo(repo_path).tags` からタグ名を取得して `_find_previous_version` に渡す
- `get_version_diff`: `gitpython` の `repo.git.show(f"{prev_tag}:{file_path}")` で旧ファイル内容を取得し、`repo.git.show(f"{version}:{file_path}")` で新ファイル内容を取得。`repo.git.diff(prev_tag, version, "--name-status")` で変更ファイルリストを取得

- [ ] **Step 4: テストを実行して全て通ることを確認する**

```bash
pytest alt_generator/tests/test_git_diff.py -v
```
Expected: 全テスト PASS

- [ ] **Step 5: Commit**

```bash
git add alt_generator/git_diff.py alt_generator/tests/test_git_diff.py
git commit -m "feat: implement git version-based diff retrieval"
```

---

## Task 6: GitHub PR差分取得

**Files:**
- Create: `alt_generator/github_diff.py`
- Create: `alt_generator/tests/test_github_diff.py`

**Interfaces:**
- Consumes: `DiffedFile` from `git_diff`
- Produces:
  ```python
  def get_pr_diff(
      repo_path: str,
      pr_number: int,
      github_token: str,
      github_repo: str,  # 例: "taichi0373/kumamoto-henno-map"
  ) -> list[DiffedFile]:
      """GitHub PRの変更SQLファイルリストを返す。ファイル内容はローカルcloneから取得。"""
  ```

- [ ] **Step 1: `test_github_diff.py` に失敗テストを書く**

```python
from unittest.mock import patch, MagicMock
from alt_generator.github_diff import get_pr_diff

def test_get_pr_diff_filters_sql_files():
    mock_file1 = MagicMock()
    mock_file1.filename = "config/database/DDL/TABLE/BENEFIT.SQL"
    mock_file1.status = "modified"
    mock_file2 = MagicMock()
    mock_file2.filename = "apps/back/src/SomeClass.java"
    mock_file2.status = "modified"

    mock_pr = MagicMock()
    mock_pr.get_files.return_value = [mock_file1, mock_file2]
    mock_pr.base.sha = "abc123"
    mock_pr.head.sha = "def456"

    with patch("alt_generator.github_diff.Github") as mock_github:
        mock_repo = MagicMock()
        mock_repo.get_pull.return_value = mock_pr
        mock_github.return_value.get_repo.return_value = mock_repo

        with patch("alt_generator.github_diff._get_file_content_at_commit") as mock_content:
            mock_content.return_value = "CREATE TABLE BENEFIT (...)"
            result = get_pr_diff("/fake/path", 42, "token", "owner/repo")

    assert len(result) == 1
    assert result[0].table_name == "BENEFIT"
    assert result[0].sql_type == "DDL"
```

- [ ] **Step 2: テストを実行して失敗を確認する**

```bash
pytest alt_generator/tests/test_github_diff.py -v
```
Expected: FAIL

- [ ] **Step 3: `github_diff.py` に実装する**

- `_get_file_content_at_commit(repo_path: str, commit_sha: str, file_path: str) -> str | None`: `git show {sha}:{file_path}` をサブプロセスで実行。ファイルが存在しない場合（新規/削除）は `None` を返す
- `get_pr_diff`: `PyGithub` の `Github(token).get_repo(github_repo).get_pull(pr_number)` でPR情報取得。変更ファイルの中から `config/database/DDL/TABLE/` または `config/database/DML/TABLE/` に含まれる `.SQL` ファイルのみ対象。各ファイルについて `_get_file_content_at_commit` でベースコミットと HEADコミットの内容を取得して `DiffedFile` を組み立てる

- [ ] **Step 4: テストを実行して通ることを確認する**

```bash
pytest alt_generator/tests/test_github_diff.py -v
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add alt_generator/github_diff.py alt_generator/tests/test_github_diff.py
git commit -m "feat: implement GitHub PR-based diff retrieval"
```

---

## Task 7: CLIエントリーポイントと統合

**Files:**
- Create: `alt_generator/alt_generator.py`
- Create: `alt_generator/tests/test_alt_generator.py`

**Interfaces:**
- Consumes: `get_version_diff`, `get_pr_diff`, `DiffedFile` (Task 5/6); `parse_ddl`, `parse_dml` (Task 2); `generate_ddl_alt` (Task 3); `generate_dml_alt` (Task 4)

**CLI仕様:**
```bash
python -m alt_generator.alt_generator pr <PR番号> --repo-path <path> [--output-base <path>]
python -m alt_generator.alt_generator version <バージョン> --repo-path <path> [--output-base <path>]
```
`--output-base` 省略時は `{repo_path}/config/database/Alt/` を使用する。

- [ ] **Step 1: `test_alt_generator.py` に失敗テストを書く（統合テスト）**

```python
import os
import tempfile
from pathlib import Path
from unittest.mock import patch, MagicMock
from alt_generator.alt_generator import run_version

def test_run_version_creates_ddl_alt_file(tmp_path):
    """バージョン指定でDDL ALTファイルが正しい場所に生成される"""
    diff_file = MagicMock()
    diff_file.table_name = "BENEFIT"
    diff_file.sql_type = "DDL"
    diff_file.old_content = "CREATE TABLE BENEFIT (ID VARCHAR(10) NOT NULL, CONSTRAINT PK PRIMARY KEY (ID));"
    diff_file.new_content = "CREATE TABLE BENEFIT (ID VARCHAR(10) NOT NULL, NAME VARCHAR(100), CONSTRAINT PK PRIMARY KEY (ID));"

    with patch("alt_generator.alt_generator.get_version_diff", return_value=("v1.1.4", [diff_file])):
        run_version(
            repo_path=str(tmp_path),
            version="v1.1.5",
            output_base=str(tmp_path / "config/database/Alt"),
        )

    output_path = tmp_path / "config/database/Alt/v1.1.5/DDL/Alt_BENEFIT.SQL"
    assert output_path.exists()
    content = output_path.read_text(encoding="utf-8")
    assert "ALTER TABLE BENEFIT MODIFY NAME VARCHAR(100)" in content

def test_run_version_creates_dml_alt_file(tmp_path):
    """DML変更でDML ALTファイルが生成される。DDLはディスク上のファイルから主キーを読む。"""
    # DDLファイルをtmp_pathに配置
    ddl_dir = tmp_path / "config/database/DDL/TABLE"
    ddl_dir.mkdir(parents=True)
    (ddl_dir / "BENEFIT.SQL").write_text(
        "CREATE TABLE BENEFIT (BENEFIT_ID VARCHAR(20) NOT NULL, NAME VARCHAR(100), CONSTRAINT PK PRIMARY KEY (BENEFIT_ID));",
        encoding="utf-8"
    )

    diff_file = MagicMock()
    diff_file.table_name = "BENEFIT"
    diff_file.sql_type = "DML"
    diff_file.old_content = "INSERT INTO BENEFIT VALUES ('BEN-001', '旧名前');\n"
    diff_file.new_content = "INSERT INTO BENEFIT VALUES ('BEN-001', '新名前');\nINSERT INTO BENEFIT VALUES ('BEN-002', '追加');\n"

    with patch("alt_generator.alt_generator.get_version_diff", return_value=("v1.1.4", [diff_file])):
        run_version(
            repo_path=str(tmp_path),
            version="v1.1.5",
            output_base=str(tmp_path / "config/database/Alt"),
        )

    output_path = tmp_path / "config/database/Alt/v1.1.5/DML/Alt_BENEFIT.SQL"
    assert output_path.exists()
    content = output_path.read_text(encoding="utf-8")
    assert "UPDATE BENEFIT SET" in content
    assert "INSERT INTO BENEFIT VALUES ('BEN-002'" in content
```

- [ ] **Step 2: テストを実行して失敗を確認する**

```bash
pytest alt_generator/tests/test_alt_generator.py -v
```
Expected: FAIL

- [ ] **Step 3: `alt_generator.py` に `run_version`, `run_pr`, `main` を実装する**

```python
def run_version(repo_path: str, version: str, output_base: str) -> None: ...
def run_pr(repo_path: str, pr_number: int, github_token: str, github_repo: str, output_base: str) -> None: ...
```

共通処理 `_process_diff_files(diff_files, repo_path, output_base, identifier)`:
1. 各 `DiffedFile` について処理
2. `sql_type == "DDL"`: `parse_ddl` で旧/新を解析 → `generate_ddl_alt` → `{output_base}/{identifier}/DDL/Alt_{table_name}.SQL` に書き込み
3. `sql_type == "DML"`: 対応DDLをディスクの `{repo_path}/config/database/DDL/TABLE/{table_name}.SQL` から読み込んでカラムとPKを取得 → `parse_dml` で旧/新を解析 → `generate_dml_alt` → `{output_base}/{identifier}/DML/Alt_{table_name}.SQL` に書き込み（空文字列の場合はファイル未作成）

`main`: `argparse` で `pr` / `version` サブコマンドを定義。`python-dotenv` で `.env` をロードし `GITHUB_TOKEN` を取得。

- [ ] **Step 4: テストを実行して全て通ることを確認する**

```bash
pytest alt_generator/tests/ -v
```
Expected: 全テスト PASS

- [ ] **Step 5: 実際のリポジトリで動作確認する（手動）**

```bash
cd /c/Users/ta9ns/work_tools
# バージョンベース
python -m alt_generator.alt_generator version v1.1.5 \
  --repo-path /c/Users/ta9ns/kumamoto-henno-map

# PRベース（有効なPR番号に変更して実行）
python -m alt_generator.alt_generator pr 1 \
  --repo-path /c/Users/ta9ns/kumamoto-henno-map
```

生成された `Alt_*.SQL` ファイルの内容を目視確認する。

- [ ] **Step 6: Commit**

```bash
git add alt_generator/alt_generator.py alt_generator/tests/test_alt_generator.py
git commit -m "feat: implement CLI entry point and integration for ALT SQL generator"
```
