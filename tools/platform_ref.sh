#!/usr/bin/env bash
# Points a stack's shared-platform module sources at another ref, in the
# runner's checkout only (never committed): the downstream check and a
# project's PLATFORM_REF override use it to plan against unmerged platform code.
#   Usage: platform_ref.sh REF [DIR]   (DIR defaults to .)
# Rewrites `shared-platform.git//<path>?ref=main` to `?ref=REF` in every *.tf
# under DIR and lists the files it changed. Sources pinned to anything but
# main are left alone. REF main is a no-op.
set -euo pipefail

ref="${1:?usage: platform_ref.sh REF [DIR]}"
dir="${2:-.}"
[[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] || {
  echo "::error::platform_ref: bad ref" >&2
  exit 1
}
[[ "$ref" == main ]] && exit 0

while IFS= read -r -d '' f; do
  if grep -q 'shared-platform\.git//[^"?]*?ref=main"' "$f"; then
    sed -i -E "s#(shared-platform\\.git//[^\"?]*)\\?ref=main\"#\\1?ref=${ref}\"#g" "$f"
    echo "platform_ref: $f now uses ref=$ref"
  fi
done < <(find "$dir" -name '*.tf' -not -path '*/.terraform/*' -print0)
