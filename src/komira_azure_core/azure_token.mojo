# =============================================================================
# komira_azure_core/azure_token.mojo — AzureBearerToken + OAuth JSON helpers
# =============================================================================
#
# The Azure OAuth2 access token and the field extractors shared by
# AzureImdsProvider (managed identity) and ServicePrincipalProvider (the Entra
# client-credentials grant).
#
# Two `expires_in` readers, because the two token endpoints disagree on its
# JSON type: Azure IMDS returns a STRING ("3599"), the Entra token endpoint
# (login.microsoftonline.com) a NUMBER (3599). The responses are flat objects,
# so a byte scan reads them; no JSON library is needed.
#
# No UnsafePointer in any signature, no wildcard origin.
# =============================================================================


# -----------------------------------------------------------------------------
# AzureBearerToken — OAuth2 access token (managed identity / service principal)
# -----------------------------------------------------------------------------


@fieldwise_init
struct AzureBearerToken(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """An OAuth2 bearer token for Azure Storage (the audience is
    https://storage.azure.com/). Returned by managed-identity / service-
    principal providers.

    Field layout:
      var token: String              — the access_token string
      var expiry_unix_ms: Int64      — Unix epoch ms; -1 if unknown
    """

    var token: String
    var expiry_unix_ms: Int64

    @always_inline
    def is_empty(self) -> Bool:
        """True iff this is the empty / anonymous sentinel (token == "")."""
        return self.token.byte_length() == 0


# -----------------------------------------------------------------------------
# extract_oauth_token_field — STRING-valued field extractor
# -----------------------------------------------------------------------------


def extract_oauth_token_field(body: String, field: String) raises -> String:
    """Extract a STRING-valued field from a flat OAuth token JSON
    response. Searches for the quoted field name, then `:`, then the
    opening quote of the value, then copies through the closing quote.
    Supports JSON backslash escapes. Raises if missing/unterminated."""
    var needle = String("\"") + field + String("\"")
    var body_bs = body.as_bytes()
    var needle_bs = needle.as_bytes()
    var nn = len(needle_bs)
    var bn = len(body_bs)
    if nn == 0 or bn < nn:
        raise Error("extract_oauth_token_field: field not found: " + field)
    var i = 0
    var key_end = -1
    while i + nn <= bn:
        var is_match = True
        var j = 0
        while j < nn:
            if body_bs[i + j] != needle_bs[j]:
                is_match = False
                break
            j += 1
        if is_match:
            key_end = i + nn
            break
        i += 1
    if key_end < 0:
        raise Error("extract_oauth_token_field: field not found: " + field)
    var k = key_end
    while k < bn and (
        body_bs[k] == UInt8(0x20)
        or body_bs[k] == UInt8(0x09)
        or body_bs[k] == UInt8(0x0A)
        or body_bs[k] == UInt8(0x0D)
    ):
        k += 1
    if k >= bn or body_bs[k] != UInt8(0x3A):  # ':'
        raise Error("extract_oauth_token_field: missing ':' after key " + field)
    k += 1
    while k < bn and (
        body_bs[k] == UInt8(0x20)
        or body_bs[k] == UInt8(0x09)
        or body_bs[k] == UInt8(0x0A)
        or body_bs[k] == UInt8(0x0D)
    ):
        k += 1
    if k >= bn or body_bs[k] != UInt8(0x22):  # '"'
        raise Error(
            "extract_oauth_token_field: value not a string for key " + field
        )
    k += 1
    var out = String("")
    while k < bn:
        var b = body_bs[k]
        if b == UInt8(0x5C) and k + 1 < bn:  # '\\'
            var esc = body_bs[k + 1]
            if esc == UInt8(0x22):  # \"
                out += "\""
                k += 2
                continue
            if esc == UInt8(0x5C):  # \\
                out += "\\"
                k += 2
                continue
            if esc == UInt8(0x2F):  # \/
                out += "/"
                k += 2
                continue
            if esc == UInt8(0x6E):  # \n
                out += chr(0x0A)
                k += 2
                continue
            if esc == UInt8(0x74):  # \t
                out += chr(0x09)
                k += 2
                continue
            if esc == UInt8(0x72):  # \r
                out += chr(0x0D)
                k += 2
                continue
            out += chr(Int(b))
            k += 1
            continue
        if b == UInt8(0x22):  # closing '"'
            return out^
        out += chr(Int(b))
        k += 1
    raise Error(
        "extract_oauth_token_field: unterminated string for key " + field
    )


# -----------------------------------------------------------------------------
# _find_field_value_start — shared cursor advance past `"<field>"` `:` ws
# -----------------------------------------------------------------------------


def _find_field_value_start(body: String, field: String) raises -> Int:
    """Return the byte offset of the first non-whitespace character of the
    value for `"<field>": ...`. Raises if the field or the ':' is missing.
    """
    var needle = String("\"") + field + String("\"")
    var body_bs = body.as_bytes()
    var needle_bs = needle.as_bytes()
    var nn = len(needle_bs)
    var bn = len(body_bs)
    if bn < nn:
        raise Error("oauth json: field not found: " + field)
    var i = 0
    var key_end = -1
    while i + nn <= bn:
        var is_match = True
        var j = 0
        while j < nn:
            if body_bs[i + j] != needle_bs[j]:
                is_match = False
                break
            j += 1
        if is_match:
            key_end = i + nn
            break
        i += 1
    if key_end < 0:
        raise Error("oauth json: field not found: " + field)
    var k = key_end
    while k < bn and (
        body_bs[k] == UInt8(0x20)
        or body_bs[k] == UInt8(0x09)
        or body_bs[k] == UInt8(0x0A)
        or body_bs[k] == UInt8(0x0D)
    ):
        k += 1
    if k >= bn or body_bs[k] != UInt8(0x3A):  # ':'
        raise Error("oauth json: missing ':' after key " + field)
    k += 1
    while k < bn and (
        body_bs[k] == UInt8(0x20)
        or body_bs[k] == UInt8(0x09)
        or body_bs[k] == UInt8(0x0A)
        or body_bs[k] == UInt8(0x0D)
    ):
        k += 1
    return k


def _parse_digits_from(body: String, start: Int) raises -> Int64:
    """Parse a contiguous run of decimal digits beginning at `start`.
    Raises if there are no digits."""
    var body_bs = body.as_bytes()
    var bn = len(body_bs)
    var k = start
    var value = Int64(0)
    var digit_count = 0
    while k < bn:
        var b = body_bs[k]
        if b >= UInt8(0x30) and b <= UInt8(0x39):
            value = value * Int64(10) + Int64(Int(b) - 0x30)
            digit_count += 1
            k += 1
        else:
            break
    if digit_count == 0:
        raise Error("oauth json: value not numeric")
    return value


# -----------------------------------------------------------------------------
# parse_oauth_expires_in — NUMBER form  ("expires_in": 3599)
# -----------------------------------------------------------------------------


def parse_oauth_expires_in(body: String) raises -> Int64:
    """Extract the integer `expires_in` field (NUMBER form) from an OAuth
    token JSON response — the shape returned by the Entra token endpoint
    (login.microsoftonline.com). Returns SECONDS."""
    var start = _find_field_value_start(body, String("expires_in"))
    return _parse_digits_from(body, start)


# -----------------------------------------------------------------------------
# parse_oauth_expires_in_str — STRING form  ("expires_in": "3599")
# -----------------------------------------------------------------------------


def parse_oauth_expires_in_str(body: String) raises -> Int64:
    """Extract the integer `expires_in` field (STRING form) from an OAuth
    token JSON response — the shape returned by Azure IMDS (managed
    identity), where `expires_in` is JSON-quoted. Tolerates BOTH the
    quoted and unquoted forms (skips a leading `"` if present). Returns
    SECONDS."""
    var start = _find_field_value_start(body, String("expires_in"))
    var body_bs = body.as_bytes()
    var bn = len(body_bs)
    var k = start
    if k < bn and body_bs[k] == UInt8(0x22):  # leading '"'
        k += 1
    return _parse_digits_from(body, k)
