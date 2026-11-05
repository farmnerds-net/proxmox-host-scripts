#!/usr/bin/env bash
#
# kernel-manager.sh - see which Proxmox kernels this host runs, boots,
# has installed and could install, check them against this host's
# hardware, and find old kernels that only take up space.
#
# Run on the Proxmox VE host as root:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/farmnerds-net/proxmox-host-scripts/main/kernel-manager.sh)"
#
# This version only reports: it changes nothing. (Trying a kernel for one
# boot, pinning, installing other series and removing old kernels come
# next, built on Proxmox's own proxmox-boot-tool.)
#
# Options:
#   --check <version>   check one installed kernel against this host's
#                       hardware, e.g. --check 7.0.14-26-pve
#   --help

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
Usage: kernel-manager.sh [--check <version> | --help]

Show this Proxmox host's kernels: running, next to boot, pinned, installed
(and whether they're bootable), the kernel series in your repositories,
a check of each installed kernel against the drivers your hardware uses,
and old kernels that could be removed. Changes nothing.

  --check <version>   per-driver check of one installed kernel
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
    "") say_head "Proxmox kernel report"; report ;;
    *) die "Unknown option '$1' (try --help)." ;;
  esac
}

main "$@"
