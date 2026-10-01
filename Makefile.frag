# resvg-php — cargo build rules for the vendored Rust shim.
#
# `PHP_ADD_MAKEFILE_FRAGMENT` in config.m4 appends this file into the generated
# Makefile.objects, so a plain `make` builds the shim before the link step
# consumes it. config.m4 substitutes RESVG_NATIVE_DIR, RESVG_ARCHIVE, and
# RESVG_CARGO_FLAGS (--locked normally, --frozen for an offline build).

$(RESVG_ARCHIVE): $(RESVG_NATIVE_DIR)/Cargo.toml $(RESVG_NATIVE_DIR)/Cargo.lock $(wildcard $(RESVG_NATIVE_DIR)/src/*.rs)
	cd $(RESVG_NATIVE_DIR) && $(RESVG_CARGO) build --release $(RESVG_CARGO_FLAGS)

# Force the archive to be built before the extension is linked.
$(phplibdir)/resvg.la: $(RESVG_ARCHIVE)
