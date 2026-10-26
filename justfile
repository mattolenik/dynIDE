# dynide task runner
set windows-shell := ["cmd.exe", "/d", "/s", "/c"]

import 'dynide/dynide.just'

python := if os() == "windows" { "python" } else { "python3" }

# Run repository maintenance contract tests (vendoring scripts)
maintenance-test:
    {{python}} -m unittest scripts.test_vendor_libghostty_vt scripts.test_vendor_portable_pty

# The gate: alias of dynide-check
check: dynide-check

# Regenerate the C API bindings with bindgen-cli 0.72.1
libghostty-bindings *clang_args:
    bash scripts/generate_libghostty_bindings.sh {{clang_args}}

# Build the vendored libghostty-vt source dist
build-libghostty-vt:
    scripts/build_vendored_libghostty_vt.sh
