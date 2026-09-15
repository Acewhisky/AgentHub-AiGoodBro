# Contributing

## Source baseline and branch lifecycle · 0915v1

Changes since the earlier branch workflow: use `main` as the integration entry, keep the rebuilt V1.0 application as the accepted macOS baseline, and distinguish source integration from native acceptance.

- `V1.0` permanently identifies commit `517f2daeccca54fe9c388660c52889aef48f54dd`, corresponding to macOS 9.6.1 (50). Later documentation, CI or Windows fixes must not move this tag or restore an older macOS implementation.
- Compare branch contents and commit ancestry before integration. Old branch names and timestamps are not evidence that a feature is missing from the current app.
- Use focused pull requests into `main` and preserve their commit history with merge commits. Delete completed development branches only after their commits are reachable from `main`.
- If a superseded branch was replaced rather than merged, preserve its exact head under an archive tag before retiring the branch. `archive/app-backups` contains historical built applications and stays outside the source integration flow.
- Keep unfinished Windows migration work separate until its changed execution paths, Tauri/Web builds and required native behavior are verified. A macOS pass, a pure policy test or a configured CLI is not proof of Windows behavior or a successful model request.

## Local verification

Build without launching the App:

```bash
make build
make test-palettes
./scripts/test-status-item.sh
```

For account automation changes, also run:

```bash
build/AiGoodBro.app/Contents/MacOS/AiGoodBro --self-test-automatic-account-switch
build/AiGoodBro.app/Contents/MacOS/AiGoodBro --self-test-account-switch-safety
build/AiGoodBro.app/Contents/MacOS/AiGoodBro --self-test-feishu-webhook
build/AiGoodBro.app/Contents/MacOS/AiGoodBro --self-test-account-automation-audit
```

Keep changes focused, preserve the local-first boundary, and update documentation when behavior, permissions, storage, packaging, or network disclosure changes. Never attach real account data, webhooks, thread titles, local databases, or screenshots containing private tasks to an issue or pull request.

Windows runtime captures and probe output must remain under the Git-ignored `.local-artifacts/` directory. Any public visual evidence must be regenerated from fully synthetic fixtures under the rules in [`docs/windows-port/README.md`](docs/windows-port/README.md).

Palette packages remain declarative under `Resources/Palettes/<stable-id>/` and must pass `make test-palettes`. Historical palette IDs, project-local tool IDs and Windows package paths remain internal compatibility details, not current product names. Public product copy, issue routing and macOS releases use AiGoodBro; the in-app workspace name remains AgentHub.
