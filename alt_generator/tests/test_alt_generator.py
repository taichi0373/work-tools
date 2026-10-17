from pathlib import Path
from unittest.mock import patch, MagicMock
from alt_generator.alt_generator import run_version


def test_run_version_creates_ddl_alt_file(tmp_path):
    """バージョン指定でDDL ALTファイルが正しい場所に生成される。"""
    diff_file = MagicMock()
    diff_file.table_name = "BENEFIT"
    diff_file.sql_type = "DDL"
    diff_file.old_content = (
        "CREATE TABLE BENEFIT (\n"
        "  ID VARCHAR(10) NOT NULL,\n"
        "  CONSTRAINT PK PRIMARY KEY (ID)\n"
        ");"
    )
    diff_file.new_content = (
        "CREATE TABLE BENEFIT (\n"
        "  ID VARCHAR(10) NOT NULL,\n"
        "  NAME VARCHAR(100),\n"
        "  CONSTRAINT PK PRIMARY KEY (ID)\n"
        ");"
    )

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


def test_run_version_ddl_and_dml_changed_together(tmp_path):
    """DDLとDMLが同時に変更された場合（カラム追加）、旧DMLは旧DDLのカラム数でパースされる。"""
    ddl_dir = tmp_path / "config/database/DDL/TABLE"
    ddl_dir.mkdir(parents=True)
    (ddl_dir / "BENEFIT.SQL").write_text(
        "CREATE TABLE BENEFIT (\n"
        "  BENEFIT_ID VARCHAR(20) NOT NULL,\n"
        "  NAME VARCHAR(100),\n"
        "  NEW_COL DATE,\n"
        "  CONSTRAINT PK PRIMARY KEY (BENEFIT_ID)\n"
        ");",
        encoding="utf-8",
    )

    ddl_diff = MagicMock()
    ddl_diff.table_name = "BENEFIT"
    ddl_diff.sql_type = "DDL"
    ddl_diff.old_content = (
        "CREATE TABLE BENEFIT (\n"
        "  BENEFIT_ID VARCHAR(20) NOT NULL,\n"
        "  NAME VARCHAR(100),\n"
        "  CONSTRAINT PK PRIMARY KEY (BENEFIT_ID)\n"
        ");"
    )
    ddl_diff.new_content = (
        "CREATE TABLE BENEFIT (\n"
        "  BENEFIT_ID VARCHAR(20) NOT NULL,\n"
        "  NAME VARCHAR(100),\n"
        "  NEW_COL DATE,\n"
        "  CONSTRAINT PK PRIMARY KEY (BENEFIT_ID)\n"
        ");"
    )

    dml_diff = MagicMock()
    dml_diff.table_name = "BENEFIT"
    dml_diff.sql_type = "DML"
    # 旧DMLは2カラム、新DMLは3カラム
    dml_diff.old_content = "INSERT INTO BENEFIT VALUES ('BEN-001', '旧名前');\n"
    dml_diff.new_content = "INSERT INTO BENEFIT VALUES ('BEN-001', '旧名前', NULL);\n"

    with patch("alt_generator.alt_generator.get_version_diff",
               return_value=("v1.0.0", [ddl_diff, dml_diff])):
        run_version(
            repo_path=str(tmp_path),
            version="v1.1.0",
            output_base=str(tmp_path / "config/database/Alt"),
        )

    ddl_out = tmp_path / "config/database/Alt/v1.1.0/DDL/Alt_BENEFIT.SQL"
    assert ddl_out.exists()
    # DMLに変更がないため DML ALT は生成されない
    dml_out = tmp_path / "config/database/Alt/v1.1.0/DML/Alt_BENEFIT.SQL"
    assert not dml_out.exists()


def test_run_version_creates_dml_alt_file(tmp_path):
    """DML変更でDML ALTファイルが生成される。DDLはディスク上のファイルから主キーを読む。"""
    ddl_dir = tmp_path / "config/database/DDL/TABLE"
    ddl_dir.mkdir(parents=True)
    (ddl_dir / "BENEFIT.SQL").write_text(
        "CREATE TABLE BENEFIT (\n"
        "  BENEFIT_ID VARCHAR(20) NOT NULL,\n"
        "  NAME VARCHAR(100),\n"
        "  CONSTRAINT PK PRIMARY KEY (BENEFIT_ID)\n"
        ");",
        encoding="utf-8",
    )

    diff_file = MagicMock()
    diff_file.table_name = "BENEFIT"
    diff_file.sql_type = "DML"
    diff_file.old_content = "INSERT INTO BENEFIT VALUES ('BEN-001', '旧名前');\n"
    diff_file.new_content = (
        "INSERT INTO BENEFIT VALUES ('BEN-001', '新名前');\n"
        "INSERT INTO BENEFIT VALUES ('BEN-002', '追加');\n"
    )

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
