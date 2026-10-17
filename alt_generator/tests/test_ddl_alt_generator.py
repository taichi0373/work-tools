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
  NAME         VARCHAR(400),
  NEW_REQUIRED VARCHAR(50) NOT NULL,
  CONSTRAINT BENEFIT_PK PRIMARY KEY (BENEFIT_ID)
);
COMMENT ON TABLE BENEFIT IS 'test';
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
    # BENEFIT_ID は共通カラム → INSERT に含まれる
    assert "BENEFIT_ID" in result
    # NAME は削除されたカラム → INSERT の SELECT に含まれない
    insert_part = result.split("INSERT INTO BENEFIT")[1]
    assert "NAME" not in insert_part


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
