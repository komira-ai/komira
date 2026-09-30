# =============================================================================
# komira_crypto/tests/test_x509_smoke.mojo
# X.509 v3 cert parser smoke tests.
# =============================================================================
#
# Fixture: a self-signed ECDSA-P256 cert generated once with Python
# cryptography. The 480 DER bytes are inlined below. Regenerating produces
# a NEW cert (ECDSA random-k) — to rotate, also update the assertions if
# version / serial / etc. drift.
# Current fixture properties:
#   - version: v3 (UInt8 2)
#   - serialNumber: 0x12345678 (4 bytes)
#   - signatureAlgorithm: ecdsa-with-SHA256 = 1.2.840.10045.4.3.2
#   - issuer = subject (self-signed):
#       C=US (2.5.4.6, PrintableString)
#       O="Example Test" (2.5.4.10, UTF8String)
#       CN="test.example.com" (2.5.4.3, UTF8String)
#   - validity: 2020-01-01T00:00:00Z to 2030-01-01T00:00:00Z (both UTCTime)
#   - subjectPublicKeyInfo algo: ecPublicKey + secp256r1 curve OID
#       (1.2.840.10045.2.1)
#   - extensions (5):
#       basicConstraints (2.5.29.19) — CRITICAL, CA=false
#       keyUsage (2.5.29.15) — CRITICAL
#       extKeyUsage (2.5.29.37) — serverAuth
#       subjectAltName (2.5.29.17) — DNS:example.com
#       subjectKeyIdentifier (2.5.29.14)
#   - signatureValue: ECDSA-Sig-Value SEQUENCE { r INTEGER, s INTEGER }
#                     wrapped in BIT STRING (~ 70-72 bytes)
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.cert.x509 import (
    X509Certificate,
    Extension,
    x509_parse_certificate,
    x509_find_extension,
)
from komira_crypto.cert.asn1 import der_oid_eq


# Common X.509 OID constants for assertions
def _oid_country_name() -> List[UInt32]:
    var o = List[UInt32](); o.append(UInt32(2)); o.append(UInt32(5))
    o.append(UInt32(4)); o.append(UInt32(6)); return o^

def _oid_org_name() -> List[UInt32]:
    var o = List[UInt32](); o.append(UInt32(2)); o.append(UInt32(5))
    o.append(UInt32(4)); o.append(UInt32(10)); return o^

def _oid_common_name() -> List[UInt32]:
    var o = List[UInt32](); o.append(UInt32(2)); o.append(UInt32(5))
    o.append(UInt32(4)); o.append(UInt32(3)); return o^

def _oid_basic_constraints() -> List[UInt32]:
    var o = List[UInt32](); o.append(UInt32(2)); o.append(UInt32(5))
    o.append(UInt32(29)); o.append(UInt32(19)); return o^

def _oid_key_usage() -> List[UInt32]:
    var o = List[UInt32](); o.append(UInt32(2)); o.append(UInt32(5))
    o.append(UInt32(29)); o.append(UInt32(15)); return o^

def _oid_ext_key_usage() -> List[UInt32]:
    var o = List[UInt32](); o.append(UInt32(2)); o.append(UInt32(5))
    o.append(UInt32(29)); o.append(UInt32(37)); return o^

def _oid_san() -> List[UInt32]:
    var o = List[UInt32](); o.append(UInt32(2)); o.append(UInt32(5))
    o.append(UInt32(29)); o.append(UInt32(17)); return o^

def _oid_subject_key_id() -> List[UInt32]:
    var o = List[UInt32](); o.append(UInt32(2)); o.append(UInt32(5))
    o.append(UInt32(29)); o.append(UInt32(14)); return o^

def _oid_ecdsa_with_sha256() -> List[UInt32]:
    # 1.2.840.10045.4.3.2
    var o = List[UInt32](); o.append(UInt32(1)); o.append(UInt32(2))
    o.append(UInt32(840)); o.append(UInt32(10045)); o.append(UInt32(4))
    o.append(UInt32(3)); o.append(UInt32(2)); return o^

def _oid_ec_public_key() -> List[UInt32]:
    # 1.2.840.10045.2.1
    var o = List[UInt32](); o.append(UInt32(1)); o.append(UInt32(2))
    o.append(UInt32(840)); o.append(UInt32(10045)); o.append(UInt32(2))
    o.append(UInt32(1)); return o^


def _self_signed_test_cert_der() -> List[UInt8]:
    """Return the 480-byte DER bytes of the self-signed test cert."""
    var d = List[UInt8]()
    d.append(UInt8(0x30))
    d.append(UInt8(0x82))
    d.append(UInt8(0x01))
    d.append(UInt8(0xdc))
    d.append(UInt8(0x30))
    d.append(UInt8(0x82))
    d.append(UInt8(0x01))
    d.append(UInt8(0x82))
    d.append(UInt8(0xa0))
    d.append(UInt8(0x03))
    d.append(UInt8(0x02))
    d.append(UInt8(0x01))
    d.append(UInt8(0x02))
    d.append(UInt8(0x02))
    d.append(UInt8(0x04))
    d.append(UInt8(0x12))
    d.append(UInt8(0x34))
    d.append(UInt8(0x56))
    d.append(UInt8(0x78))
    d.append(UInt8(0x30))
    d.append(UInt8(0x0a))
    d.append(UInt8(0x06))
    d.append(UInt8(0x08))
    d.append(UInt8(0x2a))
    d.append(UInt8(0x86))
    d.append(UInt8(0x48))
    d.append(UInt8(0xce))
    d.append(UInt8(0x3d))
    d.append(UInt8(0x04))
    d.append(UInt8(0x03))
    d.append(UInt8(0x02))
    d.append(UInt8(0x30))
    d.append(UInt8(0x3f))
    d.append(UInt8(0x31))
    d.append(UInt8(0x0b))
    d.append(UInt8(0x30))
    d.append(UInt8(0x09))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x04))
    d.append(UInt8(0x06))
    d.append(UInt8(0x13))
    d.append(UInt8(0x02))
    d.append(UInt8(0x55))
    d.append(UInt8(0x53))
    d.append(UInt8(0x31))
    d.append(UInt8(0x15))
    d.append(UInt8(0x30))
    d.append(UInt8(0x13))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x04))
    d.append(UInt8(0x0a))
    d.append(UInt8(0x0c))
    d.append(UInt8(0x0c))
    d.append(UInt8(0x45))
    d.append(UInt8(0x78))
    d.append(UInt8(0x61))
    d.append(UInt8(0x6d))
    d.append(UInt8(0x70))
    d.append(UInt8(0x6c))
    d.append(UInt8(0x65))
    d.append(UInt8(0x20))
    d.append(UInt8(0x54))
    d.append(UInt8(0x65))
    d.append(UInt8(0x73))
    d.append(UInt8(0x74))
    d.append(UInt8(0x31))
    d.append(UInt8(0x19))
    d.append(UInt8(0x30))
    d.append(UInt8(0x17))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x04))
    d.append(UInt8(0x03))
    d.append(UInt8(0x0c))
    d.append(UInt8(0x10))
    d.append(UInt8(0x74))
    d.append(UInt8(0x65))
    d.append(UInt8(0x73))
    d.append(UInt8(0x74))
    d.append(UInt8(0x2e))
    d.append(UInt8(0x65))
    d.append(UInt8(0x78))
    d.append(UInt8(0x61))
    d.append(UInt8(0x6d))
    d.append(UInt8(0x70))
    d.append(UInt8(0x6c))
    d.append(UInt8(0x65))
    d.append(UInt8(0x2e))
    d.append(UInt8(0x63))
    d.append(UInt8(0x6f))
    d.append(UInt8(0x6d))
    d.append(UInt8(0x30))
    d.append(UInt8(0x1e))
    d.append(UInt8(0x17))
    d.append(UInt8(0x0d))
    d.append(UInt8(0x32))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x31))
    d.append(UInt8(0x30))
    d.append(UInt8(0x31))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x5a))
    d.append(UInt8(0x17))
    d.append(UInt8(0x0d))
    d.append(UInt8(0x33))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x31))
    d.append(UInt8(0x30))
    d.append(UInt8(0x31))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x5a))
    d.append(UInt8(0x30))
    d.append(UInt8(0x3f))
    d.append(UInt8(0x31))
    d.append(UInt8(0x0b))
    d.append(UInt8(0x30))
    d.append(UInt8(0x09))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x04))
    d.append(UInt8(0x06))
    d.append(UInt8(0x13))
    d.append(UInt8(0x02))
    d.append(UInt8(0x55))
    d.append(UInt8(0x53))
    d.append(UInt8(0x31))
    d.append(UInt8(0x15))
    d.append(UInt8(0x30))
    d.append(UInt8(0x13))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x04))
    d.append(UInt8(0x0a))
    d.append(UInt8(0x0c))
    d.append(UInt8(0x0c))
    d.append(UInt8(0x45))
    d.append(UInt8(0x78))
    d.append(UInt8(0x61))
    d.append(UInt8(0x6d))
    d.append(UInt8(0x70))
    d.append(UInt8(0x6c))
    d.append(UInt8(0x65))
    d.append(UInt8(0x20))
    d.append(UInt8(0x54))
    d.append(UInt8(0x65))
    d.append(UInt8(0x73))
    d.append(UInt8(0x74))
    d.append(UInt8(0x31))
    d.append(UInt8(0x19))
    d.append(UInt8(0x30))
    d.append(UInt8(0x17))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x04))
    d.append(UInt8(0x03))
    d.append(UInt8(0x0c))
    d.append(UInt8(0x10))
    d.append(UInt8(0x74))
    d.append(UInt8(0x65))
    d.append(UInt8(0x73))
    d.append(UInt8(0x74))
    d.append(UInt8(0x2e))
    d.append(UInt8(0x65))
    d.append(UInt8(0x78))
    d.append(UInt8(0x61))
    d.append(UInt8(0x6d))
    d.append(UInt8(0x70))
    d.append(UInt8(0x6c))
    d.append(UInt8(0x65))
    d.append(UInt8(0x2e))
    d.append(UInt8(0x63))
    d.append(UInt8(0x6f))
    d.append(UInt8(0x6d))
    d.append(UInt8(0x30))
    d.append(UInt8(0x59))
    d.append(UInt8(0x30))
    d.append(UInt8(0x13))
    d.append(UInt8(0x06))
    d.append(UInt8(0x07))
    d.append(UInt8(0x2a))
    d.append(UInt8(0x86))
    d.append(UInt8(0x48))
    d.append(UInt8(0xce))
    d.append(UInt8(0x3d))
    d.append(UInt8(0x02))
    d.append(UInt8(0x01))
    d.append(UInt8(0x06))
    d.append(UInt8(0x08))
    d.append(UInt8(0x2a))
    d.append(UInt8(0x86))
    d.append(UInt8(0x48))
    d.append(UInt8(0xce))
    d.append(UInt8(0x3d))
    d.append(UInt8(0x03))
    d.append(UInt8(0x01))
    d.append(UInt8(0x07))
    d.append(UInt8(0x03))
    d.append(UInt8(0x42))
    d.append(UInt8(0x00))
    d.append(UInt8(0x04))
    d.append(UInt8(0x15))
    d.append(UInt8(0x9c))
    d.append(UInt8(0x19))
    d.append(UInt8(0xc6))
    d.append(UInt8(0xb0))
    d.append(UInt8(0x2c))
    d.append(UInt8(0xb9))
    d.append(UInt8(0x62))
    d.append(UInt8(0xba))
    d.append(UInt8(0x30))
    d.append(UInt8(0x0a))
    d.append(UInt8(0x03))
    d.append(UInt8(0x75))
    d.append(UInt8(0x10))
    d.append(UInt8(0xb8))
    d.append(UInt8(0x6a))
    d.append(UInt8(0x84))
    d.append(UInt8(0x10))
    d.append(UInt8(0xee))
    d.append(UInt8(0x11))
    d.append(UInt8(0x0e))
    d.append(UInt8(0x2b))
    d.append(UInt8(0x62))
    d.append(UInt8(0xea))
    d.append(UInt8(0x40))
    d.append(UInt8(0x12))
    d.append(UInt8(0xf6))
    d.append(UInt8(0xae))
    d.append(UInt8(0x73))
    d.append(UInt8(0xcb))
    d.append(UInt8(0x7c))
    d.append(UInt8(0x71))
    d.append(UInt8(0x18))
    d.append(UInt8(0x72))
    d.append(UInt8(0xd3))
    d.append(UInt8(0x4a))
    d.append(UInt8(0xdb))
    d.append(UInt8(0x7d))
    d.append(UInt8(0x11))
    d.append(UInt8(0x4c))
    d.append(UInt8(0xb4))
    d.append(UInt8(0xb0))
    d.append(UInt8(0x6b))
    d.append(UInt8(0x74))
    d.append(UInt8(0xf7))
    d.append(UInt8(0x4a))
    d.append(UInt8(0x4c))
    d.append(UInt8(0xec))
    d.append(UInt8(0xf2))
    d.append(UInt8(0x69))
    d.append(UInt8(0xaa))
    d.append(UInt8(0xd7))
    d.append(UInt8(0x90))
    d.append(UInt8(0xff))
    d.append(UInt8(0x0b))
    d.append(UInt8(0x0a))
    d.append(UInt8(0x01))
    d.append(UInt8(0xcf))
    d.append(UInt8(0xdf))
    d.append(UInt8(0xf2))
    d.append(UInt8(0x67))
    d.append(UInt8(0x3f))
    d.append(UInt8(0x78))
    d.append(UInt8(0x18))
    d.append(UInt8(0xa3))
    d.append(UInt8(0x6c))
    d.append(UInt8(0x30))
    d.append(UInt8(0x6a))
    d.append(UInt8(0x30))
    d.append(UInt8(0x0c))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x1d))
    d.append(UInt8(0x13))
    d.append(UInt8(0x01))
    d.append(UInt8(0x01))
    d.append(UInt8(0xff))
    d.append(UInt8(0x04))
    d.append(UInt8(0x02))
    d.append(UInt8(0x30))
    d.append(UInt8(0x00))
    d.append(UInt8(0x30))
    d.append(UInt8(0x0e))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x1d))
    d.append(UInt8(0x0f))
    d.append(UInt8(0x01))
    d.append(UInt8(0x01))
    d.append(UInt8(0xff))
    d.append(UInt8(0x04))
    d.append(UInt8(0x04))
    d.append(UInt8(0x03))
    d.append(UInt8(0x02))
    d.append(UInt8(0x05))
    d.append(UInt8(0xa0))
    d.append(UInt8(0x30))
    d.append(UInt8(0x13))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x1d))
    d.append(UInt8(0x25))
    d.append(UInt8(0x04))
    d.append(UInt8(0x0c))
    d.append(UInt8(0x30))
    d.append(UInt8(0x0a))
    d.append(UInt8(0x06))
    d.append(UInt8(0x08))
    d.append(UInt8(0x2b))
    d.append(UInt8(0x06))
    d.append(UInt8(0x01))
    d.append(UInt8(0x05))
    d.append(UInt8(0x05))
    d.append(UInt8(0x07))
    d.append(UInt8(0x03))
    d.append(UInt8(0x01))
    d.append(UInt8(0x30))
    d.append(UInt8(0x16))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x1d))
    d.append(UInt8(0x11))
    d.append(UInt8(0x04))
    d.append(UInt8(0x0f))
    d.append(UInt8(0x30))
    d.append(UInt8(0x0d))
    d.append(UInt8(0x82))
    d.append(UInt8(0x0b))
    d.append(UInt8(0x65))
    d.append(UInt8(0x78))
    d.append(UInt8(0x61))
    d.append(UInt8(0x6d))
    d.append(UInt8(0x70))
    d.append(UInt8(0x6c))
    d.append(UInt8(0x65))
    d.append(UInt8(0x2e))
    d.append(UInt8(0x63))
    d.append(UInt8(0x6f))
    d.append(UInt8(0x6d))
    d.append(UInt8(0x30))
    d.append(UInt8(0x1d))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x1d))
    d.append(UInt8(0x0e))
    d.append(UInt8(0x04))
    d.append(UInt8(0x16))
    d.append(UInt8(0x04))
    d.append(UInt8(0x14))
    d.append(UInt8(0xf5))
    d.append(UInt8(0x63))
    d.append(UInt8(0x66))
    d.append(UInt8(0x70))
    d.append(UInt8(0xbd))
    d.append(UInt8(0xd8))
    d.append(UInt8(0x3e))
    d.append(UInt8(0xfb))
    d.append(UInt8(0x91))
    d.append(UInt8(0xdb))
    d.append(UInt8(0x08))
    d.append(UInt8(0x62))
    d.append(UInt8(0xea))
    d.append(UInt8(0x4f))
    d.append(UInt8(0xe9))
    d.append(UInt8(0xa5))
    d.append(UInt8(0x38))
    d.append(UInt8(0xc7))
    d.append(UInt8(0x4e))
    d.append(UInt8(0xa5))
    d.append(UInt8(0x30))
    d.append(UInt8(0x0a))
    d.append(UInt8(0x06))
    d.append(UInt8(0x08))
    d.append(UInt8(0x2a))
    d.append(UInt8(0x86))
    d.append(UInt8(0x48))
    d.append(UInt8(0xce))
    d.append(UInt8(0x3d))
    d.append(UInt8(0x04))
    d.append(UInt8(0x03))
    d.append(UInt8(0x02))
    d.append(UInt8(0x03))
    d.append(UInt8(0x48))
    d.append(UInt8(0x00))
    d.append(UInt8(0x30))
    d.append(UInt8(0x45))
    d.append(UInt8(0x02))
    d.append(UInt8(0x20))
    d.append(UInt8(0x6e))
    d.append(UInt8(0xff))
    d.append(UInt8(0x13))
    d.append(UInt8(0x19))
    d.append(UInt8(0x60))
    d.append(UInt8(0x3e))
    d.append(UInt8(0xfd))
    d.append(UInt8(0x3f))
    d.append(UInt8(0xd5))
    d.append(UInt8(0x19))
    d.append(UInt8(0xcc))
    d.append(UInt8(0x7a))
    d.append(UInt8(0x7b))
    d.append(UInt8(0x97))
    d.append(UInt8(0x58))
    d.append(UInt8(0x7a))
    d.append(UInt8(0x2b))
    d.append(UInt8(0x11))
    d.append(UInt8(0x34))
    d.append(UInt8(0x0c))
    d.append(UInt8(0x79))
    d.append(UInt8(0x7c))
    d.append(UInt8(0xce))
    d.append(UInt8(0xf3))
    d.append(UInt8(0xb0))
    d.append(UInt8(0xb7))
    d.append(UInt8(0x0b))
    d.append(UInt8(0xaf))
    d.append(UInt8(0x72))
    d.append(UInt8(0xf5))
    d.append(UInt8(0x6f))
    d.append(UInt8(0x6f))
    d.append(UInt8(0x02))
    d.append(UInt8(0x21))
    d.append(UInt8(0x00))
    d.append(UInt8(0xf4))
    d.append(UInt8(0x54))
    d.append(UInt8(0x7b))
    d.append(UInt8(0x14))
    d.append(UInt8(0xa3))
    d.append(UInt8(0x08))
    d.append(UInt8(0xa5))
    d.append(UInt8(0x90))
    d.append(UInt8(0xb1))
    d.append(UInt8(0x74))
    d.append(UInt8(0xdb))
    d.append(UInt8(0x52))
    d.append(UInt8(0x5e))
    d.append(UInt8(0x62))
    d.append(UInt8(0xc3))
    d.append(UInt8(0xdd))
    d.append(UInt8(0x0c))
    d.append(UInt8(0xc0))
    d.append(UInt8(0x38))
    d.append(UInt8(0x68))
    d.append(UInt8(0x1e))
    d.append(UInt8(0xda))
    d.append(UInt8(0x98))
    d.append(UInt8(0xa9))
    d.append(UInt8(0x77))
    d.append(UInt8(0xa3))
    d.append(UInt8(0xd0))
    d.append(UInt8(0xe3))
    d.append(UInt8(0x9b))
    d.append(UInt8(0xac))
    d.append(UInt8(0xd3))
    d.append(UInt8(0x48))
    return d^


def test_parse_succeeds() raises:
    """Parser accepts the 480-byte test cert DER without raising."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    # Version is v3 (encoded as INTEGER 2)
    assert_equal(Int(cert.version), 2)


def test_serial_number() raises:
    """Serial number is 0x12345678 (4 bytes big-endian)."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    assert_equal(len(cert.serial_number), 4)
    assert_equal(Int(cert.serial_number[0]), 0x12)
    assert_equal(Int(cert.serial_number[1]), 0x34)
    assert_equal(Int(cert.serial_number[2]), 0x56)
    assert_equal(Int(cert.serial_number[3]), 0x78)


def test_signature_algo_oid() raises:
    """signatureAlgorithm OID matches ecdsa-with-SHA256."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    assert_true(der_oid_eq(cert.signature_algo_oid, _oid_ecdsa_with_sha256()))


def test_subject_pubkey_algo_oid() raises:
    """SPKI algorithm OID matches ecPublicKey (1.2.840.10045.2.1)."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    assert_true(der_oid_eq(cert.subject_pubkey_algo_oid, _oid_ec_public_key()))


def test_issuer_equals_subject() raises:
    """Self-signed: issuer DN attributes match subject DN attributes."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    assert_equal(len(cert.issuer), len(cert.subject))
    assert_equal(len(cert.issuer), 3)  # C, O, CN
    # Each pair byte-equal.
    for i in range(len(cert.issuer)):
        assert_true(der_oid_eq(cert.issuer[i].oid, cert.subject[i].oid))
        assert_equal(cert.issuer[i].value, cert.subject[i].value)


def test_subject_cn() raises:
    """Subject CN is 'test.example.com'. Walk subject DN to find it."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    var cn_oid = _oid_common_name()
    var found = False
    for i in range(len(cert.subject)):
        if der_oid_eq(cert.subject[i].oid, cn_oid):
            assert_equal(cert.subject[i].value, "test.example.com")
            found = True
            break
    assert_true(found, "CN not found in subject DN")


def test_subject_country() raises:
    """Subject country code is 'US' (PrintableString)."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    var c_oid = _oid_country_name()
    var found = False
    for i in range(len(cert.subject)):
        if der_oid_eq(cert.subject[i].oid, c_oid):
            assert_equal(cert.subject[i].value, "US")
            found = True
            break
    assert_true(found, "C not found in subject DN")


def test_validity_period() raises:
    """notBefore = 2020-01-01T00:00:00Z; notAfter = 2030-01-01T00:00:00Z."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    assert_equal(Int(cert.not_before.year), 2020)
    assert_equal(Int(cert.not_before.month), 1)
    assert_equal(Int(cert.not_before.day), 1)
    assert_equal(Int(cert.not_before.hour), 0)
    assert_equal(Int(cert.not_after.year), 2030)
    assert_equal(Int(cert.not_after.month), 1)


def test_extension_count() raises:
    """5 extensions: basicConstraints, keyUsage, extKeyUsage, SAN, SKI."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    assert_equal(len(cert.extensions), 5)


def test_basic_constraints_critical() raises:
    """basicConstraints is CRITICAL (extension parser parses BOOLEAN before
    OCTET STRING)."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    var idx = x509_find_extension(cert, _oid_basic_constraints())
    assert_true(idx >= 0, "basicConstraints extension not found")
    assert_true(cert.extensions[idx].critical)


def test_key_usage_critical() raises:
    """keyUsage is CRITICAL."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    var idx = x509_find_extension(cert, _oid_key_usage())
    assert_true(idx >= 0, "keyUsage extension not found")
    assert_true(cert.extensions[idx].critical)


def test_ext_key_usage_present() raises:
    """extKeyUsage is non-critical and present."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    var idx = x509_find_extension(cert, _oid_ext_key_usage())
    assert_true(idx >= 0, "extKeyUsage extension not found")
    assert_false(cert.extensions[idx].critical)
    # Inside is a SEQUENCE OF OIDs, at least one (serverAuth = 1.3.6.1.5.5.7.3.1).
    assert_true(len(cert.extensions[idx].value) > 0)


def test_san_present() raises:
    """SubjectAlternativeName extension exists (cert/chain.mojo parses
    the inner GeneralNames; this just verifies the extension is parsed +
    value is captured)."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    var idx = x509_find_extension(cert, _oid_san())
    assert_true(idx >= 0, "SAN extension not found")
    # Inner value is a SEQUENCE { [2] IMPLICIT IA5String "example.com" }.
    assert_true(len(cert.extensions[idx].value) > 0)


def test_subject_key_id_present() raises:
    """SubjectKeyIdentifier extension exists (20-byte SHA-1 of pubkey)."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    var idx = x509_find_extension(cert, _oid_subject_key_id())
    assert_true(idx >= 0, "SKI extension not found")


def test_find_extension_negative() raises:
    """Looking for an OID that isn't present returns -1."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    # OID 1.2.3.4.5.6 — not in any X.509 cert.
    var fake = List[UInt32]()
    fake.append(UInt32(1)); fake.append(UInt32(2)); fake.append(UInt32(3))
    fake.append(UInt32(4)); fake.append(UInt32(5)); fake.append(UInt32(6))
    var idx = x509_find_extension(cert, fake)
    assert_equal(idx, -1)


def test_subject_pubkey_nonempty() raises:
    """SPKI subjectPublicKey BIT STRING bytes are extracted (ECDSA-P256
    pubkey: 1 byte format + 32 + 32 = 65 bytes uncompressed)."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    # ECDSA-P256 uncompressed pubkey is exactly 65 bytes (0x04 + x + y).
    assert_equal(len(cert.subject_pubkey), 65)
    # First byte is the EC uncompressed-point marker.
    assert_equal(Int(cert.subject_pubkey[0]), 0x04)


def test_tbs_raw_nonempty() raises:
    """tbs_raw holds the TBSCertificate bytes for downstream signature
    verification by cert/chain.mojo."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    # TBSCertificate is everything from the inner SEQUENCE through the
    # last extension. For a 480-byte cert, TBS is ~390 bytes.
    assert_true(len(cert.tbs_raw) > 100)
    assert_true(len(cert.tbs_raw) < len(der))
    # First byte of TBS must be the SEQUENCE tag (0x30).
    assert_equal(Int(cert.tbs_raw[0]), 0x30)


def test_signature_value_nonempty() raises:
    """signatureValue is the BIT STRING bytes (ECDSA-Sig-Value SEQUENCE)."""
    var der = _self_signed_test_cert_der()
    var cert = x509_parse_certificate(der)
    # ECDSA-P256 signature: typically 70-72 bytes (DER-encoded { r, s }).
    assert_true(len(cert.signature_value) > 60)
    assert_true(len(cert.signature_value) < 80)


def main() raises:
    test_parse_succeeds()
    test_serial_number()
    test_signature_algo_oid()
    test_subject_pubkey_algo_oid()
    test_issuer_equals_subject()
    test_subject_cn()
    test_subject_country()
    test_validity_period()
    test_extension_count()
    test_basic_constraints_critical()
    test_key_usage_critical()
    test_ext_key_usage_present()
    test_san_present()
    test_subject_key_id_present()
    test_find_extension_negative()
    test_subject_pubkey_nonempty()
    test_tbs_raw_nonempty()
    test_signature_value_nonempty()
    print("All 18 x509 cert parser tests PASSED")
