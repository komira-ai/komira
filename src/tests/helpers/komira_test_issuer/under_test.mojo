# =============================================================================
# komira_test_issuer/under_test.mojo: what the scenario table needs from an
#   issuer, and what the issuer is expected to issue.
# =============================================================================
#
# `IssuerUnderTest` is the issuer a scenario drives: its JWK Set document,
# a user-token mint, its clock, and the two steps of a key rotation. A test
# issuer conforms directly; an adapter for another issuer maps each method to
# that issuer's own endpoint or admin step (`advance` on a live issuer
# waits, or moves a clock the issuer reads).
#
# `IssuerProfile` is what a relying party configures for the issuer (one
# issuer, one audience, one `alg`, one `typ`, the max lifetime and the
# leeway, as a trust anchor of the HTTP auth design) plus what a scenario
# asks it to mint for (`client_id`) and how long it waits after a rotation
# starts (`publish_lead_s`).
#
# ENCAPSULATION: values in and out. No pointer crosses this file's API.
# =============================================================================


trait IssuerUnderTest(Movable, Deinitable):
    """An issuer the scenario table can drive (see the file header)."""

    def now(self) -> Int64:
        """The issuer's clock, in seconds since the epoch."""
        ...

    def advance(mut self, seconds: Int64) raises:
        """Move the issuer's clock `seconds` forward."""
        ...

    def jwks_document(mut self) raises -> String:
        """The JWK Set document the issuer serves now."""
        ...

    def mint_user_token(
        mut self,
        subject: String,
        audience: String,
        client_id: String,
        scope: String,
    ) raises -> String:
        """A user access token for `subject`, signed now. Raises for an
        empty subject."""
        ...

    def begin_rotation(mut self) raises:
        """Start a key rotation: publish the next key."""
        ...

    def finish_rotation(mut self) raises:
        """Finish it: sign with the next key from now on."""
        ...


@fieldwise_init
struct IssuerProfile(Copyable, Movable):
    """What a relying party expects of the issuer under test (see the file
    header)."""

    var issuer: String
    var audience: String
    var client_id: String
    var alg: String
    var typ: String
    var max_ttl_s: Int64
    var leeway_s: Int64
    var publish_lead_s: Int64
