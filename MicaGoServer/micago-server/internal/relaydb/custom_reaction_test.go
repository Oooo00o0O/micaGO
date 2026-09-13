package relaydb

import (
	"context"
	"testing"

	"micagoserver/internal/store"
)

type reactionBackfillSource struct {
	fakeSemanticSource
	rows []store.SyncMessageRow
}

func (s reactionBackfillSource) ListSyncCustomReactions(_ context.Context, after int64, limit int) ([]store.SyncMessageRow, error) {
	var rows []store.SyncMessageRow
	for _, row := range s.rows {
		if row.SourceRowID > after && len(rows) < limit {
			rows = append(rows, row)
		}
	}
	return rows, nil
}

func TestCustomReactionBackfillKeepsMainWatermark(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	src := reactionBackfillSource{
		fakeSemanticSource: fakeSemanticSource{
			chats:    []store.SyncChatRow{{GUID: "chatA", ServiceName: strp("iMessage")}},
			messages: []store.SyncMessageRow{{ChatGUID: "chatA", GUID: "text", SourceRowID: 10, Text: strp("hello"), DateCreated: intp(100)}},
		},
		rows: []store.SyncMessageRow{{ChatGUID: "chatA", GUID: "custom", SourceRowID: 100, DateCreated: intp(200), AssociatedMessageType: intp(2006), AssociatedMessageGUID: strp("p:0/text"), AssociatedMessageEmoji: strp("🥳")}},
	}
	result, err := SyncOnce(ctx, src, db, 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	if result.NewLastMessageRowID != 10 {
		t.Fatalf("main watermark skipped: %d", result.NewLastMessageRowID)
	}
	value, _, err := db.GetSyncState("custom_reaction_rowid")
	if err != nil || value != "100" {
		t.Fatalf("reaction cursor %s: %v", value, err)
	}
	result, err = SyncOnce(ctx, src, db, 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	if result.MessagesWritten != 0 {
		t.Fatalf("duplicate writes: %+v", result)
	}
}
