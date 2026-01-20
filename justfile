# Export default package version (can be overridden by setting GNOSISVPN_PACKAGE_VERSION)
export GNOSISVPN_PACKAGE_VERSION := env_var_or_default('GNOSISVPN_PACKAGE_VERSION', `date +%Y.%m.%d+build.%H%M%S`)

# Download binaries from GCP
download distribution arch:
    ./scripts/download-binaries.sh --distribution {{ distribution }} --architecture {{ arch }}

# Generate changelog
changelog:
    ./scripts/generate-changelog.sh

# Generate manual pages for binaries
manual:
    ./scripts/generate-manual.sh

# Build package for GitHub releases (assumes binaries, changelog, and manual already exist)
package distribution arch sign="false":
    #!/usr/bin/env bash
    set -o errexit -o nounset -o pipefail
    SIGN_FLAG=$([ "{{ sign }}" = "true" ] && echo "--sign" || echo "")
    ./scripts/generate-package.sh \
        --package-version "${GNOSISVPN_PACKAGE_VERSION}" \
        --distribution {{ distribution }} \
        --architecture {{ arch }} \
        $SIGN_FLAG

all distribution arch sign="false":
    #!/usr/bin/env bash
    set -o errexit -o nounset -o pipefail
    just download {{ distribution }} {{ arch }}
    if [ "{{ arch }}" =~ ^(x86_64-linux)$ ]; then
        just changelog
        just manual
    fi
    just package {{ distribution }} {{ arch }} {{ sign }}
