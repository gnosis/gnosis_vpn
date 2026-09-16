#!/usr/bin/env bats
#
# Unit tests for the pure helpers of scripts/publish-rpm.sh.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=../publish-rpm.sh
    source "${REPO_ROOT}/scripts/publish-rpm.sh"
}

@test "parse_rpm_filename splits version and arch" {
    run parse_rpm_filename gnosisvpn-0.94.2-1.x86_64.rpm
    [ "$status" -eq 0 ]
    [ "$output" = "0.94.2 x86_64" ]
    run parse_rpm_filename gnosisvpn-2026.09.14+build.010203.experimental-1.aarch64.rpm
    [ "$output" = "2026.09.14+build.010203.experimental aarch64" ]
}

@test "parse_rpm_filename rejects other names" {
    local name
    for name in gnosisvpn_0.94.2_amd64.deb gnosisvpn-0.94.2-2.x86_64.rpm gnosisvpn-0.94.2-1.noarch.rpm other-0.94.2-1.x86_64.rpm; do
        run parse_rpm_filename "$name"
        [ "$status" -eq 1 ]
    done
}

@test "repodata_hrefs lists the metadata files a repomd.xml references" {
    cat >"${BATS_TEST_TMPDIR}/repomd.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<repomd xmlns="http://linux.duke.edu/metadata/repo">
  <data type="primary">
    <location href="repodata/aaa-primary.xml.zst"/>
  </data>
  <data type="filelists">
    <location href="repodata/bbb-filelists.xml.zst"/>
  </data>
</repomd>
EOF
    run repodata_hrefs "${BATS_TEST_TMPDIR}/repomd.xml"
    [ "$output" = $'aaa-primary.xml.zst\nbbb-filelists.xml.zst' ]
}

@test "repodata_hrefs prints nothing for a missing repomd.xml" {
    run repodata_hrefs "${BATS_TEST_TMPDIR}/missing.xml"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "stale_repodata_objects keeps referenced files and the repomd pair" {
    local listing referenced
    listing=$'gs://b/rpm/stable/repodata/aaa-primary.xml.zst\ngs://b/rpm/stable/repodata/old-primary.xml.zst\ngs://b/rpm/stable/repodata/repomd.xml\ngs://b/rpm/stable/repodata/repomd.xml.asc\ngs://b/rpm/stable/repodata/ccc-other.xml.zst'
    referenced=$'aaa-primary.xml.zst\nccc-other.xml.zst'
    run stale_repodata_objects "$listing" "$referenced"
    [ "$output" = "gs://b/rpm/stable/repodata/old-primary.xml.zst" ]
}
