# =============================================================================
# komira_gcp_wif/tests/test_parse_refusals.mojo — the pure readers' refusals
#   and boundaries, with no connector.
# =============================================================================
#
#   §1 the STS answer (`parse_sts_token_response`): each refused shape named,
#      `expires_in` at 0 and -1 refused and 1 accepted (the boundary).
#   §2 the OAuth error code of a refused exchange (`oauth_error_code`,
#      `is_oauth_error_code`): every allow-listed code, near misses (a
#      prefix, a longer word, another case), bodies with no code, and the
#      body-size cap at exactly 65536 bytes (read) and 65537 (not read).
#   §3 the signJwt answer (`parse_sign_jwt_response`).
#   §4 the generateAccessToken answer (`parse_generate_access_token_response`):
#      each refusal, `expireTime` equal to the wall clock (refused) and one
#      second after (accepted), and a calendar sweep: the last and the first
#      second of every month from 2026-09 to 2028-03 (a whole year, and the
#      leap day of 2028), checked against an epoch computed in this file
#      (days_from_civil), not by komira_datetime.
#   §5 the external_account file (`parse_external_account`): the refusals the
#      file-flow tests leave out, each with the message whole, and the
#      lifetime and format defaults.
#   §6 the subject token (`subject_token_from`): bytes that are not UTF-8, an
#      empty token, a JSON source that is not JSON, and a token holding
#      multi-byte UTF-8 returned byte for byte.
#
# Every input is SYNTHETIC; the tokens are made up. Every endpoint is an
# address of 192.0.2.0/24 (RFC 5737) or a name under example.test.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_gcp_wif import (
    IMPERSONATION_LIFETIME_SECONDS,
    JWT_SUBJECT_TOKEN_TYPE,
    is_oauth_error_code,
    oauth_error_code,
    parse_external_account,
    parse_generate_access_token_response,
    parse_sign_jwt_response,
    parse_sts_token_response,
    subject_token_from,
)


comptime NOW_MS: Int64 = 7_000
comptime TOKEN = "ya29.PARSE-FAKE"
comptime AUDIENCE = (
    "//iam.example.test/projects/1/locations/global/"
    "workloadIdentityPools/pool/providers/oidc"
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


# =============================================================================
# §1 — the STS answer.
# =============================================================================


def _sts_refusal(body: String) -> String:
    try:
        _ = parse_sts_token_response(_bytes(body), NOW_MS)
    except e:
        return String(e)
    return String("NOT REFUSED")


def test_sts_answer_refusals_name_the_field() raises:
    """Each refused shape gets its own message (a reader that let one shape
    through, or reported it as another, changes the text); none quotes the
    token."""
    assert_equal(
        _sts_refusal(String('[{"access_token":"') + TOKEN + '"}]'),
        "komira_gcp_wif: the STS answer is not a JSON object",
    )
    assert_equal(
        _sts_refusal(String('{"access_token":7,"expires_in":3600}')),
        "komira_gcp_wif: the STS answer has no access_token string",
    )
    assert_equal(
        _sts_refusal(String('{"access_token":"","expires_in":3600}')),
        "komira_gcp_wif: the STS answer's access_token is empty",
    )
    var no_int: List[String] = ['', ',"expires_in":"3600"', ',"expires_in":3600.5']
    for i in range(len(no_int)):
        var msg = _sts_refusal(
            String('{"access_token":"') + TOKEN + '"' + no_int[i] + "}"
        )
        assert_equal(msg, "komira_gcp_wif: the STS answer has no integer expires_in")
        assert_false(TOKEN in msg, msg)


def test_sts_expires_in_must_be_positive() raises:
    """0 and -1 are refused; 1, the smallest accepted, expires 1000 ms after
    now. The token is kept whole."""
    var bad: List[String] = ["0", "-1"]
    for i in range(len(bad)):
        assert_equal(
            _sts_refusal(
                String('{"access_token":"') + TOKEN + '","expires_in":' + bad[i] + "}"
            ),
            "komira_gcp_wif: the STS answer's expires_in is not positive",
        )
    # Two faults at once: the empty token is the one reported.
    assert_equal(
        _sts_refusal(String('{"access_token":"","expires_in":0}')),
        "komira_gcp_wif: the STS answer's access_token is empty",
    )
    var tok = parse_sts_token_response(
        _bytes(String('{"access_token":"') + TOKEN + '","expires_in":1}'), NOW_MS
    )
    assert_equal(tok.token, TOKEN)
    assert_equal(tok.expires_at_ms, NOW_MS + 1000)


# =============================================================================
# §2 — the OAuth error code.
# =============================================================================


def test_every_listed_oauth_code_and_no_near_miss() raises:
    """The seven codes of RFC 6749 §5.2 and RFC 8693 §2.2.2 are each listed
    and repeated; a prefix, a longer word, another case and "" are not."""
    var listed: List[String] = [
        "invalid_request",
        "invalid_client",
        "invalid_grant",
        "unauthorized_client",
        "unsupported_grant_type",
        "invalid_scope",
        "invalid_target",
    ]
    for i in range(len(listed)):
        assert_true(is_oauth_error_code(listed[i]), listed[i])
        assert_equal(
            oauth_error_code(_bytes(String('{"error":"') + listed[i] + '"}')),
            String("OAuth error ") + listed[i],
        )
    var near: List[String] = [
        "invalid_gran", "invalid_grants", "INVALID_GRANT", "", "invalid_"
    ]
    for i in range(len(near)):
        assert_false(is_oauth_error_code(near[i]), near[i])
        assert_equal(
            oauth_error_code(_bytes(String('{"error":"') + near[i] + '"}')),
            "OAuth error not a known code",
        )


def test_a_body_with_no_error_string_has_no_code() raises:
    """Not JSON, not an object, no `error`, and an `error` that is not a
    string: each is "" (never a raise, never a body byte)."""
    var none: List[String] = [
        '{"error":"invalid_grant"',
        '["invalid_grant"]',
        '{"error_description":"invalid_grant"}',
        '{"error":["invalid_grant"]}',
        "",
    ]
    for i in range(len(none)):
        assert_equal(oauth_error_code(_bytes(none[i])), "", none[i])


def _padded_error_body(total: Int) -> List[UInt8]:
    """`{"error":"invalid_grant","pad":"xx..."}` of exactly `total` bytes."""
    var head = String('{"error":"invalid_grant","pad":"')
    var out = _bytes(head)
    var pad = total - head.byte_length() - 2
    for _ in range(pad):
        out.append(UInt8(ord("x")))
    out.append(UInt8(ord('"')))
    out.append(UInt8(ord("}")))
    return out^


def test_the_error_body_cap_is_65536_bytes() raises:
    """A body of exactly 65536 bytes is read; one byte more is not read at
    all (so a code inside it is not repeated)."""
    var at = _padded_error_body(65536)
    assert_equal(len(at), 65536)
    assert_equal(oauth_error_code(at), "OAuth error invalid_grant")
    var over = _padded_error_body(65537)
    assert_equal(len(over), 65537)
    assert_equal(oauth_error_code(over), "")


# =============================================================================
# §3 — the signJwt answer.
# =============================================================================


def _jwt_refusal(body: String) -> String:
    try:
        _ = parse_sign_jwt_response(_bytes(body))
    except e:
        return String(e)
    return String("NOT REFUSED")


def test_sign_jwt_answer_refusals_name_the_field() raises:
    """The control first: a non-empty `signedJwt` is returned whole."""
    assert_equal(
        parse_sign_jwt_response(_bytes(String('{"keyId":"k","signedJwt":"a.b.c"}'))),
        "a.b.c",
    )
    assert_equal(
        _jwt_refusal(String('["a.b.c"]')),
        "komira_gcp_wif: the signJwt answer is not a JSON object",
    )
    assert_equal(
        _jwt_refusal(String('{"signedJwt":5}')),
        "komira_gcp_wif: the signJwt answer has no signedJwt string",
    )
    assert_equal(
        _jwt_refusal(String('{"keyId":"k-ONLY","signedJwt":""}')),
        "komira_gcp_wif: the signJwt answer's signedJwt is empty",
    )


# =============================================================================
# §4 — the generateAccessToken answer.
# =============================================================================


def _days_from_civil(y0: Int, m: Int, d: Int) -> Int:
    """Days since 1970-01-01 (H. Hinnant's days_from_civil): this file's
    own oracle, independent of komira_datetime."""
    var y = y0 - 1 if m <= 2 else y0
    var era = (y if y >= 0 else y - 399) // 400
    var yoe = y - era * 400
    var mp = m - 3 if m > 2 else m + 9
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _epoch(y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int) -> Int:
    return _days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s


def _days_in_month(y: Int, m: Int) -> Int:
    var days: List[Int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    if m == 2 and y % 4 == 0 and (y % 100 != 0 or y % 400 == 0):
        return 29
    return days[m - 1]


def _two(n: Int) -> String:
    if n < 10:
        return String("0") + String(n)
    return String(n)


def _rfc3339(y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int) -> String:
    return (
        String(y) + "-" + _two(mo) + "-" + _two(d) + "T" + _two(h) + ":"
        + _two(mi) + ":" + _two(s) + "Z"
    )


def _gat_body(expire: String) -> List[UInt8]:
    return _bytes(
        String('{"accessToken":"') + TOKEN + '","expireTime":"' + expire + '"}'
    )


def _gat_refusal(body: String, wall_s: Int) -> String:
    try:
        _ = parse_generate_access_token_response(_bytes(body), Int64(wall_s), NOW_MS)
    except e:
        return String(e)
    return String("NOT REFUSED")


def test_the_oracle_matches_a_known_instant() raises:
    """2026-10-01T12:00:00Z is 1790856000 (the other test files' NOW_S), and
    2028-02-29 exists while 2027-02-29 does not."""
    assert_equal(_epoch(2026, 10, 1, 12, 0, 0), 1_790_856_000)
    assert_equal(_days_in_month(2028, 2), 29)
    assert_equal(_days_in_month(2027, 2), 28)
    assert_equal(_days_in_month(2100, 2), 28)


def test_generate_access_token_answer_refusals_name_the_field() raises:
    var wall = _epoch(2026, 9, 1, 0, 0, 0)
    var future = _rfc3339(2026, 9, 1, 1, 0, 0)
    var cases: List[String] = [
        String('["x"]'),
        String('{"expireTime":"') + future + '"}',
        String('{"accessToken":"","expireTime":"') + future + '"}',
        String('{"accessToken":"') + TOKEN + '"}',
        String('{"accessToken":"') + TOKEN + '","expireTime":1788224400}',
        String('{"accessToken":"') + TOKEN + '","expireTime":"in one hour"}',
        String('{"accessToken":"') + TOKEN + '","expireTime":"2026-09-01"}',
    ]
    var want: List[String] = [
        " is not a JSON object",
        " has no accessToken string",
        "'s accessToken is empty",
        " has no expireTime string",
        " has no expireTime string",
        "'s expireTime is not RFC 3339",
        "'s expireTime is not RFC 3339",
    ]
    for i in range(len(cases)):
        var msg = _gat_refusal(cases[i], wall)
        assert_equal(
            msg,
            String("komira_gcp_wif: the generateAccessToken answer") + want[i],
        )
        assert_false(TOKEN in msg, msg)
    # Two faults at once: the empty token is the one reported.
    assert_equal(
        _gat_refusal(String('{"accessToken":"","expireTime":"in one hour"}'), wall),
        "komira_gcp_wif: the generateAccessToken answer's accessToken is empty",
    )


def test_expire_time_must_be_after_the_wall_clock() raises:
    """`expireTime` equal to the wall clock, or before it, is refused; one
    second after expires 1000 ms after the monotonic `now_ms`."""
    var wall = _epoch(2026, 9, 30, 23, 59, 59)
    var refused: List[String] = [
        _rfc3339(2026, 9, 30, 23, 59, 59), _rfc3339(2026, 9, 30, 23, 59, 58)
    ]
    for i in range(len(refused)):
        assert_equal(
            _gat_refusal(
                String('{"accessToken":"') + TOKEN + '","expireTime":"' + refused[i] + '"}',
                wall,
            ),
            "komira_gcp_wif: the generateAccessToken answer's expireTime is not in"
            " the future",
        )
    var tok = parse_generate_access_token_response(
        _gat_body(_rfc3339(2026, 10, 1, 0, 0, 0)), Int64(wall), NOW_MS
    )
    assert_equal(tok.token, TOKEN)
    assert_equal(tok.expires_at_ms, NOW_MS + 1000)


def test_expire_time_calendar_sweep() raises:
    """The last second of each month and the first of the next, 2026-09 to
    2028-03: each token expires (expireTime - wall) seconds after now_ms,
    the epoch computed by this file's oracle. A reader that dropped a day,
    a month length or the leap day is off by 86400 s or more."""
    var wall = _epoch(2026, 9, 1, 0, 0, 0)
    var y = 2026
    var m = 9
    var months = 0
    while not (y == 2028 and m == 4):
        var last = _days_in_month(y, m)
        var end = parse_generate_access_token_response(
            _gat_body(_rfc3339(y, m, last, 23, 59, 59)), Int64(wall), NOW_MS
        )
        assert_equal(
            end.expires_at_ms,
            NOW_MS + Int64(_epoch(y, m, last, 23, 59, 59) - wall) * 1000,
            _rfc3339(y, m, last, 23, 59, 59),
        )
        var ny = y + 1 if m == 12 else y
        var nm = 1 if m == 12 else m + 1
        var start = parse_generate_access_token_response(
            _gat_body(_rfc3339(ny, nm, 1, 0, 0, 0)), Int64(wall), NOW_MS
        )
        assert_equal(start.expires_at_ms - end.expires_at_ms, 1000)
        y = ny
        m = nm
        months += 1
    assert_equal(months, 19)
    # The leap day itself, and a zone offset read as UTC.
    var leap = parse_generate_access_token_response(
        _gat_body(String("2028-02-29T12:00:00Z")), Int64(wall), NOW_MS
    )
    assert_equal(
        leap.expires_at_ms, NOW_MS + Int64(_epoch(2028, 2, 29, 12, 0, 0) - wall) * 1000
    )
    var offset = parse_generate_access_token_response(
        _gat_body(String("2027-01-01T00:59:59+01:00")), Int64(wall), NOW_MS
    )
    assert_equal(
        offset.expires_at_ms,
        NOW_MS + Int64(_epoch(2026, 12, 31, 23, 59, 59) - wall) * 1000,
    )


# =============================================================================
# §5 — the external_account file.
# =============================================================================


comptime _P_TEXT = "komira_gcp_wif: the external_account file "


def _ea(source: String, extra: String) -> String:
    """A file with a 192.0.2.1 token_url, `extra` members (each ending in a
    comma) and `source` as its credential_source."""
    return (
        String('{"type":"external_account","audience":"') + AUDIENCE
        + '","subject_token_type":"' + JWT_SUBJECT_TOKEN_TYPE
        + '","token_url":"https://192.0.2.1/v1/token",' + extra
        + '"credential_source":' + source + "}"
    )


comptime FILE_SOURCE = '{"file":"/run/ci/token"}'
comptime URL_HEAD = '{"url":"http://192.0.2.9/token"'


def _refusal(text: String) -> String:
    try:
        _ = parse_external_account(text)
    except e:
        return String(e)
    return String("NOT REFUSED")


def test_file_text_that_is_not_a_json_object_is_refused() raises:
    _ = parse_external_account(_ea(String(FILE_SOURCE), String("")))
    assert_equal(_refusal(String('{"type":"external_account"')), _P_TEXT + "is not JSON")
    assert_equal(_refusal(String("")), _P_TEXT + "is not JSON")
    assert_equal(
        _refusal(String('["external_account"]')), _P_TEXT + "is not a JSON object"
    )


def test_a_token_url_that_is_not_a_url_is_refused() raises:
    var good = _ea(String(FILE_SOURCE), String(""))
    var bad: List[String] = ["192.0.2.1/v1/token", "https//192.0.2.1/v1/token"]
    for i in range(len(bad)):
        var msg = _refusal(good.replace("https://192.0.2.1/v1/token", bad[i]))
        assert_equal(msg, _P_TEXT + "has a \"token_url\" that is not a URL")
    # Two faults at once: the token_url is reported before the source.
    assert_equal(
        _refusal(_ea(String("[]"), String("")).replace("https://192.0.2.1/v1/token", "x")),
        _P_TEXT + "has a \"token_url\" that is not a URL",
    )


def test_impersonation_options_object_and_default_lifetime() raises:
    """An options object with no lifetime is the 3600 s default; one that
    is not an object is refused."""
    var empty_opts = parse_external_account(
        _ea(String(FILE_SOURCE), String('"service_account_impersonation":{},'))
    )
    assert_equal(empty_opts.impersonation_lifetime_s, IMPERSONATION_LIFETIME_SECONDS)
    assert_equal(empty_opts.impersonation_lifetime_s, 3600)
    var set_opts = parse_external_account(
        _ea(
            String(FILE_SOURCE),
            String('"service_account_impersonation":{"token_lifetime_seconds":601},'),
        )
    )
    assert_equal(set_opts.impersonation_lifetime_s, 601)
    var not_obj: List[String] = ["600", "[]", '"600"']
    for i in range(len(not_obj)):
        assert_equal(
            _refusal(
                _ea(
                    String(FILE_SOURCE),
                    String('"service_account_impersonation":') + not_obj[i] + ",",
                )
            ),
            _P_TEXT + "has a \"service_account_impersonation\" that is not an object",
        )
    # Two faults at once: the options are read before the source.
    assert_equal(
        _refusal(_ea(String("{}"), String('"service_account_impersonation":[],'))),
        _P_TEXT + "has a \"service_account_impersonation\" that is not an object",
    )


def test_url_source_refusals() raises:
    """The control first: an http source URL with one header parses, the
    header kept by name and value."""
    var ok = parse_external_account(
        _ea(String(URL_HEAD) + ',"headers":{"X-Ci":"v1"}}', String(""))
    )
    assert_equal(ok.source_url, "http://192.0.2.9/token")
    assert_equal(len(ok.source_header_names), 1)
    assert_equal(ok.source_header_names[0], "X-Ci")
    assert_equal(ok.source_header_values[0], "v1")
    var not_url: List[String] = [
        "ftp://192.0.2.9/token", "192.0.2.9/token", "token"
    ]
    for i in range(len(not_url)):
        assert_equal(
            _refusal(_ea(String('{"url":"') + not_url[i] + '"}', String(""))),
            _P_TEXT + "has a \"credential_source.url\" that is not an http or https URL",
        )
    var not_obj: List[String] = ['"X-Ci: v1"', '["X-Ci"]']
    for i in range(len(not_obj)):
        assert_equal(
            _refusal(_ea(String(URL_HEAD) + ',"headers":' + not_obj[i] + "}", String(""))),
            _P_TEXT + "has a \"credential_source.headers\" that is not an object",
        )
    # A non-string value after a good header: the first is not enough.
    var not_str: List[String] = ['{"X-Ci":5}', '{"X-A":"a","X-Ci":null}']
    for i in range(len(not_str)):
        assert_equal(
            _refusal(_ea(String(URL_HEAD) + ',"headers":' + not_str[i] + "}", String(""))),
            _P_TEXT + "names a credential_source header whose value is not a string",
        )


def test_format_refusals_and_defaults() raises:
    """No format, a format with no type, and type text all read the whole
    text (json field ""); type json names its field; anything else, or a
    format that is not an object, is refused."""
    var no_format = parse_external_account(_ea(String(FILE_SOURCE), String("")))
    assert_equal(no_format.source_json_field, "")
    var file_head = String('{"file":"/run/ci/token","format":')
    var no_type = parse_external_account(_ea(file_head + "{}}", String("")))
    assert_equal(no_type.source_json_field, "")
    var text = parse_external_account(_ea(file_head + '{"type":"text"}}', String("")))
    assert_equal(text.source_json_field, "")
    var json = parse_external_account(
        _ea(file_head + '{"type":"json","subject_token_field_name":"id_token"}}', String(""))
    )
    assert_equal(json.source_json_field, "id_token")
    var other: List[String] = ['"xml"', '"JSON"', '"Text"']
    for i in range(len(other)):
        assert_equal(
            _refusal(_ea(file_head + '{"type":' + other[i] + "}}", String(""))),
            _P_TEXT + "has a \"credential_source.format.type\" other than text or json",
        )
    var not_obj: List[String] = ['"json"', "[]"]
    for i in range(len(not_obj)):
        assert_equal(
            _refusal(_ea(file_head + not_obj[i] + "}", String(""))),
            _P_TEXT + "has a \"credential_source.format\" that is not an object",
        )
    # Two faults at once: the source headers are reported before the format.
    assert_equal(
        _refusal(_ea(String(URL_HEAD) + ',"headers":[],"format":{"type":"xml"}}', String(""))),
        _P_TEXT + "has a \"credential_source.headers\" that is not an object",
    )


# =============================================================================
# §6 — the subject token.
# =============================================================================


def _subject_refusal(var raw: List[UInt8], field: String) -> String:
    try:
        _ = subject_token_from(raw, field)
    except e:
        return String(e)
    return String("NOT REFUSED")


def test_subject_token_refusals_and_multibyte_text() raises:
    """Text: bytes that are not UTF-8 (a lone 0xFF, a truncated two-byte
    sequence) and an empty token are refused; a token holding multi-byte
    UTF-8 and high bytes is returned byte for byte. JSON: a source that is
    not JSON is refused."""
    var mb = String("tok-é€-中-𐍈-end")
    var got = subject_token_from(_bytes(mb), String(""))
    assert_equal(got, mb)
    assert_equal(got.byte_length(), mb.byte_length())
    var not_utf8: List[UInt8] = [UInt8(0x61), UInt8(0xFF), UInt8(0x62)]
    assert_equal(
        _subject_refusal(not_utf8^, String("")),
        "komira_gcp_wif: the subject token is not UTF-8",
    )
    var truncated: List[UInt8] = [UInt8(0x61), UInt8(0xC3)]
    assert_equal(
        _subject_refusal(truncated^, String("")),
        "komira_gcp_wif: the subject token is not UTF-8",
    )
    assert_equal(
        _subject_refusal(List[UInt8](), String("")),
        "komira_gcp_wif: the subject token is empty",
    )
    var not_json: List[String] = ['{"id_token":"abc"', "id_token=abc", ""]
    for i in range(len(not_json)):
        assert_equal(
            _subject_refusal(_bytes(not_json[i]), String("id_token")),
            "komira_gcp_wif: the subject token source is not JSON",
        )
    assert_equal(
        subject_token_from(_bytes(String('{"id_token":"abc"}')), String("id_token")),
        "abc",
    )


def main() raises:
    test_sts_answer_refusals_name_the_field()
    test_sts_expires_in_must_be_positive()
    test_every_listed_oauth_code_and_no_near_miss()
    test_a_body_with_no_error_string_has_no_code()
    test_the_error_body_cap_is_65536_bytes()
    test_sign_jwt_answer_refusals_name_the_field()
    test_the_oracle_matches_a_known_instant()
    test_generate_access_token_answer_refusals_name_the_field()
    test_expire_time_must_be_after_the_wall_clock()
    test_expire_time_calendar_sweep()
    test_file_text_that_is_not_a_json_object_is_refused()
    test_a_token_url_that_is_not_a_url_is_refused()
    test_impersonation_options_object_and_default_lifetime()
    test_url_source_refusals()
    test_format_refusals_and_defaults()
    test_subject_token_refusals_and_multibyte_text()
