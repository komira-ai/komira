# =============================================================================
# kci_validate -- the validations of a stage's steps: checks of what a step
#   produced, run after it.
# =============================================================================
#
#   conda_install_smoke.mojo  `run_install_smoke`: a CONDA_INSTALL_SMOKE
#                             validation of a PUBLISH step. Read the channel
#                             anonymously, install the release inside a
#                             digest-pinned container, read back what was
#                             installed, run a program. Fails closed;
#                             WOULD_VALIDATE under --plan.
#   request.mojo              `ValidateRequest`, `ContainerHost`; the release
#                             and the pins, read the PUBLISH step's way
#   channel_index.mojo        check 1: the index lists and serves the bytes
#                             the build made, with the wait for the index
#   container.mojo            the scratch layout, pixi.toml, the script and
#                             the exact `docker` command lines
#   readback.mojo             checks 2 to 4: records, payloads, the count
#
# Which validations a step has is the machine file's (kci_stage_graph); the
# result rows are kci_contract's; processes start through kci_build's
# ProcessRunner seam and the channel is read through kci_pkg_upload's
# PkgTransport. The command line is the kci binary's (`kci run`).
# =============================================================================

from kci_validate.channel_index import CHECK_CHANNEL, WAIT_POLL_SECONDS, ChannelUrl, check_channel
from kci_validate.conda_install_smoke import run_install_smoke
from kci_validate.container import (
    COMPILER_PACKAGE,
    CONDA_FORGE_URL,
    ENV_DIR,
    MANIFEST_NAME,
    PROGRAM_COPY,
    PULL_TIMEOUT_S,
    RUN_TIMEOUT_S,
    WORK_MOUNT,
    channel_url_of,
    container_script,
    docker_child_env,
    install_manifest_text,
    payload_record_name,
    pull_argv,
    run_argv,
)
from kci_validate.readback import program_stem
from kci_validate.request import (
    ContainerHost,
    InstallPin,
    ValidateRequest,
    install_pins,
    load_validated_release,
    mojo_pin_of,
)
