# sge — Son of Grid Engine 8.1.9, pinned for Cloud Pipeline

A fork of **Son of Grid Engine (SoGE) 8.1.9** pinned at the exact version Cloud Pipeline already
runs, carrying the patches needed to build it on EL9 and EL10 (Rocky Linux 9 and 10) and a GitHub
Action that publishes the resulting `gridengine-*` RPMs.

This repository is the only place SGE is built. [epam/cloud-pipeline](https://github.com/epam/cloud-pipeline)
consumes the published artifact by URL and contains no SGE sources, spec or build scripts.

## Why this exists

Cloud Pipeline installs SGE on RHEL-alikes from prebuilt `gridengine-8.1.9-1.el6` RPMs. Those came
from `https://arc.liv.ac.uk/downloads/SGE/releases/8.1.9/`, which no longer exists, and `gridengine`
was never shipped in EPEL 8, 9 or 10 — so there is no way to install SGE on Rocky Linux 9 or 10, and
no source of truth to rebuild from. This fork restores that source of truth.

The version is pinned at 8.1.9 rather than moved to a newer Grid Engine lineage because Cloud
Pipeline's autoscaler parses `qstat`/`qhost` XML output. Staying on 8.1.9 keeps that output
byte-compatible; see the compatibility contract in the implementation plan.

## Provenance

`arc.liv.ac.uk` is gone and no `.src.rpm` was ever archived, so the sources were recovered from the
Internet Archive's capture of the original release directory:

| Artifact | Wayback snapshot | Recovered as |
|---|---|---|
| `sge-8.1.9.tar.gz` (11,943,716 bytes) | `20210814200605` | the pristine tree at the repository root |
| `sge-8.1.9.tar.gz.sig` | `20210724073215` | `provenance/sge-8.1.9.tar.gz.sig` |
| `debian.tar.gz` | `20210814223555` | `provenance/debian-packaging-8.1.9.tar.gz` |

Checksums are in [`provenance/SHA256SUMS`](provenance/SHA256SUMS).

The tarball was confirmed to be the source of the RPMs Cloud Pipeline runs today: its
`gridengine.spec` declares `Name: gridengine`, `Version: 8.1.9`, `Release: 1%{?dist}`, the license
string `(SISSL and BSD and LGPLv3+ and MIT) and GPLv3+ and GFDL and others`, and the subpackages
`devel`, `qmon`, `execd`, `qmaster`, `drmaa4ruby`, `hadoop`, `guiinst` — all of which match the
metadata of the deployed `gridengine-8.1.9-1.el6` packages exactly. It also defines
`%define sge_home /opt/sge` and `%define username sgeadmin`, matching the `SGE_ROOT` and
`ADMIN_USER` values Cloud Pipeline's setup scripts assume.

`sge.spec` and `gridengine.spec` in the tarball are identical files.

**The detached signature has not been verified** — SoGE's signing key is not available offline. It is
preserved so that verification remains possible if the key is recovered. The identity argument above
rests on the spec metadata matching the deployed packages, not on the signature.

## Layout

```
/                       pristine SoGE 8.1.9 source tree (tag: upstream/8.1.9)
gridengine.spec         upstream spec; builds the gridengine* subpackages (== sge.spec)
build/                  build and test scripts -- see Building and Testing
provenance/             recovery artifacts and checksums
```

The EL9/EL10 changes are ordinary commits on top of `upstream/8.1.9`, not a `patches/` directory:
`git diff upstream/8.1.9` is the whole delta, and `git log` says why each piece of it exists.

Added in a later step: `.github/workflows/release.yml`, which runs the same scripts as below.

## Building

Two constraints apply however you build:

* **Build on the distribution you want packages for.** rpm stamps `%dist` from the build host, so
  `el9` packages have to be built on EL9 and `el10` packages on EL10.
* **Build x86_64.** Cloud Pipeline hardcodes `/opt/sge/bin/lx-amd64` in three setup scripts, so an
  arm64 package would install and then find no binaries.

### From a workstation, in a container

```sh
build/build-in-container.sh          # -> RPMS/
build/build-in-container.sh --tar    # -> RPMS/, plus the tar the platform downloads

# For a different EL major.  Note the Rocky 10 images are only under the
# rockylinux/rockylinux repository; there is no docker.io/library/rockylinux:10.
SGE_BUILD_IMAGE=rockylinux/rockylinux:10.2 build/build-in-container.sh --tar
```

Needs only docker. It builds in `rockylinux:9`, forces `--platform linux/amd64` (so it works on an
arm64 workstation — under Rosetta this takes minutes, not hours), keeps all scratch space inside the
container, and chowns the results back to you. Arguments are passed through to `build-rpm.sh`.

### On an EL9 or EL10 machine

```sh
sudo build/install-build-deps.sh     # once
build/build-rpm.sh --tar
```

`build-rpm.sh -w` builds your working tree instead of `HEAD`, which is what you want while fixing a
build error. `build-rpm.sh -h` lists the rest.

### The same thing by hand

```sh
dnf -y install dnf-plugins-core
dnf config-manager --set-enabled crb
dnf -y install gcc gcc-c++ make patch tar which diffutils file \
               perl python3 tcsh net-tools hostname git rpm-build \
               openssl-devel ncurses-devel pam-devel \
               hwloc-devel libdb-devel motif-devel libXmu-devel \
               libtirpc-devel munge-devel

mkdir -p rpmbuild/SOURCES rpmbuild/SPECS
git archive --format=tar.gz --prefix=sge-8.1.9/ -o rpmbuild/SOURCES/sge-8.1.9.tar.gz HEAD
cp gridengine.spec rpmbuild/SPECS/
rpmbuild --define "_topdir $PWD/rpmbuild" -bb rpmbuild/SPECS/gridengine.spec
```

`%setup` expects the tarball to unpack into a single `sge-8.1.9` directory, which is where the
`--prefix` comes from; take the version from the spec rather than typing it twice.

Repositories: baseos and appstream, plus **crb** for `libtirpc-devel` and `munge-devel`. Whether
EPEL is needed on top depends on the EL major, and this is the one place the two builds differ:

* **EL9 — no EPEL**, at build time or on the nodes. `libdb-devel` and `motif-devel` are both in
  appstream, and nothing else here comes from outside the distribution — see
  [jemalloc](#jemalloc) below.
* **EL10 — EPEL is mandatory.** RHEL 10 dropped Berkeley DB and Motif from the distribution, so
  `libdb-devel` and `motif-devel` come from `epel` at build time, and `libdb`, `libdb-utils` and
  (for `-qmon`) `motif` and `libXp` come from it on the *nodes*.

So on EL10 the by-hand recipe above needs `epel-release` as well:

```sh
dnf -y install epel-release dnf-plugins-core    # EL10 only
```

`build/install-build-deps.sh` does this for you, keying off `/etc/os-release`.

### What comes out

Eleven packages, `8.1.9-1.el9` or `8.1.9-1.el10` depending on the build host:

```
gridengine  -devel  -drmaa4ruby  -execd  -qmaster  -qmon
gridengine-debuginfo  -debugsource  -execd-debuginfo  -qmaster-debuginfo  -qmon-debuginfo
```

That is the same set as the `el6` RPMs Cloud Pipeline runs today, minus `guiinst`. Four things
cannot be built on EL9 or EL10, and `gridengine.spec` turns them off under `%if 0%{?rhel} >= 9`:

| Not built | Why |
|---|---|
| Java / JGDI / `guiinst` | no `ant-nodeps` and no `swing-layout` |
| CSP mode (`-no-secure`) | `libs/comm/cl_ssl_framework.c` needs the pre-1.1 OpenSSL API, where `X509_STORE_CTX` was not opaque |
| `qmake`, `qtcsh` | vendored GNU make and tcsh, reaching for `__alloca`, `__stat`, `union wait` |
| LTO | `aimk` does not pass make's jobserver to `lto-wrapper`; the code also needs `-fno-strict-aliasing` |

None of them is used by a Grid Engine cluster, and nothing in Cloud Pipeline invokes them.

EL10 needs one thing more, under `%if 0%{?rhel} >= 10`: gcc 14 makes
`-Wincompatible-pointer-types` an error by default, and the vendored Motif toolkit in
`3rdparty/qmon/Xmt310` trips it (`MsgDialogs.c` passes the address of a `va_list` parameter). That one
class is downgraded to a warning, by name, so any *other* new default error still stops the build.
Nothing else differs: the daemons, the shepherd and the client tools all compile clean under gcc 14.

### jemalloc

Upstream's spec passes `aimk -with-jemalloc`; this one does not. `aimk` appends `-ljemalloc` to
`LIBS` for every binary rather than only qmaster — its own comment says *"fixme: this should probably
only apply to qmaster"* — so rpm generates a `libjemalloc.so.2` dependency on all four binary
subpackages, `gridengine-qmon` included. `jemalloc` is an EPEL package on both EL9 and EL10, so a
node carrying just the distribution repositories and `cloud-pipeline` cannot install the packages at
all:

```
nothing provides libjemalloc.so.2()(64bit) needed by gridengine-8.1.9-1.el9.x86_64
```

What the flag buys is an alternative malloc for the daemons — an enhancement from 2008, made against
a much older glibc than EL9's 2.34 — and its allocator statistics in qmaster's `print_malloc_info`,
per `sge_conf(5)`. Neither is worth an extra runtime dependency, and on EL9 it is the difference
between needing EPEL on every node in the cluster and not needing it at all, so the packages are
built against the system allocator instead. `rpmbuild --with jemalloc` restores the old behaviour,
and then needs `jemalloc-devel` at build time and `jemalloc` on every node.

## Testing

`build/smoke-test.sh` checks a build the way the platform consumes it, rather than trusting that it
compiled:

```sh
build/build-in-container.sh --tar                                   # produces the payload
build/smoke-test.sh                                                 # -> tests it on rockylinux:9
SGE_TEST_IMAGE=rockylinux/rockylinux:10.2 build/smoke-test.sh -o RPMS
```

It starts a bare container of the target image and, in it: unpacks the tar payload, asserts six
runtime packages all stamped with that host's `%dist` and none requiring `libjemalloc`, `dnf install`s
them with only the repositories that release is allowed to need, checks `%pre` made `sgeadmin` and
that `/opt/sge/bin/lx-amd64` is populated and `qmon`'s libraries resolve, auto-installs a qmaster and
an execd from a `grid.conf` generated out of the template the packages ship, submits a job as an
unprivileged user, and asserts `qacct` reports `exit_status 0` and that the autoscaler's three XML
queries still carry the element names it reads.

Because it asserts the `%dist` tag, it has to run on the image the packages were built for — testing
an `el9` payload on EL10 fails by design. `--here` runs the checks directly instead of nesting a
container, which is how it re-enters itself and how to run it on a real EL host or in CI.

## Tags

* `upstream/8.1.9` — the unmodified upstream import. Every Cloud Pipeline change is a commit after
  this, so `git diff upstream/8.1.9` is always the complete set of local modifications.
* `v<version>-<release>` — a release. Pushing one triggers the build-and-publish Action. The first
  will be `v8.1.9-1`, cut once there is an Action to publish it.

## Status

Both builds work and have been exercised end to end by `build/smoke-test.sh`, on
`rockylinux/rockylinux:9.8` and `rockylinux/rockylinux:10.2`: all eleven packages build, the six
runtime packages install into a bare
container of the same image (`%pre` creates `sgeadmin`), `inst_sge -m -auto` and `inst_sge -x -auto`
both succeed from one `grid.conf`, `qhost` reports the host as `lx-amd64` with `all.q` at 6 slots, a
job submitted by an unprivileged user finishes with `qacct -j` reporting `exit_status 0`, and the
three XML queries Cloud Pipeline's autoscaler parses (`qstat -u "*" -r -f -xml`, `qhost -q -F -xml`,
`qhost -h "*" -F -xml`) carry the same element and attribute names as before, so the autoscaler needs
no change. No package on either build requires `libjemalloc`.

The difference between the two is only the repositories, as above:

* **EL9** resolves every dependency from **baseos and appstream alone** — the install was done with
  neither crb nor EPEL enabled.
* **EL10** needs **EPEL**. Without it the transaction fails outright, which is the check that keeps
  this honest:

  ```
  nothing provides libdb-5.3.so()(64bit) needed by gridengine-8.1.9-1.el10.x86_64
  nothing provides libdb-utils needed by gridengine-qmaster-8.1.9-1.el10.x86_64
  nothing provides libXm.so.4()(64bit) needed by gridengine-qmon-8.1.9-1.el10.x86_64
  ```

Not written yet: `.github/workflows/release.yml`, and therefore no `v8.1.9-1` tag and no published
artifact. Until then, build with the commands above.
