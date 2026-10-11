# =============================================================================
# komira_test_pdp/reasons.mojo: why the test decision point answered as it
#   did, as fixed codes.
# =============================================================================
#
# Every reply carries one of these in `PdpReply.reason`, and
# `TestPdp.last_reason()` returns the latest. The HTTP body never carries
# them: an error body says only the status class (`pdp.mojo`), so a caller
# cannot learn which check refused it. Tests read the code to prove WHICH
# check answered, not only that one did.
#
# Status of each code:
#   200  REASON_DECIDED (the body holds the decision)
#   404  REASON_NOT_FOUND           413  REASON_BODY_TOO_LARGE
#   405  REASON_METHOD
#   401  REASON_BEARER_MISSING (bare `Bearer` challenge),
#        REASON_BEARER_INVALID, REASON_BEARER_AUDIENCE,
#        REASON_BEARER_NO_CLIENT_ID (`Bearer error="invalid_token"`)
#   400  REASON_BEARER_MALFORMED (`Bearer error="invalid_request"`),
#        REASON_BODY_NOT_JSON, REASON_DUPLICATE_MEMBER,
#        REASON_SUBJECT_INVALID, REASON_ACTION_INVALID,
#        REASON_RESOURCE_INVALID, REASON_CONTEXT_INVALID,
#        REASON_BATCH_INVALID
#   403  the profile's safety conditions: REASON_SUBJECT_TOKEN_INVALID,
#        REASON_SUBJECT_TYPE_MISMATCH, REASON_SUBJECT_MISMATCH,
#        REASON_AUDIENCE_MISMATCH, REASON_CLIENT_MISMATCH
# =============================================================================

comptime REASON_DECIDED: String = "decided"

comptime REASON_NOT_FOUND: String = "not_found"
comptime REASON_METHOD: String = "method_not_allowed"
comptime REASON_BODY_TOO_LARGE: String = "body_too_large"

# The bearer: the asking service's client token.
comptime REASON_BEARER_MISSING: String = "bearer_missing"
comptime REASON_BEARER_MALFORMED: String = "bearer_malformed"
comptime REASON_BEARER_INVALID: String = "bearer_invalid"
comptime REASON_BEARER_AUDIENCE: String = "bearer_audience_mismatch"
comptime REASON_BEARER_NO_CLIENT_ID: String = "bearer_no_client_id"

# The body's shape.
comptime REASON_BODY_NOT_JSON: String = "body_not_json"
comptime REASON_DUPLICATE_MEMBER: String = "duplicate_member"
comptime REASON_SUBJECT_INVALID: String = "subject_invalid"
comptime REASON_ACTION_INVALID: String = "action_invalid"
comptime REASON_RESOURCE_INVALID: String = "resource_invalid"
comptime REASON_CONTEXT_INVALID: String = "context_invalid"
comptime REASON_BATCH_INVALID: String = "batch_invalid"

# The safety conditions: the subject comes only from the subject token.
comptime REASON_SUBJECT_TOKEN_INVALID: String = "subject_token_invalid"
comptime REASON_SUBJECT_TYPE_MISMATCH: String = "subject_type_mismatch"
comptime REASON_SUBJECT_MISMATCH: String = "subject_mismatch"
comptime REASON_AUDIENCE_MISMATCH: String = "audience_mismatch"
comptime REASON_CLIENT_MISMATCH: String = "client_mismatch"
