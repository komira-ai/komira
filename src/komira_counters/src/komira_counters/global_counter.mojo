# =============================================================================
# global_counter -- the shared primitive under every counter in this package
# =============================================================================
#
# WHAT IT IS. A process-global, name-keyed, init-once table of relaxed atomic
# 64-bit counters. Two call sites that spell the same NAME see the same cells,
# whichever module they are written in, because the cells live in the stdlib's
# `_Global` runtime slot, which is keyed by that name. The first call that
# reaches a name allocates its cells, zeroed; every later call reuses them.
#
#   comptime _CALLS = GlobalCounter["my_subsystem_calls"]
#   _CALLS.incr()          # one relaxed fetch_add
#   _CALLS.read()          # Int
#   _CALLS.reset()         # back to 0
#
#   comptime _TABLE = GlobalCounterTable["my_subsystem_table", 16]
#   _TABLE.add(3, 40)      # slot 3 += 40
#
# WHY IT IS ONE MODULE. Every counter in this package used to carry its own
# copy of the same unsafe lines: allocate one `AtomicI64` cell, zero it through
# a bitcast, wrap the pointer in an `OwnedPointer`, and hand that to `_Global`.
# They are written once here, so the one `SAFETY` argument covers all of them
# and a counter module holds no pointer at all.
#
# THE SEALED API. No `UnsafePointer` appears in any signature, and none is
# returned or stored. The allocation, the zeroing and the slot arithmetic are
# private to this file.
#
# THE ORDERING IS RELAXED. A counter orders nothing: no other memory is
# published through it, so `Ordering.RELAXED` is enough and a sequentially
# consistent add would only be paid for nothing. A reader that wants a total
# reads after the writers have joined, which supplies its own ordering.
#
# RAISING AND NON-RAISING FORMS. `_Global.get_or_create_ptr` is declared
# `raises` because it may allocate. The plain methods raise. The `try_` forms
# swallow that error, for an instrument sitting in a non-raising kernel: an
# instrument must never change the control flow of the code it observes. A
# swallowed error can only mean the cells failed to allocate, and that reads
# back as a zero.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.atomic import Ordering


def _init_cells[n: Int]() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: allocate `n` counter cells, all zero, once per name.

    A `_Global` slot is process-lifetime and is never destroyed, so the cells
    are never freed; the `OwnedPointer` is only the shape `_Global` stores.
    """
    # SAFETY: `alloc` returns storage for `n` cells that nothing else aliases.
    # Every cell is written (zero) through a bitcast to its `Int64` storage
    # BEFORE the pointer is wrapped, so no cell is ever read uninitialised.
    # `AtomicI64` is not movable by value, which is why the zero goes in by
    # `unsafe_write` rather than by constructing a value.
    var raw = alloc[AtomicI64](n)
    for i in range(n):
        (raw + i).unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(
            Scalar[DType.int64](0)
        )
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


struct GlobalCounterTable[name: StaticString, n: Int]:
    """`n` relaxed atomic counters shared by everything that spells `name`.

    Parameters:
        name: The process-wide key. Two uses of the same name, in any module,
            are the same table. Spell a name with the width in mind: two uses
            of one name with different `n` are a defect, and `_Global` does
            not catch it.
        n: The number of slots.

    A pure namespace: it has no fields and is never constructed.
    """

    comptime _G = _Global[Self.name, _init_cells[Self.n]]

    @staticmethod
    @always_inline
    def _check(slot: Int) raises:
        if slot < 0 or slot >= Self.n:
            raise Error("GlobalCounterTable: slot out of range")

    @staticmethod
    @always_inline
    def add(slot: Int, delta: Int) raises:
        """Add `delta` (may be negative) to `slot`."""
        Self._check(slot)
        var gp = Self._G.get_or_create_ptr()
        # SAFETY: `get_or_create_ptr` targets KGEN-runtime static storage that
        # lives for the whole process; the wildcard origin is the stdlib
        # `_Global` API's own return type and stays inside this method. `gp[][]`
        # is cell 0 of the `n` cells `_init_cells` allocated; `_check` bounds
        # `slot`, so `base + slot` is inside that allocation.
        var base = UnsafePointer(to=gp[][])
        _ = (base + slot)[].fetch_add[ordering=Ordering.RELAXED](
            Int64(delta)
        )

    @staticmethod
    @always_inline
    def incr(slot: Int) raises:
        """Add one to `slot`."""
        Self.add(slot, 1)

    @staticmethod
    @always_inline
    def try_add(slot: Int, delta: Int):
        """`add`, non-raising: a failure is dropped (see the file header)."""
        try:
            Self.add(slot, delta)
        except:
            pass

    @staticmethod
    @always_inline
    def read(slot: Int) raises -> Int:
        """The current value of `slot`."""
        Self._check(slot)
        var gp = Self._G.get_or_create_ptr()
        # SAFETY: see `add`.
        var base = UnsafePointer(to=gp[][])
        return Int((base + slot)[].load[ordering=Ordering.RELAXED]())

    @staticmethod
    def reset_slot(slot: Int) raises:
        """Set `slot` back to 0."""
        Self._check(slot)
        var gp = Self._G.get_or_create_ptr()
        # SAFETY: see `add`.
        var base = UnsafePointer(to=gp[][])
        (base + slot)[].store[ordering=Ordering.RELAXED](
            Scalar[DType.int64](0)
        )

    @staticmethod
    def reset() raises:
        """Set every slot back to 0. Not atomic across slots: call it with no
        writer running, as test and harness setup do."""
        var gp = Self._G.get_or_create_ptr()
        # SAFETY: see `add`; the loop stays below `n`.
        var base = UnsafePointer(to=gp[][])
        for i in range(Self.n):
            (base + i)[].store[ordering=Ordering.RELAXED](
                Scalar[DType.int64](0)
            )


struct GlobalCounter[name: StaticString]:
    """One relaxed atomic counter shared by everything that spells `name`.

    The one-slot `GlobalCounterTable`, so the two share one implementation.
    A pure namespace: it has no fields and is never constructed.
    """

    comptime _T = GlobalCounterTable[Self.name, 1]

    @staticmethod
    @always_inline
    def add(delta: Int) raises:
        """Add `delta` (may be negative)."""
        Self._T.add(0, delta)

    @staticmethod
    @always_inline
    def incr() raises:
        """Add one."""
        Self._T.add(0, 1)

    @staticmethod
    @always_inline
    def try_add(delta: Int):
        """`add`, non-raising: a failure is dropped (see the file header)."""
        Self._T.try_add(0, delta)

    @staticmethod
    @always_inline
    def try_incr():
        """`incr`, non-raising: a failure is dropped (see the file header)."""
        Self._T.try_add(0, 1)

    @staticmethod
    @always_inline
    def read() raises -> Int:
        """The current value."""
        return Self._T.read(0)

    @staticmethod
    def reset() raises:
        """Set the counter back to 0."""
        Self._T.reset_slot(0)
