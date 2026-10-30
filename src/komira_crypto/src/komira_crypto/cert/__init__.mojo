# =============================================================================
# komira_crypto/cert — X.509 + ASN.1 DER decoder (RFC 5280)
# =============================================================================
#
# ASN.1 DER decoder + X.509 Certificate / TBSCertificate parser per
# RFC 5280 §4 / X.690 BER-DER, the RFC 6125 hostname matcher, RFC 5280 §6
# chain validation, and the Mozilla CA root store.
#
# Layered shape:
#   - asn1.mojo           Pure ASN.1 DER decoder (TLV + primitives + constructed)
#   - x509.mojo           X.509 Certificate parser consuming asn1.mojo
#   - name_matcher.mojo   RFC 6125 hostname matcher
#   - chain.mojo          RFC 5280 §6 chain validation
#   - root_store.mojo     Mozilla CA root store (data in root_store_data.mojo)
#
# Encapsulation invariants:
#   * ZERO UnsafePointer in any public function signature.
#   * ZERO wildcard origins — `Span[UInt8, _]` is origin-inferred per call
#     site, NOT wildcard widening.
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * ZERO new ArcPointer (all POD structs).
# =============================================================================

from .asn1 import (
    # Tag classes
    ASN1_CLASS_UNIVERSAL,
    ASN1_CLASS_APPLICATION,
    ASN1_CLASS_CONTEXT,
    ASN1_CLASS_PRIVATE,
    # Universal tag numbers (X.509-relevant subset)
    ASN1_TAG_BOOLEAN,
    ASN1_TAG_INTEGER,
    ASN1_TAG_BIT_STRING,
    ASN1_TAG_OCTET_STRING,
    ASN1_TAG_NULL,
    ASN1_TAG_OID,
    ASN1_TAG_UTF8_STRING,
    ASN1_TAG_SEQUENCE,
    ASN1_TAG_SET,
    ASN1_TAG_PRINTABLE_STRING,
    ASN1_TAG_IA5_STRING,
    ASN1_TAG_UTC_TIME,
    ASN1_TAG_GENERALIZED_TIME,
    # Core types
    DerTag,
    DerTlv,
    DerTime,
    # TLV / primitive parsers
    der_parse_tag,
    der_parse_length,
    der_parse_tlv,
    der_parse_boolean,
    der_parse_null,
    der_parse_integer_to_int64,
    der_parse_integer_to_bytes,
    der_parse_octet_string,
    der_parse_bit_string,
    der_parse_utf8_string,
    der_parse_printable_string,
    der_parse_ia5_string,
    der_parse_oid,
    der_parse_utc_time,
    der_parse_generalized_time,
    # OID encode (for comparison)
    der_oid_eq,
    # Constructed iteration helpers
    der_iter_count,
    der_expect_tag,
)

from .x509 import (
    Extension,
    DnAttribute,
    X509Certificate,
    x509_parse_certificate,
    x509_find_extension,
)

# RFC 6125 hostname matcher
from .name_matcher import match_hostname

# RFC 5280 §6 chain validation
from .chain import chain_verify

# Mozilla CA root store
from .root_store import mozilla_root_store, root_store_verify
