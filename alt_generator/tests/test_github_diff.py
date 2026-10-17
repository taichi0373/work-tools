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
