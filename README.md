# mica-docker

The Docker engine of Mica OS, built from pinned upstream source for amd64 and
arm64 and packed as the Debian package `mica-docker`, the only output of this
repository. A product carries one container engine: this one or mica-podman's,
chosen when the product is built. The release-lock and build rules run in
`mica-build-tools`, at the commit `locks/mica-build-tools.pin` names, through
`bin/mica-tools`.

## The package

| Binary | From | Installed as |
| --- | --- | --- |
| `dockerd`, `docker-proxy` | moby `docker-v29.9.1` | `/usr/bin/` |
| `docker` | docker/cli `v29.9.1` | `/usr/bin/docker` |
| `docker-compose` | docker/compose `v5.6.0` | `/usr/libexec/docker/cli-plugins/docker-compose` (`docker compose`) |
| `containerd`, `containerd-shim-runc-v2` | containerd `v2.4.2` | `/usr/bin/` |
| `runc` | opencontainers/runc `v1.5.2`, with seccomp | `/usr/bin/runc` |
| `docker-init` | krallin/tini `v0.19.0`, static | `/usr/bin/docker-init` |

It also ships `/etc/docker/daemon.json`, `docker.service` and the OpenRC script
`/etc/init.d/docker`, and `/usr/share/mica-docker/upstream.lock`, the upstream
pins it was built from. It enables nothing and creates no user or group (no
`docker` group: the socket is root's). `deb/payload.manifest` is the exact list
of paths. There is no buildx and no `docker-containerd` unit: dockerd starts its
own containerd.

Every Go binary is built with `-trimpath -s -w`, CGO off and no VCS stamp, so
all but runc are static and their bytes do not depend on the build platform;
runc links the system libseccomp, and docker-init is static because it runs
inside containers. Installed-Size is about 209 MB on amd64.

`Depends` are declared in `deb/mica-docker.control` with their floors and are
exactly `deb/debian-depends` plus `mica-system`; it installs on either of
mica-system-base's inits. `Provides: mica-container-engine`, `Conflicts:
mica-podman` (both ship `/usr/bin/docker`). `nftables` names the `nft` binary
dockerd runs for its firewall rules.

## The runtime contract

micad (mica-core) drives this engine: it talks to dockerd through the Docker
API on `/run/docker.sock`, and it switches the engine on and off.

- **micad enables docker.service from `container.enabled`.** Neither the
  package nor the product enables it: micad enables, starts, stops and
  disables `docker.service` on systemd, and adds `docker` to or removes it from
  the `default` runlevel on OpenRC.
- **Ordering**: `docker.service` is `After=micad.service` and the OpenRC
  script `after micad`, so micad's application reset runs before the engine
  holds `/mica/containers`. No socket activation (`docker.socket` is not
  shipped; dockerd listens on `/run/docker.sock` itself), and no
  `network-online` ordering: a device may run offline, and dockerd starts with
  no default route.
- **`/run/docker.pid`**: dockerd's default pid file (`/var/run` is `/run`),
  passed explicitly with `-p` on OpenRC. micad reads it to know whether
  dockerd runs.
- **API 1.44 stays served**: the minimum API version is dockerd's default
  (1.40); nothing sets `min-api-version` or `DOCKER_MIN_API_VERSION`.
- **`daemon.json`** sets exactly `data-root` `/mica/containers/docker` (so
  micad's application reset and the DATA layout are those of podman products),
  `log-driver` `local`, and `firewall-backend` `nftables`.
- **live-restore is off**, Docker's default, so it is not written: stopping
  dockerd stops its containers, and turning containers off in micad turns them
  really off. A container's `restart:` policy starts it again with dockerd.

`tests/units-test.sh` holds the start-up files and `daemon.json` to this, and
`tests/docker-smoke.sh` the installed archive.

Users run `docker` and `docker compose` as root on the device; what they start
is Docker's, under the same data root.

### The firewall ruleset is dockerd's

dockerd's nftables backend runs `nft` and owns its own tables. As for podman
products, mica-system-base disables `nftables.service`, whose
`flush ruleset` would wipe dockerd's rules on reload, restart and shutdown. Do
not enable it.

## Using a release

A release carries exactly two assets:

- `mica-docker.lock` (mica-lock v1, `mica-build-tools:docs/spec/release-lock.md`): the
  release row, a `pool` row per architecture naming
  `ghcr.io/micaoss/mica-docker:pool.<arch>.<release>` by digest, and a
  `package` row per architecture with the archive's version and sha256.
- `SHA256SUMS`, listing only the lock.

A pool is an OCI artifact (`application/vnd.mica.pool`) whose one layer is the
archive (`application/vnd.mica.deb`, titled with its file name, annotated with
its `mica.inputs`). A consumer commits the lock unchanged as
`locks/mica-docker.lock` and records the release in
`locks/pins/mica-docker.pin`, or runs `bin/mica-tools locks move mica-docker <release>`,
which writes both.

## Inputs

- `locks/mica-build-env.lock`: the build-env images every stage builds `FROM`,
  and the third-party images (buildkit), by digest.
- `locks/mica-system-base.lock`: the Base release the package installs into.
  `make base-check` reads each root's dpkg status from the rootfs the lock
  names and runs apt with the lock's `apt` rows as its only sources. Every
  archive the root lacks for `deb/debian-depends` must be an `upstream` row
  Base pins, and every declared `Depends` floor must be met by what the root
  ships or Base pins.
- `locks/upstream.lock`: the six upstream trees as `git` rows (tag and commit;
  the build clones the tag and refuses another commit), and the Debian build
  closure of the cgo stage as `source` rows, by sha256. moby, docker/cli and
  containerd vendor their Go modules; docker/compose's are downloaded at the
  build and verified against its `go.sum`.
- `pins/`: the cgo stage's build packages (`go.roots`), their resolved closure
  in install order (`go.<arch>`), the Debian snapshot they are resolved from
  (`snapshot`), and the build-env release and images they were resolved
  against (`resolved-for`). `tools/dev-pins.sh check` refuses a closure
  resolved against other images.

**Every pin is at its latest release**: the six upstream trees (majors
included), mica-build-tools, mica-build-env and mica-system-base. A pin is never
moved alone and never held back; `make upgrade` (`tools/upgrade.sh`) moves all
of them:

- each `git` row to the newest release tag of its tree and the commit it
  peels to (`check-pins.sh`, `make engine-pins`, lists what is behind; moby
  tags the engine `docker-v<version>`, and docker/cli publishes tags only);
- the mica-build-env and mica-system-base locks and pins, and
  `locks/mica-build-tools.pin` with `bin/mica-tools`, through
  `mica-tools locks update`;
- after a mica-build-env move, `pins/snapshot` and the build closure;
- the component versions of `deb/copyright` and the control's description,
  and the package version (below).

`.github/workflows/upgrade.yml` runs it every Monday: a change is built, packed
and gated for both architectures, then `main` moves to it and it is released
without a person. A red upgrade stops before `main` moves and leaves its
`upgrade/<run>` branch.

## Versions

The package is locked by its own version
(`mica-build-tools:docs/spec/package-versions.md`).
`deb/mica-docker.control` declares `Version: <Docker version>-<revision>`,
whose upstream part must be the moby tag of `locks/upstream.lock` without
`docker-v`, and `Source-Date-Epoch`, the `SOURCE_DATE_EPOCH` of the pack; both
are bumped together, and a release never changes them. A moby bump sets the
upstream part and resets the revision; any other change to what decides the
archive's bytes bumps the revision; `make upgrade` does both. `deb/mica-inputs`
declares those inputs, and `mica-tools inputs deb <arch>` hashes them into
`mica.inputs`.

`mica-tools pool guard` (CI and release) compares every archive with the
latest release: a lower version is refused, a higher one is new, and the same
version must carry the same `mica.inputs` and the same bytes.

## Releasing

A release is tagged with the UTC time it is cut, and only from a commit of
`main`:

```sh
gh release create "$(date -u +%Y%m%d-%H%M)" -R micaoss/mica-docker --target <commit of main> --notes ""
```

That triggers `.github/workflows/release.yml`, which builds, packs, smoke-tests
and gates the tag natively (amd64 on `ubuntu-26.04`, arm64 on
`ubuntu-26.04-arm`), then `publish.yml` runs `tools/release.sh <tag>`: the
release check, `mica-tools pool guard`, `mica-tools release pool` (both pools,
read back anonymously) and `mica-tools release attach`. Nothing published is
ever replaced, and nothing is published from a workstation;
`.github/workflows/ci.yml` builds, packs and gates both architectures on every
push and pull request and publishes nothing.

## Development

`bin/mica-tools` runs on bun from `PATH` at the version the pinned checkout
declares, from `MICA_BUN`, or else in the `mica-build-env` base image.

```sh
make check                     # lint, locks/, the offline tests, the closure against the build-env images
make inputs                    # every pinned lock against its release (network)
make base-check                # the Debian dependencies against the pinned Base release (network, docker)
MICA_ARCH=amd64 make engine    # the engine -> _out/engine/amd64/
make pool                      # both archives -> _out/debs/{amd64,arm64}/{pool/,Packages,SHA256SUMS,manifest.txt}
make package-gate              # the package gate, with no-cache engine and archive rebuilds
MICA_ARCH=amd64 make smoke     # the archive installed and run in a privileged container (docker, network)
make offline                   # engine and pool for both architectures from a clean checkout
make upgrade                   # every pin to its latest release (network, docker)
```

The pure Go binaries cross-compile on the build platform; runc and docker-init
build at the target, on the `default` buildx builder when it offers the
platform, else a `mica-<arch>` docker-container builder that emulates it. CI
builds each architecture on a native runner.

| File | Purpose |
| --- | --- |
| `build.sh`, `Dockerfile` | the engine binaries, from the pinned trees and build closure |
| `tools/stamp.sh` | records which pins a build used; packing refuses a stale one |
| `tools/package.sh`, `deb/`, `overlay/` | stages and packs the archive with `mica-tools deb pack`, and indexes the pool |
| `tests/package-gate.sh` | identity, payload, Depends, Provides and Conflicts, copyright, no conffiles or enablement, `mica-tools pool gate`, byte-identical rebuilds |
| `tests/units-test.sh` | the start-up files and `daemon.json` against the runtime contract |
| `tests/docker-smoke.sh` | the archive installed in a privileged container and run: offline start, pid file, API 1.44, containers, networks and DNS, nftables, ports, logs, compose, capabilities, devices, stop |
| `tools/release.sh` | publishes a release through `mica-tools` |
| `tools/base-check.sh` | the Debian dependencies against the pinned Base release |
| `tools/dev-pins.sh`, `pins/` | resolves, checks and fetches the build closure |
| `tools/upgrade.sh` | moves every pin to its latest release and bumps the package |
| `check-pins.sh` | which upstream tags have a newer release |
| `tools/buildx.sh`, `tools/build-cache.sh` | the builders, and CI's engine compile caches |
| `bin/mica-tools`, `locks/mica-build-tools.pin` | runs the pinned `mica-build-tools` |
| `tests/` | the offline tests; `tests/mica-tools-stub.sh` stands in for `bin/mica-tools` in their fixtures |
