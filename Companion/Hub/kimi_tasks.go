package main

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode"
)

const maxKimiAutomationJSONBytes = 256 * 1024
const maxKimiRunJSONBytes = 8 * 1024 * 1024

type kimiTasksOverview struct {
	Tasks  []kimiTaskOverview `json:"tasks"`
	Notice string             `json:"notice,omitempty"`
}

type kimiTaskOverview struct {
	Title                  string          `json:"title"`
	Enabled                bool            `json:"enabled"`
	Trigger                kimiTaskTrigger `json:"trigger"`
	ExecutionKind          string          `json:"executionKind,omitempty"`
	RunCount               *int            `json:"runCount,omitempty"`
	LatestRunID            string          `json:"latestRunId,omitempty"`
	LatestRunStartedAt     *time.Time      `json:"latestRunStartedAt,omitempty"`
	LatestRunCompletedAt   *time.Time      `json:"latestRunCompletedAt,omitempty"`
	LatestRecordID         string          `json:"latestRecordId,omitempty"`
	LatestRecordModifiedAt *time.Time      `json:"latestRecordModifiedAt,omitempty"`
	RunsDirectoryUpdatedAt *time.Time      `json:"runsDirectoryUpdatedAt,omitempty"`
}

type kimiTaskTrigger struct {
	Kind     string `json:"kind,omitempty"`
	Cron     string `json:"cron,omitempty"`
	Timezone string `json:"timezone,omitempty"`
}

type kimiAutomationFile struct {
	Automation struct {
		Title   string `json:"title"`
		Enabled *bool  `json:"enabled"`
		Trigger struct {
			Kind     string `json:"kind"`
			Cron     string `json:"cron"`
			Timezone string `json:"timezone"`
		} `json:"trigger"`
		Execution struct {
			Kind string `json:"kind"`
		} `json:"execution"`
	} `json:"automation"`
}

type kimiRunFile struct {
	Run struct {
		RunID       string `json:"runId"`
		StartedAt   string `json:"startedAt"`
		CompletedAt string `json:"completedAt"`
	} `json:"run"`
}

var (
	kimiEmailPattern     = regexp.MustCompile(`(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b`)
	kimiAccountIDPattern = regexp.MustCompile(`(?i)\baccount[_-]?id\b(?:\s*[:=]\s*|\s+)?[A-Za-z0-9._\-]*`)
	kimiRunDirPattern    = regexp.MustCompile(`^run_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)
)

func readKimiTasks(root string) kimiTasksOverview {
	result := kimiTasksOverview{Tasks: make([]kimiTaskOverview, 0)}
	if strings.TrimSpace(root) == "" {
		result.Notice = "Kimi 自动化目录未配置；此功能已关闭。"
		return result
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		result.Notice = "Kimi 自动化目录不可读取；暂未返回任务。"
		return result
	}
	partial := false
	for _, entry := range entries {
		if !entry.IsDir() || !strings.HasPrefix(entry.Name(), "automation_") {
			continue
		}
		task, ok, incomplete := readKimiAutomation(filepath.Join(root, entry.Name()))
		partial = partial || incomplete
		if ok {
			result.Tasks = append(result.Tasks, task)
		}
	}
	sort.Slice(result.Tasks, func(i, j int) bool {
		return strings.ToLower(result.Tasks[i].Title) < strings.ToLower(result.Tasks[j].Title)
	})
	if partial {
		result.Notice = "部分 Kimi 自动化或运行记录不可读取；已省略不可靠字段。"
	}
	return result
}

func readKimiAutomation(dir string) (kimiTaskOverview, bool, bool) {
	file, err := os.Open(filepath.Join(dir, "automation.json"))
	if err != nil {
		return kimiTaskOverview{}, false, true
	}
	defer file.Close()
	limited := &io.LimitedReader{R: file, N: maxKimiAutomationJSONBytes + 1}
	decoder := json.NewDecoder(limited)
	var source kimiAutomationFile
	if err := decoder.Decode(&source); err != nil || limited.N == 0 || requireEOF(decoder) != nil {
		return kimiTaskOverview{}, false, true
	}
	if source.Automation.Enabled == nil || strings.TrimSpace(source.Automation.Title) == "" {
		return kimiTaskOverview{}, false, true
	}
	task := kimiTaskOverview{
		Title:   cleanKimiText(source.Automation.Title, 240),
		Enabled: *source.Automation.Enabled,
		Trigger: kimiTaskTrigger{
			Kind:     cleanKimiText(source.Automation.Trigger.Kind, 80),
			Cron:     cleanKimiText(source.Automation.Trigger.Cron, 160),
			Timezone: cleanKimiText(source.Automation.Trigger.Timezone, 100),
		},
		ExecutionKind: cleanKimiText(source.Automation.Execution.Kind, 80),
	}
	if task.Title == "" {
		return kimiTaskOverview{}, false, true
	}
	incomplete := readKimiRuns(filepath.Join(dir, "runs"), &task)
	return task, true, incomplete
}

func readKimiRuns(runsDir string, task *kimiTaskOverview) bool {
	directoryInfo, directoryErr := os.Stat(runsDir)
	if directoryErr != nil || !directoryInfo.IsDir() {
		return true
	}
	directoryUpdatedAt := directoryInfo.ModTime().UTC()
	task.RunsDirectoryUpdatedAt = &directoryUpdatedAt
	entries, err := os.ReadDir(runsDir)
	if err != nil {
		return true
	}
	runEntries := make([]os.DirEntry, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() && kimiRunDirPattern.MatchString(entry.Name()) {
			runEntries = append(runEntries, entry)
		}
	}
	count := len(runEntries)
	task.RunCount = &count
	if count == 0 {
		return false
	}
	var latestInfo os.FileInfo
	latestName := ""
	metadataComplete := true
	var latestStarted time.Time
	var latestCompleted *time.Time
	latestRunID := ""
	for _, entry := range runEntries {
		info, err := entry.Info()
		if err != nil {
			metadataComplete = false
			continue
		}
		if latestInfo == nil || info.ModTime().After(latestInfo.ModTime()) || info.ModTime().Equal(latestInfo.ModTime()) && entry.Name() > latestName {
			latestInfo = info
			latestName = entry.Name()
		}
		runID, startedAt, completedAt, ok := readKimiRun(filepath.Join(runsDir, entry.Name(), "run.json"), entry.Name())
		if !ok {
			metadataComplete = false
			continue
		}
		if latestRunID == "" || startedAt.After(latestStarted) || startedAt.Equal(latestStarted) && runID > latestRunID {
			latestRunID = runID
			latestStarted = startedAt
			latestCompleted = completedAt
		}
	}
	if metadataComplete && latestRunID != "" {
		task.LatestRunID = cleanKimiText(latestRunID, 160)
		task.LatestRunStartedAt = &latestStarted
		task.LatestRunCompletedAt = latestCompleted
		return task.LatestRunID == ""
	}
	if latestInfo != nil {
		modifiedAt := latestInfo.ModTime().UTC()
		task.LatestRecordID = cleanKimiText(latestName, 160)
		task.LatestRecordModifiedAt = &modifiedAt
	}
	return true
}

func readKimiRun(path, expectedID string) (string, time.Time, *time.Time, bool) {
	file, err := os.Open(path)
	if err != nil {
		return "", time.Time{}, nil, false
	}
	defer file.Close()
	limited := &io.LimitedReader{R: file, N: maxKimiRunJSONBytes + 1}
	decoder := json.NewDecoder(limited)
	var source kimiRunFile
	if err := decoder.Decode(&source); err != nil || limited.N == 0 || requireEOF(decoder) != nil || source.Run.RunID != expectedID {
		return "", time.Time{}, nil, false
	}
	startedAt, err := time.Parse(time.RFC3339Nano, source.Run.StartedAt)
	if err != nil {
		return "", time.Time{}, nil, false
	}
	startedAt = startedAt.UTC()
	var completedAt *time.Time
	if source.Run.CompletedAt != "" {
		value, err := time.Parse(time.RFC3339Nano, source.Run.CompletedAt)
		if err != nil {
			return "", time.Time{}, nil, false
		}
		value = value.UTC()
		completedAt = &value
	}
	return source.Run.RunID, startedAt, completedAt, true
}

func cleanKimiText(value string, limit int) string {
	value = strings.TrimSpace(value)
	value = maskOutput(value)
	value = kimiEmailPattern.ReplaceAllString(value, "[账号已隐藏]")
	value = kimiAccountIDPattern.ReplaceAllString(value, "[账号标识已隐藏]")
	value = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, value)
	value = strings.Join(strings.Fields(value), " ")
	if limit <= 0 {
		return ""
	}
	runes := []rune(value)
	if len(runes) > limit {
		value = string(runes[:limit]) + "…"
	}
	return value
}
