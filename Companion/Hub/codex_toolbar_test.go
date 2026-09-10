package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type sizedAttachmentReader struct {
	prefix    []byte
	remaining int64
	fill      byte
}

func (reader *sizedAttachmentReader) Read(buffer []byte) (int, error) {
	if len(reader.prefix) > 0 {
		count := copy(buffer, reader.prefix)
		reader.prefix = reader.prefix[count:]
		reader.remaining -= int64(count)
		return count, nil
	}
	if reader.remaining <= 0 {
		return 0, io.EOF
	}
	count := min(len(buffer), int(reader.remaining))
	for index := 0; index < count; index++ {
		buffer[index] = reader.fill
	}
	reader.remaining -= int64(count)
	return count, nil
}

func newAttachmentTestBoard(t *testing.T, mode string) (*CodexBoard, Config, string) {
	t.Helper()
	config := testConfig(t, "/usr/bin/true")
	config.Mode = mode
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	board, err := newCodexBoard(config, hub)
	if err != nil {
		t.Fatal(err)
	}
	threadID := "11111111-1111-4111-8111-111111111111"
	name := "附件测试"
	if err := board.replaceAppThreads([]appThreadWire{{
		ID: threadID, Name: &name, Cwd: config.Projects["demo"], Source: json.RawMessage(`"appServer"`),
		Status: appThreadStatus{Type: "idle"}, CreatedAt: time.Now().Unix(), UpdatedAt: time.Now().Unix(),
	}}, map[string]bool{threadID: true}, observerSharedLive, time.Now()); err != nil {
		t.Fatal(err)
	}
	return board, config, observedByTitle(t, board.overview().Threads, name).PublicRef
}

func TestCodexAttachmentTypeAndSizeValidation(t *testing.T) {
	board, config, publicRef := newAttachmentTestBoard(t, "workspace-write")
	pngHeader := []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}

	uploaded, err := board.storeAttachment(publicRef, "../../截图.png", "image/png", bytes.NewReader(pngHeader))
	if err != nil {
		t.Fatal(err)
	}
	if uploaded.Name != "截图.png" || !uploaded.IsImage || uploaded.Size != int64(len(pngHeader)) {
		t.Fatalf("unexpected sanitized upload: %#v", uploaded)
	}
	resolved, err := board.resolveAttachments(publicRef, []string{uploaded.ID})
	if err != nil || len(resolved) != 1 || !pathContains(config.DataDir, resolved[0].Path) {
		t.Fatalf("attachment escaped controlled storage: %#v %v", resolved, err)
	}

	if _, err := board.storeAttachment(publicRef, "fake.png", "image/png", strings.NewReader("not an image")); !errors.Is(err, errAttachmentType) {
		t.Fatalf("spoofed image content was accepted: %v", err)
	}
	if _, err := board.storeAttachment(publicRef, "script.sh", "text/plain", strings.NewReader("echo unsafe")); !errors.Is(err, errAttachmentType) {
		t.Fatalf("non-whitelisted extension was accepted: %v", err)
	}
	tooLargeImage := &sizedAttachmentReader{
		prefix: append([]byte(nil), pngHeader...), remaining: maxCodexImageAttachmentBytes + 1, fill: 0,
	}
	if _, err := board.storeAttachment(publicRef, "large.png", "image/png", tooLargeImage); !errors.Is(err, errAttachmentTooLarge) {
		t.Fatalf("oversized image was accepted: %v", err)
	}
	tooLargeText := &sizedAttachmentReader{remaining: maxCodexAttachmentBytes + 1, fill: 'a'}
	if _, err := board.storeAttachment(publicRef, "large.txt", "text/plain", tooLargeText); !errors.Is(err, errAttachmentTooLarge) {
		t.Fatalf("oversized file was accepted: %v", err)
	}
}

func TestCodexAttachmentEndpointHasIndependentMultipartLimit(t *testing.T) {
	board, config, publicRef := newAttachmentTestBoard(t, "workspace-write")
	token := []byte("01234567890123456789012345678901")
	handler := (&API{hub: board.hub, board: board, token: token}).routes()

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("files", "notes.md")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(part, "# notes\n"); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/api/codex/threads/"+publicRef+"/attachments", &body)
	request.Header.Set("Authorization", "Bearer "+string(token))
	request.Header.Set("Content-Type", writer.FormDataContentType())
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusCreated || !strings.Contains(response.Body.String(), `"name":"notes.md"`) || !strings.Contains(response.Body.String(), `"size":8`) {
		t.Fatalf("valid multipart upload failed: %d %s", response.Code, response.Body.String())
	}
	if strings.Contains(response.Body.String(), config.DataDir) || strings.Contains(response.Body.String(), config.Projects["demo"]) {
		t.Fatalf("upload response leaked a private path: %s", response.Body.String())
	}

	oversized := httptest.NewRequest(http.MethodPost, "/api/codex/threads/"+publicRef+"/attachments", strings.NewReader("small"))
	oversized.ContentLength = maxAttachmentRequestBytes + 1
	oversized.Header.Set("Authorization", "Bearer "+string(token))
	oversizedResponse := httptest.NewRecorder()
	handler.ServeHTTP(oversizedResponse, oversized)
	if oversizedResponse.Code != http.StatusRequestEntityTooLarge || !strings.Contains(oversizedResponse.Body.String(), "attachment_request_too_large") {
		t.Fatalf("25 MiB request cap was not enforced independently: %d %s", oversizedResponse.Code, oversizedResponse.Body.String())
	}
}

func TestCodexSandboxMappingOnlyNarrowsHubMode(t *testing.T) {
	tests := []struct {
		cap, requested, want string
		wantErr              bool
	}{
		{cap: "workspace-write", requested: "", want: "workspace-write"},
		{cap: "workspace-write", requested: "workspace-write", want: "workspace-write"},
		{cap: "workspace-write", requested: "read-only", want: "read-only"},
		{cap: "workspace-write", requested: "danger-full-access", want: "workspace-write", wantErr: true},
		{cap: "read-only", requested: "workspace-write", want: "read-only", wantErr: true},
		{cap: "read-only", requested: "read-only", want: "read-only"},
	}
	for _, test := range tests {
		got, err := narrowCodexSandbox(test.cap, test.requested)
		if got != test.want || (err != nil) != test.wantErr {
			t.Fatalf("narrowCodexSandbox(%q, %q) = %q, %v", test.cap, test.requested, got, err)
		}
	}
	for _, option := range codexSandboxOptions("workspace-write") {
		if option.Value == "danger-full-access" {
			t.Fatal("danger-full-access appeared in a capped UI option")
		}
	}
	if policy := codexSandboxPolicy("workspace-write", "/safe/project"); policy["type"] != "workspaceWrite" {
		t.Fatalf("workspace policy mapping mismatch: %#v", policy)
	}
	if policy := codexSandboxPolicy("read-only", "/safe/project"); policy["type"] != "readOnly" {
		t.Fatalf("read-only policy mapping mismatch: %#v", policy)
	}
}

func TestCodexModelDefaultFollowsCLIConfiguration(t *testing.T) {
	models := []CodexModelDTO{{Model: "gpt-5.6-sol", DisplayName: "GPT-5.6 Sol"}}
	if got, err := normalizeCodexModel("", models); err != nil || got != "" {
		t.Fatalf("empty model did not preserve CLI default: %q %v", got, err)
	}
	if got, err := normalizeCodexModel("gpt-5.6-sol", models); err != nil || got != "gpt-5.6-sol" {
		t.Fatalf("catalog model was rejected: %q %v", got, err)
	}
	if _, err := normalizeCodexModel("arbitrary-model", models); !errors.Is(err, errInvalid) {
		t.Fatalf("non-catalog model was accepted: %v", err)
	}
}

func TestCodexMessageInputUsesNativeImagesAndLabelsFilePaths(t *testing.T) {
	input := codexMessageInput("请查看附件", []codexAttachment{
		{CodexAttachmentDTO: CodexAttachmentDTO{Name: "screen.png", IsImage: true}, Path: "/private/data/screen.png"},
		{CodexAttachmentDTO: CodexAttachmentDTO{Name: "notes.md"}, Path: "/private/data/notes.md"},
	})
	if len(input) != 2 || input[0]["type"] != "text" || input[1]["type"] != "localImage" || input[1]["path"] != "/private/data/screen.png" {
		t.Fatalf("native image input mapping mismatch: %#v", input)
	}
	text, _ := input[0]["text"].(string)
	if !strings.Contains(text, "[用户附件路径]") || !strings.Contains(text, "notes.md: /private/data/notes.md") || strings.Contains(text, "screen.png: /private/data/screen.png") {
		t.Fatalf("file fallback path annotation mismatch: %q", text)
	}
}
