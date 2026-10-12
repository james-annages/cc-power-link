# cc-power-link

A standalone ComputerCraft program pair that shows an energy storage system on a monitor: a Mekanism induction
matrix or a Draconic Evolution energy core, over a wireless/ender modem, including across dimensions. It has its own
installer and configuration tool and does not need any other SCADA software on the computers.

Its screen library, packet framing and message authentication come from small, unmodified parts of the MIT-licensed
[cc-mek-scada](https://github.com/MikaylaFischler/cc-mek-scada) libraries, bundled in `third_party/` with their license.
That is only a source of code; nothing of cc-mek-scada needs to be installed or running.

Two computers:

- **sender**: next to the induction port, reads the matrix and transmits over a wireless/ender modem.
- **display**: wherever you want the screen, receives and draws the panel on an advanced monitor.

## Install

**Publish once** (from your build machine):

1. `python3 build.py --base-url https://raw.githubusercontent.com/james-annages/cc-power-link/main/dist/`
2. Commit the `dist/` folder (`install.lua`, `manifest.json`, `sender/`, `display/`) to that repo and push.

**On each computer** (needs `http` enabled in the server's ComputerCraft config):

```
wget https://raw.githubusercontent.com/james-annages/cc-power-link/main/dist/install.lua install.lua
install sender        (or: install display)
```

The installer downloads every file into a staging folder, checks each size and checksum, and only then moves them
into place, so a failed download never leaves a half-installed computer. It then offers to reboot. On the first start
the configuration tool opens by itself.

| Command | What it does |
|---|---|
| `install sender` / `install display` | first install (`--url <address>` to use another server, `-y` to skip questions) |
| `install update` | install the published version, repair changed or missing files, remove files that no longer exist, keep the configuration |
| `install check` | compare this computer with the published version and list differences |
| `install remove [--purge]` | uninstall; the configuration is kept unless `--purge` |

To release a new version, change `VERSION`, rebuild, and push `dist/`; computers pick it up with `install update`.

**Upload the installer once.** `dist/install.lua` can be put on pastebin (or anywhere) a single time. Every run compares
itself with the installer published next to the files and, if it differs, downloads the newer one and continues with it,
so the uploaded copy never needs updating. Use `--no-self-update` to skip that. A bare `install` on a computer that
already has cc-power-link installed does the same as `install update`.

**Renamed from "ESS Link".** The project used to be called ESS Link (`ess/` folder, `/ess_sender.cfg`, `/ess_install.json`,
`/ess.log`). Running `install update` on such a computer moves the configuration and install record to the new names
(`/ccpl_sender.cfg`, `/ccpl_display.cfg`, `/ccpl_install.json`, log `/ccpl.log`), keeps your settings and removes the old
`ess/` files.

## Configuration

Run `configure` on a computer any time. It shows every setting, lets you pick the storage or monitor from the
peripherals it finds, hides the AuthKey while you type, checks each value, and writes `/ccpl_sender.cfg` or
`/ccpl_display.cfg`. Reboot (ctrl+r) to apply. The file is plain Lua if you prefer to edit it by hand.

## Supported storage

- Mekanism induction matrix (`inductionPort`, `reinforcedInductionPort`): live input/output from the multiblock.
- Draconic Evolution energy core (peripheral type `draconic_rf_storage`, the peripheral Draconic Evolution provides): tier, level, live input/output.
- Any other block exposing `getEnergy`/`getEnergyCapacity` (or `getEnergyStored`/`getMaxEnergyStored`): level and time to full/empty, rates measured from the change in energy.

Auto-detect prefers a matrix, then an energy core, then the largest generic storage.

## Hardware

- Sender: computer + wireless (or ender) modem + wired link to an `inductionPort` / `reinforcedInductionPort`.
- Display: computer + wireless (or ender) modem + **2x2 advanced monitor or larger** (the panel is 33x24 characters at text scale 0.5).
- Across dimensions: both computers must be in loaded chunks (chunk loaders) and use ender modems.

## Settings

| Field | Both/Role | Default | Notes |
|---|---|---|---|
| SenderChannel / DisplayChannel | both | 16250 / 16251 | must match, must differ |
| AuthKey | both | "" | same on both, 8+ chars, or empty to disable |
| TrustedRange | both | 0 | **must be 0 across dimensions** (see below) |
| PeerID | both | 0 | computer ID of the other end, 0 = any |
| StorageInterface | sender | "" | peripheral name of the storage, empty = auto-detect |
| StorageTier | sender | 0 | label an energy core as tier 1-8, 0 = no tier shown (capacity is always read from the core) |
| SendPeriodMs / BuildPeriodMs | sender | 500 / 3000 | |
| Monitor, EnergyUnit ("FE"/"J"), Theme | display | | |
| StaleMs | display | 3000 | time without telemetry before OFF-LINE; keep it at least 3x the sender's SendPeriodMs |

## Security notes

- Across dimensions the modem reports no distance, so a non-zero TrustedRange drops every frame. Use 0 and set an AuthKey.
- cc-power-link enforces message authentication itself: frames that fail the HMAC are rejected and counted.
- The HMAC covers the frame header only, not the payload (inherited from the bundled library), so it stops forged frames
  but is not a tamper-proof payload signature.
- In the simulator, the bundled library's `network.init_mac` derived the same key for every passkey because it passes a string
  where the key derivation expects a byte array. cc-power-link converts the key itself. This was seen in simulation under
  standard Lua rules, not in game.

## Wiki

Longer guides are in the project wiki; their source is in `wiki/` in this repository and a GitHub Action (`.github/workflows/wiki.yml`) publishes it to the wiki when it changes on `main`. Create a first page in the Wiki tab once so the wiki exists.

## Licence

MIT, see `LICENSE`. Bundled third-party code keeps its own MIT licences, see `THIRD_PARTY_NOTICES.md`.

## Tests

`python3 tests/run_tests.py` (needs `pip install lupa`). It runs the real startup scripts and libraries against a
ComputerCraft simulator (modems, monitors, timers, fs). It has not been run inside Minecraft.
