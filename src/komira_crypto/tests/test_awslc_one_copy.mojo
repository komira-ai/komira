# =============================================================================
# komira_crypto/tests/test_awslc_one_copy.mojo
# =============================================================================
#
# A program that holds komira_crypto and komira_uuid holds one copy of aws-lc.
# Both packages depend on komira_awslc (komira_uuid for RAND_bytes, komira_crypto
# for everything else) and neither ships aws-lc itself, so the unit this file
# builds links `libawslc.a` once. It would not link otherwise: a second archive
# defining komira_awslc_* names is a duplicate definition.
#
# One exception holds today: komira_http_core's s2n-tls still compiles against
# //third_party/aws-lc, so a program that links komira_http_core has two
# archives defining komira_awslc_* names on its link line. The linker pulls
# archive members only as they are needed, so the link resolves each name from
# one copy (a real duplicate would be a link error). The s2n step moves s2n onto
# komira_awslc and ends that.
#
# The test mints UUIDs through komira_uuid (aws-lc RAND_bytes) and hashes them
# through komira_crypto (aws-lc SHA256) in one process, and checks that the
# hash of a UUID's bytes is what a second, independent call to the hash gives.

from std.testing import assert_equal, assert_true

from komira_crypto import sha256
from komira_uuid import generate_uuidv7


def main() raises:
    var a = generate_uuidv7()
    var b = generate_uuidv7()
    # Two draws from the one RAND_bytes differ (a collision of 74 random bits is not a case).
    assert_true(a != b)
    var bytes = a.as_bytes()
    var d1 = sha256(Span(bytes))
    var d2 = sha256(Span(bytes))
    for i in range(32):
        assert_equal(d1[i], d2[i])
    # SHA-256 of the 16 bytes is not the bytes: the call reached aws-lc.
    var same = True
    for i in range(16):
        if d1[i] != bytes[i]:
            same = False
    assert_true(not same)
