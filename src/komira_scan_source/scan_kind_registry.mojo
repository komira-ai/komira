# =============================================================================
# ScanKindRegistry — the PLAN/COMPILE-TIME registry. Lives in `komira_scan_source`.
# =============================================================================
#
# WHY CORE CAN OWN THIS AND CANNOT OWN THE OTHER ONE. A `ScanKindDescriptor` is
# PURE DATA — schema, stats and gate are values, and nothing here names
# `ParquetSource` or a `Searcher`. That is precisely why it can live in core
# without inverting the DAG, and it is the same reason `FsDescriptorPod` lives
# in core while the file systems it names (`S3Fs`, `AzureFs`, ...) cannot.
#
# The execution side cannot live here: a morsel-source trait would have to
# name `LocalDispatcher`, `CancellationToken`, `ParquetMetadataCache` — all
# defined ABOVE the core packages, so a core-resident trait CANNOT spell those
# types (see `komira_plan_expr/fs_resolver.mojo`).
#
# `MorselSourceImpl` lives in `komira_morsel`, which depends on
# the core packages, so the EXECUTION resolver splits into two tiers (see
# `scan_resolver.mojo`). This registry is the tier that has no such problem.
#
# WHAT THE OPTIMIZER GETS FROM A KIND IT HAS NEVER HEARD OF: a pushdown gate,
# an orientation, a snapshot policy, and the list of params that must be
# present. That is enough to plan a scan without knowing what a scan IS.
# =============================================================================

from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import (
    ScanBinding,
    SCAN_ORIENTATION_COLUMNAR,
    SNAPSHOT_NONE,
    scan_kind_id,
)
from komira_scan_source.scan_params import ScanParams


struct ScanKindDescriptor(Copyable, Movable, Deinitable):
    """Everything the OPTIMIZER needs to reason about a source kind.

    Names NO source type. A package above the engine constructs one of these
    for its own kind and registers it; core never learns what the kind is.
    """

    var kind_id: UInt32
    var kind_name: String
    var gate: PushdownGate
    var orientation: UInt8
    var snapshot_policy: UInt8
    var required_params: List[String]
    """Validated at bind time — this is what turns a stringly-typed params
    typo from a silent runtime miss into a plan-build error naming the key."""

    def __init__(
        out self,
        var kind_name: String,
        var gate: PushdownGate,
        orientation: UInt8 = SCAN_ORIENTATION_COLUMNAR,
        snapshot_policy: UInt8 = SNAPSHOT_NONE,
        var required_params: List[String] = List[String](),
    ):
        """`kind_id` is DERIVED from `kind_name`, never passed. There is no way
        to register a descriptor whose id disagrees with its name."""
        self.kind_id = scan_kind_id(kind_name)
        self.kind_name = kind_name^
        self.gate = gate^
        self.orientation = orientation
        self.snapshot_policy = snapshot_policy
        self.required_params = required_params^

    def copy(self) -> Self:
        var out = Self(
            kind_name=String(self.kind_name),
            gate=self.gate.copy(),
            orientation=self.orientation,
            snapshot_policy=self.snapshot_policy,
            required_params=self.required_params.copy(),
        )
        return out^

    def missing_params(self, params: ScanParams) -> List[String]:
        """Required keys absent from `params`, in declared order. Empty means
        the binding satisfies this descriptor."""
        var missing = List[String]()
        for i in range(len(self.required_params)):
            if not params.has(self.required_params[i]):
                missing.append(String(self.required_params[i]))
        return missing^


struct ScanKindRegistry(Movable, Deinitable):
    """Plan-time descriptor table, keyed by `kind_id`.

    Two parallel Lists rather than a Dict: the table holds one entry per source
    KIND (single digits, ever), lookups happen at plan build (not per morsel),
    and a linear scan over a handful of UInt32s beats a hash lookup at this size.
    """

    var _ids: List[UInt32]
    var _descs: List[ScanKindDescriptor]

    def __init__(out self):
        self._ids = List[UInt32]()
        self._descs = List[ScanKindDescriptor]()

    def __len__(self) -> Int:
        return len(self._ids)

    def num_kinds(self) -> Int:
        """Non-dunder length. `__len__` on a `def` is raising, so it does not
        bind `Sized` and `len(registry)` will not compile at a call site."""
        return len(self._ids)

    def _index_of(self, kind_id: UInt32) -> Int:
        for i in range(len(self._ids)):
            if self._ids[i] == kind_id:
                return i
        return -1

    def register(mut self, var d: ScanKindDescriptor) raises:
        """Register a kind.

        Re-registering the SAME (id, name) pair is idempotent — two packages
        may legitimately both ensure a shared kind is present. Registering a
        DIFFERENT name under the same id is a 32-bit FNV-1a COLLISION and
        raises: the design accepts a hashed id precisely on the condition that
        a collision is a loud startup failure and never a silent mis-dispatch.
        """
        var at = self._index_of(d.kind_id)
        if at >= 0:
            if self._descs[at].kind_name != d.kind_name:
                raise Error(
                    String("ScanKindRegistry: kind_id collision — id ")
                    + String(d.kind_id)
                    + String(" already registered as '")
                    + self._descs[at].kind_name
                    + String("', cannot re-register as '")
                    + d.kind_name
                    + String("'")
                )
            self._descs[at] = d^
            return
        self._ids.append(d.kind_id)
        self._descs.append(d^)

    def describes(self, kind_id: UInt32) -> Bool:
        return self._index_of(kind_id) >= 0

    def kind_id_at(self, index: Int) -> UInt32:
        """The `kind_id` at `index`, in registration order.

        ⚠ EXISTS SO AN AUDIT CAN ITERATE *EVERY* REGISTERED KIND rather than a
        hand-written list of the kinds someone remembered — see
        `scan_identity_audit.mojo` rule R0. A hand-listed set of kinds is the
        same defect the closed union is, one level up: it goes stale silently,
        and the kind that was forgotten is exactly the kind that is unchecked.
        """
        return self._ids[index]

    def descriptor(self, kind_id: UInt32) raises -> ScanKindDescriptor:
        var at = self._index_of(kind_id)
        if at < 0:
            raise Error(
                String("ScanKindRegistry: no descriptor for kind_id ")
                + String(kind_id)
            )
        return self._descs[at].copy()

    def validate(self, binding: ScanBinding) raises:
        """Bind-time check: the kind is registered, its declared properties
        agree with the binding, and every required param is present.

        This is where a stringly-typed params typo surfaces — at PLAN BUILD,
        naming the missing key, rather than as a wrong answer at execute time.
        """
        var at = self._index_of(binding.kind_id)
        if at < 0:
            raise Error(
                String("ScanBinding validate: unregistered kind '")
                + binding.kind_name
                + String("' (id ")
                + String(binding.kind_id)
                + String(")")
            )
        ref d = self._descs[at]
        if d.kind_name != binding.kind_name:
            raise Error(
                String("ScanBinding validate: kind_id ")
                + String(binding.kind_id)
                + String(" is registered as '")
                + d.kind_name
                + String("' but the binding names '")
                + binding.kind_name
                + String("'")
            )
        if d.orientation != binding.orientation:
            raise Error(
                String("ScanBinding validate: kind '")
                + binding.kind_name
                + String("' declares orientation ")
                + String(d.orientation)
                + String(" but the binding carries ")
                + String(binding.orientation)
            )
        if d.snapshot_policy != binding.snapshot_policy:
            raise Error(
                String("ScanBinding validate: kind '")
                + binding.kind_name
                + String("' declares snapshot_policy ")
                + String(d.snapshot_policy)
                + String(" but the binding carries ")
                + String(binding.snapshot_policy)
            )
        var missing = d.missing_params(binding.params)
        if len(missing) > 0:
            var joined = String("")
            for i in range(len(missing)):
                if i > 0:
                    joined += String(", ")
                joined += missing[i]
            raise Error(
                String("ScanBinding validate: kind '")
                + binding.kind_name
                + String("' requires param(s) not present: ")
                + joined
            )
