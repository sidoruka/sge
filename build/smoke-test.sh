#!/bin/sh
# End-to-end check of the packages build/build-rpm.sh produced: install the tar
# payload into a bare container of the distribution it was built for, auto-install a
# qmaster and an execd from one grid.conf, run a job as an unprivileged user, and
# read back the three XML queries Cloud Pipeline's autoscaler parses.
#
#   build/build-rpm.sh --tar                                 # the payload it needs
#   build/smoke-test.sh                                      # -> rockylinux:9
#   SGE_TEST_IMAGE=rockylinux/rockylinux:10.2 build/smoke-test.sh
#
# Run it on the image the packages were built for: it asserts that every package is
# stamped with that host's %dist, so an el9 payload tested on EL10 fails by design.
#
# --here runs the checks against the machine it is called on instead of starting a
# container.  That is how it re-enters itself above, and how to run it on a real EL
# host or in CI, where there is no docker to nest.

set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image=${SGE_TEST_IMAGE:-rockylinux:9}
outdir=
here=no

usage() {
   cat <<EOF
usage: ${0##*/} [-o DIR] [--here]

  -o DIR   the directory build-rpm.sh wrote to  (default: $repo/RPMS)
  --here   run the checks on this machine rather than in a container

Override the image with SGE_TEST_IMAGE (default: $image).
EOF
}

while [ $# -gt 0 ]; do
   case $1 in
      -o) outdir=$2; shift 2 ;;
      --here) here=yes; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "${0##*/}: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
   esac
done

: "${outdir:=$repo/RPMS}"

# ---------------------------------------------------------------------- outer half
# Same --platform reasoning as build-in-container.sh: the packages are x86_64
# because Cloud Pipeline hardcodes /opt/sge/bin/lx-amd64, so they have to be tested
# on x86_64 even from an arm64 workstation.
if [ "$here" = no ]; then
   command -v docker >/dev/null || { echo "${0##*/}: docker not found" >&2; exit 1; }
   [ -d "$outdir" ] || { echo "${0##*/}: no such directory: $outdir" >&2; exit 1; }
   ls "$outdir"/sge-*.tar >/dev/null 2>&1 ||
      { echo "${0##*/}: no tar payload in $outdir -- build with --tar first" >&2; exit 1; }

   echo "${0##*/}: testing $outdir in $image"
   exec docker run --rm --platform linux/amd64 --hostname sgesmoke \
      -v "$outdir:/rpms:ro" \
      -v "$0:/smoke-test.sh:ro" \
      "$image" /smoke-test.sh --here -o /rpms
fi

# ---------------------------------------------------------------------- inner half
el=$(. /etc/os-release; echo "${VERSION_ID%%.*}")
me=${0##*/}
step=0

say()  { step=$((step + 1)); echo; echo "=== $step. $* ==="; }
fail() { echo "$me: FAIL: $*" >&2; exit 1; }
ok()   { echo "   ok -- $*"; }

echo "### $me on EL$el, $(uname -m), host $(hostname 2>/dev/null || echo '?')"

# The claim under test: EL9 needs nothing beyond baseos and appstream, EL10 needs
# EPEL because RHEL 10 ships neither Berkeley DB nor Motif.  crb is a *build*
# repository and is deliberately left disabled -- no runtime dependency may need it.
say "repositories"
dnf -y install dnf-plugins-core >/dev/null
# Scaffolding for this script, not gridengine dependencies: hostname and pgrep drive
# the checks, python3 parses the XML at the end.
dnf -y install hostname procps-ng python3 >/dev/null
if [ "$el" -ge 10 ]; then
   dnf -y install epel-release >/dev/null
   ok "EL10: epel enabled (libdb, libdb-utils, motif and libXp come from it)"
else
   ok "EL9: baseos and appstream only -- no crb, no epel"
fi
echo "   enabled: $(dnf repolist --enabled 2>/dev/null | awk 'NR>1{print $1}' | tr '\n' ' ')"

say "unpack the payload"
tar=$(ls "$outdir"/sge-*.tar) || fail "no tar payload in $outdir"
mkdir -p /pkgs && tar -xf "$tar" -C /pkgs
pkgdir=$(ls -d /pkgs/*/)
echo "   $(basename "$tar")"
ls -1 "$pkgdir" | sed 's/^/     /'
[ "$(ls -1 "$pkgdir" | wc -l)" -eq 6 ] || fail "expected 6 runtime packages in the payload"
ls "$pkgdir" | grep -q debuginfo && fail "payload contains debuginfo packages"
ok "6 runtime packages, no debuginfo"

say "dist tag"
for r in "$pkgdir"*.rpm; do
   rel=$(rpm -qp --qf '%{RELEASE}' "$r" 2>/dev/null)
   case $rel in
      *.el$el) ;;
      *) fail "$(basename "$r") has release '$rel', expected .el$el" ;;
   esac
done
ok "every package is stamped .el$el"

# The whole point of not passing aimk -with-jemalloc: see gridengine.spec.
say "jemalloc is not linked"
if rpm -qpR "$pkgdir"*.rpm 2>/dev/null | grep -i jemalloc; then
   fail "a package still requires jemalloc"
fi
ok "no package requires libjemalloc"

say "install"
dnf -y install "$pkgdir"*.rpm
for p in gridengine gridengine-qmaster gridengine-execd gridengine-qmon \
         gridengine-devel gridengine-drmaa4ruby; do
   rpm -q "$p" >/dev/null || fail "$p is not installed"
done
ok "all six install, every dependency resolved from the repositories above"
id sgeadmin >/dev/null 2>&1 || fail "%pre did not create sgeadmin"
ok "sgeadmin exists: $(id sgeadmin)"

# The paths Cloud Pipeline hardcodes.
[ -x /opt/sge/bin/lx-amd64/sge_qmaster ] || fail "no /opt/sge/bin/lx-amd64/sge_qmaster"
[ -x /opt/sge/bin/lx-amd64/qstat ]       || fail "no /opt/sge/bin/lx-amd64/qstat"
ok "/opt/sge/bin/lx-amd64 is populated"

# qmon links Motif, which on EL10 comes from EPEL.  Prove the link resolves.
ldd /opt/sge/bin/lx-amd64/qmon 2>/dev/null | grep -q 'not found' &&
   fail "qmon has unresolved shared libraries"
ok "qmon's shared libraries all resolve"

# A grid.conf built from the template the packages ship, so the two cannot drift.
say "auto-install qmaster and execd"
h=$(hostname)
conf=/tmp/grid.conf
sed -e 's|^SGE_JMX_PORT=.*|SGE_JMX_PORT="6666"|' \
    -e 's|^SGE_JMX_SSL_KEYSTORE=.*|SGE_JMX_SSL_KEYSTORE=""|' \
    -e 's|^SGE_JMX_SSL_KEYSTORE_PW=.*|SGE_JMX_SSL_KEYSTORE_PW=""|' \
    -e 's|^SGE_JVM_LIB_PATH=.*|SGE_JVM_LIB_PATH=""|' \
    -e "s|^ADMIN_HOST_LIST=.*|ADMIN_HOST_LIST=\"$h\"|" \
    -e "s|^SUBMIT_HOST_LIST=.*|SUBMIT_HOST_LIST=\"$h\"|" \
    -e "s|^EXEC_HOST_LIST=.*|EXEC_HOST_LIST=\"$h\"|" \
    -e 's|^ADD_TO_RC=.*|ADD_TO_RC="false"|' \
    -e 's|^REMOVE_RC=.*|REMOVE_RC="false"|' \
    -e 's|^ADMIN_MAIL=.*|ADMIN_MAIL="none"|' \
    -e 's|^DEFAULT_DOMAIN=.*|DEFAULT_DOMAIN="none"|' \
    -e 's|^HOSTNAME_RESOLVING=.*|HOSTNAME_RESOLVING="false"|' \
    /opt/sge/util/install_modules/inst_template.conf > "$conf"

cd /opt/sge
./inst_sge -m -auto "$conf" || fail "inst_sge -m -auto failed"
ok "inst_sge -m -auto (qmaster)"
./inst_sge -x -auto "$conf" || fail "inst_sge -x -auto failed"
ok "inst_sge -x -auto (execd)"

# settings.sh expands $MANPATH unguarded, which trips "set -u".  That is upstream's
# quirk and harmless in a login shell; relax the option around the source.
set +u
. /opt/sge/default/common/settings.sh
set -u

i=0
while [ $i -lt 30 ]; do
   qhost 2>/dev/null | grep -q "^$h" && break
   i=$((i + 1)); sleep 2
done

say "the cluster is up"
pgrep -x sge_qmaster >/dev/null || fail "sge_qmaster is not running"
pgrep -x sge_execd   >/dev/null || fail "sge_execd is not running"
ok "sge_qmaster and sge_execd are running"
echo
qhost | sed 's/^/     /'
qhost | grep -q lx-amd64 || fail "qhost does not report the host as lx-amd64"
ok "qhost reports lx-amd64"
qconf -sql | grep -qx all.q || fail "all.q was not created"
ok "all.q exists, slots=$(qconf -sq all.q | awk '$1=="slots"{print $2}')"

say "run a job as an unprivileged user"
id tester >/dev/null 2>&1 || useradd -m tester
chmod 755 /home/tester
su - tester -c "
   set -e
   . /opt/sge/default/common/settings.sh
   cd /home/tester
   echo 'echo \"ran on \$(hostname) as \$(id -un)\"; sleep 3; exit 0' > smoke.sh
   chmod +x smoke.sh
   qsub -N smoke -sync y -o /home/tester/smoke.out -e /home/tester/smoke.err \
        -b n /home/tester/smoke.sh
" || fail "qsub -sync y did not report success"
ok "qsub -sync y returned success"
echo "   job stdout:"
sed 's/^/     /' /home/tester/smoke.out 2>/dev/null || echo "     (none)"

# The accounting file is written asynchronously.
i=0
while [ $i -lt 30 ]; do
   qacct -j smoke >/dev/null 2>&1 && break
   i=$((i + 1)); sleep 2
done
qacct -j smoke > /tmp/qacct.out 2>&1 || fail "qacct -j smoke found no accounting record"
grep -E '^(qname|hostname|owner|jobname|exit_status|failed)' /tmp/qacct.out | sed 's/^/     /'
es=$(awk '$1=="exit_status"{print $2; exit}' /tmp/qacct.out)
[ "$es" = 0 ] || fail "exit_status is '$es', expected 0"
ok "qacct reports exit_status 0"

# The autoscaler reads these by element and attribute name, so a rename upstream
# would break it silently.  Check the names, not just the exit status.
say "the autoscaler's XML queries"
python3 - <<'PY' || exit 1
import subprocess, sys
import xml.etree.ElementTree as ET

QUERIES = [
    (['qstat', '-u', '*', '-r', '-f', '-xml'], 'job_info', ['queue_info', 'job_info']),
    (['qhost', '-q', '-F', '-xml'],            'qhost',    ['host', 'hostvalue', 'queue']),
    (['qhost', '-h', '*', '-F', '-xml'],       'qhost',    ['host', 'hostvalue']),
]

bad = False
for argv, root_tag, expected in QUERIES:
    label = ' '.join(argv)
    p = subprocess.run(argv, capture_output=True, text=True)
    if p.returncode != 0:
        print(f"   FAIL {label}: exit {p.returncode}\n{p.stderr}")
        bad = True
        continue
    try:
        root = ET.fromstring(p.stdout)
    except ET.ParseError as e:
        print(f"   FAIL {label}: not well-formed XML: {e}")
        bad = True
        continue
    if root.tag != root_tag:
        print(f"   FAIL {label}: root is <{root.tag}>, expected <{root_tag}>")
        bad = True
        continue
    tags = {el.tag for el in root.iter()}
    missing = [t for t in expected if t not in tags]
    if missing:
        print(f"   FAIL {label}: missing element(s) {missing}; saw {sorted(tags)}")
        bad = True
        continue
    print(f"   ok   {label}: <{root.tag}>, elements {sorted(tags)}")

sys.exit(1 if bad else 0)
PY
ok "all three queries are well-formed and carry the expected names"

echo
echo "### $me: EL$el PASSED"
