"""The uppercase-`StoreError[<KIND>]`-token classification path.

`ServiceRegistry`'s `register` retries-once on a 412 (concurrent-deploy CAS
conflict) and takes the CREATE path on a 404 (first-deploy, object absent). It
classifies the store's raised `Error` by message substring
(`_is_precondition_failed` / `_is_not_found`).

A probe keyed ONLY on lowercase `find("precondition")` / `find("not_found")` +
the numeric `412` / `404` does NOT match the CANONICAL uppercase taxonomy tokens
`StoreError[PRECONDITION]` / `StoreError[NOT_FOUND]` that the object-store
conformers raise; it would work only while a numeric `status=412` /
`status=404` happened to be co-present. A message without the numeric would
then silently:
  * turn a first-deploy `StoreError[NOT_FOUND]` into a FATAL register (the
    object-absent CREATE path is never taken — the head-raise propagates), and
  * drop the concurrent-deploy `StoreError[PRECONDITION]` retry (register
    re-raises instead of re-reading + retrying).

These two gates feed the classifiers messages that carry ONLY the uppercase
token — NO numeric, NO lowercase — so a lowercase/numeric-only probe fails
both: `_is_not_found("StoreError[NOT_FOUND] head ...")` would return False and
gate 1's register would RE-RAISE the head error (fatal first deploy);
`_is_precondition_failed("StoreError[PRECONDITION] ...")` would return False and
gate 2's register would RE-RAISE instead of retrying.

Hermetic — a small `ConditionalWriteStore` decorator over the in-memory CAS
conformer that RE-RAISES the uppercase-token error at the head / CAS seam. No
FFI, no gRPC dependency (this package is a clean object-store leaf and
classifies the taxonomy token in-leaf).
"""

from std.memory import ArcPointer

from komira_svcref.service_registry import ServiceRegistry

from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


# The uppercase canonical taxonomy tokens the object-store conformers emit.
# NOTE (load-bearing for this test): these strings carry NO numeric `404`/`412`
# and NO lowercase `not_found`/`precondition` — so ONLY the uppercase-token
# probe can classify them. If you "fix" these strings to add a numeric you defeat
# the falsifier.
comptime _UPPER_NOT_FOUND: String = (
    "StoreError[NOT_FOUND] head gs://bootstrap/service/x"
)
comptime _UPPER_PRECONDITION: String = (
    "StoreError[PRECONDITION] compare_and_swap gs://bootstrap/service/x"
)


def _eq_opt(got: Optional[String], want: String, ctx: String) raises:
    if not got:
        raise Error(ctx + ": expected '" + want + "' but got None")
    if got.value() != want:
        raise Error(
            ctx + ": expected '" + want + "' but got '" + got.value() + "'"
        )


# -----------------------------------------------------------------------------
# _UppercaseTokenStore — a ConditionalWriteStore decorator that raises the
# CANONICAL uppercase `StoreError[<KIND>]` token (numeric-free) at the head /
# compare_and_swap seam, so the classifier is exercised on the exact message
# shape a production store emits. Mode-driven:
#   mode == NOT_FOUND:      `head` ALWAYS raises the uppercase NOT_FOUND token
#                           (object-absent first-deploy); create/get delegate.
#   mode == PRECONDITION:   the FIRST `compare_and_swap` raises the uppercase
#                           PRECONDITION token (concurrent-deploy CAS conflict);
#                           subsequent CAS + head delegate (the retry commits).
# -----------------------------------------------------------------------------
comptime _MODE_NOT_FOUND: Int = 0
comptime _MODE_PRECONDITION: Int = 1


struct _ClassifyCell(Movable, Deinitable):
    """Interior-mutable one-shot flag (shared via ArcPointer so the immutable-
    `self` verbs can flip it)."""

    var cas_fired: Bool

    def __init__(out self):
        self.cas_fired = False


struct _UppercaseTokenStore(
    ConditionalWriteStore, ObjectStore, Movable, Deinitable
):
    var _inner: SharedInMemoryConditionalStore
    var _mode: Int
    var _cell: ArcPointer[_ClassifyCell]

    def __init__(
        out self, var inner: SharedInMemoryConditionalStore, mode: Int
    ):
        self._inner = inner^
        self._mode = mode
        self._cell = ArcPointer[_ClassifyCell](_ClassifyCell())

    # ---- ObjectStore surface ----

    def head(self, path: Path) raises -> ObjectMeta:
        if self._mode == _MODE_NOT_FOUND:
            # First-deploy: the object is absent — raise the CANONICAL uppercase
            # NOT_FOUND token (numeric-free). register MUST classify this as
            # not-found and take the CREATE (conditional_put) path.
            raise Error(_UPPER_NOT_FOUND)
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    # ---- ConditionalWriteStore surface ----

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        if self._mode == _MODE_PRECONDITION and not self._cell[].cas_fired:
            # Concurrent-deploy: the FIRST CAS 412s under the uppercase
            # PRECONDITION token (numeric-free). register MUST classify this as
            # a precondition failure, re-read, and retry — NOT re-raise.
            self._cell[].cas_fired = True
            raise Error(_UPPER_PRECONDITION)
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


# -----------------------------------------------------------------------------
# Gate 1 — first-deploy: an uppercase `StoreError[NOT_FOUND]` (numeric-free) is
# classified as not-found, so register takes the CREATE path (not a fatal raise).
# -----------------------------------------------------------------------------
def test_uppercase_not_found_takes_create_path() raises:
    print("-- test_uppercase_not_found_takes_create_path --")
    var store = _UppercaseTokenStore(
        SharedInMemoryConditionalStore(), _MODE_NOT_FOUND
    )
    var reg = ServiceRegistry(store^)

    # head raises the uppercase NOT_FOUND token -> _is_not_found must be True ->
    # register takes conditional_put(If-None-Match:*) and COMMITS. A
    # lowercase-only probe would return False and this register would RE-RAISE.
    reg.register(String("first-deploy"), String("http://svc-a:8088"))

    _eq_opt(
        reg.resolve(String("first-deploy")),
        String("http://svc-a:8088"),
        "first-deploy resolve after uppercase-NOT_FOUND create",
    )
    print("   uppercase StoreError[NOT_FOUND] -> CREATE path OK")


# -----------------------------------------------------------------------------
# Gate 2 — concurrent-deploy: an uppercase `StoreError[PRECONDITION]`
# (numeric-free) is classified as a precondition failure, so register re-reads +
# retries-once and commits (last-writer-wins) rather than re-raising.
# -----------------------------------------------------------------------------
def test_uppercase_precondition_retries_once() raises:
    print("-- test_uppercase_precondition_retries_once --")
    var inner = SharedInMemoryConditionalStore()

    # Seed the object so the victim register takes the UPDATE (If-Match CAS) path.
    var seed = ServiceRegistry(inner.clone())
    seed.register(String("svc"), String("http://old"))
    _eq_opt(
        ServiceRegistry(inner.clone()).resolve(String("svc")),
        String("http://old"),
        "seed",
    )

    # The victim registers "http://new". Its FIRST compare_and_swap raises the
    # uppercase PRECONDITION token (numeric-free); register must classify it,
    # re-read, retry, and the retry commits. A lowercase-only probe would return
    # False and register would RE-RAISE on the first CAS.
    var racing = _UppercaseTokenStore(inner.clone(), _MODE_PRECONDITION)
    var reg = ServiceRegistry(racing^)
    reg.register(String("svc"), String("http://new"))

    _eq_opt(
        ServiceRegistry(inner.clone()).resolve(String("svc")),
        String("http://new"),
        "after uppercase-PRECONDITION retry",
    )
    print("   uppercase StoreError[PRECONDITION] -> retry-once + commit OK")


def main() raises:
    print("== uppercase StoreError[<KIND>] classification ==")
    test_uppercase_not_found_takes_create_path()
    test_uppercase_precondition_retries_once()
    print("== ALL GATES PASSED ==")
