using MicaGo.Core.Models;
using System.Text.Json;

internal static class CustomReactionTests
{
    public static void Run()
    {
        var target = new Message("target", "chat", "hello", "", false, MessageDeliveryState.Sent, DateCreated: 1);
        Message Reaction(int row, string sender, int code, string? emoji = null) =>
            new($"r{row}", "chat", "", "", false, MessageDeliveryState.Sent, DateCreated: 2,
                AssociatedMessageGuid: "p:0/target", AssociatedMessageType: code,
                SenderIdentity: sender, SourceRowId: row, AssociatedMessageEmoji: emoji);
        var rows = new List<Message> { target, Reaction(1, "alice", 2006, "🥳"),
            Reaction(2, "bob", 2006, "🥳"), Reaction(3, "alice", 2006, "👩‍💻"),
            Reaction(4, "alice", 3006, "🥳") };
        void Check(params string[] expected)
        {
            var rendered = ThreadPresentation.Build(rows.AsEnumerable().Reverse(), false, "en");
            var actual = rendered.Single(row => row.Id == "target");
            if (!(actual.Reactions ?? []).SequenceEqual(expected)) throw new Exception("Incorrect sender-scoped reactions");
            if (rendered.Any(row => row.IsReaction)) throw new Exception("Unconsumed reaction");
        }
        Check("👩‍💻", "🥳");
        rows.Add(Reaction(5, "alice", 3006, "👩‍💻"));
        Check("🥳");
        rows.Add(Reaction(6, "bob", 3006));
        Check();
        foreach (var emoji in new[] { "👍🏽", "👩‍💻", "🇬🇧", "🫩" })
        {
            var restored = JsonSerializer.Deserialize<Message>(JsonSerializer.Serialize(Reaction(7, "alice", 2006, emoji)))!;
            if (!restored.IsReaction || restored.AssociatedMessageEmoji != emoji) throw new Exception("Emoji cache roundtrip failed");
        }
        if (Reaction(8, "alice", 2007).IsReaction || Reaction(9, "alice", 2999).IsReaction) throw new Exception("Invalid reaction code");
    }
}
