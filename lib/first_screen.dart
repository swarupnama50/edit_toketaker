import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:token_taker/saved_tokens.dart';
import 'package:token_taker/second_screen.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:token_taker/app_updater.dart';
import 'package:token_taker/payment_dialog.dart';

class FirstScreen extends StatefulWidget {
  const FirstScreen({super.key});

  @override
  State<FirstScreen> createState() => _FirstScreenState();
}

class _FirstScreenState extends State<FirstScreen> with WidgetsBindingObserver {
  bool isTRMode = false;
  bool _modeLoaded = false;

  Timer? _workingSaveTimer;

  static const String _workingStateKey = 'token_taker_current_working_state';
  static const String _lastGalleryViewedKey = 'token_taker_last_gallery_viewed';
  static const Color _pageColor = Color(0xFFF5F6F8);
  static const Color _primaryColor = Color(0xFF2878D0);
  static const Color _borderColor = Color(0xFFD5D9E0);
  static const String _saveToDeviceGalleryKey = 'save_to_device_gallery';
  static const String _uGuideShownKey = 'u_guide_shown';
  static const String _autoTrEnabledKey = 'auto_tr_enabled';
  static const String _autoTrHourKey = 'auto_tr_hour';
  static const String _autoTrMinuteKey = 'auto_tr_minute';
  static const String _autoTrLastOnKey = 'auto_tr_last_on_date';
  static const String _autoTrPendingOffKey = 'auto_tr_pending_off';

  // TR mode is switched off automatically at 7:00 PM.
  static const int _autoTrEndMinutes = 19 * 60;
  Timer? _autoTrTimer;
  String _todayKey() {
    final n = DateTime.now();
    return '${n.year}-${n.month}-${n.day}';
  }

  Future<void> _setModeAutomatically(bool tr, String message) async {
    if (!mounted) return;

    setState(() {
      if (tr) {
        _convertAmountsForTRMode();
      } else {
        _convertAmountsForFRSRMode();
      }
      isTRMode = tr;
    });

    await _saveMode(tr);
    _scheduleWorkingSave();

    if (!mounted) return;

    _showAppSnackBar(message);
  }

  bool _checkingAutoTr = false;

  Future<void> _checkAutoTrSchedule() async {
    if (_checkingAutoTr || !_modeLoaded || !mounted) return;
    _checkingAutoTr = true;

    try {
      final prefs = await SharedPreferences.getInstance();

      if (!(prefs.getBool(_autoTrEnabledKey) ?? false)) return;

      final startMinutes =
          (prefs.getInt(_autoTrHourKey) ?? 15) * 60 +
          (prefs.getInt(_autoTrMinuteKey) ?? 0);

      final now = DateTime.now();
      final nowMinutes = now.hour * 60 + now.minute;
      final today = _todayKey();

      final lastOn = prefs.getString(_autoTrLastOnKey);
      final pendingOff = prefs.getBool(_autoTrPendingOffKey) ?? false;

      // 1. Turn TR off at 7 PM (also covers the app being closed overnight).
      if (pendingOff && (nowMinutes >= _autoTrEndMinutes || lastOn != today)) {
        await prefs.setBool(_autoTrPendingOffKey, false);

        if (isTRMode) {
          await _setModeAutomatically(false, 'TR mode turned off (FR, SR)');
        }
      }

      // 2. Turn TR on once per day when the start time is reached.
      if (nowMinutes >= startMinutes &&
          nowMinutes < _autoTrEndMinutes &&
          lastOn != today) {
        await prefs.setString(_autoTrLastOnKey, today);
        await prefs.setBool(_autoTrPendingOffKey, true);

        if (!isTRMode) {
          await _setModeAutomatically(true, 'TR mode turned on');
        }
      }
    } finally {
      _checkingAutoTr = false;
    }
  }

  bool _saveToDeviceGallery = true;

  bool _restoringWorkingState = false;

  final List<int> allowedValues = List.generate(20, (i) => (i + 1) * 5);
  final List<TextEditingController> numControllers = [];
  final List<TextEditingController> frControllers = [];
  final List<TextEditingController> srControllers = [];
  final List<FocusNode> numFocusNodes = [];
  final List<FocusNode> frFocusNodes = [];
  final List<FocusNode> srFocusNodes = [];
  final Set<int> warnedDuplicateRows = {};
  final Map<TextEditingController, bool> _numberWasEmpty = {};
  final ValueNotifier<int> amountRevision = ValueNotifier<int>(0);
  final FocusNode _undoFocus = FocusNode(canRequestFocus: false);
  final FocusNode _redoFocus = FocusNode(canRequestFocus: false);

  final TextEditingController nameController = TextEditingController();

  // ================= UNDO / REDO =================

  static const int _maxHistory = 50;

  final List<String> _undoStack = [];
  final List<String> _redoStack = [];
  String _currentSnap = '[]';
  Timer? _historyTimer;
  bool _applyingHistory = false;

  String _buildSnapshot() {
    final rows = <Map<String, String>>[];

    for (int i = 0; i < numControllers.length; i++) {
      final num = numControllers[i].text.trim();
      final fr = frControllers[i].text.trim();
      final sr = srControllers[i].text.trim();

      if (num.isNotEmpty || fr.isNotEmpty || sr.isNotEmpty) {
        rows.add({'num': num, 'fr': fr, 'sr': sr});
      }
    }

    return jsonEncode(rows);
  }

  // Rows whose TR amount was moved from the FR box.
  final Set<TextEditingController> _trFromFr = {};

  // FR amounts hidden when switching to TR mode (row had both FR and SR).
  final Map<TextEditingController, String> _hiddenFr = {};

  // Switching to TR mode:
  // FR only   -> FR amount goes to TR (remembered, so it returns to FR later)
  // SR only   -> SR amount stays as TR
  // FR and SR -> SR amount stays as TR, FR is remembered and returns later
  void _convertAmountsForTRMode() {
    _trFromFr.clear();
    _hiddenFr.clear();

    for (int i = 0; i < numControllers.length; i++) {
      final fr = frControllers[i].text.trim();
      final sr = srControllers[i].text.trim();

      if (fr.isEmpty) continue;

      if (sr.isEmpty) {
        // FR only -> becomes TR, goes back to FR later
        srControllers[i].text = fr;
        _trFromFr.add(srControllers[i]);
      } else {
        // FR and SR -> SR stays as TR, remember FR so it can come back
        _hiddenFr[srControllers[i]] = fr;
      }

      frControllers[i].clear();
    }

    warnedDuplicateRows.clear();
    amountRevision.value++;
  }

  // Switching back to FR, SR mode:
  // TR amounts that came from FR go back to FR.
  // Hidden FR amounts are restored. All other TR amounts stay in SR.
  void _convertAmountsForFRSRMode() {
    for (int i = 0; i < numControllers.length; i++) {
      final tr = srControllers[i].text.trim();

      if (tr.isNotEmpty && _trFromFr.contains(srControllers[i])) {
        frControllers[i].text = tr;
        srControllers[i].clear();
      } else {
        final hidden = _hiddenFr[srControllers[i]];
        if (hidden != null && hidden.isNotEmpty) {
          frControllers[i].text = hidden;
        }
      }
    }

    _trFromFr.clear();
    _hiddenFr.clear();
    warnedDuplicateRows.clear();
    amountRevision.value++;
  }

  void _scheduleHistoryRecord() {
    if (_applyingHistory) return;

    _historyTimer?.cancel();
    _historyTimer = Timer(const Duration(milliseconds: 500), _recordHistory);
  }

  void _recordHistory() {
    _historyTimer?.cancel();
    _historyTimer = null;

    if (_applyingHistory) return;

    final snap = _buildSnapshot();
    if (snap == _currentSnap) return;

    _undoStack.add(_currentSnap);
    if (_undoStack.length > _maxHistory) {
      _undoStack.removeAt(0);
    }

    _currentSnap = snap;
    _redoStack.clear();

    amountRevision.value++;
  }

  // Call when a different token is loaded or the list is cleared.
  void _resetHistory() {
    _historyTimer?.cancel();
    _historyTimer = null;
    _undoStack.clear();
    _redoStack.clear();
    _currentSnap = _buildSnapshot();

    amountRevision.value++;
  }

  void _applySnapshot(String snap) {
    final previousFocus = FocusManager.instance.primaryFocus;
    _applyingHistory = true;

    try {
      final rows =
          (jsonDecode(snap) as List<dynamic>)
              .map((item) => Map<String, dynamic>.from(item as Map))
              .toList();

      while (numControllers.length < rows.length + 1 &&
          numControllers.length < 200) {
        addNewRow();
      }

      for (final c in numControllers) {
        c.clear();
      }
      for (final c in frControllers) {
        c.clear();
      }
      for (final c in srControllers) {
        c.clear();
      }

      for (int i = 0; i < rows.length && i < numControllers.length; i++) {
        numControllers[i].text = rows[i]['num'] as String? ?? '';
        frControllers[i].text = rows[i]['fr'] as String? ?? '';
        srControllers[i].text = rows[i]['sr'] as String? ?? '';
      }

      warnedDuplicateRows.clear();
      _currentSnap = snap;
    } finally {
      _applyingHistory = false;
    }

    if (mounted) setState(() {});
    amountRevision.value++;
    _scheduleWorkingSave();

    // Keep the keyboard open on the field the user was typing in.
    if (previousFocus != null && previousFocus.canRequestFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) previousFocus.requestFocus();
      });
    }
  }

  void _undo() {
    _recordHistory(); // save any pending typing first

    if (_undoStack.isEmpty) return;

    _redoStack.add(_currentSnap);
    _applySnapshot(_undoStack.removeLast());
  }

  void _redo() {
    _recordHistory();

    if (_redoStack.isEmpty) return;

    _undoStack.add(_currentSnap);
    if (_undoStack.length > _maxHistory) {
      _undoStack.removeAt(0);
    }
    _applySnapshot(_redoStack.removeLast());
  }

  static const String _draftsKey = 'token_taker_drafts';

  List<Map<String, dynamic>> _drafts = [];
  String? _activeDraftId;

  String _getDraftTitle(Map<String, dynamic> draft) {
    final name = (draft['name'] as String? ?? '').trim();

    // If a name exists, always show only the name.
    if (name.isNotEmpty) return name;

    // Otherwise, show the first filled row's number and amounts.
    final rows = draft['rows'] as List<dynamic>? ?? [];
    final isTR = draft['isTRMode'] as bool? ?? false;

    for (final item in rows) {
      final row = Map<String, dynamic>.from(item as Map);

      final num = (row['num'] as String? ?? '').trim();
      final fr = (row['fr'] as String? ?? '').trim();
      final sr = (row['sr'] as String? ?? '').trim();

      if (num.isEmpty && fr.isEmpty && sr.isEmpty) continue;

      final parts = <String>[];

      if (num.isNotEmpty) parts.add(num);
      if (fr.isNotEmpty) parts.add('FR ₹$fr');
      if (sr.isNotEmpty) parts.add('${isTR ? 'TR' : 'SR'} ₹$sr');

      return parts.join(' · ');
    }

    return 'Untitled token';
  }

  bool _hasCurrentData() {
    return nameController.text.trim().isNotEmpty ||
        numControllers.any((c) => c.text.trim().isNotEmpty) ||
        frControllers.any((c) => c.text.trim().isNotEmpty) ||
        srControllers.any((c) => c.text.trim().isNotEmpty);
  }

  Map<String, dynamic> _createDraftSnapshot(String id) {
    final rows = <Map<String, String>>[];

    for (int i = 0; i < numControllers.length; i++) {
      final num = numControllers[i].text.trim();
      final fr = frControllers[i].text.trim();
      final sr = srControllers[i].text.trim();

      if (num.isNotEmpty || fr.isNotEmpty || sr.isNotEmpty) {
        rows.add({'num': num, 'fr': fr, 'sr': sr});
      }
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final existingIndex = _drafts.indexWhere((draft) => draft['id'] == id);

    final createdAt =
        existingIndex >= 0
            ? (_drafts[existingIndex]['createdAt'] as int? ??
                _drafts[existingIndex]['updatedAt'] as int? ??
                now)
            : now;

    return {
      'id': id,
      'name': nameController.text,
      'isTRMode': isTRMode,
      'rows': rows,
      'createdAt': createdAt,
      'updatedAt': now,
    };
  }

  int _todayReceiptCount = 0;

  Future<void> _copyTokenData() async {
    final lines = <String>[];

    if (isTRMode) {
      lines.add('Num      TR');
    } else {
      lines.add('Num      FR      SR');
    }

    for (int i = 0; i < numControllers.length; i++) {
      final num = numControllers[i].text.trim();
      final fr = frControllers[i].text.trim();
      final sr = srControllers[i].text.trim();

      if (num.isEmpty && fr.isEmpty && sr.isEmpty) continue;

      if (isTRMode) {
        final amount = sr.isEmpty ? 'x' : sr;
        lines.add('${num.padRight(9)}${amount.padRight(8)}');
      } else {
        final frAmount = fr.isEmpty ? 'x' : fr;
        final srAmount = sr.isEmpty ? 'x' : sr;

        lines.add(
          '${num.padRight(9)}'
          '${frAmount.padRight(8)}'
          '$srAmount',
        );
      }
    }

    // Use exactly the same calculation as the displayed total.
    final total = getTotalAmount();

    lines.add('');
    lines.add('Total- $total');

    await Clipboard.setData(ClipboardData(text: lines.join('\n')));

    if (!mounted) return;

    _showAppSnackBar('Copied token data');
  }

  Future<void> _loadTodayReceiptCount() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      int? lastViewed = prefs.getInt(_lastGalleryViewedKey);

      // First launch: don't count receipts saved before this feature.
      if (lastViewed == null) {
        lastViewed = DateTime.now().millisecondsSinceEpoch;
        await prefs.setInt(_lastGalleryViewedKey, lastViewed);
      }

      final appDir = await getApplicationDocumentsDirectory();
      final directory = Directory('${appDir.path}/saved_receipts');

      int count = 0;

      if (await directory.exists()) {
        for (final file in directory.listSync().whereType<File>()) {
          if (!file.path.toLowerCase().endsWith('.jpg')) continue;

          final modified = await file.lastModified();

          if (modified.millisecondsSinceEpoch > lastViewed) {
            count++;
          }
        }
      }

      if (mounted) {
        setState(() {
          _todayReceiptCount = count;
        });
      }
    } catch (e) {
      debugPrint('Could not count new receipts: $e');
    }
  }

  void showAppMenu() {
    showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(0, 80, 0, 0),
      items: const [
        PopupMenuItem(
          value: 'drafts',
          child: Row(
            children: [
              Icon(Icons.drafts_outlined),
              SizedBox(width: 12),
              Text('Drafts'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'new_token',
          child: Row(
            children: [
              Icon(Icons.note_add_outlined),
              SizedBox(width: 12),
              Text('Save to Draft'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'copy',
          child: Row(
            children: [Icon(Icons.copy), SizedBox(width: 12), Text('Copy')],
          ),
        ),
        PopupMenuItem(
          value: 'payment',
          child: Row(
            children: [
              Icon(Icons.payment_outlined),
              SizedBox(width: 12),
              Text('Payment'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'settings',
          child: Row(
            children: [
              Icon(Icons.settings_outlined),
              SizedBox(width: 12),
              Text('Settings'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'about',
          child: Row(
            children: [
              Icon(Icons.info_outline),
              SizedBox(width: 12),
              Text('About'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'how_to_use',
          child: Row(
            children: [
              Icon(Icons.help_outline),
              SizedBox(width: 12),
              Text('How to Use'),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == null || !mounted) return;

      switch (value) {
        case 'drafts':
          _showDrafts();
          break;
        case 'new_token':
          _createNewToken();
          break;
        case 'copy':
          _copyTokenData();
          break;
        case 'payment':
          PaymentDialog.show(context);
          break;
        case 'settings':
          showSettingsDialog();
          break;
        case 'about':
          showAboutDialog();
          break;
        case 'how_to_use':
          showHowToUseDialog();
          break;
      }
    });
  }

  Future<void> showSettingsDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final savedValue = prefs.getBool(_saveToDeviceGalleryKey) ?? true;

    bool autoTrEnabled = prefs.getBool(_autoTrEnabledKey) ?? false;
    TimeOfDay autoTrTime = TimeOfDay(
      hour: prefs.getInt(_autoTrHourKey) ?? 15,
      minute: prefs.getInt(_autoTrMinuteKey) ?? 0,
    );

    if (!mounted) return;

    setState(() {
      _saveToDeviceGallery = savedValue;
    });

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.settings_outlined, color: _primaryColor),
                  SizedBox(width: 8),
                  Text('Settings'),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Save to device Gallery',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: const Text(
                        'Show newly downloaded images in your device gallery',
                      ),
                      value: _saveToDeviceGallery,
                      activeTrackColor: _primaryColor,
                      onChanged: (value) async {
                        setDialogState(() {
                          _saveToDeviceGallery = value;
                        });

                        setState(() {
                          _saveToDeviceGallery = value;
                        });

                        await prefs.setBool(_saveToDeviceGalleryKey, value);
                      },
                    ),
                    const Divider(),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Auto TR mode',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: const Text(
                        'Switch to TR mode daily at the set time. '
                        'It turns off automatically at 7:00 PM.',
                      ),
                      value: autoTrEnabled,
                      activeTrackColor: _primaryColor,
                      onChanged: (value) async {
                        setDialogState(() {
                          autoTrEnabled = value;
                        });

                        await prefs.setBool(_autoTrEnabledKey, value);

                        if (value) {
                          // Allow it to apply today if we're inside the window.
                          await prefs.remove(_autoTrLastOnKey);
                          await _checkAutoTrSchedule();
                        } else {
                          await prefs.setBool(_autoTrPendingOffKey, false);
                        }
                      },
                    ),
                    if (autoTrEnabled)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.access_time,
                          color: _primaryColor,
                        ),
                        title: const Text('TR mode starts at'),
                        subtitle: const Text('Ends daily at 7:00 PM'),
                        trailing: Text(
                          autoTrTime.format(context),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: _primaryColor,
                          ),
                        ),
                        onTap: () async {
                          final picked = await showTimePicker(
                            context: dialogContext,
                            initialTime: autoTrTime,
                            helpText: 'TR mode start time (before 7:00 PM)',
                            initialEntryMode:
                                TimePickerEntryMode
                                    .input, // text input mode by default
                            builder: (context, child) {
                              return Theme(
                                data: Theme.of(context).copyWith(
                                  colorScheme: Theme.of(context).colorScheme
                                      .copyWith(primary: _primaryColor),
                                  timePickerTheme: TimePickerThemeData(
                                    // Selected AM/PM gets a blue background.
                                    dayPeriodColor:
                                        WidgetStateColor.resolveWith(
                                          (states) =>
                                              states.contains(
                                                    WidgetState.selected,
                                                  )
                                                  ? _primaryColor
                                                  : Colors.transparent,
                                        ),
                                    // Selected AM/PM text is white, the other one is gray.
                                    dayPeriodTextColor:
                                        WidgetStateColor.resolveWith(
                                          (states) =>
                                              states.contains(
                                                    WidgetState.selected,
                                                  )
                                                  ? Colors.white
                                                  : Colors.grey.shade600,
                                        ),
                                    dayPeriodBorderSide: const BorderSide(
                                      color: _borderColor,
                                    ),
                                  ),
                                ),
                                child: child!,
                              );
                            },
                          );

                          if (picked == null) return;

                          if (picked.hour * 60 + picked.minute >=
                              _autoTrEndMinutes) {
                            if (!mounted) return;
                            _showAppSnackBar(
                              'Please choose a time before 7:00 PM',
                            );
                            return;
                          }

                          setDialogState(() {
                            autoTrTime = picked;
                          });

                          await prefs.setInt(_autoTrHourKey, picked.hour);
                          await prefs.setInt(_autoTrMinuteKey, picked.minute);

                          // Re-apply today if the new time is already inside the window.
                          await prefs.remove(_autoTrLastOnKey);
                          await _checkAutoTrSchedule();
                        },
                      ),
                  ],
                ),
              ),
              actions: [
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
  }

  void showAboutDialog() {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.info_outline, color: _primaryColor),
                SizedBox(width: 8),
                Text('About Token Taker'),
              ],
            ),
            content: const Text(
              'Token Taker\n\n'
              'A simple app to manage token numbers, '
              'FR/SR/TR amounts, calculate totals, '
              'save receipts, and manage drafts.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
    );
  }

  void showHowToUseDialog() {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.help_outline, color: _primaryColor),
                SizedBox(width: 8),
                Expanded(child: Text('How to Use')),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      Navigator.pop(context); // close How to Use
                      _showIAnimationDialog();
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE6F4FF),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _primaryColor.withValues(alpha: 0.3),
                        ),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '1. Fill Multiple Amount Boxes',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: _primaryColor,
                                  ),
                                ),
                              ),
                              Icon(
                                Icons.play_circle_outline,
                                color: _primaryColor,
                                size: 20,
                              ),
                            ],
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Enter 10i in an amount box to fill eligible blank '
                            'amount boxes below with ₹10.',
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Tap to watch',
                            style: TextStyle(
                              fontSize: 12,
                              color: _primaryColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: 12),
                  Text(
                    '2. Navigate Quickly',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text('Use Space or Enter to move between fields.'),
                  SizedBox(height: 12),
                  Text(
                    '3. Paste Data',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text('Use the paste icon to import token rows.'),
                  SizedBox(height: 12),
                  Text(
                    '4. Manage Tokens',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'Use Drafts to save tokens for later editing and the '
                    'gallery icon to view saved images.',
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
    );
  }

  void _showIAnimationDialog() {
    showDialog<void>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            title: const Row(
              children: [
                Icon(Icons.touch_app, color: _primaryColor),
                SizedBox(width: 8),
                Expanded(child: Text('Fill Multiple Boxes')),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _IGuideAnimation(showFr: !isTRMode),
                const SizedBox(height: 14),
                const Text(
                  'Type 10i in an amount box. The app fills the blank '
                  'amount boxes below with ₹10.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
            ],
          ),
    );
  }

  Future<void> _showFirstInstallGuide() async {
    final prefs = await SharedPreferences.getInstance();

    if (prefs.getBool(_uGuideShownKey) ?? false) return;
    if (!mounted) return;

    // Wait until the main screen is rendered.
    await Future.delayed(const Duration(milliseconds: 500));

    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          title: const Column(
            children: [
              Icon(Icons.touch_app, size: 38, color: _primaryColor),
              SizedBox(height: 8),
              Text('Quick Tip: Use i', textAlign: TextAlign.center),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Fill multiple amount boxes at once! using i',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 18),

              // Animated preview: typing 10i fills the boxes below.
              _IGuideAnimation(showFr: !isTRMode),

              const SizedBox(height: 16),

              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE6F4FF),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _primaryColor.withValues(alpha: 0.3),
                    ),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.lightbulb_outline, color: _primaryColor),
                      SizedBox(width: 8),
                      Text(
                        'Enter 10i',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                          color: _primaryColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              const Text(
                'Type 10i in an amount box. '
                'The app automatically fills the eligible blank '
                'amount boxes below with ₹10.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13),
              ),
            ],
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () {
                  Navigator.pop(dialogContext);
                },
                child: const Text("Got it! Let's Start"),
              ),
            ),
          ],
        );
      },
    );

    await prefs.setBool(_uGuideShownKey, true);
  }

  Future<void> _persistDrafts() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(_draftsKey, jsonEncode(_drafts));
  }

  Future<void> _loadDrafts() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_draftsKey);

    if (saved == null || saved.isEmpty) return;

    try {
      final decoded = jsonDecode(saved) as List<dynamic>;

      if (!mounted) return;

      setState(() {
        _drafts =
            decoded
                .map((item) => Map<String, dynamic>.from(item as Map))
                .toList();
      });
    } catch (_) {
      // Ignore invalid draft data rather than crashing the app.
    }
  }

  // ================= AUTO-SAVE CURRENT TOKEN =================

  void _scheduleWorkingSave() {
    if (_restoringWorkingState) return;
    _scheduleHistoryRecord();

    _workingSaveTimer?.cancel();

    _workingSaveTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) {
        _saveWorkingState();
      }
    });
  }

  Future<void> _saveWorkingState() {
    if (_restoringWorkingState) return Future<void>.value();

    final rows = <Map<String, String>>[];

    for (int i = 0; i < numControllers.length; i++) {
      rows.add({
        'num': numControllers[i].text,
        'fr': frControllers[i].text,
        'sr': srControllers[i].text,
        'hfr': _hiddenFr[srControllers[i]] ?? '',
      });
    }

    final state = <String, dynamic>{
      'name': nameController.text,
      'isTRMode': isTRMode,
      'rows': rows,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };

    final encodedState = jsonEncode(state);

    _workingSaveQueue = _workingSaveQueue.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_workingStateKey, encodedState);
    });

    return _workingSaveQueue;
  }

  Future<void> _restoreWorkingState(bool savedMode) async {
    final prefs = await SharedPreferences.getInstance();

    final saved = prefs.getString(_workingStateKey);

    if (!mounted) return;

    if (saved == null || saved.isEmpty) {
      setState(() {
        isTRMode = savedMode;
        _modeLoaded = true;
      });
      return;
    }

    try {
      final decoded = jsonDecode(saved) as Map<String, dynamic>;

      final rows =
          (decoded['rows'] as List<dynamic>? ?? [])
              .map((item) => Map<String, dynamic>.from(item as Map))
              .toList();

      _restoringWorkingState = true;

      // Ensure enough controllers exist to restore every saved row.
      final requiredRows = (rows.length + 1).clamp(1, 200);

      while (numControllers.length < requiredRows) {
        addNewRow();
      }

      for (final controller in numControllers) {
        controller.clear();
      }

      for (final controller in frControllers) {
        controller.clear();
      }

      for (final controller in srControllers) {
        controller.clear();
      }

      for (int i = 0; i < rows.length && i < numControllers.length; i++) {
        numControllers[i].text = rows[i]['num'] as String? ?? '';
        frControllers[i].text = rows[i]['fr'] as String? ?? '';
        srControllers[i].text = rows[i]['sr'] as String? ?? '';
      }

      // Restore FR amounts that were hidden while in TR mode.
      _hiddenFr.clear();
      for (int i = 0; i < rows.length && i < srControllers.length; i++) {
        final hfr = rows[i]['hfr'] as String? ?? '';
        if (hfr.isNotEmpty) _hiddenFr[srControllers[i]] = hfr;
      }

      nameController.text = decoded['name'] as String? ?? '';

      setState(() {
        isTRMode = decoded['isTRMode'] as bool? ?? savedMode;
        _modeLoaded = true;
        amountRevision.value++;
      });
    } catch (_) {
      // If the saved state is invalid, start with an empty list.
      if (mounted) {
        setState(() {
          isTRMode = savedMode;
          _modeLoaded = true;
        });
      }
    } finally {
      _restoringWorkingState = false;
      _resetHistory();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAutoTrSchedule();
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _workingSaveTimer?.cancel();
      _saveWorkingState();
    }
  }

  //===================Paste=========================
  Future<void> pasteTokenData() async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final rawText = clipboardData?.text;

    if (rawText == null || rawText.trim().isEmpty) return;

    // Remove WhatsApp headers such as:
    //   [30/10, 1:52 pm] User Name (t):
    //   [30/10/2026, 1:52:10 PM] Name:
    //   30/10/2026, 1:52 pm - Name:
    // Each header is replaced with a line break, so the message after it
    // (e.g. "45=10") is kept, even when a header is glued to the previous
    // line like "12-180[30/10, 1:52 pm] Name: Fr."
    final whatsappHeader = RegExp(
      r'\[\s*\d{1,2}[/.\-]\d{1,2}(?:[/.\-]\d{2,4})?,?\s*'
      r'\d{1,2}:\d{2}(?::\d{2})?\s*(?:[ap]\.?m\.?)?\s*\]\s*[^:\n\]]*:'
      r'|'
      r'\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4},?\s*'
      r'\d{1,2}:\d{2}(?::\d{2})?\s*(?:[ap]\.?m\.?)?\s*[-–]\s*[^:\n]*:',
      caseSensitive: false,
    );

    final text = rawText.replaceAll(whatsappHeader, '\n');

    if (text.trim().isEmpty) return;

    final parsedRows = <Map<String, String>>[];

    // Every symbol / space is ignored: we only keep runs of digits or letters.
    final tokenPattern = RegExp(r'\d+|[A-Za-z]+');
    final digitsOnly = RegExp(r'^\d+$');

    for (final line in text.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      if (RegExp(
        r'^(?:total|grand\s+total)\b',
        caseSensitive: false,
      ).hasMatch(trimmed)) {
        continue;
      }

      final tokens =
          tokenPattern
              .allMatches(trimmed)
              .map((m) => m.group(0)!.toUpperCase())
              .toList();

      if (tokens.isEmpty) continue;

      // ---------- 1. Find the Num ----------
      String num = '';
      int next = 0; // index of the first token after the Num

      final first = tokens[0];
      String? compactAmount;

      if (digitsOnly.hasMatch(first)) {
        final hasNextLetters =
            tokens.length > 1 && !digitsOnly.hasMatch(tokens[1]);

        if (first.length == 2) {
          // 45 / 45V / 45!V / 45!velu
          num = first;
          next = 1;
          if (hasNextLetters && tokens[1].startsWith('V')) {
            num += 'V';
            next = 2;
          }
        } else if (first.length == 1) {
          // 4E / 4!E / 4#H / 4 hoze
          if (hasNextLetters &&
              (tokens[1].startsWith('H') || tokens[1].startsWith('E'))) {
            num = first + tokens[1][0];
            next = 2;
          } else {
            continue;
          }
        } else if (first.length > 2) {
          // Joined number and amount: 1510 = Num 15, Amount 10
          final possibleNum = first.substring(0, 2);
          final possibleAmount = first.substring(2);

          final amount = int.tryParse(possibleAmount);

          if (amount == null || amount < 1 || amount > 15000) {
            continue;
          }

          num = possibleNum;
          compactAmount = possibleAmount;
          next = 1;
        } else {
          continue;
        }
      } else {
        // AP / HP, also A!P and H-P, and spelled-out words such as
        // "All Pair", "Aal par", "Alfair", "Half Pair", "Halfpair".
        // Letters-only text, so the "i" amount trick etc. is not affected.
        final allPair = RegExp(r'^A[AL]{0,3}[PF][AEI]{0,2}RS?$');
        final halfPair = RegExp(r'^(?=.*[FP])H[AEL]{0,3}F?P?[AEI]{0,2}RS?$');

        bool isAllPair(String s) => allPair.hasMatch(s);
        bool isHalfPair(String s) => halfPair.hasMatch(s);

        final second =
            tokens.length > 1 && !digitsOnly.hasMatch(tokens[1])
                ? tokens[1]
                : '';

        if (first.startsWith('AP') || first.startsWith('HP')) {
          num = first.substring(0, 2);
          next = 1;
        } else if ((first == 'A' || first == 'H') &&
            tokens.length > 1 &&
            tokens[1].startsWith('P')) {
          num = '${first}P';
          next = 2;
        } else if (isAllPair(first)) {
          // "Alfair", "Allpair"
          num = 'AP';
          next = 1;
        } else if (isHalfPair(first)) {
          // "Halfpair"
          num = 'HP';
          next = 1;
        } else if (second.isNotEmpty && isAllPair(first + second)) {
          // "All Pair", "Aal par"
          num = 'AP';
          next = 2;
        } else if (second.isNotEmpty && isHalfPair(first + second)) {
          // "Half Pair"
          num = 'HP';
          next = 2;
        } else {
          continue;
        }
      }
      // ---------- 2. Find the amounts ----------
      String? frLabel, srLabel, trLabel;
      final unlabelled = <String>[];

      if (compactAmount != null) {
        unlabelled.add(compactAmount);
      }

      String? pendingLabel;

      for (int i = next; i < tokens.length; i++) {
        final t = tokens[i];

        if (digitsOnly.hasMatch(t)) {
          final amount = int.tryParse(t);
          final valid = amount != null && amount >= 1 && amount <= 15000;

          if (valid) {
            if (pendingLabel == 'FR') {
              frLabel = t;
            } else if (pendingLabel == 'SR') {
              srLabel = t;
            } else if (pendingLabel == 'TR') {
              trLabel = t;
            } else {
              unlabelled.add(t);
            }
          }
          pendingLabel = null;
        } else {
          // Words are ignored, except FR / SR / TR labels.
          pendingLabel = (t == 'FR' || t == 'SR' || t == 'TR') ? t : null;
        }
      }

      // ---------- 3. Assign FR / SR ----------
      String fr = '';
      String sr = '';

      if (isTRMode) {
        sr =
            trLabel ??
            srLabel ??
            frLabel ??
            (unlabelled.isNotEmpty ? unlabelled.last : '');
      } else {
        fr = frLabel ?? '';
        sr = srLabel ?? '';

        final rest = List<String>.from(unlabelled);
        if (fr.isEmpty && rest.isNotEmpty) fr = rest.removeAt(0);
        if (sr.isEmpty && rest.isNotEmpty) sr = rest.removeAt(0);
      }

      parsedRows.add({'num': num, 'fr': fr, 'sr': sr});

      if (parsedRows.length >= 200) break;
    }

    if (parsedRows.isEmpty || !mounted) return;

    int startIndex = numControllers.indexWhere(
      (controller) => controller.text.trim().isEmpty,
    );

    if (startIndex == -1) startIndex = numControllers.length;

    while (numControllers.length < startIndex + parsedRows.length &&
        numControllers.length < 200) {
      addNewRow();
    }

    final availableRows = numControllers.length - startIndex;
    final rowsToPaste =
        parsedRows.length < availableRows ? parsedRows.length : availableRows;

    setState(() {
      for (int i = 0; i < rowsToPaste; i++) {
        final rowIndex = startIndex + i;
        final row = parsedRows[i];

        numControllers[rowIndex].text = row['num'] ?? '';
        frControllers[rowIndex].text = isTRMode ? '' : (row['fr'] ?? '');
        srControllers[rowIndex].text = row['sr'] ?? '';
      }

      amountRevision.value++;
    });

    _scheduleWorkingSave();
  }

  Future<void> _saveCurrentDraft() async {
    if (!_hasCurrentData()) return;

    final id =
        _activeDraftId ?? DateTime.now().microsecondsSinceEpoch.toString();

    final snapshot = _createDraftSnapshot(id);

    final index = _drafts.indexWhere((draft) => draft['id'] == id);

    if (index >= 0) {
      _drafts[index] = snapshot;
    } else {
      _drafts.add(snapshot);
    }

    _activeDraftId = id;

    await _persistDrafts();

    if (mounted) setState(() {});
  }

  void _clearCurrentToken() {
    hideKeyboard();

    for (final controller in numControllers) {
      controller.clear();
    }

    for (final controller in frControllers) {
      controller.clear();
    }

    for (final controller in srControllers) {
      controller.clear();
    }

    nameController.clear();
    warnedDuplicateRows.clear();
    _trFromFr.clear();
    _hiddenFr.clear();
    _activeDraftId = null;
    _resetHistory();

    amountRevision.value++;

    if (mounted) setState(() {});
    _scheduleWorkingSave();
  }

  Future<void> _createNewToken() async {
    hideKeyboard();

    // Save a draft only when at least one Num field contains text.
    if (_hasCurrentData()) {
      await _saveCurrentDraft();
    }

    if (!mounted) return;

    _clearCurrentToken();

    _showAppSnackBar('Saved to Draft', duration: const Duration(seconds: 1));
  }

  Future<void> _openDraft(Map<String, dynamic> draft) async {
    final targetId = draft['id'] as String?;

    // Save the current list only if it is different from the selected draft.
    // If the selected draft is already open, save its latest changes
    // and keep the current screen as it is.
    if (_activeDraftId == targetId) {
      await _saveCurrentDraft();
      return;
    }

    // Save the current token before switching to another draft.
    if (_hasCurrentData()) {
      await _saveCurrentDraft();
    }

    if (!mounted) return;

    // Keep the remaining existing _openDraft code here.

    final rows =
        (draft['rows'] as List<dynamic>? ?? [])
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();

    hideKeyboard();

    // Clear existing data.
    for (final controller in numControllers) {
      controller.clear();
    }

    for (final controller in frControllers) {
      controller.clear();
    }

    for (final controller in srControllers) {
      controller.clear();
    }

    // Ensure there are enough rows for the selected draft.
    while (numControllers.length < rows.length + 1 &&
        numControllers.length < 200) {
      addNewRow();
    }

    setState(() {
      isTRMode = draft['isTRMode'] as bool? ?? false;
      nameController.text = draft['name'] as String? ?? '';
      _activeDraftId = draft['id'] as String?;

      for (int i = 0; i < rows.length && i < numControllers.length; i++) {
        numControllers[i].text = rows[i]['num'] as String? ?? '';
        frControllers[i].text = rows[i]['fr'] as String? ?? '';
        srControllers[i].text = rows[i]['sr'] as String? ?? '';
      }
      _trFromFr.clear();
      _hiddenFr.clear();
      warnedDuplicateRows.clear();
      amountRevision.value++;
    });
    _resetHistory();

    await _saveMode(isTRMode);
    _scheduleWorkingSave();
  }

  Future<void> _showDrafts() async {
    hideKeyboard();

    await _loadDrafts();

    if (!mounted) return;

    final Set<String> selectedDraftIds = {};

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final sortedDrafts = List<Map<String, dynamic>>.from(_drafts)
              ..sort((a, b) {
                final aTime =
                    a['createdAt'] as int? ?? a['updatedAt'] as int? ?? 0;
                final bTime =
                    b['createdAt'] as int? ?? b['updatedAt'] as int? ?? 0;

                // Newest first; oldest remains at the bottom.
                return bTime.compareTo(aTime);
              });

            final isSelecting = selectedDraftIds.isNotEmpty;

            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.drafts_outlined),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('Drafts')),
                  Text(
                    '${sortedDrafts.length}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child:
                    sortedDrafts.isEmpty
                        ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: Text('No drafts saved yet')),
                        )
                        : ListView.separated(
                          shrinkWrap: true,
                          itemCount: sortedDrafts.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final draft = sortedDrafts[index];
                            final id = draft['id'] as String;
                            final rows = draft['rows'] as List<dynamic>? ?? [];
                            final selected = selectedDraftIds.contains(id);

                            final date = DateTime.fromMillisecondsSinceEpoch(
                              draft['updatedAt'] as int? ?? 0,
                            );

                            final dateText =
                                '${date.day.toString().padLeft(2, '0')}/'
                                '${date.month.toString().padLeft(2, '0')}/'
                                '${date.year} '
                                '${date.hour.toString().padLeft(2, '0')}:'
                                '${date.minute.toString().padLeft(2, '0')}';

                            return ListTile(
                              selected: selected,
                              leading: Icon(
                                selected
                                    ? Icons.check_circle
                                    : Icons.description_outlined,
                                color: selected ? Colors.blue : null,
                              ),
                              title: Text(
                                _getDraftTitle(draft),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${rows.length} entries • $dateText',
                              ),
                              onLongPress: () {
                                setDialogState(() {
                                  if (selected) {
                                    selectedDraftIds.remove(id);
                                  } else {
                                    selectedDraftIds.add(id);
                                  }
                                });
                              },
                              onTap: () async {
                                if (isSelecting) {
                                  setDialogState(() {
                                    if (selected) {
                                      selectedDraftIds.remove(id);
                                    } else {
                                      selectedDraftIds.add(id);
                                    }
                                  });
                                  return;
                                }

                                Navigator.pop(dialogContext);
                                await _openDraft(draft);
                              },
                            );
                          },
                        ),
              ),
              actions: [
                if (isSelecting)
                  TextButton.icon(
                    onPressed: () async {
                      final count = selectedDraftIds.length;

                      final confirmed = await showDialog<bool>(
                        context: dialogContext,
                        builder:
                            (confirmContext) => AlertDialog(
                              title: const Text('Delete drafts?'),
                              content: Text(
                                'Delete $count selected '
                                '${count == 1 ? 'draft' : 'drafts'}? '
                                'This cannot be undone.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed:
                                      () =>
                                          Navigator.pop(confirmContext, false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed:
                                      () => Navigator.pop(confirmContext, true),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.red,
                                  ),
                                  child: const Text('Delete'),
                                ),
                              ],
                            ),
                      );

                      if (confirmed != true) return;

                      final idsToDelete = Set<String>.from(selectedDraftIds);

                      _drafts.removeWhere(
                        (draft) => idsToDelete.contains(draft['id']),
                      );

                      if (_activeDraftId != null &&
                          idsToDelete.contains(_activeDraftId)) {
                        _activeDraftId = null;
                      }

                      await _persistDrafts();

                      if (!mounted) return;

                      selectedDraftIds.clear();
                      setDialogState(() {});
                      setState(() {});
                    },
                    icon: const Icon(Icons.delete_outline),
                    label: Text('Delete (${selectedDraftIds.length})'),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
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
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    addNewRow();
    _loadMode();
    _loadDrafts();
    _loadTodayReceiptCount();

    // Check every 20 seconds while the app is open.
    _autoTrTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _checkAutoTrSchedule(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppUpdater.checkForUpdate(context);
    });
  }

  Future<void> _loadMode() async {
    final prefs = await SharedPreferences.getInstance();
    final savedMode = prefs.getBool('isTRMode') ?? false;

    if (!mounted) return;

    await _restoreWorkingState(savedMode);
    await _checkAutoTrSchedule();

    if (mounted) {
      await _showFirstInstallGuide();
    }
  }

  Future<void> _saveMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isTRMode', value);
  }

  void handleBackspace(
    TextEditingController controller,
    int rowIndex,
    String fieldType,
  ) {
    if (controller.text.isNotEmpty) return;

    FocusNode? previousFocus;
    TextEditingController? previousController;

    if (fieldType == 'num') {
      // Num -> previous row's amount box, skipping blank rows.
      for (int i = rowIndex - 1; i >= 0; i--) {
        if (!isFirstFilled(i)) continue;

        if (isTRMode) {
          if (srControllers[i].text.trim().isNotEmpty) {
            previousController = srControllers[i];
            previousFocus = srFocusNodes[i];
            break;
          }
        } else {
          if (srControllers[i].text.trim().isNotEmpty) {
            previousController = srControllers[i];
            previousFocus = srFocusNodes[i];
            break;
          }

          if (frControllers[i].text.trim().isNotEmpty) {
            previousController = frControllers[i];
            previousFocus = frFocusNodes[i];
            break;
          }
        }

        previousController = numControllers[i];
        previousFocus = numFocusNodes[i];
        break;
      }
    } else if (fieldType == 'sr') {
      if (isTRMode) {
        // TR -> same row's Num.
        previousController = numControllers[rowIndex];
        previousFocus = numFocusNodes[rowIndex];
      } else {
        // SR -> FR if filled; otherwise Num.
        if (frControllers[rowIndex].text.trim().isNotEmpty) {
          previousController = frControllers[rowIndex];
          previousFocus = frFocusNodes[rowIndex];
        } else {
          previousController = numControllers[rowIndex];
          previousFocus = numFocusNodes[rowIndex];
        }
      }
    } else if (fieldType == 'fr') {
      // FR -> same row's Num.
      previousController = numControllers[rowIndex];
      previousFocus = numFocusNodes[rowIndex];
    }

    if (previousController != null && previousFocus != null) {
      FocusScope.of(context).requestFocus(previousFocus);

      previousController.selection = TextSelection.collapsed(
        offset: previousController.text.length,
      );
    }
  }

  void hideKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }

  // ================= SPACE NAVIGATION =================

  bool isValidCompletedNumber(String value) {
    return RegExp(r'^\d{2}$').hasMatch(value) ||
        RegExp(r'^\d[HE]$').hasMatch(value) ||
        RegExp(r'^\d{2}V$').hasMatch(value) ||
        value == 'AP' ||
        value == 'HP';
  }

  void moveToNextField(int rowIndex, String currentField) {
    if (currentField == 'num') {
      if (isTRMode) {
        FocusScope.of(context).requestFocus(srFocusNodes[rowIndex]);
      } else {
        FocusScope.of(context).requestFocus(frFocusNodes[rowIndex]);
      }
      return;
    }

    if (currentField == 'fr') {
      FocusScope.of(context).requestFocus(srFocusNodes[rowIndex]);
      return;
    }

    // After SR/TR, move to the next visible row's Num field.
    final sortedIndexes = getSortedRowIndexes();
    final position = sortedIndexes.indexOf(rowIndex);

    for (int i = position + 1; i < sortedIndexes.length; i++) {
      final nextIndex = sortedIndexes[i];

      if (isNumEnabled(nextIndex)) {
        FocusScope.of(context).requestFocus(numFocusNodes[nextIndex]);
        return;
      }
    }

    // If there is no next enabled row, leave the current field focused.
  }

  void moveToNextNum(int rowIndex) {
    final sortedIndexes = getSortedRowIndexes();
    final position = sortedIndexes.indexOf(rowIndex);

    for (int i = position + 1; i < sortedIndexes.length; i++) {
      final nextIndex = sortedIndexes[i];

      if (isNumEnabled(nextIndex)) {
        FocusScope.of(context).requestFocus(numFocusNodes[nextIndex]);
        return;
      }
    }
  }

  void moveToNextAmount(int rowIndex, String fieldType) {
    final sortedIndexes = getSortedRowIndexes();
    final position = sortedIndexes.indexOf(rowIndex);

    for (int i = position + 1; i < sortedIndexes.length; i++) {
      final nextIndex = sortedIndexes[i];

      if (fieldType == 'num') {
        FocusScope.of(context).requestFocus(numFocusNodes[nextIndex]);
        return;
      }

      if (fieldType == 'fr') {
        if (!isTRMode && isFirstFilled(nextIndex)) {
          FocusScope.of(context).requestFocus(frFocusNodes[nextIndex]);
        } else {
          FocusScope.of(context).requestFocus(numFocusNodes[nextIndex]);
        }
        return;
      }

      if (fieldType == 'sr' || fieldType == 'tr') {
        if (isFirstFilled(nextIndex)) {
          FocusScope.of(context).requestFocus(srFocusNodes[nextIndex]);
        } else {
          FocusScope.of(context).requestFocus(numFocusNodes[nextIndex]);
        }
        return;
      }
    }
  }

  void checkDuplicateNumber(String value, int currentIndex) {
    value = value.trim().toUpperCase();

    if (!isValidCompletedNumber(value)) {
      warnedDuplicateRows.remove(currentIndex);
      return;
    }

    final exists = numControllers.asMap().entries.any(
      (entry) =>
          entry.key != currentIndex &&
          entry.value.text.trim().toUpperCase() == value,
    );

    if (exists && !warnedDuplicateRows.contains(currentIndex) && mounted) {
      warnedDuplicateRows.add(currentIndex);

      _showAppSnackBar('Number $value already exists');
    } else if (!exists) {
      warnedDuplicateRows.remove(currentIndex);
    }
  }

  void _showAppSnackBar(
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();

    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 100),
      ),
    );
  }

  void handleSpaceInput(
    TextEditingController controller,
    String value,
    int rowIndex,
    String fieldType,
  ) {
    if (!value.endsWith(' ')) return;

    final text = value.substring(0, value.length - 1);
    final upperText = text.toUpperCase();

    if (fieldType == 'num') {
      if (!isValidCompletedNumber(upperText)) {
        controller.value = TextEditingValue(
          text: upperText,
          selection: TextSelection.collapsed(offset: upperText.length),
        );
        return;
      }

      checkDuplicateNumber(upperText, rowIndex);
    }

    controller.value = TextEditingValue(
      text: upperText,
      selection: TextSelection.collapsed(offset: upperText.length),
    );

    moveToNextField(rowIndex, fieldType);
  }

  Widget spaceAwareField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required int rowIndex,
    required String fieldType,
    required InputDecoration decoration,
    required double width,
    required bool enabled,
    required TextInputType keyboardType,
    List<TextInputFormatter>? inputFormatters,
    TextAlign textAlign = TextAlign.center,
    ValueChanged<String>? onChanged,
    VoidCallback? onEditingComplete,
    ValueChanged<String>? onSubmitted,
    TextInputAction textInputAction = TextInputAction.next,
  }) {
    final isNumber = fieldType == 'num';

    return SizedBox(
      width: width,
      child: Focus(
        onKeyEvent: (node, event) {
          if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
              event.logicalKey == LogicalKeyboardKey.backspace &&
              controller.text.isEmpty) {
            handleBackspace(controller, rowIndex, fieldType);
            return KeyEventResult.handled;
          }

          return KeyEventResult.ignored;
        },
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          textAlign: textAlign,
          style: TextStyle(
            fontSize: isNumber ? 21 : 20,
            fontWeight: isNumber ? FontWeight.w600 : FontWeight.w600,
            color:
                !enabled
                    ? Colors.grey.shade400
                    : isNumber
                    ? const Color.fromARGB(255, 0, 0, 0)
                    : const Color.fromARGB(255, 0, 0, 0),
          ),
          inputFormatters: inputFormatters,
          onChanged: onChanged,
          onEditingComplete: onEditingComplete,
          onSubmitted: onSubmitted,
          decoration: decoration.copyWith(
            filled: true,
            fillColor:
                !enabled
                    ? const Color(0xFFF8F9FB)
                    : isNumber
                    ? const Color(0xFFE6F4FF)
                    : Colors.white,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 5,
              vertical: 6,
            ),
            prefixStyle: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w500,
              color: Color(0xFF656D78),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(color: _borderColor, width: 1),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(color: _borderColor, width: 1),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(color: _primaryColor, width: 1.7),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(color: Color(0xFFE7E9ED), width: 1),
            ),
          ),
        ),
      ),
    );
  }

  // ================= V GENERATOR =================

  List<String> generateVNumbers(String value) {
    if (value.length != 3 || !value.endsWith('V')) return [];

    String base = value.substring(0, 2);

    int a = int.parse(base[0]);
    int b = int.parse(base[1]);

    int cA = (a >= 5) ? a - 5 : a + 5;
    int cB = (b >= 5) ? b - 5 : b + 5;

    Set<String> numbers = {};

    numbers.add("$a$b");
    numbers.add("$b$a");
    numbers.add("$cA$cB");
    numbers.add("$cB$cA");
    numbers.add("$a$cB");
    numbers.add("$cB$a");
    numbers.add("$cA$b");
    numbers.add("$b$cA");

    return numbers.toList();
  }

  void showVNumbersPopup(String value) {
    List<String> numbers = generateVNumbers(value);

    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text("Values"),
            content: Wrap(
              spacing: 10,
              children: numbers.map((e) => Chip(label: Text(e))).toList(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Close"),
              ),
            ],
          ),
    );
  }

  Future<void> _openSavedReceipts() async {
    // Mark all receipts saved up to now as viewed.
    final prefs = await SharedPreferences.getInstance();

    await prefs.setInt(
      _lastGalleryViewedKey,
      DateTime.now().millisecondsSinceEpoch,
    );

    if (mounted) {
      setState(() {
        _todayReceiptCount = 0;
      });
    }

    final appDir = await getApplicationDocumentsDirectory();
    final directory = Directory('${appDir.path}/saved_receipts');

    if (!await directory.exists()) return;
    if (!mounted) return;

    final receipts =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.toLowerCase().endsWith('.jpg'))
            .toList();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SavedReceiptsScreen(receipts: receipts),
      ),
    );

    if (!mounted) return;

    await _loadTodayReceiptCount();
    hideKeyboard();
  }

  Future<void> _workingSaveQueue = Future<void>.value();

  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Clear all?'),
            content: const Text(
              'Clear all entered data and remove the extra blank rows? '
              'Your saved drafts will not be deleted.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Clear All'),
              ),
            ],
          ),
    );

    if (confirmed != true || !mounted) return;

    // Cancel any pending auto-save.
    _workingSaveTimer?.cancel();

    setState(() {
      _trFromFr.clear();
      _hiddenFr.clear();
      // Dispose all existing controllers and focus nodes.
      for (final controller in numControllers) {
        _numberWasEmpty.remove(controller);
        controller.dispose();
      }

      for (final controller in frControllers) {
        controller.dispose();
      }

      for (final controller in srControllers) {
        controller.dispose();
      }

      for (final node in numFocusNodes) {
        node.dispose();
      }

      for (final node in frFocusNodes) {
        node.dispose();
      }

      for (final node in srFocusNodes) {
        node.dispose();
      }

      // Remove all rows and focus nodes.
      numControllers.clear();
      frControllers.clear();
      srControllers.clear();

      numFocusNodes.clear();
      frFocusNodes.clear();
      srFocusNodes.clear();

      // Reset the current token.
      nameController.clear();
      warnedDuplicateRows.clear();
      _activeDraftId = null;

      // Create exactly one fresh row.
      addNewRow();

      // Refresh total and Continue button.
      amountRevision.value++;
    });
    _resetHistory();

    // Save the fresh state so reopening the app keeps it blank.
    await _saveWorkingState();

    if (!mounted) return;

    hideKeyboard();

    _showAppSnackBar(
      'All cleared. Fresh token ready.',
      duration: const Duration(seconds: 1),
    );
  }
  // ================= TOTAL LOGIC =================

  int getTotalAmount() {
    int total = 0;

    for (int i = 0; i < numControllers.length; i++) {
      final numText = numControllers[i].text.trim();
      final fr = isTRMode ? 0 : (int.tryParse(frControllers[i].text) ?? 0);
      final sr = int.tryParse(srControllers[i].text) ?? 0;

      bool isSingleWithHE =
          (numText.length == 2 &&
              int.tryParse(numText[0]) != null &&
              (numText[1] == 'H' || numText[1] == 'E')) ||
          numText == 'AP' ||
          numText == 'HP';

      bool isDoubleWithV =
          numText.length == 3 && RegExp(r'^[0-9]{2}V$').hasMatch(numText);

      if (isSingleWithHE) {
        total += (fr * 10) + (sr * 10);
      } else if (isDoubleWithV) {
        int count = generateVNumbers(numText).length;
        total += (fr * count) + (sr * count);
      } else {
        total += fr + sr;
      }
    }

    return total;
  }

  // ================= VALIDATION =================

  bool canProceed() {
    bool hasAtLeastOneNumber = false;

    for (int i = 0; i < numControllers.length; i++) {
      final numText = numControllers[i].text.trim();
      final frText = frControllers[i].text.trim();
      final srText = srControllers[i].text.trim();

      if (numText.isNotEmpty) {
        hasAtLeastOneNumber = true;

        bool isNormalTwoDigit =
            numText.length == 2 && int.tryParse(numText) != null;

        bool isSingleWithHE =
            (numText.length == 2 &&
                int.tryParse(numText[0]) != null &&
                (numText[1] == 'H' || numText[1] == 'E')) ||
            (numText == 'AP' || numText == 'HP');

        bool isDoubleWithV =
            numText.length == 3 && RegExp(r'^[0-9]{2}V$').hasMatch(numText);

        if (!isNormalTwoDigit && !isSingleWithHE && !isDoubleWithV) {
          return false;
        }

        if (frText.isEmpty && srText.isEmpty) return false;

        if (frText.isNotEmpty) {
          final value = int.tryParse(frText);
          if (value == null || value < 1 || value > 15000) {
            return false;
          }
        }

        if (srText.isNotEmpty) {
          final value = int.tryParse(srText);
          if (value == null || value < 1 || value > 15000) {
            return false;
          }
        }
      }
    }

    if (!hasAtLeastOneNumber) return false;

    return true;
  }

  // ================= REAL-TIME ARRANGEMENT =================

  int getNumberType(String value) {
    if (RegExp(r'^\d{2}$').hasMatch(value)) return 0;

    if (RegExp(r'^\d[HE]$').hasMatch(value) || value == 'AP' || value == 'HP') {
      return 1;
    }

    if (RegExp(r'^\d{2}V$').hasMatch(value)) return 2;

    return 0;
  }

  List<int> getSortedRowIndexes() {
    return List.generate(numControllers.length, (i) => i);
  }

  // ================= ROW LOGIC =================

  void addNewRow() {
    if (numControllers.length >= 200) return;

    final numController = TextEditingController();
    final frController = TextEditingController();
    final srController = TextEditingController();

    _numberWasEmpty[numController] = true;

    numController.addListener(() {
      final index = numControllers.indexOf(numController);
      if (index == -1) return;

      final isEmpty = numController.text.isEmpty;
      final wasEmpty = _numberWasEmpty[numController] ?? true;

      // Rebuild the row list only when a row becomes empty/non-empty.
      if (isEmpty != wasEmpty) {
        _numberWasEmpty[numController] = isEmpty;

        if (isEmpty) {
          frController.clear();
          srController.clear();
        } else {
          final isLast = index == numControllers.length - 1;
          if (isLast && numControllers.length < 200) {
            addNewRow();
          }
        }
      }

      // Rebuild on every Num change so amount boxes enable immediately.
      if (mounted) setState(() {});

      // Refresh only the total/Continue area while text is being edited.
      amountRevision.value++;

      _scheduleWorkingSave();
    });

    frController.addListener(() {
      amountRevision.value++;

      _scheduleWorkingSave();
    });

    srController.addListener(() {
      amountRevision.value++;

      _scheduleWorkingSave();
    });

    numControllers.add(numController);
    frControllers.add(frController);
    srControllers.add(srController);

    numFocusNodes.add(FocusNode());
    frFocusNodes.add(FocusNode());
    srFocusNodes.add(FocusNode());
  }

  // ================= REMOVE ROW =================

  void removeRow(int index) {
    if (numControllers.length <= 1) return;

    _numberWasEmpty.remove(numControllers[index]);
    _trFromFr.remove(srControllers[index]);
    _hiddenFr.remove(srControllers[index]);

    numControllers[index].dispose();
    frControllers[index].dispose();
    srControllers[index].dispose();

    numFocusNodes[index].dispose();
    frFocusNodes[index].dispose();
    srFocusNodes[index].dispose();

    numControllers.removeAt(index);
    frControllers.removeAt(index);
    srControllers.removeAt(index);

    numFocusNodes.removeAt(index);
    frFocusNodes.removeAt(index);
    srFocusNodes.removeAt(index);

    setState(() {});
    _scheduleWorkingSave();
  }

  bool isFirstFilled(int index) {
    final value = numControllers[index].text.trim().toUpperCase();

    return RegExp(r'^\d{2}$').hasMatch(value) ||
        RegExp(r'^\d[HE]$').hasMatch(value) ||
        RegExp(r'^\d{2}V$').hasMatch(value) ||
        value == 'AP' ||
        value == 'HP';
  }

  bool isNumEnabled(int index) {
    return true;
  }

  void validateController(TextEditingController controller) {
    final value = int.tryParse(controller.text);

    if (value == null || value < 5 || value > 15000) {
      controller.clear();
    }
  }

  void handleChange(TextEditingController controller, String val) {
    final value = int.tryParse(val);

    if (val.isNotEmpty && (value == null || value < 1 || value > 15000)) {
      controller.clear();
    }
  }

  void compactRowsAfterDelete(int deletedIndex) {
    if (numControllers[deletedIndex].text.isNotEmpty) return;

    int targetIndex = deletedIndex;

    for (
      int sourceIndex = deletedIndex + 1;
      sourceIndex < numControllers.length;
      sourceIndex++
    ) {
      if (numControllers[sourceIndex].text.trim().isEmpty) {
        continue;
      }

      numControllers[targetIndex].text = numControllers[sourceIndex].text;

      frControllers[targetIndex].text = frControllers[sourceIndex].text;

      srControllers[targetIndex].text = srControllers[sourceIndex].text;

      if (_trFromFr.remove(srControllers[sourceIndex])) {
        _trFromFr.add(srControllers[targetIndex]);
      }

      final hidden = _hiddenFr.remove(srControllers[sourceIndex]);
      _hiddenFr.remove(srControllers[targetIndex]);
      if (hidden != null) _hiddenFr[srControllers[targetIndex]] = hidden;

      numControllers[sourceIndex].clear();
      frControllers[sourceIndex].clear();
      srControllers[sourceIndex].clear();

      targetIndex++;
    }

    amountRevision.value++;
    if (mounted) setState(() {});
  }

  // ================= i AMOUNT LOGIC =================

  void handleAmountWithI(
    TextEditingController controller,
    String val,
    int rowIndex,
    bool isFr,
  ) {
    final upperVal = val.toUpperCase();

    if (!upperVal.endsWith('I')) return;

    final amountText = upperVal.substring(0, upperVal.length - 1);
    final amount = int.tryParse(amountText);

    if (amount == null || amount < 1 || amount > 15000) {
      controller.clear();
      return;
    }

    controller.value = TextEditingValue(
      text: amountText,
      selection: TextSelection.collapsed(offset: amountText.length),
    );

    final controllers = isFr ? frControllers : srControllers;
    final sortedIndexes = getSortedRowIndexes();
    final currentPosition = sortedIndexes.indexOf(rowIndex);

    if (currentPosition == -1) return;

    final numericRowPattern = RegExp(r'^\d{2}$');

    bool isNormalNumericRow(String value) {
      return numericRowPattern.hasMatch(value);
    }

    int lastBlankNumericPosition = -1;

    for (
      int position = currentPosition + 1;
      position < sortedIndexes.length;
      position++
    ) {
      final index = sortedIndexes[position];
      final numberText = numControllers[index].text.trim();

      if (isNormalNumericRow(numberText) &&
          controllers[index].text.trim().isEmpty) {
        lastBlankNumericPosition = position;
      }
    }

    for (
      int position = currentPosition + 1;
      position < sortedIndexes.length;
      position++
    ) {
      final belowIndex = sortedIndexes[position];
      final numberText = numControllers[belowIndex].text.trim();

      if (!isNormalNumericRow(numberText)) continue;

      if (controllers[belowIndex].text.trim().isEmpty) {
        controllers[belowIndex].text = amountText;
        continue;
      }

      if (lastBlankNumericPosition > position) {
        break;
      }
    }
  }

  // ================= NEXT SCREEN =================

  Future<void> goToNextScreen() async {
    if (!canProceed()) return;

    final List<Map<String, String>> data = [];

    for (int i = 0; i < numControllers.length; i++) {
      final num = numControllers[i].text.trim();

      if (num.isNotEmpty) {
        data.add({
          'num': num,
          'fr':
              frControllers[i].text.trim().isEmpty
                  ? 'Nil'
                  : frControllers[i].text.trim(),
          'sr':
              srControllers[i].text.trim().isEmpty
                  ? 'Nil'
                  : srControllers[i].text.trim(),
        });
      }
    }

    if (data.isEmpty) return;

    hideKeyboard();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => SecondScreen(
              data: data,
              name: nameController.text.trim(),
              isTRMode: isTRMode,
            ),
      ),
    );

    if (!mounted) return;

    await _loadTodayReceiptCount();

    if (!mounted) return;

    hideKeyboard();
  }

  // ================= UI =================

  Widget buildRow(int index) {
    const double gap = 3;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: spaceAwareField(
              controller: numControllers[index],
              focusNode: numFocusNodes[index],
              rowIndex: index,
              fieldType: 'num',
              width: double.infinity,
              enabled: isNumEnabled(index),
              keyboardType: TextInputType.text,
              inputFormatters: [
                LengthLimitingTextInputFormatter(4),
                TextInputFormatter.withFunction((oldValue, newValue) {
                  final text = newValue.text.toUpperCase();
                  final value = TextEditingValue(
                    text: text,
                    selection: newValue.selection,
                  );

                  if (text.isEmpty || text.endsWith(' ')) {
                    return value;
                  }

                  if (RegExp(r'^[0-9]$').hasMatch(text) ||
                      RegExp(r'^[AH]$').hasMatch(text) ||
                      text == 'AP' ||
                      text == 'HP' ||
                      RegExp(r'^[0-9]{2}$').hasMatch(text) ||
                      RegExp(r'^[0-9][HE]$').hasMatch(text) ||
                      RegExp(r'^[0-9]{2}V$').hasMatch(text)) {
                    return value;
                  }

                  return oldValue;
                }),
              ],
              onChanged: (val) {
                final value = val.trim().toUpperCase();

                if (value.length >= 2 && isValidCompletedNumber(value)) {
                  checkDuplicateNumber(value, index);
                } else {
                  warnedDuplicateRows.remove(index);
                }

                if (val.endsWith(' ')) {
                  handleSpaceInput(numControllers[index], val, index, 'num');
                }

                if (val.isEmpty) {
                  compactRowsAfterDelete(index);
                }
              },
              onSubmitted: (_) {
                final value = numControllers[index].text.trim().toUpperCase();

                if (!isValidCompletedNumber(value)) {
                  FocusScope.of(context).requestFocus(numFocusNodes[index]);
                  return;
                }

                checkDuplicateNumber(value, index);
                moveToNextAmount(index, 'num');
              },
              decoration: const InputDecoration(),
            ),
          ),

          const SizedBox(width: gap),

          if (!isTRMode) ...[
            Expanded(
              child: spaceAwareField(
                controller: frControllers[index],
                focusNode: frFocusNodes[index],
                rowIndex: index,
                fieldType: 'fr',
                width: double.infinity,
                enabled: isFirstFilled(index),
                keyboardType: TextInputType.text,
                inputFormatters: [AmountInputFormatter()],
                onChanged: (val) {
                  if (val.endsWith(' ')) {
                    handleSpaceInput(frControllers[index], val, index, 'fr');
                  } else {
                    handleAmountWithI(frControllers[index], val, index, true);
                  }
                },
                onSubmitted: (_) => moveToNextAmount(index, 'fr'),
                decoration: const InputDecoration(prefixText: '₹ '),
              ),
            ),
            const SizedBox(width: gap),
          ],

          Expanded(
            child: spaceAwareField(
              controller: srControllers[index],
              focusNode: srFocusNodes[index],
              rowIndex: index,
              fieldType: 'sr',
              width: double.infinity,
              enabled: isFirstFilled(index),
              keyboardType: TextInputType.text,
              inputFormatters: [AmountInputFormatter()],
              onChanged: (val) {
                if (val.endsWith(' ')) {
                  handleSpaceInput(srControllers[index], val, index, 'sr');
                } else {
                  handleAmountWithI(srControllers[index], val, index, false);
                }
              },
              onSubmitted:
                  (_) => moveToNextAmount(index, isTRMode ? 'tr' : 'sr'),
              decoration: const InputDecoration(prefixText: '₹ '),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _workingSaveTimer?.cancel();
    _historyTimer?.cancel();
    _undoFocus.dispose();
    _redoFocus.dispose();
    _autoTrTimer?.cancel();

    // Save the latest working list before disposing.
    _saveWorkingState();

    WidgetsBinding.instance.removeObserver(this);

    for (final c in numControllers) {
      c.dispose();
    }

    for (final c in frControllers) {
      c.dispose();
    }

    for (final c in srControllers) {
      c.dispose();
    }

    for (final node in numFocusNodes) {
      node.dispose();
    }

    for (final node in frFocusNodes) {
      node.dispose();
    }

    for (final node in srFocusNodes) {
      node.dispose();
    }

    nameController.dispose();
    amountRevision.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_modeLoaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final sortedIndexes = getSortedRowIndexes();

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: _pageColor,
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Menu',
          icon: const Icon(Icons.menu, color: _primaryColor),
          onPressed: showAppMenu,
        ),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: SizedBox(
          width: 150,
          height: 40,
          child: TextField(
            controller: nameController,
            textAlignVertical: TextAlignVertical.center,
            decoration: const InputDecoration(
              hintText: 'Enter name',
              contentPadding: EdgeInsets.symmetric(horizontal: 10),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: OutlinedButton(
              onPressed: () async {
                final newMode = !isTRMode;

                setState(() {
                  if (newMode) {
                    _convertAmountsForTRMode();
                  } else {
                    _convertAmountsForFRSRMode();
                  }
                  isTRMode = newMode;
                });

                await _saveMode(newMode);
                _scheduleWorkingSave();
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: _primaryColor,
                backgroundColor: const Color(0xFFF1F6FD),
                side: const BorderSide(color: Color(0xFFD5E4F8)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              child: Text(
                isTRMode ? 'TR' : 'FR, SR',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 5),
            child: Row(
              children: [
                Expanded(
                  child: Center(
                    child: Text(
                      'Num(${numControllers.where((c) => c.text.trim().isNotEmpty).length})',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                        color: Color(0xFF687282),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 3),

                if (!isTRMode) ...[
                  Expanded(
                    child: Center(
                      child: Text(
                        'FR',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                          color: Color(0xFF687282),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                ],

                Expanded(
                  child: Center(
                    child: Text(
                      isTRMode ? 'TR' : 'SR',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                        color: Color(0xFF687282),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: sortedIndexes.length,
              itemBuilder: (context, index) => buildRow(sortedIndexes[index]),
            ),
          ),

          ValueListenableBuilder<int>(
            valueListenable: amountRevision,
            builder: (context, _, child) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(top: BorderSide(color: Color(0xFFE0E3E8))),
                ),
                child: SizedBox(
                  height: 46,
                  child: Row(
                    children: [
                      // Gallery
                      Expanded(
                        child: IconButton(
                          tooltip: 'Saved tokens',
                          onPressed: _openSavedReceipts,
                          icon: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              const Icon(Icons.photo_library_outlined),
                              if (_todayReceiptCount > 0)
                                Positioned(
                                  right: -9,
                                  top: -7,
                                  child: Container(
                                    padding: const EdgeInsets.all(3),
                                    constraints: const BoxConstraints(
                                      minWidth: 17,
                                      minHeight: 17,
                                    ),
                                    decoration: const BoxDecoration(
                                      color: Colors.red,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Text(
                                      '$_todayReceiptCount',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          iconSize: 25,
                          padding: EdgeInsets.zero,
                        ),
                      ),

                      // Clear All
                      Expanded(
                        child: IconButton(
                          tooltip: 'Clear all',
                          onPressed: _confirmClearAll,
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.red,
                          ),
                          iconSize: 25,
                          padding: EdgeInsets.zero,
                        ),
                      ),

                      // Paste
                      Expanded(
                        child: IconButton(
                          tooltip: 'Paste token rows',
                          onPressed: pasteTokenData,
                          icon: const Icon(Icons.content_paste),
                          iconSize: 25,
                          padding: EdgeInsets.zero,
                        ),
                      ),

                      // Total
                      // Undo / Redo + Total
                      Expanded(
                        flex: 2,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 40,
                              height: 40,
                              child: IconButton(
                                tooltip: 'Undo',
                                focusNode: _undoFocus,
                                onPressed:
                                    (_undoStack.isNotEmpty ||
                                            _historyTimer != null)
                                        ? _undo
                                        : null,
                                icon: const Icon(Icons.undo),
                                iconSize: 20,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                              ),
                            ),
                            SizedBox(
                              width: 40,
                              height: 40,
                              child: IconButton(
                                tooltip: 'Redo',
                                focusNode: _redoFocus,
                                onPressed: _redoStack.isNotEmpty ? _redo : null,
                                icon: const Icon(Icons.redo),
                                iconSize: 20,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                              ),
                            ),
                            Expanded(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.center,
                                child: Text(
                                  '₹ ${getTotalAmount()}',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Next
                      Expanded(
                        child: Center(
                          child: SizedBox(
                            width: 40,
                            height: 40,
                            child: FloatingActionButton(
                              mini: true,
                              elevation: 1,
                              backgroundColor:
                                  canProceed() ? Colors.blue : Colors.grey,
                              foregroundColor: Colors.white,
                              onPressed:
                                  canProceed()
                                      ? () {
                                        if (isTRMode) {
                                          for (
                                            int i = 0;
                                            i < numControllers.length;
                                            i++
                                          ) {
                                            if (numControllers[i].text
                                                    .trim()
                                                    .isNotEmpty &&
                                                srControllers[i].text
                                                    .trim()
                                                    .isEmpty) {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                const SnackBar(
                                                  content: Text(
                                                    'Please fill all TR amount boxes before continuing.',
                                                  ),
                                                ),
                                              );
                                              return;
                                            }
                                          }
                                        }

                                        goToNextScreen();
                                      }
                                      : null,
                              child: const Icon(Icons.arrow_forward, size: 20),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class AmountInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;

    // Allow up to 5 digits, optional I at the end,
    // or one trailing space for keyboard navigation.
    if (RegExp(r'^\d{0,5}[Ii]?$').hasMatch(text) ||
        RegExp(r'^\d{0,5}[Ii]? $').hasMatch(text)) {
      return newValue;
    }

    return oldValue;
  }
}

class _IGuideAnimation extends StatefulWidget {
  final bool showFr;

  const _IGuideAnimation({required this.showFr});

  @override
  State<_IGuideAnimation> createState() => _IGuideAnimationState();
}

class _IGuideAnimationState extends State<_IGuideAnimation> {
  static const Color _primary = Color(0xFF2878D0);
  static const Color _border = Color(0xFFD5D9E0);
  static const Color _numFill = Color(0xFFE6F4FF);
  static const Color _filledFlash = Color(0xFFE3F6E8);

  static const List<String> _nums = ['10', '11', '12', '13'];

  // Steps:
  // 0 empty | 1 "1" | 2 "10" | 3 "10i"
  // 4 row 2 filled | 5 row 3 filled | 6 row 4 filled
  // 7-9 hold, then loop
  static const int _totalSteps = 7;

  Timer? _timer;
  int _step = 0;

  @override
  void initState() {
    super.initState();

    _timer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (!mounted) return;
      setState(() {
        _step = (_step + 1) % _totalSteps;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // Text shown in the animated amount box of each row.
  // Text shown in the animated amount box of each row.
  String _amountFor(int row) {
    if (row == 0) {
      if (_step == 0) return '';
      if (_step == 1) return '1';
      if (_step == 2) return '10';
      if (_step == 3) return '10i';
      return '10'; // "i" disappears at the same moment the boxes fill
    }

    // Every box below fills at the same time, right after "10i".
    return _step >= 4 ? '10' : '';
  }

  Widget _label(String text) {
    return Expanded(
      child: Center(
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
            color: Color(0xFF687282),
          ),
        ),
      ),
    );
  }

  Widget _box({
    required String text,
    bool isNum = false,
    bool focused = false,
    bool justFilled = false,
  }) {
    final hasI = text.endsWith('i');
    final amount = hasI ? text.substring(0, text.length - 1) : text;

    return Expanded(
      child: AnimatedScale(
        scale: justFilled ? 1.07 : 1.0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutBack,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color:
                isNum
                    ? _numFill
                    : justFilled
                    ? _filledFlash
                    : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: focused ? _primary : _border,
              width: focused ? 1.7 : 1,
            ),
          ),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: amount),
                if (hasI)
                  const TextSpan(text: 'i', style: TextStyle(color: _primary)),
              ],
            ),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTyping = _step >= 1 && _step <= 3;

    return Column(
      children: [
        Row(
          children: [
            _label('Num'),
            const SizedBox(width: 5),
            if (widget.showFr) ...[_label('FR'), const SizedBox(width: 5)],
            _label(widget.showFr ? 'SR' : 'TR'),
          ],
        ),
        const SizedBox(height: 6),
        for (int row = 0; row < _nums.length; row++) ...[
          Row(
            children: [
              _box(text: _nums[row], isNum: true),
              const SizedBox(width: 5),

              // The animated amount box is the first amount column:
              // FR in FR/SR mode, TR in TR mode.
              _box(
                text: _amountFor(row),
                focused: row == 0 && isTyping,
                justFilled: row > 0 && _step == 4,
              ),

              // The second amount column (SR) stays empty in FR/SR mode.
              if (widget.showFr) ...[const SizedBox(width: 5), _box(text: '')],
            ],
          ),
          if (row != _nums.length - 1) const SizedBox(height: 6),
        ],
      ],
    );
  }
}
