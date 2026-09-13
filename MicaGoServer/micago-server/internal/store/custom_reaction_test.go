package store

import (
	"context"
	"testing"
)

func TestCustomReactionWithoutText(t *testing.T) {
	q := modernChatDB(t)
	if _, err := q.db.Exec(`ALTER TABLE message ADD COLUMN associated_message_emoji TEXT`); err != nil {
		t.Fatal(err)
	}
	if _, err := q.db.Exec(`UPDATE message SET associated_message_type=2006, associated_message_emoji='👩‍💻' WHERE guid='m-react'`); err != nil {
		t.Fatal(err)
	}
	q.SetMessageColumns(columnsOf(t, q))
	rows, err := q.ListSyncRecentMessages(context.Background(), 100)
	if err != nil {
		t.Fatal(err)
	}
	var found bool
	for _, row := range rows {
		if row.GUID != "m-react" {
			continue
		}
		found = true
		if row.AssociatedMessageEmoji == nil || *row.AssociatedMessageEmoji != "👩‍💻" || !IsReactionForSyncRow(row) {
			t.Fatalf("reaction lost: %+v", row)
		}
	}
	if !found {
		t.Fatal("textless reaction filtered out")
	}
	rows, err = q.ListSyncCustomReactions(context.Background(), 0, 1)
	if err != nil || len(rows) != 1 {
		t.Fatalf("backfill: %v %v", rows, err)
	}
	rows, err = q.ListSyncCustomReactions(context.Background(), rows[0].SourceRowID, 1)
	if err != nil || len(rows) != 0 {
		t.Fatalf("cursor: %v %v", rows, err)
	}
}
