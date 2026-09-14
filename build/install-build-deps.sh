#!/bin/sh
# Install everything needed to build the gridengine RPMs on EL9 or EL10 (Rocky Linux 9, 10).
# Run as root, on the machine or in the container that will do the build.
#
# Some of the packages live outside the repositories a minimal install enables, so
# this has to turn those on and check that it worked:
#
#   crb    libtirpc-devel, munge-devel  --  on both EL9 and EL10
#   epel   libdb-devel, motif-devel  --  EL10 only, where RHEL ships neither
#          Berkeley DB nor Motif; on EL9 appstream has both
#
# So EPEL is mandatory on EL10 and not wanted on EL9.  jemalloc used to be the one
# EPEL package on EL9, and gridengine.spec no longer links it (see the comment
# there); "rpmbuild --with jemalloc" still does, and then needs jemalloc-devel,
# which is in EPEL on both.
#
# A missing EPEL on EL10 does not fail here.  It fails later, in the rpm
# transaction, with "no match for argument: libdb-devel", a long way from the
# cause -- hence the explicit check below.

set -eu

[ "$(id -u)" = 0 ] || { echo "$0: must run as root" >&2; exit 1; }

el=
if [ -r /etc/os-release ]; then
   . /etc/os-release
   el=${VERSION_ID%%.*}
fi
case $el in
   [0-9]*) ;;
   *) echo "$0: cannot tell which EL version this is (/etc/os-release)" >&2; exit 1 ;;
esac
if [ "$el" -lt 9 ]; then
   cat >&2 <<EOF
$0: this list is for EL9 and later; found EL$el.

EL6-EL8 build with the upstream dependency set, whose package names differ
(db4-devel, lesstif-devel, no libtirpc).  There, install a toolchain and let rpm
resolve the spec's own BuildRequires:

  dnf -y install dnf-plugins-core gcc gcc-c++ make rpm-build git
  dnf -y builddep gridengine.spec
EOF
   exit 1
fi

if [ "$el" -ge 10 ]; then
   dnf -y install epel-release dnf-plugins-core
   want_repos='crb epel'
else
   dnf -y install dnf-plugins-core
   want_repos=crb
fi
dnf config-manager --set-enabled crb

# Fail now, with a readable message, rather than at the end of the build.
for repo in $want_repos; do
   dnf repolist --enabled | awk '{print $1}' | grep -qx "$repo" ||
      { echo "$0: repository '$repo' is not enabled -- see the comment at the top" >&2; exit 1; }
done

# The set the EL9 and EL10 builds are verified against.  Which repository provides
# what differs between the two -- crb has libtirpc-devel and munge-devel on both,
# while libdb-devel and motif-devel come from appstream on EL9 and from epel on
# EL10 -- so the list is deliberately flat and lets dnf pick.
dnf -y install \
    gcc gcc-c++ make patch tar which diffutils file \
    perl python3 tcsh net-tools hostname \
    git rpm-build \
    openssl-devel ncurses-devel pam-devel \
    hwloc-devel libdb-devel motif-devel libXmu-devel \
    libtirpc-devel munge-devel

# Not installed on purpose: java-devel, javacc, ant-junit.  Neither EL9 nor EL10 has
# ant-nodeps or swing-layout, so gridengine.spec builds --without java there and the
# guiinst subpackage cannot be produced.  Nothing in Cloud Pipeline uses it.

echo
echo "Build dependencies installed.  Next: build/build-rpm.sh"
