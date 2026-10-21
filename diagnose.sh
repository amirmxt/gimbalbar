#!/bin/zsh
# GimbalBar: read-only USB diagnostics (does not modify the app).
set -eu
cd "${0:A:h}"
mkdir -p build
clang -O2 -Wall -Wextra tools/uvc_diag.c \
  -framework IOKit -framework CoreFoundation \
  -o build/uvc_diag
exec ./build/uvc_diag "$@"
