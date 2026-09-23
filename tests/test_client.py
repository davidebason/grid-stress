"""Tests for the ENTSO-E client. Nothing here touches the network.

window_edges is pure: it turns a UTC range into the window boundaries the fetch will request. The
expectations below are written from the calendar, not from the function: a boundary is correct when
it is midnight on the Amsterdam clock, which is 23:00Z the previous day in winter and 22:00Z in
summer.
"""

from datetime import UTC, datetime
from zoneinfo import ZoneInfo

import pytest
import requests

from conftest import DUMMY_TOKEN
from gridstress import client
from gridstress.client import DATE_FORMAT, WINDOW_DAYS, window_edges

AMSTERDAM = ZoneInfo("Europe/Amsterdam")

# The project's range: 2021-01-01 to 2026-09-01, both at midnight in Amsterdam.
RANGE_BEGIN = "202012312300"
RANGE_END = "202608312200"


def local_time(edge):
    """The Amsterdam wall-clock time of an edge, as a string like '00:00'."""
    return (
        datetime.strptime(edge, DATE_FORMAT)
        .replace(tzinfo=UTC)
        .astimezone(AMSTERDAM)
        .strftime("%H:%M")
    )


def test_a_range_shorter_than_one_window_is_a_single_window():
    assert window_edges("202012312300", "202101032300") == ["202012312300", "202101032300"]


def test_the_range_is_returned_unchanged_at_both_ends():
    edges = window_edges(RANGE_BEGIN, RANGE_END)
    assert edges[0] == RANGE_BEGIN
    assert edges[-1] == RANGE_END


def test_edges_are_strictly_increasing():
    edges = window_edges(RANGE_BEGIN, RANGE_END)
    assert edges == sorted(edges)
    assert len(set(edges)) == len(edges)


def test_each_window_starts_where_the_previous_one_ended():
    edges = window_edges(RANGE_BEGIN, RANGE_END)
    windows = list(zip(edges, edges[1:], strict=False))
    for (_, first_end), (second_start, _) in zip(windows, windows[1:], strict=False):
        assert first_end == second_start


def test_a_whole_number_of_windows_leaves_no_empty_last_window():
    # 1 January 2021 plus 600 local days is 24 August 2022, both local midnights.
    edges = window_edges("202012312300", "202208232200", 300)
    assert edges == ["202012312300", "202110272200", "202208232200"]


def test_a_winter_only_range_keeps_the_winter_offset():
    # 1 November 2021 to 1 January 2022, in 30-day windows: all inside winter time.
    assert window_edges("202110312300", "202112312300", 30) == [
        "202110312300",
        "202111302300",
        "202112302300",
        "202112312300",
    ]


@pytest.mark.parametrize("window_days", [1, 7, 30, 90, 300])
def test_every_boundary_is_local_midnight_whatever_the_window(window_days):
    edges = window_edges(RANGE_BEGIN, RANGE_END, window_days)
    assert {local_time(edge) for edge in edges} == {"00:00"}


def test_boundaries_change_utc_offset_across_the_clock_changes():
    # 1 March to 1 November 2021 in 30-day windows: the range spans both clock changes, so the
    # boundaries must be 23:00Z in winter and 22:00Z in summer, all of them local midnight.
    edges = window_edges("202103012300", "202111012300", 30)
    assert edges[0].endswith("2300")
    assert edges[1].endswith("2200")
    assert edges[-1].endswith("2300")
    assert {local_time(edge) for edge in edges} == {"00:00"}


def test_a_range_that_does_not_start_at_midnight_keeps_its_own_clock_time():
    # 13:00 Amsterdam on 1 January 2021 is 12:00Z; the boundaries stay at 13:00 local.
    edges = window_edges("202101011200", "202301011200", 300)
    assert {local_time(edge) for edge in edges} == {"13:00"}
    assert edges[1].endswith("1100")  # summer, so 11:00Z


def test_the_project_range_splits_into_seven_windows():
    edges = window_edges(RANGE_BEGIN, RANGE_END, WINDOW_DAYS)
    assert len(edges) - 1 == 7


def local_date(edge):
    """The Amsterdam calendar date of an edge."""
    return datetime.strptime(edge, DATE_FORMAT).replace(tzinfo=UTC).astimezone(AMSTERDAM).date()


def test_every_window_but_the_last_is_a_full_window_of_local_days():
    # Local days, not elapsed hours: a window crossing a clock change is 300 local days but 299
    # days and 23 hours of elapsed time, which is exactly what stepping in local days is for.
    edges = window_edges(RANGE_BEGIN, RANGE_END, WINDOW_DAYS)
    lengths = [
        (local_date(end) - local_date(start)).days
        for start, end in zip(edges, edges[1:], strict=False)
    ]
    assert lengths[:-1] == [WINDOW_DAYS] * (len(lengths) - 1)
    assert 0 < lengths[-1] <= WINDOW_DAYS


def fake_response(status_code):
    """A requests.Response carrying only a status code, which is all the client reads."""
    response = requests.Response()
    response.status_code = status_code
    return response


def test_a_first_attempt_that_succeeds_is_returned_without_waiting(monkeypatch):
    response = fake_response(200)
    calls = []
    waits = []

    def fake_get(url, params, timeout):
        calls.append({"url": url, "params": params, "timeout": timeout})
        return response

    monkeypatch.setattr(client.requests, "get", fake_get)
    monkeypatch.setattr(client.time, "sleep", waits.append)

    out = client.error_or_not_api(
        "202012312300", "202101302300", {"documentType": "A65"}, timeout=30
    )

    assert out is response
    assert len(calls) == 1
    assert calls[0] == {
        "url": client.BASE_URL,
        "params": {"documentType": "A65"},
        "timeout": 30,
    }
    assert waits == []


def test_a_window_crossing_the_spring_change_loses_an_hour_of_elapsed_time():
    edges = window_edges("202012312300", "202208232200", 300)
    elapsed = datetime.strptime(edges[1], DATE_FORMAT).replace(tzinfo=UTC) - datetime.strptime(
        edges[0], DATE_FORMAT
    ).replace(tzinfo=UTC)
    assert (local_date(edges[1]) - local_date(edges[0])).days == 300
    assert elapsed.days == 299
    assert elapsed.seconds == 23 * 3600


# error_or_not_api: one window, with retries. requests.get and time.sleep are replaced throughout,
# so nothing reaches the network and nothing waits; the recorded calls and waits are the evidence.


def recorder(monkeypatch, outcomes):
    """Replace requests.get with one that serves `outcomes` in turn, and time.sleep with a log.

    An outcome that is an exception instance is raised, anything else is returned. Returns the
    list of calls made and the list of waits taken, both filled in as the client runs.
    """
    calls = []
    waits = []
    remaining = list(outcomes)

    def fake_get(url, params, timeout):
        calls.append({"url": url, "params": dict(params), "timeout": timeout})
        outcome = remaining.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    monkeypatch.setattr(client.requests, "get", fake_get)
    monkeypatch.setattr(client.time, "sleep", waits.append)
    return calls, waits


def test_a_window_that_fails_every_attempt_on_5xx_is_reported_as_missing(monkeypatch):
    calls, waits = recorder(monkeypatch, [fake_response(503)] * client.N_ATTEMPTS)

    out = client.error_or_not_api("202012312300", "202101302300", {}, timeout=30)

    assert out == 1
    assert len(calls) == client.N_ATTEMPTS
    assert waits == [2, 3, 5, 9, 17]  # doubling, and none after the last attempt


def test_a_5xx_that_clears_returns_the_later_response(monkeypatch):
    good = fake_response(200)
    calls, waits = recorder(monkeypatch, [fake_response(503), fake_response(500), good])

    out = client.error_or_not_api("202012312300", "202101302300", {}, timeout=30)

    assert out is good
    assert len(calls) == 3
    assert waits == [2, 3]


@pytest.mark.parametrize("status", [400, 401, 403, 404, 429])
def test_a_4xx_stops_the_fetch_without_retrying(monkeypatch, status):
    calls, waits = recorder(monkeypatch, [fake_response(status)])

    out = client.error_or_not_api("202012312300", "202101302300", {}, timeout=30)

    assert out == 0
    assert len(calls) == 1
    assert waits == []


@pytest.mark.parametrize(
    "error",
    [
        requests.exceptions.ConnectTimeout(),
        requests.exceptions.ReadTimeout(),
        requests.exceptions.ConnectionError(),
        requests.exceptions.ChunkedEncodingError(),
    ],
)
def test_a_retriable_exception_is_retried(monkeypatch, error):
    good = fake_response(200)
    calls, waits = recorder(monkeypatch, [error, good])

    out = client.error_or_not_api("202012312300", "202101302300", {}, timeout=30)

    assert out is good
    assert len(calls) == 2
    assert waits == [2]


@pytest.mark.parametrize(
    "error",
    [
        requests.exceptions.SSLError(),  # a ConnectionError, but excluded by name
        requests.exceptions.TooManyRedirects(),
        requests.exceptions.MissingSchema(),
    ],
)
def test_an_exception_a_retry_cannot_cure_stops_the_fetch(monkeypatch, error):
    calls, waits = recorder(monkeypatch, [error])

    out = client.error_or_not_api("202012312300", "202101302300", {}, timeout=30)

    assert out == 0
    assert len(calls) == 1
    assert waits == []


# api_request: the whole range, window by window.

THREE_WINDOWS = (RANGE_BEGIN, "202212312300")
THREE_EDGES = window_edges(*THREE_WINDOWS)


def fetch_three_windows(timeout=30, **kwargs):
    """Fetch the three-window range as load, with whatever extra arguments a test needs."""
    return client.api_request(
        "A65", "A16", *THREE_WINDOWS, timeout, "outBiddingZone_Domain", "10YNL----------L", **kwargs
    )


def test_every_window_is_fetched_and_labelled_with_its_own_edges(monkeypatch):
    responses_sent = [fake_response(200) for _ in range(3)]
    calls, _ = recorder(monkeypatch, responses_sent)

    missing, responses = fetch_three_windows()

    assert missing == []
    assert [(start, end) for start, end, _ in responses] == list(
        zip(THREE_EDGES, THREE_EDGES[1:], strict=False)
    )
    assert [r for _, _, r in responses] == responses_sent
    assert [(call["params"]["periodStart"], call["params"]["periodEnd"]) for call in calls] == list(
        zip(THREE_EDGES, THREE_EDGES[1:], strict=False)
    )


def test_a_window_that_fails_every_attempt_leaves_the_others_fetched(monkeypatch):
    outcomes = [fake_response(200), *[fake_response(503)] * client.N_ATTEMPTS, fake_response(200)]
    recorder(monkeypatch, outcomes)

    missing, responses = fetch_three_windows()

    assert missing == [(THREE_EDGES[1], THREE_EDGES[2])]
    assert [(start, end) for start, end, _ in responses] == [
        (THREE_EDGES[0], THREE_EDGES[1]),
        (THREE_EDGES[2], THREE_EDGES[3]),
    ]
    # Every window is accounted for exactly once, in one list or the other.
    accounted = missing + [(start, end) for start, end, _ in responses]
    assert sorted(accounted) == sorted(zip(THREE_EDGES, THREE_EDGES[1:], strict=False))


def test_a_permanent_failure_stops_the_run_and_returns_nothing(monkeypatch):
    calls, _ = recorder(monkeypatch, [fake_response(200), fake_response(400), fake_response(200)])

    out = fetch_three_windows()

    assert out is None
    assert len(calls) == 2  # the third window is never requested


def test_unusable_dates_send_no_request(monkeypatch):
    calls, _ = recorder(monkeypatch, [])

    out = client.api_request(
        "A65", "A16", "202212312300", RANGE_BEGIN, 30, "outBiddingZone_Domain", "Z"
    )

    assert out == "date_begin is after date_end!"
    assert calls == []


def test_the_query_carries_the_token_and_omits_a_process_type_that_is_none(monkeypatch):
    calls, _ = recorder(monkeypatch, [fake_response(200) for _ in range(3)])

    client.api_request("A44", None, *THREE_WINDOWS, 30, "in_Domain", "10YNL----------L")

    sent = calls[0]["params"]
    assert sent["securityToken"] == DUMMY_TOKEN
    assert sent["documentType"] == "A44"
    assert sent["processType"] is None  # requests leaves a None parameter out of the URL
    assert sent["in_Domain"] == "10YNL----------L"


@pytest.mark.parametrize(
    ("domain_2", "zone_2", "expected"),
    [
        ("out_Domain", "10YNL----------L", True),
        ("out_Domain", None, False),
        (None, "10YNL----------L", False),
        (None, None, False),
    ],
)
def test_the_second_zone_is_sent_only_when_both_halves_are_given(
    monkeypatch, domain_2, zone_2, expected
):
    calls, _ = recorder(monkeypatch, [fake_response(200) for _ in range(3)])

    fetch_three_windows(domain_2=domain_2, zone_2=zone_2)

    assert ("out_Domain" in calls[0]["params"]) is expected


def test_the_token_never_reaches_the_printed_output(monkeypatch, capsys):
    # A run that fails in both ways: one window exhausts its retries, the next one stops the fetch.
    outcomes = [*[fake_response(503)] * client.N_ATTEMPTS, fake_response(401)]
    recorder(monkeypatch, outcomes)

    fetch_three_windows()

    printed = capsys.readouterr()
    assert DUMMY_TOKEN not in printed.out
    assert DUMMY_TOKEN not in printed.err
