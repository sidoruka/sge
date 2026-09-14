#!/bin/sh
# Build the gridengine RPMs from this checkout.
#
#   build/install-build-deps.sh     # once, as root
#   build/build-rpm.sh              # -> RPMS/*.rpm
#
# Run it on the distribution you want the packages for: rpm stamps them with the
# %dist of the build host, so EL9 packages have to be built on EL9.  They also have
# to be x86_64 -- Cloud Pipeline hardcodes /opt/sge/bin/lx-amd64 in three of its
# setup scripts, so an arm64 build would install but find no binaries.
#
# build/build-in-container.sh does both of those for you, from any workstation.

set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
spec=$repo/gridengine.spec

topdir=
outdir=
source=HEAD
worktree=no
maketar=no

usage() {
   cat <<EOF
usage: ${0##*/} [-o DIR] [-t DIR] [-w] [--tar]

  -o DIR   collect the finished RPMs here      (default: $repo/RPMS)
  -t DIR   rpmbuild topdir, i.e. scratch space (default: $repo/rpmbuild)
  -w       build the working tree instead of HEAD.  Uncommitted changes to tracked
           files are included; untracked files are not (they are invisible to git,
           so add them before using this).
  --tar    also pack the runtime RPMs the way Cloud Pipeline consumes them:
           sge-<version>-<release>.<dist>.<arch>.tar, holding one directory of
           RPMs.  The -debuginfo and -debugsource packages are left out of the tar
           -- they are 20MB that every cluster node would download and no part of
           the platform reads.  They are still in the -o directory if you want them.
EOF
}

while [ $# -gt 0 ]; do
   case $1 in
      -o) outdir=$2; shift 2 ;;
      -t) topdir=$2; shift 2 ;;
      -w) worktree=yes; source='the working tree'; shift ;;
      --tar) maketar=yes; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "${0##*/}: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
   esac
done

: "${topdir:=$repo/rpmbuild}"
: "${outdir:=$repo/RPMS}"

for cmd in git rpmbuild; do
   command -v "$cmd" >/dev/null ||
      { echo "${0##*/}: $cmd not found -- run build/install-build-deps.sh first" >&2; exit 1; }
done
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 ||
   { echo "${0##*/}: $repo is not a git checkout, and the source tarball is built with git archive" >&2; exit 1; }

# Take the version from the spec, so the tarball name, the directory %setup expects
# and the package version cannot drift apart.
version=$(sed -n 's/^Version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$spec")
release=$(sed -n 's/^Release:[[:space:]]*\([^%[:space:]]*\).*/\1/p' "$spec")
[ -n "$version" ] && [ -n "$release" ] ||
   { echo "${0##*/}: cannot read Version/Release out of $spec" >&2; exit 1; }

tarball=$topdir/SOURCES/sge-$version.tar.gz
rm -rf "$topdir/BUILD" "$topdir/BUILDROOT" "$topdir/RPMS" "$topdir/SRPMS"
mkdir -p "$topdir/SOURCES" "$topdir/SPECS" "$outdir"

echo "Packing sge-$version from $source"
if [ "$worktree" = yes ]; then
   ( cd "$repo" && git ls-files -z |
        tar -czf "$tarball" --null -T - --transform "s,^,sge-$version/," )
else
   # Refresh first: diff-index compares the index's cached stat info, and a checkout
   # bind-mounted into a container shows up with a different uid, which looks like a
   # modification until the index is refreshed against the actual contents.
   git -C "$repo" update-index -q --refresh 2>/dev/null || :
   git -C "$repo" diff-index --quiet HEAD -- ||
      echo "${0##*/}: warning: the working tree is dirty; building HEAD anyway (-w builds the tree)" >&2
   git -C "$repo" archive --format=tar.gz --prefix="sge-$version/" -o "$tarball" HEAD
fi

cp "$spec" "$topdir/SPECS/gridengine.spec"

echo "Building gridengine-$version-$release  (topdir $topdir)"
rpmbuild --define "_topdir $topdir" -bb "$topdir/SPECS/gridengine.spec"

find "$topdir/RPMS" -name '*.rpm' -exec cp -p {} "$outdir/" \;

if [ "$maketar" = yes ]; then
   dist=$(rpm --eval '%{?dist}')
   arch=$(rpm --eval '%{_arch}')
   payload=sge-$version-$release
   tar=$outdir/$payload$dist.$arch.tar
   staging=$topdir/tar

   rm -rf "$staging"
   mkdir -p "$staging/$payload"
   # Pack what this build produced, i.e. rpmbuild's own output directory.  The -o
   # directory accumulates instead: build for EL9 and then for EL10 with the same
   # -o, and globbing it would put both distributions' packages in one payload.
   find "$topdir/RPMS" -name '*.rpm' \
        ! -name '*-debuginfo-*' ! -name '*-debugsource-*' \
        -exec cp -p {} "$staging/$payload/" \;
   ( cd "$staging" && tar -cf "$tar" "$payload" )
   rm -rf "$staging"
   echo
   echo "Payload: $tar"
   tar -tf "$tar" | sed 's/^/  /'
fi

echo
echo "RPMs in $outdir:"
ls -1 "$outdir" | sed 's/^/  /'
