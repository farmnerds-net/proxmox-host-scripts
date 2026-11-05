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

# ---- the questions, as steps you can go back through ----------------------------
#
# Each step asks one question into one variable. Back returns to the
# previous step with the earlier answer pre-selected; on the first screen
# the button reads Exit and leaves. Steps whose variable was preset are
# skipped both ways, so going back never lands on them.

declare -gA WZ_PRESET=() WZ_LAST=()
WZ_HIST=()
WZ_STATE=""
ISO_SIZE=0

wz_var() {   # <step> -> the variable it asks for
  case $1 in
    storage) printf 'ISO_STORAGE' ;;
    group) printf 'ISO_GROUP' ;;
    list|results) printf 'ISO_DISTRO' ;;
    search) printf 'ISO_QUERY' ;;
    paste_url) printf 'ISO_URL' ;;
    paste_sum) printf 'ISO_CHECKSUM' ;;
    confirm) printf 'ISO_CONFIRM' ;;
  esac
}

wz_init() {
  local v
  for v in ISO_STORAGE ISO_GROUP ISO_DISTRO ISO_QUERY ISO_URL ISO_CHECKSUM ISO_CONFIRM; do
    if ui_is_set "$v"; then WZ_PRESET[$v]=1; fi
  done
  return 0
}

wz_clear() {   # <var>: forget an answer, unless it was preset
  if [[ -z "${WZ_PRESET[$1]:-}" ]]; then unset "$1"; fi
}

wz_go() {   # <next step>: remember this step (unless preset) and move on
  local v
  v=$(wz_var "$WZ_STATE")
  if [[ -n "$v" && -z "${WZ_PRESET[$v]:-}" ]]; then WZ_HIST+=("$WZ_STATE"); fi
  WZ_STATE=$1
}

wz_back() {   # go back one question, or leave from the first one
  local v
  v=$(wz_var "$WZ_STATE")
  if [[ -n "$v" ]]; then wz_clear "$v"; fi
  if (( ${#WZ_HIST[@]} == 0 )); then ui_cancelled; fi
  WZ_STATE=${WZ_HIST[-1]}
  unset 'WZ_HIST[-1]'
  v=$(wz_var "$WZ_STATE")
  WZ_LAST[$v]=${!v:-}
  wz_clear "$v"
}

step_storage() {
  local last list name free type def
  local -a items=()
  list=$(iso_storages)
  [[ -n "$list" ]] || die "No active storage on this host can hold ISO images. Enable 'ISO image' content on a storage (Datacenter > Storage) first."
  last=$(conf_last_storage)
  def=${WZ_LAST[ISO_STORAGE]:-}
  while read -r name free type; do
    if [[ "$name" == "$last" ]]; then
      items+=("$name" "$(human_bytes $(( free * 1024 ))) free, ${type}  (last used)")
      [[ -n "$def" ]] || def=$name
    else
      items+=("$name" "$(human_bytes $(( free * 1024 ))) free, ${type}")
    fi
  done <<<"$list"
  [[ -n "$def" ]] || def=${items[0]}
  ui_menu ISO_STORAGE "Where should the ISO be saved?

These storages can hold ISO images." "$def" "${items[@]}" || return 1
  grep -qx -- "$ISO_STORAGE" < <(awk '{ print $1 }' <<<"$list") ||
    die "Storage '${ISO_STORAGE}' is not an active storage that can hold ISO images."
}

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

valid_search() { [[ "$1" =~ [A-Za-z0-9] ]]; }
valid_iso_url() { [[ "$1" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[^[:space:]]*\.iso([?#][^[:space:]]*)?$ ]]; }
valid_checksum() { [[ "${1,,}" =~ ^([0-9a-f]{64}|[0-9a-f]{128})$ ]]; }

# Fill RES_* from the link and checksum the user pasted.
use_pasted() {
  RES_URL=$ISO_URL
  RES_FILE=${ISO_URL%%[?#]*}
  RES_FILE=${RES_FILE##*/}
  [[ "$RES_FILE" =~ ^[A-Za-z0-9._+-]+\.iso$ ]] || die "Cannot use '${RES_FILE}' as a file name."
  RES_SUM=${ISO_CHECKSUM,,}
  if (( ${#RES_SUM} == 64 )); then RES_ALGO=sha256; else RES_ALGO=sha512; fi
  RES_VERSION="(from your link)"
  if [[ "$ISO_DISTRO" == url ]]; then ISO_NAME=$RES_FILE; fi
}

# Not a question: decide what comes after a distribution was picked.
step_pick() {
  if [[ "$ISO_DISTRO" == url ]]; then
    ISO_NAME=""
    WZ_STATE=paste_url
    return 0
  fi
  iso_entry "$ISO_DISTRO" >/dev/null || die "Unknown distribution '${ISO_DISTRO}' (see --list)."
  ISO_NAME=$(iso_field "$ISO_DISTRO" 3)
  if [[ "$(iso_field "$ISO_DISTRO" 4)" == manual ]]; then
    WZ_STATE=paste_url
    return 0
  fi
  say "   Looking up the current ${ISO_NAME} release..."
  if iso_resolve "$ISO_DISTRO" 2>>"$RCP_LOG"; then
    log_line "Resolved ${ISO_DISTRO}: ${RES_VERSION} ${RES_URL} ${RES_ALGO}:${RES_SUM}"
    WZ_STATE=confirm
    return 0
  fi
  local why="Could not find the current ${ISO_NAME} ISO on its official site (details in ${RCP_LOG}). Its site may have changed; please report it."
  [[ -z "${WZ_PRESET[ISO_DISTRO]:-}" ]] || die "$why"
  ui_msg "$why"
  WZ_STATE=pick   # wz_back goes back to the list it was picked from
  wz_back
}

# Ask everything; returns once the user has confirmed a download.
# Returns 1 if the ISO is already there (nothing to do).
wizard() {
  local -a found=() items=()
  local note free_kib
  wz_init
  WZ_STATE=storage
  while true; do
    # shellcheck disable=SC2034  # read by lib/ui.func
    if (( ${#WZ_HIST[@]} )); then UI_BACK_LABEL=Back; else UI_BACK_LABEL=Exit; fi
    case $WZ_STATE in
      storage)
        if step_storage; then wz_go group; else wz_back; fi
        ;;
      group)
        if [[ -n "${WZ_PRESET[ISO_DISTRO]:-}" ]]; then WZ_STATE=pick; continue; fi
        wz_clear ISO_DISTRO
        if ui_menu ISO_GROUP "What would you like to download?" "${WZ_LAST[ISO_GROUP]:-server}" \
          server  "Server distributions" \
          desktop "Desktop distributions" \
          gaming  "Gaming distributions" \
          search  "Find your own (search by name)" \
          url     "Paste a download link and checksum"; then
          case $ISO_GROUP in
            server|desktop|gaming) wz_go list ;;
            search) wz_go search ;;
            *) ISO_DISTRO=url; wz_go pick ;;
          esac
        else
          wz_back
        fi
        ;;
      list)
        mapfile -t found < <(iso_slugs "$ISO_GROUP")
        mapfile -t items < <(distro_items "${found[@]}")
        if ui_menu ISO_DISTRO "Which ${ISO_GROUP} distribution?" "${WZ_LAST[ISO_DISTRO]:-${found[0]}}" "${items[@]}"; then
          wz_go pick
        else
          wz_back
        fi
        ;;
      search)
        wz_clear ISO_DISTRO
        if ui_input ISO_QUERY "Search for a distribution by name (for example: mint, fedora, bazzite)." \
          "${WZ_LAST[ISO_QUERY]:-}" valid_search "Type at least one letter or digit."; then
          wz_go results
        else
          wz_back
        fi
        ;;
      results)
        mapfile -t found < <(iso_search "$ISO_QUERY")
        if (( ${#found[@]} == 0 )); then
          ui_msg "Nothing in the list matches '${ISO_QUERY}'.

You can still download it: find the ISO on that distribution's official website, copy the download link and its SHA-256 (or SHA-512) checksum from the same page, and paste them in the next step. (Back there returns to the search.)"
          ISO_DISTRO=url
          WZ_STATE=pick   # not remembered: Back from the link goes to the search
          continue
        fi
        mapfile -t items < <(distro_items "${found[@]}")
        if ui_menu ISO_DISTRO "Matches for '${ISO_QUERY}':" "${WZ_LAST[ISO_DISTRO]:-${found[0]}}" \
          "${items[@]}" url "Not listed: paste a download link"; then
          wz_go pick
        else
          wz_back
        fi
        ;;
      pick)
        step_pick
        ;;
      paste_url)
        note=""
        if [[ "$ISO_DISTRO" != url ]]; then
          note="

Get both from the official site: ${ISO_MANUAL_PAGES[$ISO_DISTRO]}"
        fi
        if ui_input ISO_URL "Download link of the ISO (https://..., ending in .iso).${note}" \
          "${WZ_LAST[ISO_URL]:-}" valid_iso_url "Enter an https:// link that ends in .iso."; then
          wz_go paste_sum
        else
          wz_back
        fi
        ;;
      paste_sum)
        if ui_input ISO_CHECKSUM "Its SHA-256 or SHA-512 checksum, from the same official page.

The download is checked against it and discarded if it doesn't match." "${WZ_LAST[ISO_CHECKSUM]:-}" \
          valid_checksum "Paste the 64-character (SHA-256) or 128-character (SHA-512) checksum."; then
          use_pasted
          wz_go confirm
        else
          wz_back
        fi
        ;;
      confirm)
        if already_there "$ISO_STORAGE" "$RES_FILE"; then
          say_ok "${RES_FILE} is already on ${ISO_STORAGE}; nothing to download."
          conf_save_storage "$ISO_STORAGE"
          return 1
        fi
        ISO_SIZE=$(remote_size "$RES_URL")
        free_kib=$(storage_free_kib "$ISO_STORAGE")
        if (( ISO_SIZE > 0 && ISO_SIZE / 1024 > free_kib )); then
          note="Not enough space on ${ISO_STORAGE}: the ISO is $(human_bytes "$ISO_SIZE"), $(human_bytes $(( free_kib * 1024 ))) is free."
          if [[ -n "${WZ_PRESET[ISO_CONFIRM]:-}" ]]; then die "$note"; fi
          ui_msg "${note}

Pick another storage or a smaller ISO."
          wz_back
          continue
        fi
        if ui_yesno ISO_CONFIRM "Download this ISO?

  Distribution: ${ISO_NAME}
  Version:      ${RES_VERSION}
  File:         ${RES_FILE}
  Size:         $( (( ISO_SIZE > 0 )) && human_bytes "$ISO_SIZE" || printf 'unknown')
  From:         $(sed -E 's#^https://([^/]+)/.*#\1#' <<<"$RES_URL")
  Checksum:     ${RES_ALGO^^} (verified after download)
  Save to:      ${ISO_STORAGE}" yes Download Back && [[ "$ISO_CONFIRM" == yes ]]; then
          return 0
        fi
        [[ -z "${WZ_PRESET[ISO_CONFIRM]:-}" ]] || ui_cancelled   # preset "no": just stop
        wz_back
        ;;
    esac
  done
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
  preflight_checks
  wizard || return 0
  log_line "Settings: storage=${ISO_STORAGE} distro=${ISO_DISTRO} file=${RES_FILE}"
  download "$ISO_STORAGE" "$RES_URL" "$RES_FILE" "$RES_ALGO" "$RES_SUM" "$ISO_SIZE" "$ISO_NAME"
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
