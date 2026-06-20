# ioscpy top-level build orchestration.
# Author: Lautaro Villarreal Culic' (https://lautarovculic.com)

.PHONY: all host host-release install-host uninstall-host device device-rootless \
        device-rootful device-roothide release repo clean fmt clippy test help

PREFIX ?= /usr/local

all: host

## Host (Rust)
host:
	cd host && cargo build

host-release:
	cd host && cargo build --release

install-host: host-release
	install -m 0755 host/target/release/ioscpy $(PREFIX)/bin/ioscpy
	@echo "installed ioscpy -> $(PREFIX)/bin/ioscpy"

uninstall-host:
	rm -f $(PREFIX)/bin/ioscpy

fmt:
	cd host && cargo fmt

clippy:
	cd host && cargo clippy --all-targets --all-features

test:
	cd host && cargo test

## Device (Theos)
device-rootless:
	cd device && $(MAKE) package THEOS_PACKAGE_SCHEME=rootless

device-rootful:
	cd device && $(MAKE) package

device-roothide:
	# Needs the roothide Theos fork installed (THEOS with the roothide scheme);
	# a plain Theos falls back to a rootful build, which won't load on roothide.
	cd device && $(MAKE) package THEOS_PACKAGE_SCHEME=roothide

device: device-rootless

## Packaging
repo:
	packaging/repo/build-repo.sh

## Combined
release: host-release device-rootless device-rootful

clean:
	cd host && cargo clean || true
	cd device && $(MAKE) clean || true

help:
	@echo "ioscpy targets:"
	@echo "  make host-release      build macOS host binary (release)"
	@echo "  make install-host      install ioscpy to $(PREFIX)/bin (on PATH)"
	@echo "  make device-rootless   build rootless .deb (/var/jb)"
	@echo "  make device-rootful    build rootful .deb (/)"
	@echo "  make repo              build the Sileo/Zebra repo from the .deb"
	@echo "  make release           host-release + both device variants"
	@echo "  make fmt|clippy|test   host lint/test"
	@echo "  make clean             clean host + device"
