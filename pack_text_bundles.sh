#!/usr/bin/env bash
# pack_text_bundles.sh
# Bundle text-based files into chunked "bundles" with a JSON source map.
# - Respects .gitignore in single *and nested* git repos via `git ls-files`.
# - Falls back to `find` for non-repo portions of the tree.
# - Parallel pre-processing with xargs -P.
# - Always verbose logging.
#
# Usage:
#   ./pack_text_bundles.sh [source_dir] [out_dir] [chunk_size_bytes]
#
# Defaults:
#   source_dir       = .
#   out_dir          = bundles_out
#   chunk_size_bytes = 5242880   # 5 MiB
#
# Environment overrides:
#   PACK_EXTS="txt,md,js,ts,java,py"     # override extension set
#   PACK_TRIM=1                          # trim trailing spaces on each line
#   PACK_EXCLUDE="node_modules,dist"     # extra dirs to exclude in find() fallback
#   PACK_WORKERS=8                       # number of parallel workers (default = CPU cores)
#
set -euo pipefail

SRC_DIR="${1:-.}"
OUT_DIR="${2:-bundles_out}"
CHUNK_SIZE="${3:-5242880}"  # 5 MiB

DEFAULT_EXTS="txt,md,js,ts,jsx,tsx,java,py,c,cpp,h,cs,sh,html,css,json,xml,yaml,yml,rs,go,php,rb,kt,swift"
IFS=',' read -r -a EXT_ARR <<< "${PACK_EXTS:-$DEFAULT_EXTS}"

mkdir -p -- "$OUT_DIR"

detect_workers() {
  if [[ -n "${PACK_WORKERS:-}" ]]; then
    printf '%s\n' "$PACK_WORKERS"
  else
    if cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null); then
      printf '%s\n' "$cores"
    elif cores=$(sysctl -n hw.ncpu 2>/dev/null); then
      printf '%s\n' "$cores"
    else
      printf '4\n'
    fi
  fi
}

WORKERS=$(detect_workers)

err() { printf 'Error: %s\n' "$*" >&2; }
log() { printf '%s\n' "$*" >&2; }

is_git_repo() {
  git -C "$SRC_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Check if a path should be excluded by PACK_EXCLUDE (dir-name match anywhere in path)
path_is_excluded() {
  local p="$1"
  if [[ -z "${PACK_EXCLUDE:-}" ]]; then return 1; fi
  IFS=',' read -r -a EX_ARR <<< "$PACK_EXCLUDE"
  for ex in "${EX_ARR[@]}"; do
    if [[ "$p" == *"/$ex/"* ]] || [[ "$(basename "$p")" == "$ex" ]]; then
      return 0
    fi
  done
  return 1
}

# Emit NUL-delimited absolute paths from:
#   - git repos (SRC_DIR if repo, otherwise any nested repos under SRC_DIR)
#   - plus non-repo files via find fallback (excluding repo subtrees)
collect_files() {
  local -a emitted_repos=()   # initialize to avoid unbound under set -u

  if is_git_repo; then
    log "Discovery: using git ls-files for top-level repo (respects .gitignore)"
    (cd "$SRC_DIR" && git ls-files --cached --others --exclude-standard -z \
      | while IFS= read -r -d '' rel; do printf '%s\0' "$PWD/$rel"; done)
    emitted_repos+=("$SRC_DIR")
  fi

  # Find nested git repos under SRC_DIR (directories containing a .git folder)
  log "Discovery: scanning for nested git repos..."
  while IFS= read -r -d '' gitdir; do
    repo_root="$(dirname "$gitdir")"

    # Skip if already added or excluded
    if [[ " ${emitted_repos[*]} " == *" $repo_root "* ]]; then
      continue
    fi
    if path_is_excluded "$repo_root"; then
      log "Discovery: skip excluded repo: $repo_root"
      continue
    fi

    if [[ "$repo_root" != "$SRC_DIR" ]]; then
      if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log "Discovery: using git ls-files in nested repo: $repo_root"
        (cd "$repo_root" && git ls-files --cached --others --exclude-standard -z \
          | while IFS= read -r -d '' rel; do printf '%s\0' "$PWD/$rel"; done)
        emitted_repos+=("$repo_root")
      fi
    fi
  done < <(find "$SRC_DIR" \( -name .git -type d \) -print0)

  # Fallback: non-repo files in SRC_DIR excluding PACK_EXCLUDE dirs
  log "Discovery: adding non-repo files via find fallback"
  local -a fargs
  fargs=(find "$SRC_DIR")

  # Prune .git directories always
  fargs+=(-name .git -prune -o)

  # Add PACK_EXCLUDE prunes
  if [[ -n "${PACK_EXCLUDE:-}" ]]; then
    IFS=',' read -r -a EX_ARR <<< "$PACK_EXCLUDE"
    for ex in "${EX_ARR[@]}"; do
      fargs+=(-name "$ex" -prune -o)
    done
  fi

  # Type file and extension filter to cut volume early
  fargs+=(-type f "(")
  for i in "${!EXT_ARR[@]}"; do
    ext="${EXT_ARR[$i]}"
    if [[ $i -gt 0 ]]; then fargs+=(-o); fi
    fargs+=(-iname "*.${ext}")
  done
  fargs+=(")" -print0)

  "${fargs[@]}"
}

has_wanted_ext() {
  local path="$1"
  local name ext lower
  name=$(basename -- "$path")
  ext=${name##*.}
  lower=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
  for e in "${EXT_ARR[@]}"; do
    if [[ "$lower" == "$e" ]]; then
      return 0
    fi
  done
  return 1
}

export SRC_DIR OUT_DIR CHUNK_SIZE PACK_TRIM
export -f has_wanted_ext

TMP_DIR=$(mktemp -d "${OUT_DIR}/.packtmp.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

FILES_NUL="$TMP_DIR/files.nul"
collect_files > "$FILES_NUL"
DISCOVERED_COUNT=$(tr -cd '\0' < "$FILES_NUL" | wc -c | awk '{print $1}')
export DISCOVERED_COUNT  # ensure workers can read it under set -u
log "Discovered files: $DISCOVERED_COUNT"
log "Workers: $WORKERS"
log "Chunk size: $CHUNK_SIZE bytes"
log "Extensions: ${EXT_ARR[*]}"

PROCESSED_COUNT_FILE="$TMP_DIR/processed.count"
echo 0 > "$PROCESSED_COUNT_FILE"

worker() {
  local abs="$1"; local src="$2"; local tmp="$3"; local pcount="$4"
  if ! has_wanted_ext "$abs"; then
    return 0
  fi
  local rel
  if [[ "$abs" == "$src"* ]]; then
    rel="${abs#$src/}"
  else
    rel="$abs"
  fi

  log "[worker $$] Start: $rel"
  local chunk tmpmeta
  chunk=$(mktemp "$tmp/chunk.XXXXXX") || exit 1
  {
    printf '//// BEGIN %s\n' "$rel"
    if [[ "${PACK_TRIM:-0}" -eq 1 ]]; then
      sed -e 's/[[:space:]]\+$//' -- "$abs" | tr -d '\r'
    else
      tr -d '\r' < "$abs"
    fi
  } > "$chunk"

  local bytes lines
  bytes=$(wc -c < "$chunk" | awk '{print $1}')
  lines=$(wc -l < "$chunk" | awk '{print $1}')

  tmpmeta=$(mktemp "$tmp/meta.XXXXXX") || exit 1
  printf '%s\t%s\t%s\t%s\n' "$bytes" "$lines" "$rel" "$chunk" > "$tmpmeta"

  {
    flock 9
    count=$(cat "$pcount"); count=$((count + 1)); echo "$count" > "$pcount"
    printf '[worker %s] Done : %s (%s B, %s L) — processed %s/%s\n' "$$" "$rel" "$bytes" "$lines" "$count" "${DISCOVERED_COUNT:-?}" >&2
  } 9>"$pcount.lock"
}
export -f worker

command -v xargs >/dev/null 2>&1 || { err "xargs is required."; exit 1; }

# Use -I{} to pass file path robustly as $1
xargs -0 -I{} -n 1 -P "$WORKERS" bash -c 'worker "$1" "$2" "$3" "$4"' _ "{}" "$SRC_DIR" "$TMP_DIR" "$PROCESSED_COUNT_FILE" < "$FILES_NUL"

bundle_index=1
bundle_path="$(printf '%s/bundle_%04d.txt' "$OUT_DIR" "$bundle_index")"
: > "$bundle_path"
bundle_bytes=0
bundle_lines=0
total_bytes=0

map_path="$OUT_DIR/bundles.map.json"
printf '{\n  "bundles": [\n' > "$map_path"
need_comma_bundle=0

open_bundle_object() {
  local bundle_name="$1"
  if [[ $need_comma_bundle -eq 1 ]]; then printf ',\n' >> "$map_path"; fi
  printf '    {\n      "bundle": "%s",\n      "files": [\n' "$bundle_name" >> "$map_path"
  need_comma_file=0
  need_comma_bundle=1
  log ">>> Starting $bundle_name"
}

close_bundle_object() {
  printf '\n      ]\n    }' >> "$map_path"
  log "<<< Closed $(basename "$bundle_path") (${bundle_bytes} bytes, ${bundle_lines} lines)"
  total_bytes=$((total_bytes + bundle_bytes))
}

append_map_segment() {
  local src_rel="$1" off_s="$2" off_e="$3" line_s="$4" line_c="$5"
  local esc_src
  esc_src=$(printf '%s' "$src_rel" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  if [[ $need_comma_file -eq 1 ]]; then printf ',\n' >> "$map_path"; fi
  printf '        {"source": "%s", "offset_start": %s, "offset_end": %s, "line_start": %s, "line_count": %s}' \
    "$esc_src" "$off_s" "$off_e" "$line_s" "$line_c" >> "$map_path"
  need_comma_file=1
}

new_bundle() {
  local idx="$1"
  bundle_path="$(printf '%s/bundle_%04d.txt' "$OUT_DIR" "$idx")"
  : > "$bundle_path"
  bundle_bytes=0
  bundle_lines=0
  open_bundle_object "$(basename "$bundle_path")"
}

meta_count=$(ls "$TMP_DIR"/meta.* 2>/dev/null | wc -l | awk '{print $1}')
if (( meta_count == 0 )); then
  log "No matching files found. Nothing to do."
  printf '\n  ]\n}\n' >> "$map_path"
  log "Bundling complete (empty)."
  log "Bundles dir: $OUT_DIR"
  log "Source map:  $map_path"
  exit 0
fi

LC_ALL=C sort -t $'\t' -k3,3 "$TMP_DIR"/meta.* | while IFS=$'\t' read -r bytes lines rel chunk; do
  prospective=$((bundle_bytes + bytes))
  if (( prospective > CHUNK_SIZE && bundle_bytes > 0 )); then
    close_bundle_object
    ((bundle_index++))
    bundle_path="$(printf '%s/bundle_%04d.txt' "$OUT_DIR" "$bundle_index")"
    : > "$bundle_path"
    bundle_bytes=0
    bundle_lines=0
    open_bundle_object "$(basename "$bundle_path")"
  fi

  if (( bundle_bytes == 0 && need_comma_bundle == 0 )); then
    open_bundle_object "$(basename "$bundle_path")"
  fi

  off_start=$((bundle_bytes))
  line_start=$((bundle_lines + 1))

  cat -- "$chunk" >> "$bundle_path"
  bundle_bytes=$((bundle_bytes + bytes))
  bundle_lines=$((bundle_lines + lines))

  off_end=$bundle_bytes
  line_count=$lines

  append_map_segment "$rel" "$off_start" "$off_end" "$line_start" "$line_count"
  log "Added $rel (${bytes} B, ${lines} L) to $(basename "$bundle_path") [offset ${off_start}→${off_end}]"
done

if (( bundle_bytes > 0 )); then
  close_bundle_object
fi

printf '\n  ]\n}\n' >> "$map_path"

bundles_total=$bundle_index
files_total=$meta_count

log "Finished: ${bundles_total} bundles, ${files_total} files, ${total_bytes} bytes"
log "Bundles dir: $OUT_DIR"
log "Source map:  $map_path"
