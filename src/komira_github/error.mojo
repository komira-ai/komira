# =============================================================================
# komira_github/error.mojo -- the error kinds this package raises.
# =============================================================================
#
# Every error this package raises starts `GitHubError[<KIND>]: `, so a caller
# can tell a refusal made before anything was sent (NOT_ALLOWED, BAD_INPUT,
# RATE_LIMITED while the latch holds) from an answer GitHub gave (AUTH,
# HTTP_STATUS, RATE_LIMITED from a response, BAD_RESPONSE) with
# `github_error_kind`. No message quotes a response body, a token, a key or
# a webhook secret.
# =============================================================================

comptime GITHUB_ERROR_PREFIX: String = "GitHubError["

# A request the REST subset does not hold (route.mojo), or one sent with the
# wrong credential kind for its route. Nothing was sent.
comptime KIND_NOT_ALLOWED: String = "NOT_ALLOWED"
# An input refused before anything was sent (a name, a path, a body field).
comptime KIND_BAD_INPUT: String = "BAD_INPUT"
# A rate limit: GitHub's answer, or the latch refusing a call before the
# time that answer named (rate_limit.mojo). Never retried by this package.
comptime KIND_RATE_LIMITED: String = "RATE_LIMITED"
# A credential refused: GitHub answered 401, or the App JWT or installation
# token could not be minted or read.
comptime KIND_AUTH: String = "AUTH"
# A non-2xx answer that is not a rate limit or a 401.
comptime KIND_HTTP_STATUS: String = "HTTP_STATUS"
# A 2xx answer this package could not read (a token response without
# `token`, a page that is not the documented shape, a hostile Link header).
comptime KIND_BAD_RESPONSE: String = "BAD_RESPONSE"
# A webhook delivery whose signature is missing, malformed or wrong.
comptime KIND_WEBHOOK: String = "WEBHOOK"


def github_error(kind: String, detail: String) -> Error:
    """`GitHubError[<kind>]: <detail>`."""
    return Error(String(GITHUB_ERROR_PREFIX) + kind + String("]: ") + detail)


def github_error_kind(text: String) -> String:
    """The `<KIND>` of a `GitHubError[<KIND>]: ...` text, "" when `text` does
    not start with one."""
    if not text.startswith(GITHUB_ERROR_PREFIX):
        return String("")
    var start = String(GITHUB_ERROR_PREFIX).byte_length()
    var end = text.find("]", start)
    if end < 0:
        return String("")
    return String(text[byte=start:end])
