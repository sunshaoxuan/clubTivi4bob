import 'package:flutter/foundation.dart';

/// New installations start with user-owned sources on every platform.
abstract final class UserSourcePolicy {
  static bool get enabled =>
      const bool.fromEnvironment('BOBTV_USER_SOURCES_ONLY', defaultValue: true) ||
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);
}
