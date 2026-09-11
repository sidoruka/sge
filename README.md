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
provenance/             recovery artifacts and checksums
```

Added in later steps: `patches/el9/`, `build/build-rpm.sh`, `test/reference/`,
`.github/workflows/release.yml`.

## Tags

* `upstream/8.1.9` — the unmodified upstream import. Every Cloud Pipeline change is a commit after
  this, so `git diff upstream/8.1.9` is always the complete set of local modifications.
* `v<version>-<release>` — a release. Pushing one triggers the build-and-publish Action. The first
  will be `v8.1.9-1`, cut once the EL9 build passes.

## Status

Pristine upstream imported. EL9 build patches and the release Action are not written yet.
