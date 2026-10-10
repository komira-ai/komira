# =============================================================================
# kci_cloud/outcome.mojo: what an apply did (`ApplyOutcome`).
# =============================================================================
#
# deploy.apply_resources returns one whether or not the apply finished. A
# driver reads its outcome from the typed fields, never from `error`'s text:
#   * `refusal` set: the engine refused the run before any change (REFUSED);
#   * `failed_release` set: the engine's apply finished, then a release of an
#     adopted object failed (PARTIAL: `landed` holds every node);
#   * any other `error`: the engine stopped, with `landed` and `pending` as
#     far as it got, possibly empty (PARTIAL: the failing node's own call may
#     have landed);
#   * no `error`: every node converged, and every release was made.
# A refusal kci_cloud makes itself is raised before any effect, never
# returned here (deploy.mojo, THE TYPED REFUSAL).
#
# Value-typed: String / List / Optional only. No pointer.
# =============================================================================

from kci_reconciler import AppliedNode

from kci_cloud.refusal import Refusal


struct ApplyOutcome(Movable, Deinitable):
    """What an apply did, whether or not it finished.

      * `error`    — None when every node converged; else the engine's error
                     (it names the node, the verb and the fault domain), or
                     the failed release. Text for a person; `refusal` and
                     `failed_release` say which it is.
      * `applied`  — every node, in apply order, when `error` is None; empty
                     otherwise (use `landed`).
      * `landed`   — the nodes this apply acted on before it stopped, in
                     apply order, each with the verb it issued. On success it
                     equals `applied`. These mutations are LIVE in the cell.
      * `pending`  — the nodes it never reached, in the order they would have
                     run; the failing node is the first. Empty on success.
      * `leftover` — nodes of resources the file no longer names that the
                     cloud says this cell owns; reported, never deleted here.
      * `left_behind` — RETAINED objects (`kci-retention=retain`) of resources
                     still in the file that the file no longer lowers;
                     reported, never deleted.
      * `released` — objects kci adopted whose resource left the list, that
                     this apply released (their kci labels and state record
                     dropped, the object left standing), in order. A release
                     runs only after the engine's apply succeeded. When one
                     fails, `error` says which (`release of <node> failed:
                     ...`), `released` lists those released before it,
                     `landed` holds every node the engine applied, `pending`
                     is empty (the engine finished) and `applied` is empty;
                     the next apply releases the rest. `failed_release`
                     names that node, so the failure is told from an engine
                     error without reading `error`.
      * `refusal`  — the engine's ownership refusal (refusal.mojo), when
                     that is why it stopped: before any change, so
                     `landed` is empty. None for any other error.

    A caller that only got a bool (or only the error) could not tell "nothing
    happened" from "half the graph is live": that is the PARTIAL outcome a
    driver must not retry blindly, and these lists are how it is reported.
    """

    var applied: List[AppliedNode]
    var landed: List[AppliedNode]
    var pending: List[String]
    var error: Optional[String]
    var leftover: List[String]
    var left_behind: List[String]
    var released: List[String]
    var refusal: Optional[Refusal]
    var failed_release: String

    def __init__(
        out self,
        var applied: List[AppliedNode],
        var landed: List[AppliedNode],
        var pending: List[String],
        var error: Optional[String],
        var leftover: List[String] = List[String](),
        var left_behind: List[String] = List[String](),
        var released: List[String] = List[String](),
        var refusal: Optional[Refusal] = None,
        var failed_release: String = String(""),
    ):
        self.applied = applied^
        self.landed = landed^
        self.pending = pending^
        self.error = error^
        self.leftover = leftover^
        self.left_behind = left_behind^
        self.released = released^
        self.refusal = refusal^
        self.failed_release = failed_release^

    def ok(self) -> Bool:
        return not self.error

    def partial(self) -> Bool:
        """True iff the apply failed AFTER at least one node landed."""
        return Bool(self.error) and len(self.landed) > 0

    def refused(self) -> Bool:
        """True iff the engine refused the run before any change (a node it
        may not act on: foreign, conflict, or one that cannot stamp): the
        typed `refusal` is set."""
        return Bool(self.refusal)

    def release_failed(self) -> Bool:
        """True iff the engine's apply finished and a release then failed
        (`failed_release` names its node)."""
        return self.failed_release.byte_length() > 0
