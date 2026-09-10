package main

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"
)

func TestDispatchWindowRecheckedAtCreateAndApproval(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	account := testAccountConfig(t, t.TempDir(), "fixture-account")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeApprovalQuotaSnapshot(t, account, time.Now().UTC(), 10, 20)
	setWindow := func(mode string) {
		data, err := os.ReadFile(hub.managerSnapshotPath)
		if err != nil {
			t.Fatal(err)
		}
		var snapshot managerSnapshotFile
		if err := json.Unmarshal(data, &snapshot); err != nil {
			t.Fatal(err)
		}
		snapshot.Profiles[0].DispatchParticipationWindow = &managerDispatchWindow{Mode: mode, TimeZoneIdentifier: "UTC", Intervals: []managerDispatchInterval{}}
		data, err = json.Marshal(snapshot)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(hub.managerSnapshotPath, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	setWindow("onlyWithin")
	request := CreateRequest{RequestID: "window-create-001", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "fixture"}
	if _, err := hub.create(request); err == nil {
		t.Fatal("closed window admitted create")
	}
	setWindow("unrestricted")
	task, err := hub.create(request)
	if err != nil {
		t.Fatal(err)
	}
	setWindow("onlyWithin")
	if _, err := hub.approve(task.ID, ApproveRequest{RequestID: "window-approve-001", ActionHash: task.ActionHash}); err == nil {
		t.Fatal("closed window admitted approval")
	}
	if hub.tasks[task.ID].State != stateAwaitingApproval {
		t.Fatal("blocked approval changed task state")
	}
}

func TestDispatchWindowAdmissionBoundaries(t *testing.T) {
	var policy managerDispatchWindow
	if err := json.Unmarshal([]byte(`{"mode":"onlyWithin","timeZoneIdentifier":"Asia/Shanghai","intervals":[{"startMinute":1380,"endMinute":60,"allDays":false,"weekdays":[1],"allDay":false}]}`), &policy); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		at   string
		want bool
	}{
		{"2026-09-07T15:00:00Z", true}, {"2026-09-07T16:59:59Z", true},
		{"2026-09-07T17:00:00Z", false}, {"2026-09-06T16:30:00Z", false},
	}
	for _, c := range cases {
		now, _ := time.Parse(time.RFC3339, c.at)
		if got := policy.allows(now); got != c.want {
			t.Errorf("at %s: got %v want %v", c.at, got, c.want)
		}
	}
	policy.Mode = "exceptWithin"
	at, _ := time.Parse(time.RFC3339, "2026-09-07T15:00:00Z")
	if policy.allows(at) {
		t.Fatal("excluded interval admitted")
	}
	policy.TimeZoneIdentifier = "Invalid/Zone"
	if policy.allows(at) {
		t.Fatal("invalid zone admitted")
	}
	if !((*managerDispatchWindow)(nil)).allows(at) {
		t.Fatal("legacy profile should remain unrestricted")
	}
	policy = managerDispatchWindow{Mode: "onlyWithin", TimeZoneIdentifier: "UTC", Intervals: []managerDispatchInterval{}}
	if policy.allows(at) {
		t.Fatal("empty positive schedule admitted")
	}
	policy.Mode = "unrestricted"
	if !policy.allows(at) {
		t.Fatal("valid unrestricted policy blocked")
	}
	if err := json.Unmarshal([]byte(`{"mode":"onlyWithin","timeZoneIdentifier":"America/New_York","intervals":[{"startMinute":90,"endMinute":120,"allDays":true,"weekdays":[],"allDay":false}]}`), &policy); err != nil {
		t.Fatal(err)
	}
	for _, raw := range []string{"2026-11-01T05:45:00Z", "2026-11-01T06:45:00Z"} {
		now, _ := time.Parse(time.RFC3339, raw)
		if !policy.allows(now) {
			t.Fatal("DST repeated hour should match")
		}
	}
}

func TestDispatchWindowRejectsMissingIntervalFields(t *testing.T) {
	now, _ := time.Parse(time.RFC3339, "2026-09-08T09:30:00Z")
	for _, raw := range []string{
		`{"startMinute":540,"endMinute":600,"weekdays":[1],"allDay":false}`,
		`{"startMinute":540,"endMinute":600,"allDays":null,"weekdays":[1],"allDay":false}`,
		`{"startMinute":540,"endMinute":600,"allDays":true,"weekdays":[],"allDay":null}`,
	} {
		var interval managerDispatchInterval
		if err := json.Unmarshal([]byte(raw), &interval); err != nil {
			t.Fatal(err)
		}
		policy := managerDispatchWindow{Mode: "onlyWithin", TimeZoneIdentifier: "UTC", Intervals: []managerDispatchInterval{interval}}
		if policy.allows(now) {
			t.Fatal("malformed rule widened admission")
		}
	}
}
