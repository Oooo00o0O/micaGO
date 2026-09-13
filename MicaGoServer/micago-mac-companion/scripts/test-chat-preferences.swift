import Foundation

enum APIError: Error { case status(Int) }

@MainActor
final class APIClient {
    var serverId = String(repeating: "a", count: 32)
    var revision: Int64 = 0
    var rows: [String: ChatPreference] = [:]
    var replies: [String: ChatPreferencesResponse] = [:]
    var offline = false
    var loseReply = false
    func chatPreferences() async throws -> ChatPreferencesResponse {
        if offline { throw APIError.status(503) }
        return ChatPreferencesResponse(serverId: serverId, revision: revision, data: Array(rows.values))
    }
    func patchChatPreferences(_ request: ChatPreferenceMutation) async throws -> ChatPreferencesResponse {
        if offline { throw APIError.status(503) }
        if let reply = replies[request.mutationId] { return reply }
        guard request.serverId == serverId,
              request.changes.allSatisfy({ $0.baseRevision == (rows[$0.chatGuid]?.revision ?? 0) }) else {
            throw APIError.status(409)
        }
        revision += 1
        let data = request.changes.map { ChatPreference(chatGuid: $0.chatGuid, hidden: $0.hidden, revision: revision) }
        for row in data { rows[row.chatGuid] = row }
        let reply = ChatPreferencesResponse(serverId: serverId, revision: revision, data: data)
        replies[request.mutationId] = reply
        if loseReply { loseReply = false; throw APIError.status(503) }
        return reply
    }
}

@main
struct PreferenceTests {
    @MainActor
    static func main() async {
        let suiteA = "micago.preference.test." + UUID().uuidString
        let suiteB = "micago.preference.test." + UUID().uuidString
        let defaultsA = UserDefaults(suiteName: suiteA)!
        let defaultsB = UserDefaults(suiteName: suiteB)!
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }
        let api = APIClient()
        var a = ChatPreferenceStore(defaults: defaultsA)
        let b = ChatPreferenceStore(defaults: defaultsB)
        await a.sync(client: api)
        await b.sync(client: api)
        await a.setHidden("route", hidden: true, client: api)
        await b.sync(client: api)
        precondition(b.hidden.contains("route"))
        await b.setHidden("route", hidden: false, client: api)
        await a.sync(client: api)
        precondition(!a.hidden.contains("route"))
        api.offline = true
        await a.setHidden("offline", hidden: true, client: api)
        await a.setHidden("offline", hidden: false, client: api)
        a = ChatPreferenceStore(defaults: defaultsA)
        api.offline = false
        await a.sync(client: api)
        precondition(!a.pending && !a.hasConflicts && api.rows["offline"]?.hidden == false)
        api.loseReply = true
        await a.setHidden("lost", hidden: true, client: api)
        await b.sync(client: api)
        await b.setHidden("lost", hidden: false, client: api)
        let revision = api.revision
        await a.sync(client: api)
        precondition(!a.pending && !a.hidden.contains("lost") && api.revision == revision)
        api.offline = true
        await a.setHidden("conflict", hidden: true, client: api)
        api.offline = false
        await b.setHidden("conflict", hidden: false, client: api)
        await a.sync(client: api)
        precondition(a.hasConflicts && !a.hidden.contains("conflict"))
        await a.resolve(useMine: true, client: api)
        await b.sync(client: api)
        precondition(!a.hasConflicts && b.hidden.contains("conflict"))
        api.offline = true
        await a.setHidden("private-route", hidden: true, client: api)
        api.offline = false
        api.serverId = String(repeating: "b", count: 32)
        await a.sync(client: api)
        precondition(!a.pending && api.rows["private-route"] == nil)
        api.serverId = String(repeating: "a", count: 32)
        await a.sync(client: api)
        precondition(api.rows["private-route"]?.hidden == true)
        print("PASS Companion preferences: devices, offline restart, replay, conflicts, server scope")
    }
}
