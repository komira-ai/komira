# =============================================================================
# komira_async.runtime.idle_hook — the per-worker installable idle-hook slot.
# =============================================================================
#
# This module has no bespoke bare-POD
# `_IdleHookSlot` struct + its hand-rolled `_IdleHookRunFn` / `_IdleHookDropFn`
# fn-ptr aliases and now adopts the ONE blessed LOW installable-hook primitive
# `ErasedHook` (installable_hook.mojo). BOTH the runtime idle-hook slot AND the
# logger native-index hook now import the SAME primitive — the consolidation that
# lets the HIGH logger carry ZERO bespoke wildcard. The wildcard byte-ptr
# type-erasure handle + the FFI-POD fire/drop code pointers all live ONCE, in the
# blessed `ErasedHook`, not cloned per consumer.
#
# `_IdleHookSlot` is RE-EXPORTED as an ALIAS of `ErasedHook` so existing imports
# (`from komira_async.runtime.idle_hook import _IdleHookSlot`) keep resolving;
# new code should import `ErasedHook` directly.
#
# See installable_hook.mojo (the primitive's full SAFETY narrative).
#
# WHAT THIS IS (unchanged contract)
#   A single FFI-POD value the worker BORROWS — the worker fires it on its OWN
#   thread in the empty-spin idle window (worker.mojo, sibling to
#   `_drain_log_ring`), BLIND (type-erased): the worker never names the
#   parametric store/metastore/index types (which it physically cannot, due to
#   the komira_async <- HIGH-package import direction). The hook body is
#   monomorphized HIGH-side on the PRODUCER side of the erasure boundary.
#
# THE LOAD-BEARING SAFETY CONTRACT
#   The worker OWNS no context heap; it only BORROWS. The `ctx_raw` byte-ptr
#   targets a FOREVER-ROOT allocation (a EngineContext-owned context home that
#   lives the whole process and is freed AFTER all workers join), NOT a
#   destroy-recreate-lifecycle OWNING field. The slot itself is a POD value-field
#   on Worker; it owns NO heap. The slot's drop is a no-op; the drop trampoline is
#   invoked exactly once, by the EngineContext, AFTER all workers have joined.
#   Full destroy-recreate / acyclicity argument: see installable_hook.mojo header.
#
# Use `fn` (Mojo 1.0.0b1 pin; fn->def migration DEFERRED — match the surrounding
# `_TaskEntry` shape).
# =============================================================================

from komira_async.runtime.installable_hook import (
    ErasedHook,
    installable_hook_home,
)


# `_IdleHookSlot` — the per-worker installable idle-hook slot. RETIRED as a
# bespoke struct; now an ALIAS of the blessed `ErasedHook` primitive
# (installable_hook.mojo). Kept as an alias so existing imports resolve; the
# fields are `ErasedHook`'s (`ctx_raw` / `fire_fn` / `drop_fn`), and the worker
# fires it via `slot.fire(worker_id)` + `slot.drop()` (the encapsulated API), not
# a raw fn-ptr call.
comptime _IdleHookSlot = ErasedHook
