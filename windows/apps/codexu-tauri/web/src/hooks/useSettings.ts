import { useCallback, useEffect, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import type { AppConfig, SettingsDto, SettingsResponse } from '../types/settings';
import {
  isTauriRuntimeAvailable,
  requireTauriRuntime,
} from '../utils/tauri';

export function useSettings() {
  const [settings, setSettings] = useState<SettingsDto | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const normalizeSettings = (payload: SettingsResponse): SettingsDto => ({
    config: {
      // The backend deliberately returns only presence flags for local paths.
      // Keep display values non-sensitive; path selections are write-only
      // patches from the directory picker.
      codex_root: payload.codex_root_configured ? 'configured' : '',
      cache_dir: payload.cache_dir_configured ? 'configured' : '',
      theme: payload.theme,
      refresh_interval_secs: payload.refresh_interval_secs,
      tray_density: payload.tray_density,
      language: payload.language ?? 'auto',
      palette_id: payload.palette_id ?? 'codexu.default',
    },
  });

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      requireTauriRuntime();
      const dto = await invoke<SettingsResponse>('get_settings');
      setSettings(normalizeSettings(dto));
    } catch (e) {
      setError(String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  const update = useCallback(async (patch: Partial<AppConfig>): Promise<AppConfig> => {
    setError(null);
    try {
      requireTauriRuntime();
      const updated = await invoke<SettingsResponse>('set_settings', { req: patch });
      const normalized = normalizeSettings(updated);
      setSettings(normalized);
      return normalized.config;
    } catch (e) {
      setError(String(e));
      throw e;
    }
  }, []);

  useEffect(() => {
    load();

    if (!isTauriRuntimeAvailable()) {
      return;
    }

    let unlisten: (() => void) | null = null;
    let cancelled = false;

    const subscribe = async () => {
      try {
        const unlistenFn = await listen('settings:changed', () => {
          load();
        });
        if (cancelled) {
          unlistenFn();
        } else {
          unlisten = unlistenFn;
        }
      } catch (e) {
        setError(String(e));
      }
    };
    subscribe();

    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [load]);

  return { settings, loading, update, reload: load, error };
}
