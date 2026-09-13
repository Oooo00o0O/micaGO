using MicaGo.Core.Connection;

internal static class RouteSelectionTests
{
    private const string Lan = "http://192.168.1.20:8787";
    private const string Pub = "https://mica.example.com";

    public static void Run()
    {
        var ok = new RouteProbe(true, TimeSpan.FromMilliseconds(38));
        var down = new RouteProbe(false, null);

        // The route in use stays connected while realtime is up, even if a check just failed.
        Equal(RouteRowStatus.Connected, RouteSelection.RowStatus(Lan, null, Lan, true, false, down));
        Equal(RouteRowStatus.Connected, RouteSelection.RowStatus(Lan, null, Lan, true, true, null));
        Equal(RouteRowStatus.Connecting, RouteSelection.RowStatus(Lan, null, Lan, false, false, null));
        Equal(RouteRowStatus.Unavailable, RouteSelection.RowStatus(Lan, null, Lan, false, false, down));
        // Other routes: checking while probed or never probed, else their last result.
        Equal(RouteRowStatus.Checking, RouteSelection.RowStatus(Pub, null, Lan, true, true, ok));
        Equal(RouteRowStatus.Checking, RouteSelection.RowStatus(Pub, null, Lan, true, false, null));
        Equal(RouteRowStatus.Available, RouteSelection.RowStatus(Pub, null, Lan, true, false, ok));
        Equal(RouteRowStatus.Unavailable, RouteSelection.RowStatus(Pub, null, Lan, true, false, down));
        Equal(RouteRowStatus.Switching, RouteSelection.RowStatus(Pub, Pub, Lan, true, false, ok));

        var statuses = new Dictionary<string, RouteRowStatus>(StringComparer.OrdinalIgnoreCase)
        {
            [Lan] = RouteRowStatus.Connected,
            [Pub] = RouteRowStatus.Switching,
        };
        Equal<string?>(Pub, RouteSelection.InUse(statuses, Pub, Lan));
        statuses[Pub] = RouteRowStatus.Available;
        Equal<string?>(Lan, RouteSelection.InUse(statuses, null, Lan));
        statuses[Lan] = RouteRowStatus.Unavailable;
        Equal<string?>(null, RouteSelection.InUse(statuses, null, Lan));

        var endpoints = new[]
        {
            new ConnectionEndpoint(EndpointKind.Public, Pub, "wss://mica.example.com/ws"),
            new ConnectionEndpoint(EndpointKind.Lan, Lan, "ws://192.168.1.20:8787/ws"),
            new ConnectionEndpoint(EndpointKind.Lan, Lan, "ws://192.168.1.20:8787/ws"),
        };
        Equal($"{Lan},{Pub}", string.Join(',', RouteSelection.DisplayOrder(endpoints, ConnectionMode.Auto).Select(e => e.BaseUrl)));
        Equal(Pub, string.Join(',', RouteSelection.DisplayOrder(endpoints, ConnectionMode.PublicOnly).Select(e => e.BaseUrl)));
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"expected {expected}, got {actual}");
    }
}
