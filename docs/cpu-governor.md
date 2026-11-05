# cpu-governor

See how your Proxmox host's CPU scales its speed, pick a profile
(**Performance**, **Balanced** or **Power saver**), keep it across reboots,
and undo it whenever you like. It also checks that your CPU's microcode is
up to date.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/farmnerds-net/proxmox-host-scripts/main/cpu-governor.sh)"
```

Run it on the Proxmox host shell as root.

## How CPU scaling works (and what this script does)

Your CPU already changes each core's speed with the load, by itself,
many times a second: idle cores drop to their lowest speed and busy ones
boost. A script can't do that faster. What the kernel gives you are the
**limits and hints** the CPU works within, and that's what this script sets:

- the **governor**: the kernel's scaling policy
- the **energy/performance preference** (EPP), on CPUs whose driver has
  one (Intel `intel_pstate`, AMD `amd-pstate-epp`), which tells the CPU how
  eager to be
- **turbo**: whether speeds above the base clock are allowed

Proxmox's default is **Performance**: the CPU still idles down, but always
leans towards speed. It doesn't take cores offline (the CPU's own idle
states already park unused cores better) and doesn't change kernel boot
options.

## The profiles

| Profile | Intel / AMD with EPP | Other drivers | Good for |
| --- | --- | --- | --- |
| **Performance** | governor `performance` | `performance` | lowest latency; the Proxmox default |
| **Balanced** | `powersave` + `balance_performance` | `schedutil` (or `ondemand`) | most 24/7 hosts: still boosts to full speed under load, idles cooler |
| **Power saver** | `powersave` + `balance_power` | `conservative` (or `schedutil`) | quiet or low-power boxes; slower to boost |

With Intel and AMD's active drivers, the `powersave` governor does **not**
mean slow: the CPU still picks its own speed, up to full turbo. The
preference only changes how readily it does.

Measured on an Intel Core i9-14900KS host (idle, CPU package power, and
the speed one busy performance core reached):

| | Performance | Balanced | Power saver, turbo off |
| --- | --- | --- | --- |
| Idle power | 14 W | 10 W | 10 W |
| One busy core | 4.9 GHz | 5.9 GHz | 3.2 GHz (base clock) |

Your numbers will differ; the script shows the power before and after
applying a profile on CPUs that report it.

## Using it

1. It shows what it found: the CPU model, cores (performance and efficiency
   cores on hybrid Intel CPUs), speed range and current speeds, the driver,
   governor and preference, turbo, temperature, CPU power, microcode, and
   any profile it has set before.
2. Pick a profile, then whether to allow turbo.
3. Confirm. It applies the profile to every core right away and installs a
   small boot service (`proxmox-host-scripts-cpu-governor.service`) that
   applies it again after every reboot.

Every screen has **Back** (or Esc) to return to the previous one; the first
has **Exit**.

### Microcode

Microcode updates fix CPU bugs, including stability problems such as the
13th/14th-gen Intel one. The script checks Debian's `intel-microcode` or
`amd64-microcode` package. If it's missing or out of date, it offers to
install or upgrade it (it asks first). New microcode loads at boot, so
**reboot the host** afterwards. If the package isn't available, enable
Debian's `non-free-firmware` component in your apt sources; the script
doesn't edit them.

## Undo

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/farmnerds-net/proxmox-host-scripts/main/cpu-governor.sh)" -- --undo
```

Before its first change, the script saves the host's original settings.
Undo puts exactly those back and removes the boot service and its files.
(It doesn't uninstall microcode it installed; that's worth keeping.)

## Other options

```bash
cpu-governor.sh --status   # everything it detects, plus the current profile; changes nothing
cpu-governor.sh --help
```

### Without questions

```bash
CPU_PROFILE=balanced CPU_TURBO=on CPU_CONFIRM=yes CPU_MICROCODE=no \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/farmnerds-net/proxmox-host-scripts/main/cpu-governor.sh)"
```

| Variable | Value |
| --- | --- |
| `CPU_PROFILE` | `performance`, `balanced` or `powersave` |
| `CPU_TURBO` | `on` or `off` |
| `CPU_CONFIRM` | `yes` skips the confirmation |
| `CPU_MICROCODE` | `yes` / `no`: install or upgrade microcode if needed |

## Files

- Boot service: `/etc/systemd/system/proxmox-host-scripts-cpu-governor.service`,
  running `/usr/local/sbin/proxmox-host-scripts-cpu-governor`
- Profile: `/etc/proxmox-host-scripts/cpu-governor.conf`
- Original settings (for undo): `/etc/proxmox-host-scripts/cpu-governor.orig`
- Log: `/var/log/proxmox-host-scripts/cpu-governor.log`
