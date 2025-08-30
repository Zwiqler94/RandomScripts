#!/usr/bin/env bash
# v3
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
# - This version avoids 'eval' and builds the find command as an argv array.
# - Runs under bash; invoke with `bash collect_files.sh ...` if your default shell is not bash.
#
# Jake: Edit the EXTENSIONS array to customize what gets collected.

set -euo pipefail

SRC_DIR="${1:-.}"
DEST_DIR="${2:-collected_files}"

# Default extensions; edit as needed.
EXTENSIONS=(pdf txt md mp3 wav m4a flac)

err() { printf 'Error: %s\n' "$*" >&2; }

copy_with_suffix() {
  local src_file="$1"
  local dest_dir="$2"

  local filename base ext dest_path counter
  filename=$(basename -- "$src_file")
  base=${filename%.*}
  ext=${filename##*.}
  dest_path="$dest_dir/$filename"
  counter=1

  while [[ -e "$dest_path" ]]; do
    dest_path="$dest_dir/${base}_$counter.${ext}"
    ((counter++))
  done

  cp -- "$src_file" "$dest_path"
  printf 'Copied: %s -> %s\n' "$src_file" "$dest_path"
}

if [[ ! -d "$SRC_DIR" ]]; then
  err "Source directory '$SRC_DIR' does not exist."
  exit 1
fi

mkdir -p -- "$DEST_DIR"

# Build a 'find' argv array with grouped -iname predicates: ( -iname *.a -o -iname *.b ... )
find_args=(find "$SRC_DIR" -type f "(")
for i in "${!EXTENSIONS[@]}"; do
  ext=${EXTENSIONS[$i]}
  if [[ $i -gt 0 ]]; then
    find_args+=("-o")
  fi
  find_args+=("-iname" "*.${ext}")
done
find_args+=(")" -print0)

# Run find and copy results safely
# shellcheck disable=SC2046
while IFS= read -r -d '' file; do
  copy_with_suffix "$file" "$DEST_DIR"
done < <("${find_args[@]}")

printf "Collection complete. Files saved in '%s'\n" "$DEST_DIR"
