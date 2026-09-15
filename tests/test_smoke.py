"""Smoke test.

Deliberately trivial: it proves the package installs, imports and runs under CI before any real
code exists.
"""

import gridstress


def test_package_imports_and_reports_a_version() -> None:
    assert isinstance(gridstress.__version__, str)
    assert gridstress.__version__
