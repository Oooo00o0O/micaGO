import 'dart:async';

import 'package:async/async.dart';
import 'package:flutter/foundation.dart';

import '../../core/app_controller.dart';
import '../../core/network/api_client.dart';
import '../../core/network/websocket_client.dart';
import '../../core/storage/media_cache.dart';
import 'attachment_panel.dart' show StagedAttachment;
import 'models/message_model.dart';
import 'realtime_event_helpers.dart' as rt;
import 'store/message_collection.dart';
// Re-export the reconciliation predicate so existing callers/tests that import
// it from thread_controller continue to work after the store extraction.
export 'store/message_collection.dart' show shouldReconcileLocalWithServer;

enum ThreadState { loading, loaded, empty, error }

/// Drives one chat thread. Holds a [MessageCollection] (the per-chat store) and
/// *patches* it from REST pages + WebSocket events — it never reloads the whole
/// thread on an event when the payload is complete. Optimistic sends live in the
/// store and reconcile against later server rows.
class ThreadController extends ChangeNotifier {
  final AppController app;
  final String chatGuid;

  /// C68 (beta merged view): additional route guids displayed in this thread.
  /// Sends always go to [chatGuid]; these only widen what is *shown*.
  final Set<String> mergedGuids;

  ThreadController({
    required this.app,
    required this.chatGuid,
    Set<String> mergedGuids = const {},
  }) : mergedGuids = {...mergedGuids}..remove(chatGuid);

  /// Every chat guid rendered by this thread (primary + merged routes).
  Set<String> get threadGuids => {chatGuid, ...mergedGuids};

  static const int _pageSize = 50;

  ThreadState state = ThreadState.loading;
  String? error;

  final MessageCollection _col = MessageCollection();

  /// C78: pagination is tracked **per route**. The merged view used to page
  /// only the primary route, so scrolling up never fetched older messages from
  /// the other routes — the timeline showed one source with growing holes.
  final Map<String, int> _routeOffsets = {};
  final Set<String> _routesWithMore = {};
  bool hasMore = true;
  bool loadingOlder = false;

  /// C78: coalesces concurrent load() calls. There are seven triggers (start,
  /// pull-to-refresh, error retry, the debounced WS fallback, post-action
  /// refresh…), and each one used to clear + replace the whole message set, so
  /// two overlapping loads raced and the slower — possibly staler — one won.
  /// AsyncCache.ephemeral runs the body at most once concurrently and lets
  /// every caller await the same result (package:async, Dart team).
  final AsyncCache<void> _loadGate = AsyncCache<void>.ephemeral();

  /// C78: in-flight work must not touch a disposed controller (switching routes
  /// disposes this one while its load is still running).
  bool _disposed = false;

  StreamSubscription<WsEvent>? _wsSub;
  StreamSubscription<MessageModel>? _deltaSub;
  Timer? _reloadDebounce;

  /// Chronological (oldest → newest); the thread view renders it reversed.
  List<MessageModel> get messages => _col.ordered;

  String presentationKeyFor(MessageModel message) =>
      _col.presentationKeyFor(message);

  void start() {
    _wsSub = app.ws.events.listen(_onWsEvent);
    // C21: also patch from the delta catch-up (the correctness path), not only
    // WebSocket events. GUID dedup in the collection prevents duplicate bubbles.
    _deltaSub = app.deltaMessages.listen(_onDeltaMessage);
    unawaited(app.catchUp(reason: 'thread:$chatGuid'));
    load();
  }

  /// notifyListeners() that is safe after dispose (C78).
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  void _onDeltaMessage(MessageModel msg) {
    if (_disposed) return;
    if (!threadGuids.contains(msg.chatGuid) || msg.guid.isEmpty) return;
    _col.upsertServer(msg);
    _sweepAttachmentSendBookkeeping();
    state = ThreadState.loaded;
    _notify();
  }

  /// Cached messages for every guid this thread displays.
  Future<List<MessageModel>> _cachedThreadMessages() async {
    final combined = <MessageModel>[];
    for (final guid in threadGuids) {
      combined.addAll(await app.cache.listMessages(guid, limit: _pageSize));
    }
    return combined;
  }

  /// Refreshes the thread. Concurrent callers share one run (see [_loadGate]).
  Future<void> load({bool showSpinner = true}) =>
      _loadGate.fetch(() => _loadInner(showSpinner: showSpinner));

  Future<void> _loadInner({required bool showSpinner}) async {
    final api = app.api;
    if (api == null) {
      final cached = await _cachedThreadMessages();
      if (_disposed) return;
      if (cached.isNotEmpty) {
        _col.mergeServerPage(cached);
        state = ThreadState.loaded;
        error = null;
      } else {
        state = ThreadState.error;
        error = 'Not connected.';
      }
      _notify();
      return;
    }
    if (showSpinner) {
      final cached = await _cachedThreadMessages();
      if (_disposed) return;
      if (cached.isNotEmpty) {
        _col.mergeServerPage(cached);
        state = ThreadState.loaded;
      } else {
        state = ThreadState.loading;
      }
      error = null;
      _notify();
    }
    try {
      // C78: every route in parallel — the merged view used to await them one
      // after another, multiplying latency (and the window in which an
      // arriving message could be clobbered) by the number of routes.
      final routes = threadGuids.toList(growable: false);
      final pages = await Future.wait(
        routes.map(
          (guid) async => (
            guid: guid,
            rows: await _fetchRoutePage(api, guid, offset: 0),
          ),
        ),
      );
      if (_disposed) return;
      final fetched = <MessageModel>[];
      for (final page in pages) {
        if (page.rows == null) continue; // route failed; keep the others
        await app.cache.mergeServerPage(page.guid, page.rows!);
        fetched.addAll(page.rows!);
        _routeOffsets[page.guid] = page.rows!.length;
        if (page.rows!.length >= _pageSize) {
          _routesWithMore.add(page.guid);
        } else {
          _routesWithMore.remove(page.guid);
        }
      }
      if (_disposed) return;
      // Store everything (so unhide can restore it) but never display a
      // client-hidden message.
      final hidden = await app.cache.hiddenMessageGuids();
      if (_disposed) return;
      _col.mergeServerPage(
        fetched.where((m) => !hidden.contains(m.guid)).toList(),
      );
      _sweepAttachmentSendBookkeeping();
      hasMore = _routesWithMore.isNotEmpty;
      state = _col.isEmpty ? ThreadState.empty : ThreadState.loaded;
      error = null;
    } on ApiException catch (e) {
      final cached = await _cachedThreadMessages();
      if (_disposed) return;
      if (cached.isNotEmpty) {
        _col.mergeServerPage(cached);
        state = ThreadState.loaded;
        error = null;
      } else {
        state = ThreadState.error;
        error = _humanize(e);
      }
    }
    _notify();
  }

  /// One route's page, or null when that route failed (the rest still render).
  Future<List<MessageModel>?> _fetchRoutePage(
    ApiClient api,
    String guid, {
    required int offset,
  }) async {
    try {
      return await api.getMessages(guid, limit: _pageSize, offset: offset);
    } on ApiException {
      return null;
    }
  }

  /// Hides a single message on the client only (the server copy is untouched).
  /// Re-reads the visible page from the cache so it disappears immediately.
  Future<void> hideMessage(String guid) => hideMessages([guid]);

  /// C64: batch variant for multi-select — one cache reload for the whole set.
  Future<void> hideMessages(Iterable<String> guids) async {
    final ids = guids.where((g) => g.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    for (final guid in ids) {
      await app.cache.setMessageHidden(guid, true);
    }
    _col.mergeServerPage(await _cachedThreadMessages());
    _notify();
  }

  /// C78: pages **every** route that still has history, in parallel. Previously
  /// only the primary route was paged, so a merged conversation could scroll
  /// back through one participant's messages while the other route stayed stuck
  /// at its newest page.
  Future<void> loadOlder() async {
    if (loadingOlder || !hasMore) return;
    final api = app.api;
    if (api == null) return;
    loadingOlder = true;
    _notify();
    try {
      final routes = threadGuids
          .where(_routesWithMore.contains)
          .toList(growable: false);
      final pages = await Future.wait(
        routes.map(
          (guid) async => (
            guid: guid,
            rows: await _fetchRoutePage(
              api,
              guid,
              offset: _routeOffsets[guid] ?? 0,
            ),
          ),
        ),
      );
      if (_disposed) return;
      final fetched = <MessageModel>[];
      for (final page in pages) {
        final rows = page.rows;
        if (rows == null) continue;
        for (final m in rows) {
          await app.cache.upsertMessage(page.guid, m);
        }
        fetched.addAll(rows);
        _routeOffsets[page.guid] = (_routeOffsets[page.guid] ?? 0) + rows.length;
        if (rows.length < _pageSize) _routesWithMore.remove(page.guid);
      }
      if (_disposed) return;
      final hidden = await app.cache.hiddenMessageGuids();
      if (_disposed) return;
      _col.mergeOlder(fetched.where((m) => !hidden.contains(m.guid)).toList());
      hasMore = _routesWithMore.isNotEmpty;
    } on ApiException {
      // Keep what we have; a transient failure shouldn't break the thread.
    }
    loadingOlder = false;
    _notify();
  }

  Future<void> send(String text) async {
    final trimmed = text.trim();
    final api = app.api;
    if (trimmed.isEmpty || api == null) return;

    final tempId = 'tmp-${DateTime.now().microsecondsSinceEpoch}';
    final optimistic = MessageModel.optimistic(
      tempId: tempId,
      text: trimmed,
      dateCreated: DateTime.now().millisecondsSinceEpoch,
    );
    _col.addPending(optimistic);
    await app.cache.addPending(chatGuid, optimistic);
    state = ThreadState.loaded;
    _notify();

    try {
      final confirmed = await api.sendText(
        chatGuid: chatGuid,
        tempGuid: tempId,
        message: trimmed,
      );
      _col.confirmPending(tempId, confirmed);
      await app.cache.confirmPending(chatGuid, tempId, confirmed);
    } on ApiException catch (e) {
      // AppleScript succeeded but DB confirmation timed out → sentUnconfirmed,
      // NOT failed; a later server row / update will upgrade it.
      _col.setPendingState(
        tempId,
        e.code == 'send_confirmation_timeout'
            ? LocalSendState.sentUnconfirmed
            : LocalSendState.failed,
      );
      await app.cache.setPendingState(
        tempId,
        e.code == 'send_confirmation_timeout'
            ? LocalSendState.sentUnconfirmed
            : LocalSendState.failed,
      );
    }
    _notify();
  }

  Future<void> retry(String tempId) async {
    // C63: failed attachment sends retry with their staged bytes.
    final staged = _pendingAttachmentSends[tempId];
    if (staged != null) {
      _col.removePending(tempId);
      _cleanupAttachmentSend(tempId);
      _notify();
      await sendAttachments([staged]);
      return;
    }
    final removed = _col.removePending(tempId);
    final text = removed?.text;
    if (text == null) return;
    _notify();
    await send(text);
  }

  Future<void> deletePending(String tempId) async {
    final removed = _col.removePending(tempId);
    if (removed == null) return;
    _cleanupAttachmentSend(tempId);
    await app.cache.deletePending(tempId);
    state = _col.isEmpty ? ThreadState.empty : ThreadState.loaded;
    _notify();
  }

  void markRetractedLocally(String guid, {int? dateRetracted}) {
    if (guid.isEmpty) return;
    final applied = _col.applyUnsend(
      guid,
      dateRetracted ?? DateTime.now().millisecondsSinceEpoch,
    );
    if (!applied) return;
    state = ThreadState.loaded;
    _notify();
  }

  // C63 attachment send: each staged file gets an optimistic bubble that
  // renders the local bytes immediately (pinned in the media cache under
  // `local-<tempId>`), with a live upload progress bar; failures mark the
  // bubble failed (tap to retry) instead of only a snackbar. The server can't
  // echo `tempGuid` for attachments (202 optimistic, no send:match), so the
  // pending row reconciles against the confirmed server row by file identity
  // (see shouldReconcileLocalWithServer / attachmentSendMatches).
  bool attachmentSending = false;
  String? attachmentError;

  /// Staged bytes for in-flight/failed attachment sends, kept for retry and
  /// released after the server row reconciles.
  final Map<String, StagedAttachment> _pendingAttachmentSends = {};
  final Map<String, ValueNotifier<double>> _uploadProgress = {};

  /// Upload progress (0..1) for a pending attachment send, or null.
  ValueNotifier<double>? uploadProgressOf(String tempId) =>
      _uploadProgress[tempId];

  /// C21c: BlueBubbles-style multi-select, conservative send path — each staged
  /// attachment is sent as its own request. The grouped AppleScript send path is
  /// fragile on some Messages setups, so the UI may stage several files while
  /// the transport stays one-file-at-a-time. One catch-up after the sequence
  /// pulls the real rows (they also arrive via message:new).
  Future<void> sendAttachments(List<StagedAttachment> items) async {
    final api = app.api;
    if (api == null || attachmentSending || items.isEmpty) return;
    attachmentSending = true;
    attachmentError = null;
    _notify();

    // C71: stage EVERY bubble up front — a multi-file batch shows all its
    // pending bubbles (with progress rings) immediately. Uploads still run
    // one at a time below; previously the next bubble only appeared after
    // the previous upload finished, so "only the first image showed".
    final queue =
        <({String tempId, StagedAttachment item, MessageModel optimistic})>[];
    final baseMs = DateTime.now().millisecondsSinceEpoch;
    final baseMicro = DateTime.now().microsecondsSinceEpoch;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      // Index suffix keeps ids unique and preserves the staged order.
      final tempId = 'tmp-att-${baseMicro + i}';
      final optimistic = MessageModel.optimisticAttachment(
        tempId: tempId,
        filename: item.filename,
        totalBytes: item.bytes.length,
        dateCreated: baseMs + i,
      );
      _pendingAttachmentSends[tempId] = item;
      _uploadProgress[tempId] = ValueNotifier<double>(0);
      // C66: *pin* the local bytes (non-evictable, synchronous) so the bubble
      // renders instantly — a pending guid must never fall into the
      // spinner/network path. Unpinned in _cleanupAttachmentSend.
      MediaCache.instance.pinLocal(
        MessageModel.localAttachmentGuid(tempId),
        item.bytes,
      );
      _col.addPending(optimistic);
      queue.add((tempId: tempId, item: item, optimistic: optimistic));
    }
    state = ThreadState.loaded;
    _notify();

    var anySent = false;
    for (final staged in queue) {
      final tempId = staged.tempId;
      final item = staged.item;
      final optimistic = staged.optimistic;
      // The user may have deleted this pending while it was queued.
      if (_col.pendingByTempId(tempId) == null) continue;
      final progress = _uploadProgress[tempId];

      try {
        final sentFilename = await api.sendAttachment(
          chatGuid: chatGuid,
          tempGuid: tempId,
          bytes: item.bytes,
          filename: item.filename,
          isAudioMessage: item.isAudioMessage,
          onSendProgress: (sent, total) {
            if (total > 0) progress?.value = sent / total;
          },
        );
        anySent = true;
        // Upload done; the row is now "sent, awaiting the server row". If the
        // server renamed the file (voice conversion), match on the new name.
        var updated = optimistic.copyWith(
          localState: LocalSendState.sentUnconfirmed,
        );
        if (sentFilename != null &&
            sentFilename.isNotEmpty &&
            sentFilename != item.filename) {
          updated = updated.copyWith(
            attachments: [
              for (final a in updated.attachments)
                AttachmentModel(
                  guid: a.guid,
                  downloadUrl: a.downloadUrl,
                  filename: sentFilename,
                  transferName: sentFilename,
                  totalBytes: a.totalBytes,
                  attachmentKind: a.attachmentKind,
                  displayKind: a.displayKind,
                  isPreviewableImage: a.isPreviewableImage,
                ),
            ],
          );
        }
        _col.replacePending(tempId, updated);
        _notify();
      } on ApiException catch (e) {
        // C70: keep sending the remaining files — the failed one keeps its
        // failed bubble (tap to retry) and the batch continues.
        attachmentError = e.friendly;
        _col.setPendingState(tempId, LocalSendState.failed);
        _notify();
      } catch (e) {
        attachmentError = '$e';
        _col.setPendingState(tempId, LocalSendState.failed);
        _notify();
      }
    }

    attachmentSending = false;
    _notify();
    if (anySent) {
      // One catch-up after the sequence; the rows also arrive via message:new.
      await app.catchUp(reason: 'attachment_sent', minInterval: Duration.zero);
    }
  }

  /// C70: confirmed images are server-authoritative. Reconciliation lives
  /// solely in MessageCollection; this sweep just releases staged bytes,
  /// progress notifiers, and pinned local bytes once a pending row is gone.
  /// Failed pendings keep their row (and bytes) for retry.
  void _sweepAttachmentSendBookkeeping() {
    if (_pendingAttachmentSends.isEmpty) return;
    for (final tempId in _pendingAttachmentSends.keys.toList()) {
      if (_col.pendingByTempId(tempId) == null) {
        _cleanupAttachmentSend(tempId);
      }
    }
  }

  void _cleanupAttachmentSend(String tempId) {
    _pendingAttachmentSends.remove(tempId);
    _uploadProgress.remove(tempId)?.dispose();
    MediaCache.instance.unpinLocal(MessageModel.localAttachmentGuid(tempId));
  }

  void clearAttachmentError() {
    if (attachmentError == null) return;
    attachmentError = null;
    _notify();
  }

  void _onWsEvent(WsEvent e) {
    switch (e.type) {
      case 'send:match':
        final tempId = e.data['tempGuid'] as String?;
        final msg = e.data['message'];
        if (tempId != null &&
            msg is Map<String, dynamic> &&
            _col.pendingByTempId(tempId) != null) {
          final confirmed = MessageModel.fromJson(msg);
          _col.confirmPending(tempId, confirmed);
          unawaited(app.cache.confirmPending(chatGuid, tempId, confirmed));
          unawaited(app.markRealtimeEventApplied(e));
          _notify();
        }
        break;
      case 'send:error':
        final tempId = e.data['tempGuid'] as String?;
        final code = e.data['code'] as String?;
        final recoverable =
            e.data['recoverable'] == true ||
            e.data['state'] == 'sent_unconfirmed' ||
            code == 'send_confirmation_timeout';
        if (tempId != null && _col.pendingByTempId(tempId) != null) {
          _col.setPendingState(
            tempId,
            recoverable
                ? LocalSendState.sentUnconfirmed
                : LocalSendState.failed,
          );
          unawaited(
            app.cache.setPendingState(
              tempId,
              recoverable
                  ? LocalSendState.sentUnconfirmed
                  : LocalSendState.failed,
            ),
          );
          _notify();
        }
        break;
      case 'message:new':
      case 'message:update':
        final msg = rt.messageFromWsEvent(e);
        if (msg == null || msg.chatGuid == null) {
          unawaited(
            app.recordRealtimeFallback(
              missingChatGuid: msg != null && msg.chatGuid == null,
              malformed: msg == null,
            ),
          );
          _scheduleReload();
          break;
        }
        if (threadGuids.contains(msg.chatGuid)) {
          if (rt.isReactionMessage(msg)) {
            final target = rt.reactionTargetGuid(msg);
            final applied =
                target != null &&
                _col.applyReactionEvent(
                  targetGuid: target,
                  reaction: ReactionModel(
                    type: rt.reactionType(msg),
                    fromHandle: msg.handleId,
                    isFromMe: msg.isFromMe,
                    eventGuid: msg.guid,
                    createdAt: msg.dateCreated,
                  ),
                  add: rt.isReactionAdd(msg),
                );
            unawaited(
              app.cache.applyReactionEvent(msg.chatGuid ?? chatGuid, msg).then((
                ok,
              ) {
                if (ok) return app.markRealtimeEventApplied(e);
                return app.recordRealtimeFallback();
              }),
            );
            if (!applied) _scheduleReload();
          } else {
            _col.upsertServer(msg);
            _sweepAttachmentSendBookkeeping();
            unawaited(
              app.cache
                  .upsertMessage(msg.chatGuid ?? chatGuid, msg)
                  .then(
                    (_) => app.markRealtimeEventApplied(e),
                    onError: (_) => app.recordRealtimeFallback(),
                  ),
            );
          }
          state = ThreadState.loaded;
          _notify();
        }
        break;
      case 'message:unsend':
        final eventChat = rt.chatGuidFromWsEvent(e);
        if (eventChat == null) {
          unawaited(app.recordRealtimeFallback(missingChatGuid: true));
          _scheduleReload();
          break;
        }
        if (threadGuids.contains(eventChat)) {
          final guid = e.data['guid'] as String?;
          final dateRetracted = _asInt(e.data['dateRetracted']);
          if (guid == null || !_col.applyUnsend(guid, dateRetracted)) {
            unawaited(app.recordRealtimeFallback(malformed: guid == null));
            _scheduleReload();
          } else {
            unawaited(
              app.cache
                  .applyUnsend(eventChat, guid, dateRetracted)
                  .then((_) => app.markRealtimeEventApplied(e)),
            );
            _notify();
          }
        }
        break;
      default:
        break;
    }
  }

  void _scheduleReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 400), () {
      load(showSpinner: false);
    });
  }

  String _humanize(ApiException e) {
    switch (e.code) {
      case 'unauthorized':
        return 'Token rejected (401). Re-pair with the server.';
      case 'timeout':
        return 'Timed out loading messages.';
      case 'network_error':
        return 'Could not reach the server.';
      case 'not_found':
        return 'This chat was not found on the server.';
      default:
        return e.message;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _reloadDebounce?.cancel();
    _wsSub?.cancel();
    _deltaSub?.cancel();
    for (final n in _uploadProgress.values) {
      n.dispose();
    }
    _uploadProgress.clear();
    super.dispose();
  }
}

MessageModel? messageFromWsEvent(WsEvent e) => rt.messageFromWsEvent(e);

String? chatGuidFromWsEvent(WsEvent e) => rt.chatGuidFromWsEvent(e);

int? _asInt(Object? v) => v is num ? v.toInt() : null;
