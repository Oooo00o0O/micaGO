import 'package:flutter/material.dart';

/// C77: keyboard-inset handling that survives a lock/unlock cycle.
///
/// `MediaQuery.viewInsets.bottom` is the platform's keyboard height, but it is
/// known to go **stale** across an app-lifecycle transition on Android: the app
/// is backgrounded with the IME open, the IME is torn down while the app is not
/// visible, and the resumed app can still read the old value until something
/// forces new metrics (flutter/flutter#179208, #163502). The app then reserves
/// space for a keyboard that is not on screen — the "screen cut in half" gap
/// below the composer.
///
/// Two guards, together:
///   1. an inset is only trusted while something editable actually has focus
///      ([_hasEditableFocus]), and
///   2. only while the app is **resumed** — [KeyboardLifecycle] drops focus on
///      every lifecycle change, because Android restores IME focus to the field
///      on resume *without* re-showing the keyboard, which would otherwise
///      re-open guard 1 for a stale value.
bool _hasEditableFocus() {
  final focus = FocusManager.instance.primaryFocus;
  if (focus == null || !focus.hasFocus) return false;
  final context = focus.context;
  if (context == null) return true;
  return context.widget is EditableText ||
      context.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// True when the platform inset may be trusted as a live keyboard height.
bool keyboardInsetIsTrustworthy() =>
    KeyboardLifecycle.isResumed && _hasEditableFocus();

double activeKeyboardInset(BuildContext context, {bool enabled = true}) {
  if (!enabled || !keyboardInsetIsTrustworthy()) return 0;
  return MediaQuery.viewInsetsOf(context).bottom;
}

MediaQueryData withoutStaleKeyboardInset(BuildContext context) {
  final data = MediaQuery.of(context);
  if (data.viewInsets.bottom == 0 || keyboardInsetIsTrustworthy()) return data;
  final insets = data.viewInsets;
  return data.copyWith(
    viewInsets: EdgeInsets.fromLTRB(insets.left, insets.top, insets.right, 0),
  );
}

/// Tracks whether the app is resumed and drops IME focus around every
/// lifecycle transition. Installed once, from the app root.
class KeyboardLifecycle with WidgetsBindingObserver {
  KeyboardLifecycle._();
  static final KeyboardLifecycle instance = KeyboardLifecycle._();
  static bool get isResumed => instance._resumed;

  bool _resumed = true;
  bool _installed = false;

  void install() {
    if (_installed) return;
    _installed = true;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    _resumed = resumed;
    // Both directions matter: dropping focus on the way out closes the IME
    // before the app is hidden, and dropping it again on the way back in
    // discards the focus Android restores for a keyboard that is not showing.
    FocusManager.instance.primaryFocus?.unfocus();
    if (!resumed) return;
    // The resumed frame can still carry the pre-lock metrics; nudge a rebuild
    // once they have settled (the community "wait for metrics to stabilise"
    // pattern) so nothing is left reserving a phantom keyboard.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.scheduleFrame();
    });
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      WidgetsBinding.instance.scheduleFrame();
    });
  }
}

class KeyboardInsetGuard extends StatelessWidget {
  final Widget child;

  const KeyboardInsetGuard({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return MediaQuery(data: withoutStaleKeyboardInset(context), child: child);
  }
}
