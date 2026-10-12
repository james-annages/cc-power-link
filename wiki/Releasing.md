# Releasing

1. Change `VERSION`.
2. Rebuild: `python3 build.py --base-url https://raw.githubusercontent.com/james-annages/cc-power-link/main/dist/`
3. Run the tests: `pip install lupa` then `python3 tests/run_tests.py`
4. Commit and push `dist/` (and the sources) to `main`.

Computers pick the release up with `install update` (or just `install`). The installer on each computer replaces
itself with the published one first, so a copy uploaded to pastebin never needs re-uploading.

`dist/` is generated: never edit it by hand. The tests run against it.

## Editing the wiki

Edit the files in `wiki/` and push to `main`. The *Publish wiki* GitHub Action copies them to the wiki (pages deleted
from `wiki/` are deleted from the wiki, so don't edit pages in the web editor). The wiki must exist first: create any page
in the Wiki tab once.
