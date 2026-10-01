# =============================================================================
# test_connection_registry.mojo
# =============================================================================
# ConnectionRegistry tests.
#
# Per-server registry of in-flight
# connection handles. Used by accept loop (writer) + graceful-shutdown
# (reader/drainer).
#
# Storage shape (see task_scope.mojo): List[T] requires Copyable T; JoinHandle is NOT
# Copyable. ConnectionRegistry stores `List[ArcPointer[_SpawnSlot[None]]]`
# and exposes `register_slot(var slot)` instead of
# `add(handle: JoinHandle)`.
#
# 5 tests:
#   1. construct_empty — count == 0 after new()
#   2. register_slot_increments_count — register 3 already-completed
#      slots; count == 3
#   3. clone_shares_state — clone, register via clone, count via
#      original shows the increment
#   4. drain_completes_all — register 3 already-completed slots; drain
#      returns; count == 0 post-drain
#   5. drain_empty_idempotent — drain on empty registry is no-op
# =============================================================================

from std.memory import ArcPointer
from std.atomic import Atomic
from std.testing import assert_equal, assert_false, assert_true

from komira_async.primitives.connection_registry import ConnectionRegistry
from komira_async.spawner.join_handle import _SpawnSlot, complete_slot


# -----------------------------------------------------------------------------
# Helper: build an Arc-shared spawn slot already marked READY.
# Mirrors what the worker-pool trampoline does after the task body
# returns. The READY state means drain_with_timeout will see the slot
# terminal on first observation.
# -----------------------------------------------------------------------------


def _make_completed_slot() raises -> ArcPointer[_SpawnSlot[NoneType]]:
    """Build an Arc-shared _SpawnSlot[None] in the READY state via
    complete_slot. Returns a fresh Arc clone for the caller to register."""
    var slot = ArcPointer[_SpawnSlot[NoneType]](_SpawnSlot[NoneType]())
    var slot_for_complete = ArcPointer[_SpawnSlot[NoneType]](copy=slot)
    complete_slot[NoneType](slot_for_complete, None)
    return slot^


# -----------------------------------------------------------------------------
# Test 1: construct_empty
# -----------------------------------------------------------------------------


def test_registry_construct_empty() raises:
    """new() yields a registry with count == 0."""
    var r = ConnectionRegistry.new()
    assert_equal(r.count(), UInt(0))


# -----------------------------------------------------------------------------
# Test 2: register_slot_increments_count
# -----------------------------------------------------------------------------


def test_registry_register_slot_increments_count() raises:
    """Register 3 already-completed slots; count == 3."""
    var r = ConnectionRegistry.new()
    var s1 = _make_completed_slot()
    var s2 = _make_completed_slot()
    var s3 = _make_completed_slot()
    r.register_slot(s1^)
    r.register_slot(s2^)
    r.register_slot(s3^)
    assert_equal(r.count(), UInt(3))


# -----------------------------------------------------------------------------
# Test 3: clone_shares_state
# -----------------------------------------------------------------------------


def test_registry_clone_shares_state() raises:
    """Clone, register via clone, count via original shows the
    increment. Both clones share the same underlying ArcPointer-anchored
    state."""
    var r1 = ConnectionRegistry.new()
    var r2 = r1.clone()
    var s = _make_completed_slot()
    r2.register_slot(s^)
    assert_equal(r1.count(), UInt(1))
    assert_equal(r2.count(), UInt(1))


# -----------------------------------------------------------------------------
# Test 4: drain_completes_all
# -----------------------------------------------------------------------------


def test_registry_drain_completes_all() raises:
    """Register 3 already-completed slots; drain_with_timeout returns
    near-instantly (slots already terminal); count == 0 post-drain."""
    var r = ConnectionRegistry.new()
    var s1 = _make_completed_slot()
    var s2 = _make_completed_slot()
    var s3 = _make_completed_slot()
    r.register_slot(s1^)
    r.register_slot(s2^)
    r.register_slot(s3^)
    assert_equal(r.count(), UInt(3))
    # Slots are already in READY state so the wait_on_address(.timeout=1ms)
    # cycles inside drain return immediately.
    r.drain_with_timeout(Int64(1_000_000_000))
    assert_equal(r.count(), UInt(0))


# -----------------------------------------------------------------------------
# Test 5: drain_empty_idempotent
# -----------------------------------------------------------------------------


def test_registry_drain_empty_idempotent() raises:
    """Drain on empty registry — no-op + count stays 0."""
    var r = ConnectionRegistry.new()
    r.drain_with_timeout(Int64(100_000_000))
    assert_equal(r.count(), UInt(0))


def main() raises:
    test_registry_construct_empty()
    test_registry_register_slot_increments_count()
    test_registry_clone_shares_state()
    test_registry_drain_completes_all()
    test_registry_drain_empty_idempotent()
    print("PASS komira_async.primitives.connection_registry (5/5 tests)")
