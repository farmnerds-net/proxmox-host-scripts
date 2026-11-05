#!/usr/bin/env bash
#
# kernel-manager.sh - see which Proxmox kernels this host runs, boots,
# has installed and could install, check them against this host's
# hardware, and find old kernels that only take up space.
#
# Run on the Proxmox VE host as root:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/farmnerds-net/proxmox-host-scripts/main/kernel-manager.sh)"
#
# Without options it shows the report, then offers to try a kernel for
# the next boot only, pin or unpin one, or cancel a trial. Changes go
# through Proxmox's own proxmox-boot-tool, and the script never reboots.
# It can also install other kernel series (checking their drivers first)
# and remove old kernels.
#
# Options:
#   --report            the report only; changes nothing
#   --check <version>   check one installed kernel against this host's
#                       hardware, e.g. --check 7.0.14-26-pve
#   --try <version>     boot <version> on the next boot only
#   --pin <version>     keep booting <version>
#   --unpin             remove the pin and any trial (boot the newest again)
#   --cancel-try        remove only the next-boot trial
#   --install <series>  install another kernel series, e.g. --install 6.17
#                       (opt-in series also need KM_OPTIN=yes)
#   --remove <version>... remove old kernels (only ones that aren't running,
#                       next to boot, pinned or the fallback)
#   --help
#
# Presets (each skips its question):
#   KM_ACTION=try|pin|keep|unpin|cancel-try|install|remove  KM_KERNEL=<version>
#   KM_SERIES=<series>  KM_OPTIN=yes  KM_AFTER=try|default|hold|pin|none
#   KM_REMOVE="<version> ..."  KM_CONFIRM=yes

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
  fi || { printf 'kernel-manager: could not load %s\n' "$1" >&2; exit 1; }
  # shellcheck source=/dev/null
  source /dev/stdin <<<"$body"
}

hs_load core
hs_load lib/ui.func

# shellcheck disable=SC2034  # read by lib/ui.func
UI_TITLE="Proxmox kernel manager"
# shellcheck disable=SC2034  # read by lib/ui.func
UI_CANCEL_MSG="Cancelled. Nothing was changed."

HS_LOG_DIR="/var/log/proxmox-host-scripts"
PIN_FILE="/etc/kernel/proxmox-boot-pin"
NEXT_PIN_FILE="/etc/kernel/next-boot-pin"
ESP_LIST="/etc/kernel/proxmox-boot-uuids"

first_line() { [[ -r "$1" ]] && head -n 1 -- "$1" | tr -d '[:space:]'; return 0; }

# ---- kernels: running, installed, bootable --------------------------------------

running_kernel() { uname -r; }

uptime_text() {
  local s
  s=$(cut -d. -f1 /proc/uptime)
  if (( s >= 86400 )); then printf '%d days' $(( s / 86400 ))
  elif (( s >= 3600 )); then printf '%d hours' $(( s / 3600 ))
  else printf '%d minutes' $(( s / 60 )); fi
}

# Installed kernels -> "<abi> <package> <size KiB>", newest first.
installed_kernels() {
  # dpkg-query fails when a pattern matches nothing (e.g. no old pve-kernel-*).
  { dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Installed-Size}\n' \
      'proxmox-kernel-*-pve' 'proxmox-kernel-*-pve-signed' 'pve-kernel-*-pve' 2>/dev/null || true; } |
    awk '$1 == "ii" {
      abi = $2; sub(/^(proxmox|pve)-kernel-/, "", abi); sub(/-signed$/, "", abi)
      if (abi ~ /^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-pve$/) print abi, $2, $3 }' |
    sort -k1,1Vr
}

uses_boot_tool() { [[ -s "$ESP_LIST" ]]; }

# Kernels the boot loader can start.
bootable_kernels() {
  if uses_boot_tool; then
    proxmox-boot-tool kernel list 2>/dev/null |
      grep -oE '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-pve' | sort -uVr
  else
    find /boot -maxdepth 1 -name 'vmlinuz-*-pve' -printf '%f\n' 2>/dev/null |
      sed 's/^vmlinuz-//' | sort -uVr
  fi
}

boot_loader_text() {
  local mode loader n
  if [[ -d /sys/firmware/efi ]]; then mode=UEFI; else mode="legacy BIOS"; fi
  if uses_boot_tool; then
    n=$(grep -cE '^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}' "$ESP_LIST" || true)
    # proxmox-boot-tool sets each boot partition up for "uefi" (systemd-boot) or "grub".
    if proxmox-boot-tool status 2>/dev/null | grep -q 'configured with: uefi'; then loader=systemd-boot; else loader=GRUB; fi
    printf '%s (%s), managed by proxmox-boot-tool on %s boot partition%s' "$loader" "$mode" "$n" "$([[ $n == 1 ]] || printf s)"
  else
    printf 'GRUB (%s)' "$mode"
  fi
}

# What the next boot starts: a next-boot pin, else a pin, else the newest
# bootable kernel.
next_boot_kernel() {
  local k
  k=$(first_line "$NEXT_PIN_FILE")
  [[ -n "$k" ]] || k=$(first_line "$PIN_FILE")
  [[ -n "$k" ]] || k=$(bootable_kernels | head -n 1)
  printf '%s' "$k"
}

# ---- kernel series in the repositories ---------------------------------------------

default_series() {   # -> e.g. 7.0, from what proxmox-default-kernel depends on
  apt-cache depends proxmox-default-kernel 2>/dev/null |
    sed -n 's/^ *Depends: proxmox-kernel-\([0-9]*\.[0-9]*\)$/\1/p' | head -n 1
}

repo_series() {   # -> series with a proxmox-kernel-X.Y package, newest first
  apt-cache pkgnames proxmox-kernel- 2>/dev/null |
    grep -oE '^proxmox-kernel-[0-9]+\.[0-9]+$' | sed 's/^proxmox-kernel-//' | sort -uVr
}

# -> "<installed or none> <candidate> <repository component>"
series_info() {   # <series>
  apt-cache policy "proxmox-kernel-$1" 2>/dev/null | awk '
    /Installed:/ { i = $2 } /Candidate:/ { c = $2 }
    /^ +(\*\*\* )?[0-9]/ && !/https?:\/\// { v = $1; if (v == "***") v = $2; cur = (v == c) }
    cur && /https?:\/\// && !r { n = split($3, a, "/"); r = a[n] }
    END { print (i == "(none)" ? "none" : i), c, (r ? r : "?") }'
}

# ---- hardware check -------------------------------------------------------------------

# Kernel modules the devices use right now (built-in drivers have no module
# and are part of every build of the same kernel series).
modules_in_use() {
  local d m
  for d in /sys/bus/pci/devices/*/driver; do
    [[ -e "$d/module" ]] || continue
    m=$(basename "$(readlink -f "$d/module")")
    printf '%s %s\n' "$m" "$(basename "$(readlink -f "$d")")"
  done | sort -u
}

vfio_devices() {
  local d n=0
  for d in /sys/bus/pci/devices/*/driver; do
    [[ "$(basename "$(readlink -f "$d")")" == vfio-pci ]] && n=$(( n + 1 ))
  done
  printf '%d' "$n"
}

# Module names (normalised to _) that kernel <abi> has, loadable or built
# in. Cached per kernel: KMOD_<abi> lists are read once.
declare -gA KMODS=()

kernel_modules() {   # <abi> -> sets KMODS[<abi>]; returns 2 if the kernel isn't installed
  local dir="/lib/modules/$1"
  [[ -n "${KMODS[$1]+x}" ]] && return 0
  [[ -r "$dir/modules.dep" ]] || return 2
  KMODS[$1]=$(cut -d: -f1 "$dir/modules.dep" "$dir/modules.builtin" 2>/dev/null |
    sed 's#.*/##; s/\.ko.*$//; s/-/_/g' | sort -u)
}

# Is <module> in kernel <abi>? 0 yes, 1 no, 2 can't tell (kernel not installed).
module_in_kernel() {   # <module> <abi>
  local rc=0
  kernel_modules "$2" || rc=$?
  (( rc == 0 )) || return "$rc"
  # A here-string, not a pipe: grep -q stopping early must not fail the test.
  grep -qxF -- "${1//-/_}" <<<"${KMODS[$2]}"
}

# Drivers the running kernel doesn't list as a module or as built in are
# part of the kernel's core (e.g. pcieport) and present in every build.
is_core_driver() {   # <module>
  ! module_in_kernel "$1" "$(running_kernel)"
}

hardware_check() {   # <abi> -> prints a summary line, then missing drivers; returns 1 if any missing
  local abi=$1 m drv have=0 total=0
  local -a missing=()
  while read -r m drv; do
    [[ -n "$m" ]] || continue
    total=$(( total + 1 ))
    if is_core_driver "$m" || module_in_kernel "$m" "$abi"; then
      have=$(( have + 1 ))
    else
      missing+=("${m} (${drv})")
    fi
  done < <(modules_in_use)
  if (( ${#missing[@]} == 0 )); then
    printf 'all %d drivers your devices use are present\n' "$total"
    return 0
  fi
  printf '%d of %d drivers present; MISSING: %s\n' "$have" "$total" "${missing[*]}"
  return 1
}

dkms_status() {
  if ! command -v dkms >/dev/null 2>&1; then printf 'none (dkms not installed)'; return 0; fi
  local s
  s=$(dkms status 2>/dev/null | tr '\n' ';' | sed 's/;$//')
  printf '%s' "${s:-none}"
}

pkg_status() {   # <package> -> "3.18-9 (up to date)" / "x installed, y available" / "not installed"
  apt-cache policy "$1" 2>/dev/null | awk '
    /Installed:/ { i = $2 } /Candidate:/ { c = $2 }
    END {
      if (i == "" || i == "(none)") print "not installed"
      else if (c != "" && c != "(none)" && c != i) print i " installed, " c " available"
      else print i " (up to date)" }'
}

# ---- report ------------------------------------------------------------------------

human_kib() {   # <KiB> -> "1.0 GB" / "983 MB"
  awk -v k="$1" 'BEGIN { b = k * 1024; split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1000 && i < 5) { b /= 1000; i++ }; printf (i >= 4 ? "%.1f %s" : "%d %s"), b, u[i] }'
}

report() {
  local run next pin nextpin abi pkg size note boot fallback=""
  local -a bootable=() unused=()
  local unused_kib=0 series inst cand repo label s_def
  run=$(running_kernel)
  pin=$(first_line "$PIN_FILE")
  nextpin=$(first_line "$NEXT_PIN_FILE")
  next=$(next_boot_kernel)
  mapfile -t bootable < <(bootable_kernels)

  say_head "Kernel"
  say "  Running:      ${run} (up $(uptime_text))"
  if [[ -n "$nextpin" ]]; then
    say "  Next boot:    ${next} (pinned for the next boot only)"
  elif [[ -n "$pin" ]]; then
    say "  Next boot:    ${next} (pinned)"
  else
    say "  Next boot:    ${next} (the newest bootable kernel; nothing is pinned)"
  fi
  if [[ "$next" != "$run" ]]; then
    say "                A reboot will switch to ${next}."
  fi
  say "  Boot loader:  $(boot_loader_text)"
  say "  Pinned:       ${pin:-none}$([[ -n "$nextpin" ]] && printf '   (next boot only: %s)' "$nextpin")"
  say "  Boot menu:    shows for $(menu_timeout) seconds; default: $(loader_default_text)"

  say_head "Installed kernels"
  printf '  %-17s %-9s %-8s %s\n' VERSION BOOTABLE SIZE NOTES
  # The fallback: the newest bootable kernel other than the one the next boot uses.
  for abi in "${bootable[@]}"; do
    if [[ "$abi" != "$next" ]]; then fallback=$abi; break; fi
  done
  while read -r abi pkg size; do
    boot=no
    printf '%s\n' "${bootable[@]}" | grep -qxF -- "$abi" && boot=yes
    note=""
    [[ "$abi" == "$run" ]] && note+="running, "
    [[ "$abi" == "$next" ]] && note+="next boot, "
    [[ "$abi" == "$pin" ]] && note+="pinned, "
    [[ "$abi" == "$fallback" ]] && note+="fallback, "
    if [[ -z "$note" ]]; then
      if [[ "$boot" == no ]]; then
        note="unused: not on the boot partition"
      else
        note="older, still bootable"
      fi
      unused+=("${abi}|${pkg}|${size}")
      unused_kib=$(( unused_kib + size ))
    fi
    printf '  %-17s %-9s %-8s %s\n' "$abi" "$boot" "$(human_kib "$size")" "${note%, }"
  done < <(installed_kernels)

  say_head "Kernel series in your repositories"
  s_def=$(default_series)
  printf '  %-7s %-14s %-12s %-24s %s\n' SERIES NEWEST INSTALLED STATUS FROM
  while read -r series; do
    read -r inst cand repo < <(series_info "$series"; echo) || true
    if [[ "$series" == "$s_def" ]]; then label="default"
    elif [[ "$(printf '%s\n%s\n' "$series" "$s_def" | sort -V | tail -n 1)" == "$series" ]]; then label="opt-in (newer, less tested)"
    else label="older (fallback)"; fi
    printf '  %-7s %-14s %-12s %-24s %s\n' "$series" "$cand" "$([[ $inst == none ]] && printf '-' || printf '%s' "$inst")" "$label" "$repo"
  done < <(repo_series)
  read -r inst cand repo < <(series_info "$s_def"; echo) || true
  if [[ "$inst" != none && "$cand" != "$inst" ]]; then
    say "  A newer ${s_def} build (${cand}) is available: it arrives with your normal updates (apt full-upgrade)."
  fi
  say "  Newer opt-in series appear here when Proxmox publishes them."

  say_head "Hardware check"
  say "  Drivers your devices use now, looked up in each installed kernel:"
  while read -r abi pkg size; do
    printf '  %-17s %s\n' "$abi" "$(hardware_check "$abi" || true)"
  done < <(installed_kernels)
  local nv
  nv=$(vfio_devices)
  if (( nv > 0 )); then
    say "  Passthrough:  ${nv} device(s) use vfio-pci. Kernel changes can affect passthrough,"
    say "                so try a new kernel for one boot first."
  fi
  say "  DKMS modules: $(dkms_status)"
  say "  Firmware:     pve-firmware $(pkg_status pve-firmware)"
  case "$(sed -n 's/^vendor_id[[:space:]]*: //p' /proc/cpuinfo | head -n 1)" in
    GenuineIntel) say "  Microcode:    intel-microcode $(pkg_status intel-microcode)" ;;
    AuthenticAMD) say "  Microcode:    amd64-microcode $(pkg_status amd64-microcode)" ;;
  esac

  say_head "Cleanup suggestions (nothing is removed)"
  if (( ${#unused[@]} == 0 )); then
    say "  None: every installed kernel is running, next to boot, pinned or the fallback."
  else
    say "  These kernels aren't running, pinned, next to boot or the fallback:"
    local u
    for u in "${unused[@]}"; do
      IFS='|' read -r abi pkg size <<<"$u"
      printf '    %-17s %-8s (package %s)\n' "$abi" "$(human_kib "$size")" "$pkg"
    done
    say "  Removing them would free about $(human_kib "$unused_kib")."
  fi
}

# ---- the boot loader's real default (read from the boot partition) ---------------------

GRUB_PIN_SNIPPET="/etc/default/grub.d/proxmox-kernel-pin.cfg"

# Run <command> with each boot partition mounted read-only at "$1".
with_esps() {   # <function taking a mountpoint>
  local u m
  while read -r u; do
    m=$(mktemp -d)
    if mount -o ro "/dev/disk/by-uuid/$u" "$m" 2>/dev/null; then
      "$1" "$m" "$u" || true
      umount "$m" || true
    fi
    rmdir "$m" 2>/dev/null || true
  done < <(grep -oE '^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}' "$ESP_LIST" 2>/dev/null || true)
}

_esp_default() { sed -n 's/^default //p' "$1/loader/loader.conf" 2>/dev/null | head -n 1; }
_esp_timeout() { sed -n 's/^timeout //p' "$1/loader/loader.conf" 2>/dev/null | head -n 1; }

loader_default_text() {   # -> "proxmox-7.0.14-26-pve.conf" / "newest kernel"
  local d
  if uses_boot_tool; then
    d=$(with_esps _esp_default | sort -u | paste -sd' ' -)
    if [[ "$d" == "proxmox-*" ]]; then printf 'the newest kernel'
    else printf '%s' "${d:-unknown}" | sed 's/^proxmox-//; s/\.conf$//; s/ proxmox-/, /g; s/\.conf / /g'; fi
  elif [[ -s "$GRUB_PIN_SNIPPET" ]]; then
    sed -n 's/.*gnulinux-\([0-9][^-]*-[0-9]*-pve\)-advanced.*/\1/p' "$GRUB_PIN_SNIPPET" | head -n 1
  else
    printf 'the newest kernel'
  fi
}

menu_timeout() {   # -> seconds the boot menu shows, or "?"
  local t=""
  if uses_boot_tool; then
    t=$(with_esps _esp_timeout | head -n 1)
  else
    t=$(sed -n 's/^GRUB_TIMEOUT=//p' /etc/default/grub 2>/dev/null | tr -d '"' | tail -n 1)
  fi
  printf '%s' "${t:-?}"
}

# ---- changing what boots ------------------------------------------------------------

boot_tool_refresh() {
  if uses_boot_tool; then proxmox-boot-tool refresh; fi
}

do_try() {   # <abi>
  proxmox-boot-tool kernel pin "$1" --next-boot </dev/null
  boot_tool_refresh
}

do_pin() {   # <abi>
  proxmox-boot-tool kernel pin "$1" </dev/null
  boot_tool_refresh
}

do_unpin() {
  proxmox-boot-tool kernel unpin </dev/null
  boot_tool_refresh
}

do_cancel_try() {
  proxmox-boot-tool kernel unpin --next-boot </dev/null
  boot_tool_refresh
}

kernel_items() {   # <exclude abi or ""> -> menu items for installed kernels
  local abi pkg size note run next pin
  run=$(running_kernel)
  next=$(next_boot_kernel)
  pin=$(first_line "$PIN_FILE")
  while read -r abi pkg size; do
    [[ "$abi" == "${1:-}" ]] && continue
    note=""
    [[ "$abi" == "$run" ]] && note+="running, "
    [[ "$abi" == "$next" ]] && note+="next boot, "
    [[ "$abi" == "$pin" ]] && note+="pinned, "
    if ! hardware_check "$abi" >/dev/null; then note+="MISSING DRIVERS, "; fi
    printf '%s\n%s\n' "$abi" "${note:+(${note%, })}"
  done < <(installed_kernels)
}

valid_installed() {   # <abi>
  installed_kernels | awk '{ print $1 }' | grep -qxF -- "$1"
}

# Shown before a change: the honest picture of what happens and how to get back.
consequence_text() {   # <action> <abi>
  local fb t
  t=$(menu_timeout)
  fb=$(bootable_kernels | grep -vxF -- "$2" | head -n 1)
  case $1 in
    try)
      cat <<EOF
On the next reboot the host starts ${2}, once. After it has booted,
Proxmox's cleanup service removes the trial, so the reboot after that
returns to your normal kernel.

If something doesn't work on ${2} (a driver, passthrough, a VM):
just reboot once more.

If ${2} doesn't start at all, the cleanup never runs and the host keeps
trying it. Then, at the console, choose ${fb:-another kernel} in the boot
menu (it shows for ${t} seconds at startup), and run this script with
--cancel-try.

This script does not reboot. Reboot when it suits you.
EOF
      ;;
    pin|keep)
      cat <<EOF
The host will keep booting ${2}, also after kernel updates, until you
unpin it (--unpin). New kernels are still installed by updates; they're
just not started.

If ${2} ever doesn't start, choose ${fb:-another kernel} in the boot menu
at the console (it shows for ${t} seconds) and unpin.

Tip: try a kernel for one boot first (--try) before pinning one you
haven't booted yet.
EOF
      ;;
  esac
}

apply_action() {   # <action> [<abi>]
  case $1 in
    try)        run_step "Setting ${2} for the next boot only" do_try "$2" ;;
    pin|keep)   run_step "Pinning ${2}" do_pin "$2" ;;
    unpin)      run_step "Removing the pin" do_unpin ;;
    cancel-try) run_step "Cancelling the next-boot trial" do_cancel_try ;;
  esac
  log_line "Action ${1} ${2:-}: next boot $(next_boot_kernel), loader default $(loader_default_text)"
  say_ok "Next boot: $(next_boot_kernel)   (boot loader default: $(loader_default_text))"
  if [[ "$(next_boot_kernel)" != "$(running_kernel)" ]]; then
    say "   Nothing has been rebooted. The change takes effect when you reboot."
  else
    say "   That's the kernel running now, so a reboot changes nothing."
  fi
}

# ---- installing other kernel series --------------------------------------------------

series_label() {   # <series> -> default | older | opt-in
  local d
  d=$(default_series)
  if [[ "$1" == "$d" ]]; then printf 'default'
  elif [[ "$(printf '%s\n%s\n' "$1" "$d" | sort -V | tail -n 1)" == "$1" ]]; then printf 'opt-in'
  else printf 'older'; fi
}

series_installed() {   # <series>
  [[ "$(dpkg-query -W -f '${db:Status-Abbrev}' "proxmox-kernel-$1" 2>/dev/null)" == ii* ]]
}

# The kernel package a series' meta package installs now, e.g.
# proxmox-kernel-6.17.13-21-pve-signed (the signed one when there is one).
series_kernel_pkg() {   # <series>
  apt-cache depends "proxmox-kernel-$1" 2>/dev/null |
    sed -n 's/^ *|\{0,1\}Depends: \(proxmox-kernel-[0-9][0-9.]*-[0-9]*-pve\(-signed\)\{0,1\}\)$/\1/p' |
    sort -r | head -n 1
}

pkg_abi() { local p=${1#proxmox-kernel-}; printf '%s' "${p%-signed}"; }

pkg_download_size() {   # <package> -> bytes
  apt-cache show "$1" 2>/dev/null | sed -n 's/^Size: //p' | head -n 1
}

human_bytes() {
  awk -v b="${1:-0}" 'BEGIN { split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1000 && i < 5) { b /= 1000; i++ }; printf (i >= 4 ? "%.1f %s" : "%d %s"), b, u[i] }'
}

# Download a kernel package (not installed) and read which drivers it has,
# so hardware_check works on it before it's installed.
precheck_package() {   # <package> <abi>
  local tmp deb list
  tmp=$(mktemp -d)
  ( cd "$tmp" && apt-get -q -o APT::Sandbox::User=root download "$1" ) >>"$RCP_LOG" 2>&1 ||
    { rm -rf -- "$tmp"; return 1; }
  deb=$(find "$tmp" -maxdepth 1 -name '*.deb' | head -n 1)
  [[ -n "$deb" ]] || { rm -rf -- "$tmp"; return 1; }
  list=$(dpkg-deb --fsys-tarfile "$deb" | tar -t 2>/dev/null |
    sed -n 's#.*/\([^/]*\)\.ko\(\.[a-z]*\)\{0,1\}$#\1#p')
  list+=$'\n'$(dpkg-deb --fsys-tarfile "$deb" | tar -xO --wildcards "*/modules/$2/modules.builtin" 2>/dev/null |
    sed 's#.*/##; s/\.ko.*$//')
  KMODS[$2]=$(printf '%s\n' "$list" | sed 's/-/_/g' | sed '/^$/d' | sort -u)
  rm -rf -- "$tmp"
  [[ -n "${KMODS[$2]}" ]]
}

apt_install_series() {   # <series>
  DEBIAN_FRONTEND=noninteractive apt-get -y install "proxmox-kernel-$1"
}

optin_risk_text() {   # <series>
  cat <<EOF
${1} is an OPT-IN kernel: newer than the default series ($(default_series)),
and less tested. Proxmox offers opt-in kernels for newer hardware support and
fixes, but they can have regressions, especially with passthrough, ZFS,
network cards or graphics.

Use it if you need something it adds, have console access to the host
(to pick another kernel in the boot menu if it doesn't start), and are fine
reporting or living with problems. The safe way is to try it for one boot.

Install ${1} anyway?
EOF
}

# The install flow. Returns 1 when the user goes Back from its first screen.
flow_install() {
  local step=series s label pkg abi size check nextk newer prompt run v
  local -a items=() after=()
  local -A preset=()
  for v in KM_SERIES KM_OPTIN KM_AFTER KM_CONFIRM; do
    if ui_is_set "$v"; then preset[$v]=1; fi
  done
  run=$(running_kernel)
  while true; do
    case $step in
      series)
        items=()
        while read -r s; do
          series_installed "$s" && continue
          label=$(series_label "$s")
          pkg=$(series_kernel_pkg "$s")
          items+=("$s" "$(case $label in opt-in) printf 'OPT-IN, newer and less tested' ;; older) printf 'older, a fallback' ;; *) printf 'default' ;; esac)  ($(pkg_abi "$pkg"), $(human_bytes "$(pkg_download_size "$pkg")") download)")
        done < <(repo_series)
        if (( ${#items[@]} == 0 )); then
          ui_msg "Every kernel series in your repositories is already installed."
          return 1
        fi
        # shellcheck disable=SC2034  # read by lib/ui.func
        UI_BACK_LABEL=Back
        if ui_menu KM_SERIES "Which kernel series should be installed?" "${items[0]}" "${items[@]}"; then
          repo_series | grep -qxF -- "$KM_SERIES" || die "There's no kernel series ${KM_SERIES} in your repositories."
          series_installed "$KM_SERIES" && die "Kernel series ${KM_SERIES} is already installed."
          step=optin
        else
          [[ -z "${preset[KM_SERIES]:-}" ]] || ui_cancelled
          return 1
        fi
        ;;
      optin)
        if [[ "$(series_label "$KM_SERIES")" != opt-in ]]; then step=check; continue; fi
        if ui_yesno KM_OPTIN "$(optin_risk_text "$KM_SERIES")" no "I understand" Back && [[ "$KM_OPTIN" == yes ]]; then
          step=check
        else
          [[ -z "${preset[KM_OPTIN]:-}" ]] || die "Opt-in kernel ${KM_SERIES} needs KM_OPTIN=yes."
          unset KM_OPTIN
          [[ -n "${preset[KM_SERIES]:-}" ]] && ui_cancelled
          unset KM_SERIES
          step=series
        fi
        ;;
      check)
        pkg=$(series_kernel_pkg "$KM_SERIES")
        abi=$(pkg_abi "$pkg")
        size=$(pkg_download_size "$pkg")
        [[ -n "$pkg" ]] || die "Cannot find the kernel package of series ${KM_SERIES}."
        if (( RCP_TTY )); then clear; fi
        say "   Downloading ${pkg} ($(human_bytes "$size")) to check its drivers before installing..."
        if precheck_package "$pkg" "$abi"; then
          check=$(hardware_check "$abi" || true)
        else
          check="could not be checked (download failed; see ${RCP_LOG})"
        fi
        log_line "Pre-install check of ${abi}: ${check}"
        step=confirm
        ;;
      confirm)
        nextk=$(next_boot_kernel)
        newer=no
        [[ "$(printf '%s\n%s\n' "$abi" "$nextk" | sort -V | tail -n 1)" == "$abi" && "$abi" != "$nextk" ]] && newer=yes
        prompt="Install kernel ${KM_SERIES} (${abi})?

  Series:       ${KM_SERIES}, $(series_label "$KM_SERIES")
  Download:     $(human_bytes "$size"), about 1 GB installed
  Your drivers: ${check}
"
        if [[ "$newer" == yes && -z "$(first_line "$PIN_FILE")" ]]; then
          prompt+="
It's newer than your current kernel (${nextk}), so after installing, the
host would start it on the next reboot. You choose what to do next: try it
for one boot only (recommended), boot it from now on, or not yet."
        else
          prompt+="
Your next boot doesn't change: it stays on ${nextk}. After installing you
can try ${abi} for one boot or pin it."
        fi
        prompt+="

This script does not reboot."
        if ui_yesno KM_CONFIRM "$prompt" yes Install Back && [[ "$KM_CONFIRM" == yes ]]; then
          break
        fi
        [[ -z "${preset[KM_CONFIRM]:-}" ]] || ui_cancelled
        unset KM_CONFIRM
        [[ -n "${preset[KM_SERIES]:-}" ]] && ui_cancelled
        unset KM_SERIES KM_OPTIN
        step=series
        ;;
    esac
  done

  run_step "Installing proxmox-kernel-${KM_SERIES} (${abi})" apt_install_series "$KM_SERIES"
  installed_kernels | awk '{ print $1 }' | grep -qxF -- "$abi" || die "Kernel ${abi} did not install (see ${RCP_LOG})."
  log_line "Installed ${KM_SERIES} (${abi}); bootable: $(bootable_kernels | tr '\n' ' ')"
  say_ok "Installed ${abi}; its drivers: $(hardware_check "$abi" || true)"

  # What should the next boot do?
  # shellcheck disable=SC2034  # read by lib/ui.func
  UI_BACK_LABEL=Skip
  if [[ "$(next_boot_kernel)" == "$abi" ]]; then
    # Unattended: never let a newly installed kernel boot by surprise.
    if [[ ! -t 0 || ! -t 1 ]] && ! ui_is_set KM_AFTER; then KM_AFTER=hold; fi
    after=(try  "Try it on the next boot only, then return to ${run} (recommended)"
           default "Boot it from now on (it's the newest kernel)"
           hold "Not yet: keep booting ${run}")
    ui_menu KM_AFTER "${abi} is now the newest kernel, so the next reboot would start it.

What should the next boot do?" try "${after[@]}" || KM_AFTER=default
    case $KM_AFTER in
      try)
        run_step "Pinning ${run} (the host returns to it after the trial)" do_pin "$run"
        run_step "Setting ${abi} for the next boot only" do_try "$abi"
        say "   ${run} is pinned so the host goes back to it after the trial. If ${abi} works"
        say "   well, pin it (--pin ${abi}) or unpin (--unpin) to follow updates again."
        ;;
      hold) run_step "Pinning ${run}" do_pin "$run" ;;
      *) ;;
    esac
  else
    if [[ ! -t 0 || ! -t 1 ]] && ! ui_is_set KM_AFTER; then KM_AFTER=none; fi
    after=(try  "Try it on the next boot only"
           pin  "Pin it: boot it from now on"
           none "Nothing for now (keep booting $(next_boot_kernel))")
    ui_menu KM_AFTER "${abi} is installed. What should the next boot do?" none "${after[@]}" || KM_AFTER=none
    case $KM_AFTER in
      try) run_step "Setting ${abi} for the next boot only" do_try "$abi" ;;
      pin) run_step "Pinning ${abi}" do_pin "$abi" ;;
      *) ;;
    esac
  fi
  log_line "After install (${KM_AFTER}): next boot $(next_boot_kernel), loader default $(loader_default_text)"
  say_ok "Next boot: $(next_boot_kernel)   (boot loader default: $(loader_default_text))"
  say "   Nothing has been rebooted."
}

# ---- removing old kernels ------------------------------------------------------------

# Kernels that are safe to remove: not running, not next to boot, not pinned
# (also not for the next boot), not the fallback -> "<abi> <package> <KiB>"
removal_candidates() {
  local run next pin nextpin fb abi pkg size
  run=$(running_kernel)
  next=$(next_boot_kernel)
  pin=$(first_line "$PIN_FILE")
  nextpin=$(first_line "$NEXT_PIN_FILE")
  fb=$(bootable_kernels | grep -vxF -- "$next" | head -n 1)
  while read -r abi pkg size; do
    case $abi in "$run"|"$next"|"$pin"|"$nextpin"|"$fb") continue ;; esac
    printf '%s %s %s\n' "$abi" "$pkg" "$size"
  done < <(installed_kernels)
  return 0
}

abi_series() { sed -E 's/^([0-9]+\.[0-9]+)\..*/\1/' <<<"$1"; }

# Packages to purge for these kernels: their packages, the unsigned
# companions, and a non-default series' meta package once none of its
# kernels is left.
removal_packages() {   # <abi>...
  local abi pkg size ser left
  local -a pkgs=() sel=("$@")
  while read -r abi pkg size; do
    printf '%s\n' "${sel[@]}" | grep -qxF -- "$abi" || continue
    pkgs+=("$pkg")
    if [[ "$pkg" == *-signed ]] && dpkg-query -W -f '${db:Status-Abbrev}' "${pkg%-signed}" 2>/dev/null | grep -q '^ii'; then
      pkgs+=("${pkg%-signed}")
    fi
  done < <(installed_kernels)
  for ser in $(printf '%s\n' "${sel[@]}" | while read -r a; do abi_series "$a"; done | sort -u); do
    [[ "$ser" == "$(default_series)" ]] && continue
    series_installed "$ser" || continue
    left=$(installed_kernels | awk '{ print $1 }' | while read -r a; do
      [[ "$(abi_series "$a")" == "$ser" ]] || continue
      printf '%s\n' "${sel[@]}" | grep -qxF -- "$a" || printf '%s\n' "$a"
    done)
    [[ -n "$left" ]] || pkgs+=("proxmox-kernel-${ser}")
  done
  printf '%s\n' "${pkgs[@]}"
}

# apt must remove exactly these packages and nothing else.
removal_is_exact() {   # <package>...
  local want got
  want=$(printf '%s\n' "$@" | sort -u)
  got=$(apt-get -s purge "$@" 2>/dev/null | sed -n 's/^\(Purg\|Remv\) \([^ ]*\).*/\2/p' | sort -u)
  if [[ "$want" == "$got" ]]; then return 0; fi
  printf '%s\n' "$got" | grep -vxF -f <(printf '%s\n' "$want") | tr '\n' ' '
  return 1
}

apt_purge() {
  local p
  DEBIAN_FRONTEND=noninteractive apt-get -y purge "$@"
  # Also drop apt's cached download of each removed package.
  for p in "$@"; do
    rm -f -- /var/cache/apt/archives/"${p}"_*.deb
  done
}

flow_remove() {
  local abi pkg size total=0 extra v
  local -a items=() sel=() pkgs=()
  local -A preset=()
  for v in KM_REMOVE KM_CONFIRM; do
    if ui_is_set "$v"; then preset[$v]=1; fi
  done
  while true; do
    items=()
    while read -r abi pkg size; do
      items+=("$abi" "$(human_kib "$size")$(bootable_kernels | grep -qxF -- "$abi" || printf ', not bootable')" on)
    done < <(removal_candidates)
    if (( ${#items[@]} == 0 )); then
      ui_msg "There's nothing to remove: every installed kernel is running, next to boot, pinned or the fallback."
      return 1
    fi
    # shellcheck disable=SC2034  # read by lib/ui.func
    UI_BACK_LABEL=Back
    if ! ui_checklist KM_REMOVE "Which old kernels should be removed?

Only kernels that aren't running, next to boot, pinned or the fallback are
listed. (Space ticks/unticks.)" "${items[@]}"; then
      [[ -z "${preset[KM_REMOVE]:-}" ]] || ui_cancelled
      return 1
    fi
    read -r -a sel <<<"$KM_REMOVE"
    if (( ${#sel[@]} == 0 )); then
      [[ -z "${preset[KM_REMOVE]:-}" ]] || { say_ok "Nothing selected; nothing removed."; return 0; }
      unset KM_REMOVE
      continue
    fi
    for abi in "${sel[@]}"; do
      removal_candidates | awk '{ print $1 }' | grep -qxF -- "$abi" ||
        die "${abi} can't be removed: it's not installed, or it's running, next to boot, pinned or the fallback."
    done
    mapfile -t pkgs < <(removal_packages "${sel[@]}")
    if ! extra=$(removal_is_exact "${pkgs[@]}"); then
      die "Removing these would also remove other packages (${extra}), so nothing was done."
    fi
    total=0
    while read -r abi pkg size; do
      printf '%s\n' "${sel[@]}" | grep -qxF -- "$abi" && total=$(( total + size ))
    done < <(installed_kernels)
    if ui_yesno KM_CONFIRM "Remove these kernels?

  $(printf '%s ' "${sel[@]}")

Packages: $(printf '%s ' "${pkgs[@]}")
This frees about $(human_kib "$total"). apt was asked first (dry run): it
removes these packages and nothing else.

Your running, next-boot, pinned and fallback kernels stay." yes Remove Back && [[ "$KM_CONFIRM" == yes ]]; then
      break
    fi
    [[ -z "${preset[KM_CONFIRM]:-}" ]] || ui_cancelled
    unset KM_CONFIRM
    [[ -n "${preset[KM_REMOVE]:-}" ]] && ui_cancelled
    unset KM_REMOVE
  done
  run_step "Removing $(printf '%s ' "${sel[@]}")" apt_purge "${pkgs[@]}"
  for abi in "${sel[@]}"; do
    installed_kernels | awk '{ print $1 }' | grep -qxF -- "$abi" && die "${abi} is still installed (see ${RCP_LOG})."
  done
  log_line "Removed ${sel[*]} (${pkgs[*]}); bootable now: $(bootable_kernels | tr '\n' ' ')"
  say_ok "Removed $(printf '%s ' "${sel[@]}")(freed about $(human_kib "$total"))"
  say_ok "Next boot: $(next_boot_kernel)   (boot loader default: $(loader_default_text))"
}

# One change, with Back on every screen and Exit on the first.
cmd_change() {
  local step=action prompt pin nextpin run newest
  local -a hist=() items=() acts=()
  local -A preset=()
  local v
  for v in KM_ACTION KM_KERNEL KM_CONFIRM; do
    if ui_is_set "$v"; then preset[$v]=1; fi
  done
  run=$(running_kernel)
  pin=$(first_line "$PIN_FILE")
  nextpin=$(first_line "$NEXT_PIN_FILE")
  newest=$(bootable_kernels | head -n 1)

  km_back() {
    case $step in kernel) v=KM_KERNEL ;; confirm) v=KM_CONFIRM ;; *) v=KM_ACTION ;; esac
    [[ -n "${preset[$v]:-}" ]] || unset "$v"
    (( ${#hist[@]} )) || ui_cancelled
    step=${hist[-1]}
    unset 'hist[-1]'
    case $step in kernel) v=KM_KERNEL ;; *) v=KM_ACTION ;; esac
    [[ -n "${preset[$v]:-}" ]] || unset "$v"
  }
  km_next() {
    case $step in kernel) v=KM_KERNEL ;; *) v=KM_ACTION ;; esac
    [[ -n "${preset[$v]:-}" ]] || hist+=("$step")
    step=$1
  }

  while true; do
    # shellcheck disable=SC2034  # read by lib/ui.func
    if (( ${#hist[@]} )); then UI_BACK_LABEL=Back; else UI_BACK_LABEL=Exit; fi
    case $step in
      action)
        acts=(try "Try a kernel for the next boot only (safest way to test one)"
              pin "Pin a kernel: keep booting it, also after updates")
        if [[ -z "$pin" && "$run" != "$newest" ]]; then
          acts+=(keep "Keep the running kernel ${run} (pin it)")
        fi
        [[ -n "$pin" ]] && acts+=(unpin "Remove the pin on ${pin} (boot the newest kernel again)")
        [[ -n "$nextpin" ]] && acts+=(cancel-try "Cancel the next-boot trial of ${nextpin}")
        acts+=(install "Install another kernel series (older fallback, or opt-in)")
        if [[ -n "$(removal_candidates)" ]]; then
          acts+=(remove "Remove old kernels")
        fi
        if ui_menu KM_ACTION "What would you like to do?" try "${acts[@]}"; then
          case $KM_ACTION in
            install|remove)
              if "flow_${KM_ACTION}"; then return 0; fi
              [[ -n "${preset[KM_ACTION]:-}" ]] && ui_cancelled
              unset KM_ACTION
              continue
              ;;
            try|pin) km_next kernel ;;
            keep) KM_KERNEL=$run; km_next confirm ;;
            unpin|cancel-try) km_next confirm ;;
            *) die "KM_ACTION must be try, pin, keep, unpin, cancel-try, install or remove." ;;
          esac
        else
          km_back
        fi
        ;;
      kernel)
        mapfile -t items < <(kernel_items "$([[ $KM_ACTION == try ]] && next_boot_kernel)")
        (( ${#items[@]} )) || { ui_msg "There's no other installed kernel to choose."; km_back; continue; }
        if [[ "$KM_ACTION" == try ]]; then prompt="Which kernel should the next boot try?"; else prompt="Which kernel should the host keep booting?"; fi
        if ui_menu KM_KERNEL "$prompt" "${items[0]}" "${items[@]}"; then
          valid_installed "$KM_KERNEL" || die "Kernel ${KM_KERNEL} is not installed."
          km_next confirm
        else
          km_back
        fi
        ;;
      confirm)
        case $KM_ACTION in
          try|pin|keep)
            prompt="$(consequence_text "$KM_ACTION" "$KM_KERNEL")"
            if ! hardware_check "$KM_KERNEL" >/dev/null; then
              prompt="WARNING: $(hardware_check "$KM_KERNEL" || true)
Devices that need those drivers won't work on this kernel.

${prompt}"
            fi
            prompt="$([[ $KM_ACTION == try ]] && printf 'Try' || printf 'Pin') ${KM_KERNEL}?

${prompt}"
            ;;
          unpin) prompt="Remove the pin on ${pin}?

The host then boots the newest kernel ($(bootable_kernels | head -n 1)) again, and follows updates as usual. This script does not reboot." ;;
          cancel-try)
            if [[ -n "$pin" ]]; then v="${pin} (pinned)"; else v=$(bootable_kernels | head -n 1); fi
            prompt="Cancel the next-boot trial of ${nextpin}?

The next boot then starts ${v} as usual." ;;
        esac
        if ui_yesno KM_CONFIRM "$prompt" yes "$(case $KM_ACTION in try) printf 'Set trial' ;; unpin) printf 'Unpin' ;; cancel-try) printf 'Cancel trial' ;; *) printf 'Pin' ;; esac)" Back &&
          [[ "$KM_CONFIRM" == yes ]]; then
          break
        fi
        [[ -z "${preset[KM_CONFIRM]:-}" ]] || ui_cancelled
        km_back
        ;;
    esac
  done
  apply_action "$KM_ACTION" "${KM_KERNEL:-}"
}

cmd_direct() {   # <action> [<abi>]: the --try/--pin/--unpin/--cancel-try options
  local a=$1
  case $a in
    try|pin)
      [[ -n "${2:-}" ]] || die "Usage: --${a} <kernel version>. Installed: $(installed_kernels | awk '{ print $1 }' | tr '\n' ' ')"
      valid_installed "$2" || die "Kernel ${2} is not installed. Installed: $(installed_kernels | awk '{ print $1 }' | tr '\n' ' ')"
      KM_KERNEL=$2 ;;
    unpin)
      [[ -n "$(first_line "$PIN_FILE")$(first_line "$NEXT_PIN_FILE")" ]] || { say_ok "Nothing is pinned."; return 0; } ;;
    cancel-try)
      [[ -n "$(first_line "$NEXT_PIN_FILE")" ]] || { say_ok "There's no next-boot trial to cancel."; return 0; } ;;
  esac
  KM_ACTION=$a
  : "${KM_CONFIRM:=yes}"
  cmd_change
}

cmd_check() {   # <abi>
  local abi=$1 m drv
  installed_kernels | awk '{ print $1 }' | grep -qxF -- "$abi" ||
    die "Kernel ${abi} is not installed. Installed: $(installed_kernels | awk '{ print $1 }' | tr '\n' ' ')"
  say_head "Hardware check for ${abi}"
  while read -r m drv; do
    if is_core_driver "$m"; then
      printf '  %s[ ok ]%s %-22s used by %s (part of the kernel core)\n' "$C_GREEN" "$C_RESET" "$m" "$drv"
    elif module_in_kernel "$m" "$abi"; then
      printf '  %s[ ok ]%s %-22s used by %s\n' "$C_GREEN" "$C_RESET" "$m" "$drv"
    else
      printf '  %s[miss]%s %-22s used by %s\n' "$C_RED" "$C_RESET" "$m" "$drv"
    fi
  done < <(modules_in_use)
  say "  $(hardware_check "$abi" || true)"
}

usage() {
  cat <<'USAGE'
Usage: kernel-manager.sh [--report | --check <version> | --try <version> |
                         --pin <version> | --unpin | --cancel-try |
                         --install <series> | --remove <version>... | --help]

Show this Proxmox host's kernels: running, next to boot, pinned, installed
(and whether they're bootable), the kernel series in your repositories,
a check of each installed kernel against the drivers your hardware uses,
and old kernels that could be removed. Without options it then offers to
try a kernel for one boot, pin or unpin one (it never reboots).

  --report            the report only; changes nothing
  --check <version>   per-driver check of one installed kernel
  --try <version>     start <version> on the next boot only
  --pin <version>     keep booting <version>
  --unpin             remove the pin and any trial
  --cancel-try        remove only the next-boot trial
  --install <series>  install another kernel series (driver check first;
                      opt-in series also need KM_OPTIN=yes)
  --remove <version>... remove old kernels that aren't running, next to boot,
                      pinned or the fallback
USAGE
}

main() {
  mkdir -p "$HS_LOG_DIR"
  RCP_LOG="${HS_LOG_DIR}/kernel-manager.log"
  (umask 077; touch "$RCP_LOG")
  rcp_install_traps
  (( EUID == 0 )) || die "Run this as root on the Proxmox VE host."
  command -v pveversion >/dev/null 2>&1 || die "This does not look like a Proxmox VE host."
  log_line "==== kernel-manager ${*:-} ===="
  case "${1:-}" in
    --check)
      [[ -n "${2:-}" ]] || die "Usage: --check <kernel version>, e.g. --check $(running_kernel)"
      cmd_check "$2" ;;
    -h|--help) usage ;;
    --report) say_head "Proxmox kernel report"; report ;;
    --try|--pin) cmd_direct "${1#--}" "${2:-}" ;;
    --unpin|--cancel-try) cmd_direct "${1#--}" ;;
    --install)
      [[ -n "${2:-}" ]] || die "Usage: --install <series>, e.g. --install 6.17"
      KM_SERIES=$2; : "${KM_CONFIRM:=yes}"; flow_install || true ;;
    --remove)
      shift
      (( $# )) || die "Usage: --remove <version>... (see the cleanup suggestions in --report)"
      KM_REMOVE="$*"; : "${KM_CONFIRM:=yes}"; flow_remove || true ;;
    "")
      say_head "Proxmox kernel report"
      report
      if [[ -t 0 && -t 1 ]] || ui_is_set KM_ACTION; then cmd_change; fi
      ;;
    *) die "Unknown option '$1' (try --help)." ;;
  esac
}

main "$@"
