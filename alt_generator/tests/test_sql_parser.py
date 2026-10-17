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
