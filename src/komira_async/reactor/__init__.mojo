# =============================================================================
# komira_async.reactor — Reactor[S] + IoSubsystem[S] + per-platform backends
# =============================================================================
# Reactor[S], IoSubsystem[S] (per-worker pluggable IoSubsystem).
#
# Per-platform backends gated via comptime if CompilationTarget.is_linux/
# is_macos().
# Single package umbrella; only host-matching branch enters codegen
# (verified via nm -D on the ELF binary).
# =============================================================================
