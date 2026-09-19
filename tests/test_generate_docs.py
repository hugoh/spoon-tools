"""Tests for generate_docs.py."""

import subprocess
from pathlib import Path

import pytest

from generate_docs import _repo_url


def _git_repo_with_origin(tmp_path: Path, url: str) -> Path:
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "remote", "add", "origin", url], cwd=tmp_path, check=True)
    return tmp_path


@pytest.mark.parametrize(
    ("origin_url", "expected"),
    [
        (
            "https://x-access-token:ghs_abc123@github.com/hugoh/TeamsControl.spoon",
            "https://github.com/hugoh/TeamsControl.spoon",
        ),
        (
            "https://x-access-token:ghs_abc123@github.com/hugoh/TeamsControl.spoon.git",
            "https://github.com/hugoh/TeamsControl.spoon",
        ),
        (
            "git@github.com:hugoh/TeamsControl.spoon.git",
            "https://github.com/hugoh/TeamsControl.spoon",
        ),
        (
            "https://github.com/hugoh/TeamsControl.spoon.git",
            "https://github.com/hugoh/TeamsControl.spoon",
        ),
    ],
)
def test_repo_url_strips_credentials(
    tmp_path: Path, origin_url: str, expected: str
) -> None:
    repo = _git_repo_with_origin(tmp_path, origin_url)
    assert _repo_url(repo) == expected


def test_repo_url_returns_empty_without_origin(tmp_path: Path) -> None:
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    assert _repo_url(tmp_path) == ""
