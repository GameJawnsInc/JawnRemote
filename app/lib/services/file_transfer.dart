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
  }

  static const int _chunk = 64 * 1024;
  static const int _window = 8; // max in-flight (unacked) chunks

  // SAF file access lives in the app's own MainActivity (no plugin needed).
  static const MethodChannel _ch = MethodChannel('jawnremote/files');
  String? _cacheDirPath;

  Future<String> _tempDir() async {
    _cacheDirPath ??= await _ch.invokeMethod<String>('cacheDir') ?? '.';
    return _cacheDirPath!;
  }

  /// Opens the system document picker. Returns {path, name, size} or null.
  Future<Map?> pickFile() async {
    final r = await _ch.invokeMethod('pickFile');
    return r is Map ? r : null;
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
  Completer<void>? _ackTick; // fires whenever an ack advances the window
  Completer<bool>? _doneWaiter; // fires on the final filedone

  bool get isSending => txState == TxState.sending;
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

  Future<void> sendFile(String path, String name) async {
    if (txState == TxState.sending) return; // one upload at a time
    txName = name;
    txTotal = 0;
    txSent = 0;
    txError = '';
    txState = TxState.sending;
    notifyListeners();
    // Opening the system file picker backgrounds the app, which can briefly
    // drop the socket. Give the auto-reconnect up to ~10 s to come back before
    // giving up, so the first send after picking doesn't fail spuriously.
    for (var i = 0; i < 50 && !client.isConnected; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (!client.isConnected) {
      _txFail('Not connected — try again.');
      return;
    }
    final file = File(path);
    txTotal = await file.length();
    _txId = _newId();
    _txAcked = 0;
    _txCanceled = false;
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
      client.fileEnd(_txId!, ds.value!.toString());
      final ok = await _doneWaiter!.future
          .timeout(const Duration(seconds: 30), onTimeout: () => false);
      if (ok) {
        txSent = txTotal;
        txState = TxState.done;
      } else {
        _txFail('The PC didn\'t confirm the file.');
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
    }
    notifyListeners();
  }

  Future<void> _awaitWindow(int i) async {
    while (!_txCanceled && (i - _txAcked) >= _window) {
      _ackTick = Completer<void>();
      await _ackTick!.future.timeout(const Duration(seconds: 20),
          onTimeout: () => throw 'Transfer stalled — connection lost?');
    }
    if (_txCanceled) throw const _Canceled();
  }

  void cancelOutgoing() {
    if (txState != TxState.sending) return;
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

  Future<void> _beginIncoming(Map msg) async {
    await _closeRxSink();
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

  @override
  void dispose() {
    if (identical(client.onFileFrame, _onFrame)) client.onFileFrame = null;
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
