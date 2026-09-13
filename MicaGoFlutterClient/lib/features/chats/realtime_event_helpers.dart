import '../../core/network/websocket_client.dart';
import 'message_render.dart' as render;
import 'models/message_model.dart';

MessageModel? messageFromWsEvent(WsEvent e) {
  final raw = e.type == 'message:update' || e.type == 'send:match'
      ? e.data['message']
      : e.data;
  if (raw is Map<String, dynamic>) return MessageModel.fromJson(raw);
  return null;
}

String? chatGuidFromWsEvent(WsEvent e) {
  if (e.data['chatGuid'] is String) return e.data['chatGuid'] as String;
  final msg = e.data['message'];
  if (msg is Map<String, dynamic> && msg['chatGuid'] is String) {
    return msg['chatGuid'] as String;
  }
  return null;
}

bool isReactionMessage(MessageModel message) => render.isReaction(message);

String? reactionTargetGuid(MessageModel message) =>
    render.reactionTargetGuid(message.associatedMessageGuid);

String? realtimeCursorForEvent(WsEvent e) {
  final direct = _cursorFromMap(e.data);
  if (direct != null) return direct;
  final msg = e.data['message'];
  if (msg is Map<String, dynamic>) return _cursorFromMap(msg);
  return null;
}

String? _cursorFromMap(Map<String, dynamic> map) {
  for (final key in const [
    'sequence',
    'eventSequence',
    'eventId',
    'sourceRowID',
    'sourceRowId',
    'source_rowid',
    'rowID',
    'rowId',
    'rowid',
    'id',
  ]) {
    final n = _asInt(map[key]);
    if (n != null) return 'n:$n';
  }
  final date = _asInt(map['dateCreated']);
  final guid = map['guid'];
  if (date != null && guid is String && guid.isNotEmpty) {
    return 'f:$date:$guid';
  }
  return null;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
