#!/bin/bash
#
# Shared helpers for the Linux maintainer scripts.
#
# nfpm embeds every maintainer script on its own, and %pre runs before any package file exists, so the scripts
# cannot source this file at install time. generate-package-linux.sh inlines it into each script at build time
# instead (see render_maintainer_scripts in scripts/common.sh).

# How the package manager invoked the script, from its first argument.
#   phase "install" (pre/postinstall): rpm passes 1 on a fresh install, 2+ when another version is installed.
#   phase "remove" (pre/postuninstall): rpm passes 0 on erase, 1+ when another version stays installed.
# dpkg passes action words (configure, upgrade, remove, purge, ...), so anything non-numeric is dpkg.
scriptlet_mode() {
    local phase="$1" arg="${2:-}"
    if [[ ! $arg =~ ^[0-9]+$ ]]; then
        echo "dpkg"
    elif [[ $phase == "install" ]]; then
        if [[ $arg -le 1 ]]; then echo "rpm-install"; else echo "rpm-upgrade"; fi
    else
        if [[ $arg -eq 0 ]]; then echo "rpm-erase"; else echo "rpm-upgrade"; fi
    fi
}

is_rpm_mode() {
    [[ $1 == rpm-* ]]
}

# Debian ships deb-systemd-* wrappers that honour policy-rc.d; other hosts use systemctl directly.
service_stop() {
    if command -v deb-systemd-invoke >/dev/null 2>&1; then
        deb-systemd-invoke stop "$@"
    else
        systemctl stop "$@"
    fi
}

service_kill() {
    if command -v deb-systemd-invoke >/dev/null 2>&1; then
        deb-systemd-invoke kill "$@"
    else
        systemctl kill "$@"
    fi
}

service_disable() {
    if command -v deb-systemd-helper >/dev/null 2>&1; then
        deb-systemd-helper disable "$@"
    else
        systemctl disable "$@"
    fi
}

systemd_daemon_reload() {
    # deb-systemd-helper has no daemon-reload action; callers tolerate a host without a running systemd.
    systemctl daemon-reload
}
