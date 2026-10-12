# Security

- Set an `AuthKey` (8+ characters) on both computers. Frames that fail the HMAC are rejected and counted.
- Set `PeerID` on both computers so only the expected computer is accepted.
- Across dimensions the modem reports no distance, so a non-zero `TrustedRange` drops every frame. Use 0 and rely on
  `AuthKey` and `PeerID`.
- The HMAC covers the frame header only, not the payload (inherited from the bundled library). It stops forged
  frames but is not a tamper-proof payload signature.
- Received messages are validated: wrong types, negative or non-finite numbers, fractional or huge block counts and
  out-of-order sequence numbers are rejected.
- The `AuthKey` is stored in plain text in `/ccpl_sender.cfg` / `/ccpl_display.cfg`.
- The installer downloads code from the address it was built with, and checks size and an Adler-32 checksum from the
  published manifest. That catches damaged downloads, not a compromised server: only publish from a repository you
  control.

Bundled code from cc-mek-scada keeps its MIT licence, see `THIRD_PARTY_NOTICES.md` in the repository.
