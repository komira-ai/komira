# =============================================================================
# komira_placement/heartbeat_credential.mojo — the per-job heartbeat
#   credential, IN CLEARTEXT, as a type the compiler will not print.
# =============================================================================
#
# The job manager mints the credential, writes only its sha256 to the job row,
# and hands the cleartext to the conformer on `PlacementSpec.heartbeat_credential`
# so `create` can stamp it into the VM's GCE metadata item
# `komira-heartbeat-token`. That metadata item is the ONLY place it may land.
#
# ⛔⛔ WHY A TYPE AND NOT A `String`. As a plain `String` field the no-log /
# no-error / no-argv contract would be held by COMMENTS:
# `print(spec.heartbeat_credential)`, `String(e) + spec.heartbeat_credential`
# and an f-string in a raise all compile. This struct is deliberately NOT
# `Writable` — in Mojo 1.0 the ONE formatting trait (`Stringable` and
# `Representable` no longer exist; `String(x)`, `print(x)` and interpolation all
# route through `Writable`) — so every one of those is a COMPILE ERROR, and the
# one way out is the explicitly named `cleartext_for_metadata_stamp()` — a call
# a reviewer can grep for.
#
# ⚠ NOT `Equatable` EITHER, deliberately: comparing a presented credential is
# done on the HASH, in constant time, by the heartbeat door — never by `==` on
# cleartext.
#
# ⚠ `Copyable` because `PlacementSpec` is (the placement pipeline copies specs
# freely). The copy rule is the field comment's: no copy may outlive the
# placement call.
#
# gap6-clean: one owned `String`, no pointer, no wildcard origin, not stored in
# any byte slab.
# =============================================================================


struct HeartbeatCredential(Copyable, Movable):
    """The per-job heartbeat credential's cleartext. EMPTY => no credential.

    Deliberately NOT `Writable` (Mojo 1.0's one formatting trait) and NOT
    `Equatable`: it cannot be printed, formatted into an error, or compared on
    cleartext.
    Read it only through `cleartext_for_metadata_stamp()`."""

    var _cleartext: String

    def __init__(out self):
        """EMPTY — no credential. The default every `PlacementSpec` carries."""
        self._cleartext = String("")

    def __init__(out self, *, minted: String):
        """A credential the job manager has just minted. Keyword-only so a
        call site says `minted=` — a positional `HeartbeatCredential(s)` would
        read like a conversion of any string."""
        self._cleartext = minted

    def is_empty(self) -> Bool:
        """True iff no credential is carried. Safe to log — it says whether a
        credential exists, never what it is."""
        return self._cleartext.byte_length() == 0

    def cleartext_for_metadata_stamp(self) -> String:
        """THE ONE READ. Its only legitimate caller is a conformer's `create`
        stamping GCE metadata item `komira-heartbeat-token`. The
        name is the grep target a review looks for; any other caller is the
        defect this type exists to make visible."""
        return self._cleartext
