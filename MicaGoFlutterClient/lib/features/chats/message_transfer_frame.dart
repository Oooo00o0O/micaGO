import 'package:flutter/material.dart';

class MessageTransferFrame extends StatelessWidget {
  final Widget child;
  final Widget? overlay;
  final bool dimmed;

  const MessageTransferFrame({
    super.key,
    required this.child,
    this.overlay,
    this.dimmed = false,
  });

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      Opacity(opacity: dimmed ? 0.55 : 1, child: child),
      if (overlay != null) Positioned.fill(child: Center(child: overlay)),
    ],
  );
}
