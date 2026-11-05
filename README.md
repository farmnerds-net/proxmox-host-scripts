# proxmox-host-scripts

Scripts that run on your Proxmox VE host to make housekeeping and everyday
host tasks simpler. Companion of
[proxmox-recipes](https://github.com/farmnerds-net/proxmox-recipes), which
builds app containers, and built on the same engine, so they look and
behave the same.

## Scripts

| Script | What it does |
| --- | --- |
| [iso-download](docs/iso-download.md) | Download a Linux ISO (server, desktop or gaming) to a storage, from the official site, checksum-verified, with a progress meter |
| [cpu-governor](docs/cpu-governor.md) | Detect the CPU and how it scales, pick a Performance / Balanced / Power saver profile that survives reboots, undo it; checks microcode |

## Usage

Run on the Proxmox host shell as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/farmnerds-net/proxmox-host-scripts/main/<script>.sh)"
```

> **Warning:** These scripts run as **root on your Proxmox host**. Read a
> script before you run it.

Every question can be answered in advance with a variable, so the scripts
also run unattended; each script's doc lists them. Logs go to
`/var/log/proxmox-host-scripts/`.

### Testing a branch or local checkouts

```bash
HOST_SCRIPTS_REF=<branch> bash <script>.sh   # this repo's branch
RECIPES_REF=<branch> bash <script>.sh        # engine (proxmox-recipes) branch
HOST_SCRIPTS_SRC=/path/to/proxmox-host-scripts RECIPES_SRC=/path/to/proxmox-recipes bash <script>.sh
```

## Layout

- `<script>.sh`: the scripts, one per task.
- `lib/`: shared menus (`ui.func`) and progress meter (`progress.func`).
- `iso/`: the ISO catalog and its official-source resolvers.
- `docs/`: one page per script.

## Support

If these scripts save you time, you can
[support farmnerds on Ko-fi](https://ko-fi.com/farmnerds).

## License

[MIT](LICENSE)
