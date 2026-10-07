# AzureSasSigner, komira_objectstore's ObjectUrlSigner as a blob service SAS,
# at a fixed clock (2026-10-01T12:00:00Z), with a dummy account key, and at a
# clock that advances between mints.
#
# Rows: one generic mint over the trait gives a GET and a PUT URL on the
# account's blob host, and only the upload carries the required
# `x-ms-blob-type: BlockBlob`; both URLs equal goldens computed independently
# (Python's hmac and urllib over the documented string-to-sign, values
# below); the string-to-sign is sixteen positional fields (counted, since a
# dropped empty field is invisible in a diff and fatal on the wire), the
# permission letters are in Azure's order (`cw`, not `wc`), the resource is
# URL-decoded and the instants are absolute RFC 3339 UTC; the TTL ceiling
# refuses rather than clamps; the same inputs sign the same; a key path
# is signed as given, never normalized; the clock is read at each mint, once,
# so a clock that advances 600 s between two mints gives two SAS windows,
# each equal to its golden; a clock that reads 0 is refused; and the
# production clock, SystemAzureSasClock, reads whole Unix seconds of the wall
# clock (bracketed by komira_clock's reads before and after), so a signer on
# it reports an expiry TTL seconds after an instant inside that bracket.
#
# Goldens, by Python, key = base64.b64decode(_AZURE_KEY):
#   sts = "\n".join([sp, "2026-10-01T12:00:00Z", "2026-10-01T12:05:00Z",
#                    "/blob/myaccount/repo-container/lake/events/part-0001.parquet",
#                    "", "", "https", "2020-12-06", "b", "", "", "", "", "", "", ""])
#   base64(hmac.new(key, sts.encode(), sha256).digest())
#     sp="r"  -> xvFLpnr8zb+g9fCQsN0TM7jdDRj+l4QJkkpR38L/Lqo=
#     sp="cw" -> BJcZ8XJeA6sKEeIbgE1lfuN2xjwWpi5oPGuYy2oC7qA=
#   and with st/se = "2026-10-01T12:10:00Z" / "2026-10-01T12:15:00Z":
#     sp="r"  -> IiZQYhvJAOfU7fTHs8jq6nHST4/tjujZQm1NwMWgcec=
#     sp="cw" -> tXpbnx1irhjgr+Xp8rerzsL39Aq6kFwzwmC7Z7WiYFc=
from std.testing import assert_equal, assert_raises, assert_true

from komira_azure_blob import (
    AZURE_SAS_PERM_CREATE_WRITE,
    AZURE_SAS_PERM_READ,
    AZURE_SAS_VERSION,
    AzureSasClock,
    AzureSasSigner,
    FixedAzureSasClock,
    SystemAzureSasClock,
    azure_blob_service_sas,
    azure_sas_canonicalized_resource,
    azure_sas_iso8601_utc,
)
from komira_clock import now_unix_ms
from komira_objectstore.presign import (
    PRESIGN_MAX_TTL_SECONDS,
    ObjectUrlSigner,
    PresignedUrl,
)


comptime _KEY = "lake/events/part-0001.parquet"
comptime _TTL: Int = 300
comptime _FIXED_NOW: Int64 = 1790856000  # 2026-10-01T12:00:00Z
comptime _STEP: Int = 600

# A DUMMY account key: base64 of "azure-sas-test-key-not-a-real-account-key!".
# Not a credential for anything.
comptime _AZURE_KEY = "YXp1cmUtc2FzLXRlc3Qta2V5LW5vdC1hLXJlYWwtYWNjb3VudC1rZXkh"

comptime _GET_URL = (
    "https://myaccount.blob.core.windows.net/repo-container/lake/events/part-0001.parquet"
    "?sp=r&st=2026-10-01T12%3A00%3A00Z&se=2026-10-01T12%3A05%3A00Z&spr=https"
    "&sv=2020-12-06&sr=b&sig=xvFLpnr8zb%2Bg9fCQsN0TM7jdDRj%2Bl4QJkkpR38L%2FLqo%3D"
)
comptime _PUT_URL = (
    "https://myaccount.blob.core.windows.net/repo-container/lake/events/part-0001.parquet"
    "?sp=cw&st=2026-10-01T12%3A00%3A00Z&se=2026-10-01T12%3A05%3A00Z&spr=https"
    "&sv=2020-12-06&sr=b&sig=BJcZ8XJeA6sKEeIbgE1lfuN2xjwWpi5oPGuYy2oC7qA%3D"
)
comptime _GET_URL_LATER = (
    "https://myaccount.blob.core.windows.net/repo-container/lake/events/part-0001.parquet"
    "?sp=r&st=2026-10-01T12%3A10%3A00Z&se=2026-10-01T12%3A15%3A00Z&spr=https"
    "&sv=2020-12-06&sr=b&sig=IiZQYhvJAOfU7fTHs8jq6nHST4%2FtjujZQm1NwMWgcec%3D"
)
comptime _PUT_URL_LATER = (
    "https://myaccount.blob.core.windows.net/repo-container/lake/events/part-0001.parquet"
    "?sp=cw&st=2026-10-01T12%3A10%3A00Z&se=2026-10-01T12%3A15%3A00Z&spr=https"
    "&sv=2020-12-06&sr=b&sig=tXpbnx1irhjgr%2BXp8rerzsL39Aq6kFwzwmC7Z7WiYFc%3D"
)


struct SteppingClock(AzureSasClock, Movable):
    """Reads `start`, then `start + step`, and so on; counts its reads."""

    var next_unix_seconds: Int
    var step: Int
    var reads: Int

    def __init__(out self, start: Int, step: Int):
        self.next_unix_seconds = start
        self.step = step
        self.reads = 0

    def now_unix_seconds(mut self) -> Int:
        var now = self.next_unix_seconds
        self.next_unix_seconds += self.step
        self.reads += 1
        return now


def _azure() -> AzureSasSigner[FixedAzureSasClock]:
    return AzureSasSigner[FixedAzureSasClock](
        String("myaccount"),
        String("repo-container"),
        String(_AZURE_KEY),
        FixedAzureSasClock(Int(_FIXED_NOW)),
    )


def _stepping() -> AzureSasSigner[SteppingClock]:
    return AzureSasSigner[SteppingClock](
        String("myaccount"),
        String("repo-container"),
        String(_AZURE_KEY),
        SteppingClock(Int(_FIXED_NOW), _STEP),
    )


def _mint[S: ObjectUrlSigner](
    mut signer: S, key: String, ttl: Int
) raises -> Tuple[PresignedUrl, PresignedUrl]:
    """Names no cloud: the trait is the seam."""
    return Tuple[PresignedUrl, PresignedUrl](
        signer.presign_download(key, ttl), signer.presign_upload(key, ttl)
    )


def test_generic_mint_matches_the_goldens() raises:
    var az = _azure()
    var a = _mint(az, String(_KEY), _TTL)
    assert_equal(az.signer_cloud(), String("azure"))
    assert_equal(a[0].method, String("GET"))
    assert_equal(a[1].method, String("PUT"))
    assert_equal(a[0].url, String(_GET_URL))
    assert_equal(a[1].url, String(_PUT_URL))
    # Only the upload requires a client header.
    assert_equal(len(a[0].required_headers), 0)
    assert_equal(len(a[1].required_headers), 1)
    assert_equal(a[1].required_headers[0].name, String("x-ms-blob-type"))
    assert_equal(a[1].required_headers[0].value, String("BlockBlob"))
    assert_equal(a[0].expires_unix_seconds, _FIXED_NOW + Int64(_TTL))
    assert_equal(a[1].expires_unix_seconds, _FIXED_NOW + Int64(_TTL))


def test_string_to_sign_is_sixteen_positional_fields() raises:
    var res = azure_blob_service_sas(
        String("myaccount"),
        String("repo-container"),
        String(_KEY),
        String(AZURE_SAS_PERM_READ),
        _FIXED_NOW,
        _FIXED_NOW + Int64(_TTL),
        String(_AZURE_KEY),
    )
    var lines = res.string_to_sign.split("\n")
    assert_equal(len(lines), 16)
    assert_equal(String(lines[0]), String("r"))  # sp
    assert_equal(String(lines[1]), String("2026-10-01T12:00:00Z"))  # st
    assert_equal(String(lines[2]), String("2026-10-01T12:05:00Z"))  # se
    assert_equal(
        String(lines[3]),
        String("/blob/myaccount/repo-container/lake/events/part-0001.parquet"),
    )
    assert_equal(String(lines[4]), String(""))  # si
    assert_equal(String(lines[5]), String(""))  # sip
    assert_equal(String(lines[6]), String("https"))  # spr
    assert_equal(String(lines[7]), String(AZURE_SAS_VERSION))  # sv
    assert_equal(String(lines[8]), String("b"))  # sr
    for k in range(9, 16):
        assert_equal(String(lines[k]), String(""))  # snapshot, ses, rsc*
    assert_equal(res.signature_base64, "xvFLpnr8zb+g9fCQsN0TM7jdDRj+l4QJkkpR38L/Lqo=")
    # The permission letters are in Azure's documented order.
    assert_equal(String(AZURE_SAS_PERM_CREATE_WRITE), String("cw"))
    # The canonicalized resource is URL-DECODED.
    assert_equal(
        azure_sas_canonicalized_resource(String("acct"), String("cont"), String("a b/c")),
        String("/blob/acct/cont/a b/c"),
    )
    # The instants are absolute RFC 3339 UTC, whole seconds.
    assert_equal(azure_sas_iso8601_utc(_FIXED_NOW), String("2026-10-01T12:00:00Z"))
    assert_equal(azure_sas_iso8601_utc(Int64(0)), String("1970-01-01T00:00:00Z"))


def test_ttl_ceiling_refuses() raises:
    assert_equal(PRESIGN_MAX_TTL_SECONDS, 3600)
    var az = _azure()
    with assert_raises():
        _ = az.presign_upload(String(_KEY), PRESIGN_MAX_TTL_SECONDS + 1)
    with assert_raises():
        _ = az.presign_download(String(_KEY), 0)
    # At the ceiling it mints.
    var at = az.presign_download(String(_KEY), PRESIGN_MAX_TTL_SECONDS)
    assert_equal(at.expires_unix_seconds, _FIXED_NOW + Int64(PRESIGN_MAX_TTL_SECONDS))
    with assert_raises(contains="refusing to sign an empty blob name"):
        _ = az.presign_download(String(""), _TTL)


def test_signatures_are_deterministic() raises:
    var a1 = _azure()
    var a2 = _azure()
    var u1 = a1.presign_download(String(_KEY), _TTL)
    assert_equal(u1.url, a2.presign_download(String(_KEY), _TTL).url)
    var up = a1.presign_upload(String(_KEY), _TTL)
    assert_true(up.url != u1.url)


def test_key_paths_are_never_normalized() raises:
    """`a//b`, `a/./b` and `a/../b` are three DIFFERENT blobs: each is signed
    and addressed as given."""
    var az = _azure()
    var keys: List[String] = ["d//x", "d/./x", "d/a/../x"]
    for i in range(len(keys)):
        var u = az.presign_download(keys[i], _TTL)
        assert_true(
            u.url.find(String("/repo-container/") + keys[i] + "?") > 0, u.url
        )
    # `&` is encoded in the path, `/` is not.
    var amp = az.presign_download(String("d/a&c"), _TTL)
    assert_true(amp.url.find(String("/repo-container/d/a%26c?")) > 0, amp.url)


def test_clock_is_read_at_each_mint() raises:
    """A signer kept between mints signs each at the clock's current
    instant: the second window starts where the clock is then, not where it
    was when the signer was built."""
    var az = _stepping()
    assert_equal(az._clock.reads, 0, "construction reads no clock")
    var first = az.presign_download(String(_KEY), _TTL)
    var second = az.presign_download(String(_KEY), _TTL)
    assert_equal(first.url, String(_GET_URL))
    assert_equal(second.url, String(_GET_URL_LATER))
    assert_equal(first.expires_unix_seconds, _FIXED_NOW + Int64(_TTL))
    assert_equal(second.expires_unix_seconds, _FIXED_NOW + Int64(_STEP + _TTL))
    # One read per mint: st, se and expires_unix_seconds share it.
    assert_equal(az._clock.reads, 2)
    var up = az.presign_upload(String(_KEY), _TTL)
    assert_equal(az._clock.reads, 3)
    # The third read is _FIXED_NOW + 1200: st=12:20:00Z.
    assert_true(up.url.find("&st=2026-10-01T12%3A20%3A00Z&se=2026-10-01T12%3A25%3A00Z&") > 0, up.url)
    assert_equal(up.expires_unix_seconds, _FIXED_NOW + Int64(2 * _STEP + _TTL))


def test_upload_at_an_advanced_clock_matches_its_golden() raises:
    var az = _stepping()
    _ = az.presign_download(String(_KEY), _TTL)
    var up = az.presign_upload(String(_KEY), _TTL)
    assert_equal(up.url, String(_PUT_URL_LATER))
    assert_equal(up.method, String("PUT"))


def test_unreadable_clock_is_refused() raises:
    var az = AzureSasSigner[FixedAzureSasClock](
        String("myaccount"),
        String("repo-container"),
        String(_AZURE_KEY),
        FixedAzureSasClock(0),
    )
    with assert_raises(
        contains=(
            "azure sas: refusing to sign at the non-positive instant 0 (a clock"
            " that cannot be read reports 0)"
        )
    ):
        _ = az.presign_download(String(_KEY), _TTL)


def test_system_clock_reads_unix_seconds() raises:
    var before = Int(now_unix_ms() // 1000)
    var clock = SystemAzureSasClock()
    var v = clock.now_unix_seconds()
    var after = Int(now_unix_ms() // 1000)
    assert_true(before > 0, String(before))
    assert_true(before <= v and v <= after, String(before) + " <= " + String(v) + " <= " + String(after))


def test_system_clock_signer_expires_ttl_after_now() raises:
    var az = AzureSasSigner[SystemAzureSasClock](
        String("myaccount"),
        String("repo-container"),
        String(_AZURE_KEY),
        SystemAzureSasClock(),
    )
    var before = Int64(now_unix_ms() // 1000)
    var got = az.presign_download(String(_KEY), _TTL)
    var after = Int64(now_unix_ms() // 1000)
    var signed_at = got.expires_unix_seconds - Int64(_TTL)
    assert_true(
        before <= signed_at and signed_at <= after,
        String(before) + " <= " + String(signed_at) + " <= " + String(after),
    )
    var st = String("&st=") + azure_sas_iso8601_utc(signed_at).replace(":", "%3A") + "&"
    assert_true(got.url.find(st) > 0, got.url)


def main() raises:
    test_generic_mint_matches_the_goldens()
    test_string_to_sign_is_sixteen_positional_fields()
    test_ttl_ceiling_refuses()
    test_signatures_are_deterministic()
    test_key_paths_are_never_normalized()
    test_clock_is_read_at_each_mint()
    test_upload_at_an_advanced_clock_matches_its_golden()
    test_unreadable_clock_is_refused()
    test_system_clock_reads_unix_seconds()
    test_system_clock_signer_expires_ttl_after_now()
    print("OK")
