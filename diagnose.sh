#!/bin/zsh
# GimbalBar 1.2: diagnósticos USB somente leitura (NÃO modifica o app).
set -eu
cd "${0:A:h}"
mkdir -p build
clang -O2 -Wall -Wextra tools/uvc_diag.c \
  -framework IOKit -framework CoreFoundation \
  -o build/uvc_diag
exec ./build/uvc_diag "$@"
