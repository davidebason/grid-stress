"""Client for the ENTSO-E Transparency Platform API."""

import os
import time
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import requests

BASE_URL = "https://web-api.tp.entsoe.eu/api"
DATE_FORMAT = "%Y%m%d%H%M"
WINDOW_DAYS = 300  # the API refuses windows longer than about one year
MARKET_ZONE = ZoneInfo("Europe/Amsterdam")  # the clock the Dutch market day follows
N_ATTEMPTS = 6
RETRIABLE_EXCEPTIONS = [
    "ConnectTimeout",
    "ReadTimeout",
    "Timeout",
    "ConnectionError",
    "ChunkedEncodingError",
    "ContentDecodingError",
]
ERROR_DOC = "See the API errors section of DATA.md."


def error_date(date_begin: str, date_end: str) -> str:
    """Check the two dates and return "No errors!" if they are usable, otherwise a message."""

    try:
        date_begin_time = datetime.strptime(date_begin, DATE_FORMAT)
    except ValueError as err:
        return f"{date_begin} has the following ValueError: {err}"

    try:
        date_end_time = datetime.strptime(date_end, DATE_FORMAT)
    except ValueError as err:
        return f"{date_end} has the following ValueError: {err}"

    if date_begin == date_end:
        return "The begin and end date can't coincide!"
    if (date_begin_time - date_end_time).total_seconds() > 0:
        return "date_begin is after date_end!"
    return "No errors!"


def error_or_not_api(
    window_start: datetime,
    window_end: datetime,
    params: dict[str, str | None],
    timeout: float,
) -> requests.Response | int:
    """Fetch one window, retrying the failures that a later attempt may survive.

    Up to N_ATTEMPTS requests are sent for the same window. A failure that a retry cannot cure,
    any 4xx status and any exception outside RETRIABLE_EXCEPTIONS, stops immediately. A failure
    that may pass, any 5xx status and the retriable exceptions, is retried after a wait that
    doubles, and no wait follows the last attempt.

    Every outcome other than success is printed: the window, the attempt number, what failed, and
    what happens next. A 429 counts as permanent here: ENTSO-E blocks the token for about ten
    minutes, so the run stops and the window can be fetched again later.

    Args:
        window_start: start of this window, used only to name it in the messages.
        window_end: end of this window, used only to name it in the messages.
        params: the full query, security token included, sent as given. periodStart and periodEnd
            in it are what actually decide the window requested.
        timeout: seconds to wait for the server, for each attempt.

    Returns:
        The requests.Response of the first attempt that neither raised nor returned 4xx or 5xx.
        0 when a failure a retry cannot cure stopped the fetch, so the caller should stop too.
        1 when every attempt failed on something retriable, so this window alone is missing and
        the caller may carry on with the next one. In both cases the printed messages say why.
    """
    window = f"window ({window_start},{window_end})"
    i = 0
    save = 0
    last_failure = "nothing"
    while i < N_ATTEMPTS:
        try:
            r = requests.get(BASE_URL, params, timeout=timeout)
        except requests.exceptions.RequestException as err:
            save = type(err).__name__

        # Check if exception is raised and if we retry or not.
        if save != 0:
            last_failure = save
            if save in RETRIABLE_EXCEPTIONS:
                retry_or_stop(window, i, save)
            else:
                print(f"Attempt {i + 1} in {window}. {save}. Retrying cannot help. {ERROR_DOC}")
                return 0
        # If no exception, still potentially bad result.
        else:
            error_type = str(r.status_code)
            last_failure = f"status code {error_type}"
            if error_type.startswith("5"):
                retry_or_stop(window, i, last_failure)
            elif error_type.startswith("4"):
                print(
                    f"Attempt {i + 1} in {window}. Status code {error_type}. Retrying cannot "
                    f"help: the request, the token or the rate limit is at fault. {ERROR_DOC}"
                )
                return 0
            else:
                break

        save = 0
        i += 1

    if i == N_ATTEMPTS:
        print(
            f"All {N_ATTEMPTS} attempts failed in {window}, last failure {last_failure}. "
            f"No response is returned, so this window is missing from the result, and the "
            f"remaining windows are still fetched. {ERROR_DOC}"
        )
        return 1
    return r


def window_edges(date_begin: str, date_end: str, window_days: int = WINDOW_DAYS) -> list[str]:
    """Split a range into window boundaries that keep the local clock time of date_begin.

    The boundaries are stepped in Amsterdam calendar days rather than in fixed 24-hour blocks, so
    a clock change inside the range does not move them: a range that starts at a local midnight
    has every later boundary at a local midnight too. That matters because the API answers a price
    request with whole local days, widening the window at both ends when a boundary falls inside a
    day, which would otherwise return the same day in two consecutive windows.

    Args:
        date_begin: start of the range, "YYYYMMDDHHmm" in UTC.
        date_end: end of the range, "YYYYMMDDHHmm" in UTC.
        window_days: length of one window, in local days.

    Returns:
        The boundaries as "YYYYMMDDHHmm" strings in UTC, starting with date_begin and ending with
        date_end, so that n windows are described by n + 1 boundaries.
    """
    begin_local = (
        datetime.strptime(date_begin, DATE_FORMAT)
        .replace(tzinfo=UTC)
        .astimezone(MARKET_ZONE)
        .replace(tzinfo=None)
    )
    end_local = (
        datetime.strptime(date_end, DATE_FORMAT)
        .replace(tzinfo=UTC)
        .astimezone(MARKET_ZONE)
        .replace(tzinfo=None)
    )

    edges_local = [begin_local]
    while edges_local[-1] + timedelta(days=window_days) < end_local:
        edges_local.append(edges_local[-1] + timedelta(days=window_days))
    edges_local.append(end_local)

    return [
        edge.replace(tzinfo=MARKET_ZONE).astimezone(UTC).strftime(DATE_FORMAT)
        for edge in edges_local
    ]


def retry_or_stop(window: str, i: int, failure: str) -> None:
    """Report a retriable failure, and wait before the next attempt unless this was the last."""
    if i < N_ATTEMPTS - 1:
        wait = 2**i + 1
        print(
            f"Attempt {i + 1} of {N_ATTEMPTS} in {window}. {failure}. "
            f"It may pass, retrying in {wait} seconds."
        )
        time.sleep(wait)
    else:
        print(f"Attempt {i + 1} of {N_ATTEMPTS} in {window}. {failure}. No attempts left.")


def api_request(
    document_type: str,
    process_type: str | None,
    date_begin: str,
    date_end: str,
    timeout: float,
    domain_1: str,
    zone_1: str,
    domain_2: str | None = None,
    zone_2: str | None = None,
) -> tuple[list[tuple[str, str]], list[tuple[str, str, requests.Response]]] | str | None:
    """Fetch a time range from the ENTSO-E Transparency Platform API, one request per window.

    The range from date_begin to date_end is split by window_edges into consecutive windows of
    WINDOW_DAYS local days, the last one shorter when the range is not a whole multiple of them,
    and one GET request is sent per window. Each window starts where the previous one ends.

    The security token is read from the ENTSOE_TOKEN environment variable and sent as the
    securityToken query parameter, so it is part of the request URL: never print or log
    response.url.

    Args:
        document_type: ENTSO-E document type code, for example "A65" for actual total load.
        process_type: ENTSO-E process type code, for example "A16" for realised values.
            Pass None for document types that take none, such as "A44" for day-ahead prices;
            requests leaves a parameter whose value is None out of the URL.
        date_begin: start of the range, "YYYYMMDDHHmm" in UTC.
        date_end: end of the range, "YYYYMMDDHHmm" in UTC.
        timeout: seconds to wait for the server before giving up, for each request.
        domain_1: name of the zone query parameter, for example "outBiddingZone_Domain".
        zone_1: EIC code of the zone, for example "10YNL----------L" for the Netherlands.
        domain_2: name of a second zone query parameter, for document types that need two,
            such as "out_Domain" alongside "in_Domain" for "A44". Optional.
        zone_2: EIC code for domain_2. Optional. The second pair is sent only when both
            domain_2 and zone_2 are given and non-empty; if either is None or "", both are
            ignored.

    Returns:
        One of three things, and every failure is also described by the messages printed as it
        happens, which name the window, the attempt and what went wrong.

        A pair (missing, responses), where every window of the range appears in exactly one of
        the two, so the caller never has to work out which window a result belongs to.

        missing holds a (periodStart, periodEnd) pair for each window that failed every attempt
        on something retriable. Those windows carry no data and can be requested again later; the
        rest of the range was still fetched.

        responses holds a (periodStart, periodEnd, requests.Response) triple per fetched window,
        in chronological order, each response with a status code outside 4xx and 5xx. Each body is
        a separate XML document, and point positions restart at 1 in each. Both lists may be
        empty: an empty responses with a full missing list means nothing was fetched.

        None, when a failure a retry cannot cure ended the fetch. The windows already fetched are
        discarded with it, because a run that stopped halfway is not a range, and so is the record
        of which windows were missing.

        A message naming the problem with the dates, when they are unusable, in which case no
        request is sent at all.

    Raises:
        KeyError: if ENTSOE_TOKEN is not set in the environment.
    """

    # Check if dates are correct
    error = error_date(date_begin, date_end)
    if error != "No errors!":
        return error

    # Window boundaries, stepped in Amsterdam local days so a clock change cannot move them.
    edges = window_edges(date_begin, date_end)

    # API parameters
    params = {
        "securityToken": os.environ["ENTSOE_TOKEN"],
        "documentType": document_type,
        "processType": process_type,
        domain_1: zone_1,
    }
    if domain_2 and zone_2:
        params[domain_2] = zone_2

    # List of the final result
    responses = []
    missing = []

    # One request per window: the boundaries are consecutive pairs of edges.
    for window_start, window_end in zip(edges, edges[1:], strict=False):
        params["periodStart"] = window_start
        params["periodEnd"] = window_end
        r = error_or_not_api(window_start, window_end, params, timeout=timeout)
        if r == 0:
            return
        elif r == 1:
            missing.append((window_start, window_end))
        else:
            responses.append((window_start, window_end, r))

    if len(responses) == 0:
        print("All data is missing!")
    elif len(missing) == 0:
        print("No data is missing!")
    else:
        print("Some data is missing!")

    return missing, responses
