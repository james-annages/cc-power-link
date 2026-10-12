# Contributors

Thank you to everyone who has helped build cc-power-link.

## Project

| Who | Role |
|---|---|
| [@james-annages](https://github.com/james-annages) | Creator and maintainer |
| [Claude](https://claude.ai/code) (AI assistant) | Code, tests, installer, docs and review fixes, working with the maintainer through Claude Code |

The full list of people who have committed is on the
[contributors graph](https://github.com/james-annages/cc-power-link/graphs/contributors).

## Built on

cc-power-link bundles unmodified, MIT-licensed code from these projects. Their licences travel with the files, see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

| Project | Author | Used for |
|---|---|---|
| [cc-mek-scada](https://github.com/MikaylaFischler/cc-mek-scada) | Mikayla Fischler | screen library, packet framing, message authentication, and the layout the panel is adapted from |
| lockbox (bundled in cc-mek-scada) | James L. | the HMAC and key derivation behind message authentication |

Mekanism, Draconic Evolution and ComputerCraft: Tweaked are the mods the program reads from and runs on.

## Contributing

1. Fork the repository and create a branch.
2. Edit the sources (`lib/`, `sender/`, `display/`, `tools/`), never `dist/` by hand.
3. Rebuild and test:
   ```
   python3 build.py --base-url https://raw.githubusercontent.com/james-annages/cc-power-link/main/dist/
   pip install lupa
   python3 tests/run_tests.py
   ```
4. Commit the rebuilt `dist/` with your change and open a pull request.

Wiki pages live in `wiki/` and are published to the GitHub wiki automatically when they change on `main`, so edit them
there, not in the web editor. Bug reports and ideas are welcome as
[issues](https://github.com/james-annages/cc-power-link/issues).
