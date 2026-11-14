import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class PaymentDialog extends StatefulWidget {
  const PaymentDialog({super.key});

  /// Call this from the menu: PaymentDialog.show(context);
  /// Now opens a full screen instead of a dialog.
  static Future<void> show(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const PaymentDialog()),
    );
  }

  @override
  State<PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<PaymentDialog> {
  static const String _upiId = '6033037225@okbizaxis';
  static const String _phone = '6033037225';
  static const String _payeeName = 'Swarup Nama';
  static const String _qrAsset = 'assets/my_qr.png';

  static const Color _primary = Color(0xFF2878D0);
  static const Color _border = Color(0xFFD5D9E0);

  String? _status;
  bool _isError = false;
  bool _saving = false;

  void _setStatus(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = text;
      _isError = error;
    });
  }

  Future<void> _downloadQr() async {
    if (_saving) return;
    setState(() => _saving = true);

    try {
      var hasAccess = await Gal.hasAccess();
      if (!hasAccess) hasAccess = await Gal.requestAccess();

      if (!hasAccess) {
        _setStatus('Gallery permission denied', error: true);
        return;
      }

      final data = await rootBundle.load(_qrAsset);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/payment_qr.png');
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);

      await Gal.putImage(file.path);
      _setStatus('QR code saved to your gallery');
    } catch (e) {
      _setStatus('Could not save QR code', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copy(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    _setStatus('$label copied');
  }

  Future<void> _payWithUpiApp() async {
    final upiUrl =
        'upi://pay?pa=$_upiId'
        '&pn=${Uri.encodeComponent(_payeeName)}'
        '&cu=INR';

    try {
      if (Platform.isAndroid) {
        // Shows the Android "choose an app" sheet with ALL installed UPI apps
        // (Google Pay, PhonePe, Paytm, BHIM, ...), instead of opening one directly.
        final intent = AndroidIntent(action: 'action_view', data: upiUrl);
        await intent.launchChooser('Pay with');
      } else {
        // iOS: the system handles upi:// links.
        final ok = await launchUrl(
          Uri.parse(upiUrl),
          mode: LaunchMode.externalApplication,
        );
        if (!ok) _setStatus('No UPI app found on this phone', error: true);
      }
    } catch (_) {
      _setStatus('No UPI app found on this phone', error: true);
    }
  }

  Widget _infoTile({
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onCopy,
  }) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(top: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: _border),
      ),
      child: ListTile(
        leading: Icon(icon, color: _primary),
        title: Text(title),
        subtitle: Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
        trailing: IconButton(
          tooltip: 'Copy',
          icon: const Icon(Icons.copy, size: 22),
          onPressed: onCopy,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Make the QR as large as the screen allows (max 380).
    final screenWidth = MediaQuery.of(context).size.width;
    final qrSize = (screenWidth - 32 - 24).clamp(200.0, 380.0);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: _primary),
        title: const Row(
          children: [
            Icon(Icons.payment_outlined, color: _primary),
            SizedBox(width: 8),
            Text('Payment'),
          ],
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              const Text(
                'Scan to pay',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: _border),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Image.asset(
                  _qrAsset,
                  width: qrSize,
                  height: qrSize,
                  fit: BoxFit.contain,
                  errorBuilder:
                      (_, __, ___) => SizedBox(
                        width: qrSize,
                        height: qrSize,
                        child: const Center(child: Text('QR image not found')),
                      ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : _downloadQr,
                  icon:
                      _saving
                          ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : const Icon(Icons.download),
                  label: const Text('Download QR'),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primary,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _payWithUpiApp,
                  icon: const Icon(Icons.send),
                  label: const Text('Pay with UPI app'),
                ),
              ),
              const SizedBox(height: 6),
              _infoTile(
                icon: Icons.account_balance_outlined,
                title: 'UPI ID',
                value: _upiId,
                onCopy: () => _copy(_upiId, 'UPI ID'),
              ),
              _infoTile(
                icon: Icons.phone_outlined,
                title: 'Phone number',
                value: _phone,
                onCopy: () => _copy(_phone, 'Number'),
              ),
              if (_status != null) ...[
                const SizedBox(height: 14),
                Text(
                  _status!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: _isError ? Colors.red : Colors.green.shade700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}