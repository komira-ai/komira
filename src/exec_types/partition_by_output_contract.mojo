# =============================================================================
# PartitionBy sink — THE OUTPUT-ORDERING CONTRACT
# =============================================================================
#
# READ THIS BEFORE ADDING A PartitionBy SINK DRIVER.
#
# WHAT THIS FILE IS FOR
# ---------------------
# The SDK optimizer's window rewrite ("Pattern C") DELETES a user `Sort(K)`
# that sits directly above a `PartitionBy(P, O)` when `K` is a prefix of
# `(P ++ O)`. It is allowed to do that only because the PartitionBy sink
# emits its rows ALREADY in `(P ASC ++ O per descending)` order.
#
# That is an invariant assumed at a distance, by a pass that cannot see the
# implementation it depends on. A driver that scatters rows by HASH and
# concatenates buckets breaks it silently: every windowed query routed to
# that driver returns rows in BUCKET order while its SQL says `ORDER BY`,
# and the `ORDER BY` clause becomes a literal no-op. This file states the
# invariant in one place so both halves can read it.
#
# THE CONTRACT
# ------------
# EVERY driver reachable from `_execute_partition_by_sink_parallel` MUST
# return rows ordered by `(partition_keys ASC ++ order_keys per
# descending)` — the same order `_execute_partition_by_sink` produces:
#
#   * `_execute_partition_by_sink`
#         one `sort_batch_by_keys` over the whole batch.
#   * `_execute_partition_by_sink_parallel`
#         global sort, then whole-partition contiguous range buckets,
#         concatenated in bucket order.
#   * `_execute_partition_by_sink_hash_scatter`
#         RANGE-scatter on the partition-key VALUE (bucket id is a
#         monotone non-decreasing function of the key tuple), per-bucket
#         sort, concatenated in bucket order. (A HASH scatter here would
#         violate the contract.)
#
# HOW A FUTURE DRIVER IS SUPPOSED TO FAIL
# ---------------------------------------
# Land a driver that does NOT emit that order and the engine operators'
# PartitionBy global-order test goes RED, at the driver, with the first
# descending row printed. You then have exactly two moves, and BOTH are
# safe:
#
#   1. Fix the driver, or
#   2. flip `PARTITION_BY_SINK_EMITS_GLOBAL_KEY_ORDER` to False below.
#      Pattern C reads this constant and stops eliding, so the plan keeps
#      its Sort. The query gets SLOWER and stays CORRECT.
#
# THE CONSTANT IS NOT A TUNING KNOB AND NOT A KILL SWITCH FOR THE
# SCATTER. It is a DECLARATION about the drivers, and the test above is its
# DIFFERENTIAL: it verifies the declaration against what the drivers
# actually emit, in BOTH directions. Declaring False while the drivers do
# emit global order is ALSO red — an unnecessary Sort on every windowed
# query is a cost nobody chose.
#
# AND IT IS NOT SUFFICIENT ON ITS OWN. A driver whose output order depends
# on data (row count, worker count, key type) can satisfy the test fixture
# and violate the contract in production. The parallel driver's routing
# thresholds decide which driver runs; the test exercises the arms ON BOTH
# SIDES of `_HASH_SCATTER_MIN_ROWS` for exactly that reason.
#
# LEAF MODULE ON PURPOSE — it imports nothing, so the SDK optimizer can read
# the declaration without pulling an operator translation unit into its
# compile.
# =============================================================================


# Declared TRUE: every PartitionBy sink driver emits rows globally ordered
# by `(partition_keys ASC ++ order_keys per descending)`.
#
# Read by:
#   * the SDK optimizer's window rewrite — Pattern C, the post-window Sort
#     elision. False here disables the elision entirely.
#   * the engine operators' PartitionBy global-order test — the
#     differential that keeps this line honest.
comptime PARTITION_BY_SINK_EMITS_GLOBAL_KEY_ORDER: Bool = True
