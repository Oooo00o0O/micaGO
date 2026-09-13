import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/models/message_model.dart';
import 'package:mica_go/features/chats/message_render.dart';

MessageModel reaction(int row, String sender, int code, [String? emoji]) =>
    MessageModel.fromJson({
      'guid': 'reaction-$row',
      'isFromMe': false,
      'handle': {'id': sender},
      'dateCreated': 100,
      'sourceRowId': row,
      'associatedMessageGuid': 'p:0/target',
      'associatedMessageType': code,
      'associatedMessageEmoji': emoji,
    });

void main() {
  test('custom emoji survives cache serialization and copy', () {
    for (final emoji in ['🥳', '👍🏽', '👩‍💻', '🇬🇧', '🫩']) {
      final row = reaction(1, 'alice', 2006, emoji);
      final restored = MessageModel.fromJson(row.copyWith().toJson());
      expect(isReaction(restored), isTrue);
      expect(reactionEmoji(restored), emoji);
      expect(restored.sourceRowId, 1);
    }
    expect(tapbackFromCode(2007), isNull);
    expect(tapbackFromCode(2999), isNull);
    expect(tapbackFromCode(3006)?.isRemoval, isTrue);
  });
  test('replacement and removal are sender-scoped and ordered', () {
    final rows = [
      reaction(1, 'alice', 2006, '🥳'),
      reaction(2, 'bob', 2006, '🥳'),
      reaction(3, 'alice', 2006, '👩‍💻'),
      reaction(4, 'alice', 3006, '🥳'),
    ];
    expect(activeReactionEmojis(rows.reversed), ['👩‍💻', '🥳']);
    rows.add(reaction(5, 'alice', 3006, '👩‍💻'));
    expect(activeReactionEmojis(rows), ['🥳']);
    rows.add(reaction(6, 'bob', 3006));
    expect(activeReactionEmojis(rows), isEmpty);
  });
}
