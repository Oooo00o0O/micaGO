namespace MicaGo.Core.Connection;

/// <summary>W-UI9: what one row of the Settings route card shows (Flutter C85).</summary>
public enum RouteRowStatus
{
    Switching,
    Connected,
    Connecting,
    Checking,
    Available,
    Unavailable,
}

/// <summary>Outcome of a manual route switch, shown as a short notice.</summary>
public enum RouteSwitchResult
{
    /// <summary>Connected through the requested route.</summary>
    Switched,

    /// <summary>The requested route failed and automatic selection connected another.</summary>
    FellBack,

    /// <summary>Nothing was reachable.</summary>
    Unreachable,

    /// <summary>A newer selection replaced this one; say nothing.</summary>
    Superseded,
}

/// <summary>Latest reachability check of one route.</summary>
public sealed record RouteProbe(bool Reachable, TimeSpan? Latency);

public static class RouteSelection
{
    /// <summary>
    /// The radio marks the route in use (switching / connected / connecting) and
    /// only <see cref="RouteRowStatus.Available"/> rows can be picked. A check
    /// never changes the connection — it only decides whether a row is pickable.
    /// </summary>
    public static RouteRowStatus RowStatus(
        string baseUrl,
        string? switchingTo,
        string? activeBaseUrl,
        bool realtimeConnected,
        bool probing,
        RouteProbe? probe)
    {
        if (Same(baseUrl, switchingTo)) return RouteRowStatus.Switching;
        if (Same(baseUrl, activeBaseUrl))
        {
            // The route in use stays "connected" while realtime is up, even if a
            // Settings check of it just timed out.
            if (realtimeConnected) return RouteRowStatus.Connected;
            if (probing || probe is null || probe.Reachable) return RouteRowStatus.Connecting;
        }
        if (probing || probe is null) return RouteRowStatus.Checking;
        return probe.Reachable ? RouteRowStatus.Available : RouteRowStatus.Unavailable;
    }

    /// <summary>The row the radio marks, or null when no route is in use.</summary>
    public static string? InUse(
        IReadOnlyDictionary<string, RouteRowStatus> statuses,
        string? switchingTo,
        string? activeBaseUrl)
    {
        if (switchingTo is not null && statuses.ContainsKey(switchingTo)) return switchingTo;
        if (activeBaseUrl is not null
            && statuses.TryGetValue(activeBaseUrl, out var status)
            && (status is RouteRowStatus.Connected or RouteRowStatus.Connecting))
        {
            return activeBaseUrl;
        }
        return null;
    }

    /// <summary>Stable Settings order (LAN, then Public, as the selector tries them), deduplicated.</summary>
    public static IReadOnlyList<ConnectionEndpoint> DisplayOrder(
        IReadOnlyList<ConnectionEndpoint> endpoints,
        ConnectionMode mode)
    {
        var lan = endpoints.Where(endpoint => endpoint.Kind == EndpointKind.Lan);
        var publicEndpoints = endpoints.Where(endpoint => endpoint.Kind == EndpointKind.Public);
        var ordered = mode switch
        {
            ConnectionMode.LanOnly => lan,
            ConnectionMode.PublicOnly => publicEndpoints,
            _ => lan.Concat(publicEndpoints),
        };
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return ordered.Where(endpoint => seen.Add(endpoint.BaseUrl)).ToArray();
    }

    private static bool Same(string a, string? b) =>
        b is not null && string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
}
