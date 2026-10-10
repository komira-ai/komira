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
#   conda_install_env.mojo    `run_install_env`: a CONDA_INSTALL_ENV
#                             validation. The same checks, the install on
#                             this machine with no container (a pinned pixi,
#                             a scratch directory outside the checkout, a
#                             cleared environment), and each installed
#                             library's README examples as the programs. No
#                             network at all is INDETERMINATE with a
#                             skip_reason (exit 5), never a pass
#   env.mojo                  the ENV scratch layout, the child's whole
#                             environment, the exact pixi command lines, the
#                             checkout and system-config refusals
#   network.mojo              whether any declared host answers at all
#   readme_installed.mojo     an installed README as the programs it runs,
#                             byte-equal to the welded SOURCE-mode programs
#   request.mojo              `ValidateRequest`, `ContainerHost`; the release
#                             and the pins, read the PUBLISH step's way; a
#                             metapackage's members from its own depends
#   channel_index.mojo        check 1: the index lists and serves the bytes
#                             the build made, with the wait for the index
#   file_channel.mojo         a LOCAL channel (`file:///<dir>`, kci run
#                             --channel): check 1's reads answered from a
#                             directory, every other read over HTTPS
#   container.mojo            the scratch layout, pixi.toml, the script and
#                             the exact `docker` command lines
#   readback.mojo             checks 2 to 4: records, payloads, the count
#
# Which validations a step has is the machine file's (kci_release_machine); the
# result rows are kci_api's; processes start through kci_build's
# ProcessRunner seam and the channel is read through kci_pkg_upload's
# PkgTransport. The README examples become programs through the Mojo
# library of //tools/build/readme_examples, which makes the bytes the
# package's Zig tool makes for the welded `[tests][readme]` test. The command
# line is the kci binary's (`kci run`).
# =============================================================================

from kci_validate.channel_index import (
    CHECK_CHANNEL,
    FILE_CHANNEL_PREFIX,
    WAIT_POLL_SECONDS,
    ChannelUrl,
    IndexPollLog,
    RecordingIndexPollLog,
    StderrIndexPollLog,
    check_channel,
    poll_line,
)
from kci_validate.conda_install_env import run_install_env
from kci_validate.file_channel import FileChannelTransport
from kci_validate.conda_install_smoke import run_install_smoke
from kci_validate.env import (
    AUTH_FILE_TEXT,
    ENV_SYSTEM_PATH,
    PIXI_SYSTEM_CONFIG_DIR,
    EnvHost,
    env_child_env,
    install_env_argv,
    run_program_argv,
    scratch_refusal,
    system_configs,
)
from kci_validate.network import declared_hosts
from kci_validate.readme_installed import ReadmeProgram, installed_readme, package_dir_of, readme_program_of
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
    metapackage_members,
    mojo_pin_of,
    readme_doc_path,
    with_members,
)
