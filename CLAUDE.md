# pve-purestorage-plugin

Perl storage plugin (`PureStoragePlugin.pm`) for Proxmox VE and Pure Storage.

## Rules

- Run `prove tests/unit/` before every commit. Unit tests load the real plugin: call its functions, never copy them into a test. A plugin change ships with a unit test that failed first.
- The plugin must work on PVE 8 and PVE 9 (storage API versions 11 to 16). Check every change on a node of each version. Use only Perl syntax and PVE functions that exist in both.
- E2E tests run only on request, never in CI by default, one test after another. Deploy the plugin to a node only after an explicit request, one node at a time, never while a run is active.
- Stand access lives in `.env` (git-ignored, may hold secrets): read only the keys. Never print `/etc/pve/storage.cfg` raw. Changing `storage.cfg` needs an explicit request.
- Documents and comments stay impersonal: nothing specific to a particular stand or person. Where an exact value is needed, put it in `CLAUDE.local.md` (not committed) or `.env`.
- Code, comments and docs in English. 2-space indentation, `.perltidyrc` for Perl.
- Conventional commits: `<type>(<scope>): <subject>`, subject up to 50 characters.
- Do not hard-wrap prose in markdown: one paragraph or list item is one line. `.markdownlint.json` disables MD013.

## Read when needed

- `docs/agents/testing.md`: before running tests or using the stand (order, rules, known behaviours and skips).
- `docs/agents/plugin-notes.md`: before changing activation, removal, resize or allocation (why the code is ordered as it is).
- For people: `README.md`, `docs/*.md`, `tests/e2e/README.md`.
