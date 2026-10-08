# =============================================================================
# komira_vcard_conformance -- komira_vcard (and the komira_content_line layer
# under it) against the RFC 6350, RFC 2426 and RFC 9555 examples and
# vendor-shaped exports. Test-only: nothing ships from here.
# =============================================================================
#
# vectors.mojo holds the inputs and says where each comes from; the tests
# under tests/ hold the expected mappings and the round trips.
# =============================================================================

from .vectors import (
    apple_shaped_3_0,
    google_shaped_3_0,
    outlook_shaped_2_1,
    rfc2426_7_example,
    rfc6350_6_1_4_kind,
    rfc6350_6_2_5_bday_text,
    rfc6350_6_6_5_member,
    rfc6350_6_property_examples,
    rfc6350_8_author,
    rfc9555_figures,
)
