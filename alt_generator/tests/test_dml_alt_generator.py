from alt_generator.dml_alt_generator import generate_dml_alt

PK = ["BENEFIT_ID"]
COLS = ["BENEFIT_ID", "MUNICIPALITY_CD", "BENEFIT_NAME", "SYS_CREATED_AT", "SYS_UPDATED_AT"]

OLD = {
    ("'BEN-001'",): {
        "BENEFIT_ID": "'BEN-001'", "MUNICIPALITY_CD": "'43'",
        "BENEFIT_NAME": "'名前A'",
        "SYS_CREATED_AT": "CURRENT_TIMESTAMP", "SYS_UPDATED_AT": "CURRENT_TIMESTAMP",
    },
    ("'BEN-002'",): {
        "BENEFIT_ID": "'BEN-002'", "MUNICIPALITY_CD": "'43'",
        "BENEFIT_NAME": "'名前B'",
        "SYS_CREATED_AT": "CURRENT_TIMESTAMP", "SYS_UPDATED_AT": "CURRENT_TIMESTAMP",
    },
}
NEW = {
    ("'BEN-001'",): {
        "BENEFIT_ID": "'BEN-001'", "MUNICIPALITY_CD": "'43'",
        "BENEFIT_NAME": "'名前A改'",
        "SYS_CREATED_AT": "CURRENT_TIMESTAMP", "SYS_UPDATED_AT": "CURRENT_TIMESTAMP",
    },
    ("'BEN-003'",): {
        "BENEFIT_ID": "'BEN-003'", "MUNICIPALITY_CD": "'44'",
        "BENEFIT_NAME": "'名前C'",
        "SYS_CREATED_AT": "CURRENT_TIMESTAMP", "SYS_UPDATED_AT": "CURRENT_TIMESTAMP",
    },
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
    old = {("'B-001'", "'CD-01'"): {
        "BENEFIT_ID": "'B-001'", "CONDITION_CD": "'CD-01'", "DETAIL": "'旧詳細'"
    }}
    new = {("'B-001'", "'CD-01'"): {
        "BENEFIT_ID": "'B-001'", "CONDITION_CD": "'CD-01'", "DETAIL": "'新詳細'"
    }}
    result = generate_dml_alt("BENEFIT_ELIGIBILITY", old, new, pk, cols)
    assert "WHERE BENEFIT_ID = 'B-001' AND CONDITION_CD = 'CD-01'" in result


def test_current_timestamp_preserved_in_update():
    old = {("'BEN-001'",): {
        "BENEFIT_ID": "'BEN-001'", "BENEFIT_NAME": "'旧名前'",
        "SYS_UPDATED_AT": "'2024-01-01 00:00:00'",
    }}
    new = {("'BEN-001'",): {
        "BENEFIT_ID": "'BEN-001'", "BENEFIT_NAME": "'新名前'",
        "SYS_UPDATED_AT": "CURRENT_TIMESTAMP",
    }}
    result = generate_dml_alt(
        "BENEFIT", old, new, ["BENEFIT_ID"],
        ["BENEFIT_ID", "BENEFIT_NAME", "SYS_UPDATED_AT"],
    )
    assert "SYS_UPDATED_AT = CURRENT_TIMESTAMP" in result
