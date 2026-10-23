import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'common.dart';

/// Renders [code] as a PNG QR with a white quiet zone, so it still scans
/// after being sent as a screenshot and opened from the gallery.
Future<File> renderQrPng(String code, {double size = 900}) async {
  const margin = 72.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, size, size), Paint()..color = Colors.white);
  canvas.translate(margin, margin);
  QrPainter(data: code, version: QrVersions.auto, gapless: true)
      .paint(canvas, Size.square(size - 2 * margin));
  final image = await recorder.endRecording().toImage(size.toInt(), size.toInt());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File(p.join((await getTemporaryDirectory()).path, 'splitmate-code.png'));
  await file.writeAsBytes(png!.buffer.asUint8List(), flush: true);
  return file;
}

/// Share sheet with the QR image and the same code as text.
Future<void> shareCode(String code, {required String message}) async {
  final png = await renderQrPng(code);
  await SharePlus.instance.share(ShareParams(
    files: [XFile(png.path, mimeType: 'image/png')],
    text: '$message\n\n$code',
  ));
}

Future<void> copyCode(BuildContext context, String code) async {
  await Clipboard.setData(ClipboardData(text: code));
  if (context.mounted) showSnack(context, 'Code copied');
}

/// Lets the user pick a screenshot/photo of a QR code and decodes it.
/// Returns null (after telling the user) if no QR code is found.
Future<String?> pickQrFromGallery(BuildContext context, MobileScannerController controller) async {
  final x = await ImagePicker().pickImage(source: ImageSource.gallery);
  if (x == null) return null;
  BarcodeCapture? capture;
  try {
    capture = await controller.analyzeImage(x.path, formats: const [BarcodeFormat.qrCode]);
  } catch (_) {
    capture = null;
  }
  final value = capture?.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
  if (value == null && context.mounted) {
    showSnack(context, 'No QR code found in that image. Try a sharper, uncropped screenshot.');
  }
  return value;
}

/// Asks the user to paste a code received as text.
Future<String?> pasteCodeDialog(BuildContext context) async {
  final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
  final c = TextEditingController(text: clip != null && clip.startsWith('splitmate:') ? clip : '');
  if (!context.mounted) return null;
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Paste a code'),
      content: TextField(
        controller: c,
        autofocus: true,
        maxLines: 4,
        decoration: const InputDecoration(hintText: 'splitmate:…'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Connect')),
      ],
    ),
  );
}
