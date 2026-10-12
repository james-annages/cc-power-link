# Installation

You need `http` enabled in the server's ComputerCraft config.

## Hardware

- **Sender**: computer + wireless (or ender) modem + a wired link to the storage (for example an `inductionPort`).
- **Display**: computer + wireless (or ender) modem + a **2x2 advanced monitor or larger**. The panel is 33x24
  characters at text scale 0.5.
- Across dimensions: both computers must be in loaded chunks and use ender modems.

## First install

```
wget https://raw.githubusercontent.com/james-annages/cc-power-link/main/dist/install.lua install.lua
install sender        (or: install display)
```

The installer downloads every file into a staging folder, checks each size and checksum, and only then moves them
into place. It then offers to reboot. On the first start the configuration tool opens by itself.

## Commands

| Command | What it does |
|---|---|
| `install sender` / `install display` | first install (`--url <address>` for another server, `-y` to skip questions) |
| `install update` | install the published version, repair changed or missing files, remove files that no longer exist, keep the configuration |
| `install` (no command) | on a computer that already has cc-power-link installed, the same as `install update` |
| `install check` | compare this computer with the published version and list differences |
| `install remove [--purge]` | uninstall; the configuration is kept unless `--purge` |
| `--no-self-update` | do not replace the installer with the published one first |

## The installer updates itself

Every run compares the installer with the one published next to the files. If they differ it downloads the newer
one, checks it, and carries on with it. So you can upload `dist/install.lua` to pastebin **once** and never touch that
copy again; releasing is just pushing a new `dist/` to GitHub.

Use the file from `dist/`, not `tools/install.lua`: the `dist/` copy has the download address filled in.

## Updating a computer

Run `install update`, then reboot (ctrl+r). The configuration file is kept.

## Upgrading from the old "ESS Link" name

`install update` migrates a computer installed under the old name: the configuration moves from `/ess_<role>.cfg` to
`/ccpl_<role>.cfg` (settings kept, the default log path becomes `/ccpl.log`), the install record moves to
`/ccpl_install.json`, and the old `ess/` program folder is removed. Reboot afterwards (ctrl+r).
