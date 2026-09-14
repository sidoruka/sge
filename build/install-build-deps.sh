#!/bin/sh
# Install everything needed to build the gridengine RPMs on EL9 (Rocky Linux 9+).
# Run as root, on the machine or in the container that will do the build.
#
# Two of the packages live outside the repositories a minimal install enables, so
# this has to turn that repository on and check that it worked:
#
#   crb    libtirpc-devel, munge-devel
#
# Nothing here comes from EPEL, and the default build needs none: jemalloc was the
# only EPEL package, and gridengine.spec no longer links it (see the comment there).
# "rpmbuild --with jemalloc" still does, and then needs epel-release enabled and
# jemalloc-devel installed on top of this set.

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

dnf -y install dnf-plugins-core
dnf config-manager --set-enabled crb

# Fail now, with a readable message, rather than at the end of the build.
dnf repolist --enabled | awk '{print $1}' | grep -qx crb ||
   { echo "$0: repository 'crb' is not enabled -- see the comment at the top" >&2; exit 1; }

# The set the EL9 build is verified against.  Where a package is not in baseos or
# appstream, its repository is named.
dnf -y install \
    gcc gcc-c++ make patch tar which diffutils file \
    perl python3 tcsh net-tools hostname \
    git rpm-build \
    openssl-devel ncurses-devel pam-devel \
    hwloc-devel libdb-devel motif-devel libXmu-devel \
    libtirpc-devel munge-devel

# Not installed on purpose: java-devel, javacc, ant-junit.  EL9 has no ant-nodeps
# and no swing-layout, so gridengine.spec builds --without java there and the
# guiinst subpackage cannot be produced.  Nothing in Cloud Pipeline uses it.

echo
echo "Build dependencies installed.  Next: build/build-rpm.sh"
