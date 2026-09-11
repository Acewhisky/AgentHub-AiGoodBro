# Isolated workspace preview fixtures

`--render-workspace-previews` renders production SwiftUI views from injected synthetic data. It uses a unique temporary root and `UserDefaults` suite, never discovers local CLI installations, and never reads real profiles, configuration, Keychain, or authentication state. Every fixture identity uses `example.invalid`; the renderer window is non-presented and no account action is invoked.

## Acceptance scene index

Each scene is emitted in `dark` and `light` variants.

| Pattern | Purpose |
|---|---|
| `acceptance-matrix-rows-<theme>-720x900.png` | Narrow live-window crop using production rows; checks clipping and the fixed identity/quota/action columns. |
| `acceptance-matrix-rows-<theme>-full.png` | Full 980-point workspace capture with all Codex, Grok, OpenCode, and WorkBuddy rows. |
| `acceptance-matrix-cards-<theme>-720x900.png` | Narrow live-window crop using production cards; checks responsive card sizing and icon scale. |
| `acceptance-matrix-cards-<theme>-full.png` | Full 980-point workspace capture with all provider cards. |
| `acceptance-provider-grok-<theme>-760x640.png` | Grok provider detail with short/long names and 0%/100% remaining; reset-card state stays unknown because the official adapter exposes no card field. |
| `acceptance-provider-openCode-<theme>-760x640.png` | OpenCode provider detail with Rolling/7-day/Monthly OpenCode Go windows plus the truthful “Go not connected” state. |
| `acceptance-provider-workBuddy-<theme>-760x640.png` | WorkBuddy provider detail with short/long names and the truthful unsupported-quota state; no quota window is invented. |

The Codex accounts cover unknown quota/reset count, 0% and 100% remaining, a non-expiring available reset-credit state, and an expiring reset-credit state. OpenCode covers a production-supported three-window quota shape. Grok covers its production-supported single Credits window and explicitly unknown reset-card data. WorkBuddy has no confirmed official quota interface, so its fixture remains unsupported.

## Reproduce

From the repository root, build and render Chinese fixtures into task-owned ignored directories:

```sh
bash scripts/render-workspace-preview-fixtures.sh \
  .local-artifacts/workspace-preview-build \
  .local-artifacts/workspace-previews-zh
```

Render the same final integrated source in English:

```sh
bash scripts/render-workspace-preview-fixtures.sh \
  .local-artifacts/workspace-preview-build-en \
  .local-artifacts/workspace-previews-en \
  --preview-english
```

Do not use `make run`, `open`, or the installed application for fixture acceptance.
