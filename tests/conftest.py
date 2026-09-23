"""Fixtures shared by every test in this folder."""

import pytest

DUMMY_TOKEN = "test-token-not-a-real-one"


@pytest.fixture(autouse=True)
def dummy_token(monkeypatch):
    """Give every test a token that is not the real one.

    api_request reads ENTSOE_TOKEN from the environment each time it runs. Setting it here keeps
    the tests independent of the machine they run on, lets them run in CI, which has no token, and
    makes it possible to assert that the value never reaches the output.
    """
    monkeypatch.setenv("ENTSOE_TOKEN", DUMMY_TOKEN)
