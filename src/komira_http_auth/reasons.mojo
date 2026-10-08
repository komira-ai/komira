# =============================================================================
# komira_http_auth/reasons.mojo: why a request was refused, as fixed codes.
# =============================================================================
#
# Every refusal carries one of these constants and nothing else: no part of
# the token, no claim value, no error text from a parser. They are safe to log
# and to count. The HTTP response never carries them (it says only
# invalid_request or invalid_token, or nothing at all: middleware.mojo has the
# status and challenge of each case); `BearerJwtMiddleware.last_reason()` and
# `VerifyOutcome.reason` expose them to the embedder and to tests, which use
# them to prove WHICH check refused a token rather than only that one did.
# =============================================================================

comptime REASON_OK: String = "ok"

# The Authorization header. Missing, or another scheme: 401 with a bare
# `Bearer` challenge. Malformed, or more than one credential: 400
# invalid_request.
comptime REASON_MISSING_HEADER: String = "missing_authorization"
comptime REASON_OTHER_SCHEME: String = "unsupported_authorization_scheme"
comptime REASON_MALFORMED_HEADER: String = "malformed_authorization"
comptime REASON_REPEATED_HEADER: String = "repeated_authorization"

# The token's shape and its JOSE header (checked before any key or signature).
comptime REASON_MALFORMED_TOKEN: String = "malformed_token"
comptime REASON_HEADER_JSON: String = "header_not_json_object"
comptime REASON_DUPLICATE_KEY: String = "duplicate_json_key"
comptime REASON_ALG: String = "alg_not_accepted"
comptime REASON_KEY_IN_HEADER: String = "key_in_header"
comptime REASON_CRIT: String = "crit_not_understood"
comptime REASON_TYP: String = "typ_not_accepted"
comptime REASON_KID: String = "kid_missing"

# Keys and the signature.
comptime REASON_UNKNOWN_KID: String = "unknown_kid"
comptime REASON_SIGNATURE: String = "signature_invalid"

# The claims (checked only after the signature verified).
comptime REASON_PAYLOAD_JSON: String = "payload_not_json_object"
comptime REASON_ISS: String = "iss_mismatch"
comptime REASON_AUD: String = "aud_mismatch"
comptime REASON_SUB: String = "sub_missing"
comptime REASON_EXP: String = "exp_missing"
comptime REASON_EXPIRED: String = "expired"
comptime REASON_IAT: String = "iat_invalid"
comptime REASON_NBF: String = "not_yet_valid"
comptime REASON_TTL: String = "lifetime_too_long"

# No usable key set: never fetched, or every refresh failed and the last good
# set is past its freshness plus the configured max-stale. Not a verdict on
# the token: answered 503 with Retry-After.
comptime REASON_KEYS_UNAVAILABLE: String = "keys_unavailable"

# Anything unexpected (an internal error); still answered with invalid_token.
comptime REASON_INTERNAL: String = "internal_error"
