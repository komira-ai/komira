# komira_awslc: aws-lc's libcrypto as a static archive (libawslc.a), every global symbol renamed komira_awslc_X.
#
# The package has no Mojo code of its own. Its library is the archive: `mojo_package` links it into the tests of
# the package and of every package that depends on it (komira_crypto, komira_uuid), so a program that holds several
# of them links one copy. Callers declare the C names they use (komira_awslc_SHA256, ...) in the module that owns
# the foreign resource, as komira_crypto does.
