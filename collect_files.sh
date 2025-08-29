#!/usr/bin/env bash
# v2
# Collect specified file types from a source directory (recursively) into a destination directory.
# Safe for spaces/newlines in filenames; avoids overwriting by adding numeric suffixes.
#
# Usage:
#   ./collect_files.sh [source_directory] [destination_directory]
#
# Defaults:
#   source_directory = current directory (.)
#   destination_directory = collected_files
#
# Extensions included by default (case-insensitive):
#   pdf, txt, md, mp3, wav, m4a, flac
#
# Notes:
# - This script uses POSIX-friendly 'find' predicates (-iname with -o) for macOS/Linux portability.
# - Runs under bash; invoke with `bash collect_files.sh ...` if your default shell is not bash.
#
# Jake: If you want to change the set of extensions, edit the EXTENSIONS array below.

set -euo pipefail

SRC_DIR="${1:-.}"
DEST_DIR="${2:-collected_files}"

# Default extensions; edit as needed.
EXTENSIONS=(pdf txt md mp3 wav m4a flac)

# --- helpers ---

err() { printf 'Error: %s\n' "$*" >&2; }

copy_with_suffix() {
  # $1 = src_file, $2 = dest_dir
  local src_file="$1"
  local dest_dir="$2"

  local filename base ext dest_path counter
  filename=$(basename -- "$src_file")
  base=${filename%.*}
  ext=${filename##*.}
  dest_path="$dest_dir/$filename"
  counter=1

  # Append _N before extension to avoid overwrites
  while [[ -e "$dest_path" ]]; do
    dest_path="$dest_dir/${base}_$counter.${ext}"
    ((counter++))
  done

  cp -- "$src_file" "$dest_path"
  printf 'Copied: %s -> %s\n' "$src_file" "$dest_path"
}

# --- checks ---

if [[ ! -d "$SRC_DIR" ]]; then
  err "Source directory '$SRC_DIR' does not exist."
  exit 1
fi

mkdir -p -- "$DEST_DIR"

# Build a portable find predicate: \( -iname '*.ext1' -o -iname '*.ext2' ... \)
build_find_predicate() {
  local pred=""
  local first=1
  for ext in "${EXTENSIONS[@]}"; do
    if [[ $first -eq 1 ]]; then
      pred="-iname '*.${ext}'"
      first=0
    else
      pred="$pred -o -iname '*.${ext}'"
    fi
  done
  printf '%s' "$pred"
}

# --- main ---

# shellcheck disable=SC2046
FIND_PREDICATE=$(build_find_predicate)

# Use -print0 and read -d '' to be robust to any filename characters
# shellcheck disable=SC2086
while IFS= read -r -d '' file; do
  copy_with_suffix "$file" "$DEST_DIR"
done < <(eval find "\"$SRC_DIR\"" -type f \( $FIND_PREDICATE \) -print0)

printf "Collection complete. Files saved in '%s'\n" "$DEST_DIR"
