using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace MicaGo.App.Services;

/// <summary>
/// W-UI8: the thread's contact bar, composer, cards and chips are translucent
/// so the Mica canvas shows through. Over a custom chat background that reads
/// as see-through boxes, so they turn solid while one is set. Theme brushes are
/// shared instances: changing them in place updates every XAML and code
/// reference in both Light and Dark, and survives theme switches.
/// </summary>
public static class ChatSurfaceBrushes
{
    private static readonly (string Key, Color Light, Color Dark)[] SolidColors =
    [
        ("MicaGoChatChipBrush", Color.FromArgb(0xFF, 0xEC, 0xEC, 0xEC), Color.FromArgb(0xFF, 0x33, 0x33, 0x33)),
        ("MicaGoChatCardBrush", Color.FromArgb(0xFF, 0xFB, 0xFB, 0xFB), Color.FromArgb(0xFF, 0x2B, 0x2B, 0x2B)),
    ];

    private static readonly Dictionary<SolidColorBrush, Color> Originals = [];
    private static bool? _solid;

    public static void Apply(bool solid)
    {
        if (_solid == solid) return;
        _solid = solid;
        foreach (var merged in Application.Current.Resources.MergedDictionaries)
        {
            foreach (var (themeKey, value) in merged.ThemeDictionaries)
            {
                // HighContrast brushes are already opaque system colours.
                if (themeKey is not string name || value is not ResourceDictionary theme) continue;
                var dark = name is "Default" or "Dark";
                if (!dark && name != "Light") continue;

                // MicaGoComposerBrush is a StaticResource alias of this acrylic.
                if (theme.TryGetValue("MicaGoContactBarBrush", out var bar) && bar is AcrylicBrush acrylic)
                {
                    acrylic.AlwaysUseFallback = solid;
                }
                foreach (var (key, light, darkColor) in SolidColors)
                {
                    if (!theme.TryGetValue(key, out var raw) || raw is not SolidColorBrush brush) continue;
                    if (!Originals.ContainsKey(brush)) Originals[brush] = brush.Color;
                    brush.Color = solid ? (dark ? darkColor : light) : Originals[brush];
                }
            }
        }
    }
}
