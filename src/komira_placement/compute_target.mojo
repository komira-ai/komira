# =============================================================================
# komira_placement/compute_target.mojo — WHERE a job-VM placement lands, as
#   RESOLVED FROM THE CUSTOMER'S `compute-env/<env>` RECORD.
# =============================================================================
#
# The placement seam's carrier for a customer compute environment.
# `PlacementSpec.compute_target` defaults to ABSENT, and a conformer handed no
# target keeps placing exactly where its construction state says. The job
# manager is the writer — it resolves the record into this value under its
# fences — and a VM conformer the reader (`GcpCloudProvider.create` inserts at
# `project`/`zone` with `subnetwork` as the ONLY network field on the
# interface).
#
# ⛔ IT IS RESOLVED, NEVER AUTHORED. None of the four values comes from the job
# request or a beat: a job request names only the ENVIRONMENT, and the job
# manager derives these from the control-plane-owned record and re-checks each
# against the compute-environment naming functions by POSITIVE equality. A value
# here that did not come through that resolution is the defect those checks
# exist to refuse.
#
# ⛔ AND IT IS **NOT** THE TEARDOWN ADDRESS. Every address verb takes the row's
# job-manager-written `placement_ref`, never a re-read record and never this
# struct: a record rewritten after placement must not be able to redirect a
# delete.
#
# gap6-clean: four owned Strings, no pointer, no heap-owning container beyond
# `String`. Not stored in any byte slab.
# =============================================================================


struct ComputeTarget(Copyable, Movable):
    """The customer project, zone, subnetwork and runtime service account a VM
    job places into — resolved from `compute-env/<env>`.

    `subnetwork` is the full resource path
    (`projects/<p>/regions/<r>/subnetworks/<name>`): GCE infers the network
    from it, which is what lets the customer's placement role omit
    `compute.networks.use`. `service_account` is the VM SA's
    EMAIL (`<vm-sa>@<p>.iam.gserviceaccount.com`)."""

    var project: String
    var zone: String
    var subnetwork: String
    var service_account: String

    def __init__(
        out self,
        project: String,
        zone: String,
        subnetwork: String,
        service_account: String,
    ):
        """All four, stated. No defaults: a target missing any of the four is not
        a target, and a defaulted field here would be a placement into whatever
        the default names."""
        self.project = project
        self.zone = zone
        self.subnetwork = subnetwork
        self.service_account = service_account

    def is_complete(self) -> Bool:
        """True iff all four are non-empty — the only shape a VM conformer may
        place at. A conformer handed an incomplete target REFUSES, naming the
        empty field; it never fills one in from its own construction state."""
        return (
            self.project.byte_length() > 0
            and self.zone.byte_length() > 0
            and self.subnetwork.byte_length() > 0
            and self.service_account.byte_length() > 0
        )
