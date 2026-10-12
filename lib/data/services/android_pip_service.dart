import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidPipService {
  AndroidPipService._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pipChanged') active.value = call.arguments == true;
    });
  }
  static final instance = AndroidPipService._();
  static const _channel = MethodChannel('bobtv/device');
  final active = ValueNotifier(false);
  Future<bool> enter({required int width, required int height}) async =>
      await _channel.invokeMethod<bool>('enterPip', {
        'width': width,
        'height': height,
      }) ??
      false;
}
