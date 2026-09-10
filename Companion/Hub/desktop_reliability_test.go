package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func desktopRPCFixture(t *testing.T, board *CodexBoard, respond func(string, map[string]any) (any, error)) *appServerClient {
	t.Helper()
	server, connection := net.Pipe()
	client := &appServerClient{
		encoder: json.NewEncoder(connection), input: connection, pending: make(map[int64]chan appRPCResult), nextID: 2,
		done: make(chan struct{}), cancel: func() {}, board: board, mode: observerSharedLive,
	}
	go client.readLoop(connection)
	go func() {
		defer server.Close()
		decoder, encoder := json.NewDecoder(server), json.NewEncoder(server)
		for {
			var request struct {
				ID     int64          `json:"id"`
				Method string         `json:"method"`
				Params map[string]any `json:"params"`
			}
			if decoder.Decode(&request) != nil {
				return
			}
			result, err := respond(request.Method, request.Params)
			response := map[string]any{"id": request.ID, "result": result}
			if err != nil {
				delete(response, "result")
				response["error"] = map[string]any{"code": -32000, "message": "synthetic_rpc_failure"}
			}
			if encoder.Encode(response) != nil {
				return
			}
		}
	}()
	board.publishClient(client)
	t.Cleanup(func() { board.retireClient(client) })
	return client
}

func TestDesktopContentPagesWithinBudgetAndKeepsLatestText(t *testing.T) {
	board, _, _ := newAttachmentTestBoard(t, "read-only")
	threadID := "11111111-1111-4111-8111-111111111111"
	turnID := "22222222-2222-4222-8222-222222222222"
	var pageCalls atomic.Int32
	client := desktopRPCFixture(t, board, func(method string, params map[string]any) (any, error) {
		switch method {
		case "thread/turns/list":
			if params["itemsView"] != "summary" || params["limit"] != float64(8) {
				return nil, errors.New("unbounded turn detail requested")
			}
			return map[string]any{"nextCursor": "older-turns", "data": []any{map[string]any{
				"id": turnID, "status": "completed", "items": []any{},
			}}}, nil
		case "thread/items/list":
			pageCalls.Add(1)
			if params["threadId"] != threadID || params["turnId"] != turnID || params["limit"] != float64(16) || params["sortDirection"] != "desc" {
				return nil, errors.New("item page escaped bounds")
			}
			offset := 0
			if cursor, ok := params["cursor"].(string); ok {
				var err error
				offset, err = strconv.Atoi(cursor)
				if err != nil {
					return nil, err
				}
			}
			entries := make([]any, 0, 16)
			for index := 0; index < 16; index++ {
				// The full synthetic history exceeds the 4 MiB transport limit.
				text := fmt.Sprintf("item-%d %s", 1200-offset-index, strings.Repeat("x", 10_000))
				entries = append(entries, map[string]any{"turnId": turnID, "item": map[string]any{"type": "agentMessage", "text": text}})
			}
			return map[string]any{"data": entries, "nextCursor": strconv.Itoa(offset + 16)}, nil
		default:
			return nil, errors.New("unexpected method")
		}
	})
	content, err := client.threadContent(context.Background(), threadID, board.hub)
	if err != nil || !content.Truncated || !content.HasMore || pageCalls.Load() != 4 {
		t.Fatalf("content read escaped its page budget: pages=%d truncated=%t hasMore=%t error=%v", pageCalls.Load(), content.Truncated, content.HasMore, err)
	}
	visibleRunes := 0
	latest := false
	for _, turn := range content.Turns {
		for _, item := range turn.Items {
			visibleRunes += len([]rune(item.Text))
			latest = latest || strings.Contains(item.Text, "item-1200")
		}
	}
	if visibleRunes > 64*1024 || !latest {
		t.Fatalf("latest text was lost or output exceeded the display budget: runes=%d latest=%t", visibleRunes, latest)
	}
}

func TestDesktopContentFallsBackToSummaryOnInvalidItemPages(t *testing.T) {
	for _, failure := range []string{"rpc-error", "wrong-turn", "cursor-cycle", "empty-page-cursor"} {
		t.Run(failure, func(t *testing.T) {
			board, _, _ := newAttachmentTestBoard(t, "read-only")
			threadID := "11111111-1111-4111-8111-111111111111"
			turnID := "22222222-2222-4222-8222-222222222222"
			var pageCalls atomic.Int32
			client := desktopRPCFixture(t, board, func(method string, params map[string]any) (any, error) {
				if method == "thread/turns/list" {
					return map[string]any{"data": []any{map[string]any{"id": turnID, "status": "completed", "items": []any{
						map[string]any{"type": "agentMessage", "text": "safe-summary"},
					}}}}, nil
				}
				pageCalls.Add(1)
				if method != "thread/items/list" || failure == "rpc-error" {
					return nil, errors.New("synthetic item failure")
				}
				if failure == "empty-page-cursor" {
					return map[string]any{"data": []any{}, "nextCursor": "repeated"}, nil
				}
				entryTurn := turnID
				if failure == "wrong-turn" {
					entryTurn = "33333333-3333-4333-8333-333333333333"
				}
				return map[string]any{"data": []any{map[string]any{"turnId": entryTurn, "item": map[string]any{
					"type": "agentMessage", "text": "discard-this-item-page",
				}}}, "nextCursor": "repeated"}, nil
			})
			content, err := client.threadContent(context.Background(), threadID, board.hub)
			data, _ := json.Marshal(content)
			if err != nil || !content.Truncated || !bytes.Contains(data, []byte("safe-summary")) || bytes.Contains(data, []byte("discard-this-item-page")) || pageCalls.Load() > 2 {
				t.Fatalf("invalid item page did not yield a bounded, truthful summary: calls=%d truncated=%t error=%v", pageCalls.Load(), content.Truncated, err)
			}
		})
	}
}

func TestDesktopUnloadedHistoryDoesNotOfferControls(t *testing.T) {
	board, _, publicRef := newAttachmentTestBoard(t, "read-only")
	var calls atomic.Int32
	desktopRPCFixture(t, board, func(string, map[string]any) (any, error) {
		calls.Add(1)
		return nil, errors.New("history must not issue control RPCs")
	})
	for _, latest := range []LatestTurnState{turnCompleted, turnInterrupted, turnFailed, turnUnknown} {
		board.mu.Lock()
		thread := board.threads[board.reverse[publicRef]]
		thread.RuntimeState = runtimeNotLoaded
		thread.LatestTurnState = latest
		thread.ActiveTurnID = ""
		board.mu.Unlock()
		for _, item := range board.overview().Threads {
			if item.PublicRef == publicRef && (item.CanMessage || item.CanInterrupt) {
				t.Fatalf("unloaded %s history became controllable", latest)
			}
		}
		_, err := board.sendMessage(context.Background(), publicRef, "desktop-history-0908v5", "synthetic-message", nil)
		if !errors.Is(err, errConflict) || calls.Load() != 0 {
			t.Fatalf("unloaded history issued a control RPC: calls=%d error=%v", calls.Load(), err)
		}
	}
}

func TestDesktopControlRechecksServerStateBeforeMutation(t *testing.T) {
	for _, condition := range []string{"not-loaded", "now-active", "different-cwd", "wrong-thread", "read-failed"} {
		t.Run(condition, func(t *testing.T) {
			board, config, publicRef := newAttachmentTestBoard(t, "read-only")
			var calls, writes atomic.Int32
			otherCwd := t.TempDir()
			desktopRPCFixture(t, board, func(method string, params map[string]any) (any, error) {
				calls.Add(1)
				if method != "thread/read" {
					writes.Add(1)
					return nil, errors.New("unexpected mutation")
				}
				if condition == "read-failed" {
					return nil, errors.New("metadata unavailable")
				}
				threadID, cwd, state := params["threadId"], config.Projects["demo"], "idle"
				switch condition {
				case "not-loaded":
					state = "notLoaded"
				case "now-active":
					state = "active"
				case "different-cwd":
					cwd = otherCwd
				case "wrong-thread":
					threadID = "33333333-3333-4333-8333-333333333333"
				}
				return map[string]any{"thread": map[string]any{"id": threadID, "cwd": cwd, "status": map[string]any{"type": state}}}, nil
			})
			_, err := board.sendMessage(context.Background(), publicRef, "desktop-check-0908v5", "synthetic-message", nil)
			if err == nil || calls.Load() != 1 || writes.Load() != 0 {
				t.Fatalf("stale cached state permitted mutation: calls=%d writes=%d error=%v", calls.Load(), writes.Load(), err)
			}
		})
	}
}

func TestWebSocketRejectsOversizedFragmentedMessage(t *testing.T) {
	server, client := net.Pipe()
	defer client.Close()
	done := make(chan error, 1)
	go func() {
		defer server.Close()
		if err := writeServerFrame(server, false, 0x1, bytes.Repeat([]byte("a"), 2*1024*1024)); err != nil {
			done <- err
			return
		}
		done <- writeServerFrame(server, true, 0x0, bytes.Repeat([]byte("b"), 2*1024*1024+1))
	}()
	ws := &wsOverUnixSocket{conn: client, reader: bufio.NewReader(client)}
	if _, err := ws.readTextMessage(); err == nil || err.Error() != "app_server_frame" {
		t.Fatalf("fragmented payload escaped the total message cap: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestDesktopContentFailureKeepsObserverConnectionLive(t *testing.T) {
	board, _, publicRef := newAttachmentTestBoard(t, "read-only")
	directory, err := os.MkdirTemp("/tmp", "arc-content-fixture-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	socketPath, codexHome := filepath.Join(directory, "control.sock"), filepath.Join(directory, "codex-home")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	var connections atomic.Int32
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			connections.Add(1)
			go func() {
				defer connection.Close()
				reader := bufio.NewReader(connection)
				request, err := http.ReadRequest(reader)
				if err != nil {
					return
				}
				if _, err := fmt.Fprintf(connection, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", websocketAccept(request.Header.Get("Sec-WebSocket-Key"))); err != nil {
					return
				}
				for {
					frame, err := readRawFrame(reader)
					if err != nil || frame.opcode == 0x8 {
						return
					}
					var rpc struct {
						ID     int64  `json:"id"`
						Method string `json:"method"`
					}
					if json.Unmarshal(frame.payload, &rpc) != nil || rpc.Method == "initialized" {
						continue
					}
					var result any
					switch rpc.Method {
					case "initialize":
						result = map[string]any{"codexHome": codexHome, "platformFamily": "unix", "platformOs": "macos", "userAgent": "synthetic-fixture"}
					case "thread/turns/list":
						_ = writeServerFrame(connection, true, 0x1, bytes.Repeat([]byte("x"), 4*1024*1024+1))
						return
					case "thread/loaded/list":
						result = map[string]any{"data": []string{}}
					default:
						return
					}
					payload, _ := json.Marshal(map[string]any{"id": rpc.ID, "result": result})
					if writeServerFrame(connection, true, 0x1, payload) != nil {
						return
					}
				}
			}()
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	observer, err := startSocketAppServerClient(ctx, board, socketPath, codexHome)
	if err != nil {
		t.Fatal(err)
	}
	board.publishClient(observer)
	defer board.retireClient(observer)
	if _, err := board.threadContent(ctx, publicRef); !errors.Is(err, errObserverUnavailable) {
		t.Fatalf("oversized isolated reply did not fail safely: %v", err)
	}
	var page appIDPage
	if !observer.live() || observer.call(ctx, "thread/loaded/list", map[string]any{}, &page) != nil || connections.Load() != 2 {
		t.Fatalf("content failure disrupted the observer: live=%t connections=%d", observer.live(), connections.Load())
	}
}
