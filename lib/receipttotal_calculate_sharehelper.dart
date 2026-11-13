import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:token_taker/saved_tokens.dart';

class ReceiptTotals {
  static const String _key = 'receipt_totals';

  static String nameOf(File file) =>
      file.path.split(Platform.pathSeparator).last;

  static Future<Map<String, int>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(String fileName, int total) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAll();
    all[fileName] = total;
    await prefs.setString(_key, jsonEncode(all));
  }

  static Future<void> removeAll(Iterable<String> fileNames) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAll();
    for (final n in fileNames) {
      all.remove(n);
    }
    await prefs.setString(_key, jsonEncode(all));
  }
}

/// Caption for each image: its number within its day (1 = first saved that day).
class ReceiptCaption {
  static Future<List<String>> forFiles(List<File> files) async {
    final cache = <String, List<File>>{};
    final result = <String>[];

    for (final file in files) {
      final all =
          cache[file.parent.path] ??= await ReceiptStorage.listJpgs(
            file.parent,
          );
      final date = file.lastModifiedSync();

      final sameDay =
          all.where((f) {
              final m = f.lastModifiedSync();
              return m.year == date.year &&
                  m.month == date.month &&
                  m.day == date.day;
            }).toList()
            ..sort(
              (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()),
            );

      final i = sameDay.indexWhere((f) => f.path == file.path);
      result.add('${i < 0 ? 1 : i + 1}');
    }
    return result;
  }
}

class ShareHelper {
  static const MethodChannel _channel = MethodChannel('token_taker/whatsapp');
  static const String modeKey = 'share_mode';
  static const String numberKey = 'share_whatsapp_number';
  static const String captionKey = 'share_with_caption';

  /// Digits only. A 10-digit number gets the India code (91).
  static String cleanNumber(String raw) {
    var digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('00')) digits = digits.substring(2);
    if (digits.length == 10) digits = '91$digits';
    return digits;
  }

  static Future<void> _normalShare(List<File> files, List<String> captions) {
    return SharePlus.instance.share(
      ShareParams(
        files: files.map((f) => XFile(f.path, mimeType: 'image/jpeg')).toList(),
        text: captions.isEmpty ? null : captions.join('\n'),
        sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
      ),
    );
  }

  static Future<void> shareFiles(
    List<File> files, {
    void Function(String message)? onNotice,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getInt(modeKey) ?? 2;
    final number = cleanNumber(prefs.getString(numberKey) ?? '');
    final captionEnabled = prefs.getBool(captionKey) ?? true;

    final captions =
        captionEnabled ? await ReceiptCaption.forFiles(files) : <String>[];

    if (mode == 0 || mode == 1) {
      if (mode == 0 && number.isEmpty) {
        onNotice?.call('No WhatsApp number saved. Add one in Settings.');
        await _normalShare(files, captions);
        return;
      }

      try {
        final ok = await _channel.invokeMethod<bool>('share', {
          'paths': files.map((f) => f.path).toList(),
          'texts': captions,
          'phone': mode == 0 ? number : '',
        });

        if (ok == true) return;

        onNotice?.call('WhatsApp is not installed. Using normal share.');
      } catch (e) {
        debugPrint('WhatsApp share failed: $e');
        onNotice?.call('Could not open WhatsApp ($e). Using normal share.');
      }
    }

    await _normalShare(files, captions);
  }
}
