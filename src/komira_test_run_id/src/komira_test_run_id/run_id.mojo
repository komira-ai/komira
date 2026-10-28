# =============================================================================
# komira_test_run_id/run_id.mojo -- the run id: minted at run time, inside the
# test process, from the clock and 64 random bits, and from nothing else.
# =============================================================================
#
# Format: `<epoch seconds>-<16 lowercase hex>`, for example
# `1790000000-0123456789abcdef` (27 bytes). It is a legal validation-run id
# (komira_validation_run: lowercase, digits, `-`, at most 63 bytes), so the
# same value can label a cloud resource.
#
# ⛔ NEVER DERIVED FROM INPUTS. A remote executor can run one action twice
# (a retry, or two concurrent executions of the same digest), and both need
# disjoint resources. An id computed from the action's inputs would give both
# the same prefix, and one run's cleanup would delete the other's objects.
# The random half is what keeps a retry and its twin apart; the epoch half
# only makes ids sort by creation and lets a reader see an id's age.
# =============================================================================

from komira_validation_run.validation_run_tag import is_valid_validation_run_id

from .seams import Entropy, WallClock


struct RunId(Copyable, Movable, Writable):
    """A minted run id and the wall-clock second it was minted at."""

    var value: String
    var created_unix: Int

    def __init__(out self, var value: String, created_unix: Int):
        self.value = value^
        self.created_unix = created_unix

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.value)


def hex16_lower(v: UInt64) -> String:
    """`v` as exactly 16 lowercase hex digits, zero-padded: the random half
    of a run id. Exported so every id-shaped name (a run id, an embedded
    server's credential) uses one format."""
    comptime digits = "0123456789abcdef"
    var out = String("")
    for i in range(16):
        var shift = UInt64((15 - i) * 4)
        var nib = Int((v >> shift) & UInt64(0xF))
        out += String(digits[byte=nib : nib + 1])
    return out^


def mint_run_id[C: WallClock, E: Entropy](mut clock: C, mut entropy: E) raises -> RunId:
    """A fresh run id. Two calls never share one unless the clock and the
    entropy both repeat; nothing about the caller feeds it."""
    var now = clock.now_unix()
    if now <= 0:
        raise Error("mint_run_id: the wall clock read " + String(now) + "; refusing to mint")
    var value = String(now) + "-" + hex16_lower(entropy.next_u64())
    if not is_valid_validation_run_id(value):  # cov: unreachable a positive Int, "-" and 16 lowercase hex digits are at most 36 legal bytes
        raise Error("mint_run_id: minted an id that is not a valid validation-run id")  # cov: unreachable see the line above
    return RunId(value^, now)
