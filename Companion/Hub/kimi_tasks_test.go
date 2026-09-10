package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCodexMessageLimitUsesUTF8Bytes(t *testing.T) {
	board := &CodexBoard{}
	if _, err := board.sendMessage(context.Background(), "unused", "message-limit-0001", strings.Repeat("界", maxCodexMessageBytes/3+1), nil); err != errInvalid {
		t.Fatalf("multibyte message above 32 KiB did not fail validation: %v", err)
	}
}

func TestEmbeddedWebUsesUTF8LimitsAndReadOnlyKimiSection(t *testing.T) {
	html := string(indexHTML)
	for _, required := range []string{
		`const messageByteLimit = 32 * 1024`,
		`const promptByteLimit = 64 * 1024`,
		`const requestBodyByteLimit = 72 * 1024`,
		`function renderByteLimit(`,
		`<details id="desktop-panel">`,
		`<details id="kimi-panel">`,
		`await request("/api/kimi/tasks")`,
		`只读展示本机 Kimi 自动化`,
	} {
		if !strings.Contains(html, required) {
			t.Fatalf("embedded web is missing %q", required)
		}
	}
	if strings.Contains(html, `maxlength="64000"`) {
		t.Fatal("embedded web still uses a character maxlength for byte-limited inputs")
	}
}

func TestReadKimiTasksRedactsPrivateFieldsAndUsesFilesystemEvidence(t *testing.T) {
	root := t.TempDir()
	first := filepath.Join(root, "automation_first")
	second := filepath.Join(root, "automation_second")
	broken := filepath.Join(root, "automation_broken")
	for _, dir := range []string{first, second, broken} {
		if err := os.MkdirAll(filepath.Join(dir, "runs"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	firstJSON := `{"version":1,"automation":{"automationId":"account_id=secret-value","title":"Daily alice@example.com account_id=private-account","enabled":true,"description":"private prompt","prompt":"must not leak","trigger":{"kind":"cron","cron":"0 9 * * *","timezone":"Asia/Shanghai"},"execution":{"kind":"agent","mode":"normal"}}}`
	secondJSON := `{"version":1,"automation":{"automationId":"ignored","title":"Backup","enabled":false,"trigger":{"kind":"cron","cron":"30 1 * * *","timezone":"UTC"},"execution":{"kind":"workflow","mode":"normal"}}}`
	if err := os.WriteFile(filepath.Join(first, "automation.json"), []byte(firstJSON), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(second, "automation.json"), []byte(secondJSON), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(broken, "automation.json"), []byte(`{"automation":`), 0o600); err != nil {
		t.Fatal(err)
	}
	oldID := "run_11111111-1111-4111-8111-111111111111"
	newID := "run_22222222-2222-4222-8222-222222222222"
	older := filepath.Join(first, "runs", oldID)
	newer := filepath.Join(first, "runs", newID)
	if err := os.Mkdir(older, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(newer, 0o700); err != nil {
		t.Fatal(err)
	}
	oldTime := time.Date(2026, 8, 31, 3, 0, 0, 0, time.FixedZone("local-test", 8*60*60))
	newTime := oldTime.Add(time.Hour)
	oldRun := `{"run":{"runId":"` + oldID + `","startedAt":"2026-08-30T18:00:00Z","completedAt":"2026-08-30T18:05:00Z"},"logs":[{"message":"private"}]}`
	newRun := `{"run":{"runId":"` + newID + `","startedAt":"2026-08-30T19:00:00Z","completedAt":"2026-08-30T19:05:00Z"},"artifact":{"account_id":"must-not-leak"}}`
	if err := os.WriteFile(filepath.Join(older, "run.json"), []byte(oldRun), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(newer, "run.json"), []byte(newRun), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(older, oldTime, oldTime); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(newer, newTime, newTime); err != nil {
		t.Fatal(err)
	}

	overview := readKimiTasks(root)
	if len(overview.Tasks) != 2 || overview.Notice == "" {
		t.Fatalf("expected two valid tasks plus partial notice: %#v", overview)
	}
	backup, daily := overview.Tasks[0], overview.Tasks[1]
	if backup.Title != "Backup" || backup.Enabled || backup.RunCount == nil || *backup.RunCount != 0 {
		t.Fatalf("empty valid runs directory was not represented accurately: %#v", backup)
	}
	if daily.Title != "Daily [账号已隐藏] [账号标识已隐藏]" || !daily.Enabled || daily.Trigger.Cron != "0 9 * * *" || daily.Trigger.Timezone != "Asia/Shanghai" || daily.ExecutionKind != "agent" {
		t.Fatalf("automation fields mismatch: %#v", daily)
	}
	wantStarted := time.Date(2026, 8, 30, 19, 0, 0, 0, time.UTC)
	if daily.RunCount == nil || *daily.RunCount != 2 || daily.LatestRunID != newID || daily.LatestRunStartedAt == nil || !daily.LatestRunStartedAt.Equal(wantStarted) || daily.LatestRunStartedAt.Location() != time.UTC || daily.LatestRecordModifiedAt != nil {
		t.Fatalf("run evidence mismatch: %#v", daily)
	}
	encoded, err := json.Marshal(overview)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"alice@example.com", "account_id", "automationId", "secret-value", "private-account", "private prompt", "must not leak", root} {
		if strings.Contains(string(encoded), forbidden) {
			t.Fatalf("Kimi response leaked %q: %s", forbidden, encoded)
		}
	}
}

func TestReadKimiTasksDoesNotInventRunCount(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "automation_one")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	contents := `{"automation":{"title":"One","enabled":true,"trigger":{"kind":"cron"},"execution":{"kind":"agent"}}}`
	if err := os.WriteFile(filepath.Join(dir, "automation.json"), []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "runs"), []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	overview := readKimiTasks(root)
	if len(overview.Tasks) != 1 || overview.Tasks[0].RunCount != nil || overview.Notice == "" {
		t.Fatalf("unavailable runs metadata was represented as a real count: %#v", overview)
	}
}

func TestReadKimiTasksFallsBackToRunDirectoryTime(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "automation_one")
	runs := filepath.Join(dir, "runs")
	if err := os.MkdirAll(runs, 0o700); err != nil {
		t.Fatal(err)
	}
	contents := `{"automation":{"title":"One","enabled":true,"trigger":{"kind":"manual"},"execution":{"kind":"agent"}}}`
	if err := os.WriteFile(filepath.Join(dir, "automation.json"), []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	runID := "run_33333333-3333-4333-8333-333333333333"
	runDir := filepath.Join(runs, runID)
	if err := os.Mkdir(runDir, 0o700); err != nil {
		t.Fatal(err)
	}
	modifiedAt := time.Date(2026, 8, 31, 18, 13, 4, 0, time.UTC)
	if err := os.Chtimes(runDir, modifiedAt, modifiedAt); err != nil {
		t.Fatal(err)
	}
	overview := readKimiTasks(root)
	if len(overview.Tasks) != 1 || overview.Tasks[0].RunCount == nil || *overview.Tasks[0].RunCount != 1 || overview.Tasks[0].LatestRunStartedAt != nil || overview.Tasks[0].LatestRecordID != runID || overview.Tasks[0].LatestRecordModifiedAt == nil || !overview.Tasks[0].LatestRecordModifiedAt.Equal(modifiedAt) || overview.Notice == "" {
		t.Fatalf("missing run.json did not use an explicit filesystem fallback: %#v", overview)
	}
}

func TestKimiTasksAPIDisabledAndMissingReturnNoticeNotError(t *testing.T) {
	for _, dir := range []string{"", filepath.Join(t.TempDir(), "missing")} {
		hub := &Hub{config: Config{KimiAutomationsDir: dir}}
		handler := (&API{hub: hub, requireToken: false, requireTokenSet: true}).routes()
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/kimi/tasks", nil))
		if response.Code != http.StatusOK {
			t.Fatalf("Kimi unavailable response returned %d: %s", response.Code, response.Body.String())
		}
		var overview kimiTasksOverview
		if err := json.Unmarshal(response.Body.Bytes(), &overview); err != nil {
			t.Fatal(err)
		}
		if overview.Tasks == nil || len(overview.Tasks) != 0 || overview.Notice == "" {
			t.Fatalf("Kimi unavailable response was ambiguous: %#v", overview)
		}
	}
}

func TestLoadConfigAcceptsOptionalAbsoluteKimiDirectory(t *testing.T) {
	root := t.TempDir()
	project := filepath.Join(root, "project")
	kimi := filepath.Join(root, "kimi-automations")
	if err := os.Mkdir(project, 0o700); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(root, "config.json")
	contents := `{"listen":"127.0.0.1:8787","dataDir":"./data","requireToken":false,"kimiAutomationsDir":` + quotedJSON(t, kimi) + `,"approvalTTLSeconds":300,"mode":"read-only","claudeMaxBudgetUSD":0.25,"commands":{"codex":"codex","claude":"claude"},"projects":{"demo":` + quotedJSON(t, project) + `}}`
	if err := os.WriteFile(configPath, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	config, err := loadConfig(configPath)
	if err != nil || config.KimiAutomationsDir != kimi {
		t.Fatalf("optional Kimi config field was rejected: %#v %v", config, err)
	}
}

func quotedJSON(t *testing.T, value string) string {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}
