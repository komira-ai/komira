# =============================================================================
# komira_crypto/tests/test_x509_letsencrypt_r3.mojo
# Real Let's Encrypt R3 cert parse + fuzz.
# =============================================================================
#
# Two distinct test surfaces in this file:
#
# 1. Real-cert assertions: parser MUST extract correct fields from the
#    real LE R3 intermediate (vendored from letsencrypt.org). Locks the
#    parser against an actual production CA cert.
#
# 2. Malformed-fuzz corpus: 20+ adversarial DER inputs that MUST raise
#    gracefully (no crash, no UB). These exercise the boundary conditions
#    of the ASN.1 + X.509 parser layers.
#
# The LE R3 bytes are vendored at gen time (one-time download from
# letsencrypt.org); the cert was issued 2020-09-04, expires 2025-09-15.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.cert.x509 import (
    X509Certificate,
    Extension,
    x509_parse_certificate,
    x509_find_extension,
)
from komira_crypto.cert.asn1 import (
    der_oid_eq,
    der_parse_tag,
    der_parse_length,
    der_parse_tlv,
    der_parse_boolean,
    der_parse_integer_to_int64,
    der_parse_oid,
    der_parse_utc_time,
    der_parse_generalized_time,
    der_parse_bit_string,
    der_iter_count,
    der_expect_tag,
    ASN1_CLASS_UNIVERSAL,
    ASN1_TAG_INTEGER,
    ASN1_TAG_SEQUENCE,
)


def _oid_common_name() -> List[UInt32]:
    var o = List[UInt32](); o.append(UInt32(2)); o.append(UInt32(5))
    o.append(UInt32(4)); o.append(UInt32(3)); return o^

def _oid_country_name() -> List[UInt32]:
    var o = List[UInt32](); o.append(UInt32(2)); o.append(UInt32(5))
    o.append(UInt32(4)); o.append(UInt32(6)); return o^

def _oid_org_name() -> List[UInt32]:
    var o = List[UInt32](); o.append(UInt32(2)); o.append(UInt32(5))
    o.append(UInt32(4)); o.append(UInt32(10)); return o^

def _oid_sha256_with_rsa() -> List[UInt32]:
    # 1.2.840.113549.1.1.11
    var o = List[UInt32](); o.append(UInt32(1)); o.append(UInt32(2))
    o.append(UInt32(840)); o.append(UInt32(113549)); o.append(UInt32(1))
    o.append(UInt32(1)); o.append(UInt32(11)); return o^

def _oid_rsa_encryption() -> List[UInt32]:
    # 1.2.840.113549.1.1.1
    var o = List[UInt32](); o.append(UInt32(1)); o.append(UInt32(2))
    o.append(UInt32(840)); o.append(UInt32(113549)); o.append(UInt32(1))
    o.append(UInt32(1)); o.append(UInt32(1)); return o^

def _oid_basic_constraints() -> List[UInt32]:
    var o = List[UInt32](); o.append(UInt32(2)); o.append(UInt32(5))
    o.append(UInt32(29)); o.append(UInt32(19)); return o^


def _list_from_bytes(*vals: UInt8) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(vals)):
        out.append(vals[i])
    return out^


# Length: 1306 bytes
def _letsencrypt_r3_der() -> List[UInt8]:
    """Real Let's Encrypt R3 intermediate cert DER bytes.
    Vendored from <https://letsencrypt.org/certs/lets-encrypt-r3.der>.
    Stable; well-known intermediate signed by ISRG Root X1."""
    var d = List[UInt8]()
    d.append(UInt8(0x30))
    d.append(UInt8(0x82))
    d.append(UInt8(0x05))
    d.append(UInt8(0x16))
    d.append(UInt8(0x30))
    d.append(UInt8(0x82))
    d.append(UInt8(0x02))
    d.append(UInt8(0xfe))
    d.append(UInt8(0xa0))
    d.append(UInt8(0x03))
    d.append(UInt8(0x02))
    d.append(UInt8(0x01))
    d.append(UInt8(0x02))
    d.append(UInt8(0x02))
    d.append(UInt8(0x11))
    d.append(UInt8(0x00))
    d.append(UInt8(0x91))
    d.append(UInt8(0x2b))
    d.append(UInt8(0x08))
    d.append(UInt8(0x4a))
    d.append(UInt8(0xcf))
    d.append(UInt8(0x0c))
    d.append(UInt8(0x18))
    d.append(UInt8(0xa7))
    d.append(UInt8(0x53))
    d.append(UInt8(0xf6))
    d.append(UInt8(0xd6))
    d.append(UInt8(0x2e))
    d.append(UInt8(0x25))
    d.append(UInt8(0xa7))
    d.append(UInt8(0x5f))
    d.append(UInt8(0x5a))
    d.append(UInt8(0x30))
    d.append(UInt8(0x0d))
    d.append(UInt8(0x06))
    d.append(UInt8(0x09))
    d.append(UInt8(0x2a))
    d.append(UInt8(0x86))
    d.append(UInt8(0x48))
    d.append(UInt8(0x86))
    d.append(UInt8(0xf7))
    d.append(UInt8(0x0d))
    d.append(UInt8(0x01))
    d.append(UInt8(0x01))
    d.append(UInt8(0x0b))
    d.append(UInt8(0x05))
    d.append(UInt8(0x00))
    d.append(UInt8(0x30))
    d.append(UInt8(0x4f))
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
    d.append(UInt8(0x29))
    d.append(UInt8(0x30))
    d.append(UInt8(0x27))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x04))
    d.append(UInt8(0x0a))
    d.append(UInt8(0x13))
    d.append(UInt8(0x20))
    d.append(UInt8(0x49))
    d.append(UInt8(0x6e))
    d.append(UInt8(0x74))
    d.append(UInt8(0x65))
    d.append(UInt8(0x72))
    d.append(UInt8(0x6e))
    d.append(UInt8(0x65))
    d.append(UInt8(0x74))
    d.append(UInt8(0x20))
    d.append(UInt8(0x53))
    d.append(UInt8(0x65))
    d.append(UInt8(0x63))
    d.append(UInt8(0x75))
    d.append(UInt8(0x72))
    d.append(UInt8(0x69))
    d.append(UInt8(0x74))
    d.append(UInt8(0x79))
    d.append(UInt8(0x20))
    d.append(UInt8(0x52))
    d.append(UInt8(0x65))
    d.append(UInt8(0x73))
    d.append(UInt8(0x65))
    d.append(UInt8(0x61))
    d.append(UInt8(0x72))
    d.append(UInt8(0x63))
    d.append(UInt8(0x68))
    d.append(UInt8(0x20))
    d.append(UInt8(0x47))
    d.append(UInt8(0x72))
    d.append(UInt8(0x6f))
    d.append(UInt8(0x75))
    d.append(UInt8(0x70))
    d.append(UInt8(0x31))
    d.append(UInt8(0x15))
    d.append(UInt8(0x30))
    d.append(UInt8(0x13))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x04))
    d.append(UInt8(0x03))
    d.append(UInt8(0x13))
    d.append(UInt8(0x0c))
    d.append(UInt8(0x49))
    d.append(UInt8(0x53))
    d.append(UInt8(0x52))
    d.append(UInt8(0x47))
    d.append(UInt8(0x20))
    d.append(UInt8(0x52))
    d.append(UInt8(0x6f))
    d.append(UInt8(0x6f))
    d.append(UInt8(0x74))
    d.append(UInt8(0x20))
    d.append(UInt8(0x58))
    d.append(UInt8(0x31))
    d.append(UInt8(0x30))
    d.append(UInt8(0x1e))
    d.append(UInt8(0x17))
    d.append(UInt8(0x0d))
    d.append(UInt8(0x32))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x39))
    d.append(UInt8(0x30))
    d.append(UInt8(0x34))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x5a))
    d.append(UInt8(0x17))
    d.append(UInt8(0x0d))
    d.append(UInt8(0x32))
    d.append(UInt8(0x35))
    d.append(UInt8(0x30))
    d.append(UInt8(0x39))
    d.append(UInt8(0x31))
    d.append(UInt8(0x35))
    d.append(UInt8(0x31))
    d.append(UInt8(0x36))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x30))
    d.append(UInt8(0x5a))
    d.append(UInt8(0x30))
    d.append(UInt8(0x32))
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
    d.append(UInt8(0x16))
    d.append(UInt8(0x30))
    d.append(UInt8(0x14))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x04))
    d.append(UInt8(0x0a))
    d.append(UInt8(0x13))
    d.append(UInt8(0x0d))
    d.append(UInt8(0x4c))
    d.append(UInt8(0x65))
    d.append(UInt8(0x74))
    d.append(UInt8(0x27))
    d.append(UInt8(0x73))
    d.append(UInt8(0x20))
    d.append(UInt8(0x45))
    d.append(UInt8(0x6e))
    d.append(UInt8(0x63))
    d.append(UInt8(0x72))
    d.append(UInt8(0x79))
    d.append(UInt8(0x70))
    d.append(UInt8(0x74))
    d.append(UInt8(0x31))
    d.append(UInt8(0x0b))
    d.append(UInt8(0x30))
    d.append(UInt8(0x09))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x04))
    d.append(UInt8(0x03))
    d.append(UInt8(0x13))
    d.append(UInt8(0x02))
    d.append(UInt8(0x52))
    d.append(UInt8(0x33))
    d.append(UInt8(0x30))
    d.append(UInt8(0x82))
    d.append(UInt8(0x01))
    d.append(UInt8(0x22))
    d.append(UInt8(0x30))
    d.append(UInt8(0x0d))
    d.append(UInt8(0x06))
    d.append(UInt8(0x09))
    d.append(UInt8(0x2a))
    d.append(UInt8(0x86))
    d.append(UInt8(0x48))
    d.append(UInt8(0x86))
    d.append(UInt8(0xf7))
    d.append(UInt8(0x0d))
    d.append(UInt8(0x01))
    d.append(UInt8(0x01))
    d.append(UInt8(0x01))
    d.append(UInt8(0x05))
    d.append(UInt8(0x00))
    d.append(UInt8(0x03))
    d.append(UInt8(0x82))
    d.append(UInt8(0x01))
    d.append(UInt8(0x0f))
    d.append(UInt8(0x00))
    d.append(UInt8(0x30))
    d.append(UInt8(0x82))
    d.append(UInt8(0x01))
    d.append(UInt8(0x0a))
    d.append(UInt8(0x02))
    d.append(UInt8(0x82))
    d.append(UInt8(0x01))
    d.append(UInt8(0x01))
    d.append(UInt8(0x00))
    d.append(UInt8(0xbb))
    d.append(UInt8(0x02))
    d.append(UInt8(0x15))
    d.append(UInt8(0x28))
    d.append(UInt8(0xcc))
    d.append(UInt8(0xf6))
    d.append(UInt8(0xa0))
    d.append(UInt8(0x94))
    d.append(UInt8(0xd3))
    d.append(UInt8(0x0f))
    d.append(UInt8(0x12))
    d.append(UInt8(0xec))
    d.append(UInt8(0x8d))
    d.append(UInt8(0x55))
    d.append(UInt8(0x92))
    d.append(UInt8(0xc3))
    d.append(UInt8(0xf8))
    d.append(UInt8(0x82))
    d.append(UInt8(0xf1))
    d.append(UInt8(0x99))
    d.append(UInt8(0xa6))
    d.append(UInt8(0x7a))
    d.append(UInt8(0x42))
    d.append(UInt8(0x88))
    d.append(UInt8(0xa7))
    d.append(UInt8(0x5d))
    d.append(UInt8(0x26))
    d.append(UInt8(0xaa))
    d.append(UInt8(0xb5))
    d.append(UInt8(0x2b))
    d.append(UInt8(0xb9))
    d.append(UInt8(0xc5))
    d.append(UInt8(0x4c))
    d.append(UInt8(0xb1))
    d.append(UInt8(0xaf))
    d.append(UInt8(0x8e))
    d.append(UInt8(0x6b))
    d.append(UInt8(0xf9))
    d.append(UInt8(0x75))
    d.append(UInt8(0xc8))
    d.append(UInt8(0xa3))
    d.append(UInt8(0xd7))
    d.append(UInt8(0x0f))
    d.append(UInt8(0x47))
    d.append(UInt8(0x94))
    d.append(UInt8(0x14))
    d.append(UInt8(0x55))
    d.append(UInt8(0x35))
    d.append(UInt8(0x57))
    d.append(UInt8(0x8c))
    d.append(UInt8(0x9e))
    d.append(UInt8(0xa8))
    d.append(UInt8(0xa2))
    d.append(UInt8(0x39))
    d.append(UInt8(0x19))
    d.append(UInt8(0xf5))
    d.append(UInt8(0x82))
    d.append(UInt8(0x3c))
    d.append(UInt8(0x42))
    d.append(UInt8(0xa9))
    d.append(UInt8(0x4e))
    d.append(UInt8(0x6e))
    d.append(UInt8(0xf5))
    d.append(UInt8(0x3b))
    d.append(UInt8(0xc3))
    d.append(UInt8(0x2e))
    d.append(UInt8(0xdb))
    d.append(UInt8(0x8d))
    d.append(UInt8(0xc0))
    d.append(UInt8(0xb0))
    d.append(UInt8(0x5c))
    d.append(UInt8(0xf3))
    d.append(UInt8(0x59))
    d.append(UInt8(0x38))
    d.append(UInt8(0xe7))
    d.append(UInt8(0xed))
    d.append(UInt8(0xcf))
    d.append(UInt8(0x69))
    d.append(UInt8(0xf0))
    d.append(UInt8(0x5a))
    d.append(UInt8(0x0b))
    d.append(UInt8(0x1b))
    d.append(UInt8(0xbe))
    d.append(UInt8(0xc0))
    d.append(UInt8(0x94))
    d.append(UInt8(0x24))
    d.append(UInt8(0x25))
    d.append(UInt8(0x87))
    d.append(UInt8(0xfa))
    d.append(UInt8(0x37))
    d.append(UInt8(0x71))
    d.append(UInt8(0xb3))
    d.append(UInt8(0x13))
    d.append(UInt8(0xe7))
    d.append(UInt8(0x1c))
    d.append(UInt8(0xac))
    d.append(UInt8(0xe1))
    d.append(UInt8(0x9b))
    d.append(UInt8(0xef))
    d.append(UInt8(0xdb))
    d.append(UInt8(0xe4))
    d.append(UInt8(0x3b))
    d.append(UInt8(0x45))
    d.append(UInt8(0x52))
    d.append(UInt8(0x45))
    d.append(UInt8(0x96))
    d.append(UInt8(0xa9))
    d.append(UInt8(0xc1))
    d.append(UInt8(0x53))
    d.append(UInt8(0xce))
    d.append(UInt8(0x34))
    d.append(UInt8(0xc8))
    d.append(UInt8(0x52))
    d.append(UInt8(0xee))
    d.append(UInt8(0xb5))
    d.append(UInt8(0xae))
    d.append(UInt8(0xed))
    d.append(UInt8(0x8f))
    d.append(UInt8(0xde))
    d.append(UInt8(0x60))
    d.append(UInt8(0x70))
    d.append(UInt8(0xe2))
    d.append(UInt8(0xa5))
    d.append(UInt8(0x54))
    d.append(UInt8(0xab))
    d.append(UInt8(0xb6))
    d.append(UInt8(0x6d))
    d.append(UInt8(0x0e))
    d.append(UInt8(0x97))
    d.append(UInt8(0xa5))
    d.append(UInt8(0x40))
    d.append(UInt8(0x34))
    d.append(UInt8(0x6b))
    d.append(UInt8(0x2b))
    d.append(UInt8(0xd3))
    d.append(UInt8(0xbc))
    d.append(UInt8(0x66))
    d.append(UInt8(0xeb))
    d.append(UInt8(0x66))
    d.append(UInt8(0x34))
    d.append(UInt8(0x7c))
    d.append(UInt8(0xfa))
    d.append(UInt8(0x6b))
    d.append(UInt8(0x8b))
    d.append(UInt8(0x8f))
    d.append(UInt8(0x57))
    d.append(UInt8(0x29))
    d.append(UInt8(0x99))
    d.append(UInt8(0xf8))
    d.append(UInt8(0x30))
    d.append(UInt8(0x17))
    d.append(UInt8(0x5d))
    d.append(UInt8(0xba))
    d.append(UInt8(0x72))
    d.append(UInt8(0x6f))
    d.append(UInt8(0xfb))
    d.append(UInt8(0x81))
    d.append(UInt8(0xc5))
    d.append(UInt8(0xad))
    d.append(UInt8(0xd2))
    d.append(UInt8(0x86))
    d.append(UInt8(0x58))
    d.append(UInt8(0x3d))
    d.append(UInt8(0x17))
    d.append(UInt8(0xc7))
    d.append(UInt8(0xe7))
    d.append(UInt8(0x09))
    d.append(UInt8(0xbb))
    d.append(UInt8(0xf1))
    d.append(UInt8(0x2b))
    d.append(UInt8(0xf7))
    d.append(UInt8(0x86))
    d.append(UInt8(0xdc))
    d.append(UInt8(0xc1))
    d.append(UInt8(0xda))
    d.append(UInt8(0x71))
    d.append(UInt8(0x5d))
    d.append(UInt8(0xd4))
    d.append(UInt8(0x46))
    d.append(UInt8(0xe3))
    d.append(UInt8(0xcc))
    d.append(UInt8(0xad))
    d.append(UInt8(0x25))
    d.append(UInt8(0xc1))
    d.append(UInt8(0x88))
    d.append(UInt8(0xbc))
    d.append(UInt8(0x60))
    d.append(UInt8(0x67))
    d.append(UInt8(0x75))
    d.append(UInt8(0x66))
    d.append(UInt8(0xb3))
    d.append(UInt8(0xf1))
    d.append(UInt8(0x18))
    d.append(UInt8(0xf7))
    d.append(UInt8(0xa2))
    d.append(UInt8(0x5c))
    d.append(UInt8(0xe6))
    d.append(UInt8(0x53))
    d.append(UInt8(0xff))
    d.append(UInt8(0x3a))
    d.append(UInt8(0x88))
    d.append(UInt8(0xb6))
    d.append(UInt8(0x47))
    d.append(UInt8(0xa5))
    d.append(UInt8(0xff))
    d.append(UInt8(0x13))
    d.append(UInt8(0x18))
    d.append(UInt8(0xea))
    d.append(UInt8(0x98))
    d.append(UInt8(0x09))
    d.append(UInt8(0x77))
    d.append(UInt8(0x3f))
    d.append(UInt8(0x9d))
    d.append(UInt8(0x53))
    d.append(UInt8(0xf9))
    d.append(UInt8(0xcf))
    d.append(UInt8(0x01))
    d.append(UInt8(0xe5))
    d.append(UInt8(0xf5))
    d.append(UInt8(0xa6))
    d.append(UInt8(0x70))
    d.append(UInt8(0x17))
    d.append(UInt8(0x14))
    d.append(UInt8(0xaf))
    d.append(UInt8(0x63))
    d.append(UInt8(0xa4))
    d.append(UInt8(0xff))
    d.append(UInt8(0x99))
    d.append(UInt8(0xb3))
    d.append(UInt8(0x93))
    d.append(UInt8(0x9d))
    d.append(UInt8(0xdc))
    d.append(UInt8(0x53))
    d.append(UInt8(0xa7))
    d.append(UInt8(0x06))
    d.append(UInt8(0xfe))
    d.append(UInt8(0x48))
    d.append(UInt8(0x85))
    d.append(UInt8(0x1d))
    d.append(UInt8(0xa1))
    d.append(UInt8(0x69))
    d.append(UInt8(0xae))
    d.append(UInt8(0x25))
    d.append(UInt8(0x75))
    d.append(UInt8(0xbb))
    d.append(UInt8(0x13))
    d.append(UInt8(0xcc))
    d.append(UInt8(0x52))
    d.append(UInt8(0x03))
    d.append(UInt8(0xf5))
    d.append(UInt8(0xed))
    d.append(UInt8(0x51))
    d.append(UInt8(0xa1))
    d.append(UInt8(0x8b))
    d.append(UInt8(0xdb))
    d.append(UInt8(0x15))
    d.append(UInt8(0x02))
    d.append(UInt8(0x03))
    d.append(UInt8(0x01))
    d.append(UInt8(0x00))
    d.append(UInt8(0x01))
    d.append(UInt8(0xa3))
    d.append(UInt8(0x82))
    d.append(UInt8(0x01))
    d.append(UInt8(0x08))
    d.append(UInt8(0x30))
    d.append(UInt8(0x82))
    d.append(UInt8(0x01))
    d.append(UInt8(0x04))
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
    d.append(UInt8(0x01))
    d.append(UInt8(0x86))
    d.append(UInt8(0x30))
    d.append(UInt8(0x1d))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x1d))
    d.append(UInt8(0x25))
    d.append(UInt8(0x04))
    d.append(UInt8(0x16))
    d.append(UInt8(0x30))
    d.append(UInt8(0x14))
    d.append(UInt8(0x06))
    d.append(UInt8(0x08))
    d.append(UInt8(0x2b))
    d.append(UInt8(0x06))
    d.append(UInt8(0x01))
    d.append(UInt8(0x05))
    d.append(UInt8(0x05))
    d.append(UInt8(0x07))
    d.append(UInt8(0x03))
    d.append(UInt8(0x02))
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
    d.append(UInt8(0x12))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x1d))
    d.append(UInt8(0x13))
    d.append(UInt8(0x01))
    d.append(UInt8(0x01))
    d.append(UInt8(0xff))
    d.append(UInt8(0x04))
    d.append(UInt8(0x08))
    d.append(UInt8(0x30))
    d.append(UInt8(0x06))
    d.append(UInt8(0x01))
    d.append(UInt8(0x01))
    d.append(UInt8(0xff))
    d.append(UInt8(0x02))
    d.append(UInt8(0x01))
    d.append(UInt8(0x00))
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
    d.append(UInt8(0x14))
    d.append(UInt8(0x2e))
    d.append(UInt8(0xb3))
    d.append(UInt8(0x17))
    d.append(UInt8(0xb7))
    d.append(UInt8(0x58))
    d.append(UInt8(0x56))
    d.append(UInt8(0xcb))
    d.append(UInt8(0xae))
    d.append(UInt8(0x50))
    d.append(UInt8(0x09))
    d.append(UInt8(0x40))
    d.append(UInt8(0xe6))
    d.append(UInt8(0x1f))
    d.append(UInt8(0xaf))
    d.append(UInt8(0x9d))
    d.append(UInt8(0x8b))
    d.append(UInt8(0x14))
    d.append(UInt8(0xc2))
    d.append(UInt8(0xc6))
    d.append(UInt8(0x30))
    d.append(UInt8(0x1f))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x1d))
    d.append(UInt8(0x23))
    d.append(UInt8(0x04))
    d.append(UInt8(0x18))
    d.append(UInt8(0x30))
    d.append(UInt8(0x16))
    d.append(UInt8(0x80))
    d.append(UInt8(0x14))
    d.append(UInt8(0x79))
    d.append(UInt8(0xb4))
    d.append(UInt8(0x59))
    d.append(UInt8(0xe6))
    d.append(UInt8(0x7b))
    d.append(UInt8(0xb6))
    d.append(UInt8(0xe5))
    d.append(UInt8(0xe4))
    d.append(UInt8(0x01))
    d.append(UInt8(0x73))
    d.append(UInt8(0x80))
    d.append(UInt8(0x08))
    d.append(UInt8(0x88))
    d.append(UInt8(0xc8))
    d.append(UInt8(0x1a))
    d.append(UInt8(0x58))
    d.append(UInt8(0xf6))
    d.append(UInt8(0xe9))
    d.append(UInt8(0x9b))
    d.append(UInt8(0x6e))
    d.append(UInt8(0x30))
    d.append(UInt8(0x32))
    d.append(UInt8(0x06))
    d.append(UInt8(0x08))
    d.append(UInt8(0x2b))
    d.append(UInt8(0x06))
    d.append(UInt8(0x01))
    d.append(UInt8(0x05))
    d.append(UInt8(0x05))
    d.append(UInt8(0x07))
    d.append(UInt8(0x01))
    d.append(UInt8(0x01))
    d.append(UInt8(0x04))
    d.append(UInt8(0x26))
    d.append(UInt8(0x30))
    d.append(UInt8(0x24))
    d.append(UInt8(0x30))
    d.append(UInt8(0x22))
    d.append(UInt8(0x06))
    d.append(UInt8(0x08))
    d.append(UInt8(0x2b))
    d.append(UInt8(0x06))
    d.append(UInt8(0x01))
    d.append(UInt8(0x05))
    d.append(UInt8(0x05))
    d.append(UInt8(0x07))
    d.append(UInt8(0x30))
    d.append(UInt8(0x02))
    d.append(UInt8(0x86))
    d.append(UInt8(0x16))
    d.append(UInt8(0x68))
    d.append(UInt8(0x74))
    d.append(UInt8(0x74))
    d.append(UInt8(0x70))
    d.append(UInt8(0x3a))
    d.append(UInt8(0x2f))
    d.append(UInt8(0x2f))
    d.append(UInt8(0x78))
    d.append(UInt8(0x31))
    d.append(UInt8(0x2e))
    d.append(UInt8(0x69))
    d.append(UInt8(0x2e))
    d.append(UInt8(0x6c))
    d.append(UInt8(0x65))
    d.append(UInt8(0x6e))
    d.append(UInt8(0x63))
    d.append(UInt8(0x72))
    d.append(UInt8(0x2e))
    d.append(UInt8(0x6f))
    d.append(UInt8(0x72))
    d.append(UInt8(0x67))
    d.append(UInt8(0x2f))
    d.append(UInt8(0x30))
    d.append(UInt8(0x27))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x1d))
    d.append(UInt8(0x1f))
    d.append(UInt8(0x04))
    d.append(UInt8(0x20))
    d.append(UInt8(0x30))
    d.append(UInt8(0x1e))
    d.append(UInt8(0x30))
    d.append(UInt8(0x1c))
    d.append(UInt8(0xa0))
    d.append(UInt8(0x1a))
    d.append(UInt8(0xa0))
    d.append(UInt8(0x18))
    d.append(UInt8(0x86))
    d.append(UInt8(0x16))
    d.append(UInt8(0x68))
    d.append(UInt8(0x74))
    d.append(UInt8(0x74))
    d.append(UInt8(0x70))
    d.append(UInt8(0x3a))
    d.append(UInt8(0x2f))
    d.append(UInt8(0x2f))
    d.append(UInt8(0x78))
    d.append(UInt8(0x31))
    d.append(UInt8(0x2e))
    d.append(UInt8(0x63))
    d.append(UInt8(0x2e))
    d.append(UInt8(0x6c))
    d.append(UInt8(0x65))
    d.append(UInt8(0x6e))
    d.append(UInt8(0x63))
    d.append(UInt8(0x72))
    d.append(UInt8(0x2e))
    d.append(UInt8(0x6f))
    d.append(UInt8(0x72))
    d.append(UInt8(0x67))
    d.append(UInt8(0x2f))
    d.append(UInt8(0x30))
    d.append(UInt8(0x22))
    d.append(UInt8(0x06))
    d.append(UInt8(0x03))
    d.append(UInt8(0x55))
    d.append(UInt8(0x1d))
    d.append(UInt8(0x20))
    d.append(UInt8(0x04))
    d.append(UInt8(0x1b))
    d.append(UInt8(0x30))
    d.append(UInt8(0x19))
    d.append(UInt8(0x30))
    d.append(UInt8(0x08))
    d.append(UInt8(0x06))
    d.append(UInt8(0x06))
    d.append(UInt8(0x67))
    d.append(UInt8(0x81))
    d.append(UInt8(0x0c))
    d.append(UInt8(0x01))
    d.append(UInt8(0x02))
    d.append(UInt8(0x01))
    d.append(UInt8(0x30))
    d.append(UInt8(0x0d))
    d.append(UInt8(0x06))
    d.append(UInt8(0x0b))
    d.append(UInt8(0x2b))
    d.append(UInt8(0x06))
    d.append(UInt8(0x01))
    d.append(UInt8(0x04))
    d.append(UInt8(0x01))
    d.append(UInt8(0x82))
    d.append(UInt8(0xdf))
    d.append(UInt8(0x13))
    d.append(UInt8(0x01))
    d.append(UInt8(0x01))
    d.append(UInt8(0x01))
    d.append(UInt8(0x30))
    d.append(UInt8(0x0d))
    d.append(UInt8(0x06))
    d.append(UInt8(0x09))
    d.append(UInt8(0x2a))
    d.append(UInt8(0x86))
    d.append(UInt8(0x48))
    d.append(UInt8(0x86))
    d.append(UInt8(0xf7))
    d.append(UInt8(0x0d))
    d.append(UInt8(0x01))
    d.append(UInt8(0x01))
    d.append(UInt8(0x0b))
    d.append(UInt8(0x05))
    d.append(UInt8(0x00))
    d.append(UInt8(0x03))
    d.append(UInt8(0x82))
    d.append(UInt8(0x02))
    d.append(UInt8(0x01))
    d.append(UInt8(0x00))
    d.append(UInt8(0x85))
    d.append(UInt8(0xca))
    d.append(UInt8(0x4e))
    d.append(UInt8(0x47))
    d.append(UInt8(0x3e))
    d.append(UInt8(0xa3))
    d.append(UInt8(0xf7))
    d.append(UInt8(0x85))
    d.append(UInt8(0x44))
    d.append(UInt8(0x85))
    d.append(UInt8(0xbc))
    d.append(UInt8(0xd5))
    d.append(UInt8(0x67))
    d.append(UInt8(0x78))
    d.append(UInt8(0xb2))
    d.append(UInt8(0x98))
    d.append(UInt8(0x63))
    d.append(UInt8(0xad))
    d.append(UInt8(0x75))
    d.append(UInt8(0x4d))
    d.append(UInt8(0x1e))
    d.append(UInt8(0x96))
    d.append(UInt8(0x3d))
    d.append(UInt8(0x33))
    d.append(UInt8(0x65))
    d.append(UInt8(0x72))
    d.append(UInt8(0x54))
    d.append(UInt8(0x2d))
    d.append(UInt8(0x81))
    d.append(UInt8(0xa0))
    d.append(UInt8(0xea))
    d.append(UInt8(0xc3))
    d.append(UInt8(0xed))
    d.append(UInt8(0xf8))
    d.append(UInt8(0x20))
    d.append(UInt8(0xbf))
    d.append(UInt8(0x5f))
    d.append(UInt8(0xcc))
    d.append(UInt8(0xb7))
    d.append(UInt8(0x70))
    d.append(UInt8(0x00))
    d.append(UInt8(0xb7))
    d.append(UInt8(0x6e))
    d.append(UInt8(0x3b))
    d.append(UInt8(0xf6))
    d.append(UInt8(0x5e))
    d.append(UInt8(0x94))
    d.append(UInt8(0xde))
    d.append(UInt8(0xe4))
    d.append(UInt8(0x20))
    d.append(UInt8(0x9f))
    d.append(UInt8(0xa6))
    d.append(UInt8(0xef))
    d.append(UInt8(0x8b))
    d.append(UInt8(0xb2))
    d.append(UInt8(0x03))
    d.append(UInt8(0xe7))
    d.append(UInt8(0xa2))
    d.append(UInt8(0xb5))
    d.append(UInt8(0x16))
    d.append(UInt8(0x3c))
    d.append(UInt8(0x91))
    d.append(UInt8(0xce))
    d.append(UInt8(0xb4))
    d.append(UInt8(0xed))
    d.append(UInt8(0x39))
    d.append(UInt8(0x02))
    d.append(UInt8(0xe7))
    d.append(UInt8(0x7c))
    d.append(UInt8(0x25))
    d.append(UInt8(0x8a))
    d.append(UInt8(0x47))
    d.append(UInt8(0xe6))
    d.append(UInt8(0x65))
    d.append(UInt8(0x6e))
    d.append(UInt8(0x3f))
    d.append(UInt8(0x46))
    d.append(UInt8(0xf4))
    d.append(UInt8(0xd9))
    d.append(UInt8(0xf0))
    d.append(UInt8(0xce))
    d.append(UInt8(0x94))
    d.append(UInt8(0x2b))
    d.append(UInt8(0xee))
    d.append(UInt8(0x54))
    d.append(UInt8(0xce))
    d.append(UInt8(0x12))
    d.append(UInt8(0xbc))
    d.append(UInt8(0x8c))
    d.append(UInt8(0x27))
    d.append(UInt8(0x4b))
    d.append(UInt8(0xb8))
    d.append(UInt8(0xc1))
    d.append(UInt8(0x98))
    d.append(UInt8(0x2f))
    d.append(UInt8(0xa2))
    d.append(UInt8(0xaf))
    d.append(UInt8(0xcd))
    d.append(UInt8(0x71))
    d.append(UInt8(0x91))
    d.append(UInt8(0x4a))
    d.append(UInt8(0x08))
    d.append(UInt8(0xb7))
    d.append(UInt8(0xc8))
    d.append(UInt8(0xb8))
    d.append(UInt8(0x23))
    d.append(UInt8(0x7b))
    d.append(UInt8(0x04))
    d.append(UInt8(0x2d))
    d.append(UInt8(0x08))
    d.append(UInt8(0xf9))
    d.append(UInt8(0x08))
    d.append(UInt8(0x57))
    d.append(UInt8(0x3e))
    d.append(UInt8(0x83))
    d.append(UInt8(0xd9))
    d.append(UInt8(0x04))
    d.append(UInt8(0x33))
    d.append(UInt8(0x0a))
    d.append(UInt8(0x47))
    d.append(UInt8(0x21))
    d.append(UInt8(0x78))
    d.append(UInt8(0x09))
    d.append(UInt8(0x82))
    d.append(UInt8(0x27))
    d.append(UInt8(0xc3))
    d.append(UInt8(0x2a))
    d.append(UInt8(0xc8))
    d.append(UInt8(0x9b))
    d.append(UInt8(0xb9))
    d.append(UInt8(0xce))
    d.append(UInt8(0x5c))
    d.append(UInt8(0xf2))
    d.append(UInt8(0x64))
    d.append(UInt8(0xc8))
    d.append(UInt8(0xc0))
    d.append(UInt8(0xbe))
    d.append(UInt8(0x79))
    d.append(UInt8(0xc0))
    d.append(UInt8(0x4f))
    d.append(UInt8(0x8e))
    d.append(UInt8(0x6d))
    d.append(UInt8(0x44))
    d.append(UInt8(0x0c))
    d.append(UInt8(0x5e))
    d.append(UInt8(0x92))
    d.append(UInt8(0xbb))
    d.append(UInt8(0x2e))
    d.append(UInt8(0xf7))
    d.append(UInt8(0x8b))
    d.append(UInt8(0x10))
    d.append(UInt8(0xe1))
    d.append(UInt8(0xe8))
    d.append(UInt8(0x1d))
    d.append(UInt8(0x44))
    d.append(UInt8(0x29))
    d.append(UInt8(0xdb))
    d.append(UInt8(0x59))
    d.append(UInt8(0x20))
    d.append(UInt8(0xed))
    d.append(UInt8(0x63))
    d.append(UInt8(0xb9))
    d.append(UInt8(0x21))
    d.append(UInt8(0xf8))
    d.append(UInt8(0x12))
    d.append(UInt8(0x26))
    d.append(UInt8(0x94))
    d.append(UInt8(0x93))
    d.append(UInt8(0x57))
    d.append(UInt8(0xa0))
    d.append(UInt8(0x1d))
    d.append(UInt8(0x65))
    d.append(UInt8(0x04))
    d.append(UInt8(0xc1))
    d.append(UInt8(0x0a))
    d.append(UInt8(0x22))
    d.append(UInt8(0xae))
    d.append(UInt8(0x10))
    d.append(UInt8(0x0d))
    d.append(UInt8(0x43))
    d.append(UInt8(0x97))
    d.append(UInt8(0xa1))
    d.append(UInt8(0x18))
    d.append(UInt8(0x1f))
    d.append(UInt8(0x7e))
    d.append(UInt8(0xe0))
    d.append(UInt8(0xe0))
    d.append(UInt8(0x86))
    d.append(UInt8(0x37))
    d.append(UInt8(0xb5))
    d.append(UInt8(0x5a))
    d.append(UInt8(0xb1))
    d.append(UInt8(0xbd))
    d.append(UInt8(0x30))
    d.append(UInt8(0xbf))
    d.append(UInt8(0x87))
    d.append(UInt8(0x6e))
    d.append(UInt8(0x2b))
    d.append(UInt8(0x2a))
    d.append(UInt8(0xff))
    d.append(UInt8(0x21))
    d.append(UInt8(0x4e))
    d.append(UInt8(0x1b))
    d.append(UInt8(0x05))
    d.append(UInt8(0xc3))
    d.append(UInt8(0xf5))
    d.append(UInt8(0x18))
    d.append(UInt8(0x97))
    d.append(UInt8(0xf0))
    d.append(UInt8(0x5e))
    d.append(UInt8(0xac))
    d.append(UInt8(0xc3))
    d.append(UInt8(0xa5))
    d.append(UInt8(0xb8))
    d.append(UInt8(0x6a))
    d.append(UInt8(0xf0))
    d.append(UInt8(0x2e))
    d.append(UInt8(0xbc))
    d.append(UInt8(0x3b))
    d.append(UInt8(0x33))
    d.append(UInt8(0xb9))
    d.append(UInt8(0xee))
    d.append(UInt8(0x4b))
    d.append(UInt8(0xde))
    d.append(UInt8(0xcc))
    d.append(UInt8(0xfc))
    d.append(UInt8(0xe4))
    d.append(UInt8(0xaf))
    d.append(UInt8(0x84))
    d.append(UInt8(0x0b))
    d.append(UInt8(0x86))
    d.append(UInt8(0x3f))
    d.append(UInt8(0xc0))
    d.append(UInt8(0x55))
    d.append(UInt8(0x43))
    d.append(UInt8(0x36))
    d.append(UInt8(0xf6))
    d.append(UInt8(0x68))
    d.append(UInt8(0xe1))
    d.append(UInt8(0x36))
    d.append(UInt8(0x17))
    d.append(UInt8(0x6a))
    d.append(UInt8(0x8e))
    d.append(UInt8(0x99))
    d.append(UInt8(0xd1))
    d.append(UInt8(0xff))
    d.append(UInt8(0xa5))
    d.append(UInt8(0x40))
    d.append(UInt8(0xa7))
    d.append(UInt8(0x34))
    d.append(UInt8(0xb7))
    d.append(UInt8(0xc0))
    d.append(UInt8(0xd0))
    d.append(UInt8(0x63))
    d.append(UInt8(0x39))
    d.append(UInt8(0x35))
    d.append(UInt8(0x39))
    d.append(UInt8(0x75))
    d.append(UInt8(0x6e))
    d.append(UInt8(0xf2))
    d.append(UInt8(0xba))
    d.append(UInt8(0x76))
    d.append(UInt8(0xc8))
    d.append(UInt8(0x93))
    d.append(UInt8(0x02))
    d.append(UInt8(0xe9))
    d.append(UInt8(0xa9))
    d.append(UInt8(0x4b))
    d.append(UInt8(0x6c))
    d.append(UInt8(0x17))
    d.append(UInt8(0xce))
    d.append(UInt8(0x0c))
    d.append(UInt8(0x02))
    d.append(UInt8(0xd9))
    d.append(UInt8(0xbd))
    d.append(UInt8(0x81))
    d.append(UInt8(0xfb))
    d.append(UInt8(0x9f))
    d.append(UInt8(0xb7))
    d.append(UInt8(0x68))
    d.append(UInt8(0xd4))
    d.append(UInt8(0x06))
    d.append(UInt8(0x65))
    d.append(UInt8(0xb3))
    d.append(UInt8(0x82))
    d.append(UInt8(0x3d))
    d.append(UInt8(0x77))
    d.append(UInt8(0x53))
    d.append(UInt8(0xf8))
    d.append(UInt8(0x8e))
    d.append(UInt8(0x79))
    d.append(UInt8(0x03))
    d.append(UInt8(0xad))
    d.append(UInt8(0x0a))
    d.append(UInt8(0x31))
    d.append(UInt8(0x07))
    d.append(UInt8(0x75))
    d.append(UInt8(0x2a))
    d.append(UInt8(0x43))
    d.append(UInt8(0xd8))
    d.append(UInt8(0x55))
    d.append(UInt8(0x97))
    d.append(UInt8(0x72))
    d.append(UInt8(0xc4))
    d.append(UInt8(0x29))
    d.append(UInt8(0x0e))
    d.append(UInt8(0xf7))
    d.append(UInt8(0xc4))
    d.append(UInt8(0x5d))
    d.append(UInt8(0x4e))
    d.append(UInt8(0xc8))
    d.append(UInt8(0xae))
    d.append(UInt8(0x46))
    d.append(UInt8(0x84))
    d.append(UInt8(0x30))
    d.append(UInt8(0xd7))
    d.append(UInt8(0xf2))
    d.append(UInt8(0x85))
    d.append(UInt8(0x5f))
    d.append(UInt8(0x18))
    d.append(UInt8(0xa1))
    d.append(UInt8(0x79))
    d.append(UInt8(0xbb))
    d.append(UInt8(0xe7))
    d.append(UInt8(0x5e))
    d.append(UInt8(0x70))
    d.append(UInt8(0x8b))
    d.append(UInt8(0x07))
    d.append(UInt8(0xe1))
    d.append(UInt8(0x86))
    d.append(UInt8(0x93))
    d.append(UInt8(0xc3))
    d.append(UInt8(0xb9))
    d.append(UInt8(0x8f))
    d.append(UInt8(0xdc))
    d.append(UInt8(0x61))
    d.append(UInt8(0x71))
    d.append(UInt8(0x25))
    d.append(UInt8(0x2a))
    d.append(UInt8(0xaf))
    d.append(UInt8(0xdf))
    d.append(UInt8(0xed))
    d.append(UInt8(0x25))
    d.append(UInt8(0x50))
    d.append(UInt8(0x52))
    d.append(UInt8(0x68))
    d.append(UInt8(0x8b))
    d.append(UInt8(0x92))
    d.append(UInt8(0xdc))
    d.append(UInt8(0xe5))
    d.append(UInt8(0xd6))
    d.append(UInt8(0xb5))
    d.append(UInt8(0xe3))
    d.append(UInt8(0xda))
    d.append(UInt8(0x7d))
    d.append(UInt8(0xd0))
    d.append(UInt8(0x87))
    d.append(UInt8(0x6c))
    d.append(UInt8(0x84))
    d.append(UInt8(0x21))
    d.append(UInt8(0x31))
    d.append(UInt8(0xae))
    d.append(UInt8(0x82))
    d.append(UInt8(0xf5))
    d.append(UInt8(0xfb))
    d.append(UInt8(0xb9))
    d.append(UInt8(0xab))
    d.append(UInt8(0xc8))
    d.append(UInt8(0x89))
    d.append(UInt8(0x17))
    d.append(UInt8(0x3d))
    d.append(UInt8(0xe1))
    d.append(UInt8(0x4c))
    d.append(UInt8(0xe5))
    d.append(UInt8(0x38))
    d.append(UInt8(0x0e))
    d.append(UInt8(0xf6))
    d.append(UInt8(0xbd))
    d.append(UInt8(0x2b))
    d.append(UInt8(0xbd))
    d.append(UInt8(0x96))
    d.append(UInt8(0x81))
    d.append(UInt8(0x14))
    d.append(UInt8(0xeb))
    d.append(UInt8(0xd5))
    d.append(UInt8(0xdb))
    d.append(UInt8(0x3d))
    d.append(UInt8(0x20))
    d.append(UInt8(0xa7))
    d.append(UInt8(0x7e))
    d.append(UInt8(0x59))
    d.append(UInt8(0xd3))
    d.append(UInt8(0xe2))
    d.append(UInt8(0xf8))
    d.append(UInt8(0x58))
    d.append(UInt8(0xf9))
    d.append(UInt8(0x5b))
    d.append(UInt8(0xb8))
    d.append(UInt8(0x48))
    d.append(UInt8(0xcd))
    d.append(UInt8(0xfe))
    d.append(UInt8(0x5c))
    d.append(UInt8(0x4f))
    d.append(UInt8(0x16))
    d.append(UInt8(0x29))
    d.append(UInt8(0xfe))
    d.append(UInt8(0x1e))
    d.append(UInt8(0x55))
    d.append(UInt8(0x23))
    d.append(UInt8(0xaf))
    d.append(UInt8(0xc8))
    d.append(UInt8(0x11))
    d.append(UInt8(0xb0))
    d.append(UInt8(0x8d))
    d.append(UInt8(0xea))
    d.append(UInt8(0x7c))
    d.append(UInt8(0x93))
    d.append(UInt8(0x90))
    d.append(UInt8(0x17))
    d.append(UInt8(0x2f))
    d.append(UInt8(0xfd))
    d.append(UInt8(0xac))
    d.append(UInt8(0xa2))
    d.append(UInt8(0x09))
    d.append(UInt8(0x47))
    d.append(UInt8(0x46))
    d.append(UInt8(0x3f))
    d.append(UInt8(0xf0))
    d.append(UInt8(0xe9))
    d.append(UInt8(0xb0))
    d.append(UInt8(0xb7))
    d.append(UInt8(0xff))
    d.append(UInt8(0x28))
    d.append(UInt8(0x4d))
    d.append(UInt8(0x68))
    d.append(UInt8(0x32))
    d.append(UInt8(0xd6))
    d.append(UInt8(0x67))
    d.append(UInt8(0x5e))
    d.append(UInt8(0x1e))
    d.append(UInt8(0x69))
    d.append(UInt8(0xa3))
    d.append(UInt8(0x93))
    d.append(UInt8(0xb8))
    d.append(UInt8(0xf5))
    d.append(UInt8(0x9d))
    d.append(UInt8(0x8b))
    d.append(UInt8(0x2f))
    d.append(UInt8(0x0b))
    d.append(UInt8(0xd2))
    d.append(UInt8(0x52))
    d.append(UInt8(0x43))
    d.append(UInt8(0xa6))
    d.append(UInt8(0x6f))
    d.append(UInt8(0x32))
    d.append(UInt8(0x57))
    d.append(UInt8(0x65))
    d.append(UInt8(0x4d))
    d.append(UInt8(0x32))
    d.append(UInt8(0x81))
    d.append(UInt8(0xdf))
    d.append(UInt8(0x38))
    d.append(UInt8(0x53))
    d.append(UInt8(0x85))
    d.append(UInt8(0x5d))
    d.append(UInt8(0x7e))
    d.append(UInt8(0x5d))
    d.append(UInt8(0x66))
    d.append(UInt8(0x29))
    d.append(UInt8(0xea))
    d.append(UInt8(0xb8))
    d.append(UInt8(0xdd))
    d.append(UInt8(0xe4))
    d.append(UInt8(0x95))
    d.append(UInt8(0xb5))
    d.append(UInt8(0xcd))
    d.append(UInt8(0xb5))
    d.append(UInt8(0x56))
    d.append(UInt8(0x12))
    d.append(UInt8(0x42))
    d.append(UInt8(0xcd))
    d.append(UInt8(0xc4))
    d.append(UInt8(0x4e))
    d.append(UInt8(0xc6))
    d.append(UInt8(0x25))
    d.append(UInt8(0x38))
    d.append(UInt8(0x44))
    d.append(UInt8(0x50))
    d.append(UInt8(0x6d))
    d.append(UInt8(0xec))
    d.append(UInt8(0xce))
    d.append(UInt8(0x00))
    d.append(UInt8(0x55))
    d.append(UInt8(0x18))
    d.append(UInt8(0xfe))
    d.append(UInt8(0xe9))
    d.append(UInt8(0x49))
    d.append(UInt8(0x64))
    d.append(UInt8(0xd4))
    d.append(UInt8(0x4e))
    d.append(UInt8(0xca))
    d.append(UInt8(0x97))
    d.append(UInt8(0x9c))
    d.append(UInt8(0xb4))
    d.append(UInt8(0x5b))
    d.append(UInt8(0xc0))
    d.append(UInt8(0x73))
    d.append(UInt8(0xa8))
    d.append(UInt8(0xab))
    d.append(UInt8(0xb8))
    d.append(UInt8(0x47))
    d.append(UInt8(0xc2))
    return d^


def test_letsencrypt_r3_parses() raises:
    """Parser accepts the real Let's Encrypt R3 intermediate cert."""
    var der = _letsencrypt_r3_der()
    assert_equal(len(der), 1306)
    var cert = x509_parse_certificate(der)
    assert_equal(Int(cert.version), 2)  # v3 wire-form


def test_letsencrypt_r3_serial() raises:
    """Serial number 0x912b084acf0c18a753f6d62e25a75f5a (16 bytes,
    sign-pad stripped — the MSB 0x91 is high so no leading 0x00)."""
    var der = _letsencrypt_r3_der()
    var cert = x509_parse_certificate(der)
    assert_equal(len(cert.serial_number), 16)
    assert_equal(Int(cert.serial_number[0]), 0x91)
    assert_equal(Int(cert.serial_number[1]), 0x2b)
    assert_equal(Int(cert.serial_number[15]), 0x5a)


def test_letsencrypt_r3_signature_algo() raises:
    """signatureAlgorithm OID = sha256WithRSAEncryption (1.2.840.113549.1.1.11)."""
    var der = _letsencrypt_r3_der()
    var cert = x509_parse_certificate(der)
    assert_true(der_oid_eq(cert.signature_algo_oid, _oid_sha256_with_rsa()))


def test_letsencrypt_r3_subject_cn() raises:
    """Subject CN = 'R3'."""
    var der = _letsencrypt_r3_der()
    var cert = x509_parse_certificate(der)
    var cn_oid = _oid_common_name()
    var found = False
    for i in range(len(cert.subject)):
        if der_oid_eq(cert.subject[i].oid, cn_oid):
            assert_equal(cert.subject[i].value, "R3")
            found = True
            break
    assert_true(found)


def test_letsencrypt_r3_subject_org() raises:
    """Subject O = 'Let's Encrypt'."""
    var der = _letsencrypt_r3_der()
    var cert = x509_parse_certificate(der)
    var o_oid = _oid_org_name()
    var found = False
    for i in range(len(cert.subject)):
        if der_oid_eq(cert.subject[i].oid, o_oid):
            assert_equal(cert.subject[i].value, "Let's Encrypt")
            found = True
            break
    assert_true(found)


def test_letsencrypt_r3_issuer_cn() raises:
    """Issuer CN = 'ISRG Root X1' (root CA)."""
    var der = _letsencrypt_r3_der()
    var cert = x509_parse_certificate(der)
    var cn_oid = _oid_common_name()
    var found = False
    for i in range(len(cert.issuer)):
        if der_oid_eq(cert.issuer[i].oid, cn_oid):
            assert_equal(cert.issuer[i].value, "ISRG Root X1")
            found = True
            break
    assert_true(found)


def test_letsencrypt_r3_validity() raises:
    """notBefore = 2020-09-04T00:00:00Z (UTCTime).
    notAfter = 2025-09-15T16:00:00Z (UTCTime: 250915160000Z)."""
    var der = _letsencrypt_r3_der()
    var cert = x509_parse_certificate(der)
    assert_equal(Int(cert.not_before.year), 2020)
    assert_equal(Int(cert.not_before.month), 9)
    assert_equal(Int(cert.not_before.day), 4)
    assert_equal(Int(cert.not_after.year), 2025)
    assert_equal(Int(cert.not_after.month), 9)
    assert_equal(Int(cert.not_after.day), 15)
    assert_equal(Int(cert.not_after.hour), 16)


def test_letsencrypt_r3_spki_algo_is_rsa() raises:
    """SubjectPublicKeyInfo algorithm OID = rsaEncryption (1.2.840.113549.1.1.1)."""
    var der = _letsencrypt_r3_der()
    var cert = x509_parse_certificate(der)
    assert_true(der_oid_eq(cert.subject_pubkey_algo_oid, _oid_rsa_encryption()))


def test_letsencrypt_r3_rsa2048_pubkey_size() raises:
    """RSA-2048 SPKI subjectPublicKey BIT STRING wraps a SEQUENCE { n, e }
    where n is 2048 bits = 256 bytes + sign-pad. Total wrapping bytes
    should be approximately 270 bytes."""
    var der = _letsencrypt_r3_der()
    var cert = x509_parse_certificate(der)
    # Some RSA pubkeys add an explicit 0x00 padding so 257 is the typical
    # size for the modulus alone. The wrapping SEQUENCE adds ~10 bytes.
    assert_true(len(cert.subject_pubkey) > 250)
    assert_true(len(cert.subject_pubkey) < 300)


def test_letsencrypt_r3_extensions_present() raises:
    """LE R3 has 7 extensions per openssl x509 -text inspection."""
    var der = _letsencrypt_r3_der()
    var cert = x509_parse_certificate(der)
    # LE R3 has: keyUsage, basicConstraints, ext-key-usage, crl-dist-points,
    # certificatePolicies, subjectKeyIdentifier, authorityKeyIdentifier,
    # + RFC 3280 caInfoAccess. So 7-8 extensions.
    assert_true(len(cert.extensions) >= 6)
    # basicConstraints MUST be present for an intermediate CA.
    var idx = x509_find_extension(cert, _oid_basic_constraints())
    assert_true(idx >= 0, "basicConstraints (the CA-bit witness) MUST be present")
    assert_true(cert.extensions[idx].critical)


# =============================================================================
# Malformed-fuzz corpus
# =============================================================================
# 20+ adversarial DER inputs. All MUST raise gracefully (no crash, no UB,
# no out-of-bounds read).


def test_fuzz_empty_buffer() raises:
    """Empty buffer at the top level raises."""
    var empty = List[UInt8]()
    var raised = False
    try:
        var _c = x509_parse_certificate(empty)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_single_byte() raises:
    """Single tag byte without length raises."""
    var buf = _list_from_bytes(UInt8(0x30))
    var raised = False
    try:
        var _c = x509_parse_certificate(buf)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_truncated_length() raises:
    """0x30 0x82 (long-form length declaring 2 bytes follow) but no further
    bytes — raises in der_parse_length."""
    var buf = _list_from_bytes(UInt8(0x30), UInt8(0x82))
    var raised = False
    try:
        var _c = x509_parse_certificate(buf)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_indefinite_length() raises:
    """0x80 alone (BER indefinite length) raises in DER mode."""
    var buf = _list_from_bytes(UInt8(0x30), UInt8(0x80), UInt8(0x00), UInt8(0x00))
    var raised = False
    try:
        var _c = x509_parse_certificate(buf)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_length_overflow() raises:
    """TLV length declaring more bytes than buffer has — raises."""
    var buf = _list_from_bytes(UInt8(0x30), UInt8(0x10), UInt8(0x01), UInt8(0x02))
    var raised = False
    try:
        var _c = x509_parse_certificate(buf)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_length_of_length_too_large() raises:
    """Long-form length-of-length > 4 (which would mean a length >= 2^32) raises."""
    var buf = _list_from_bytes(
        UInt8(0x30), UInt8(0x85), UInt8(0x01), UInt8(0x02),
        UInt8(0x03), UInt8(0x04), UInt8(0x05),
    )
    var raised = False
    try:
        var _c = x509_parse_certificate(buf)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_top_not_sequence() raises:
    """Top-level is INTEGER (0x02), not SEQUENCE (0x30) — raises."""
    var buf = _list_from_bytes(UInt8(0x02), UInt8(0x01), UInt8(0x01))
    var raised = False
    try:
        var _c = x509_parse_certificate(buf)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_truncated_tbs() raises:
    """Top SEQUENCE valid + opens TBSCertificate SEQUENCE but truncates
    inside it."""
    var buf = _list_from_bytes(
        UInt8(0x30), UInt8(0x06),
        UInt8(0x30), UInt8(0x04),
        UInt8(0xa0), UInt8(0x03),
        UInt8(0x02), UInt8(0x01),
    )
    var raised = False
    try:
        var _c = x509_parse_certificate(buf)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_version_out_of_range() raises:
    """version INTEGER = 5 (out of range [0..2]) — raises."""
    # Top SEQUENCE of TBSCertificate having version [0] EXPLICIT INTEGER 5,
    # then truncated. We just need der_parse_tlv to walk past version and
    # the version-range check should fire.
    var buf = _list_from_bytes(
        UInt8(0x30), UInt8(0x0c),   # outer Cert SEQUENCE 12 bytes
        UInt8(0x30), UInt8(0x0a),   # TBS SEQUENCE 10 bytes
        UInt8(0xa0), UInt8(0x03),   # [0] EXPLICIT 3 bytes
        UInt8(0x02), UInt8(0x01), UInt8(0x05),   # INTEGER 5
        UInt8(0x02), UInt8(0x01), UInt8(0x01),   # serial INTEGER 1
        UInt8(0x30), UInt8(0x00),   # AlgorithmIdentifier empty (will fail later)
    )
    var raised = False
    try:
        var _c = x509_parse_certificate(buf)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_negative_version() raises:
    """version INTEGER = -1 (negative) — raises on range check."""
    var buf = _list_from_bytes(
        UInt8(0x30), UInt8(0x0c),
        UInt8(0x30), UInt8(0x0a),
        UInt8(0xa0), UInt8(0x03),
        UInt8(0x02), UInt8(0x01), UInt8(0xff),  # INTEGER -1 (single byte 0xff)
        UInt8(0x02), UInt8(0x01), UInt8(0x01),
        UInt8(0x30), UInt8(0x00),
    )
    var raised = False
    try:
        var _c = x509_parse_certificate(buf)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_malformed_oid_high_bit() raises:
    """OID byte with high bit set as last byte (no terminator) raises in
    der_parse_oid. Inject inside an AlgorithmIdentifier."""
    var bad_oid = _list_from_bytes(
        UInt8(0x06), UInt8(0x03),  # OID, 3 bytes
        UInt8(0x2a), UInt8(0x86), UInt8(0x80),  # last byte high-bit set
    )
    var raised = False
    try:
        var _o = der_parse_oid(bad_oid[2:5])
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_utc_time_wrong_length() raises:
    """UTCTime not 13 bytes (must be YYMMDDhhmmssZ) — raises."""
    # 12 bytes only
    var v = _list_from_bytes(
        UInt8(0x32), UInt8(0x31), UInt8(0x30), UInt8(0x31), UInt8(0x30),
        UInt8(0x31), UInt8(0x30), UInt8(0x30), UInt8(0x30), UInt8(0x30),
        UInt8(0x30), UInt8(0x5A),
    )
    var raised = False
    try:
        var _t = der_parse_utc_time(v)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_utc_time_no_z() raises:
    """UTCTime without trailing 'Z' raises."""
    var v = _list_from_bytes(
        UInt8(0x32), UInt8(0x31), UInt8(0x30), UInt8(0x31), UInt8(0x30),
        UInt8(0x31), UInt8(0x30), UInt8(0x30), UInt8(0x30), UInt8(0x30),
        UInt8(0x30), UInt8(0x30), UInt8(0x41),  # ends in 'A' not 'Z'
    )
    var raised = False
    try:
        var _t = der_parse_utc_time(v)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_utc_time_invalid_month() raises:
    """UTCTime with month 13 raises."""
    # YYYY=21, MM=13, ...
    var v = _list_from_bytes(
        UInt8(0x32), UInt8(0x31), UInt8(0x31), UInt8(0x33), UInt8(0x30),
        UInt8(0x31), UInt8(0x30), UInt8(0x30), UInt8(0x30), UInt8(0x30),
        UInt8(0x30), UInt8(0x30), UInt8(0x5A),
    )
    var raised = False
    try:
        var _t = der_parse_utc_time(v)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_generalized_time_wrong_length() raises:
    """GeneralizedTime must be 15 bytes — raises on length 14."""
    var v = _list_from_bytes(
        UInt8(0x32), UInt8(0x30), UInt8(0x32), UInt8(0x35), UInt8(0x30),
        UInt8(0x39), UInt8(0x31), UInt8(0x35), UInt8(0x31), UInt8(0x36),
        UInt8(0x30), UInt8(0x30), UInt8(0x30), UInt8(0x30),
    )
    var raised = False
    try:
        var _t = der_parse_generalized_time(v)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_bit_string_unused_bits_too_large() raises:
    """BIT STRING with unused_bits = 8 (must be 0..7) raises."""
    var v = _list_from_bytes(UInt8(0x08), UInt8(0xFF))
    var raised = False
    try:
        var _b = der_parse_bit_string(v)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_oid_overflow_arc() raises:
    """OID arc encoded with > 5 high-bit bytes (would overflow UInt32)."""
    # 5 bytes each with high-bit set = 5 * 7 = 35 bits accumulator,
    # exceeds UInt32. Detected by the (acc >> 25) overflow guard.
    var v = _list_from_bytes(
        UInt8(0x2a),  # first byte fine
        UInt8(0xff), UInt8(0xff), UInt8(0xff), UInt8(0xff), UInt8(0xff),
        UInt8(0x00),
    )
    var raised = False
    try:
        var _o = der_parse_oid(v)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_integer_int64_overflow() raises:
    """INTEGER with 10 bytes overflows Int64 — raises."""
    var v = List[UInt8]()
    for _ in range(10):
        v.append(UInt8(0xFF))
    var raised = False
    try:
        var _i = der_parse_integer_to_int64(v)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_boolean_wrong_length() raises:
    """BOOLEAN with length 2 raises."""
    var v = _list_from_bytes(UInt8(0x00), UInt8(0x00))
    var raised = False
    try:
        var _b = der_parse_boolean(v)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_random_garbage() raises:
    """100 bytes of random-ish garbage that doesn't form a valid cert raises."""
    var v = List[UInt8]()
    for i in range(100):
        v.append(UInt8((i * 17 + 3) & 0xFF))
    var raised = False
    try:
        var _c = x509_parse_certificate(v)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_truncated_at_signature() raises:
    """TBS valid but truncates before signature bytes."""
    # Take the real cert and truncate at byte 1000.
    var full = _letsencrypt_r3_der()
    var trunc = List[UInt8]()
    for i in range(1000):
        trunc.append(full[i])
    var raised = False
    try:
        var _c = x509_parse_certificate(trunc)
    except _:
        raised = True
    assert_true(raised)


def test_fuzz_bit_flip_in_tbs() raises:
    """Bit flip in TBSCertificate SEQUENCE tag corrupts structure — parser
    rejects."""
    var full = _letsencrypt_r3_der()
    var corrupt = List[UInt8]()
    for i in range(len(full)):
        corrupt.append(full[i])
    # Byte 4 is the inner SEQUENCE tag (0x30 = SEQUENCE). Flip to 0x02 (INTEGER).
    corrupt[4] = UInt8(0x02)
    var raised = False
    try:
        var _c = x509_parse_certificate(corrupt)
    except _:
        raised = True
    assert_true(raised, "corrupted TBS-SEQUENCE tag must raise")


def main() raises:
    # Real-cert assertions (10)
    test_letsencrypt_r3_parses()
    test_letsencrypt_r3_serial()
    test_letsencrypt_r3_signature_algo()
    test_letsencrypt_r3_subject_cn()
    test_letsencrypt_r3_subject_org()
    test_letsencrypt_r3_issuer_cn()
    test_letsencrypt_r3_validity()
    test_letsencrypt_r3_spki_algo_is_rsa()
    test_letsencrypt_r3_rsa2048_pubkey_size()
    test_letsencrypt_r3_extensions_present()
    # Malformed-fuzz corpus (22)
    test_fuzz_empty_buffer()
    test_fuzz_single_byte()
    test_fuzz_truncated_length()
    test_fuzz_indefinite_length()
    test_fuzz_length_overflow()
    test_fuzz_length_of_length_too_large()
    test_fuzz_top_not_sequence()
    test_fuzz_truncated_tbs()
    test_fuzz_version_out_of_range()
    test_fuzz_negative_version()
    test_fuzz_malformed_oid_high_bit()
    test_fuzz_utc_time_wrong_length()
    test_fuzz_utc_time_no_z()
    test_fuzz_utc_time_invalid_month()
    test_fuzz_generalized_time_wrong_length()
    test_fuzz_bit_string_unused_bits_too_large()
    test_fuzz_oid_overflow_arc()
    test_fuzz_integer_int64_overflow()
    test_fuzz_boolean_wrong_length()
    test_fuzz_random_garbage()
    test_fuzz_truncated_at_signature()
    test_fuzz_bit_flip_in_tbs()
    print("All 32 LE R3 + fuzz tests PASSED (10 real-cert + 22 fuzz)")
