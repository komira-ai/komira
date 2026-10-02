# =============================================================================
# komira_objectstore_gcs/tests/test_system_signing_clock.mojo
# =============================================================================
#
# SystemSigningClock, the production `GcsSigningClock`: the process wall
# clock in whole seconds.
#
#   1  a read is a plausible current instant: after 2026-09-01T00:00:00Z
#      (a fixed instant before this code existed) and before 2100-01-01.
#      Two reads are NOT asserted to be ordered: a wall clock may be stepped.
#   2  a GcsV4Signer over it mints, and the mint's expiry is the instant it
#      read plus the TTL, bracketed by reads of the same clock taken before
#      and after the mint (each bracket allows one second of slack for a
#      step between reads).
#
# The key is Google's published inactive dummy service account, read from the
# pinned conformance archive staged at conformance/.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto import rsa_pkcs8_der_from_pem
from komira_json import parse_json_value

from komira_gcp_core import GcsV4ServiceAccount
from komira_objectstore_gcs import GcsV4Signer, SystemSigningClock


comptime _ACCOUNT = "conformance/storage/v1/test_service_account.not-a-test.json"
comptime _AFTER: Int = 1788220800  # 2026-09-01T00:00:00Z
comptime _BEFORE: Int = 4102444800  # 2100-01-01T00:00:00Z
comptime _TTL: Int = 300


def _account() raises -> GcsV4ServiceAccount:
    var text: String
    with open(_ACCOUNT, "r") as f:
        text = f.read()
    var a = parse_json_value(text)
    var der = rsa_pkcs8_der_from_pem(a.get("private_key").as_string())
    return GcsV4ServiceAccount(a.get("client_email").as_string(), der^)


def test_reads_a_plausible_now() raises:
    var clock = SystemSigningClock()
    var now = clock.now_unix_seconds()
    assert_true(
        now > _AFTER, "wall clock reads " + String(now) + ", before 2026-09-01"
    )
    assert_true(
        now < _BEFORE, "wall clock reads " + String(now) + ", after 2100"
    )


def test_signer_signs_at_the_wall_clock() raises:
    var probe = SystemSigningClock()
    var signer = GcsV4Signer(
        _account(), String("repo-bucket"), SystemSigningClock()
    )
    var before = probe.now_unix_seconds()
    var url = signer.presign_download(String("a/b"), _TTL)
    var after = probe.now_unix_seconds()
    assert_equal(url.method, String("GET"))
    var signed_at = Int(url.expires_unix_seconds) - _TTL
    assert_true(
        signed_at >= before - 1 and signed_at <= after + 1,
        "signed at "
        + String(signed_at)
        + ", outside the wall-clock reads "
        + String(before)
        + ".."
        + String(after),
    )
    assert_true(signed_at > _AFTER, "signed before 2026-09-01")


def main() raises:
    test_reads_a_plausible_now()
    test_signer_signs_at_the_wall_clock()
    print("OK")
