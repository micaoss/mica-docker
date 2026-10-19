# mica-docker: the Docker engine of Mica OS as the Debian package mica-docker.

MICA_ARCH ?= arm64

.PHONY: help inputs upgrade engine engine-pins dev-pins engine-pins-test stamp-test dev-pins-test upgrade-test units-test smoke package-test base-check base-check-test deb pool package-gate publish offline offline-test lint check

help:
	@echo "  inputs              verify every lock in locks/ against its pinned release (network)"
	@echo "  engine              build the eight engine binaries into _out/engine/\$$MICA_ARCH (MICA_ARCH=amd64|arm64)"
	@echo "  deb                 pack _out/engine/\$$MICA_ARCH into the pool _out/debs/\$$MICA_ARCH/ (pool/, Packages, SHA256SUMS)"
	@echo "  pool                deb for amd64 and arm64"
	@echo "  offline             from a clean checkout and its pins only: engine and deb for amd64 and arm64, printing the pools"
	@echo "  package-gate        the package gate over _out/debs, with no-cache engine and archive rebuilds"
	@echo "  publish             publish _out/debs as the pools and assets of the published release TAG=<YYYYMMDD-HHMM> (release workflow only)"
	@echo "  smoke               the archive of _out/debs/\$$MICA_ARCH installed and run in a privileged container (docker, network)"
	@echo "  base-check          every Debian package mica-docker needs comes from the pinned mica-system-base release (network)"
	@echo "  upgrade             every pin to its latest release, and the package bumped when it moved (network, docker)"
	@echo "  engine-pins         are the upstream tags in locks/upstream.lock current? (network)"
	@echo "  dev-pins            re-resolve the Debian build closure of the cgo stage (network, docker)"
	@echo "  check               lint, locks/, engine-pins-test, stamp-test, dev-pins-test, upgrade-test, units-test, package-test, base-check-test, offline-test"

inputs:
	bin/mica-tools locks verify

upgrade:
	bash tools/upgrade.sh

engine:
	bash build.sh

deb:
	bash tools/package.sh --arch $(MICA_ARCH)

pool:
	bash tools/package.sh --arch amd64
	bash tools/package.sh --arch arm64

package-gate:
	bash tests/package-gate.sh --reproduce

publish:
	bash tools/release.sh "$(TAG)"

offline:
	bash tools/offline.sh

engine-pins:
	bash check-pins.sh

dev-pins:
	bash tools/dev-pins.sh resolve

engine-pins-test:
	bash tests/pins-test.sh

stamp-test:
	bash tests/stamp-test.sh

dev-pins-test:
	bash tests/dev-pins-test.sh

upgrade-test:
	bash tests/upgrade-test.sh

units-test:
	bash tests/units-test.sh

smoke:
	bash tests/docker-smoke.sh --arch $(MICA_ARCH)

package-test:
	bash tests/package-test.sh

offline-test:
	bash tests/offline-test.sh

base-check:
	bash tools/base-check.sh

base-check-test:
	bash tests/base-check-test.sh

lint:
	bin/mica-tools self-check
	bin/mica-tools shell-lint

check: lint engine-pins-test stamp-test dev-pins-test upgrade-test units-test package-test base-check-test offline-test
	bin/mica-tools locks check
	bin/mica-tools upstream check
	bash tools/dev-pins.sh check
