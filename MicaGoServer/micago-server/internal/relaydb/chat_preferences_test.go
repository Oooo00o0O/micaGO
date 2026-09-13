package relaydb

import (
	"context"
	"errors"
	"micagoserver/internal/store"
	"reflect"
	"testing"
)

func TestChatPreferencesAtomicReplayAndConflict(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	initial, err := db.ChatPreferences(ctx, 0)
	must(t, err)
	request := store.ChatPreferenceMutation{ServerID: initial.ServerID, MutationID: "first-operation", Changes: []store.ChatPreferenceChange{{ChatGUID: "a", Hidden: true}, {ChatGUID: "b", Hidden: true}}}
	first, err := db.MutateChatPreferences(ctx, request)
	must(t, err)
	if first.Revision != 1 || len(first.Data) != 2 {
		t.Fatalf("unexpected result: %+v", first)
	}
	restore := store.ChatPreferenceMutation{ServerID: initial.ServerID, MutationID: "restore-operation", Changes: []store.ChatPreferenceChange{{ChatGUID: "a", Hidden: false, BaseRevision: 1}}}
	_, err = db.MutateChatPreferences(ctx, restore)
	must(t, err)
	replay, err := db.MutateChatPreferences(ctx, request)
	must(t, err)
	if !reflect.DeepEqual(first, replay) {
		t.Fatal("replay changed the response")
	}
	delta, err := db.ChatPreferences(ctx, 1)
	must(t, err)
	if delta.Revision != 2 || len(delta.Data) != 1 || delta.Data[0].Hidden {
		t.Fatalf("restore tombstone lost: %+v", delta)
	}
	stale := store.ChatPreferenceMutation{ServerID: initial.ServerID, MutationID: "stale-operation", Changes: []store.ChatPreferenceChange{{ChatGUID: "b", Hidden: false, BaseRevision: 1}, {ChatGUID: "a", Hidden: true, BaseRevision: 1}}}
	_, err = db.MutateChatPreferences(ctx, stale)
	if !errors.Is(err, ErrPreferenceConflict) {
		t.Fatalf("expected conflict: %v", err)
	}
	current, err := db.ChatPreferences(ctx, 0)
	must(t, err)
	if current.Revision != 2 {
		t.Fatal("conflicting batch partially committed")
	}
	for _, row := range current.Data {
		if row.ChatGUID == "b" && !row.Hidden {
			t.Fatal("conflicting batch changed b")
		}
	}
	request.Changes[0].Hidden = false
	_, err = db.MutateChatPreferences(ctx, request)
	if !errors.Is(err, ErrPreferenceMutation) {
		t.Fatalf("expected mutation reuse rejection: %v", err)
	}
	request.ServerID = "another-server"
	_, err = db.MutateChatPreferences(ctx, request)
	if !errors.Is(err, ErrPreferenceScope) {
		t.Fatalf("expected scope rejection: %v", err)
	}
}

func TestHiddenChatKeepsSyncAndMuteRules(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	initial, err := db.ChatPreferences(ctx, 0)
	must(t, err)
	must(t, db.UpsertSyncRule(ctx, store.SyncRuleJSON{TargetKind: TargetChat, TargetValue: "muted", SyncMode: SyncAllow, PushMode: PushMuted}))
	must(t, db.UpsertSyncRule(ctx, store.SyncRuleJSON{TargetKind: TargetChat, TargetValue: "blocked", SyncMode: SyncBlock, PushMode: PushInherit}))
	for i, hidden := range []bool{true, false} {
		changes := []store.ChatPreferenceChange{}
		for _, guid := range []string{"normal", "muted", "blocked"} {
			changes = append(changes, store.ChatPreferenceChange{ChatGUID: guid, Hidden: hidden, BaseRevision: int64(i)})
		}
		_, err = db.MutateChatPreferences(ctx, store.ChatPreferenceMutation{ServerID: initial.ServerID, MutationID: []string{"hide-all", "show-all"}[i], Changes: changes})
		must(t, err)
		snapshot, err := db.LoadRuleSnapshot(ctx)
		must(t, err)
		if !snapshot.SyncAllowed("normal", nil) || !snapshot.SyncAllowed("muted", nil) || snapshot.SyncAllowed("blocked", nil) {
			t.Fatal("visibility changed ingestion rules")
		}
		if snapshot.PushEnabled("muted", nil) || snapshot.PushEnabled("normal", nil) == hidden {
			t.Fatal("visibility or prior mute ignored")
		}
	}
}
