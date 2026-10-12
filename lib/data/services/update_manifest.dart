import 'dart:convert';

class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.archive,
    required this.sha256,
    required this.bytes,
    this.signature,
    this.installer,
  });

  final String version;
  final Uri archive;
  final String sha256;
  final int bytes;
  final String? signature;
  final WindowsInstallerPackage? installer;

  static final _versionPattern = RegExp(r'^\d+\.\d+\.\d+\+\d+$');
  static final _hashPattern = RegExp(r'^[a-fA-F0-9]{64}$');

  static UpdateManifest parse(
    String content,
    Uri manifestUri, {
    String extension = '.zip',
  }) {
    if (!const {'.zip', '.apk'}.contains(extension)) {
      throw const FormatException('Unsupported update package type');
    }
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic> || decoded['schema'] != 1) {
      throw const FormatException('Unsupported update manifest');
    }
    final version = decoded['version'];
    final archiveText = decoded['archive'];
    final hash = decoded['sha256'];
    final bytes = decoded['bytes'];
    final signature = decoded['signature'];
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
    if (signature != null &&
        (signature is! String ||
            !RegExp(r'^[A-Za-z0-9+/]{80,120}={0,2}$').hasMatch(signature))) {
      throw const FormatException('Invalid update signature');
    }
    final archive = Uri.tryParse(archiveText);
    if (archive == null ||
        archive.scheme != 'https' ||
        archive.host != manifestUri.host ||
        archive.hasPort ||
        archive.userInfo.isNotEmpty ||
        archive.hasQuery ||
        archive.hasFragment ||
        !archive.path.startsWith('/updates/') ||
        !archive.path.endsWith(extension)) {
      throw const FormatException('Update archive must be on the mirror');
    }
    return UpdateManifest(
      version: version,
      archive: archive,
      sha256: hash.toLowerCase(),
      bytes: bytes,
      signature: signature as String?,
      installer: decoded['installer'] == null
          ? null
          : WindowsInstallerPackage.parse(
              decoded['installer'],
              manifestUri,
              version,
            ),
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

/// Publisher-signed Setup for protected Windows installations. This signature
/// verifies our update payload; it does not replace Windows Authenticode trust.
class WindowsInstallerPackage {
  const WindowsInstallerPackage({
    required this.archive,
    required this.sha256,
    required this.bytes,
    required this.signature,
  });
  final Uri archive;
  final String sha256;
  final int bytes;
  final String signature;

  static WindowsInstallerPackage parse(
    Object? value,
    Uri manifestUri,
    String version,
  ) {
    if (value is! Map ||
        value.keys.toSet().difference({
          'archive',
          'sha256',
          'bytes',
          'signature',
        }).isNotEmpty) {
      throw const FormatException('Invalid Windows installer metadata');
    }
    final url = value['archive'];
    final hash = value['sha256'];
    final bytes = value['bytes'];
    final signature = value['signature'];
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != manifestUri.host ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.path.startsWith('/updates/files/') ||
        !RegExp(
          '^BobTV-${RegExp.escape(version)}-windows-(x64|arm64)-Setup\\.exe\$',
        ).hasMatch(uri.pathSegments.last) ||
        hash is! String ||
        !UpdateManifest._hashPattern.hasMatch(hash) ||
        bytes is! int ||
        bytes < 1000000 ||
        bytes > 2000000000 ||
        signature is! String ||
        !RegExp(r'^[A-Za-z0-9+/]{80,120}={0,2}$').hasMatch(signature)) {
      throw const FormatException('Invalid Windows installer metadata');
    }
    for (final platform in ['windows-x64', 'windows-arm64']) {
      if (manifestUri.pathSegments.contains(platform) &&
          !uri.pathSegments.last.endsWith('$platform-Setup.exe')) {
        throw const FormatException('Installer architecture mismatch');
      }
    }
    return WindowsInstallerPackage(
      archive: uri,
      sha256: hash.toLowerCase(),
      bytes: bytes,
      signature: signature,
    );
  }
}
