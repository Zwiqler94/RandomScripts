#!/usr/bin/env bash
# Script to collect all PDF files from a given source directory and its subdirectories
# into a destination directory.
#
# Usage:
#   ./collect_pdfs.sh [source_directory] [destination_directory]
#
# If source_directory is not provided, the current directory (".") is used.
# If destination_directory is not provided, a folder named "collected_pdfs" is created
# in the current working directory.

set -euo pipefail

# Determine source and destination directories
SRC_DIR="${1:-.}"
DEST_DIR="${2:-collected_pdfs}"

# Create the destination directory if it doesn't exist
mkdir -p "$DEST_DIR"

# Verify that the source directory exists
if [[ ! -d "$SRC_DIR" ]]; then
  echo "Error: Source directory '$SRC_DIR' does not exist." >&2
  exit 1
fi

# Find and copy PDF files (case-insensitive) from the source directory and subdirectories
# to the destination directory. If duplicate file names are encountered, append a
# numeric suffix to avoid overwriting.
shopt -s nullglob nocaseglob

copy_file() {
  local src_file="$1"
  local dest_dir="$2"

  # Extract the base filename
  local filename
  filename=$(basename "$src_file")
  local base="${filename%.*}"
  local ext="${filename##*.}"

  # Determine the full destination path
  local dest_path="$dest_dir/$filename"
  local counter=1

  # If file with the same name exists, append a numeric suffix
  while [[ -e "$dest_path" ]]; do
    dest_path="$dest_dir/${base}_$counter.$ext"
    ((counter++))
  done

  # Copy the file
  cp "$src_file" "$dest_path"
  echo "Copied: $src_file -> $dest_path"
}

# Iterate through all PDF files found in source directory
while IFS= read -r -d '' file; do
  copy_file "$file" "$DEST_DIR"
done < <(find "$SRC_DIR" -type f \( -iname '*.pdf' \) -print0)

shopt -u nullglob nocaseglob

echo "PDF collection complete. Files are saved in '$DEST_DIR'"
