import 'dart:io';
import 'dart:typed_data';

/// Select updates from the running EXE, even when an x64 app runs under Prism.
class WindowsBinaryArchitecture {
  static String fromHeader(Uint8List bytes) {
    if (bytes.length < 64 || bytes[0] != 0x4d || bytes[1] != 0x5a) {
      throw const FormatException('Invalid Windows executable');
    }
    final data = ByteData.sublistView(bytes);
    final offset = data.getUint32(0x3c, Endian.little);
    if (offset < 64 ||
        offset > 1048576 ||
        offset + 6 > bytes.length ||
        data.getUint32(offset, Endian.little) != 0x00004550) {
      throw const FormatException('Invalid PE header');
    }
    return switch (data.getUint16(offset + 4, Endian.little)) {
      0x8664 => 'x64',
      0xaa64 => 'arm64',
      _ => throw const FormatException('Unsupported Windows architecture'),
    };
  }

  static Future<String> read(File executable) async {
    final file = await executable.open();
    try {
      final dos = await file.read(64);
      if (dos.length != 64) throw const FormatException('Truncated executable');
      final offset = ByteData.sublistView(dos).getUint32(0x3c, Endian.little);
      if (offset < 64 || offset > 1048576) {
        throw const FormatException('Invalid PE offset');
      }
      await file.setPosition(0);
      return fromHeader(await file.read(offset + 6));
    } finally {
      await file.close();
    }
  }
}
