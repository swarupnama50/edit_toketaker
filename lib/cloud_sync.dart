import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:token_taker/saved_tokens.dart' show ShareHelper;

/// Optional Google login + server sync.
///
/// - Not logged in  -> everything stays only on the device (as before).
/// - Logged in      -> everything stays on the device AND is copied to the
///                     server. Logging in on a new/old device restores
///                     settings, drafts and receipt images from the server.
/// - Auto sync ON   -> syncs by itself. OFF -> user taps "Sync now".
///
/// Server layout (all in Firestore, folder name = Google email):
///   users/{email}/meta/settings
///   users/{email}/drafts/{draftId}
///   users/{email}/receipts/{file}.jpg            (+ /parts/0000, 0001 ...)
class CloudSync {
  CloudSync._();

  static const String _draftsKey = 'token_taker_drafts';
  static const String _autoSyncKey = 'auto_sync_enabled';

  // Settings that are copied to the server. Device-specific values such as
  // auto_tr_last_on_date and auto_sync_enabled are intentionally left out.
  static List<String> get _settingKeys => [
    'isTRMode',
    'save_destination',
    'save_to_device_gallery',
    'u_guide_shown',
    'auto_tr_enabled',
    'auto_tr_hour',
    'auto_tr_minute',
    ShareHelper.modeKey,
    ShareHelper.numberKey,
  ];

  static bool _available = false;
  static bool _syncing = false;
  static bool _pending = false;
  static bool _autoSync = true;
  static Timer? _debounce;

  /// Call once in main() after WidgetsFlutterBinding.ensureInitialized().
  /// The app keeps working offline / without Firebase if this fails.
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _autoSync = prefs.getBool(_autoSyncKey) ?? true;
    } catch (_) {}

    try {
      await Firebase.initializeApp();
      _available = true;
    } catch (e) {
      debugPrint('Firebase not available: $e');
      _available = false;
    }
  }

  static User? get user =>
      _available ? FirebaseAuth.instance.currentUser : null;
  static bool get isLoggedIn => user != null;

  /// Google account name, or '' when not logged in.
  static String get displayName => user?.displayName ?? '';

  // Server folder name = the user's Google email (lowercase).
  static String get _userKey => (user!.email ?? user!.uid).toLowerCase();

  // ---------------------------------------------------------------------
  // AUTO SYNC SWITCH
  // ---------------------------------------------------------------------

  static bool get autoSyncEnabled => _autoSync;

  static Future<void> setAutoSync(bool value) async {
    _autoSync = value;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSyncKey, value);

    if (value) {
      scheduleSync(); // catch up right away
    } else {
      _debounce?.cancel();
    }
  }

  // ---------------------------------------------------------------------
  // FIRESTORE REFERENCES
  // ---------------------------------------------------------------------

  static DocumentReference<Map<String, dynamic>> get _settingsDoc =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(_userKey)
          .collection('meta')
          .doc('settings');

  static CollectionReference<Map<String, dynamic>> get _draftsCol =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(_userKey)
          .collection('drafts');

  static CollectionReference<Map<String, dynamic>> get _receiptsCol =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(_userKey)
          .collection('receipts');

  // Max base64 characters per Firestore document (limit is 1 MiB).
  static const int _chunkSize = 700000;

  // ---------------------------------------------------------------------
  // LOGIN / LOGOUT
  // ---------------------------------------------------------------------

  /// Returns true if the user signed in.
  static Future<bool> signIn() async {
    if (!_available) return false;
    try {
      await FirebaseAuth.instance.signInWithProvider(GoogleAuthProvider());
      return isLoggedIn;
    } catch (e) {
      debugPrint('Google sign-in failed or cancelled: $e');
      return false;
    }
  }

  /// Logs out. Data already on the device stays on the device.
  static Future<void> signOut() async {
    _debounce?.cancel();
    if (_available) await FirebaseAuth.instance.signOut();
  }

  // ---------------------------------------------------------------------
  // SYNC ENTRY POINTS
  // ---------------------------------------------------------------------

  /// Automatic sync (app open / resume / background).
  /// Does nothing when logged out or when Auto sync is OFF.
  /// Returns true if it synced (so the screen should reload).
  static Future<bool> syncIfLoggedIn() async {
    if (!isLoggedIn || !_autoSync) return false;
    return syncAll();
  }

  /// Full two-way sync. Used by login, "Sync now" and auto sync.
  static Future<bool> syncAll() async {
    if (!isLoggedIn) return false;
    if (_syncing) {
      _pending = true; // run again right after the current sync
      return false;
    }
    _syncing = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      // Remembered per account on this device, so it also survives restarts.
      // First sync on a device: server settings win, drafts are only merged.
      // Later syncs: this device's changes are pushed.
      final doneKey = 'cloud_initial_sync_$_userKey';
      final initialDone = prefs.getBool(doneKey) ?? false;

      bool allOk = true;

      try {
        await _syncSettings(prefs, initialDone: initialDone);
      } catch (e) {
        allOk = false;
        debugPrint('SYNC settings failed: $e');
      }

      try {
        await _syncDrafts(prefs, deleteMissingOnServer: initialDone);
      } catch (e) {
        allOk = false;
        debugPrint('SYNC drafts failed: $e');
      }

      try {
        await _syncReceipts();
      } catch (e) {
        allOk = false;
        debugPrint('SYNC receipts failed: $e');
      }

      if (allOk) await prefs.setBool(doneKey, true);
      return allOk;
    } catch (e) {
      debugPrint('Sync failed: $e');
      return false;
    } finally {
      _syncing = false;
      if (_pending) {
        _pending = false;
        scheduleSync();
      }
    }
  }

  /// Call after anything changes (settings changed, draft saved/deleted).
  /// Waits a few seconds, then syncs. No-op if logged out or Auto sync is OFF.
  static void scheduleSync() {
    if (!isLoggedIn || !_autoSync) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 4), () {
      syncAll();
    });
  }

  // ---------------------------------------------------------------------
  // SETTINGS
  // ---------------------------------------------------------------------

  static Future<void> _syncSettings(
    SharedPreferences prefs, {
    required bool initialDone,
  }) async {
    final doc = await _settingsDoc.get();

    if (!initialDone && doc.exists) {
      // First sync on this device: server wins, so an old user gets
      // their settings back.
      final data = doc.data() ?? {};
      for (final key in _settingKeys) {
        final value = data[key];
        if (value is bool) {
          await prefs.setBool(key, value);
        } else if (value is int) {
          await prefs.setInt(key, value);
        } else if (value is double) {
          await prefs.setDouble(key, value);
        } else if (value is String) {
          await prefs.setString(key, value);
        }
      }
      return;
    }

    // Otherwise push this device's settings.
    final out = <String, dynamic>{};
    for (final key in _settingKeys) {
      final value = prefs.get(key);
      if (value != null) out[key] = value;
    }
    out['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
    await _settingsDoc.set(out, SetOptions(merge: true));
  }

  // ---------------------------------------------------------------------
  // DRAFTS
  // ---------------------------------------------------------------------

  static Future<void> _syncDrafts(
    SharedPreferences prefs, {
    required bool deleteMissingOnServer,
  }) async {
    // Local drafts
    final local = <String, Map<String, dynamic>>{};
    final saved = prefs.getString(_draftsKey);
    if (saved != null && saved.isNotEmpty) {
      try {
        for (final item in jsonDecode(saved) as List<dynamic>) {
          final m = Map<String, dynamic>.from(item as Map);
          final id = m['id'] as String?;
          if (id != null) local[id] = m;
        }
      } catch (_) {}
    }

    // Server drafts
    final snap = await _draftsCol.get();
    final server = <String, Map<String, dynamic>>{};
    for (final d in snap.docs) {
      try {
        server[d.id] = Map<String, dynamic>.from(
          jsonDecode(d.data()['json'] as String),
        );
      } catch (_) {}
    }

    int stamp(Map<String, dynamic> d) => d['updatedAt'] as int? ?? 0;

    // Merge: newest copy of each draft wins.
    final merged = <String, Map<String, dynamic>>{};
    for (final id in {...local.keys, ...server.keys}) {
      final l = local[id];
      final s = server[id];
      if (l == null) {
        merged[id] = s!;
      } else if (s == null) {
        merged[id] = l;
      } else {
        merged[id] = stamp(l) >= stamp(s) ? l : s;
      }
    }

    // Save merged list on the device.
    await prefs.setString(_draftsKey, jsonEncode(merged.values.toList()));

    // Upload anything the server doesn't have or has an older copy of.
    for (final entry in merged.entries) {
      final s = server[entry.key];
      if (s == null || stamp(entry.value) > stamp(s)) {
        await _draftsCol.doc(entry.key).set({
          'json': jsonEncode(entry.value),
          'updatedAt': stamp(entry.value),
        });
      }
    }

    // Drafts deleted on this device are removed from the server too
    // (only after the first sync, so a fresh device never wipes the server).
    if (deleteMissingOnServer) {
      for (final id in server.keys) {
        if (!local.containsKey(id)) {
          await _draftsCol.doc(id).delete();
          merged.remove(id);
        }
      }
      await prefs.setString(_draftsKey, jsonEncode(merged.values.toList()));
    }
  }

  // ---------------------------------------------------------------------
  // RECEIPT IMAGES
  // ---------------------------------------------------------------------

  static Future<Directory> _receiptDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/saved_receipts');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<void> _syncReceipts() async {
    final dir = await _receiptDir();

    final localFiles = <String, File>{
      for (final f in dir.listSync().whereType<File>())
        if (f.path.toLowerCase().endsWith('.jpg'))
          f.path.split(Platform.pathSeparator).last: f,
    };

    final snap = await _receiptsCol.get();
    final serverNames = snap.docs.map((d) => d.id).toSet();

    // Download images this device doesn't have.
    for (final d in snap.docs) {
      if (localFiles.containsKey(d.id)) continue;
      try {
        await _downloadReceipt(d, dir);
      } catch (e) {
        debugPrint('Receipt download failed (${d.id}): $e');
      }
    }

    // Upload images the server doesn't have.
    for (final entry in localFiles.entries) {
      if (serverNames.contains(entry.key)) continue;
      try {
        await _uploadFile(entry.value);
      } catch (e) {
        debugPrint('Receipt upload failed (${entry.key}): $e');
      }
    }
  }

  static Future<void> _uploadFile(File file) async {
    final name = file.path.split(Platform.pathSeparator).last;
    final modified = await file.lastModified();
    final b64 = base64Encode(await file.readAsBytes());

    final doc = _receiptsCol.doc(name);

    // Count how many parts we need.
    final partCount = (b64.length / _chunkSize).ceil();

    // Upload the parts first, then the main doc, so an interrupted upload
    // is never treated as a finished image.
    for (int i = 0; i < partCount; i++) {
      final part = b64.substring(
        i * _chunkSize,
        min((i + 1) * _chunkSize, b64.length),
      );
      await doc.collection('parts').doc(i.toString().padLeft(4, '0')).set({
        'data': part,
      });
    }

    await doc.set({
      'parts': partCount,
      'modified': modified.millisecondsSinceEpoch,
    });
  }

  static Future<void> _downloadReceipt(
    QueryDocumentSnapshot<Map<String, dynamic>> d,
    Directory dir,
  ) async {
    final expected = d.data()['parts'] as int? ?? 0;
    final partsSnap = await d.reference.collection('parts').get();
    if (expected == 0 || partsSnap.docs.length != expected) return;

    final docs = partsSnap.docs..sort((a, b) => a.id.compareTo(b.id));
    final b64 = docs.map((p) => p.data()['data'] as String).join();

    final file = File('${dir.path}/${d.id}');
    await file.writeAsBytes(base64Decode(b64));

    // Keep the original save time so the "new receipts" badge isn't triggered.
    final ms = d.data()['modified'] as int?;
    if (ms != null) {
      await file.setLastModified(DateTime.fromMillisecondsSinceEpoch(ms));
    }
  }

  /// Call right after a receipt image is saved in the app.
  /// With Auto sync OFF the image is uploaded by the next "Sync now".
  static Future<void> uploadReceipt(File file) async {
    if (!isLoggedIn || !_autoSync) return;
    try {
      await _uploadFile(file);
    } catch (e) {
      debugPrint('Receipt upload failed (will retry on next sync): $e');
    }
  }

  /// Call when the user deletes a receipt in the Saved Tokens screen.
  /// Runs even when Auto sync is OFF, otherwise the next sync would
  /// download the deleted image again.
  static Future<void> deleteReceipt(String fileName) async {
    if (!isLoggedIn) return;
    try {
      final doc = _receiptsCol.doc(fileName);
      final parts = await doc.collection('parts').get();
      for (final p in parts.docs) {
        await p.reference.delete();
      }
      await doc.delete();
    } catch (e) {
      debugPrint('Receipt delete failed: $e');
    }
  }

  // ---------------------------------------------------------------------
  // MENU UI
  // ---------------------------------------------------------------------

  /// Label for the 3-dot menu item.
  static String get menuLabel => isLoggedIn ? 'Account' : 'Login with Google';

  static IconData get menuIcon =>
      isLoggedIn ? Icons.account_circle_outlined : Icons.login;

  /// Handles the menu tap. Returns true when data from the server was
  /// loaded and the screen should reload its state.
  static Future<bool> handleMenuTap(BuildContext context) async {
    if (!_available) {
      _toast(context, 'Login is not available right now');
      return false;
    }

    if (isLoggedIn) {
      return _showAccountDialog(context);
    }

    return _loginAndSync(context);
  }

  static Future<bool> _loginAndSync(BuildContext context) async {
    final ok = await signIn();
    if (!ok) {
      if (context.mounted) _toast(context, 'Login cancelled');
      return false;
    }

    if (!context.mounted) return true;

    // Show a small progress dialog while restoring data.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder:
          (_) => const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 16),
                Expanded(child: Text('Syncing your data...')),
              ],
            ),
          ),
    );

    final synced = await syncAll();

    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop(); // close progress
      _toast(
        context,
        synced
            ? 'Logged in. Data synced.'
            : 'Logged in. Sync will retry later.',
      );
    }

    return synced;
  }

  static Future<bool> _showAccountDialog(BuildContext context) async {
    bool changed = false;
    final rootContext = context; // still valid after the dialog closes

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        bool busy = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.account_circle_outlined),
                  SizedBox(width: 8),
                  Text('Account'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(user?.displayName ?? 'Google account'),
                  const SizedBox(height: 2),
                  Text(
                    user?.email ?? '',
                    style: const TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Your settings, drafts and saved images are backed up '
                    'to the server.',
                    style: TextStyle(fontSize: 13),
                  ),
                  if (busy) ...[
                    const SizedBox(height: 14),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed:
                      busy
                          ? null
                          : () async {
                            setDialogState(() => busy = true);
                            final ok = await syncAll();
                            changed = changed || ok;
                            if (dialogContext.mounted) {
                              setDialogState(() => busy = false);
                              _toast(
                                dialogContext,
                                ok ? 'Synced' : 'Sync failed. Check internet.',
                              );
                            }
                          },
                  child: const Text('Sync now'),
                ),
                TextButton(
                  onPressed:
                      busy
                          ? null
                          : () async {
                            await signOut();
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                            if (rootContext.mounted) {
                              _toast(rootContext, 'Logged out');
                            }
                          },
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('Log out'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );

    return changed;
  }

  static void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
