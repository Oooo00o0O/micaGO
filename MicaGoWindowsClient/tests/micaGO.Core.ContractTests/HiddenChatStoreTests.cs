using Microsoft.Data.Sqlite;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Storage;

internal static class HiddenChatStoreTests
{
    public static async Task RunAsync()
    {
        var path=Path.Combine(Path.GetTempPath(),$"micago-hidden-{Guid.NewGuid():N}.db");
        LocalCacheStore? cache=null;
        try
        {
            cache=new LocalCacheStore(path);await cache.InitializeAsync();
            await SeedLegacyAsync(path,["route-a","route-b"]);
            var hidden=await cache.GetHiddenChatGuidsAsync();
            True(hidden.SetEquals(["route-a","route-b"]),"hidden routes were not persisted");
            var message=new Message("message-a","route-b","hello","12:00",false,MessageDeliveryState.Read,DateCreated:1);
            await cache.UpsertMessagesAsync([message]);await cache.HideMessagesAsync([message.Id]);
            True((await cache.GetHiddenMessagesAsync()).Single().Id==message.Id,"hidden message row was not readable");
            True(await cache.RestoreHiddenMessagesAsync([message.Id])==1,"hidden message restore returned the wrong count");
            await cache.SetSettingAsync("settings.language","zh-Hans");await SeedLegacyAsync(path,["route-c"]);await cache.ClearContentCacheAsync();
            True(await cache.GetSettingAsync("settings.language")=="zh-Hans","content cache clear removed preferences");
            True((await cache.GetHiddenChatGuidsAsync()).Contains("route-c"),"content cache clear removed hidden state");
        }
        finally
        {
            cache?.Dispose();SqliteConnection.ClearAllPools();
            foreach(var suffix in new[]{string.Empty,"-wal","-shm"})if(File.Exists(path+suffix))File.Delete(path+suffix);
        }
    }

    internal static async Task SeedLegacyAsync(string path,IEnumerable<string> guids) {
        await using var db=new SqliteConnection($"Data Source={path}");await db.OpenAsync();
        foreach(var guid in guids) {
            await using var cmd=db.CreateCommand();cmd.CommandText="INSERT INTO hidden_chats(guid,hidden_at) VALUES($guid,0)";
            cmd.Parameters.AddWithValue("$guid",guid);await cmd.ExecuteNonQueryAsync();
        }
    }
    private static void True(bool value,string message){if(!value)throw new InvalidOperationException(message);}
}
