# =============================================================================
# src/kci_publish/index.mojo -- contract step 5, REPORT-ONLY: does the
#   subdir's `repodata.json` list each published file with its sha256 yet?
# =============================================================================
#
# This is not a solver run and not a gate. The read-back by download (step 3)
# is the gate; an index that lags is reported as `indexed: false` and never
# changes the exit code. A solver dry run, if one is wanted, is the release
# job's.
#
# Encapsulation: owned values; the registry set is borrowed `mut`. No pointer,
# no wildcard origin.
# =============================================================================

from komira_retry import Sleeper

from kci_pkg_upload import (
    PRESENCE_PRESENT_IDENTICAL,
    ContentIdentity,
    PkgTransport,
    RegistryCredential,
    RegistrySet,
)

from .plan import PublishTarget
from .upload import RunOptions


def is_indexed[T: PkgTransport, C: RegistryCredential, W: Sleeper](
    mut registry: RegistrySet[T, C], t: PublishTarget, opts: RunOptions, mut sleeper: W
) -> Bool:
    """Poll the repodata up to `index_polls` times for `t` with our sha256.
    Never raises: anything but a listing with our sha256 is False."""
    try:
        var expect = ContentIdentity.of_sha256_hex(t.sha256_hex.copy())
        var n = 0
        while n < opts.index_polls:
            if n > 0:
                sleeper.sleep_ms(opts.index_wait_ms)
            var p = registry.presence(t.coordinate, expect)
            if p.kind == PRESENCE_PRESENT_IDENTICAL:
                return True
            n += 1
    except:
        return False
    return False
