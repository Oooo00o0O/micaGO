package store

type ChatPreference struct {
	ChatGUID string `json:"chatGuid"`
	Hidden   bool   `json:"hidden"`
	Revision int64  `json:"revision"`
}

type ChatPreferences struct {
	ServerID string           `json:"serverId"`
	Revision int64            `json:"revision"`
	Data     []ChatPreference `json:"data"`
}

type ChatPreferenceChange struct {
	ChatGUID     string `json:"chatGuid"`
	Hidden       bool   `json:"hidden"`
	BaseRevision int64  `json:"baseRevision"`
}

type ChatPreferenceMutation struct {
	ServerID   string                 `json:"serverId"`
	MutationID string                 `json:"mutationId"`
	Changes    []ChatPreferenceChange `json:"changes"`
}
