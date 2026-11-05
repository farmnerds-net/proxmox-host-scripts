# iso-download

Download a Linux installer ISO onto a Proxmox VE storage, straight from the
distribution's official site, with its checksum verified, ready to pick when
you create a VM.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/farmnerds-net/proxmox-host-scripts/main/iso-download.sh)"
```

Run it on the Proxmox host shell as root.

## What it does

1. **Where to save it.** It lists the storages that can hold ISO images,
   with their free space. The storage you used last time is pre-selected
   (marked "last used"). A storage that's disabled, or doesn't have "ISO
   image" content enabled, isn't offered.
2. **What to download.** Pick a group (Server, Desktop, Gaming), search by
   name with **Find your own**, or **paste a download link**.
3. **It looks up the current release** on the distribution's official site
   (latest version, file name and checksum), shows a summary, and asks
   before downloading.
4. **Proxmox downloads it**, the same way as "Download from URL" in the web
   UI, so it also appears as a task there. A progress meter shows how it's
   going:

   ```
    ⬇ Debian (netinst) ▕█████████████▉        ▏  63%  502.5 MB/792.7 MB  106.3 MB/s  0:02 left
    ⏳ Verifying the SHA256 checksum...
    [ ok ] debian-13.7.0-amd64-netinst.iso downloaded to local and its SHA256 checksum verified
   ```

5. **The checksum is verified.** If it doesn't match, the file is thrown
   away and you're told why. If the ISO is already on that storage, nothing
   is downloaded again.

When it's done, create a VM and choose the ISO under **OS > ISO image**.

## The list

| Server | Desktop | Gaming |
| --- | --- | --- |
| Debian (netinst) | Ubuntu Desktop LTS | CachyOS (desktop) |
| Ubuntu Server LTS | Linux Mint (Cinnamon) | CachyOS (handheld) |
| Rocky Linux (minimal) | Fedora Workstation | Bazzite (AMD/Intel GPU) |
| AlmaLinux (minimal) | Pop!_OS (Intel/AMD) | Bazzite (NVIDIA, open driver) |
| Fedora Server (DVD) | Pop!_OS (NVIDIA) | Bazzite Deck (Steam Gaming Mode) |
| openSUSE Leap (offline) | Manjaro (KDE Plasma) | Nobara (KDE) |
| Alpine Linux (virt) | MX Linux (Xfce) | Garuda dr460nized Gaming |
| Proxmox VE | EndeavourOS | |
| Proxmox Backup Server | openSUSE Tumbleweed (DVD) | |
| | Arch Linux | |
| | NixOS (graphical) | |
| | Kali Linux (installer) | |
| | Zorin OS *(paste link)* | |
| | elementary OS *(paste link)* | |

Every entry always gets the **latest release**, found on the
distribution's own site each time you run it. amd64 (x86_64) only for now;
ARM is planned.

**Zorin OS and elementary OS** don't publish a download link and checksum
that a script can read, so for those the script shows their official
download page and you paste the link and checksum from there.

**Anything else:** use **Paste a download link**. Copy the ISO's link and
its SHA-256 or SHA-512 checksum from the distribution's official download
page. The checksum is required: it's what proves you got the real file.

The list is curated rather than pulled from a ranking site: popularity
sites don't allow scripts to read them, and their rankings measure page
visits, not installs. Suggestions are welcome.

## Without questions

Every question can be answered in advance:

```bash
ISO_STORAGE=local ISO_DISTRO=debian ISO_CONFIRM=yes \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/farmnerds-net/proxmox-host-scripts/main/iso-download.sh)"
```

| Variable | Value |
| --- | --- |
| `ISO_STORAGE` | storage to save to |
| `ISO_DISTRO` | a name from `--list` (e.g. `bazzite`), or `url` |
| `ISO_URL`, `ISO_CHECKSUM` | with `ISO_DISTRO=url`: the link and its SHA-256/512 |
| `ISO_CONFIRM` | `yes` skips the last confirmation |

## Other options

```bash
iso-download.sh --list    # the catalog, with the names ISO_DISTRO takes
iso-download.sh --check   # look up every entry's current ISO; downloads nothing
```

`--check` shows each distribution's current version, size and file name,
and exits with an error if any lookup fails, for example because a
distribution changed its download site. It's worth running now and then
(or from a scheduled job) to catch that early.

## Files

- Log: `/var/log/proxmox-host-scripts/iso-download.log`
- Remembered storage: `/etc/proxmox-host-scripts/iso-download.conf`
