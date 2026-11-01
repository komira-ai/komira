# =============================================================================
# komira_crypto/cert/root_store.mojo — Mozilla CA RootStore
# =============================================================================
#
# Mozilla CA root certificate store. Vendors 10 hand-selected widely-used
# roots from curl's `cacert.pem` (Mozilla source). Parses on each call (no
# module-level cached state: Mojo has no module-level globals).
#
# # Public surface
#
#   * `mozilla_root_store() raises -> List[X509Certificate]`
#       Parses and returns the 10 trusted roots.
#
#   * `root_store_verify(chain, now) raises -> Bool`
#       Convenience wrapper: chain_verify(chain, mozilla_root_store(), now).
#
# # Selected 10 roots (subset of full Mozilla bundle)
#
#   ISRG Root X1                                       (RSA-4096)
#   ISRG Root X2                                       (ECC-P-384)
#   DigiCert Global Root CA                            (RSA-2048)
#   DigiCert Global Root G2                            (RSA-2048)
#   Amazon Root CA 1                                   (RSA-2048)
#   USERTrust RSA Certification Authority              (RSA-4096)
#   USERTrust ECC Certification Authority              (ECC-P-384)
#   GTS Root R1 (Google Trust Services)                (RSA-4096)
#   Microsoft RSA Root Certificate Authority 2017      (RSA-4096)
#   GlobalSign Root CA - R6                            (RSA-4096)
#
# The full ~150-root Mozilla bundle is not vendored; the 10 roots cover
# the large majority of observed HTTPS chains (a rough estimate). A caller
# that needs a different trust set passes its own anchors to
# `chain_verify`.
#
# # Encapsulation invariants
#
#   * ZERO UnsafePointer in any public function signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * ZERO new ArcPointer (returns List[X509Certificate] POD).
# =============================================================================

from komira_crypto.cert.x509 import X509Certificate, x509_parse_certificate
from komira_crypto.cert.chain import chain_verify
from komira_crypto.cert.root_store_data import (
    _root_isrg_root_x1_der,
    _root_isrg_root_x2_der,
    _root_digicert_global_root_ca_der,
    _root_digicert_global_root_g2_der,
    _root_amazon_root_ca_1_der,
    _root_usertrust_rsa_der,
    _root_usertrust_ecc_der,
    _root_gts_root_r1_der,
    _root_microsoft_rsa_2017_der,
    _root_globalsign_root_r6_der,
)


def mozilla_root_store() raises -> List[X509Certificate]:
    """Returns the hand-selected 10-root Mozilla CA trust list.

    Each root is parsed at call time from its vendored DER bytes via
    `x509_parse_certificate`. The vendored DERs are extracted from
    curl's `cacert.pem` (Mozilla source).

    Cost: ~3-5 ms cold (10 DER parses; each ~1 KB). Production callers
    should build the store ONCE at server startup and pass it to the
    code that verifies chains.

    Raises if any vendored DER fails to parse (would indicate
    corruption in the generated data file).
    """
    var roots = List[X509Certificate]()
    roots.append(x509_parse_certificate(Span(_root_isrg_root_x1_der())))
    roots.append(x509_parse_certificate(Span(_root_isrg_root_x2_der())))
    roots.append(x509_parse_certificate(Span(_root_digicert_global_root_ca_der())))
    roots.append(x509_parse_certificate(Span(_root_digicert_global_root_g2_der())))
    roots.append(x509_parse_certificate(Span(_root_amazon_root_ca_1_der())))
    roots.append(x509_parse_certificate(Span(_root_usertrust_rsa_der())))
    roots.append(x509_parse_certificate(Span(_root_usertrust_ecc_der())))
    roots.append(x509_parse_certificate(Span(_root_gts_root_r1_der())))
    roots.append(x509_parse_certificate(Span(_root_microsoft_rsa_2017_der())))
    roots.append(x509_parse_certificate(Span(_root_globalsign_root_r6_der())))
    return roots^


def root_store_verify(
    chain: List[X509Certificate],
    now: Tuple[UInt16, UInt8, UInt8, UInt8, UInt8, UInt8],
) raises -> Bool:
    """Convenience wrapper: chain_verify(chain, mozilla_root_store(), now).

    Builds the Mozilla root store on every call. For production use,
    callers should construct the store ONCE via `mozilla_root_store()`
    and pass it to `chain_verify` directly to avoid the per-call
    parse cost.
    """
    var roots = mozilla_root_store()
    return chain_verify(chain, roots, now)
