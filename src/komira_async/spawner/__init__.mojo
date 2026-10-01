# =============================================================================
# komira_async.spawner — Spawner trait + JoinHandle + LocalSpawner + TaskScope
# =============================================================================
# (Spawner trait) + (LocalSpawner — trait-surface
# façade) + (TaskScope[T,S,ro] + ComputeTaskScope[T]) + (JoinHandle[T]
# + drop=cancel semantics).
# =============================================================================
