# resvg-php — cargo build rules for the vendored Rust shim.
#
# `PHP_ADD_MAKEFILE_FRAGMENT` in config.m4 appends this file into the generated
# Makefile.objects, so a plain `make` builds the shim before the link step
# consumes it. config.m4 substitutes RESVG_NATIVE_DIR and RESVG_ARCHIVE, so a
# plain root build needs no configuration here.

$(RESVG_ARCHIVE): $(RESVG_NATIVE_DIR)/Cargo.toml $(RESVG_NATIVE_DIR)/Cargo.lock $(wildcard $(RESVG_NATIVE_DIR)/src/*.rs)
	cd $(RESVG_NATIVE_DIR) && $(RESVG_CARGO) build --release --locked

# Force the archive to be built before the extension is linked.
$(phplibdir)/resvg.la: $(RESVG_ARCHIVE)
