#!/usr/bin/env bash
#
# cpu-governor.sh - see how this host's CPU scales its frequency, pick a
# profile (Performance, Balanced, Power saver), keep it across reboots, and
# undo it. Also checks that the CPU microcode is up to date.
#
# Run on the Proxmox VE host as root:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/farmnerds-net/proxmox-host-scripts/main/cpu-governor.sh)"
#
# Options:
#   --status   show the CPU, its driver and current settings (changes nothing)
#   --undo     put back the settings the host had before this script
#   --help
#
# Presets (each skips its question):
#   CPU_PROFILE=performance|balanced|powersave
#   CPU_TURBO=on|off
#   CPU_CONFIRM=yes
#   CPU_MICROCODE=yes|no    install/upgrade the microcode package if needed
#
# How it works: modern CPUs change each core's speed by themselves, many
# times a second, inside limits and hints the kernel gives them. This script
# only sets those (the cpufreq governor, the energy/performance preference
# where the driver has one, and turbo). It never takes cores offline and
# never changes kernel boot options. A small systemd service re-applies
# the profile at boot; --undo removes it and restores the original values.

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
  fi || { printf 'cpu-governor: could not load %s\n' "$1" >&2; exit 1; }
  # shellcheck source=/dev/null
  source /dev/stdin <<<"$body"
}

hs_load core
hs_load lib/ui.func

# shellcheck disable=SC2034  # read by lib/ui.func
UI_TITLE="Proxmox CPU governor"
# shellcheck disable=SC2034  # read by lib/ui.func
UI_CANCEL_MSG="Cancelled. Nothing was changed."
HS_CONF_DIR="/etc/proxmox-host-scripts"
CG_CONF="${HS_CONF_DIR}/cpu-governor.conf"
CG_ORIG="${HS_CONF_DIR}/cpu-governor.orig"
CG_APPLY="/usr/local/sbin/proxmox-host-scripts-cpu-governor"
CG_UNIT_NAME="proxmox-host-scripts-cpu-governor.service"
CG_UNIT="/etc/systemd/system/${CG_UNIT_NAME}"
HS_LOG_DIR="/var/log/proxmox-host-scripts"
SYS_CPU="/sys/devices/system/cpu"

# ---- detection (read-only) ----------------------------------------------------

cpu0() { cat "${SYS_CPU}/cpu0/cpufreq/$1" 2>/dev/null || true; }

cpu_model()  { sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -n 1; }
cpu_vendor() { sed -n 's/^vendor_id[[:space:]]*: //p' /proc/cpuinfo | head -n 1; }
cpu_driver() { cpu0 scaling_driver; }
cpu_governor() { cpu0 scaling_governor; }
cpu_governors() { cpu0 scaling_available_governors; }
cpu_epp() { cpu0 energy_performance_preference; }
cpu_epp_options() { cpu0 energy_performance_available_preferences; }
cpu_threads() { nproc --all; }

has_epp() { [[ -w "${SYS_CPU}/cpu0/cpufreq/energy_performance_preference" ]]; }
has_governor() { [[ " $(cpu_governors) " == *" $1 "* ]]; }

# Turbo control: "<file> <value meaning on> <value meaning off>", or nothing.
turbo_ctl() {
  if [[ -w "${SYS_CPU}/intel_pstate/no_turbo" ]]; then
    printf '%s 0 1' "${SYS_CPU}/intel_pstate/no_turbo"
  elif [[ -w "${SYS_CPU}/cpufreq/boost" ]]; then
    printf '%s 1 0' "${SYS_CPU}/cpufreq/boost"
  fi
}

turbo_state() {   # -> on | off | n/a
  local f on off v
  read -r f on off < <(turbo_ctl; echo) || true
  [[ -n "${f:-}" ]] || { printf 'n/a'; return 0; }
  v=$(cat "$f")
  if [[ "$v" == "$on" ]]; then printf 'on'; else printf 'off'; fi
}

hybrid_layout() {   # -> "P-cores: 0-15, E-cores: 16-31" on hybrid Intel CPUs
  if [[ -r /sys/devices/cpu_core/cpus && -r /sys/devices/cpu_atom/cpus ]]; then
    printf 'performance threads %s, efficiency threads %s' \
      "$(cat /sys/devices/cpu_core/cpus)" "$(cat /sys/devices/cpu_atom/cpus)"
  fi
}

freq_range() {   # -> "800-6200 MHz", over all cores (some boost higher than others)
  local lo hi
  lo=$(cat "${SYS_CPU}"/cpu[0-9]*/cpufreq/cpuinfo_min_freq 2>/dev/null | sort -n | head -n 1)
  hi=$(cat "${SYS_CPU}"/cpu[0-9]*/cpufreq/cpuinfo_max_freq 2>/dev/null | sort -n | tail -n 1)
  if [[ -n "$lo" && -n "$hi" ]]; then printf '%d-%d MHz' $(( lo / 1000 )) $(( hi / 1000 )); fi
  return 0
}

freq_now() {   # -> "800 / 800 / 4503 MHz" (lowest / median / highest core)
  local -a mhz
  mapfile -t mhz < <(cat "${SYS_CPU}"/cpu[0-9]*/cpufreq/scaling_cur_freq 2>/dev/null | sort -n)
  (( ${#mhz[@]} )) || return 0
  printf '%d / %d / %d MHz' $(( mhz[0] / 1000 )) $(( mhz[${#mhz[@]} / 2] / 1000 )) $(( mhz[${#mhz[@]} - 1] / 1000 ))
}

cpu_temp() {   # -> package temperature, e.g. "33 °C"
  local h
  for h in /sys/class/hwmon/hwmon*; do
    case "$(cat "$h/name" 2>/dev/null)" in
      coretemp|k10temp|zenpower)
        [[ -r "$h/temp1_input" ]] && { printf '%d °C' $(( $(cat "$h/temp1_input") / 1000 )); return 0; } ;;
    esac
  done
  return 0
}

# Package power from the CPU's own energy counter (RAPL), over <seconds>.
cpu_watts() {   # [<seconds>] -> e.g. "17 W"
  local f=/sys/class/powercap/intel-rapl:0/energy_uj s=${1:-2} e1 e2 max
  [[ -r "$f" ]] || return 0
  e1=$(cat "$f"); sleep "$s"; e2=$(cat "$f")
  if (( e2 < e1 )); then   # the counter wrapped
    max=$(cat /sys/class/powercap/intel-rapl:0/max_energy_range_uj 2>/dev/null || echo 0)
    e2=$(( e2 + max ))
  fi
  printf '%d W' $(( (e2 - e1) / s / 1000000 ))
}

microcode_pkg() {
  case "$(cpu_vendor)" in
    GenuineIntel) printf 'intel-microcode' ;;
    AuthenticAMD) printf 'amd64-microcode' ;;
  esac
}

# -> "<installed or none> <candidate or none>"
microcode_versions() {
  local pkg=$1
  apt-cache policy "$pkg" 2>/dev/null |
    awk '/Installed:/ { i = $2 } /Candidate:/ { c = $2 } END { print (i ? i : "none"), (c ? c : "none") }'
}

microcode_status() {   # -> one line for the report
  local pkg inst cand rev
  pkg=$(microcode_pkg)
  rev=$(sed -n 's/^microcode[[:space:]]*: //p' /proc/cpuinfo | head -n 1)
  [[ -n "$pkg" ]] || { printf 'revision %s (no Debian microcode package for this CPU)' "${rev:-?}"; return 0; }
  read -r inst cand < <(microcode_versions "$pkg")
  if [[ "$inst" == "(none)" || "$inst" == none ]]; then
    printf 'revision %s; %s is NOT installed' "${rev:-?}" "$pkg"
  elif [[ "$cand" != "$inst" && "$cand" != "(none)" && "$cand" != none ]]; then
    printf 'revision %s; %s %s installed, %s available' "${rev:-?}" "$pkg" "$inst" "$cand"
  else
    printf 'revision %s; %s %s (up to date)' "${rev:-?}" "$pkg" "$inst"
  fi
}

# ---- profiles -------------------------------------------------------------------
#
# With an "active" driver (intel_pstate active, amd-pstate-epp) the CPU picks
# its own speed and the kernel passes a preference (EPP): the governor is
# only performance or powersave, and powersave still boosts to full speed
# under load. With other drivers the kernel's governor picks the speed.

profile_plan() {   # <profile> -> "<governor> <epp or ->"
  local p=$1
  if has_epp && has_governor powersave && has_governor performance; then
    case $p in
      performance) printf 'performance -' ;;
      balanced)    printf 'powersave balance_performance' ;;
      powersave)   printf 'powersave balance_power' ;;
    esac
    return 0
  fi
  case $p in
    performance) printf 'performance -' ;;
    balanced)
      if has_governor schedutil; then printf 'schedutil -'
      elif has_governor ondemand; then printf 'ondemand -'
      else printf 'performance -'; fi ;;
    powersave)
      if has_governor conservative; then printf 'conservative -'
      elif has_governor schedutil; then printf 'schedutil -'
      else printf 'powersave -'; fi ;;
  esac
}

profile_label() {
  case $1 in
    performance) printf 'Performance' ;;
    balanced)    printf 'Balanced' ;;
    powersave)   printf 'Power saver' ;;
  esac
}

# Write a value to every CPU's cpufreq file.
set_all() {   # <file name> <value>
  local f n=0
  for f in "${SYS_CPU}"/cpu[0-9]*/cpufreq/"$1"; do
    [[ -w "$f" ]] || continue
    printf '%s' "$2" >"$f" || die "Could not set $1 to '$2' ($f)."
    n=$(( n + 1 ))
  done
  (( n > 0 )) || die "No CPU accepts $1 on this host."
}

set_turbo() {   # <on|off>
  local f on off
  read -r f on off < <(turbo_ctl; echo) || true
  [[ -n "${f:-}" ]] || return 0
  if [[ "$1" == on ]]; then printf '%s' "$on" >"$f"; else printf '%s' "$off" >"$f"; fi
}

apply_values() {   # <governor> <epp or -> <turbo on|off|n/a>
  set_all scaling_governor "$1"
  if [[ "$2" != - ]] && has_epp; then
    set_all energy_performance_preference "$2"
  fi
  if [[ "$3" == on || "$3" == off ]]; then set_turbo "$3"; fi
}

# ---- keeping it across reboots ----------------------------------------------------

save_original() {   # once, before the first change
  [[ -f "$CG_ORIG" ]] && return 0
  install -d -m 0755 "$HS_CONF_DIR"
  {
    printf '# The CPU settings this host had before cpu-governor.sh changed them.\n'
    printf '# Used by: cpu-governor.sh --undo\n'
    printf 'ORIG_GOVERNOR=%s\n' "$(cpu_governor)"
    printf 'ORIG_EPP=%s\n' "$(cpu_epp || true)"
    printf 'ORIG_TURBO=%s\n' "$(turbo_state)"
  } >"$CG_ORIG"
}

write_persistence() {   # <profile> <governor> <epp> <turbo>
  install -d -m 0755 "$HS_CONF_DIR"
  printf '# Written by cpu-governor.sh\nCPU_PROFILE=%s\nCPU_TURBO=%s\n' "$1" "$4" >"$CG_CONF"
  cat >"$CG_APPLY" <<EOF
#!/bin/sh
# Written by proxmox-host-scripts cpu-governor.sh: re-applies the CPU
# profile "$1" at boot. Remove with: cpu-governor.sh --undo
for f in ${SYS_CPU}/cpu[0-9]*/cpufreq/scaling_governor; do
  [ -w "\$f" ] && printf '%s' '$2' >"\$f"
done
EOF
  if [[ "$3" != - ]]; then
    cat >>"$CG_APPLY" <<EOF
for f in ${SYS_CPU}/cpu[0-9]*/cpufreq/energy_performance_preference; do
  [ -w "\$f" ] && printf '%s' '$3' >"\$f"
done
EOF
  fi
  local f on off
  read -r f on off < <(turbo_ctl; echo) || true
  if [[ -n "${f:-}" && ( "$4" == on || "$4" == off ) ]]; then
    printf "[ -w '%s' ] && printf '%%s' '%s' >'%s'\n" "$f" "$([[ "$4" == on ]] && printf '%s' "$on" || printf '%s' "$off")" "$f" >>"$CG_APPLY"
  fi
  printf 'exit 0\n' >>"$CG_APPLY"
  chmod 0755 "$CG_APPLY"
  cat >"$CG_UNIT" <<EOF
# Written by proxmox-host-scripts cpu-governor.sh
[Unit]
Description=CPU frequency profile from cpu-governor.sh ($(profile_label "$1"))
After=sysinit.target

[Service]
Type=oneshot
ExecStart=${CG_APPLY}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --quiet "$CG_UNIT_NAME"
}

remove_persistence() {
  if [[ -f "$CG_UNIT" ]]; then
    # Stop it first (it stays "active" after boot), or systemd keeps it loaded.
    systemctl stop "$CG_UNIT_NAME" 2>/dev/null || true
    systemctl disable --quiet "$CG_UNIT_NAME" 2>/dev/null || true
    rm -f -- "$CG_UNIT"
    systemctl daemon-reload
    systemctl reset-failed "$CG_UNIT_NAME" 2>/dev/null || true
  fi
  rm -f -- "$CG_APPLY" "$CG_CONF"
}

# ---- microcode ----------------------------------------------------------------------

offer_microcode() {
  local pkg inst cand action=""
  pkg=$(microcode_pkg)
  [[ -n "$pkg" ]] || return 0
  read -r inst cand < <(microcode_versions "$pkg")
  if [[ "$inst" == none || "$inst" == "(none)" ]]; then
    [[ "$cand" != none && "$cand" != "(none)" ]] || {
      say_warn "${pkg} is not installed and not available: enable Debian's 'non-free-firmware' component in your apt sources to get it."
      return 0
    }
    action=install
  elif [[ "$cand" != "$inst" && "$cand" != none && "$cand" != "(none)" ]]; then
    action=upgrade
  else
    return 0
  fi
  ui_yesno CPU_MICROCODE "CPU microcode: ${pkg} is $([[ $action == install ]] && printf 'not installed' || printf '%s, and %s is available' "$inst" "$cand").

Microcode updates fix CPU bugs and stability problems (for example the 13th/14th-gen Intel instability). They come from Debian's ${pkg} package and load at boot, so they take effect after a reboot.

${action^} ${pkg} now?" yes || CPU_MICROCODE=no
  [[ "$CPU_MICROCODE" == yes ]] || { say "   Microcode left as it is."; return 0; }
  run_step "Installing ${pkg}" apt_install_pkg "$pkg"
  say_warn "Reboot the host to load the new microcode."
}

apt_install_pkg() {
  DEBIAN_FRONTEND=noninteractive apt-get -y install "$1"
}

# ---- report and modes -------------------------------------------------------------

report() {   # -> the status text
  local layout governor epp
  layout=$(hybrid_layout)
  governor=$(cpu_governor)
  epp=$(cpu_epp || true)
  printf 'CPU:         %s\n' "$(cpu_model)"
  printf 'Threads:     %s%s\n' "$(cpu_threads)" "${layout:+ (${layout})}"
  printf 'Speed range: %s\n' "$(freq_range)"
  printf 'Speed now:   %s (lowest / median / highest)\n' "$(freq_now)"
  printf 'Driver:      %s%s\n' "$(cpu_driver)" "$( [[ -r ${SYS_CPU}/intel_pstate/status ]] && printf ' (%s)' "$(cat ${SYS_CPU}/intel_pstate/status)"; [[ -r ${SYS_CPU}/amd_pstate/status ]] && printf ' (%s)' "$(cat ${SYS_CPU}/amd_pstate/status)")"
  printf 'Governor:    %s (available: %s)\n' "$governor" "$(cpu_governors)"
  if [[ -n "$epp" ]]; then printf 'Preference:  %s\n' "$epp"; fi
  printf 'Turbo:       %s\n' "$(turbo_state)"
  if [[ -n "$(cpu_temp)" ]]; then printf 'Temperature: %s\n' "$(cpu_temp)"; fi
  if [[ -r /sys/class/powercap/intel-rapl:0/energy_uj ]]; then printf 'CPU power:   %s (measured over 2 s)\n' "$(cpu_watts 2)"; fi
  printf 'Microcode:   %s\n' "$(microcode_status)"
  if [[ -f "$CG_CONF" ]]; then
    printf 'Profile:     %s, kept across reboots by %s\n' \
      "$(profile_label "$(sed -n 's/^CPU_PROFILE=//p' "$CG_CONF")")" "$CG_UNIT_NAME"
  else
    printf 'Profile:     none set by this script (host defaults)\n'
  fi
}

cmd_status() {
  say_head "CPU frequency status"
  report | sed 's/^/  /'
}

cmd_undo() {
  local ORIG_GOVERNOR="" ORIG_EPP="" ORIG_TURBO=""
  say_head "Undo cpu-governor"
  if [[ ! -f "$CG_ORIG" ]]; then
    remove_persistence
    say_ok "Nothing to undo: this script hasn't changed the CPU settings."
    return 0
  fi
  # shellcheck source=/dev/null
  source "$CG_ORIG"
  remove_persistence
  apply_values "$ORIG_GOVERNOR" "$( [[ -n "$ORIG_EPP" && "$ORIG_GOVERNOR" != performance ]] && printf '%s' "$ORIG_EPP" || printf -- '-')" "$ORIG_TURBO"
  rm -f -- "$CG_ORIG"
  log_line "Undo: governor=${ORIG_GOVERNOR} epp=${ORIG_EPP} turbo=${ORIG_TURBO}"
  say_ok "Restored governor ${ORIG_GOVERNOR}${ORIG_EPP:+, preference ${ORIG_EPP}}, turbo ${ORIG_TURBO}; boot service removed"
}

valid_profile() { [[ "$1" == performance || "$1" == balanced || "$1" == powersave ]]; }

cmd_apply() {
  local step=profile gov epp before_w after_w current=""
  preflight_checks
  [[ -n "$(cpu_driver)" ]] || die "This host has no CPU frequency driver (cpufreq), so there is nothing to tune."
  [[ -f "$CG_CONF" ]] && current=$(sed -n 's/^CPU_PROFILE=//p' "$CG_CONF")
  ui_msg "$(report)

The CPU already changes each core's speed with the load. A profile sets how eager it is: Performance favours speed at all times (the Proxmox default), Balanced still boosts to full speed under load but idles cooler, and Power saver favours low power." || true
  local -a hist=()
  local -A preset=()
  local v
  for v in CPU_PROFILE CPU_TURBO CPU_CONFIRM; do
    if ui_is_set "$v"; then preset[$v]=1; fi
  done
  # Back: forget this step's answer (unless preset) and return to the last
  # step that was asked, or leave if there is none.
  cg_back() {
    case $step in turbo) v=CPU_TURBO ;; confirm) v=CPU_CONFIRM ;; *) v=CPU_PROFILE ;; esac
    [[ -n "${preset[$v]:-}" ]] || unset "$v"
    (( ${#hist[@]} )) || ui_cancelled
    step=${hist[-1]}
    unset 'hist[-1]'
    case $step in turbo) v=CPU_TURBO ;; *) v=CPU_PROFILE ;; esac
    [[ -n "${preset[$v]:-}" ]] || unset "$v"
  }
  cg_next() {   # <next step>: remember this one if it was really asked
    case $step in turbo) v=CPU_TURBO ;; *) v=CPU_PROFILE ;; esac
    if [[ -z "${preset[$v]:-}" && ! ( $step == turbo && "${CPU_TURBO:-}" == n/a ) ]]; then hist+=("$step"); fi
    step=$1
  }
  while true; do
    # shellcheck disable=SC2034  # read by lib/ui.func
    if (( ${#hist[@]} )); then UI_BACK_LABEL=Back; else UI_BACK_LABEL=Exit; fi
    case $step in
      profile)
        if ui_menu CPU_PROFILE "Which profile?" "${current:-balanced}" \
          performance "Performance: fastest response, most power (Proxmox default)" \
          balanced    "Balanced: full speed under load, cooler and cheaper at idle" \
          powersave   "Power saver: lowest power and heat, slower to boost"; then
          valid_profile "$CPU_PROFILE" || die "CPU_PROFILE must be performance, balanced or powersave."
          cg_next turbo
        else
          cg_back
        fi
        ;;
      turbo)
        if [[ "$(turbo_state)" == n/a ]]; then CPU_TURBO=n/a; cg_next confirm; continue; fi
        if ui_menu CPU_TURBO "Turbo boost (speeds above the base clock)?" "$(turbo_state)" \
          on  "On: allow turbo (recommended)" \
          off "Off: cap at the base clock; cooler and quieter, slower"; then
          [[ "$CPU_TURBO" == on || "$CPU_TURBO" == off ]] || die "CPU_TURBO must be on or off."
          cg_next confirm
        else
          cg_back
        fi
        ;;
      confirm)
        read -r gov epp < <(profile_plan "$CPU_PROFILE"; echo) || true
        if ui_yesno CPU_CONFIRM "Apply this profile?

  Profile:     $(profile_label "$CPU_PROFILE")
  Governor:    ${gov}
  Preference:  $([[ "$epp" == - ]] && printf '(set by the governor)' || printf '%s' "$epp")
  Turbo:       ${CPU_TURBO}

It takes effect now and is re-applied at every boot by ${CG_UNIT_NAME}. Undo with: cpu-governor.sh --undo" yes Apply Back && [[ "$CPU_CONFIRM" == yes ]]; then
          break
        fi
        [[ -z "${preset[CPU_CONFIRM]:-}" ]] || ui_cancelled   # preset "no": just stop
        cg_back
        ;;
    esac
  done
  before_w=$(cpu_watts 3)
  save_original
  run_step "Applying the $(profile_label "$CPU_PROFILE") profile" apply_values "$gov" "$epp" "$CPU_TURBO"
  run_step "Keeping it across reboots (${CG_UNIT_NAME})" write_persistence "$CPU_PROFILE" "$gov" "$epp" "$CPU_TURBO"
  log_line "Applied ${CPU_PROFILE}: governor=${gov} epp=${epp} turbo=${CPU_TURBO}"
  sleep 2
  after_w=$(cpu_watts 3)
  offer_microcode
  say_head "Done"
  report | sed 's/^/  /'
  if [[ -n "$before_w" ]]; then
    say "  Power before / after (3 s each, current load): ${before_w} / ${after_w}"
  fi
}

usage() {
  cat <<'USAGE'
Usage: cpu-governor.sh [--status | --undo | --help]

Pick a CPU frequency profile for this Proxmox host and keep it across
reboots, or undo it.

  (no option)  show the CPU, then choose Performance, Balanced or Power saver
  --status     show the CPU, driver, settings, power and microcode (read-only)
  --undo       restore the settings from before this script and remove its
               boot service

Presets: CPU_PROFILE=performance|balanced|powersave  CPU_TURBO=on|off
         CPU_CONFIRM=yes  CPU_MICROCODE=yes|no
USAGE
}

main() {
  mkdir -p "$HS_LOG_DIR"
  RCP_LOG="${HS_LOG_DIR}/cpu-governor.log"
  (umask 077; touch "$RCP_LOG")
  rcp_install_traps
  log_line "==== cpu-governor ${1:-} ===="
  case "${1:-}" in
    --status) cmd_status ;;
    --undo)
      (( EUID == 0 )) || die "Run this as root on the Proxmox VE host."
      cmd_undo ;;
    -h|--help) usage ;;
    "") say_head "Proxmox CPU governor"; cmd_apply ;;
    *) die "Unknown option '$1' (try --help)." ;;
  esac
}

main "$@"
