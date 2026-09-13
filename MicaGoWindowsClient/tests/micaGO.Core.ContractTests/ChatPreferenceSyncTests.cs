using Microsoft.Data.Sqlite;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Api;
using MicaGo.Infrastructure.Connection;
using MicaGo.Infrastructure.Storage;

internal static class ChatPreferenceSyncTests
{
    private sealed class Server : RealtimeSyncTests.FakeApi
    {
        public string ServerId = new('a', 32);
        public bool Offline;
        public bool LoseReply;
        public long Revision;
        public readonly Dictionary<string,ChatPreference> Rows = [];
        private readonly Dictionary<string,ChatPreferences> _replies = [];
        public override Task<ChatPreferences> GetChatPreferencesAsync(CancellationToken ct=default)
        {
            if(Offline)throw new HttpRequestException("offline");
            return Task.FromResult(new ChatPreferences(ServerId,Revision,Rows.Values.ToArray()));
        }
        public override Task<ChatPreferences> PatchChatPreferencesAsync(ChatPreferenceMutation request,CancellationToken ct=default)
        {
            if(Offline)throw new HttpRequestException("offline");
            if(_replies.TryGetValue(request.MutationId,out var replay))return Task.FromResult(replay);
            if(request.ServerId!=ServerId||request.Changes.Any(change=>change.BaseRevision!=(Rows.GetValueOrDefault(change.ChatGuid)?.Revision??0)))throw new MicaGoApiException("conflict",409);
            Revision++;
            var data=request.Changes.Select(change=>new ChatPreference(change.ChatGuid,change.Hidden,Revision)).ToArray();
            foreach(var row in data)Rows[row.ChatGuid]=row;
            var reply=new ChatPreferences(ServerId,Revision,data);_replies[request.MutationId]=reply;
            if(LoseReply){LoseReply=false;throw new HttpRequestException("lost acknowledgement");}
            return Task.FromResult(reply);
        }
    }

    public static async Task RunAsync()
    {
        var directory=Directory.CreateTempSubdirectory("micago-preferences-");
        try
        {
            using var cacheA=new LocalCacheStore(Path.Combine(directory.FullName,"a.db"));
            using var cacheB=new LocalCacheStore(Path.Combine(directory.FullName,"b.db"));
            var server=new Server();var a=new ChatPreferenceSync(cacheA,()=>server);var b=new ChatPreferenceSync(cacheB,()=>server);
            await cacheA.InitializeAsync();
            await HiddenChatStoreTests.SeedLegacyAsync(Path.Combine(directory.FullName,"a.db"),["legacy"]);
            await a.SyncAsync();await b.SyncAsync();
            True(a.LegacyCount==1&&server.Revision==0,"legacy records uploaded automatically");
            await a.ImportLegacyAsync();await b.SyncAsync();
            True(b.Hidden.Contains("legacy"),"legacy import not synced");
            await a.SetHiddenAsync(["route-a","route-b"],true);await b.SyncAsync();
            True(b.Hidden.Contains("route-a")&&b.Hidden.Contains("route-b"),"route batch not synced");
            await b.SetHiddenAsync(["route-a","route-b"],false);await a.SyncAsync();
            True(!a.Hidden.Contains("route-a"),"restore not synced");
            server.Offline=true;await a.SetHiddenAsync(["offline"],true);await a.SetHiddenAsync(["offline"],false);
            a=new ChatPreferenceSync(cacheA,()=>server);server.Offline=false;await a.SyncAsync();
            True(!a.Pending&&!a.HasConflicts&&!server.Rows["offline"].Hidden,"restart lost offline ordering");
            server.LoseReply=true;await a.SetHiddenAsync(["lost"],true);
            await b.SyncAsync();await b.SetHiddenAsync(["lost"],false);var revision=server.Revision;await a.SyncAsync();
            True(!a.Pending&&!a.Hidden.Contains("lost")&&server.Revision==revision,"replay overwrote a later edit");
            server.Offline=true;await a.SetHiddenAsync(["conflict"],true);server.Offline=false;
            await b.SetHiddenAsync(["conflict"],false);await a.SyncAsync();
            True(a.HasConflicts&&!a.Hidden.Contains("conflict"),"stale write overwrote server");
            await a.ResolveConflictsAsync(true);await b.SyncAsync();
            True(!a.HasConflicts&&b.Hidden.Contains("conflict"),"explicit conflict resolution failed");
            server.Offline=true;await a.SetHiddenAsync(["private-route"],true);server.Offline=false;server.ServerId=new('b',32);
            await a.SyncAsync();True(!a.Pending&&!server.Rows.ContainsKey("private-route"),"outbox crossed server identity");
            server.ServerId=new('a',32);await a.SyncAsync();True(server.Rows["private-route"].Hidden,"archived outbox lost");
            await cacheA.ClearContentCacheAsync();True(await cacheA.GetSettingAsync("chat.preferences.v1") is not null,"cache clear erased preferences");
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            directory.Delete(true);
        }
    }
    private static void True(bool condition,string message){if(!condition)throw new InvalidOperationException(message);}
}
