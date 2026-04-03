import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// API giao tiếp với app Android host (`SafeFlutterActivity` + `CccdFlutterModule`).
///
/// - [getLaunchArgs]: đọc extra Intent (cccd, dob, doe).
/// - [finishWithJson]: gửi **chuỗi JSON thuần** qua MethodChannel → host `putExtra(flutter_result)` → `setResult` → `finish()`.
///   Payload gồm `cccd`, `dob`, `doe`, `dg1`, `dg2ImagePath`, `readDurationSeconds` (giây), ...
///   (Không gửi ảnh base64 mặc định — tránh TransactionTooLarge.)
class CccdHostBridge {
  CccdHostBridge._();

  static const channelName = 'com.mta.pos/host_bridge';
  static final MethodChannel _channel = MethodChannel(channelName);

  static const methodGetLaunchArgs = 'getLaunchArgs';
  static const methodFinishWithResult = 'finishWithResult';

  static const extraResultJson = 'flutter_result';

  static Future<Map<String, dynamic>?> getLaunchArgs() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final raw = await _channel.invokeMethod<dynamic>(methodGetLaunchArgs);
      if (raw is Map) return Map<String, dynamic>.from(raw);
    } catch (e, st) {
      debugPrint('CccdHostBridge.getLaunchArgs: $e\n$st');
    }
    return null;
  }

  static Future<bool> finishWithJson(Map<String, dynamic> payload) async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final json = jsonEncode(payload);
      await _channel.invokeMethod<void>(
        methodFinishWithResult,
        <String, dynamic>{extraResultJson: json},
      );
      return true;
    } on PlatformException catch (e, st) {
      debugPrint(
        'CccdHostBridge.finishWithJson PlatformException: ${e.code} ${e.message} ${e.details}\n$st',
      );
      return false;
    } catch (e, st) {
      debugPrint('CccdHostBridge.finishWithJson: $e\n$st');
      return false;
    }
  }
}
