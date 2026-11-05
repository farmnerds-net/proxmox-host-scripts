# kernel-manager

See which kernels your Proxmox host runs, boots and has installed, which
kernel series your repositories offer, whether each installed kernel has
the drivers your hardware uses, and which old kernels only take up space.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/farmnerds-net/proxmox-host-scripts/main/kernel-manager.sh)"
```

Run it on the Proxmox host shell as root. It shows the report, then offers
to **try a kernel for one boot**, **pin** or **unpin** one, all through
Proxmox's own `proxmox-boot-tool`. **It never reboots the host**: changes
take effect when you reboot. It can also **install another kernel series**
(checking its drivers first) and **remove old kernels**.

For the report alone, which changes nothing:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/farmnerds-net/proxmox-host-scripts/main/kernel-manager.sh)" -- --report
```

## What it shows

```
Kernel
  Running:      7.0.14-28-pve (up 23 hours)
  Next boot:    7.0.14-28-pve (the newest bootable kernel; nothing is pinned)
  Boot loader:  systemd-boot (UEFI), managed by proxmox-boot-tool on 1 boot partition
  Pinned:       none
  Boot menu:    shows for 3 seconds; default: the newest kernel

Installed kernels
  VERSION           BOOTABLE  SIZE     NOTES
  7.0.14-28-pve     yes       1.0 GB   running, next boot
  7.0.14-26-pve     yes       1.0 GB   fallback
  7.0.14-25-pve     no        1.0 GB   unused: not on the boot partition
  7.0.14-24-pve     no        1.0 GB   unused: not on the boot partition

Kernel series in your repositories
  SERIES  NEWEST         INSTALLED    STATUS                   FROM
  7.0     7.0.14-28      7.0.14-28    default                  pve-no-subscription
  6.17    6.17.13-21     -            older (fallback)         pve-no-subscription
  6.14    6.14.11-9      -            older (fallback)         pve-no-subscription

Hardware check
  Drivers your devices use now, looked up in each installed kernel:
  7.0.14-28-pve     all 14 drivers your devices use are present
  ...
  Passthrough:  2 device(s) use vfio-pci. Kernel changes can affect passthrough,
                so try a new kernel for one boot first.
  DKMS modules: none (dkms not installed)
  Firmware:     pve-firmware 3.18-9 (up to date)
  Microcode:    intel-microcode 3.20251111.1~deb13u1 (up to date)

Cleanup suggestions (nothing is removed)
  These kernels aren't running, pinned, next to boot or the fallback:
    7.0.14-25-pve     1.0 GB   (package proxmox-kernel-7.0.14-25-pve-signed)
    7.0.14-24-pve     1.0 GB   (package proxmox-kernel-7.0.14-24-pve-signed)
  Removing them would free about 2.1 GB.
```

- **Next boot** is what the host will start after a reboot: a kernel pinned
  for the next boot only, else a pinned kernel, else the newest bootable
  one. If it isn't the running kernel, the report says a reboot will switch.
- **Bootable** means the boot loader can start it. With
  `proxmox-boot-tool` (most installs), only the kernels it copies to the
  boot partition are bootable; others are installed but unused.
- **Kernel series**: the **default** series is the one Proxmox installs
  and updates (`proxmox-default-kernel`). **Older** series are fallbacks
  for hardware that has trouble with the default. **Opt-in** series are
  newer than the default and less tested; they appear here when Proxmox
  publishes them.
- **Fallback** is the newest bootable kernel other than the next-boot one:
  what you'd boot if the next kernel misbehaves.

## The hardware check

There's no official list of which kernel works with which motherboard. What
actually breaks after a kernel change is usually a missing driver or an
out-of-tree module that wasn't rebuilt, and that's what the check looks at:

- **Drivers:** every driver your PCI devices use right now (disk, network,
  graphics, USB, passthrough) is looked up in each installed kernel. A
  driver that's missing is listed by name. Drivers that are part of the
  kernel's core (like the PCIe port driver) are always present.
- **DKMS modules** (for example NVIDIA's driver) must be rebuilt for each
  kernel; the report lists them.
- **Firmware and microcode:** newer kernels sometimes expect newer
  firmware; the report says whether `pve-firmware` and the CPU microcode
  are up to date.
- **Passthrough:** if devices use `vfio-pci`, it reminds you that kernel
  changes can affect passthrough.

For a driver-by-driver list of one installed kernel:

```bash
kernel-manager.sh --check 7.0.14-26-pve
```

Kernels that aren't installed are checked before you install them: the
script downloads the package and reads its driver list (see below).

## Cleanup suggestions

Old kernel builds stay installed after updates (about 1 GB each). The
report lists the ones that aren't running, pinned, next to boot or the
fallback, and how much space removing them would free. The report itself
removes nothing; use **Remove old kernels** (below) for that.

## Trying, pinning and unpinning

After the report, pick what to do. Every screen has **Back**; the first
has **Exit**. Kernels with missing drivers are marked in the list, and you
get an extra warning before choosing one.

| Action | What it does |
| --- | --- |
| **Try a kernel for the next boot only** | The safest way to test a kernel: the next boot starts it once, then the host goes back to normal |
| **Pin a kernel** | Keep booting it, also after kernel updates (they're still installed, just not started) |
| **Keep the running kernel** | Shown when you're running an older kernel (for example after a trial): pin it |
| **Remove the pin** | Boot the newest kernel again and follow updates as usual |
| **Cancel the next-boot trial** | Undo a trial you set but haven't rebooted into yet |
| **Install another kernel series** | Add an older series as a fallback, or a newer opt-in one (see below) |
| **Remove old kernels** | Free space by removing kernels you no longer need (see below) |

After each change the script reads the boot loader's actual default from
the boot partition and shows it, so you can see the change took.

### What happens if a trial kernel has problems

How Proxmox's one-boot trial works: the trial kernel becomes the boot
loader's default, and **after it has booted**, Proxmox's
`proxmox-boot-cleanup` service removes the trial again. So:

- **The trial kernel boots but something doesn't work** (a driver,
  passthrough, a VM won't start): **just reboot once more.** The cleanup
  already ran, and the host is back on its normal kernel.
- **The trial kernel doesn't start at all** (it hangs or panics before the
  system is up): the cleanup can't run, so the host keeps trying it. Then,
  at the console, **choose your previous kernel in the boot menu** (it shows
  for a few seconds at startup; the report says how long), and once it's
  up, run the script with `--cancel-try`.

The second case is rare, but it's why you need console access (a screen,
IPMI or similar) when you try a kernel, and why **trying first, then
pinning** is the safe order.

### Without menus

```bash
kernel-manager.sh --try 6.17.13-21-pve   # start this kernel on the next boot only
kernel-manager.sh --pin 7.0.14-26-pve    # keep booting this kernel
kernel-manager.sh --unpin                # remove the pin and any trial
kernel-manager.sh --cancel-try           # remove only the next-boot trial
```

The kernel must be installed. Presets for the menus: `KM_ACTION`
(`try`, `pin`, `keep`, `unpin`, `cancel-try`), `KM_KERNEL`, `KM_CONFIRM=yes`.

## Installing another kernel series

Pick a series from your repositories that isn't installed yet. Each is
labelled **older, a fallback** or **OPT-IN, newer and less tested**, with
its download size.

1. **Opt-in series** first show what that means (newer than the default,
   less tested, can have regressions with passthrough, ZFS, network cards or
   graphics) and need you to confirm with **I understand** (No is the
   default).
2. **Driver check before installing:** the script downloads the kernel
   package (about 110-125 MB) and checks it has every driver your devices
   use. The result is on the confirmation screen.
3. After installing, it asks **what the next boot should do**:
   - An **older** series doesn't change your next boot. You can try it for
     one boot, pin it, or leave it as a fallback.
   - A **newer** series would become the default automatically (the newest
     kernel boots). So you choose: **try it for the next boot only, then
     return to your current kernel** (recommended: your current kernel is
     pinned for that, unpin later with `--unpin`), boot it from now on, or
     not yet (your current kernel stays pinned).

Without a terminal (`--install 6.17` from a script), it never lets a new
kernel boot by surprise: a newer one gets your current kernel pinned, an
older one changes nothing.

## Removing old kernels

A checklist of the kernels that are safe to remove: not running, not next
to boot, not pinned (also not for the next boot) and not the fallback. All
are ticked; untick any you want to keep. Before removing anything, apt is
asked in a dry run, and if it would remove any other package the script
stops. It also removes the series' meta package once none of its kernels
is left, and apt's cached downloads of what it removed.

These are the same kernels Proxmox's own `apt autoremove` would remove.

### Without menus

```bash
kernel-manager.sh --install 6.17                 # older series
KM_OPTIN=yes kernel-manager.sh --install 7.1     # an opt-in series (example)
kernel-manager.sh --remove 7.0.14-24-pve 7.0.14-25-pve
```
