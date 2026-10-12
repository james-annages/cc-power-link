# Troubleshooting

The display's computer screen shows `data: <age> | link: up/down` and counters
`ok / auth / peer / order / bad`. They tell you why frames are dropped.

| Symptom | Likely cause |
|---|---|
| `no wireless or ender modem found` | attach a wireless/ender modem (a wired-only modem is not enough) |
| OFF-LINE, `ok` stays 0 | sender not running, channels differ, or the computers are not in loaded chunks |
| `auth` counter rises | AuthKey differs between the two computers |
| `peer` counter rises | `PeerID` does not match the other computer's ID |
| `order` counter rises | frames replayed, or two senders using the same channel |
| `bad` counter rises | frames from something else on the channel, or a protocol mismatch (update both computers) |
| Nothing arrives across dimensions | `TrustedRange` is not 0, or an ender modem is missing on one side |
| "monitor too small" | need 33x24 characters at text scale 0.5, a 2x2 advanced monitor or larger |
| Display flickers OFF-LINE | `StaleMs` is too close to the sender's `SendPeriodMs` |
| Panel says NO MATRIX | the sender found no storage; check `StorageInterface` and the wired link |

Logs are in `/ccpl.log` on each computer. After a crash the program restarts itself after 5 seconds (hold ctrl+t to
cancel).

Check an installation with `install check`; repair it with `install update`.
