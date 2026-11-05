#!/usr/bin/env bash
#
# iso-download.sh - download a Linux installer ISO to a Proxmox VE storage,
# from the distribution's official site, checksum-verified.
#
# Run on the Proxmox VE host as root:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/farmnerds-net/proxmox-host-scripts/main/iso-download.sh)"
#
# Options:
#   --check   look up every distribution's current ISO and checksum without
#             downloading anything; exits non-zero if any lookup fails
#   --list    print the catalog
#   --help
#
# Presets (each skips its question):
#   ISO_STORAGE=local          storage to save to (must allow ISO images)
#   ISO_DISTRO=debian          a catalog slug (see --list), or 'url'
#   ISO_URL=https://.../x.iso  with ISO_DISTRO=url: the ISO to fetch
#   ISO_CHECKSUM=<hex>         with ISO_DISTRO=url: its SHA-256 or SHA-512
#   ISO_CONFIRM=yes            skip the final confirmation
#
# Local checkouts (for testing):
#   HOST_SCRIPTS_SRC=/path/to/proxmox-host-scripts  RECIPES_SRC=/path/to/proxmox-recipes
# Branches on GitHub:
#   HOST_SCRIPTS_REF=<branch>  RECIPES_REF=<branch>   (default main)
#
# The download is done by Proxmox VE itself (the same as "Download from
# URL" in the web UI), which verifies the checksum; nothing is kept if it
# does not match. The last storage used is remembered in
# /etc/proxmox-host-scripts/iso-download.conf.

set -Eeuo pipefail

HS_REPO="farmnerds-net/proxmox-host-scripts"
HS_REF=${HOST_SCRIPTS_REF:-main}
RCP_REF=${RECIPES_REF:-main}

hs_load() {   # <repo-relative path in proxmox-host-scripts or "core">
  local body src
  if [[ "$1" == core ]]; then
    if [[ -n "${RECIPES_SRC:-}" ]]; then
      body=$(cat -- "${RECIPES_SRC%/}/misc/core.func")
    else
      src="https://raw.githubusercontent.com/farmnerds-net/proxmox-recipes/${RCP_REF}/misc/core.func"
      body=$(curl -fsSL --retry 2 --max-time 30 "$src")
    fi
  elif [[ -n "${HOST_SCRIPTS_SRC:-}" ]]; then
    body=$(cat -- "${HOST_SCRIPTS_SRC%/}/$1")
  else
    body=$(curl -fsSL --retry 2 --max-time 30 "https://raw.githubusercontent.com/${HS_REPO}/${HS_REF}/$1")
  fi || { printf 'iso-download: could not load %s\n' "$1" >&2; exit 1; }
  # shellcheck source=/dev/null
  source /dev/stdin <<<"$body"
}

hs_load core
hs_load lib/ui.func
hs_load lib/progress.func
hs_load iso/catalog.func

# shellcheck disable=SC2034  # read by lib/ui.func
UI_TITLE="Proxmox ISO download"
# shellcheck disable=SC2034  # read by lib/ui.func
UI_CANCEL_MSG="Cancelled. Nothing was downloaded."
HS_CONF_DIR="/etc/proxmox-host-scripts"
HS_CONF="${HS_CONF_DIR}/iso-download.conf"
HS_LOG_DIR="/var/log/proxmox-host-scripts"
NODE=$(hostname)

# ---- saved settings ------------------------------------------------------------

conf_last_storage() {
  [[ -r "$HS_CONF" ]] || return 0
  sed -n 's/^ISO_LAST_STORAGE=\([A-Za-z0-9._-]*\)$/\1/p' "$HS_CONF" | tail -n 1
}

conf_save_storage() {   # <storage>
  install -d -m 0755 "$HS_CONF_DIR"
  printf '# Written by proxmox-host-scripts iso-download.sh\nISO_LAST_STORAGE=%s\n' "$1" >"$HS_CONF"
}

# ---- storage -------------------------------------------------------------------

iso_storages() {   # -> "name free_kib type" for active storages that take ISOs
  pvesm status --content iso 2>/dev/null |
    awk 'NR > 1 && $3 == "active" { print $1, $6, $2 }'
}

storage_free_kib() {   # <storage>
  iso_storages | awk -v s="$1" '$1 == s { print $2 }'
}

choose_storage() {
  local last list name free type def
  local -a items=()
  list=$(iso_storages)
  [[ -n "$list" ]] || die "No active storage on this host can hold ISO images. Enable 'ISO image' content on a storage (Datacenter > Storage) first."
  last=$(conf_last_storage)
  def=""
  while read -r name free type; do
    if [[ "$name" == "$last" ]]; then
      items+=("$name" "$(human_bytes $(( free * 1024 ))) free, ${type}  (last used)")
      def=$name
    else
      items+=("$name" "$(human_bytes $(( free * 1024 ))) free, ${type}")
    fi
  done <<<"$list"
  [[ -n "$def" ]] || def=${items[0]}
  ui_menu ISO_STORAGE "Where should the ISO be saved?

These storages can hold ISO images." "$def" "${items[@]}"
  grep -qx -- "$ISO_STORAGE" < <(awk '{ print $1 }' <<<"$list") ||
    die "Storage '${ISO_STORAGE}' is not an active storage that can hold ISO images."
}

# ---- choosing a distribution ---------------------------------------------------

distro_items() {   # <slug>... -> menu items "slug" "name"
  local s
  for s in "$@"; do
    if [[ "$(iso_field "$s" 4)" == manual ]]; then
      printf '%s\n%s\n' "$s" "$(iso_field "$s" 3)  (paste link)"
    else
      printf '%s\n%s\n' "$s" "$(iso_field "$s" 3)"
    fi
  done
}

choose_from() {   # <prompt> <slug>...
  local prompt=$1
  local -a items=()
  shift
  mapfile -t items < <(distro_items "$@")
  ui_menu ISO_DISTRO "$prompt" "$1" "${items[@]}"
}

valid_search() { [[ "$1" =~ [A-Za-z0-9] ]]; }

choose_distro() {
  local group q
  local -a found=() items=()
  if ui_is_set ISO_DISTRO; then return 0; fi
  ui_menu group "What would you like to download?" server \
    server  "Server distributions" \
    desktop "Desktop distributions" \
    gaming  "Gaming distributions" \
    search  "Find your own (search by name)" \
    url     "Paste a download link and checksum"
  case "$group" in
    server|desktop|gaming)
      mapfile -t found < <(iso_slugs "$group")
      choose_from "Which ${group} distribution?" "${found[@]}"
      ;;
    search)
      ui_input q "Search for a distribution by name (for example: mint, fedora, bazzite)." "" \
        valid_search "Type at least one letter or digit."
      mapfile -t found < <(iso_search "$q")
      if (( ${#found[@]} == 0 )); then
        ui_msg "Nothing in the list matches '${q}'.

You can still download it: find the ISO on that distribution's official website, copy the download link and its SHA-256 (or SHA-512) checksum from the same page, and paste them in the next step."
        ISO_DISTRO=url
      else
        mapfile -t items < <(distro_items "${found[@]}")
        ui_menu ISO_DISTRO "Matches for '${q}':" "${found[0]}" "${items[@]}" url "Not listed: paste a download link"
      fi
      ;;
    url) ISO_DISTRO=url ;;
  esac
}

valid_iso_url() { [[ "$1" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[^[:space:]]*\.iso([?#][^[:space:]]*)?$ ]]; }
valid_checksum() { [[ "${1,,}" =~ ^([0-9a-f]{64}|[0-9a-f]{128})$ ]]; }

# Fill RES_* from a link and checksum the user pasted.
resolve_pasted() {   # [<official pages to mention>]
  local note=""
  [[ -n "${1:-}" ]] && note="

Get both from the official site: $1"
  ui_input ISO_URL "Download link of the ISO (https://..., ending in .iso).${note}" "" valid_iso_url \
    "Enter an https:// link that ends in .iso."
  ui_input ISO_CHECKSUM "Its SHA-256 or SHA-512 checksum, from the same official page.

The download is checked against it and discarded if it doesn't match." "" valid_checksum \
    "Paste the 64-character (SHA-256) or 128-character (SHA-512) checksum."
  RES_URL=$ISO_URL
  RES_FILE=${ISO_URL%%[?#]*}
  RES_FILE=${RES_FILE##*/}
  [[ "$RES_FILE" =~ ^[A-Za-z0-9._+-]+\.iso$ ]] || die "Cannot use '${RES_FILE}' as a file name."
  RES_SUM=${ISO_CHECKSUM,,}
  if (( ${#RES_SUM} == 64 )); then RES_ALGO=sha256; else RES_ALGO=sha512; fi
  RES_VERSION="(from your link)"
  ISO_NAME=$RES_FILE
}

resolve_choice() {
  if [[ "$ISO_DISTRO" == url ]]; then
    resolve_pasted
    return 0
  fi
  iso_entry "$ISO_DISTRO" >/dev/null || die "Unknown distribution '${ISO_DISTRO}' (see --list)."
  ISO_NAME=$(iso_field "$ISO_DISTRO" 3)
  if [[ "$(iso_field "$ISO_DISTRO" 4)" == manual ]]; then
    resolve_pasted "${ISO_MANUAL_PAGES[$ISO_DISTRO]}"
    ISO_NAME="$(iso_field "$ISO_DISTRO" 3)"
    return 0
  fi
  say "   Looking up the current ${ISO_NAME} release..."
  iso_resolve "$ISO_DISTRO" 2>>"$RCP_LOG" ||
    die "Could not find the current ${ISO_NAME} ISO on its official site (details in ${RCP_LOG}). Its site may have changed; please report it."
  log_line "Resolved ${ISO_DISTRO}: ${RES_VERSION} ${RES_URL} ${RES_ALGO}:${RES_SUM}"
}

# ---- download ------------------------------------------------------------------

remote_size() {   # <url> -> bytes (0 if unknown)
  curl -fsSIL --max-time 60 "$1" 2>/dev/null |
    awk 'tolower($1) == "content-length:" { n = $2 } END { gsub(/\r/, "", n); print n + 0 }'
}

already_there() {   # <storage> <file>
  pvesm list "$1" --content iso 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qxF -- "$1:iso/$2"
}

task_result() {   # <upid> -> the task's exit status ("OK" or the error)
  pvesh get "/nodes/${NODE}/tasks/$1/status" --output-format json 2>/dev/null |
    perl -MJSON::PP -e 'my $d = decode_json(join "", <STDIN>); print $d->{exitstatus} // "running"'
}

download() {   # <storage> <url> <file> <algo> <sum> <total bytes> <label>
  local st=$1 url=$2 file=$3 algo=$4 sum=$5 total=$6 label=$7
  local out final pid now size last_size=0 last_t rate=0 upid result
  rcp_mktemp out
  final=$(pvesm path "${st}:iso/${file}")
  log_line "Downloading ${url} -> ${final}"
  pvesh create "/nodes/${NODE}/storage/${st}/download-url" --content iso \
    --filename "$file" --url "$url" --checksum-algorithm "$algo" --checksum "$sum" \
    >"$out" 2>&1 </dev/null &
  pid=$!
  last_t=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    size=$(stat -c %s "${final}".tmp_dwnl.* 2>/dev/null | head -n 1 || true)
    now=$(date +%s)
    if [[ -n "$size" ]]; then
      if (( now > last_t )); then
        rate=$(( (rate + (size - last_size) / (now - last_t)) / (rate > 0 ? 2 : 1) ))
        last_size=$size
        last_t=$now
      fi
      if (( total > 0 && size >= total )) || grep -q 'calculating checksum' "$out"; then
        progress_status "Verifying the ${algo^^} checksum..."
      else
        progress_draw "$label" "$size" "$total" "$rate"
      fi
    fi
    sleep 0.5
  done
  wait "$pid" || true
  progress_done
  cat -- "$out" >>"$RCP_LOG"
  upid=$(grep -oE '^UPID:[^[:space:]]+' "$out" | tail -n 1 || true)
  [[ -n "$upid" ]] || die "Proxmox did not start the download (see ${RCP_LOG})."
  result=$(task_result "$upid")
  [[ "$result" == OK ]] || die "The download failed: ${result}"
}

# ---- modes ---------------------------------------------------------------------

cmd_list() {
  local s
  printf '%-20s %-8s %-7s %s\n' SLUG GROUP KIND NAME
  for s in $(iso_slugs); do
    printf '%-20s %-8s %-7s %s\n' "$s" "$(iso_field "$s" 2)" "$(iso_field "$s" 4)" "$(iso_field "$s" 3)"
  done
}

cmd_check() {
  local s bad=0 size err
  rcp_mktemp err
  say_head "Checking every distribution's current ISO (nothing is downloaded)"
  for s in $(iso_slugs); do
    if [[ "$(iso_field "$s" 4)" == manual ]]; then
      printf ' %s[ -- ]%s %-20s manual: %s\n' "$C_YELLOW" "$C_RESET" "$s" "${ISO_MANUAL_PAGES[$s]%% *}"
      continue
    fi
    if ! iso_resolve "$s" 2>"$err"; then
      printf ' %s[fail]%s %-20s %s\n' "$C_RED" "$C_RESET" "$s" "$(tr '\n' ' ' <"$err")"
      bad=$(( bad + 1 ))
      continue
    fi
    size=$(remote_size "$RES_URL")
    if (( size < 20000000 )); then
      printf ' %s[fail]%s %-20s %s is not downloadable (size %s)\n' "$C_RED" "$C_RESET" "$s" "$RES_URL" "$(human_bytes "$size")"
      bad=$(( bad + 1 ))
      continue
    fi
    printf ' %s[ ok ]%s %-20s %-16s %8s  %s\n' "$C_GREEN" "$C_RESET" "$s" "$RES_VERSION" "$(human_bytes "$size")" "$RES_FILE"
  done
  if (( bad )); then
    say_err "${bad} lookup(s) failed."
    return 1
  fi
  say_ok "All lookups work."
}

cmd_download() {
  local size free_kib label
  preflight_checks
  choose_storage
  choose_distro
  resolve_choice
  label=$ISO_NAME
  if already_there "$ISO_STORAGE" "$RES_FILE"; then
    say_ok "${RES_FILE} is already on ${ISO_STORAGE}; nothing to download."
    conf_save_storage "$ISO_STORAGE"
    return 0
  fi
  size=$(remote_size "$RES_URL")
  free_kib=$(storage_free_kib "$ISO_STORAGE")
  if (( size > 0 && size / 1024 > free_kib )); then
    die "Not enough space on ${ISO_STORAGE}: the ISO is $(human_bytes "$size"), $(human_bytes $(( free_kib * 1024 ))) is free."
  fi
  ui_yesno ISO_CONFIRM "Download this ISO?

  Distribution: ${ISO_NAME}
  Version:      ${RES_VERSION}
  File:         ${RES_FILE}
  Size:         $( (( size > 0 )) && human_bytes "$size" || printf 'unknown')
  From:         $(sed -E 's#^https://([^/]+)/.*#\1#' <<<"$RES_URL")
  Checksum:     ${RES_ALGO^^} (verified after download)
  Save to:      ${ISO_STORAGE}" yes
  [[ "$ISO_CONFIRM" == yes ]] || ui_cancelled
  log_line "Settings: storage=${ISO_STORAGE} distro=${ISO_DISTRO} file=${RES_FILE}"
  download "$ISO_STORAGE" "$RES_URL" "$RES_FILE" "$RES_ALGO" "$RES_SUM" "$size" "$label"
  conf_save_storage "$ISO_STORAGE"
  say_ok "${RES_FILE} downloaded to ${ISO_STORAGE} and its ${RES_ALGO^^} checksum verified"
  say "   Use it when creating a VM: OS > ISO image > ${ISO_STORAGE}:iso/${RES_FILE}"
}

usage() {
  cat <<'USAGE'
Usage: iso-download.sh [--check | --list | --help]

Download a Linux installer ISO to a Proxmox VE storage, from the
distribution's official site, checksum-verified.

  --check   look up every distribution's current ISO (downloads nothing)
  --list    print the catalog

Presets (each skips its question):
  ISO_STORAGE=local   ISO_DISTRO=<slug>|url   ISO_URL=...   ISO_CHECKSUM=...
  ISO_CONFIRM=yes
USAGE
}

main() {
  mkdir -p "$HS_LOG_DIR"
  RCP_LOG="${HS_LOG_DIR}/iso-download.log"
  (umask 077; touch "$RCP_LOG")
  rcp_install_traps
  log_line "==== iso-download ${1:-} ===="
  case "${1:-}" in
    --check) cmd_check ;;
    --list)  cmd_list ;;
    -h|--help) usage ;;
    "") say_head "Proxmox ISO download"; cmd_download ;;
    *) die "Unknown option '$1' (try --help)." ;;
  esac
}

main "$@"
