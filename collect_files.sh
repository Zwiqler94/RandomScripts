#!/usr/bin/env bash
# v1
# Script to collect specified file types from a source directory and subdirectories
# into a destination directory.
#
# Usage:
#   ./collect_files.sh [source_directory] [destination_directory]
#
# Defaults:
#   source_directory = current directory (.)
#   destination_directory = collected_files
#
# Extensions included by default: pdf, txt, md, mp3, wav, m4a, flac

set -euo pipefail

SRC_DIR="${1:-.}"
DEST_DIR="${2:-collected_files}"

# Extensions to collect
EXTENSIONS=("pdf" "txt" "md" "mp3" "wav" "m4a" "flac")

mkdir -p "$DEST_DIR"

for ext in "${EXTENSIONS[@]}"; do
  # Case-insensitive search for files matching the extension
  find "$SRC_DIR" -type f -iname "*.${ext}" | while read -r file; do
    base=$(basename "$file")
    dest="$DEST_DIR/$base"
    counter=1
    # Avoid overwriting duplicates
    while [[ -e "$dest" ]]; do
      dest="$DEST_DIR/${base%.*}_$counter.${base##*.}"
      ((counter++))
    done
    cp "$file" "$dest"
    echo "Copied: $file -> $dest"
  done
done
