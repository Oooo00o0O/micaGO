package relaydb

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"micagoserver/internal/store"
)

var ErrPreferenceConflict = errors.New("chat preference revision conflict")
var ErrPreferenceScope = errors.New("chat preference server changed")
var ErrPreferenceMutation = errors.New("mutation id reused with different content")

func (db *DB) ChatPreferences(ctx context.Context, since int64) (store.ChatPreferences, error) {
	tx, err := db.sqlDB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return store.ChatPreferences{}, err
	}
	defer tx.Rollback()
	result, err := readChatPreferences(ctx, tx, since)
	if err != nil {
		return result, err
	}
	return result, tx.Commit()
}

func readChatPreferences(ctx context.Context, tx *sql.Tx, since int64) (store.ChatPreferences, error) {
	result := store.ChatPreferences{Data: []store.ChatPreference{}}
	if err := tx.QueryRowContext(ctx, "SELECT server_id, revision FROM chat_preferences_state WHERE id=1").Scan(&result.ServerID, &result.Revision); err != nil {
		return result, err
	}
	rows, err := tx.QueryContext(ctx, "SELECT chat_guid, hidden, revision FROM chat_preferences WHERE revision > ? ORDER BY revision, chat_guid", since)
	if err != nil {
		return result, err
	}
	defer rows.Close()
	for rows.Next() {
		var p store.ChatPreference
		if err := rows.Scan(&p.ChatGUID, &p.Hidden, &p.Revision); err != nil {
			return result, err
		}
		result.Data = append(result.Data, p)
	}
	return result, rows.Err()
}

func (db *DB) MutateChatPreferences(ctx context.Context, request store.ChatPreferenceMutation) (store.ChatPreferences, error) {
	raw, err := json.Marshal(request)
	if err != nil {
		return store.ChatPreferences{}, err
	}
	digest := fmt.Sprintf("%x", sha256.Sum256(raw))
	tx, err := db.sqlDB.BeginTx(ctx, nil)
	if err != nil {
		return store.ChatPreferences{}, err
	}
	defer tx.Rollback()
	// Acquire the SQLite writer before reading revisions.
	if _, err = tx.ExecContext(ctx, "UPDATE chat_preferences_state SET revision=revision WHERE id=1"); err != nil {
		return store.ChatPreferences{}, err
	}
	result, err := readChatPreferences(ctx, tx, 0)
	if err != nil {
		return result, err
	}
	if request.ServerID != result.ServerID {
		return result, ErrPreferenceScope
	}
	var priorHash, priorResponse string
	err = tx.QueryRowContext(ctx, "SELECT request_hash,response FROM chat_preference_mutations WHERE mutation_id=?", request.MutationID).Scan(&priorHash, &priorResponse)
	if err == nil {
		if priorHash != digest {
			return result, ErrPreferenceMutation
		}
		err = json.Unmarshal([]byte(priorResponse), &result)
		return result, err
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return result, err
	}
	current := map[string]store.ChatPreference{}
	for _, p := range result.Data {
		current[p.ChatGUID] = p
	}
	for _, change := range request.Changes {
		if current[change.ChatGUID].Revision != change.BaseRevision {
			return result, ErrPreferenceConflict
		}
	}
	result.Revision++
	result.Data = []store.ChatPreference{}
	for _, change := range request.Changes {
		if _, err = tx.ExecContext(ctx, `INSERT INTO chat_preferences(chat_guid,hidden,revision) VALUES(?,?,?)
   ON CONFLICT(chat_guid) DO UPDATE SET hidden=excluded.hidden,revision=excluded.revision`,
			change.ChatGUID, change.Hidden, result.Revision); err != nil {
			return result, err
		}
		result.Data = append(result.Data, store.ChatPreference{ChatGUID: change.ChatGUID, Hidden: change.Hidden, Revision: result.Revision})
	}
	if _, err = tx.ExecContext(ctx, "UPDATE chat_preferences_state SET revision=? WHERE id=1", result.Revision); err != nil {
		return result, err
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return result, err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO chat_preference_mutations(mutation_id,request_hash,response) VALUES(?,?,?)", request.MutationID, digest, string(encoded)); err != nil {
		return result, err
	}
	return result, tx.Commit()
}
