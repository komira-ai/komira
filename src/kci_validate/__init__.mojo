# =============================================================================
# kci_validate -- the validations of a stage's steps: checks of what a step
#   produced, run after it.
# =============================================================================
#
#   conda_install_smoke.mojo  run_install_smoke: a CONDA_INSTALL_SMOKE
#                             validation of a PUBLISH step. Install the
#                             release from the step's channel into a clean
#                             environment, check every installed record
#                             against the release's own (name, version,
#                             build, sha256, the channel), run a smoke
#                             program. Fails closed; WOULD_VALIDATE under
#                             --plan.
#
# Which validations a step has is the machine file's (kci_stage_graph); the
# result rows are kci_contract's; processes start through kci_build's
# ProcessRunner seam. The command line is the kci binary's (`kci run`).
# =============================================================================

from kci_validate.conda_install_smoke import (
    ENV_DIR,
    INSTALL_TIMEOUT_S,
    MANIFEST_NAME,
    SMOKE_OK_SUFFIX,
    SMOKE_TIMEOUT_S,
    check_installed_records,
    install_manifest_text,
    run_install_smoke,
    smoke_child_env,
    smoke_ok_line,
    smoke_stem,
)
