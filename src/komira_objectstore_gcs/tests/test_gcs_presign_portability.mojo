# =============================================================================
# komira_objectstore_gcs/tests/test_gcs_presign_portability.mojo
# =============================================================================
#
# GcsV4Signer as an `ObjectUrlSigner`: the GCS half of the presign
# portability gates. komira_gcp_core's test_v4_sign_conformance already holds
# the algorithm to Google's published vectors; this file holds the CONFORMER
# to the seam's contract, and the composition to the algorithm.
#
# Hermetic: the clock is a parameter (a fixed or a stepping clock, never the
# wall clock), and the key is Google's published inactive dummy service
# account, read from the pinned conformance archive staged at conformance/.
#
#   GATE 1  one generic `_mint[S: ObjectUrlSigner]` mints with the GCS signer;
#           it would not compile if the conformer did not satisfy the seam.
#   GATE 2  each verb is scoped: download is GET, upload is PUT, and the two
#           URLs differ (the verb is inside the signature).
#   GATE 3  GCS requires no client header on either verb.
#   GATE 4  the expiry is the clock's instant plus the TTL, and the clock is
#           read exactly once per mint.
#   GATE 5  the codebase's TTL ceiling binds (below GCS's own 7 days) and
#           refuses rather than clamps, with the policy's own message; a
#           refused mint reads no clock.
#   GATE 6  a fixed clock gives byte-identical URLs; another instant does not.
#   GATE 7  the signer's URL is exactly komira_gcp_core's gcs_v4_signed_url
#           over the path-style path, with `host` the only signed header.
#   GATE 8  the key path is never normalized (`a//b`, `a/./b`, `a/../b` are
#           three objects), and `&` is encoded while `/` is not.
#   GATE 9  containment: the bucket is the signer's; an empty bucket, a
#           bucket holding `/`, and an empty key are refused.
#   GATE 10 an emulator authority keeps its port in the URL.
#   GATE 11 known answers: for every published vector this signer can make
#           (GET or PUT of an object, path style, the default host, no extra
#           header or query parameter), the conformer mints the published
#           URL byte for byte, at the vector's own timestamp. The set of
#           such vectors is pinned, so a filter that selects nothing fails.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_crypto import rsa_pkcs8_der_from_pem
from komira_json import JsonValue, parse_json_value

from komira_gcp_core import (
    GCS_V4_DEFAULT_HOST,
    GCS_V4_MAX_EXPIRES_SECONDS,
    GcsV4Header,
    GcsV4QueryParam,
    GcsV4ServiceAccount,
    gcs_v4_canonical_path,
    gcs_v4_signed_url,
    gcs_v4_stamps_from_unix_seconds,
)
from komira_objectstore import (
    PRESIGN_MAX_TTL_SECONDS,
    ObjectUrlSigner,
    PresignedUrl,
)
from komira_objectstore_gcs import (
    FixedSigningClock,
    GcsSigningClock,
    GcsV4Signer,
)


comptime _VECTORS = "conformance/storage/v1/v4_signatures.json"
comptime _ACCOUNT = "conformance/storage/v1/test_service_account.not-a-test.json"
comptime _BUCKET: StaticString = "repo-bucket"
comptime _KEY: StaticString = "alpha.git/lfs/objects/9f/86/9f86d081884c7d65"
comptime _TTL: Int = 300
comptime _FIXED_NOW: Int = 1790000000  # 20260921T141320Z


struct SteppingClock(GcsSigningClock):
    """Reports `start`, then `start + 1`, ... one second per read, so the
    instant a mint reports says how many reads came before it."""

    var next: Int

    def __init__(out self, start: Int):
        self.next = start

    def now_unix_seconds(mut self) -> Int:
        var t = self.next
        self.next += 1
        return t


def _read_text(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _account() raises -> GcsV4ServiceAccount:
    var a = parse_json_value(_read_text(_ACCOUNT))
    var der = rsa_pkcs8_der_from_pem(a.get("private_key").as_string())
    return GcsV4ServiceAccount(a.get("client_email").as_string(), der^)


def _gcs() raises -> GcsV4Signer[FixedSigningClock]:
    return GcsV4Signer(
        _account(), String(_BUCKET), FixedSigningClock(_FIXED_NOW)
    )


def _query_value(url: String, name: String) -> String:
    """The raw value of query parameter `name` in `url`, or "" if absent."""
    var q = url.find("?")
    if q < 0:
        return String()
    var query = String(url[byte = q + 1 :])
    for part in query.split("&"):
        var p = String(part)
        var eq = p.find("=")
        if eq >= 0 and String(p[byte=:eq]) == name:
            return String(p[byte = eq + 1 :])
    return String()


def _url_path(url: String) -> String:
    """The path of `scheme://authority/path?query`."""
    var start = url.find("://")
    var slash = url.find("/", start + 3)
    var q = url.find("?")
    if q < 0:
        q = url.byte_length()
    return String(url[byte=slash:q])


# -----------------------------------------------------------------------------
# GATE 1 + 2 + 3: one generic mint.
# -----------------------------------------------------------------------------


def _mint[
    S: ObjectUrlSigner
](mut signer: S, key: String, ttl: Int) raises -> Tuple[
    PresignedUrl, PresignedUrl
]:
    """Names no cloud: it compiles against any conformer of the seam."""
    return Tuple[PresignedUrl, PresignedUrl](
        signer.presign_download(key, ttl), signer.presign_upload(key, ttl)
    )


def test_gate1_2_3_generic_mint_scopes_each_verb() raises:
    var gcs = _gcs()
    var g = _mint(gcs, String(_KEY), _TTL)

    # GATE 2: verb scoping, and the verb changes the signature.
    assert_equal(g[0].method, String("GET"))
    assert_equal(g[1].method, String("PUT"))
    assert_true(g[0].url != g[1].url)
    assert_true(
        _query_value(g[0].url, "X-Goog-Signature")
        != _query_value(g[1].url, "X-Goog-Signature")
    )

    # The URL points at GCS and carries GCS's signature parameter.
    assert_true(
        g[0].url.startswith(
            String("https://") + String(GCS_V4_DEFAULT_HOST) + "/"
        )
    )
    assert_equal(
        _query_value(g[0].url, "X-Goog-Algorithm"), String("GOOG4-RSA-SHA256")
    )
    # Hex RSA-2048 signature: 256 bytes, 512 hex digits.
    assert_equal(
        len(_query_value(g[0].url, "X-Goog-Signature").as_bytes()), 512
    )
    assert_equal(gcs.signer_cloud(), String("gcs"))

    # GATE 3: GCS requires no client header, on either verb.
    assert_equal(len(g[0].required_headers), 0)
    assert_equal(len(g[1].required_headers), 0)


# -----------------------------------------------------------------------------
# GATE 4: the expiry comes from the one clock reading of the mint.
# -----------------------------------------------------------------------------


def test_gate4_expiry_is_the_signing_instant_plus_ttl() raises:
    var gcs = _gcs()
    var u = gcs.presign_download(String(_KEY), _TTL)
    assert_equal(u.expires_unix_seconds, Int64(_FIXED_NOW + _TTL))
    assert_equal(
        _query_value(u.url, "X-Goog-Date"), String("20260921T141320Z")
    )
    assert_equal(_query_value(u.url, "X-Goog-Expires"), String(_TTL))
    assert_true(
        _query_value(u.url, "X-Goog-Credential").find("%2F20260921%2Fauto%2F")
        > 0
    )

    # One read per mint: the second mint signs one second later.
    var stepping = GcsV4Signer(
        _account(), String(_BUCKET), SteppingClock(_FIXED_NOW)
    )
    var first = stepping.presign_download(String(_KEY), _TTL)
    var second = stepping.presign_upload(String(_KEY), _TTL)
    assert_equal(first.expires_unix_seconds, Int64(_FIXED_NOW + _TTL))
    assert_equal(second.expires_unix_seconds, Int64(_FIXED_NOW + 1 + _TTL))
    assert_equal(
        _query_value(second.url, "X-Goog-Date"), String("20260921T141321Z")
    )


# -----------------------------------------------------------------------------
# GATE 5: the TTL ceiling is ours, and it refuses.
# -----------------------------------------------------------------------------


comptime _TTL_REFUSAL = "presign: refusing a TTL"
comptime _SIGNER_REFUSAL = "gcs v4 signer: refusing"


def _refuses_ttl(ttl: Int, upload: Bool) raises -> Bool:
    """Whether the mint is refused BY THE TTL POLICY. The signer is built
    outside the `try`, so a missing key file fails the test rather than
    passing as a refusal, and only the policy's own message counts:
    komira_gcp_core refuses a TTL of 0 too, with a different message."""
    var gcs = _gcs()
    try:
        if upload:
            _ = gcs.presign_upload(String(_KEY), ttl)
        else:
            _ = gcs.presign_download(String(_KEY), ttl)
    except e:
        assert_true(String(e).find(_TTL_REFUSAL) >= 0, String(e))
        return True
    return False


def test_gate5_policy_ceiling_refuses_rather_than_clamps() raises:
    assert_equal(PRESIGN_MAX_TTL_SECONDS, 3600)
    assert_true(PRESIGN_MAX_TTL_SECONDS < GCS_V4_MAX_EXPIRES_SECONDS)

    assert_true(_refuses_ttl(PRESIGN_MAX_TTL_SECONDS + 1, False))
    assert_true(_refuses_ttl(PRESIGN_MAX_TTL_SECONDS + 1, True))
    # Below GCS's own maximum and still refused: the ceiling is ours.
    assert_true(_refuses_ttl(GCS_V4_MAX_EXPIRES_SECONDS, False))
    # A zero or negative TTL is a bug, not an already-expired URL.
    assert_true(_refuses_ttl(0, False))
    assert_true(_refuses_ttl(-1, True))

    # The ceiling itself is allowed, and is what the URL carries.
    var gcs = _gcs()
    var u = gcs.presign_download(String(_KEY), PRESIGN_MAX_TTL_SECONDS)
    assert_equal(
        _query_value(u.url, "X-Goog-Expires"), String(PRESIGN_MAX_TTL_SECONDS)
    )

    # A refused mint reads no clock: the next mint still signs at `start`.
    var stepping = GcsV4Signer(
        _account(), String(_BUCKET), SteppingClock(_FIXED_NOW)
    )
    var refused = False
    try:
        _ = stepping.presign_download(String(_KEY), PRESIGN_MAX_TTL_SECONDS + 1)
    except e:
        assert_true(String(e).find(_TTL_REFUSAL) >= 0, String(e))
        refused = True
    assert_true(refused)
    var after = stepping.presign_download(String(_KEY), _TTL)
    assert_equal(after.expires_unix_seconds, Int64(_FIXED_NOW + _TTL))


# -----------------------------------------------------------------------------
# GATE 6: deterministic for a fixed clock.
# -----------------------------------------------------------------------------


def test_gate6_fixed_clock_mints_are_byte_identical() raises:
    var a = _gcs()
    var b = _gcs()
    var ua = a.presign_download(String(_KEY), _TTL)
    var ub = b.presign_download(String(_KEY), _TTL)
    assert_equal(ua.url, ub.url)
    # The same signer twice, too: nothing in it drifts between mints.
    var ua2 = a.presign_download(String(_KEY), _TTL)
    assert_equal(ua.url, ua2.url)

    var later = GcsV4Signer(
        _account(), String(_BUCKET), FixedSigningClock(_FIXED_NOW + 1)
    )
    var ul = later.presign_download(String(_KEY), _TTL)
    assert_true(ul.url != ua.url)
    assert_true(
        _query_value(ul.url, "X-Goog-Signature")
        != _query_value(ua.url, "X-Goog-Signature")
    )


# -----------------------------------------------------------------------------
# GATE 7: the signer is gcs_v4_signed_url over the path-style path.
# -----------------------------------------------------------------------------


def test_gate7_signer_url_is_the_core_signed_url() raises:
    var gcs = _gcs()
    var got = gcs.presign_upload(String(_KEY), _TTL)
    var want = gcs_v4_signed_url(
        String("https"),
        String("PUT"),
        String(GCS_V4_DEFAULT_HOST),
        String("/") + String(_BUCKET) + "/" + String(_KEY),
        List[GcsV4Header](),
        List[GcsV4QueryParam](),
        _account(),
        String("auto"),
        gcs_v4_stamps_from_unix_seconds(Int64(_FIXED_NOW)),
        _TTL,
    )
    assert_equal(got.url, want)
    assert_equal(_query_value(got.url, "X-Goog-SignedHeaders"), String("host"))
    assert_equal(
        _url_path(got.url), String("/") + String(_BUCKET) + "/" + String(_KEY)
    )


# -----------------------------------------------------------------------------
# GATE 8: the key path is never normalized.
# -----------------------------------------------------------------------------


def test_gate8_object_key_paths_are_never_normalized() raises:
    assert_equal(gcs_v4_canonical_path(String("/b//x")), String("/b//x"))
    assert_equal(gcs_v4_canonical_path(String("/b/./x")), String("/b/./x"))
    assert_equal(
        gcs_v4_canonical_path(String("/b/a/../x")), String("/b/a/../x")
    )
    assert_equal(gcs_v4_canonical_path(String("/b/a&c")), String("/b/a%26c"))

    # Through the signer: the bucket prefix plus the key, byte for byte.
    var gcs = _gcs()
    assert_equal(
        _url_path(gcs.presign_download(String("a//b"), _TTL).url),
        String("/repo-bucket/a//b"),
    )
    assert_equal(
        _url_path(gcs.presign_download(String("a/./b"), _TTL).url),
        String("/repo-bucket/a/./b"),
    )
    assert_equal(
        _url_path(gcs.presign_download(String("a/../b"), _TTL).url),
        String("/repo-bucket/a/../b"),
    )
    assert_equal(
        _url_path(gcs.presign_download(String("a&c d"), _TTL).url),
        String("/repo-bucket/a%26c%20d"),
    )
    # Three keys, three signatures.
    assert_true(
        gcs.presign_download(String("a//b"), _TTL).url
        != gcs.presign_download(String("a/b"), _TTL).url
    )


# -----------------------------------------------------------------------------
# GATE 9: containment.
# -----------------------------------------------------------------------------


def _refuses_bucket(var account: GcsV4ServiceAccount, bucket: String) raises -> Bool:
    """Whether the signer refuses `bucket` at construction, with its own
    message. The account is loaded by the caller, outside the `try`."""
    try:
        _ = GcsV4Signer(account^, bucket, FixedSigningClock(_FIXED_NOW))
    except e:
        assert_true(String(e).find(_SIGNER_REFUSAL) >= 0, String(e))
        return True
    return False


def test_gate9_bucket_is_the_signers_and_empty_names_are_refused() raises:
    var account = _account()
    assert_true(_refuses_bucket(account.copy(), String("")))
    assert_true(_refuses_bucket(account.copy(), String("repo-bucket/other")))
    assert_true(_refuses_bucket(account.copy(), String("/repo-bucket")))
    # The control: a plain bucket name is accepted with the same account.
    assert_false(_refuses_bucket(account^, String(_BUCKET)))

    var gcs = _gcs()
    assert_equal(gcs.bucket(), String(_BUCKET))
    var refused = False
    try:
        _ = gcs.presign_upload(String(""), _TTL)
    except e:
        assert_true(String(e).find(_SIGNER_REFUSAL) >= 0, String(e))
        refused = True
    assert_true(refused)


# -----------------------------------------------------------------------------
# GATE 10: an emulator authority keeps its port.
# -----------------------------------------------------------------------------


def test_gate10_emulator_authority_keeps_its_port() raises:
    var emu = GcsV4Signer(
        _account(),
        String(_BUCKET),
        FixedSigningClock(_FIXED_NOW),
        host=String("localhost:4443"),
        scheme=String("http"),
    )
    var u = emu.presign_download(String(_KEY), _TTL)
    assert_true(
        u.url.startswith(String("http://localhost:4443/repo-bucket/"))
    )
    assert_false(u.url.startswith(String("https://")))


# -----------------------------------------------------------------------------
# GATE 11: known answers. The conformer's own URL against Google's.
# -----------------------------------------------------------------------------


def _days_from_civil(y_in: Int, m: Int, d: Int) -> Int:
    """Days since the Unix epoch of a proleptic Gregorian date (H. Hinnant,
    "chrono-Compatible Low-Level Date Algorithms"), written independently of
    the signer's stamp rendering."""
    var y = y_in - 1 if m <= 2 else y_in
    var era = y // 400  # `//` floors; no truncation adjustment
    var yoe = y - era * 400
    var mp = m - 3 if m > 2 else m + 9
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _field(ts: String, start: Int, end: Int) raises -> Int:
    return Int(String(ts[byte=start:end]))


def _unix_from_rfc3339(ts: String) raises -> Int:
    """`YYYY-MM-DDTHH:MM:SSZ`, the form of every vector's `timestamp`, as
    unix seconds."""
    assert_equal(ts.byte_length(), 20, "timestamp " + ts)
    assert_true(ts.endswith("Z"), "timestamp " + ts)
    var days = _days_from_civil(
        _field(ts, 0, 4), _field(ts, 5, 7), _field(ts, 8, 10)
    )
    return (
        days * 86400
        + _field(ts, 11, 13) * 3600
        + _field(ts, 14, 16) * 60
        + _field(ts, 17, 19)
    )


def _str(v: JsonValue, key: String) raises -> String:
    """`v[key]` as a string, or "" when absent."""
    if not v.has(key):
        return String()
    return v.get(key).as_string()


def _is_signer_shaped(t: JsonValue) raises -> Bool:
    """Whether a published vector is a request this signer makes: GET or PUT
    of a named object, path style, https to the default host, no header but
    `host`, no extra query parameter, and a TTL inside our ceiling."""
    var method = _str(t, "method")
    if method != "GET" and method != "PUT":
        return False
    if _str(t, "scheme") != "https":
        return False
    if _str(t, "object").byte_length() == 0:
        return False
    var not_ours: List[String] = [
        "urlStyle",
        "bucketBoundHostname",
        "hostname",
        "clientEndpoint",
        "emulatorHostname",
        "universeDomain",
        "headers",
        "queryParameters",
    ]
    for i in range(len(not_ours)):
        if t.has(not_ours[i]):
            return False
    return Int(t.get("expiration").as_int64()) <= PRESIGN_MAX_TTL_SECONDS


# The published vectors the signer reproduces at the pinned commit, by
# description. Update it with the pin of //third_party/googleapis_conformance_tests.
def _expected_matches() -> List[String]:
    return [
        "Simple GET",
        "Simple PUT",
        "Vary expiration and timestamp",
        "Vary bucket and object",
        "Forward Slashes should not be stripped",
    ]


def test_gate11_signer_mints_googles_published_urls() raises:
    var doc = parse_json_value(_read_text(_VECTORS))
    var tests = doc.get("signingV4Tests")
    var account = _account()
    var matched = List[String]()
    for i in range(tests.array_len()):
        var t = tests.element_at(i)
        if not _is_signer_shaped(t):
            continue
        var description = _str(t, "description")
        var signer = GcsV4Signer(
            account.copy(),
            _str(t, "bucket"),
            FixedSigningClock(_unix_from_rfc3339(_str(t, "timestamp"))),
        )
        var key = _str(t, "object")
        var ttl = Int(t.get("expiration").as_int64())
        var got: PresignedUrl
        if _str(t, "method") == "GET":
            got = signer.presign_download(key, ttl)
        else:
            got = signer.presign_upload(key, ttl)
        assert_equal(got.url, _str(t, "expectedUrl"), description)
        matched.append(description)

    # The filter is pinned too: a filter that selects nothing cannot pass.
    var want = _expected_matches()
    assert_equal(len(matched), len(want), "signer-shaped vectors")
    for i in range(len(want)):
        assert_equal(matched[i], want[i])


def main() raises:
    test_gate1_2_3_generic_mint_scopes_each_verb()
    test_gate4_expiry_is_the_signing_instant_plus_ttl()
    test_gate5_policy_ceiling_refuses_rather_than_clamps()
    test_gate6_fixed_clock_mints_are_byte_identical()
    test_gate7_signer_url_is_the_core_signed_url()
    test_gate8_object_key_paths_are_never_normalized()
    test_gate9_bucket_is_the_signers_and_empty_names_are_refused()
    test_gate10_emulator_authority_keeps_its_port()
    test_gate11_signer_mints_googles_published_urls()
    print("PASS test_gcs_presign_portability")
