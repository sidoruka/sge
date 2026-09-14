# sge — Son of Grid Engine 8.1.9, pinned for Cloud Pipeline

A fork of **Son of Grid Engine (SoGE) 8.1.9** pinned at the exact version Cloud Pipeline already
runs, carrying the patches needed to build it on EL9 (Rocky Linux 9+) and a GitHub Action that
publishes the resulting `gridengine-*` RPMs.

This repository is the only place SGE is built. [epam/cloud-pipeline](https://github.com/epam/cloud-pipeline)
consumes the published artifact by URL and contains no SGE sources, spec or build scripts.

## Why this exists

Cloud Pipeline installs SGE on RHEL-alikes from prebuilt `gridengine-8.1.9-1.el6` RPMs. Those came
from `https://arc.liv.ac.uk/downloads/SGE/releases/8.1.9/`, which no longer exists, and `gridengine`
was never shipped in EPEL 8 or 9 — so there is no way to install SGE on Rocky Linux 9, and no source
of truth to rebuild from. This fork restores that source of truth.

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
build/                  build scripts -- see Building
provenance/             recovery artifacts and checksums
```

The EL9 changes are ordinary commits on top of `upstream/8.1.9`, not a `patches/` directory:
`git diff upstream/8.1.9` is the whole delta, and `git log` says why each piece of it exists.

Added in a later step: `.github/workflows/release.yml`, which runs the same scripts as below.

## Building

Two constraints apply however you build:

* **Build on the distribution you want packages for.** rpm stamps `%dist` from the build host, so
  `el9` packages have to be built on EL9.
* **Build x86_64.** Cloud Pipeline hardcodes `/opt/sge/bin/lx-amd64` in three setup scripts, so an
  arm64 package would install and then find no binaries.

### From a workstation, in a container

```sh
build/build-in-container.sh          # -> RPMS/
build/build-in-container.sh --tar    # -> RPMS/, plus the tar the platform downloads
```

Needs only docker. It builds in `rockylinux:9`, forces `--platform linux/amd64` (so it works on an
arm64 workstation — under Rosetta this takes minutes, not hours), keeps all scratch space inside the
container, and chowns the results back to you. Arguments are passed through to `build-rpm.sh`.

### On an EL9 machine

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

Repositories: baseos and appstream, plus **crb** for `libtirpc-devel` and `munge-devel`. No EPEL,
at build time or on the nodes — see [jemalloc](#jemalloc) below.

### What comes out

Eleven packages, `8.1.9-1.el9`:

```
gridengine  -devel  -drmaa4ruby  -execd  -qmaster  -qmon
gridengine-debuginfo  -debugsource  -execd-debuginfo  -qmaster-debuginfo  -qmon-debuginfo
```

That is the same set as the `el6` RPMs Cloud Pipeline runs today, minus `guiinst`. Four things
cannot be built on EL9, and `gridengine.spec` turns them off under `%if 0%{?rhel} >= 9`:

| Not built | Why |
|---|---|
| Java / JGDI / `guiinst` | EL9 has no `ant-nodeps` and no `swing-layout` |
| CSP mode (`-no-secure`) | `libs/comm/cl_ssl_framework.c` needs the pre-1.1 OpenSSL API, where `X509_STORE_CTX` was not opaque |
| `qmake`, `qtcsh` | vendored GNU make and tcsh, reaching for `__alloca`, `__stat`, `union wait` |
| LTO | `aimk` does not pass make's jobserver to `lto-wrapper`; the code also needs `-fno-strict-aliasing` |

None of them is used by a Grid Engine cluster, and nothing in Cloud Pipeline invokes them.

### jemalloc

Upstream's spec passes `aimk -with-jemalloc`; this one does not. `aimk` appends `-ljemalloc` to
`LIBS` for every binary rather than only qmaster — its own comment says *"fixme: this should probably
only apply to qmaster"* — so rpm generates a `libjemalloc.so.2` dependency on all four binary
subpackages, `gridengine-qmon` included. On EL9 that library exists only in EPEL, and a node carrying
just the distribution repositories and `cloud-pipeline` cannot install the packages at all:

```
nothing provides libjemalloc.so.2()(64bit) needed by gridengine-8.1.9-1.el9.x86_64
```

What the flag buys is an alternative malloc for the daemons — an enhancement from 2008, made against
a much older glibc than EL9's 2.34 — and its allocator statistics in qmaster's `print_malloc_info`,
per `sge_conf(5)`. Neither is worth requiring EPEL on every node in the cluster, so the packages are
built against the system allocator instead. `rpmbuild --with jemalloc` restores the old behaviour,
and then needs `jemalloc-devel` at build time and `jemalloc` on every node.

## Tags

* `upstream/8.1.9` — the unmodified upstream import. Every Cloud Pipeline change is a commit after
  this, so `git diff upstream/8.1.9` is always the complete set of local modifications.
* `v<version>-<release>` — a release. Pushing one triggers the build-and-publish Action. The first
  will be `v8.1.9-1`, cut once the EL9 build passes.

## Status

The EL9 build works and has been exercised end to end: the packages install into a bare
`rockylinux:9` (`dnf install`, every dependency resolved from baseos and appstream with neither crb
nor EPEL enabled, `%pre` creates `sgeadmin`), `inst_sge -m -auto` and `inst_sge -x -auto` both succeed
with Cloud Pipeline's own `grid.conf`, and a submitted job runs to completion — `qacct -j` reports
`exit_status 0`. The XML that Cloud Pipeline's autoscaler parses (`qstat -u "*" -r -f -xml`,
`qhost -q -F -xml`, `qhost -h "*" -F -xml`) has the same element and attribute names as before, so the
autoscaler needs no change.

Not written yet: `.github/workflows/release.yml`, and therefore no `v8.1.9-1` tag and no published
artifact. Until then, build with the commands above.
