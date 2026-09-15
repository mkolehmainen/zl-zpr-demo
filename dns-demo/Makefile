# Build the ZPR binaries dns-demo needs into bin/, from sibling source repos.
#
#   make ZPR_ROOT=/path/to/repos
#   make ZPR_ROOT=/path/to/repos ZPR_REPO_PREFIX='zl-'
#
# ZPR_ROOT points at the directory containing the ZPR repositories.
# ZPR_REPO_PREFIX handles renamed checkouts: with ZPR_REPO_PREFIX='zl-' the
# upstream repo name "zpr-core" resolves to $(ZPR_ROOT)/zl-zpr-core, etc.
# Default is empty, so the upstream layout works unchanged.
ZPR_ROOT ?=
ZPR_REPO_PREFIX ?=

CORE_DIR = $(ZPR_ROOT)/$(ZPR_REPO_PREFIX)zpr-core
VS_DIR = $(ZPR_ROOT)/$(ZPR_REPO_PREFIX)zpr-visaservice
COMPILER_DIR = $(ZPR_ROOT)/$(ZPR_REPO_PREFIX)zpr-compiler
# zl-zpr-coredns is zipline-only (no upstream zpr-coredns), so the prefixed
# name is the only layout that exists; the prefix still composes correctly.
COREDNS_DIR = $(ZPR_ROOT)/$(ZPR_REPO_PREFIX)zpr-coredns

.PHONY: all ph visaservice compiler coredns check-zpr-root clean

all: ph visaservice compiler coredns

check-zpr-root:
	@test -n "$(ZPR_ROOT)" || { \
		echo "ZPR_ROOT must point to the directory containing the ZPR repositories" >&2; \
		exit 1; \
	}
	@test -d "$(CORE_DIR)" || { \
		echo "ZPR_ROOT=$(ZPR_ROOT) ZPR_REPO_PREFIX=$(ZPR_REPO_PREFIX) does not contain $(ZPR_REPO_PREFIX)zpr-core" >&2; \
		exit 1; \
	}

ph: check-zpr-root
	mkdir -p bin
	cd "$(CORE_DIR)/adapter/ph" && cargo build --release
	cp "$(CORE_DIR)/target/release/ph" bin/

visaservice: check-zpr-root
	mkdir -p bin
	cd "$(VS_DIR)" && cargo build --release
	cp "$(VS_DIR)/target/release/vs" \
		"$(VS_DIR)/target/release/vs-admin" \
		"$(VS_DIR)/target/release/vsapikey" bin/

compiler: check-zpr-root
	mkdir -p bin
	cd "$(COMPILER_DIR)" && cargo build --release
	cp "$(COMPILER_DIR)/target/release/zplc" \
		"$(COMPILER_DIR)/target/release/zpdump" bin/

# CoreDNS with the zpr plugin compiled in (Go build, mirrors how
# multinode-demo consumes zpr-dashboard: build in the source repo, copy bin/).
coredns: check-zpr-root
	mkdir -p bin
	cd "$(COREDNS_DIR)" && $(MAKE) build
	cp "$(COREDNS_DIR)/bin/coredns" bin/

clean:
	rm -rf bin
