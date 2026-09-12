import 'package:flutter/material.dart';

class ChatComposerInput extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final Color textColor;
  final Color hintColor;
  final Color cursorColor;
  final String hint;
  final ValueChanged<KeyboardInsertedContent> onContentInserted;

  const ChatComposerInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.textColor,
    required this.hintColor,
    required this.cursorColor,
    required this.hint,
    required this.onContentInserted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      minLines: 1,
      maxLines: 5,
      style: TextStyle(color: textColor, fontSize: 16, height: 1.3),
      strutStyle: const StrutStyle(fontSize: 16, height: 1.3),
      cursorColor: cursorColor,
      textAlignVertical: TextAlignVertical.center,
      textInputAction: TextInputAction.newline,
      keyboardType: TextInputType.multiline,
      contentInsertionConfiguration: ContentInsertionConfiguration(
        allowedMimeTypes: const [
          'image/png',
          'image/gif',
          'image/jpeg',
          'image/jpg',
          'image/bmp',
          'image/tiff',
          'image/webp',
          'image/heic',
          'image/heif',
        ],
        onContentInserted: onContentInserted,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: hintColor, fontSize: 16, height: 1.3),
        border: InputBorder.none,
        isCollapsed: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }
}
