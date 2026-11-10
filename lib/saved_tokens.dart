import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

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
    if (mounted) setState(() => _trash = files);
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
      MaterialPageRoute(
        builder:
            (context) => ReceiptViewerScreen(
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

  Future<void> _deleteSelectedForever() async {
    final files = _selectedFiles;
    if (files.isEmpty) return;

    final ok = await _confirm(
      title: 'Delete permanently?',
      message:
          'Permanently delete ${_countText(files.length)}? '
          'This cannot be undone.',
      action: 'Delete',
    );
    if (!ok || !mounted) return;

    var failed = 0;
    for (final file in files) {
      try {
        await ReceiptStorage.deleteForever(file);
      } catch (_) {
        failed++;
      }
    }

    _selectedPaths.clear();
    await _loadTrash();
    await _loadTotals();

    _showSnack(
      failed == 0
          ? '${_countText(files.length)} deleted permanently.'
          : '${files.length - failed} deleted. $failed could not be deleted.',
    );
  }

  // ---------- UI ----------

  Widget _buildReceiptGrid(List<File> files) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.72,
      ),
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        final selected = _selectedPaths.contains(file.path);

        return InkWell(
          onLongPress: () => _toggleSelection(file),
          onTap: () {
            if (_isSelecting) {
              _toggleSelection(file);
            } else {
              _openReceipt(file, files);
            }
          },
          child: Card(
            color: Colors.white,
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Column(
                  children: [
                    Expanded(
                      child: Image.file(
                        file,
                        width: double.infinity,
                        fit: BoxFit.contain,
                        errorBuilder:
                            (_, _, _) => const Icon(Icons.broken_image),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(
                        _formatReceiptTime(file),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
                if (selected)
                  Container(color: Colors.blue.withValues(alpha: 0.22)),
                Positioned(
                  top: 6,
                  right: 6,
                  child: AnimatedOpacity(
                    opacity: _isSelecting ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child:
                        _isSelecting
                            ? Icon(
                              selected
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              color: selected ? Colors.blue : Colors.grey,
                              size: 28,
                            )
                            : const SizedBox.shrink(),
                  ),
                ),
              ],
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
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
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
                    _actionButton(
                      onPressed: _deleteSelectedForever,
                      icon: Icons.delete_forever,
                      label: 'Delete forever',
                      color: Colors.red,
                    ),
                  ]
                  : [
                    _actionButton(
                      onPressed: () => _shareFiles(_selectedFiles),
                      icon: Icons.share,
                      label: 'Share',
                      color: const Color(0xFF25D366),
                    ),
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
                  ],
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    return NavigationBar(
      selectedIndex: _inTrash ? 1 : 0,
      onDestinationSelected: (index) {
        setState(() {
          _inTrash = index == 1;
          _selectedPaths.clear();
        });
      },
      destinations: [
        const NavigationDestination(
          icon: Icon(Icons.photo_library_outlined),
          selectedIcon: Icon(Icons.photo_library),
          label: 'Saved',
        ),
        NavigationDestination(
          icon: Badge(
            isLabelVisible: _trash.isNotEmpty,
            label: Text('${_trash.length}'),
            child: const Icon(Icons.delete_outline),
          ),
          selectedIcon: Badge(
            isLabelVisible: _trash.isNotEmpty,
            label: Text('${_trash.length}'),
            child: const Icon(Icons.delete),
          ),
          label: 'Trash',
        ),
      ],
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

    return Scaffold(
      appBar: AppBar(
        leading:
            _isSelecting
                ? IconButton(
                  onPressed: () => setState(() => _selectedPaths.clear()),
                  icon: const Icon(Icons.close),
                )
                : null,
        title: Text(
          _isSelecting
              ? '${_selectedPaths.length} selected'
              : _inTrash
              ? 'Trash (${_trash.length})'
              : 'Tokens (${_receipts.length})',
        ),
        actions: [
          if (_isSelecting)
            IconButton(
              tooltip:
                  _isEverythingSelected ? 'Deselect all' : 'Select everything',
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
                children: [
                  for (final title in orderedTitles)
                    _buildDateSection(title, groups[title]!),
                  const SizedBox(height: 8),
                ],
              ),
      bottomNavigationBar: _isSelecting ? _buildSelectionBar() : _buildTabBar(),
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
  late final PageController _pageController;
  late final List<File> _files;
  late final List<PhotoViewScaleStateController> _scaleControllers;

  late int _currentIndex;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
      body: PhotoViewGallery.builder(
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
              return const Center(child: Icon(Icons.broken_image, size: 60));
            },
          );
        },
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
                      if (widget.onShare != null) ...[
                        _bottomButton(
                          onPressed:
                              () => widget.onShare!(_files[_currentIndex]),
                          icon: Icons.share,
                          label: 'Share to WhatsApp',
                          color: const Color(0xFF25D366),
                        ),
                        const SizedBox(width: 10),
                      ],
                      _bottomButton(
                        onPressed: _moveToTrash,
                        icon: Icons.delete,
                        label: 'Delete',
                        color: Colors.red,
                      ),
                    ],
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

  static Future<void> _normalShare(List<File> files) {
    return SharePlus.instance.share(
      ShareParams(
        files: files.map((f) => XFile(f.path, mimeType: 'image/jpeg')).toList(),
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

    if (mode == 0 || mode == 1) {
      if (mode == 0 && number.isEmpty) {
        onNotice?.call('No WhatsApp number saved. Add one in Settings.');
        await _normalShare(files);
        return;
      }

      try {
        final ok = await _channel.invokeMethod<bool>('share', {
          'paths': files.map((f) => f.path).toList(),
          'phone': mode == 0 ? number : '',
        });

        if (ok == true) return;

        onNotice?.call('WhatsApp is not installed. Using normal share.');
      } catch (e) {
        debugPrint('WhatsApp share failed: $e');
        onNotice?.call('Could not open WhatsApp. Using normal share.');
      }
    }

    await _normalShare(files);
  }
}
