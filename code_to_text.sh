#!/usr/bin/env bash
# Convert code files into .txt files, preserving filenames but with .txt extension.
# Works recursively in a given source directory.
#
# Usage:
#   ./code_to_txt.sh [source_directory] [destination_directory]
#
# Defaults:
#   source_directory = current directory (.)
#   destination_directory = code_as_txt
#
# Extensions included: js, ts, java, py, c, cpp, h, cs, sh, html, css, json, xml, yaml, yml

set -euo pipefail

SRC_DIR="${1:-.}"
DEST_DIR="${2:-code_as_txt}"

EXTENSIONS=(js ts java py c cpp h cs sh html css json xml yaml yml)

mkdir -p "$DEST_DIR"

copy_as_txt() {
  local src_file="$1"
  local dest_dir="$2"

  local filename base
  filename=$(basename -- "$src_file")
  base=${filename%.*}
  dest_path="$dest_dir/${base}.txt"
  counter=1

  # Avoid overwriting by appending suffix
  while [[ -e "$dest_path" ]]; do
    dest_path="$dest_dir/${base}_$counter.txt"
    ((counter++))
  done

  cp -- "$src_file" "$dest_path"
  echo "Converted: $src_file -> $dest_path"
}

# Build find args
find_args=(find "$SRC_DIR" -type f "(")
for i in "${!EXTENSIONS[@]}"; do
  ext=${EXTENSIONS[$i]}
  if [[ $i -gt 0 ]]; then
    find_args+=("-o")
  fi
  find_args+=("-iname" "*.${ext}")
done
find_args+=(")" -print0)

while IFS= read -r -d '' file; do
  copy_as_txt "$file" "$DEST_DIR"
done < <("${find_args[@]}")

echo "All code files converted to txt in '$DEST_DIR'."
