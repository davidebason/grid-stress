# Data

Every source, unit and cleaning decision, recorded as it is made.

## Sources

### ENTSO-E Transparency Platform

API at `https://web-api.tp.entsoe.eu/api`, HTTPS only.

#### Access

The API requires a personal security token, which is free but issued by hand.

1. Register an account at [transparency.entsoe.eu](https://transparency.entsoe.eu).
2. Email `transparency@entsoe.eu` with the subject `RESTful API access` and the registered email address in the body.
3. Once access is granted, generate the token under the account settings of the Transparency Platform website.

The code reads the token from the environment variable `ENTSOE_TOKEN` and from nowhere else. It is never stored in the repository. One way to provide it on Linux or WSL, keeping the token in a file only your user can read and exporting it in every new terminal:

```bash
mkdir -p ~/.config/entsoe
nano ~/.config/entsoe/token          # paste the token as the file's only content, then save
chmod 600 ~/.config/entsoe/token
echo 'export ENTSOE_TOKEN="$(< ~/.config/entsoe/token)"' >> ~/.bashrc
source ~/.bashrc
```

To confirm it is set without printing it, `echo "${#ENTSOE_TOKEN}"` should print `36`.

If the variable is not set, every fetch stops before sending any request, with `KeyError: 'ENTSOE_TOKEN'`.

The API takes the token as the `securityToken` query parameter, so it is part of every request URL. Do not share logs, tracebacks or screenshots that show a full request URL.

#### API errors

What one request can come back as, and what the client does about it. For every outcome other than success the client prints the window, the attempt number and the failure.

**Acceptable.** A `200` carrying a `GL_MarketDocument` (load, generation) or a `Publication_MarketDocument` (prices). A window with no published data arrives instead as an `Acknowledgement_MarketDocument` containing `No matching data found`, and asking again returns the same answer. A window a year in the future, queried on 2026-09-16, came back under a `200`; the same document is also reported under a `400`, so the status code alone does not identify it.

**Retried**, because a later attempt may succeed. The wait doubles between attempts, and none follows the last attempt.

| Failure | How it arrives |
|---|---|
| `ConnectTimeout` | raised: the server did not accept the connection in time |
| `ReadTimeout` | raised: the answer did not finish in time |
| `Timeout` | raised: the base class of the two above |
| `ConnectionError` | raised: DNS failure, connection refused or reset, network unreachable |
| `ChunkedEncodingError` | raised: the connection broke while the body was arriving |
| `ContentDecodingError` | raised: the compressed body could not be unpacked |
| Any `5xx` status | returned: `500`, `502`, `503` and `504`, typically during ENTSO-E maintenance |

**Not retried**, because the same request gives the same answer. The window is not fetched.

| Failure | How it arrives | What to do |
|---|---|---|
| `400` | returned | A parameter is wrong: document type, process type, a zone parameter's name, a date, or a window longer than the API allows. The body names the reason |
| `401` | returned | The token is missing, wrong, or not yet activated. Check `ENTSOE_TOKEN` |
| `403` | returned | Access refused for that data |
| `404` | returned | The base URL is wrong |
| `429` | returned | The limit of 400 requests per minute, per IP and per token, has been passed. ENTSO-E blocks for about ten minutes: wait that long, then run again |
| `SSLError` | raised | Certificate or TLS failure, often a wrong system clock or an intercepting proxy. It is a `ConnectionError`, so it is excluded by name rather than by family |
| `ProxyError` | raised | The proxy refused the connection |
| `TooManyRedirects` | raised | A redirect loop |
| `InvalidURL`, `MissingSchema`, `InvalidSchema`, `InvalidProxyURL`, `InvalidHeader`, `URLRequired` | raised | The request was built wrongly, so the fault is in the client rather than at the far end |

**Before any request is sent.** A missing `ENTSOE_TOKEN` raises `KeyError`. A date that is not twelve digits in `YYYYMMDDHHmm`, a range whose two dates coincide, or an end before its start, is reported as a message and nothing is sent.

**Never printed.** The token travels as the `securityToken` query parameter, so it is part of every request URL. The client prints only the class name of an exception, never `str(err)`, `repr(err)`, `err.request.url` or `response.url`, each of which contains the token.
