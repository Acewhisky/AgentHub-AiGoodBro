import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const read = (relativePath) => readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8');

test('settings IPC exposes path presence only and the UI does not render absolute paths', () => {
  const rust = read('../src-tauri/src/commands/settings.rs');
  const settings = read('src/windows/Settings.tsx');
  const types = read('src/types/settings.ts');

  assert.match(rust, /codex_root_configured/u);
  assert.match(rust, /cache_dir_configured/u);
  assert.doesNotMatch(
    rust,
    /pub struct SettingsDto \{[\s\S]*?pub app_data_dir:/u,
    'SettingsDto must not cross the app data directory path into the WebView',
  );
  assert.doesNotMatch(settings, /settings\.app_data_dir/u);
  assert.doesNotMatch(settings, /value=\{config\.codex_root\}/u);
  assert.doesNotMatch(settings, /value=\{config\.cache_dir\}/u);
  assert.match(settings, /configuredLocalFolder/u);
  assert.match(types, /codex_root_configured: boolean/u);
  assert.match(types, /cache_dir_configured: boolean/u);
});
