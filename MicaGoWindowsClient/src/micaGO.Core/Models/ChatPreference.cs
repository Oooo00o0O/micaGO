namespace MicaGo.Core.Models;

public sealed record ChatPreference(string ChatGuid, bool Hidden, long Revision);
public sealed record ChatPreferences(string ServerId, long Revision, IReadOnlyList<ChatPreference> Data);
public sealed record ChatPreferenceChange(string ChatGuid, bool Hidden, long BaseRevision);
public sealed record ChatPreferenceMutation(string ServerId, string MutationId, IReadOnlyList<ChatPreferenceChange> Changes);
