# Process-wide tallies of the TLS entries a `MailTlsTable` created and freed.
#
# They exist so a test can see that every entry is freed exactly once: after
# any sequence of `begin_upgrade` and `drop`, and after a table is destroyed,
# `created - freed` is the number of live entries, and a double free would push
# `freed` past `created`. They are counted, not logged; nothing reads them in a
# server.
#
# Mechanism: a name-keyed, init-once process slot (`_Global`), the idiom the
# engine's route counters use, because Mojo has no global variables. Single
# relaxed atomic adds, one per entry created and one per entry freed.

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc


def _init_tally() -> OwnedPointer[AtomicI64]:
    """`_Global` init function: one zeroed counter, allocated once per name."""
    # SAFETY: `alloc` returns one uninitialised `AtomicI64` slot owned by this
    # function until the `OwnedPointer` below takes it; the zero write
    # initialises it through an int64 view of the same bytes (an `AtomicI64`
    # holds one int64). From then on the `OwnedPointer` owns and frees it, and
    # `_Global` keeps that `OwnedPointer` for the life of the process.
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(
        Scalar[DType.int64](0)
    )
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _CREATED = _Global["komira_mail_tls_entries_created", _init_tally]
comptime _FREED = _Global["komira_mail_tls_entries_freed", _init_tally]


def note_created():
    """Count one entry created. Never fails the caller."""
    try:
        # SAFETY: `get_or_create_ptr` points at process-lifetime storage the
        # runtime manages; the pointer is used only inside this body.
        var p = _CREATED.get_or_create_ptr()
        _ = p[][].fetch_add(Int64(1))
    except:
        pass


def note_freed():
    """Count one entry freed. Never fails the caller (it runs in a destructor)."""
    try:
        # SAFETY: as in `note_created`.
        var p = _FREED.get_or_create_ptr()
        _ = p[][].fetch_add(Int64(1))
    except:
        pass


def tls_entries_created() -> Int:
    """How many TLS entries every table in this process has created so far."""
    try:
        # SAFETY: as in `note_created`.
        var p = _CREATED.get_or_create_ptr()
        return Int(p[][].load())
    except:
        return -1


def tls_entries_freed() -> Int:
    """How many TLS entries every table in this process has freed so far."""
    try:
        # SAFETY: as in `note_created`.
        var p = _FREED.get_or_create_ptr()
        return Int(p[][].load())
    except:
        return -1
