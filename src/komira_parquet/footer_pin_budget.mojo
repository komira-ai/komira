# =============================================================================
# footer_pin_budget: how many bytes of file mapping the footer cache may pin
# =============================================================================
#
# `ParquetMetadataCache` can keep a file's whole-file mapping alive for its
# own lifetime (a session), so the next query over the file neither maps,
# unmaps nor re-faults it. This module is the budget for that: the cap on the
# sum of `file_size` over the files it pins.
#
# What is bounded is mapped bytes, a conservative over-estimate of what
# costs (resident pages): a query that touches 200 MB of a 14 GB file maps
# 14 GB. Bounding residency would need `mincore(2)` per pin and re-polling.
# Pins are admitted until the budget is spent and are never evicted, so a
# working set larger than the cap degrades to mapping per query, never to
# mapping and unmapping on the boundary.
#
# Why the admission key is the file size and not the bytes a query projects:
# the cache maps the whole file (no partial maps), so charging projected
# bytes would charge P and map F; and with admission-only pins, the first
# query over a file would fix its charge for the session, so the same
# queries in a different order would pin differently.
#
# The budget is sized to the machine: a fraction of the free-RAM basis
# (`min(host MemAvailable, the cgroup's memory.max)`, komira_host), clamped
# between a floor (the fixed 1 GiB default) and a ceiling. A pinned mapping
# is file-backed clean pages, which the kernel reclaims before it kills
# anything, so a fraction that is safe for an anonymous-heap cache is
# conservative here. An operator's explicit byte count overrides it; the
# library reads no environment, so a program maps its own flag to it.
# =============================================================================

from komira_host.proc_probe import detect_scan_cache_ram_basis_bytes


comptime DEFAULT_MMAP_PIN_BYTE_CAP: Int = 1 << 30
"""The cap when the RAM basis cannot be read (no procfs), and the cap of a
cache constructed without one: 1 GiB."""

comptime MMAP_PIN_MEM_FRACTION_PCT: Int = 30
"""Percent of the free-RAM basis the budget takes."""

comptime MMAP_PIN_MIN_BYTES: Int = 1 << 30
"""The floor: never less than the fixed default (1 GiB)."""

comptime MMAP_PIN_MAX_BYTES_CEILING: Int = 8 << 30
"""The ceiling: never more than 8 GiB, however much RAM is free."""


def mmap_pin_budget_from_ram(ram_basis_bytes: Int, override_bytes: Int) -> Int:
    """The budget for a RAM basis and an explicit override, in order:
      1. `override_bytes > 0` is the budget.
      2. `ram_basis_bytes <= 0` (unknown): `DEFAULT_MMAP_PIN_BYTE_CAP`.
      3. `MMAP_PIN_MEM_FRACTION_PCT` percent of the basis, clamped to
         [`MMAP_PIN_MIN_BYTES`, `MMAP_PIN_MAX_BYTES_CEILING`].
    """
    if override_bytes > 0:
        return override_bytes
    if ram_basis_bytes <= 0:
        return DEFAULT_MMAP_PIN_BYTE_CAP
    var budget = ram_basis_bytes // 100 * MMAP_PIN_MEM_FRACTION_PCT
    if budget < MMAP_PIN_MIN_BYTES:
        budget = MMAP_PIN_MIN_BYTES
    if budget > MMAP_PIN_MAX_BYTES_CEILING:
        budget = MMAP_PIN_MAX_BYTES_CEILING
    return budget


def resolve_mmap_pin_byte_cap(override_bytes: Int = 0) -> Int:
    """`mmap_pin_budget_from_ram` over this machine's free-RAM basis."""
    return mmap_pin_budget_from_ram(detect_scan_cache_ram_basis_bytes(), override_bytes)
