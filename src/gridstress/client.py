"""Client for the ENTSO-E Transparency Platform API."""

import os
from datetime import datetime, timedelta

import requests

BASE_URL = "https://web-api.tp.entsoe.eu/api"
DATE_FORMAT = "%Y%m%d%H%M"
WINDOW_DAYS = 300  # the API refuses windows longer than about one year


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
) -> list[requests.Response]:
    """Fetch a time range from the ENTSO-E Transparency Platform API, one request per window.

    The range from date_begin to date_end is split into consecutive windows of 300 days, the
    last one shorter when the range is not a whole multiple of 300 days, and one GET request is
    sent per window. Each window starts where the previous one ends.

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
        One requests.Response per window, in chronological order. Status codes are not checked.
        Each body is a separate XML document, and point positions restart at 1 in each.

    Raises:
        KeyError: if ENTSOE_TOKEN is not set in the environment.
        ValueError: if date_begin or date_end is not in the "YYYYMMDDHHmm" format.
    """
    date_begin_time = datetime.strptime(date_begin, DATE_FORMAT)
    date_end_time = datetime.strptime(date_end, DATE_FORMAT)
    delta_days = (date_end_time - date_begin_time).total_seconds() / 86400
    n_steps = int(delta_days / WINDOW_DAYS)
    final_step = delta_days - WINDOW_DAYS * n_steps

    params = {
        "securityToken": os.environ["ENTSOE_TOKEN"],
        "documentType": document_type,
        "processType": process_type,
        domain_1: zone_1,
    }
    if domain_2 and zone_2:
        params[domain_2] = zone_2

    responses = []

    i = 0
    while i < n_steps:
        window_start = date_begin_time + timedelta(days=i * WINDOW_DAYS)
        window_end = date_begin_time + timedelta(days=(i + 1) * WINDOW_DAYS)
        params["periodStart"] = window_start.strftime(DATE_FORMAT)
        params["periodEnd"] = window_end.strftime(DATE_FORMAT)
        responses.append(requests.get(BASE_URL, params=params, timeout=timeout))
        i += 1

    # The last, shorter window. Skipped when the range is a whole number of windows.
    if final_step != 0:
        window_start = date_begin_time + timedelta(days=WINDOW_DAYS * n_steps)
        window_end = window_start + timedelta(days=final_step)
        params["periodStart"] = window_start.strftime(DATE_FORMAT)
        params["periodEnd"] = window_end.strftime(DATE_FORMAT)
        responses.append(requests.get(BASE_URL, params=params, timeout=timeout))

    return responses
