"""`komira_shuffle_e2e` -- test-only: `komira_shuffle` across processes.

  * rows      the deterministic rows a map task writes, and the bytes each
              partition must then hold (the tests' oracle)
  * children  `TaskGroup`: the task processes of one test, read without
              blocking, waited on with deadlines, killed if left running
  * harness   `ShuffleRun`: tasks over one LocalFs root, and the root read
              back (entries, seal, claims, a snapshot of the map output)

The task binary is `bin/shuffle_task.mojo`. Modules are imported by path.
"""
