import pytest
from alt_generator.git_diff import _find_previous_version


def test_get_previous_version_basic():
    tags = ["v1.0.0", "v1.1.0", "v1.1.3", "v1.2.0"]
    assert _find_previous_version("v1.1.3", tags) == "v1.1.0"


def test_get_previous_version_skips_non_semver():
    tags = ["v1.0.0", "v1.0.0-rc1", "v1.1.0", "v1.1.3"]
    assert _find_previous_version("v1.1.3", tags) == "v1.1.0"


def test_get_previous_version_first_version():
    tags = ["v0.1.0", "v1.0.0"]
    with pytest.raises(ValueError, match="previous version"):
        _find_previous_version("v0.1.0", tags)
