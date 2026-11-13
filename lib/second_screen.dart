import 'package:gal/gal.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:token_taker/receipt_viewer_screen.dart';
import 'package:token_taker/receipttotal_calculate_sharehelper.dart';
import 'package:token_taker/saved_tokens.dart';

class SecondScreen extends StatefulWidget {
  final List<Map<String, String>> data;
  final String name;
  final bool isTRMode;

  const SecondScreen({
    super.key,
    required this.data,
    required this.name,
    this.isTRMode = false,
  });

  @override
  State<SecondScreen> createState() => _SecondScreenState();
}

class _SecondScreenState extends State<SecondScreen> {
  Color _currentReceiptBackground = Colors.white;
  Color _receiptBackground(int index) {
    const colors = [
      Color(0xFFFFFFFF), // White (lightest)
      Color(0xFFFFF59D), // Strong yellow
      Color(0xFFA5D6A7), // Medium green
      Color(0xFF90CAF9), // Medium blue
      Color(0xFFFFCC80), // Medium orange
      Color(0xFFCE93D8), // Medium purple
      Color(0xFFEF9A9A), // Medium red/pink
      Color(0xFFB0BEC5), // Medium grey
      Color(0xFF80DEEA), // Medium cyan
    ];

    return colors[index % colors.length];
  }

  static const String _saveToDeviceGalleryKey = 'save_to_device_gallery';
  static const String _saveDestinationKey = 'save_destination';

  // 0 = app only, 1 = device gallery only, 2 = both
  Future<int> _loadSaveDestination() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_saveDestinationKey);
    if (saved != null && saved >= 0 && saved <= 2) return saved;

    // Older versions stored a true/false switch.
    final legacy = prefs.getBool(_saveToDeviceGalleryKey) ?? true;
    return legacy ? 2 : 0;
  }

  late Timer timer;
  DateTime currentTime = DateTime.now();

  final GlobalKey _receiptKey = GlobalKey();

  List<File> _savedReceipts = [];

  static const String _lastGalleryViewedKey = 'token_taker_last_gallery_viewed';

  int _todayReceiptCount = 0;

  Future<void> _loadTodayReceiptCount() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      int? lastViewed = prefs.getInt(_lastGalleryViewedKey);

      // First launch: start tracking from now.
      if (lastViewed == null) {
        lastViewed = DateTime.now().millisecondsSinceEpoch;
        await prefs.setInt(_lastGalleryViewedKey, lastViewed);
      }

      final directory = await _getReceiptsDirectory();
      int count = 0;

      for (final file in directory.listSync().whereType<File>()) {
        if (!file.path.toLowerCase().endsWith('.jpg')) continue;

        final modified = await file.lastModified();

        if (modified.millisecondsSinceEpoch > lastViewed) {
          count++;
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

  Future<Directory> _getReceiptsDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final directory = Directory('${appDir.path}/saved_receipts');

    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    return directory;
  }

  Future<void> _loadSavedReceipts() async {
    try {
      final directory = await _getReceiptsDirectory();

      final files =
          directory
              .listSync()
              .whereType<File>()
              .where((file) => file.path.toLowerCase().endsWith('.jpg'))
              .toList();

      files.sort(
        (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
      );

      if (mounted) {
        setState(() {
          _savedReceipts = files;
        });
      }
    } catch (e) {
      debugPrint('Loading saved receipts failed: $e');
    }
  }

  Future<void> _viewSavedReceipt(File file) async {
    final exists = await file.exists();

    if (!mounted || !exists) return;

    // Load all saved receipts, sorted newest first.
    final directory = await _getReceiptsDirectory();

    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.jpg'))
            .toList();

    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

    // Find the newly saved receipt.
    final initialIndex = files.indexWhere((f) => f.path == file.path);

    if (!mounted || initialIndex == -1) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => ReceiptViewerScreen(
              files: files,
              initialIndex: initialIndex,
              onShare:
                  (file) =>
                      ShareHelper.shareFiles([file], onNotice: _showMessage),
            ),
      ),
    );
  }

  Future<void> _showSavedReceipts() async {
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

    await _loadSavedReceipts();

    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SavedReceiptsScreen(receipts: _savedReceipts),
      ),
    );

    if (!mounted) return;

    await _loadTodayReceiptCount();
  }

  bool _isBusy = false;

  bool _alreadySaved = false;

  void _markSaved() {
    if (mounted) setState(() => _alreadySaved = true);
  }

  bool _isHEGroup(String numText) {
    return (numText.length == 2 &&
            int.tryParse(numText[0]) != null &&
            (numText[1] == 'H' || numText[1] == 'E')) ||
        numText == 'AP' ||
        numText == 'HP';
  }

  bool _isVGroup(String numText) {
    return numText.length == 3 && RegExp(r'^[0-9]{2}V$').hasMatch(numText);
  }

  int _getGroup(String numText) {
    if (_isVGroup(numText)) return 2;
    if (_isHEGroup(numText)) return 1;
    return 0;
  }

  @override
  void initState() {
    super.initState();

    _loadSavedReceipts();
    _loadTodayReceiptCount();

    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          currentTime = DateTime.now();
        });
      }
    });
  }

  @override
  void dispose() {
    timer.cancel();
    super.dispose();
  }

  // TOTAL AMOUNT

  int getTotalAmount() {
    int total = 0;

    for (final item in widget.data) {
      final numText = item['num'] ?? '';
      final fr = widget.isTRMode ? 0 : (int.tryParse(item['fr'] ?? '') ?? 0);
      final sr = int.tryParse(item['sr'] ?? '') ?? 0;

      final isSingleWithHE =
          (numText.length == 2 &&
              int.tryParse(numText[0]) != null &&
              (numText[1] == 'H' || numText[1] == 'E')) ||
          numText == 'AP' ||
          numText == 'HP';

      final isDoubleWithV =
          numText.length == 3 && RegExp(r'^[0-9]{2}V$').hasMatch(numText);

      if (isSingleWithHE) {
        total += (fr * 10) + (sr * 10);
      } else if (isDoubleWithV) {
        final base = numText.substring(0, 2);

        final a = int.parse(base[0]);
        final b = int.parse(base[1]);

        final cA = a >= 5 ? a - 5 : a + 5;
        final cB = b >= 5 ? b - 5 : b + 5;

        final numbers = <String>{
          '$a$b',
          '$b$a',
          '$cA$cB',
          '$cB$cA',
          '$a$cB',
          '$cB$a',
          '$cA$b',
          '$b$cA',
        };

        total += (fr * numbers.length) + (sr * numbers.length);
      } else {
        total += fr + sr;
      }
    }

    return total;
  }

  // SORT DATA

  List<Map<String, String>> getSortedData() {
    final normal = <Map<String, String>>[];
    final he = <Map<String, String>>[];
    final v = <Map<String, String>>[];

    for (final item in widget.data) {
      final numText = item['num'] ?? '';

      final isSingleWithHE =
          (numText.length == 2 &&
              int.tryParse(numText[0]) != null &&
              (numText[1] == 'H' || numText[1] == 'E')) ||
          numText == 'AP' ||
          numText == 'HP';

      final isDoubleWithV =
          numText.length == 3 && RegExp(r'^[0-9]{2}V$').hasMatch(numText);

      if (isDoubleWithV) {
        v.add(item);
      } else if (isSingleWithHE) {
        he.add(item);
      } else {
        normal.add(item);
      }
    }

    return [...normal, ...he, ...v];
  }

  // DISPLAY VALUES

  String displayValue(String value) {
    if (value.trim().isEmpty || value.toLowerCase() == 'nil') {
      return 'X';
    }

    return '₹ $value';
  }

  String displayTRValue(String value) {
    if (value.trim().isEmpty || value.toLowerCase() == 'nil') {
      return 'X';
    }

    return '₹ $value';
  }

  // DATE AND TIME

  // DATE AND TIME — 12-hour format

  String formatDateTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');

    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final period = dt.hour >= 12 ? 'PM' : 'AM';

    return '${two(dt.day)}/${two(dt.month)}/${dt.year} '
        '${two(hour12)}:${two(dt.minute)}:${two(dt.second)} $period';
  }

  // BORDERLESS TABLE HEADER

  TableRow _buildHeaderRow() {
    return TableRow(
      children: [
        _cell('Num', isHeader: true),
        if (widget.isTRMode)
          _cell('TR', isHeader: true)
        else ...[
          _cell('FR', isHeader: true),
          _cell('SR', isHeader: true),
        ],
      ],
    );
  }

  // BORDERLESS TABLE DATA ROW

  TableRow _buildDataRow(Map<String, String> item, {bool showDivider = false}) {
    return TableRow(
      decoration:
          showDivider
              ? const BoxDecoration(
                border: Border(
                  top: BorderSide(color: Color(0xFF999999), width: 0.6),
                ),
              )
              : null,
      children: [
        _cell(item['num'] ?? ''),
        if (widget.isTRMode)
          _cell(displayTRValue(item['sr'] ?? ''))
        else ...[
          _cell(displayValue(item['fr'] ?? '')),
          _cell(displayValue(item['sr'] ?? '')),
        ],
      ],
    );
  }

  Widget _cell(String value, {bool isHeader = false}) {
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: isHeader ? 5 : 2.2, // <-- SPACE between rows
        horizontal: 3,
      ),
      child: Text(
        value,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.black,
          fontSize: isHeader ? 14 : 17, // <-- TEXT SIZE
          fontWeight:
              isHeader
                  ? FontWeight.w700
                  : (value.isNotEmpty && !value.startsWith('₹') && value != 'X'
                      ? FontWeight.w600
                      : FontWeight.w500),
          height: 1.1, // <-- line height (also affects space)
        ),
      ),
    );
  }

  Map<int, TableColumnWidth> get _columnWidths {
    if (widget.isTRMode) {
      return const {0: FlexColumnWidth(2), 1: FlexColumnWidth(2)};
    }

    return const {
      0: FlexColumnWidth(2),
      1: FlexColumnWidth(2),
      2: FlexColumnWidth(2),
    };
  }

  // CAPTURE RECEIPT AS PNG
  Future<Uint8List?> _captureReceiptPng() async {
    try {
      await WidgetsBinding.instance.endOfFrame;

      if (!mounted) return null;

      final receiptContext = _receiptKey.currentContext;

      if (receiptContext == null || !receiptContext.mounted) {
        debugPrint('Receipt context is null or unmounted');
        return null;
      }

      final renderObject = receiptContext.findRenderObject();

      if (renderObject is! RenderRepaintBoundary) {
        debugPrint('Receipt boundary is null or invalid');
        return null;
      }

      final boundary = renderObject;

      await Future.delayed(const Duration(milliseconds: 300));

      if (!mounted ||
          !receiptContext.mounted ||
          !boundary.attached ||
          !boundary.hasSize) {
        debugPrint('Receipt boundary is no longer ready');
        return null;
      }

      await WidgetsBinding.instance.endOfFrame;

      if (!mounted ||
          !receiptContext.mounted ||
          !boundary.attached ||
          !boundary.hasSize) {
        debugPrint('Receipt boundary is no longer ready after frame');
        return null;
      }

      final image = await boundary.toImage(pixelRatio: 3.0);

      try {
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

        if (byteData == null) {
          debugPrint('Receipt PNG byteData is null');
          return null;
        }

        return byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        );
      } finally {
        image.dispose();
      }
    } catch (e, stackTrace) {
      debugPrint('Receipt capture error: $e');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  void _showMessage(String message, {VoidCallback? onView}) {
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();

    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Expanded(child: Text(message)),
            if (onView != null) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  messenger.hideCurrentSnackBar();
                  onView();
                },
                child: const Text(
                  'View',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,

        // Keep SnackBar above the bottom navigation bar.
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 100),
      ),
    );
  }

  // SAVE RECEIPT AS JPG
  Future<void> _handlePrintTap() async {
    if (_isBusy || _alreadySaved) return;

    setState(() => _isBusy = true);

    try {
      final directory = await _getReceiptsDirectory();

      final existingFiles =
          directory
              .listSync()
              .whereType<File>()
              .where((file) => file.path.toLowerCase().endsWith('.jpg'))
              .length;

      // Choose the background before capturing the receipt.
      setState(() {
        _currentReceiptBackground = _receiptBackground(existingFiles);
      });

      await WidgetsBinding.instance.endOfFrame;

      final pngBytes = await _captureReceiptPng();

      if (pngBytes == null) {
        _showMessage('Image capture failed.');
        return;
      }

      final decodedImage = img.decodeImage(pngBytes);

      if (decodedImage == null) {
        _showMessage('Could not convert receipt to JPG.');
        return;
      }

      final jpgBytes = Uint8List.fromList(
        img.encodeJpg(decodedImage, quality: 95),
      );

      final now = DateTime.now();

      String two(int n) => n.toString().padLeft(2, '0');

      final hour12 = now.hour % 12 == 0 ? 12 : now.hour % 12;
      final period = now.hour >= 12 ? 'PM' : 'AM';

      final fileName =
          '${two(now.day)}-${two(now.month)}-${two(now.year % 100)}_'
          '${two(hour12)}-${two(now.minute)}-${two(now.second)}_$period.jpg';

      final destination = await _loadSaveDestination();
      final saveToApp = destination != 1;
      final saveToGallery = destination != 0;

      // Gallery-only images go to a temporary folder, so they never
      // appear in the app's Saved Tokens screen.
      final targetDir = saveToApp ? directory : await getTemporaryDirectory();
      final file = File('${targetDir.path}/$fileName');

      await file.writeAsBytes(jpgBytes, flush: true);

      Future<void> deleteTempIfNeeded() async {
        if (saveToApp) return;
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }

      if (saveToApp) {
        await ReceiptTotals.save(fileName, getTotalAmount());
        await _loadTodayReceiptCount();
        await _loadSavedReceipts();
        _markSaved();
      }

      // ---- App only ----
      if (!saveToGallery) {
        _showMessage(
          'Image saved in the app.',
          onView: () => _viewSavedReceipt(file),
        );
        return;
      }

      // ---- Gallery (only, or both) ----
      bool hasAccess = await Gal.hasAccess();
      if (!hasAccess) hasAccess = await Gal.requestAccess();

      if (!hasAccess) {
        await deleteTempIfNeeded();

        if (saveToApp) {
          _showMessage(
            'Image saved in the app, but Gallery permission was denied.',
            onView: () => _viewSavedReceipt(file),
          );
        } else {
          _showMessage('Gallery permission was denied. Image was not saved.');
        }
        return;
      }

      await Gal.putImage(file.path);
      _markSaved();
      await deleteTempIfNeeded();

      if (saveToApp) {
        _showMessage(
          'Image saved in the app and device Gallery.',
          onView: () => _viewSavedReceipt(file),
        );
      } else {
        _showMessage('Image saved in the device Gallery.');
      }
    } catch (e) {
      _showMessage('Could not save Image: $e');
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  // Width of a text, used to line things up with the table columns.
  double _textWidth(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return painter.width;
  }

  Widget _buildOffscreenReceipt() {
    final sortedData = getSortedData();
    final totalAmount = getTotalAmount();

    // Narrower image + small side padding = bigger, clearer text.
    const double receiptWidth = 330;
    const double hPad = 6;
    const double contentWidth = receiptWidth - (hPad * 2);

    final cols = widget.isTRMode ? 2 : 3;
    final colW = contentWidth / cols;

    const headerStyle = TextStyle(fontSize: 14, fontWeight: FontWeight.w700);
    const amountStyle = TextStyle(fontSize: 16, fontWeight: FontWeight.w500);
    const dateStyle = TextStyle(fontSize: 11);

    final dateText = formatDateTime(currentTime);

    // Name starts exactly above the "Num" text.
    final numW = _textWidth('Num', headerStyle);
    final nameLeft = (colW - numW) / 2;

    // Date ends exactly above the end of the "SR" / "TR" text.
    final lastHeader = widget.isTRMode ? 'TR' : 'SR';
    final lastHeaderW = _textWidth(lastHeader, headerStyle);
    final lastColStart = colW * (cols - 1);
    final headerRight = lastColStart + (colW + lastHeaderW) / 2;
    final dateRightPad = contentWidth - headerRight;

    // Total ends exactly below the widest SR / TR amount.
    double widestAmount = 0;
    for (final item in sortedData) {
      final shown =
          widget.isTRMode
              ? displayTRValue(item['sr'] ?? '')
              : displayValue(item['sr'] ?? '');
      final w = _textWidth(shown, amountStyle);
      if (w > widestAmount) widestAmount = w;
    }
    final amountRight = lastColStart + (colW + widestAmount) / 2;
    final totalRightPad = contentWidth - amountRight;

    return Material(
      color: _currentReceiptBackground,
      child: SizedBox(
        width: receiptWidth,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: hPad, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  SizedBox(width: nameLeft),
                  // Name is cut off if there is no space. Date is never hidden.
                  Expanded(
                    child: Text(
                      widget.name,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: dateStyle.copyWith(color: Colors.black54),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    dateText,
                    maxLines: 1,
                    softWrap: false,
                    style: dateStyle.copyWith(color: Colors.black54),
                  ),
                  SizedBox(width: dateRightPad),
                ],
              ),

              const SizedBox(height: 6),

              Table(
                columnWidths: _columnWidths,
                children: [
                  _buildHeaderRow(),
                  ...sortedData.asMap().entries.map((entry) {
                    final index = entry.key;
                    final item = entry.value;

                    final showDivider =
                        index > 0 &&
                        _getGroup(item['num'] ?? '') !=
                            _getGroup(sortedData[index - 1]['num'] ?? '');

                    return _buildDataRow(item, showDivider: showDivider);
                  }),
                ],
              ),

              const SizedBox(height: 6),

              Padding(
                padding: EdgeInsets.only(
                  right: totalRightPad < 0 ? 0 : totalRightPad,
                ),
                child: Text(
                  'Total: ₹ $totalAmount',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // BUILD SCREEN

  @override
  Widget build(BuildContext context) {
    final totalAmount = getTotalAmount();
    final sortedData = getSortedData();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name, style: const TextStyle(fontSize: 14)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                formatDateTime(currentTime),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),

      body: Stack(
        children: [
          Column(
            children: [
              // FIXED HEADER
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Table(
                  columnWidths: _columnWidths,
                  children: [_buildHeaderRow()],
                ),
              ),

              // NO DIVIDER, CARD, OR ROW BORDER
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 0,
                  ),
                  children: [
                    ...sortedData.asMap().entries.map((entry) {
                      final index = entry.key;
                      final item = entry.value;

                      final showDivider =
                          index > 0 &&
                          _getGroup(item['num'] ?? '') !=
                              _getGroup(sortedData[index - 1]['num'] ?? '');

                      return Table(
                        columnWidths: _columnWidths,
                        children: [
                          _buildDataRow(item, showDivider: showDivider),
                        ],
                      );
                    }),

                    const SizedBox(height: 8),

                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        'Total: ₹ $totalAmount',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ],
          ),

          // OFFSCREEN RECEIPT FOR JPG CAPTURE
          Positioned(
            left: 0,
            top: 0,
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.01,
                child: RepaintBoundary(
                  key: _receiptKey,
                  child: _buildOffscreenReceipt(),
                ),
              ),
            ),
          ),
        ],
      ),

      // BOTTOM BAR
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Saved receipts',
                onPressed: _showSavedReceipts,
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
                iconSize: 28,
              ),

              const Spacer(),

              ElevatedButton.icon(
                onPressed: (_isBusy || _alreadySaved) ? null : _handlePrintTap,
                icon:
                    _isBusy
                        ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : Icon(_alreadySaved ? Icons.check : Icons.save_alt),
                label: Text(
                  _isBusy ? 'Saving...' : (_alreadySaved ? 'Saved' : 'Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
