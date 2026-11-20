import 'package:flutter/foundation.dart';

/// Store builds start with user-owned sources. Desktop catalog mode remains
/// available in existing desktop distributions.
abstract final class UserSourcePolicy {
  static bool get enabled =>
      const bool.fromEnvironment('BOBTV_USER_SOURCES_ONLY') ||
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);
}
