#!/bin/bash

configure_logging_profile() {
    local plist="$1"
    local loglevel="$2"
    local updated_plist

    updated_plist="$(mktemp "${plist}.XXXXXX")"
    if [[ "$loglevel" == "debug" ]]; then
        sed \
            -e '/<key>RUST_LOG<\/key>/{n;s|<string>[^<]*</string>|<string>info,hopr_transport_session=debug,hopr_protocol_session=debug,hopr_protocol_start=debug,hopr_network_types=debug,gnosis_vpn_root=debug,gnosis_vpn_lib=debug</string>|;}' \
            -e '/<key>RUST_BACKTRACE<\/key>/{n;s|<string>[^<]*</string>|<string>full</string>|;}' \
            "$plist" >"$updated_plist"
    else
        sed \
            -e '/<key>RUST_LOG<\/key>/{n;s|<string>[^<]*</string>|<string>info,hopr_transport=debug,hopr_network_graph=debug</string>|;}' \
            -e '/<key>RUST_BACKTRACE<\/key>/{n;s|<string>[^<]*</string>|<string>full</string>|;}' \
            "$plist" >"$updated_plist"
    fi
    cat "$updated_plist" >"$plist"
    rm -f "$updated_plist"
}
