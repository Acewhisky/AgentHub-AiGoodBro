# Additional native CLI account/quota source note

This note records the evidence boundary for `AdditionalCLIQuotaReader`. Research was static and
read-only. No live credential, Keychain, cookie, or selected-account file was opened; no CLI or app was
launched; and no provider request was sent.

## Coverage matrix

| Provider | Native account evidence | Quota evidence and implementation | Deliberate limitation |
|---|---|---|---|
| Gemini CLI 0.56.0 | Selected profile `settings.json` → `security.auth.selectedType`; `oauth_creds.json` → fresh `access_token`, `id_token`, `expiry_date`. Identity comes only from the ID-token `email` or `sub` claim and is masked/fingerprinted. | Implemented. `loadCodeAssist` supplies the native project and tier; `retrieveUserQuota` supplies `buckets[].modelId`, `remainingFraction`, and `resetTime`. Duplicate model buckets retain the lowest remaining fraction. | OAuth-personal only. An expired/missing token requires login; there is no refresh, credential write, model request, Cloud Resource Manager project discovery, account fallback, or API-key/Vertex scope crossover. |
| Xiaomi MiMo Code 0.1.9 | Data-root `auth.json` → provider `xiaomi`, `type: "api"`, API key, and `metadata.uid`; MiMo's `whoami` implementation reads this metadata. The reader exposes only the masked UID and stable UID fingerprint. | Not source-verifiable for the native CLI credential, so the result is explicitly `unsupported` with no windows or balance. | The native key is used for inference at the authorization-returned `metadata.base_url`. The known platform balance/token-plan route requires browser cookies, not this CLI key. The app should link the limitation action to `https://platform.xiaomimimo.com/token-plan`; it must not scrape cookies or relabel local token counts as quota. |
| ZCode 3.11.2 | Bundled source defines a shared encrypted store at `$ZCODE_DATA_BASE_DIR/.zcode/v2/credentials.json` (or the corresponding home-root path), containing `oauth:active_provider`, Z.AI access/user data, and `zcodejwttoken`. | Not implemented as a network adapter. The result is explicitly `unsupported` with no credential-file read, identity, windows, or balance. | The bundle defines `/api/v1/zcode-plan/billing/current` and `/api/v1/zcode-plan/billing/balance`, but contains no billing call site or response schema (each path/symbol occurs only in the URL builder). Recreating native decryption or guessing authorization/schema would be unsafe. Keep ZCode native-plan state distinct from a Z.AI API subscription. The app may offer `https://zcode.z.ai` as the official account entry. Desktop GLM-5.3-Flash availability is not CLI remaining quota. After an authorized re-login, CLI `zai/glm-5.3-flash` and 5.1 returned 1113 (no resource pack); that route is stopped. Do not treat desktop login, membership, API balance, or local token counts as native CLI remaining subscription. |
| WorkBuddy CLI 2.137.1 | Official bundled CLI (`codebuddy`) completed a minimal return and code-review path with `deepseek-v4.1-flash`. | No official quota response is confirmed. The adapter returns `unsupported` with no windows, balance, identity, transport, or credential read. | Missing official quota is unknown, not `needsLogin`, and not 0%/100%. Do not invent a billing probe or copy desktop membership as CLI remaining. |
| TRAE SOLO | Personal TRAE SOLO is currently a desktop entry. An independent CLI / quota protocol is not confirmed. | Not implemented. The adapter returns `unsupported` with no windows, balance, identity, transport, or credential read. | Do not classify TRAE as `needsLogin`. Do not probe an unconfirmed subscription interface or treat the desktop session as CLI remaining quota. |

For MiMo, a profile passed to this reader must select the native **data directory** containing
`auth.json`: `$MIMOCODE_HOME/data` when `MIMOCODE_HOME` is set, otherwise the XDG data location
(normally `~/.local/share/mimocode`). `MIMO_HOME` and `~/.mimo` are not MiMo Code's source-backed data
roots.

## Profile launch/isolation contract

This is the static-source answer requested in `inbox-additional-providers.md`. A login/terminal action
must pass only the selected profile's provider-native variable. It must not rewrite `HOME` or a shared
default account.

| Provider | Supported native isolation | Path relationship for this reader | Launch guidance |
|---|---|---|---|
| Gemini CLI | `GEMINI_CLI_HOME=<profile-root>` is documented by the installed primary documentation as the root for all user-level configuration and storage; Gemini creates `<profile-root>/.gemini`. | `LocalCLIProfile.configDirectory` must be `<profile-root>/.gemini`. | Safe to offer an explicit launch/login action with `GEMINI_CLI_HOME` set to that profile root. Do not set `HOME`. |
| MiMo Code | `MIMOCODE_HOME=<profile-root>` must be absolute and resolves all four roots to `<profile-root>/{data,config,cache,state}`. | `configDirectory` must be `<profile-root>/data`, where `auth.json` lives. | Safe to offer an explicit launch/login action with `MIMOCODE_HOME`. `MIMOCODE_CONFIG_DIR` only adds a config search directory and is not an account-state boundary. Do not use `MIMO_HOME`. |
| ZCode | `ZCODE_DATA_BASE_DIR=<profile-root>` isolates the encrypted login store at `<profile-root>/.zcode/v2/credentials.json`. Separately, `ZCODE_STORAGE_DIR=<storage-root>` redirects runtime storage such as sessions, execution output, plugins, and caches. | No ZCode credential is read by this adapter. | **Not proven fully isolated.** The user config default is independently hard-coded as `~/.zcode/cli/config.json`; the bundled public CLI parser did not establish a supported user-config flag or a single variable that moves auth, config, and storage together. Do not offer profile login/launch as fully isolated until ZCode documents such an entry point. Setting only `ZCODE_DATA_BASE_DIR` is insufficient. `ZCODE_HOME` is used for telemetry state in this bundle and is not a full home override. |
| WorkBuddy | No source-backed quota or billing variable is confirmed for this adapter. Launch/login remains a separate surface. | `configDirectory` is unused: this adapter does not read the selected profile, the default `~/.workbuddy` tree, or any linked directory. | Do not rewrite `HOME`. Do not mix the default and linked directories. Quota stays `unsupported` even if a CLI binary is present. |
| TRAE | Independent CLI isolation is not confirmed. TRAE SOLO personal is a desktop entry. | `configDirectory` is unused: this adapter does not read `~/.trae-cn`, a linked directory, or desktop session files. | Do not rewrite `HOME`. Linked environments are not a quota source. Do not treat the desktop app path as a credential or billing root. |

Gemini's installed `docs/reference/configuration.md`, section `GEMINI_CLI_HOME`, and
`docs/cli/enterprise.md`, section “User isolation in shared environments”, are the primary isolation
sources. MiMo's path service `L2` and environment accessor define the `MIMOCODE_HOME` behavior. ZCode's
`resolveSharedZCodeCredentialsPath`, `getDefaultConfigPath`, and `ZCODE_STORAGE_DIR` consumers establish
the split-state limitation.

## Exact source anchors

### Gemini

- Installed Gemini CLI bundle 0.56.0:
  - `OAUTH_FILE = "oauth_creds.json"` in the OAuth credential storage module.
  - `CodeAssistServer.retrieveUserQuota(req)` and the quota display reducer over `modelId`,
    `remainingFraction`, and `resetTime`.
  - settings schema and runtime reads of `security.auth.selectedType`.
- Fixed research copy of CodexBar at commit
  `7fdc17636f161ab410d8a6a0e8f45b6a595cf8d2`:
  - `GeminiStatusProbe.fetchViaAPI`
  - `GeminiStatusProbe.loadCodeAssistStatus`
  - `GeminiStatusProbe.parseAPIResponse`
  - `GeminiStatusProbe.loadCredentials`
  - `docs/gemini.md`, sections “OAuth credentials”, “API endpoints”, and “Parsing + mapping”.
- Fixed requests:
  - `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
  - `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`

### MiMo

- Installed MiMo Code 0.1.9 bundled module `plugin.mimo`:
  - `MIMO_PLATFORM_URL` defaults to `https://platform.xiaomimimo.com`.
  - Browser authorization returns `sk`, `uid`, and optional `url`; the auth callback stores `sk` as
    the provider key and `{ uid, base_url }` as metadata.
  - The provider loader uses only `metadata.base_url` for Xiaomi inference and adds
    `X-Mimo-Source: mimocode-cli` to chat requests.
  - the path service resolves an absolute `MIMOCODE_HOME` to `{data, cache, config, state}` and otherwise
    uses XDG roots.
  - `auth whoami` reads provider `xiaomi` and prints `metadata.uid`; it does not fetch quota.
- `RESEARCH-PROVIDERS/mimo-auth-help.txt`, which documents `list`, `login`, `logout`, and `whoami`.
- Fixed CodexBar research copy:
  - `MiMoUsageFetcher.fetchUsage` and `fetchAuthenticated`, which use browser `Cookie` headers for
    platform `balance`, `tokenPlan/detail`, and `tokenPlan/usage`.
  - `docs/mimo.md`, sections “How it works” and “Limitations”.

No source connects MiMo Code's native `sk` to those cookie-authenticated account/billing calls. This is
why the reader returns an account identity plus an explicit unsupported quota state.

### ZCode

- `/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs` from ZCode 3.11.2:
  - `buildZCodeEndpointUrls` defines the two fixed production origins and the `zcode-plan` billing URLs.
  - `resolveSharedZCodeCredentialsPath` resolves the encrypted `credentials.json` location.
  - `createSharedZCodeCredentialStore` decrypts values through an internal encryptor and can mutate the
    store; its `saveZaiLoginCredentials` keys are `oauth:active_provider`, `oauth:zai:access_token`,
    `oauth:zai:user_info`, and `zcodejwttoken`.

The URL-builder constants alone do not establish a supported status request. The adapter therefore does
not read the encrypted store or call either endpoint. Native encrypted authentication must not be read,
decrypted, or copied, and this adapter does not add a private billing call.

### WorkBuddy

- Official bundled CLI 2.137.1 (`codebuddy`) with `deepseek-v4.1-flash` completed a minimal return and
  code-review path. That is not an official quota payload.
- This adapter therefore returns `unsupported` / no windows and does not open files or send requests.

### TRAE

- TRAE SOLO personal is currently a desktop entry. An independent CLI and a confirmable quota interface
  were not established.
- This adapter therefore returns `unsupported` / no windows and does not open files or send requests.

## Validation and security properties

- The caller uses only two exact Gemini HTTPS host/path pairs. Redirect, cookie/cache, timeout, and
  receive-size behavior remains A's shared transport contract; the adapter rechecks the 1 MiB bound.
- Credential files are bounded to 1 MiB and confined to the explicitly selected profile directory.
- Boolean, string, non-finite, negative, out-of-range, missing, malformed, expired-reset, and empty quota
  values fail as unknown; they never become `0%` or `100%`.
- API failures do not produce zero quota. HTTP 401/403 requires login, 429 is rate-limited, and other
  failures are unavailable. Exhausted Gemini remaining (`remainingFraction == 0`) stays `available` at
  100% used and is not relabeled unknown or login-required.
- WorkBuddy and TRAE are `unsupported` with the existing `local_cli_unsupported` message code. They are
  not `needsLogin` and they do not read transport or credentials.
- Fingerprints are derived from normalized account identity plus provider namespace. Access tokens,
  refresh tokens, and API keys are never identity inputs. WorkBuddy/TRAE emit no identity.

## Adaptation and license

The Gemini implementation is an original, reduced source-protocol adaptation informed by CodexBar's
Gemini provider; it does not copy its logging, refresh, process-discovery, or UI code. The fixed reference
is MIT-licensed: **Copyright (c) 2026 Peter Steinberger**. Its full license is preserved in
[third-party CLI notices](third-party-cli-notices.md). The same fixed source was used only as negative evidence
for MiMo CLI compatibility; no CodexBar MiMo code was copied.
