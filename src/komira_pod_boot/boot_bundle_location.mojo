# =============================================================================
# komira_pod_boot/boot_bundle_location.mojo — WHERE THE BOOT BUNDLE LIVES.
#   The bucket, the object key, and the URL, derived once for both clouds.
# =============================================================================
#
# ★ WHY THIS IS PART OF THE BOOT CONTRACT AND NOT PART OF THE PUBLISHER.
#
# `pod_boot_contract.mojo` declares WHAT a booting VM is told. This file declares
# WHERE the one thing it has to fetch lives. They are the same hand-off:
#
#   the PUBLISHER                       the PLACEMENT CONFORMER
#   (an operator step, once per build)  (the GCE conformer / Ec2VmPodManager)
#          |                                       |
#          |  writes an object at THIS key ...     |... renders a boot script
#          |  in THIS bucket                       |   that fetches THIS url
#          +---------------------------------------+
#
# Nothing type-checks that either. A publisher that writes `pod-loader/<sha>` and
# a renderer handed `pod-loader/sha256/<sha>/…` both compile, both deploy, and
# produce a VM that boots, 404s on the fetch, runs nothing and bills. So the
# derivation is spelled ONCE, here, beside the environment variable names it
# is the same kind of agreement as — and both sides import it.
#
# ⛔ THE BUCKET NAME TAKES A REGION, AND THAT ARGUMENT IS REQUIRED.
#
# An environment-wide bucket with no region in its name says nothing about which
# region it serves, so nothing refuses when a VM in one region fetches its
# loader from a bucket in another. The cost is not the egress (the bundle is
# small); it is that EVERY VM job in the placement region cannot boot during an
# outage of the bucket's region, on a path whose whole purpose is to start
# compute. The callback a booted VM reports to is in-region over private
# connectivity (never cross-region, never public), and the boot fetch must
# follow the same rule.
#
# ⇒ `boot_bundle_bucket(account_ref, region)` REFUSES an empty region. A boot
#   artifact bucket cannot be NAMED here without saying which region it serves.
#
# ⚠ AND IT IS A NAME OF ITS OWN, NOT A REGION SUFFIX BOLTED ONTO AN EXISTING
#   ONE. Region-suffixing a live bucket name resolves to a bucket that does not
#   exist and orphans the live one: a storage migration disguised as a config
#   diff. A dedicated name is region-correct from its first byte.
#
# ⛔ THE KEY IS CONTENT-ADDRESSED, AND THERE IS NO `latest` / `current` ALIAS.
#   Keys are content-addressed (SHA-256), never versioned by a source
#   revision. A mutable alias would make the URL derivable without a pin — and
#   would also mean a VM booting during a publish can fetch a half-written
#   object, and that two placements of the "same" job can run different code.
#   The publisher PRINTS the resolved URL (`PUBLISHED_BOOT_BUNDLE_URL=`, §4) and
#   that value is pinned into the placement config, exactly as an image digest
#   is pinned into a service.
#
# ENCAPSULATION. Pure String in / String out. ZERO UnsafePointer; no wildcard
# origin; no allocation that outlives a call.
# =============================================================================


# -----------------------------------------------------------------------------
# §1 — the two URL schemes a rendered boot script can fetch.
#
# ⚠ THESE ARE THE TWO ARMS THE RENDERERS DISPATCH ON, and they are declared here
# so a third scheme cannot be published to a VM that has no case for it.
# `Ec2VmPodManager.build_vm_bootstrap` switches `s3://*` -> `aws s3 cp`, anything
# else -> `curl`; the GCE startup-script renderer switches `gs://*` -> the
# metadata-token GET, anything else -> `curl`. A URL whose scheme neither recognises is not a
# failed download — it is a `curl` of a string that is not a URL, on a machine
# that then has nothing to run.
# -----------------------------------------------------------------------------

comptime BOOT_BUNDLE_SCHEME_GS: String = "gs"
"""GCS. A booting GCE VM reads it with its OWN instance metadata token — no
key, no signed URL, no second credential."""

comptime BOOT_BUNDLE_SCHEME_S3: String = "s3"
"""S3. A booting EC2 instance reads it with its instance profile via `aws s3 cp`
(present on Amazon Linux)."""


# -----------------------------------------------------------------------------
# §2 — the bucket. ONE artifact per (account, region).
# -----------------------------------------------------------------------------

comptime BOOT_BUNDLE_BUCKET_INFIX: String = "pod-loader"
"""The middle segment of the boot-artifact bucket name — `<account>-pod-loader-
<region>`. It names the ARTIFACT CLASS, not the environment, so an operator
reading a bucket list can tell what would break by deleting it."""

comptime _BUCKET_NAME_MAX: Int = 63
"""GCS and S3 both cap a bucket name at 63 characters (a name over the cap is
rejected at create time, so catching it here turns a live API error into a
derivation error)."""


def _is_bucket_safe(s: String) -> Bool:
    """True iff `s` is non-empty and made only of lowercase letters, digits and
    hyphens — the intersection of the GCS and S3 bucket-name alphabets, which is
    what a name usable on BOTH clouds must satisfy. Deliberately does NOT accept
    a dot: a dotted S3 bucket name breaks virtual-hosted-style TLS, and a dotted
    GCS name requires domain verification."""
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        var c = b[i]
        var lower = c >= UInt8(ord("a")) and c <= UInt8(ord("z"))
        var digit = c >= UInt8(ord("0")) and c <= UInt8(ord("9"))
        if not (lower or digit or c == UInt8(ord("-"))):
            return False
    return True


def boot_bundle_bucket(account_ref: String, region: String) raises -> String:
    """The bucket a boot bundle for `account_ref` in `region` is published to:
    `<account_ref>-pod-loader-<region>`.

    `account_ref` is the cloud account the VMs run in — a GCP project id
    (`example-project`) or an AWS account ref. `region` is the region THE VMs ARE
    PLACED IN, not the environment's home region.

    ⛔ BOTH ARGUMENTS ARE REQUIRED AND AN EMPTY ONE IS A REFUSAL. The empty-region
    case is the defect this function exists to make unspellable: a bucket name
    with no region in it cannot disagree with the region a VM is placed in, so a
    VM can silently fetch its loader cross-region. A cross-region boot fetch is
    a single-region dependency on the one hop that starts compute — every VM job
    in the placement region fails to boot during an outage of a region nobody
    chose. Making the region a required argument means the mismatch cannot be
    reintroduced by omission; it would have to be typed.

    REFUSES a name that is not usable as a bucket on BOTH clouds (lowercase,
    digits, hyphens; <= 63 chars) — a derivation error here costs nothing, the
    same string rejected by a create call costs a round trip inside a deploy."""
    if account_ref.byte_length() == 0:
        raise Error(
            "boot_bundle_bucket: REFUSED to derive a boot-artifact bucket with"
            " no account reference. The bucket is per (account, region) and an"
            " unnamed account would collapse every environment's boot artifact"
            " into one bucket name."
        )
    if region.byte_length() == 0:
        raise Error(
            String(
                "boot_bundle_bucket: REFUSED to derive a boot-artifact bucket"
                " for account '"
            )
            + account_ref
            + String(
                "' with NO REGION. A boot bundle is fetched by a VM at boot, so"
                " the bucket must be in the region the VM is placed in — an"
                " unregioned name lets a VM in one region fetch its loader from"
                " a bucket in another, making every job in the placement region"
                " depend on a region nobody chose. Pass the PLACEMENT region."
            )
        )
    if not _is_bucket_safe(account_ref) or not _is_bucket_safe(region):
        raise Error(
            String("boot_bundle_bucket: '")
            + account_ref
            + String("' / '")
            + region
            + String(
                "' — a boot-artifact bucket name must be lowercase letters,"
                " digits and hyphens only (the intersection of the GCS and S3"
                " bucket alphabets), because the SAME derivation names the"
                " bucket on both clouds."
            )
        )
    var name = (
        account_ref
        + String("-")
        + BOOT_BUNDLE_BUCKET_INFIX
        + String("-")
        + region
    )
    if name.byte_length() > _BUCKET_NAME_MAX:
        raise Error(
            String("boot_bundle_bucket: derived name '")
            + name
            + String("' is ")
            + String(name.byte_length())
            + String(
                " bytes, over the 63-byte bucket-name cap both clouds enforce."
            )
        )
    return name^


# -----------------------------------------------------------------------------
# §3 — the object key. Content-addressed, one object per distinct bundle.
# -----------------------------------------------------------------------------

comptime BOOT_BUNDLE_KEY_PREFIX: String = "pod-loader/sha256"
"""The key prefix every boot bundle lives under. Named `sha256` in the path so
the digest algorithm is READABLE from a bucket listing."""

comptime BOOT_BUNDLE_BASENAME: String = "bootstrap_bundle.tar.gz"
"""The object's terminal segment. ⚠ IT IS THE REAL FILE NAME, not an opaque
content-hash leaf, because the boot script saves it to disk and `tar -xzf`s it —
and because an operator looking at a bucket has to be able to tell what the
object is. (This is why the boot bundle is NOT stored through
`komira_blob_cas.ContentAddressedBlobStore`, whose key layout ends `.blob`.)"""

comptime _SHA256_HEX_LEN: Int = 64


def _is_lower_hex(s: String) -> Bool:
    """True iff every byte of `s` is `0-9` or `a-f`. Lowercase only: the digest
    is rendered lowercase, so an uppercase one means a second hex-rendering
    recipe is in use and the two would key different objects for identical
    bytes."""
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        var digit = c >= UInt8(ord("0")) and c <= UInt8(ord("9"))
        var af = c >= UInt8(ord("a")) and c <= UInt8(ord("f"))
        if not (digit or af):
            return False
    return True


def boot_bundle_key(digest_hex: String) raises -> String:
    """The object key for the boot bundle whose content SHA-256 is `digest_hex`:
    `pod-loader/sha256/<digest>/bootstrap_bundle.tar.gz`.

    CONTENT-ADDRESSED: the key is a pure function of the BYTES, so republishing
    an unchanged bundle is a no-op and two different bundles can never occupy the
    same key. There is no version, no tag and no `latest` — see the module
    header.

    ⛔ REFUSES anything that is not 64 lowercase hex characters. A short or
    non-hex digest would still produce a syntactically valid key, and the object
    would publish and fetch — it would just no longer be addressed by its
    content, which is the only property that makes republication safe."""
    if digest_hex.byte_length() != _SHA256_HEX_LEN or not _is_lower_hex(
        digest_hex
    ):
        raise Error(
            String("boot_bundle_key: '")
            + digest_hex
            + String(
                "' is not a 64-character lowercase SHA-256 hex digest. The boot"
                " bundle key IS its content hash; a key derived from anything"
                " else publishes and fetches perfectly while silently no longer"
                " being content-addressed, so two different bundles could share"
                " one key."
            )
        )
    return (
        BOOT_BUNDLE_KEY_PREFIX
        + String("/")
        + digest_hex
        + String("/")
        + BOOT_BUNDLE_BASENAME
    )


# -----------------------------------------------------------------------------
# §4 — the URL, and the ONE machine-parsed line the publisher prints.
# -----------------------------------------------------------------------------

comptime PUBLISHED_BOOT_BUNDLE_URL_PREFIX: String = "PUBLISHED_BOOT_BUNDLE_URL="
"""The ONE machine-parsed stdout contract line the publish step emits, carrying
the fully-resolved URL a placement conformer is then constructed with. One
marker, LAST match wins, and the value is a complete fetchable reference rather
than a fragment the reader has to reassemble."""


def boot_bundle_url(scheme: String, bucket: String, key: String) raises -> String:
    """`<scheme>://<bucket>/<key>` — the value a placement conformer is
    constructed with and a boot script fetches.

    ⛔ REFUSES a scheme that is neither `gs` nor `s3`. Those are exactly the two
    arms the two renderers dispatch on; a third scheme is not a download that
    fails, it is a `curl` of something that is not a URL on a machine that then
    has nothing to run and bills by the hour. REFUSES an empty bucket or key for
    the same reason — `gs:///key` is a well-formed string and a 404."""
    if scheme != BOOT_BUNDLE_SCHEME_GS and scheme != BOOT_BUNDLE_SCHEME_S3:
        raise Error(
            String("boot_bundle_url: scheme '")
            + scheme
            + String("' is neither '")
            + BOOT_BUNDLE_SCHEME_GS
            + String("' nor '")
            + BOOT_BUNDLE_SCHEME_S3
            + String(
                "'. Those are the only two a rendered boot script can fetch: EC2"
                " user-data dispatches s3:// to `aws s3 cp` and a GCE startup"
                " script dispatches gs:// to the instance metadata token. A URL"
                " neither recognises reaches the fallback `curl` as a string"
                " that is not a URL."
            )
        )
    if bucket.byte_length() == 0 or key.byte_length() == 0:
        raise Error(
            String("boot_bundle_url: REFUSED to render '")
            + scheme
            + String("://")
            + bucket
            + String("/")
            + key
            + String(
                "' — an empty bucket or key produces a well-formed URL that is a"
                " guaranteed 404 at boot."
            )
        )
    return scheme + String("://") + bucket + String("/") + key
