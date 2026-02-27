import 'dart:typed_data';

/// In-memory ring buffer that stores raw terminal output bytes.
/// When the UI reattaches (e.g. after app reopen), the buffered data
/// is replayed into a fresh Terminal widget to reconstruct visual state.
class TerminalReplayBuffer {
  static const int defaultCapacity = 256 * 1024; // 256 KB

  final int capacity;
  late final Uint8List _buffer;
  int _writePos = 0;
  int _length = 0;

  TerminalReplayBuffer({this.capacity = defaultCapacity}) {
    _buffer = Uint8List(capacity);
  }

  /// Append bytes to the ring buffer.
  void write(List<int> data) {
    for (final byte in data) {
      _buffer[_writePos] = byte;
      _writePos = (_writePos + 1) % capacity;
      if (_length < capacity) _length++;
    }
  }

  /// Read all buffered bytes in order (oldest first).
  Uint8List read() {
    if (_length == 0) return Uint8List(0);
    if (_length < capacity) {
      // Buffer hasn't wrapped yet
      return Uint8List.fromList(_buffer.sublist(0, _length));
    }
    // Buffer has wrapped: read from writePos to end, then start to writePos
    final result = Uint8List(_length);
    final firstPart = capacity - _writePos;
    result.setRange(0, firstPart, _buffer, _writePos);
    result.setRange(firstPart, _length, _buffer, 0);
    return result;
  }

  int get length => _length;

  void clear() {
    _writePos = 0;
    _length = 0;
  }
}
