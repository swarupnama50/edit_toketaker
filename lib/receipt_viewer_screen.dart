import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:token_taker/receipttotal_calculate_sharehelper.dart';
import 'package:token_taker/saved_tokens.dart';

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

  late PageController _pageController;
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
        _downPos == null) {
      return;
    }

    // Don't allow vertical panel gestures while zoomed.
    if (_isZoomed) return;

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

  void _setPanelOpen(bool open) {
    if (_panelOpen == open) return;

    final oldController = _pageController;

    final newController = PageController(
      initialPage: _currentIndex,
      viewportFraction: open ? 0.86 : 1.0,
    );

    setState(() {
      _pageController = newController;
      _panelOpen = open;

      if (open && _files.isNotEmpty) {
        _shareSel
          ..clear()
          ..add(_files[_currentIndex].path);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldController.dispose();
    });
  }

  void _openPanel() {
    if (_files.isEmpty) return;
    _setPanelOpen(true);
  }

  void _closePanel() {
    _setPanelOpen(false);
  }

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

    if (mounted) _closePanel();
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Move to Trash?'),
            content: const Text(
              'Are you sure you want to move this receipt to Trash?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Move to Trash'),
              ),
            ],
          ),
    );

    if (confirmed != true || !mounted) return;

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
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: PopScope(
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
              AnimatedPadding(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.only(bottom: _panelOpen ? _panelHeight : 0),
                child: Stack(
                  children: [
                    PhotoViewGallery.builder(
                      key: ValueKey(_panelOpen),
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
                    if (_panelOpen)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: _toggleCurrentImageSelection,
                        ),
                      ),
                  ],
                ),
              ),
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
      ),
    );
  }
}
