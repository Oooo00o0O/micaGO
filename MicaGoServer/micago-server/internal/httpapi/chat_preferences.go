package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"micagoserver/internal/realtime"
	"micagoserver/internal/relaydb"
	"micagoserver/internal/store"
	"net/http"
	"strconv"
	"strings"
)

type chatPreferenceService interface {
	ChatPreferences(context.Context, int64) (store.ChatPreferences, error)
	MutateChatPreferences(context.Context, store.ChatPreferenceMutation) (store.ChatPreferences, error)
}

func (h *Handlers) SetChatPreferences(service chatPreferenceService, events eventBroadcaster) {
	h.chatPreferences = service
	h.preferenceEvents = events
}

func (h *Handlers) GetChatPreferences(w http.ResponseWriter, r *http.Request) {
	if h.chatPreferences == nil {
		writeInternalError(w)
		return
	}
	since := int64(0)
	if raw := r.URL.Query().Get("since"); raw != "" {
		var err error
		since, err = strconv.ParseInt(raw, 10, 64)
		if err != nil || since < 0 {
			writeBadRequest(w, "invalid preference cursor")
			return
		}
	}
	result, err := h.chatPreferences.ChatPreferences(r.Context(), since)
	if err != nil {
		h.logInternal("chat preferences", err)
		writeInternalError(w)
		return
	}
	if since > result.Revision {
		writeJSON(w, http.StatusConflict, map[string]any{"code": "preference_cursor_reset", "serverId": result.ServerID})
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (h *Handlers) PatchChatPreferences(w http.ResponseWriter, r *http.Request) {
	if h.chatPreferences == nil {
		writeInternalError(w)
		return
	}
	var wire struct {
		ServerID   string `json:"serverId"`
		MutationID string `json:"mutationId"`
		Changes    []struct {
			ChatGUID     string `json:"chatGuid"`
			Hidden       *bool  `json:"hidden"`
			BaseRevision *int64 `json:"baseRevision"`
		} `json:"changes"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&wire); err != nil {
		writeBadRequest(w, "invalid preference mutation")
		return
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		writeBadRequest(w, "invalid preference mutation")
		return
	}
	request := store.ChatPreferenceMutation{ServerID: wire.ServerID, MutationID: wire.MutationID}
	for _, change := range wire.Changes {
		if change.Hidden == nil || change.BaseRevision == nil {
			writeBadRequest(w, "hidden and baseRevision are required")
			return
		}
		request.Changes = append(request.Changes, store.ChatPreferenceChange{ChatGUID: change.ChatGUID, Hidden: *change.Hidden, BaseRevision: *change.BaseRevision})
	}
	if len(request.ServerID) != 32 || len(request.MutationID) < 8 || len(request.MutationID) > 128 || len(request.Changes) == 0 || len(request.Changes) > 200 {
		writeBadRequest(w, "invalid preference mutation")
		return
	}
	seen := map[string]bool{}
	for _, change := range request.Changes {
		if strings.TrimSpace(change.ChatGUID) == "" || len(change.ChatGUID) > 1024 || change.BaseRevision < 0 || seen[change.ChatGUID] {
			writeBadRequest(w, "invalid or duplicate chat preference")
			return
		}
		seen[change.ChatGUID] = true
	}
	result, err := h.chatPreferences.MutateChatPreferences(r.Context(), request)
	switch {
	case errors.Is(err, relaydb.ErrPreferenceConflict):
		writeJSON(w, http.StatusConflict, map[string]any{"code": "preference_conflict", "current": result})
		return
	case errors.Is(err, relaydb.ErrPreferenceScope):
		writeJSON(w, http.StatusConflict, map[string]any{"code": "preference_server_changed", "current": result})
		return
	case errors.Is(err, relaydb.ErrPreferenceMutation):
		writeJSON(w, http.StatusConflict, map[string]any{"code": "preference_mutation_reused"})
		return
	case err != nil:
		h.logInternal("update chat preferences", err)
		writeInternalError(w)
		return
	}
	if h.preferenceEvents != nil {
		_ = h.preferenceEvents.Broadcast(r.Context(), realtime.Event{Type: "chat-preferences:changed", Data: map[string]any{"revision": result.Revision}})
	}
	writeJSON(w, http.StatusOK, result)
}
