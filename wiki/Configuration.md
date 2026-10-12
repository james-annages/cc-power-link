# Configuration

Run `configure` on a computer any time. It shows every setting, lets you pick the storage or monitor from the
peripherals it finds, hides the AuthKey while you type, checks each value, and writes `/ccpl_sender.cfg` or
`/ccpl_display.cfg`. Reboot (ctrl+r) to apply. The file is plain Lua if you prefer to edit it by hand.

| Field | Role | Default | Notes |
|---|---|---|---|
| SenderChannel / DisplayChannel | both | 16250 / 16251 | must match on both computers, must differ from each other; avoid 16240-16244 (cc-mek-scada) |
| AuthKey | both | "" | same on both, 8+ characters, or empty to disable authentication |
| TrustedRange | both | 0 | max accepted distance; **must be 0 across dimensions** |
| PeerID | both | 0 | computer ID of the other end, 0 = accept any |
| LogPath | both | /ccpl.log | log file |
| StorageInterface | sender | "" | peripheral name of the storage, empty = auto-detect |
| StorageTier | sender | 0 | label an energy core as tier 1-8; 0 = no tier shown. The capacity is always read from the core |
| SendPeriodMs | sender | 500 | 250-10000 |
| BuildPeriodMs | sender | 3000 | 1000-60000 |
| Monitor | display | "" | peripheral name, empty = first monitor found |
| EnergyUnit | display | FE | `FE` (also RF) or `J` |
| Theme | display | deepslate | `deepslate` (dark) or `smooth_stone` (light) |
| StaleMs | display | 3000 | time without telemetry before OFF-LINE; keep it at least 3x the sender's SendPeriodMs |

## Tips

- Set `PeerID` on both computers to the other one's computer ID (`id` command) so nothing else can feed the display.
- If you raise `SendPeriodMs`, raise `StaleMs` on the display too, or the display will flicker OFF-LINE.
