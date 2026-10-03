"""`komira_shuffle` — the distributed shuffle over an object store.

  * sink        map write: `HashPartitioner` assigns each row a partition; the
                producer writes one `.seg` object (a dense index trailer) and
                commits a manifest entry (`sink_shuffle_write`)
  * seal        the sole read barrier: `seal_step` verifies the committed
                producers as a SET against the expected set, then appends the
                seal (`seal_driver`, `seal`)
  * source      reduce read, through the seal (`read_shuffle_partition`)
  * claim       pull-via-claim create-CAS: elastic reducers each win distinct
                partitions (`claim_partition`)
  * retention   the cross-epoch reaper (`reclaim_floor`, `reap_epoch`)

It builds on `komira_objectstore` (CAS manifest, conditional-write stores,
`Path`); that package does not depend on this one. Modules are imported by
path (`komira_shuffle.sink`, ...); the package re-exports nothing.
"""
