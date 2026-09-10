package main

import (
	"encoding/json"
	"fmt"
	"time"
)

type TaskMessage struct {
	TaskID    string    `json:"taskId"`
	Role      string    `json:"role"`
	Text      string    `json:"text"`
	CreatedAt time.Time `json:"createdAt"`
}

type TaskConversation struct {
	TaskID   string        `json:"taskId"`
	Agent    string        `json:"agent"`
	Messages []TaskMessage `json:"messages"`
}

type taskMessageStore struct {
	messages map[string][]TaskMessage
	closed   bool
}

func openTaskMessageStore(_ string) (*taskMessageStore, error) {
	return &taskMessageStore{messages: make(map[string][]TaskMessage)}, nil
}

func validateTaskMessage(message TaskMessage) error {
	if message.TaskID == "" || message.Text == "" || message.CreatedAt.IsZero() {
		return errInvalid
	}
	if message.Role != "user" && message.Role != "assistant" {
		return errInvalid
	}
	return nil
}

func (store *taskMessageStore) append(message TaskMessage) error {
	if store == nil || store.closed {
		return fmt.Errorf("message_store_unavailable")
	}
	if err := validateTaskMessage(message); err != nil {
		return err
	}
	store.apply(message)
	return nil
}

func (store *taskMessageStore) apply(message TaskMessage) {
	messages := store.messages[message.TaskID]
	if message.Role == "assistant" && len(messages) > 0 && messages[len(messages)-1].Role == "assistant" {
		messages[len(messages)-1].Text += message.Text
		store.messages[message.TaskID] = messages
		return
	}
	store.messages[message.TaskID] = append(messages, message)
}

func (store *taskMessageStore) taskMessages(taskID string) []TaskMessage {
	if store == nil {
		return nil
	}
	messages := store.messages[taskID]
	result := make([]TaskMessage, len(messages))
	copy(result, messages)
	return result
}

func (store *taskMessageStore) assistantRuneCount(taskID string) int {
	if store == nil {
		return 0
	}
	messages := store.messages[taskID]
	if len(messages) == 0 || messages[len(messages)-1].Role != "assistant" {
		return 0
	}
	return len([]rune(messages[len(messages)-1].Text))
}

func (store *taskMessageStore) Close() error {
	if store == nil {
		return nil
	}
	clear(store.messages)
	store.closed = true
	return nil
}

func (hub *Hub) taskConversation(taskID string) (TaskConversation, error) {
	hub.mu.Lock()
	defer hub.mu.Unlock()
	task := hub.tasks[taskID]
	if task == nil {
		return TaskConversation{}, errNotFound
	}
	chain := make([]*Task, 0, 4)
	seen := make(map[string]bool)
	for current := task; ; {
		if seen[current.ID] {
			return TaskConversation{}, errConflict
		}
		seen[current.ID] = true
		chain = append(chain, current)
		if current.ResumeOf == "" {
			break
		}
		current = hub.tasks[current.ResumeOf]
		if current == nil {
			return TaskConversation{}, errConflict
		}
	}
	messages := make([]TaskMessage, 0)
	for index := len(chain) - 1; index >= 0; index-- {
		messages = append(messages, hub.messageStore.taskMessages(chain[index].ID)...)
	}
	return TaskConversation{TaskID: task.ID, Agent: task.Agent, Messages: messages}, nil
}

func (hub *Hub) appendTaskMessageLocked(taskID, role, text string, createdAt time.Time) error {
	if text == "" {
		return nil
	}
	if err := hub.messageStore.append(TaskMessage{TaskID: taskID, Role: role, Text: text, CreatedAt: createdAt}); err != nil {
		hub.poisonLocked()
		return err
	}
	return nil
}

type taskMessageAdapter struct {
	assistantChunk func(stream, line string) string
}

var taskMessageAdapters = map[string]taskMessageAdapter{
	"kimi": {assistantChunk: extractKimiAssistantChunk},
}

func persistTaskMessages(agent string) bool {
	_, ok := taskMessageAdapters[agent]
	return ok
}

func extractPersistedAssistantChunk(agent, stream, line string) string {
	adapter, ok := taskMessageAdapters[agent]
	if !ok || adapter.assistantChunk == nil {
		return ""
	}
	return adapter.assistantChunk(stream, line)
}

func extractKimiAssistantChunk(stream, line string) string {
	if stream != "stdout" {
		return ""
	}
	var event struct {
		Role    string `json:"role"`
		Content string `json:"content"`
	}
	if json.Unmarshal([]byte(line), &event) != nil || event.Role != "assistant" {
		return ""
	}
	return event.Content
}
