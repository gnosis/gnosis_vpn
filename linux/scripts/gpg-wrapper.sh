#!/bin/bash
echo "${GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD}" | /usr/bin/gpg --batch --pinentry-mode loopback --passphrase-fd 0 "$@"
