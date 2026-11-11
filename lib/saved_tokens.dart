import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

/// Smooth fade when opening the viewer.
Route<T> _fadeRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondary) => page,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    transitionsBuilder: (context, animation, secondary, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      );
    },
  );
}

/// Folders for saved and trashed receipts.
class ReceiptStorage {
  static Future<Directory> _folder(String name) async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/$name');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> receiptsDir() => _folder('saved_receipts');
  static Future<Directory> trashDir() => _folder('trash_receipts');

  static Future<List<File>> listJpgs(Directory dir) async {
    if (!await dir.exists()) return [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.jpg'))
        .toList();
  }

  /// Moves a file and keeps its original date and time.
  static Future<void> move(File file, Directory target) async {
    final newPath = '${target.path}/${ReceiptTotals.nameOf(file)}';
    try {
      await file.rename(newPath);
    } on FileSystemException {
      final modified = await file.lastModified();
      final copy = await file.copy(newPath);
      await copy.setLastModified(modified);
      await file.delete();
    }
  }

  static Future<void> moveToTrash(File file) async =>
      move(file, await trashDir());

  static Future<void> restore(File file) async =>
      move(file, await receiptsDir());

  static Future<void> deleteForever(File file) async {
    if (await file.exists()) await file.delete();
    await ReceiptTotals.removeAll([ReceiptTotals.nameOf(file)]);
  }
}

class SavedReceiptsScreen extends StatefulWidget {
  final List<File> receipts;

  const SavedReceiptsScreen({super.key, required this.receipts});

  @override
  State<SavedReceiptsScreen> createState() => _SavedReceiptsScreenState();
}

class _SavedReceiptsScreenState extends State<SavedReceiptsScreen> {
  late List<File> _receipts;
  List<File> _trash = [];
  final Set<String> _selectedPaths = {};
  Map<String, int> _totals = {};
  bool _inTrash = false;

  final ScrollController _scroll = ScrollController();
  final GlobalKey _listKey = GlobalKey();
  final Map<String, GlobalKey> _cellKeys = {};

  // Hold-and-slide selection state.
  int? _anchorIndex;
  Set<String> _baseSelection = {};
  Offset? _dragPos;
  Timer? _autoScrollTimer;

  List<File> get _current => _inTrash ? _trash : _receipts;
  bool get _isSelecting => _selectedPaths.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _receipts = List<File>.from(widget.receipts);
    _sort(_receipts);
    _loadTotals();
    _loadTrash();
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _sort(List<File> files) {
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  }

  Future<void> _loadTotals() async {
    final totals = await ReceiptTotals.loadAll();
    if (mounted) setState(() => _totals = totals);
  }

  Future<void> _loadTrash() async {
    final files = await ReceiptStorage.listJpgs(
      await ReceiptStorage.trashDir(),
    );
    _sort(files);
    if (!mounted) return;
    setState(() {
      _trash = files;
      if (_trash.isEmpty) _inTrash = false;
    });
  }

  Future<void> _reloadSaved() async {
    final files = await ReceiptStorage.listJpgs(
      await ReceiptStorage.receiptsDir(),
    );
    _sort(files);
    if (mounted) setState(() => _receipts = files);
  }

  String _formatReceiptTime(File file) {
    final date = file.lastModifiedSync();
    final hour12 = date.hour % 12 == 0 ? 12 : date.hour % 12;
    final period = date.hour >= 12 ? 'PM' : 'AM';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(hour12)}:${two(date.minute)} $period';
  }

  DateTime _dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  String _sectionTitle(File file) {
    final today = _dateOnly(DateTime.now());
    final fileDate = _dateOnly(file.lastModifiedSync());
    final difference = today.difference(fileDate).inDays;

    if (difference == 0) return 'Today';
    if (difference == 1) return 'Yesterday';

    return '${fileDate.day.toString().padLeft(2, '0')}/'
        '${fileDate.month.toString().padLeft(2, '0')}/'
        '${fileDate.year}';
  }

  Map<String, List<File>> _groupReceipts() {
    final groups = <String, List<File>>{};
    for (final file in _current) {
      groups.putIfAbsent(_sectionTitle(file), () => []).add(file);
    }
    return groups;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------- SELECTION ----------

  void _toggleSelection(File file) {
    setState(() {
      if (!_selectedPaths.remove(file.path)) {
        _selectedPaths.add(file.path);
      }
    });
  }

  bool _isSectionAllSelected(List<File> files) =>
      files.isNotEmpty && files.every((f) => _selectedPaths.contains(f.path));

  void _toggleSectionSelection(List<File> files) {
    setState(() {
      if (_isSectionAllSelected(files)) {
        _selectedPaths.removeAll(files.map((f) => f.path));
      } else {
        _selectedPaths.addAll(files.map((f) => f.path));
      }
    });
  }

  bool get _isEverythingSelected =>
      _current.isNotEmpty && _selectedPaths.length == _current.length;

  void _toggleSelectEverything() {
    setState(() {
      if (_isEverythingSelected) {
        _selectedPaths.clear();
      } else {
        _selectedPaths
          ..clear()
          ..addAll(_current.map((f) => f.path));
      }
    });
  }

  List<File> get _selectedFiles =>
      _current.where((f) => _selectedPaths.contains(f.path)).toList();

  // ---------- HOLD AND SLIDE TO SELECT ----------
  // Selects every image from where you held down to where your finger is now,
  // in reading order. Slide back up and the extra images are unselected.

  void _startDrag(File file, Offset global) {
    final i = _current.indexWhere((f) => f.path == file.path);
    if (i < 0) return;

    HapticFeedback.mediumImpact();

    _anchorIndex = i;
    _baseSelection = Set<String>.from(_selectedPaths);
    _dragPos = global;

    setState(() => _selectedPaths.add(file.path));
    _startAutoScroll();
  }

  void _dragMove(Offset global) {
    _dragPos = global;
    final index = _indexAt(global);
    if (index != null) _applyRange(index);
  }

  void _endDrag() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _dragPos = null;
    _anchorIndex = null;
  }

  void _applyRange(int currentIndex) {
    final anchor = _anchorIndex;
    if (anchor == null) return;

    final lo = math.min(anchor, currentIndex);
    final hi = math.max(anchor, currentIndex);

    final next = Set<String>.from(_baseSelection);
    for (int i = lo; i <= hi && i < _current.length; i++) {
      next.add(_current[i].path);
    }

    if (next.length == _selectedPaths.length &&
        next.containsAll(_selectedPaths)) {
      return;
    }

    setState(() {
      _selectedPaths
        ..clear()
        ..addAll(next);
    });
  }

  int? _indexAt(Offset global) {
    for (int i = 0; i < _current.length; i++) {
      final box =
          _cellKeys[_current[i].path]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;

      final local = box.globalToLocal(global);
      if ((Offset.zero & box.size).inflate(3).contains(local)) return i;
    }
    return null;
  }

  void _startAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final pos = _dragPos;
      if (pos == null || !_scroll.hasClients) return;

      final box = _listKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) return;

      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      const zone = 110.0;

      double delta = 0;
      if (pos.dy < top + zone) {
        delta = -((top + zone - pos.dy) / zone) * 18;
      } else if (pos.dy > bottom - zone) {
        delta = ((pos.dy - (bottom - zone)) / zone) * 18;
      }

      if (delta == 0) return;

      final target = (_scroll.offset + delta).clamp(
        0.0,
        _scroll.position.maxScrollExtent,
      );
      _scroll.jumpTo(target);

      final index = _indexAt(pos);
      if (index != null) _applyRange(index);
    });
  }

  // ---------- CALCULATE ----------

  void _showCalculationDialog() {
    final selected = _selectedFiles;

    int total = 0;
    int missing = 0;

    final rows = <Widget>[];

    for (final file in selected) {
      final amount = _totals[ReceiptTotals.nameOf(file)];
      if (amount == null) {
        missing++;
      } else {
        total += amount;
      }

      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_sectionTitle(file)}, ${_formatReceiptTime(file)}',
                ),
              ),
              Text(
                amount == null ? 'N/A' : '₹ $amount',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }

    showDialog<void>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(
              'Selected total (${selected.length} '
              '${selected.length == 1 ? 'receipt' : 'receipts'})',
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(child: ListView(shrinkWrap: true, children: rows)),
                  const Divider(height: 20),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Total',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Text(
                        '₹ $total',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  if (missing > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '$missing older ${missing == 1 ? 'receipt has' : 'receipts have'} '
                        'no saved amount and ${missing == 1 ? 'was' : 'were'} not counted.',
                        style: const TextStyle(fontSize: 12, color: Colors.red),
                      ),
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
          ),
    );
  }

  // ---------- OPEN / SHARE ----------

  Future<void> _openReceipt(File file, List<File> dayFiles) async {
    final initialIndex = dayFiles.indexWhere((item) => item.path == file.path);

    await Navigator.push(
      context,
      _fadeRoute(
        ReceiptViewerScreen(
          files: dayFiles,
          initialIndex: initialIndex < 0 ? 0 : initialIndex,
          isTrash: _inTrash,
          onShare: _inTrash ? null : (file) => _shareFiles([file]),
        ),
      ),
    );

    // The viewer may have deleted or restored images.
    if (!mounted) return;
    await _reloadSaved();
    await _loadTrash();
  }

  Future<void> _shareFiles(List<File> files) async {
    final existingFiles = <File>[];

    for (final file in files) {
      if (await file.exists()) existingFiles.add(file);
    }

    if (!mounted) return;

    if (existingFiles.isEmpty) {
      _showSnack('No receipt images found.');
      return;
    }

    try {
      await ShareHelper.shareFiles(existingFiles, onNotice: _showSnack);

      if (mounted && _isSelecting) {
        setState(() => _selectedPaths.clear());
      }
    } catch (e) {
      _showSnack('Unable to share receipts: $e');
    }
  }

  // ---------- TRASH ACTIONS ----------

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
    bool danger = true,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: TextButton.styleFrom(
                  foregroundColor: danger ? Colors.red : null,
                ),
                child: Text(action),
              ),
            ],
          ),
    );
    return result == true;
  }

  String _countText(int n) => '$n ${n == 1 ? 'receipt' : 'receipts'}';

  Future<void> _moveSelectedToTrash() async {
    final files = _selectedFiles;
    if (files.isEmpty) return;

    final ok = await _confirm(
      title: 'Move to Trash?',
      message:
          'Move ${_countText(files.length)} to Trash? '
          'You can restore them from Trash.',
      action: 'Move',
    );
    if (!ok || !mounted) return;

    var failed = 0;
    for (final file in files) {
      try {
        await ReceiptStorage.moveToTrash(file);
      } catch (_) {
        failed++;
      }
    }

    _selectedPaths.clear();
    await _reloadSaved();
    await _loadTrash();

    _showSnack(
      failed == 0
          ? '${_countText(files.length)} moved to Trash.'
          : '${files.length - failed} moved. $failed could not be moved.',
    );
  }

  Future<void> _restoreSelected() async {
    final files = _selectedFiles;
    if (files.isEmpty) return;

    var failed = 0;
    for (final file in files) {
      try {
        await ReceiptStorage.restore(file);
      } catch (_) {
        failed++;
      }
    }

    _selectedPaths.clear();
    await _reloadSaved();
    await _loadTrash();

    _showSnack(
      failed == 0
          ? '${_countText(files.length)} restored.'
          : '${files.length - failed} restored. $failed could not be restored.',
    );
  }

  // ---------- UI ----------

  Widget _buildReceiptGrid(List<File> files) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
      // 3 per row. Change to 2 for even bigger images.
      // childAspectRatio 1 = width and height are the same (square).
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
        childAspectRatio: 1,
      ),
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        final selected = _selectedPaths.contains(file.path);
        final cellKey = _cellKeys.putIfAbsent(file.path, () => GlobalKey());

        return GestureDetector(
          onTap: () {
            if (_isSelecting) {
              _toggleSelection(file);
            } else {
              _openReceipt(file, files);
            }
          },
          // Hold to start selecting, then slide down or up.
          onLongPressStart: (d) => _startDrag(file, d.globalPosition),
          onLongPressMoveUpdate: (d) => _dragMove(d.globalPosition),
          onLongPressEnd: (_) => _endDrag(),
          onLongPressCancel: _endDrag,
          child: Container(
            key: cellKey,
            child: AnimatedScale(
              scale: selected ? 0.92 : 1.0,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  color: Colors.white,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Full width from the top, so Num / FR / SR are visible.
                      Image.file(
                        file,
                        fit: BoxFit.fitWidth,
                        alignment: Alignment.topCenter,
                        cacheWidth: 600,
                        errorBuilder:
                            (_, _, _) => const Icon(Icons.broken_image),
                      ),

                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          color: Colors.black54,
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            _formatReceiptTime(file),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),

                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            opacity: selected ? 1 : 0,
                            duration: const Duration(milliseconds: 150),
                            child: Container(
                              color: Colors.blue.withValues(alpha: 0.3),
                            ),
                          ),
                        ),
                      ),

                      Positioned(
                        top: 4,
                        right: 4,
                        child: AnimatedOpacity(
                          opacity: _isSelecting ? 1 : 0,
                          duration: const Duration(milliseconds: 150),
                          child: Icon(
                            selected
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: selected ? Colors.blue : Colors.white,
                            size: 22,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDateSection(String title, List<File> files) {
    final allSelected = _isSectionAllSelected(files);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Fixed height, so the layout does not jump when selecting starts.
        SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (_isSelecting)
                  TextButton.icon(
                    onPressed: () => _toggleSectionSelection(files),
                    icon: Icon(
                      allSelected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 20,
                    ),
                    label: Text(allSelected ? 'Deselect all' : 'Select all'),
                  ),
              ],
            ),
          ),
        ),
        _buildReceiptGrid(files),
      ],
    );
  }

  Widget _actionButton({
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Expanded(
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 6),
        ),
      ),
    );
  }

  Widget _buildSelectionBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children:
              _inTrash
                  ? [
                    _actionButton(
                      onPressed: _restoreSelected,
                      icon: Icons.restore,
                      label: 'Restore',
                      color: Colors.blue,
                    ),
                    const SizedBox(width: 8),
                  ]
                  : [
                    const SizedBox(width: 8),
                    _actionButton(
                      onPressed: _showCalculationDialog,
                      icon: Icons.calculate,
                      label: 'Calculate',
                      color: Colors.blue,
                    ),
                    const SizedBox(width: 8),
                    _actionButton(
                      onPressed: _moveSelectedToTrash,
                      icon: Icons.delete,
                      label: 'Delete',
                      color: Colors.red,
                    ),
                    _actionButton(
                      onPressed: () => _shareFiles(_selectedFiles),
                      icon: Icons.share,
                      label: 'Share',
                      color: const Color(0xFF25D366),
                    ),
                  ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groupReceipts();

    final orderedTitles = <String>[];
    if (groups.containsKey('Today')) orderedTitles.add('Today');
    if (groups.containsKey('Yesterday')) orderedTitles.add('Yesterday');

    final olderTitles =
        groups.keys
            .where((title) => title != 'Today' && title != 'Yesterday')
            .toList()
          ..sort((a, b) {
            final dateA = groups[a]!.first.lastModifiedSync();
            final dateB = groups[b]!.first.lastModifiedSync();
            return dateB.compareTo(dateA);
          });

    orderedTitles.addAll(olderTitles);

    Widget title;
    if (_isSelecting) {
      title = Text('${_selectedPaths.length} selected');
    } else if (_inTrash) {
      title = Text('Trash (${_trash.length})');
    } else {
      title = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Tokens (${_receipts.length})'),
          if (_trash.isNotEmpty)
            IconButton(
              tooltip: 'Trash',
              icon: Icon(Icons.delete, color: Colors.red.shade700),
              onPressed:
                  () => setState(() {
                    _inTrash = true;
                    _selectedPaths.clear();
                  }),
            ),
        ],
      );
    }

    Widget? leading;
    if (_isSelecting) {
      leading = IconButton(
        onPressed: () => setState(() => _selectedPaths.clear()),
        icon: const Icon(Icons.close),
      );
    } else if (_inTrash) {
      leading = IconButton(
        tooltip: 'Back to tokens',
        onPressed: () => setState(() => _inTrash = false),
        icon: const Icon(Icons.arrow_back),
      );
    }

    return PopScope(
      canPop: !_inTrash,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _inTrash) {
          setState(() {
            _inTrash = false;
            _selectedPaths.clear();
          });
        }
      },
      child: Scaffold(
        backgroundColor: _inTrash ? const Color(0xFFFDECEC) : null,
        appBar: AppBar(
          backgroundColor: _inTrash ? Colors.red.shade700 : null,
          foregroundColor: _inTrash ? Colors.white : null,
          leading: leading,
          title: title,
          actions: [
            if (_isSelecting)
              IconButton(
                tooltip:
                    _isEverythingSelected
                        ? 'Deselect all'
                        : 'Select everything',
                icon: Icon(
                  _isEverythingSelected ? Icons.deselect : Icons.select_all,
                ),
                onPressed: _toggleSelectEverything,
              ),
          ],
        ),
        body:
            _current.isEmpty
                ? Center(
                  child: Text(
                    _inTrash ? 'Trash is empty' : 'No images saved yet',
                    style: const TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                )
                : ListView(
                  key: _listKey,
                  controller: _scroll,
                  children: [
                    for (final t in orderedTitles)
                      _buildDateSection(t, groups[t]!),
                    const SizedBox(height: 8),
                  ],
                ),
        // The bar slides in and out smoothly.
        bottomNavigationBar: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: _isSelecting ? _buildSelectionBar() : const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class ReceiptViewerScreen extends StatefulWidget {
  final List<File> files;
  final int initialIndex;
  final Future<void> Function(File file)? onShare;
  final bool isTrash;

  const ReceiptViewerScreen({
    super.key,
    required this.files,
    required this.initialIndex,
    this.onShare,
    this.isTrash = false,
  });

  @override
  State<ReceiptViewerScreen> createState() => _ReceiptViewerScreenState();
}

class _ReceiptViewerScreenState extends State<ReceiptViewerScreen> {
  static const double _panelHeight = 214;

  late final PageController _pageController;
  late final List<File> _files;
  late final List<PhotoViewScaleStateController> _scaleControllers;

  late int _currentIndex;

  // Slide-up-to-share state.
  Offset? _downPos;
  bool _multiTouch = false;
  bool _verticalLocked = false;
  int _pointers = 0;
  double _dragY = 0;
  bool _dragging = false;

  bool _panelOpen = false;
  final Set<String> _shareSel = {};

  @override
  void initState() {
    super.initState();

    _files = List<File>.from(widget.files);
    _currentIndex = widget.initialIndex.clamp(0, _files.length - 1);
    _pageController = PageController(initialPage: _currentIndex);

    _scaleControllers = List.generate(
      _files.length,
      (_) => PhotoViewScaleStateController(),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();

    for (final controller in _scaleControllers) {
      controller.dispose();
    }

    super.dispose();
  }

  bool get _isZoomed =>
      _files.isNotEmpty &&
      _scaleControllers[_currentIndex].scaleState !=
          PhotoViewScaleState.initial;

  void _onPointerDown(PointerDownEvent e) {
    _pointers++;
    if (_pointers == 1) {
      _downPos = e.position;
      _multiTouch = false;
      _verticalLocked = false;
    } else {
      _multiTouch = true; // pinch zoom
    }
  }

  Future<void> _handleShare() async {
    if (_files.isEmpty) return;

    if (_panelOpen) {
      await _shareSelected();
      return;
    }

    // Without sliding up, share only the current image.
    final currentFile = _files[_currentIndex];

    try {
      await ShareHelper.shareFiles([currentFile]);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Unable to share image: $e')));
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (widget.onShare == null ||
        _pointers != 1 ||
        _multiTouch ||
        _downPos == null ||
        _isZoomed) {
      return;
    }

    final d = e.position - _downPos!;

    if (!_verticalLocked) {
      final isCorrectDirection = _panelOpen ? d.dy > 14 : d.dy < -14;

      if (isCorrectDirection && d.dy.abs() > d.dx.abs() * 2) {
        _verticalLocked = true;
      } else {
        return;
      }
    }

    setState(() {
      _dragging = true;

      // Panel closed: image follows upward.
      // Panel open: image follows downward.
      _dragY =
          _panelOpen
              ? (d.dy * 0.6).clamp(0.0, 160.0)
              : (d.dy * 0.6).clamp(-160.0, 0.0);
    });
  }

  void _onPointerUp(PointerUpEvent e) {
    _pointers = (_pointers - 1).clamp(0, 10);
    if (_pointers != 0) return;

    final wasLocked = _verticalLocked;
    final wasPanelOpen = _panelOpen;

    final d = _downPos == null ? Offset.zero : e.position - _downPos!;

    _verticalLocked = false;
    _downPos = null;

    if (!wasLocked || _multiTouch) {
      if (_dragY != 0 || _dragging) {
        setState(() {
          _dragging = false;
          _dragY = 0;
        });
      }
      return;
    }

    setState(() {
      _dragging = false;
      _dragY = 0;
    });

    if (wasPanelOpen && d.dy > 100) {
      _closePanel();
    } else if (!wasPanelOpen && d.dy < -100) {
      _openPanel();
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _pointers = (_pointers - 1).clamp(0, 10);
    _downPos = null;
    _verticalLocked = false;
    if (_dragY != 0 || _dragging) {
      setState(() {
        _dragging = false;
        _dragY = 0;
      });
    }
  }

  void _openPanel() {
    if (_files.isEmpty) return;

    setState(() {
      _shareSel
        ..clear()
        ..add(_files[_currentIndex].path);

      _panelOpen = true;
    });
  }

  void _closePanel() => setState(() => _panelOpen = false);

  void _toggleShareSel(File file) {
    setState(() {
      if (!_shareSel.remove(file.path)) _shareSel.add(file.path);
    });
  }

  int get _shareCount => _files.where((f) => _shareSel.contains(f.path)).length;

  Future<void> _shareSelected() async {
    final files = _files.where((f) => _shareSel.contains(f.path)).toList();
    if (files.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);

    try {
      await ShareHelper.shareFiles(
        files,
        onNotice: (m) {
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(m)));
        },
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Unable to share receipts: $e')),
      );
    }

    if (mounted) setState(() => _panelOpen = false);
  }

  void _toggleCurrentImageSelection() {
    if (_files.isEmpty) return;

    _toggleShareSel(_files[_currentIndex]);
  }

  void _toggleZoom() {
    final controller = _scaleControllers[_currentIndex];

    setState(() {
      if (controller.scaleState.isScaleStateZooming) {
        controller.scaleState = PhotoViewScaleState.initial;
      } else {
        controller.scaleState = PhotoViewScaleState.zoomedIn;
      }
    });
  }

  /// Removes the current image from this viewer after it was
  /// moved, restored or deleted.
  void _removeCurrentFromList(String message) {
    final index = _currentIndex;
    final removedController = _scaleControllers.removeAt(index);
    _files.removeAt(index);

    // Dispose after the gallery has rebuilt without it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      removedController.dispose();
    });

    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));

    if (_files.isEmpty) {
      Navigator.pop(context, true);
      return;
    }

    final newIndex = index >= _files.length ? _files.length - 1 : index;

    setState(() => _currentIndex = newIndex);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(newIndex);
      }
    });
  }

  Future<void> _moveToTrash() async {
    try {
      await ReceiptStorage.moveToTrash(_files[_currentIndex]);
      if (!mounted) return;
      _removeCurrentFromList('Moved to Trash.');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not delete.')));
    }
  }

  Future<void> _restore() async {
    try {
      await ReceiptStorage.restore(_files[_currentIndex]);
      if (!mounted) return;
      _removeCurrentFromList('Restored.');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not restore.')));
    }
  }

  Future<void> _deleteForever() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Delete permanently?'),
            content: const Text(
              'This receipt will be deleted forever. This cannot be undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Delete'),
              ),
            ],
          ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await ReceiptStorage.deleteForever(_files[_currentIndex]);
      if (!mounted) return;
      _removeCurrentFromList('Deleted permanently.');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not delete.')));
    }
  }

  Widget _bottomButton({
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Expanded(
      child: SizedBox(
        height: 52,
        child: ElevatedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildSharePanel() {
    return Material(
      elevation: 12,
      color: Theme.of(context).colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: () {
                setState(() {
                  if (_shareCount == _files.length) {
                    _shareSel.clear();
                  } else {
                    _shareSel.addAll(_files.map((f) => f.path));
                  }
                });
              },
              child: Text(
                _shareCount == _files.length ? 'Clear' : 'Select all',
                style: const TextStyle(fontSize: 14),
              ),
            ),

            // Current image selection tick
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleCurrentImageSelection,
              child: Padding(
                padding: const EdgeInsets.only(right: 4, top: 8, bottom: 8),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        _shareSel.contains(_files[_currentIndex].path)
                            ? Colors.blue
                            : Colors.black45,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Icon(
                    _shareSel.contains(_files[_currentIndex].path)
                        ? Icons.check
                        : Icons.add,
                    color: Colors.white,
                    size: 19,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_panelOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _panelOpen) _closePanel();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            '${widget.isTrash ? 'Trash' : 'Token'} '
            '${_currentIndex + 1}/${_files.length}',
          ),
          actions: [
            IconButton(
              tooltip: 'Toggle zoom',
              icon: const Icon(Icons.zoom_in),
              onPressed: _toggleZoom,
            ),
          ],
        ),
        body: Stack(
          children: [
            // The image moves up when the share panel opens.
            AnimatedPadding(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.only(bottom: _panelOpen ? _panelHeight : 0),
              child: Listener(
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                onPointerCancel: _onPointerCancel,
                child: AnimatedContainer(
                  duration:
                      _dragging
                          ? Duration.zero
                          : const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                  transform: Matrix4.translationValues(0, _dragY, 0),
                  child: Stack(
                    children: [
                      PhotoViewGallery.builder(
                        itemCount: _files.length,
                        pageController: _pageController,
                        gaplessPlayback: true,
                        backgroundDecoration: BoxDecoration(
                          color: Theme.of(context).scaffoldBackgroundColor,
                        ),
                        scrollPhysics: const PageScrollPhysics(),
                        onPageChanged: (index) {
                          setState(() {
                            _currentIndex = index;
                          });
                        },
                        builder: (context, index) {
                          return PhotoViewGalleryPageOptions(
                            imageProvider: FileImage(_files[index]),
                            initialScale: PhotoViewComputedScale.contained,
                            minScale: PhotoViewComputedScale.contained,
                            maxScale: PhotoViewComputedScale.covered * 5,
                            scaleStateController: _scaleControllers[index],
                            errorBuilder: (context, error, stackTrace) {
                              return const Center(
                                child: Icon(Icons.broken_image, size: 60),
                              );
                            },
                          );
                        },
                      ),

                      // Tap the image to select or deselect it.
                      if (_panelOpen)
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: _toggleCurrentImageSelection,
                          ),
                        ),

                      // Selection tick at bottom-right.
                      // Small selection tick at bottom-right.
                    ],
                  ),
                ),
              ),
            ),

            // Share panel slides up from the bottom.
            if (widget.onShare != null)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                left: 0,
                right: 0,
                bottom: _panelOpen ? 0 : -(_panelHeight + 30),
                height: _panelHeight,
                child: _buildSharePanel(),
              ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              children:
                  widget.isTrash
                      ? [
                        _bottomButton(
                          onPressed: _restore,
                          icon: Icons.restore,
                          label: 'Restore',
                          color: Colors.blue,
                        ),
                        const SizedBox(width: 10),
                        _bottomButton(
                          onPressed: _deleteForever,
                          icon: Icons.delete_forever,
                          label: 'Delete forever',
                          color: Colors.red,
                        ),
                      ]
                      : [
                        _bottomButton(
                          onPressed: _moveToTrash,
                          icon: Icons.delete,
                          label: 'Delete',
                          color: Colors.red,
                        ),
                        if (widget.onShare != null) ...[
                          const SizedBox(width: 10),
                          _bottomButton(
                            onPressed: _handleShare,
                            icon: Icons.share,
                            label: 'Share (${_panelOpen ? _shareCount : 1})',
                            color: const Color(0xFF25D366),
                          ),
                        ],
                      ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Stores the total amount for each saved receipt (fileName -> total).
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
    final captions = await ReceiptCaption.forFiles(files);

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
