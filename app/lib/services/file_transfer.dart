import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'remote_client.dart';

enum TxState { idle, sending, done, error }

/// A file the PC pushed to us, staged in the temp dir and ready to save/share.
class IncomingFile {
  final String name;
  final String path;
  final int size;
  IncomingFile(this.name, this.path, this.size);
}

/// Drives chunked file transfer over [RemoteClient] in both directions.
///
/// Outgoing (phone -> PC): the file is streamed in 64 KB chunks, each base64'd
/// into a `filedat` frame, with a small in-flight window so we never outrun the
/// PC's `fileack`s (which also keep the link's inbound side busy, so the
/// heartbeat won't kill a long upload). A streaming SHA-256 rides along in the
/// closing `fileend` for end-to-end integrity.
///
/// Incoming (PC -> phone): frames are processed strictly in order and streamed
/// to a temp file (never held in RAM); on completion the file is verified and
/// surfaced in [received] for the user to Save (system picker -> no permission).
///
/// Lives for the app's lifetime (in AppScope) so a PC push is caught even when
/// the Files screen isn't open.
class FileTransfer extends ChangeNotifier {
  final RemoteClient client;
  FileTransfer(this.client) {
    client.onFileFrame = _onFrame;
    _wasConnected = client.isConnected;
    client.addListener(_onClientState);
    _sweepCache();
  }

  static const int _chunk = 64 * 1024;
  static const int _window = 8; // max in-flight (unacked) chunks
  static const int _maxBytes = 2 * 1024 * 1024 * 1024; // the PC's 2 GB cap

  // SAF file access lives in the app's own MainActivity (no plugin needed).
  static const MethodChannel _ch = MethodChannel('jawnremote/files');
  String? _cacheDirPath;

  Future<String> _tempDir() async {
    _cacheDirPath ??= await _ch.invokeMethod<String>('cacheDir') ?? '.';
    return _cacheDirPath!;
  }

  /// Deletes our own cache files (pick_* upload copies, jawn_* received
  /// files) older than a day. Nothing this run still uses is that old, and
  /// earlier runs' received files are no longer reachable from [received].
  Future<void> _sweepCache() async {
    try {
      final path = await _tempDir();
      if (path == '.') return;
      final cutoff = DateTime.now().subtract(const Duration(hours: 24));
      await for (final e in Directory(path).list(followLinks: false)) {
        final n = e.path.split('/').last;
        if (e is! File || !(n.startsWith('pick_') || n.startsWith('jawn_'))) {
          continue;
        }
        try {
          if ((await e.lastModified()).isBefore(cutoff)) await e.delete();
        } catch (_) {}
      }
    } catch (_) {
      // No native side (tests / other platforms): nothing to sweep.
    }
  }

  /// True while [pickFile] runs: the system picker is open, then the picked
  /// document is copied into our cache (which takes a while for a big video).
  bool preparing = false;

  /// Opens the system document picker. Returns {path, name, size} or null.
  Future<Map?> pickFile() async {
    if (preparing) return null; // one pick at a time
    preparing = true;
    notifyListeners();
    try {
      final r = await _ch.invokeMethod('pickFile');
      return r is Map ? r : null;
    } finally {
      preparing = false;
      notifyListeners();
    }
  }

  // ---- outgoing state ----
  TxState txState = TxState.idle;
  String txName = '';
  int txSent = 0; // acked bytes (approx, for the progress bar)
  int txTotal = 0;
  String txError = '';
  String? _txId;
  int _txAcked = 0; // number of chunks acked so far
  bool _txCanceled = false;
  bool _txLinkLost = false; // the link dropped mid-upload
  String? _txRejected; // the PC's err when it refused the upload
  bool _txFinishing = false; // fileend sent: too late to cancel
  Completer<void>? _ackTick; // fires whenever an ack advances the window
  Completer<bool>? _doneWaiter; // fires on the final filedone
  bool _wasConnected = false;

  bool get isSending => txState == TxState.sending;

  /// False once the upload can no longer be canceled (waiting for the PC's
  /// final confirmation).
  bool get canCancel => txState == TxState.sending && !_txFinishing;
  double get txProgress =>
      txTotal == 0 ? 0 : (txSent / txTotal).clamp(0.0, 1.0);

  // ---- incoming state ----
  final List<IncomingFile> received = [];
  String rxName = '';
  int rxReceived = 0;
  int rxTotal = 0;
  String? _rxId;
  String? _rxPath;
  IOSink? _rxSink;
  int _rxWritten = 0;
  _DigestSink? _rxDs;
  ByteConversionSink? _rxInner;
  Future<void> _rxChain = Future.value(); // serializes inbound frames in order

  bool get isReceiving => _rxId != null;
  double get rxProgress =>
      rxTotal == 0 ? 0 : (rxReceived / rxTotal).clamp(0.0, 1.0);

  String _newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  // ===================== outgoing (phone -> PC) =====================

  /// Upload [path] to the PC as [name]. A `pick_*` source (our own picker
  /// copy) is deleted afterwards, whatever the outcome.
  Future<void> sendFile(String path, String name) async {
    try {
      await _sendFile(path, name);
    } finally {
      if (path.split('/').last.startsWith('pick_')) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _sendFile(String path, String name) async {
    if (txState == TxState.sending) return; // one upload at a time
    txName = name;
    txTotal = 0;
    txSent = 0;
    txError = '';
    _txId = null;
    _txCanceled = false;
    _txFinishing = false;
    txState = TxState.sending;
    notifyListeners();
    // Opening the system file picker backgrounds the app, which can briefly
    // drop the socket. Give the auto-reconnect up to ~10 s to come back before
    // giving up, so the first send after picking doesn't fail spuriously.
    for (var i = 0; i < 50 && !client.isConnected && !_txCanceled; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (_txCanceled) {
      _txFail('Canceled.');
      return;
    }
    if (!client.isConnected) {
      _txFail('Not connected — try again.');
      return;
    }
    // From here a link drop fails the upload (see _onClientState).
    _txId = _newId();
    _txAcked = 0;
    _txLinkLost = false;
    _txRejected = null;
    final file = File(path);
    try {
      txTotal = await file.length();
    } catch (_) {
      _txId = null;
      _txFail('Couldn\'t read the file.');
      return;
    }
    if (txTotal > _maxBytes) {
      _txId = null;
      _txFail('Files over 2 GB can\'t be sent.');
      return;
    }
    _doneWaiter = Completer<bool>();
    notifyListeners();

    final ds = _DigestSink();
    final inner = sha256.startChunkedConversion(ds);
    try {
      client.fileBegin(_txId!, name, txTotal);
      int i = 0;
      final pending = <int>[];
      await for (final block in file.openRead()) {
        if (_txCanceled) throw const _Canceled();
        _checkTxAbort();
        pending.addAll(block);
        while (pending.length >= _chunk) {
          final chunk = Uint8List.fromList(pending.sublist(0, _chunk));
          pending.removeRange(0, _chunk);
          await _awaitWindow(i);
          inner.add(chunk);
          client.fileData(_txId!, i, base64.encode(chunk));
          i++;
        }
      }
      if (pending.isNotEmpty) {
        await _awaitWindow(i);
        final chunk = Uint8List.fromList(pending);
        inner.add(chunk);
        client.fileData(_txId!, i, base64.encode(chunk));
        i++;
      }
      inner.close();
      // Last chance to honor a cancel / link drop (an empty file never hit a
      // per-chunk check).
      if (_txCanceled) throw const _Canceled();
      _checkTxAbort();
      // The PC saves the file as soon as it gets fileend; a cancel after this
      // point would claim a cancel for a file that's already there.
      _txFinishing = true;
      notifyListeners();
      client.fileEnd(_txId!, ds.value!.toString());
      final ok = await _doneWaiter!.future
          .timeout(const Duration(seconds: 30), onTimeout: () => false);
      if (ok) {
        txSent = txTotal;
        txState = TxState.done;
      } else {
        _txFail(_txAbortReason ?? 'The PC didn\'t confirm the file.');
        return;
      }
    } on _Canceled {
      client.fileAbort(_txId ?? '');
      _txFail('Canceled.');
      return;
    } catch (e) {
      client.fileAbort(_txId ?? '');
      _txFail(e is String ? e : 'Transfer failed — connection lost?');
      return;
    } finally {
      _ackTick = null;
      _doneWaiter = null;
      _txId = null;
    }
    notifyListeners();
  }

  /// Why the current upload can't go on (link dropped / the PC refused it),
  /// or null.
  String? get _txAbortReason {
    if (_txLinkLost) return 'Connection lost — try again.';
    final err = _txRejected;
    if (err == null) return null;
    return err.isEmpty
        ? 'The PC couldn\'t save the file.'
        : 'The PC couldn\'t save the file: $err';
  }

  void _checkTxAbort() {
    final why = _txAbortReason;
    if (why != null) throw why; // a String: shown as-is by sendFile's catch
  }

  Future<void> _awaitWindow(int i) async {
    while (!_txCanceled &&
        _txAbortReason == null &&
        (i - _txAcked) >= _window) {
      _ackTick = Completer<void>();
      await _ackTick!.future.timeout(const Duration(seconds: 20),
          onTimeout: () => throw 'Transfer stalled — connection lost?');
    }
    if (_txCanceled) throw const _Canceled();
    _checkTxAbort();
  }

  void cancelOutgoing() {
    if (!canCancel) return;
    _txCanceled = true;
    _ackTick?.complete();
    _ackTick = null;
  }

  void clearOutgoing() {
    if (txState == TxState.sending) return;
    txState = TxState.idle;
    txName = '';
    txSent = 0;
    txTotal = 0;
    txError = '';
    notifyListeners();
  }

  void _txFail(String e) {
    txState = TxState.error;
    txError = e;
    notifyListeners();
  }

  // ===================== incoming (PC -> phone) =====================

  void _onFrame(Map<String, dynamic> msg) {
    switch (msg['t']) {
      case 'fileack':
        if (msg['id'] == _txId) {
          final i = (msg['i'] as num?)?.toInt() ?? -1;
          if (i >= 0) {
            if (i + 1 > _txAcked) _txAcked = i + 1;
            txSent = (_txAcked * _chunk).clamp(0, txTotal).toInt();
            notifyListeners();
          }
          _ackTick?.complete();
          _ackTick = null;
        }
        break;
      case 'filedone':
        if (msg['id'] == _txId && !(_doneWaiter?.isCompleted ?? true)) {
          if (msg['ok'] != true) {
            // The PC gave up (disk full, too big, …) — possibly mid-upload,
            // so stop streaming now rather than stalling on missing acks.
            _txRejected ??= (msg['err'] ?? '').toString();
            _ackTick?.complete();
            _ackTick = null;
          }
          _doneWaiter?.complete(msg['ok'] == true);
        }
        break;
      case 'filebeg':
        _enqueueRx(() => _beginIncoming(msg));
        break;
      case 'filedat':
        _enqueueRx(() => _incomingData(msg));
        break;
      case 'fileend':
        _enqueueRx(() => _endIncoming(msg));
        break;
      case 'fileabort':
        _enqueueRx(_abortIncoming);
        break;
    }
  }

  void _enqueueRx(Future<void> Function() task) {
    _rxChain = _rxChain.then((_) => task()).catchError((_) {});
  }

  /// A transfer belongs to one server session: when the link drops, the PC's
  /// side of it is gone, so stop waiting for frames that will never come.
  void _onClientState() {
    final now = client.isConnected;
    if (_wasConnected && !now) {
      // Queued behind the old session's frames, ahead of any new ones.
      _enqueueRx(() async {
        if (_rxId != null) await _abortIncoming();
      });
      if (txState == TxState.sending && _txId != null) {
        _txLinkLost = true;
        _ackTick?.complete();
        _ackTick = null;
        final d = _doneWaiter;
        if (d != null && !d.isCompleted) d.complete(false);
      }
    }
    _wasConnected = now;
  }

  Future<void> _beginIncoming(Map msg) async {
    await _deleteRx(); // drops a previous push that never finished
    _rxId = msg['id']?.toString();
    rxName = (msg['name'] ?? 'file').toString();
    _rxWritten = 0;
    rxReceived = 0;
    rxTotal = (msg['size'] as num?)?.toInt() ?? 0;
    _rxDs = _DigestSink();
    _rxInner = sha256.startChunkedConversion(_rxDs!);
    final dir = await _tempDir();
    final safe = rxName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    _rxPath = '$dir/jawn_${DateTime.now().microsecondsSinceEpoch}_$safe';
    _rxSink = File(_rxPath!).openWrite();
    notifyListeners();
  }

  Future<void> _incomingData(Map msg) async {
    if (msg['id'] != _rxId || _rxSink == null) return;
    final i = (msg['i'] as num?)?.toInt() ?? -1;
    try {
      final bytes = base64.decode((msg['b'] ?? '').toString());
      _rxSink!.add(bytes);
      _rxInner!.add(bytes);
      _rxWritten += bytes.length;
      rxReceived = _rxWritten;
      client.fileAck(_rxId!, i);
      notifyListeners();
    } catch (_) {
      final id = _rxId ?? '';
      await _deleteRx();
      client.fileDone(id, false, err: 'decode error');
      _rxId = null;
      rxName = '';
      rxTotal = 0;
      rxReceived = 0;
      notifyListeners();
    }
  }

  Future<void> _endIncoming(Map msg) async {
    if (msg['id'] != _rxId) return;
    final id = _rxId!;
    try {
      await _rxSink!.flush();
      await _rxSink!.close();
      _rxSink = null;
      _rxInner!.close();
      final sha = _rxDs!.value!.toString();
      final wantSha = (msg['sha'] ?? '').toString().toLowerCase();
      final sizeOk = rxTotal == 0 || _rxWritten == rxTotal;
      final shaOk = wantSha.isEmpty || wantSha == sha;
      if (sizeOk && shaOk) {
        received.insert(0, IncomingFile(rxName, _rxPath!, _rxWritten));
        client.fileDone(id, true, path: _rxPath);
      } else {
        await _deleteRx();
        client.fileDone(id, false,
            err: shaOk ? 'size mismatch' : 'checksum mismatch');
      }
    } catch (e) {
      await _deleteRx();
      client.fileDone(id, false, err: e.toString());
    } finally {
      _rxId = null;
      rxName = '';
      rxTotal = 0;
      rxReceived = 0;
      _rxPath = null;
      notifyListeners();
    }
  }

  Future<void> _abortIncoming() async {
    await _deleteRx();
    _rxId = null;
    rxName = '';
    rxTotal = 0;
    rxReceived = 0;
    notifyListeners();
  }

  Future<void> _closeRxSink() async {
    try {
      await _rxSink?.flush();
      await _rxSink?.close();
    } catch (_) {}
    _rxSink = null;
  }

  Future<void> _deleteRx() async {
    await _closeRxSink();
    try {
      if (_rxPath != null) {
        final f = File(_rxPath!);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
    _rxPath = null;
  }

  /// Copy a received file out to a user-chosen location via the system picker
  /// (Storage Access Framework — no storage permission required).
  Future<bool> saveReceived(IncomingFile f) async {
    try {
      final ok = await _ch
          .invokeMethod<bool>('saveFile', {'src': f.path, 'name': f.name});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Open a received file with the phone's default app for that type.
  Future<bool> openReceived(IncomingFile f) async {
    try {
      final ok = await _ch.invokeMethod<bool>('openFile', {'path': f.path});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    if (identical(client.onFileFrame, _onFrame)) client.onFileFrame = null;
    client.removeListener(_onClientState);
    super.dispose();
  }
}

/// Collects the final [Digest] from a streaming SHA-256 conversion.
class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class _Canceled implements Exception {
  const _Canceled();
}
