import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

class AppUpdater {
  static const String _releaseUrl =
      'https://api.github.com/repos/swarupnama50/token_taker/releases/latest';

  static const Duration _timeout = Duration(seconds: 20);

  static bool _checking = false;

  /// Call once when the app starts.
  static Future<void> checkForUpdate(BuildContext context) async {
    if (_checking) return;

    _checking = true;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final response = await http
          .get(
            Uri.parse(_releaseUrl),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(_timeout);

      if (response.statusCode != 200) return;

      final release = jsonDecode(response.body);

      final latestVersion = release['tag_name']?.toString().replaceFirst(
        'v',
        '',
      );

      final assets = release['assets'] as List?;

      if (latestVersion == null || assets == null) return;

      final apkAsset = assets.cast<Map<String, dynamic>>().firstWhere(
        (asset) => asset['name'] == 'app-release.apk',
        orElse: () => <String, dynamic>{},
      );

      if (apkAsset.isEmpty) return;

      if (_compareVersions(latestVersion, currentVersion) <= 0) {
        return;
      }

      if (!context.mounted) return;

      final apkUrl = apkAsset['browser_download_url']?.toString();

      if (apkUrl == null || apkUrl.isEmpty) return;

      _showUpdateDialog(context, latestVersion, apkUrl);
    } catch (e) {
      debugPrint('Update check failed: $e');
    } finally {
      _checking = false;
    }
  }

  static int _compareVersions(String latest, String current) {
    List<int> parse(String version) {
      return version
          .split('+')
          .first
          .split('-')
          .first
          .split('.')
          .map((part) => int.tryParse(part) ?? 0)
          .toList();
    }

    final a = parse(latest);
    final b = parse(current);

    for (int i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;

      if (x > y) return 1;
      if (x < y) return -1;
    }

    return 0;
  }

  static void _showUpdateDialog(
    BuildContext context,
    String version,
    String apkUrl,
  ) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        bool downloading = false;

        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Update Available'),
              content: Text(
                'A new version ($version) is available. '
                'Update now to get the latest improvements.',
              ),
              actions: [
                TextButton(
                  onPressed:
                      downloading ? null : () => Navigator.pop(dialogContext),
                  child: const Text('Later'),
                ),
                ElevatedButton(
                  onPressed:
                      downloading
                          ? null
                          : () async {
                            setState(() => downloading = true);

                            try {
                              await _downloadAndInstall(apkUrl);

                              if (dialogContext.mounted) {
                                Navigator.pop(dialogContext);
                              }
                            } catch (e) {
                              debugPrint('APK update failed: $e');

                              if (dialogContext.mounted) {
                                setState(() => downloading = false);

                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Download failed. Please try again.',
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                  child:
                      downloading
                          ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : const Text('Update'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static Future<void> _downloadAndInstall(String url) async {
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(minutes: 5));

    if (response.statusCode != 200) {
      throw Exception('APK download failed');
    }

    final directory = await getTemporaryDirectory();
    final apkFile = File('${directory.path}/app-update.apk');

    await apkFile.writeAsBytes(response.bodyBytes, flush: true);

    await OpenFilex.open(
      apkFile.path,
      type: 'application/vnd.android.package-archive',
    );
  }
}
