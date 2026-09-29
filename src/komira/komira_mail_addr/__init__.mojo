# =============================================================================
# komira_mail_addr — the MAIL ADDRESSING GRAMMAR, as a leaf package.
# =============================================================================
#
# ★ WHY THIS PACKAGE EXISTS: THE ADDRESS GRAMMAR IS NEEDED BY CODE THAT CANNOT
# AFFORD THE PACKAGES AROUND IT.
#
# `parse_addr_spec_strict` / `decode_envelope_recipients` are needed by the
# inbound-mail ingest (a mailbox writer with an object store and an HTTP serving
# surface), and `normalize_mail_domain` by the control plane's API server. Both
# modules import nothing beyond `std`, and both are also needed by a mail
# router that runs as an AWS Lambda, where binary size IS cold-start latency.
#
# So a router has three options and two of them are bad:
#
#   1. depend on the ingest and the API server — put an HTTP server and an API
#      server into a mail router's Lambda image.
#   2. RE-SPELL the grammar inside the router. ⛔ This is the one that looks
#      cheapest and is the most dangerous: a second Mojo implementation of the
#      address grammar THE INGEST ALSO PARSES is a mis-delivery primitive the
#      day the two disagree. The router decides which tenant owns an address;
#      the ingest decides which mailbox to write. Two graders, one exam.
#   3. keep the leaves in their own package. This one.
#
# ── DEPENDENCY DIRECTION ─────────────────────────────────────────────────────
#
#   komira_mail_addr  ->  (nothing but std)
#   the ingest        ->  komira_mail_addr
#   the API server    ->  komira_mail_addr
#   the mail router   ->  komira_mail_addr        (the point)
#
# A leaf both sides depend on is the cycle-free shape; nothing here may ever
# import back up into a serving or API package.
#
# ⛔ DO NOT ADD A DEPENDENCY TO THIS PACKAGE. Its entire value is that its
# closure is empty, which is what makes it payable in a cold-start budget. The
# first `deps` entry here silently re-creates the problem it exists to solve.

from komira_mail_addr.envelope_transport import (
    decode_envelope_recipients,
    parse_addr_spec_strict,
)
from komira_mail_addr.mail_domain_key import (
    MAIL_DOMAIN_MAX_LABEL_LEN,
    MAIL_DOMAIN_MAX_LEN,
    normalize_mail_domain,
)
