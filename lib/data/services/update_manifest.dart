import 'dart:convert';

class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.archive,
    required this.sha256,
    required this.bytes,
  });

  final String version;
  final Uri archive;
  final String sha256;
  final int bytes;

  static final _versionPattern = RegExp(r'^\d+\.\d+\.\d+\+\d+$');
  static final _hashPattern = RegExp(r'^[a-fA-F0-9]{64}$');

  static UpdateManifest parse(String content, Uri manifestUri) {
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic> || decoded['schema'] != 1) {
      throw const FormatException('Unsupported update manifest');
    }
    final version = decoded['version'];
    final archiveText = decoded['archive'];
    final hash = decoded['sha256'];
    final bytes = decoded['bytes'];
    if (version is! String ||
        !_versionPattern.hasMatch(version) ||
        archiveText is! String ||
        hash is! String ||
        !_hashPattern.hasMatch(hash) ||
        bytes is! int ||
        bytes < 1000000 ||
        bytes > 2000000000) {
      throw const FormatException('Invalid update manifest fields');
    }
    final archive = Uri.tryParse(archiveText);
    if (archive == null ||
        archive.scheme != 'https' ||
        archive.host != manifestUri.host ||
        archive.userInfo.isNotEmpty ||
        archive.hasQuery ||
        archive.hasFragment ||
        !archive.path.startsWith('/updates/') ||
        !archive.path.endsWith('.zip')) {
      throw const FormatException('Update archive must be on the mirror');
    }
    return UpdateManifest(
      version: version,
      archive: archive,
      sha256: hash.toLowerCase(),
      bytes: bytes,
    );
  }

  static int compareVersions(String left, String right) {
    List<int> parts(String text) {
      if (!_versionPattern.hasMatch(text)) {
        throw const FormatException('Invalid BobTV version');
      }
      return text.split(RegExp(r'[.+]')).map(int.parse).toList();
    }

    final a = parts(left);
    final b = parts(right);
    for (var i = 0; i < a.length; i++) {
      final value = a[i].compareTo(b[i]);
      if (value != 0) return value;
    }
    return 0;
  }
}
