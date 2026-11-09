import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppUpdater {
  static const String _releaseUrl =
      'https://api.github.com/repos/swarupnama50/token_taker/releases/latest';

  static const Duration _timeout = Duration(seconds: 20);
  static const Duration _checkInterval = Duration(hours: 24);

  static const String _lastCheckKey = 'app_updater_last_check_ms';

  static bool _checking = false;
  static bool _dialogShowing = false;

  /// Check for updates at most once every 24 hours.
  static Future<void> checkForUpdate(BuildContext context) async {
    if (_checking || _dialogShowing) return;

    _checking = true;

    try {
      final prefs = await SharedPreferences.getInstance();

      final lastCheck = prefs.getInt(_lastCheckKey);
      final now = DateTime.now().millisecondsSinceEpoch;

      if (lastCheck != null) {
        final elapsed = now - lastCheck;

        if (elapsed < _checkInterval.inMilliseconds) {
          return;
        }
      }

      // Save check time before making the request.
      // This prevents repeated checks after app restarts,
      // even when the internet is unavailable.
      await prefs.setInt(_lastCheckKey, now);

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

      if (release is! Map<String, dynamic>) return;

      final latestVersion = release['tag_name']?.toString().replaceFirst(
        RegExp(r'^v'),
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
    if (_dialogShowing) return;

    _dialogShowing = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        bool downloading = false;
        bool cancelling = false;

        int downloadedBytes = 0;
        int totalBytes = 0;

        _DownloadController? controller;

        return StatefulBuilder(
          builder: (context, setState) {
            final progress =
                totalBytes > 0 ? downloadedBytes / totalBytes : null;

            return PopScope(
              canPop: !downloading,
              child: AlertDialog(
                title: const Text('Update Available'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'A new version ($version) is available. '
                      'Update now to get the latest improvements.',
                    ),

                    if (downloading) ...[
                      const SizedBox(height: 24),

                      LinearProgressIndicator(
                        value: progress,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(10),
                      ),

                      const SizedBox(height: 12),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            progress != null
                                ? '${(progress * 100).toStringAsFixed(1)}%'
                                : 'Downloading...',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            '${_formatBytes(downloadedBytes)}'
                            '${totalBytes > 0 ? ' / ${_formatBytes(totalBytes)}' : ''}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed:
                        downloading ? null : () => Navigator.pop(dialogContext),
                    child: const Text('Later'),
                  ),

                  if (downloading)
                    TextButton(
                      onPressed:
                          cancelling
                              ? null
                              : () {
                                setState(() => cancelling = true);
                                controller?.cancel();
                              },
                      child: Text(
                        cancelling ? 'Cancelling...' : 'Cancel',
                        style: const TextStyle(color: Colors.red),
                      ),
                    )
                  else
                    ElevatedButton(
                      onPressed: () async {
                        setState(() {
                          downloading = true;
                          cancelling = false;
                          downloadedBytes = 0;
                          totalBytes = 0;
                        });

                        controller = _DownloadController();

                        try {
                          await _downloadAndInstall(apkUrl, controller!, (
                            received,
                            total,
                          ) {
                            if (!dialogContext.mounted) return;

                            setState(() {
                              downloadedBytes = received;
                              totalBytes = total;
                            });
                          });

                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        } catch (e) {
                          debugPrint('APK update failed: $e');

                          if (dialogContext.mounted) {
                            setState(() {
                              downloading = false;
                              cancelling = false;
                            });

                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  controller?.cancelled == true
                                      ? 'Download cancelled.'
                                      : 'Download failed. Please try again.',
                                ),
                              ),
                            );
                          }
                        } finally {
                          controller = null;
                        }
                      },
                      child: const Text('Update'),
                    ),
                ],
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      _dialogShowing = false;
    });
  }

  static Future<void> _downloadAndInstall(
    String url,
    _DownloadController controller,
    void Function(int received, int total) onProgress,
  ) async {
    final directory = await getTemporaryDirectory();

    final apkFile = File('${directory.path}/app-update.apk');

    IOSink? sink;

    try {
      if (controller.cancelled) {
        throw Exception('Download cancelled');
      }

      final request = http.Request('GET', Uri.parse(url));

      final response = await controller.client.send(request);

      if (controller.cancelled) {
        throw Exception('Download cancelled');
      }

      if (response.statusCode != 200) {
        throw Exception('APK download failed: ${response.statusCode}');
      }

      final totalBytes = response.contentLength ?? 0;
      int receivedBytes = 0;

      sink = apkFile.openWrite();

      await for (final chunk in response.stream) {
        if (controller.cancelled) {
          throw Exception('Download cancelled');
        }

        sink.add(chunk);
        receivedBytes += chunk.length;

        onProgress(receivedBytes, totalBytes);
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (controller.cancelled) {
        throw Exception('Download cancelled');
      }

      if (totalBytes > 0 && receivedBytes != totalBytes) {
        throw Exception('Incomplete APK download');
      }

      if (receivedBytes == 0) {
        throw Exception('Empty APK file');
      }

      // Open Android package installer.
      final result = await OpenFilex.open(
        apkFile.path,
        type: 'application/vnd.android.package-archive',
      );

      debugPrint('APK installer result: ${result.message}');
    } catch (e) {
      await sink?.close();

      // Remove incomplete or cancelled APK.
      if (await apkFile.exists()) {
        await apkFile.delete();
      }

      rethrow;
    } finally {
      controller.client.close();
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }

    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }

    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}

/// Controls an active download and supports cancellation.
class _DownloadController {
  final http.Client client = http.Client();

  bool cancelled = false;

  void cancel() {
    if (cancelled) return;

    cancelled = true;

    // Closing the client aborts its active HTTP request.
    client.close();
  }
}
