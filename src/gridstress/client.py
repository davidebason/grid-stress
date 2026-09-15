import os

import requests


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
) -> requests.Response:
    """Send one GET request to the ENTSO-E Transparency Platform API and return the response.

    The security token is read from the ENTSOE_TOKEN environment variable and sent as the
    securityToken query parameter, so it is part of the request URL: never print or log
    response.url.

    Args:
        document_type: ENTSO-E document type code, for example "A65" for actual total load.
        process_type: ENTSO-E process type code, for example "A16" for realised values.
            Pass None for document types that take none, such as "A44" for day-ahead prices;
            requests leaves a parameter whose value is None out of the URL.
        date_begin: start of the window, "YYYYMMDDHHmm" in UTC.
        date_end: end of the window, "YYYYMMDDHHmm" in UTC.
        timeout: seconds to wait for the server before giving up.
        domain_1: name of the zone query parameter, for example "outBiddingZone_Domain".
        zone_1: EIC code of the zone, for example "10YNL----------L" for the Netherlands.
        domain_2: name of a second zone query parameter, for document types that need two,
            such as "out_Domain" alongside "in_Domain" for "A44". Optional.
        zone_2: EIC code for domain_2. Optional. The second pair is sent only when both
            domain_2 and zone_2 are given and non-empty; if either is None or "", both are
            ignored.

    Returns:
        The requests.Response. A status code of 200 means the server returned a document.

    Raises:
        KeyError: if ENTSOE_TOKEN is not set in the environment.
    """
    url = "https://web-api.tp.entsoe.eu/api"
    params = {
        "securityToken": os.environ["ENTSOE_TOKEN"],
        "documentType": document_type,
        "processType": process_type,
        domain_1: zone_1,
        "periodStart": date_begin,
        "periodEnd": date_end,
    }

    if domain_2 and zone_2:
        params[domain_2] = zone_2

    return requests.get(url, params=params, timeout=timeout)
