#!/bin/sh
# Build the EL9 RPMs from any workstation with docker, without installing a
# toolchain on it:
#
#   build/build-in-container.sh            # -> RPMS/
#   build/build-in-container.sh --tar      # -> RPMS/, plus the tar Cloud Pipeline consumes
#
# Arguments are passed through to build/build-rpm.sh.
#
# --platform linux/amd64 is not optional.  Cloud Pipeline hardcodes
# /opt/sge/bin/lx-amd64 in three setup scripts, so the packages must be x86_64 even
# when the workstation is arm64; Docker Desktop and colima emulate it (Rosetta on
# Apple silicon, which is why this takes minutes rather than hours).
#
# Override the image with SGE_BUILD_IMAGE, e.g. to build for a different EL major:
#   SGE_BUILD_IMAGE=rockylinux:10 build/build-in-container.sh

set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image=${SGE_BUILD_IMAGE:-rockylinux:9}

command -v docker >/dev/null || { echo "${0##*/}: docker not found" >&2; exit 1; }

# Scratch space stays inside the container; only the finished RPMs come back out,
# and they are chowned to whoever owns the mount, so the build does not leave
# root-owned files in the checkout.
#
# GIT_CONFIG_* is needed because build-rpm.sh runs git as root against a checkout
# owned by another uid, which git refuses as "dubious ownership".
docker run --rm --platform linux/amd64 \
   -v "$repo:/src" -w /src \
   -e GIT_CONFIG_COUNT=1 \
   -e GIT_CONFIG_KEY_0=safe.directory \
   -e GIT_CONFIG_VALUE_0=/src \
   "$image" \
   sh -euc '
      build/install-build-deps.sh
      build/build-rpm.sh -t /tmp/rpmbuild -o /src/RPMS "$@"
      chown -R "$(stat -c %u:%g /src)" /src/RPMS
   ' sh "$@"

echo
echo "Done.  RPMs are in $repo/RPMS"
