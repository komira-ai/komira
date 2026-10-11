# =============================================================================
# komira_test_pdp/tokens.mojo: how the test decision point reads a token.
# =============================================================================
#
# The decision point verifies two tokens per request: the bearer (the asking
# service's client token, `Authorization: Bearer ...`) and the subject token
# (`subject.properties.token` in the body). Both go through one
# `TokenVerifier`, which turns a token into a `VerifiedToken` or refuses it.
#
# `TokenTable` is the verifier this package ships: a list of the tokens an
# issuer has handed out, each with the claims the decision point reads. A
# token not in the table is refused, and so is a token at or after its `exp`
# (no leeway: the table and the decision point share one clock, the
# decision point's `now_s`). A verifier that checks signed JWTs against an
# issuer's key set conforms to the same trait and replaces the table without
# any other change.
#
# The claims kept are exactly the ones the decision point compares:
#   subject_type  "jwt_sub" for a user's token, "client" for a service's
#                 client token (the profile's `subject.type` values)
#   sub           the verified subject (never empty)
#   aud           the one audience the token was issued for
#   client_id     the client the token was issued to ("" when it has none)
#   exp_s         expiry, seconds on the decision point's clock
# =============================================================================

comptime SUBJECT_TYPE_USER: String = "jwt_sub"
comptime SUBJECT_TYPE_CLIENT: String = "client"


@fieldwise_init
struct VerifiedToken(Copyable, Movable):
    """The claims of a token a `TokenVerifier` accepted."""

    var subject_type: String
    var sub: String
    var aud: String
    var client_id: String
    var exp_s: Int64


trait TokenVerifier(Movable, Deinitable):
    """Turns a token into its verified claims, or refuses it (None). Must not
    raise. `now_s` is the decision point's clock; a token is refused at or
    after its `exp_s`."""

    def verify(self, token: String, now_s: Int64) -> Optional[VerifiedToken]:
        ...


@fieldwise_init
struct _TableRow(Copyable, Movable):
    var token: String
    var claims: VerifiedToken


struct TokenTable(TokenVerifier, Movable, Deinitable):
    """The tokens an issuer handed out, with their claims (module header)."""

    var _rows: List[_TableRow]

    def __init__(out self):
        self._rows = List[_TableRow]()

    def add(mut self, token: String, var claims: VerifiedToken) raises:
        """Records a token. Raises on an empty token, an empty `sub`, a
        `subject_type` other than the two profile values, or a token already
        in the table (one token, one set of claims)."""
        if token.byte_length() == 0:
            raise Error("TokenTable: empty token")
        if claims.sub.byte_length() == 0:
            raise Error("TokenTable: empty sub")
        if (
            claims.subject_type != SUBJECT_TYPE_USER
            and claims.subject_type != SUBJECT_TYPE_CLIENT
        ):
            raise Error("TokenTable: unknown subject_type")
        for i in range(len(self._rows)):
            if self._rows[i].token == token:
                raise Error("TokenTable: token added twice")
        self._rows.append(_TableRow(token, claims^))

    def remove(mut self, token: String) -> Bool:
        """Forgets a token (the issuer revoked it). True when it was there."""
        for i in range(len(self._rows)):
            if self._rows[i].token == token:
                _ = self._rows.pop(i)
                return True
        return False

    def verify(self, token: String, now_s: Int64) -> Optional[VerifiedToken]:
        for i in range(len(self._rows)):
            if self._rows[i].token == token:
                if now_s >= self._rows[i].claims.exp_s:
                    return None
                return self._rows[i].claims.copy()
        return None
