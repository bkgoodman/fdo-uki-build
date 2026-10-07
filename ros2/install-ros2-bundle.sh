#!/bin/sh
#
# Install ROS 2 from the FDO-delivered offline apt bundle. Shipped inside the
# bundle; run in the installed target (curtin in-target) from autoinstall
# late-commands, after the bundle was unpacked to /var/lib/fdo-ros2.
#
# apt only sees the bundle's local repo (plus the target's dpkg status): its
# own source list, no sources.list.d, and a private lists directory, so the
# install never touches the network and leaves the target's apt state alone.
# The repo is [trusted=yes]: its integrity comes from the FDO payload hash
# (owner-verified in TO2) and SHA256SUMS below; the build verified every .deb
# against the signed ROS / Ubuntu snapshot indexes when it was downloaded.

set -eu

BUNDLE=$(cd "$(dirname "$0")" && pwd)
cd "$BUNDLE"

echo "FDO ROS 2: verifying bundle"
cat BUNDLE-INFO
sha256sum --quiet --strict -c SHA256SUMS

mkdir -p lists/partial no-parts
printf 'deb [trusted=yes] file:%s/repo ./\n' "$BUNDLE" > bundle.list
set -- \
    -o Dir::Etc::SourceList="$BUNDLE/bundle.list" \
    -o Dir::Etc::SourceParts="$BUNDLE/no-parts" \
    -o Dir::State::Lists="$BUNDLE/lists" \
    -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= \
    -o Acquire::Languages=none

apt-get "$@" update
# shellcheck disable=SC2046 # word splitting of the package list is intended
DEBIAN_FRONTEND=noninteractive apt-get "$@" install -y --no-install-recommends $(cat packages.txt)

for deb in extra/*.deb; do
    [ -e "$deb" ] || continue
    echo "FDO ROS 2: installing $(basename "$deb")"
    dpkg -i "$deb"
done

# Keep the manifest for auditing; drop the 100+ MiB of package files.
rm -rf repo extra lists no-parts bundle.list
apt-get clean
echo "FDO ROS 2: installed $(tr '\n' ' ' < packages.txt)"
