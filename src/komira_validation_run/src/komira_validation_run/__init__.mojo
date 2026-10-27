# =============================================================================
# komira_validation_run — the VALIDATION-RUN CORRELATOR.
#
# ONE package holding ONE fact: the shape of the tag/label key (a caller-chosen
# prefix plus a fixed suffix) under which a validation run stamps its own identity onto every billable cloud resource it creates, so that
# an unattended cleanup can act on what it can PROVE it made instead of on
# everything it can see.
#
# It exists so that an unattended cleanup can tell a resource its own run
# created from one a concurrent run created. See `validation_run_tag.mojo`'s
# header for the hazard, the two cloud character-set rules that picked the
# spelling, and why the package has no deps.
# =============================================================================
