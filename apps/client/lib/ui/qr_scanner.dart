import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/app/pairing_inputs.dart';
import '../core/app/qr_decode.dart';

/// Live camera scan of a QR code carrying the pairing code (spec #28 Pairing step 3,
/// #108 Q12). The camera, and so the CAMERA permission prompt, is opened only
/// here, after the user tapped Scan. Frames are decoded on the device with
/// the pinned zxing2 decoder (no Google Play services, no network). Returns
/// the normalized invitation, or null when the user leaves or the camera is
/// unavailable (typed entry stays available).
Future<String?> scanInvitation(BuildContext context) => Navigator.of(context)
    .push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const QrScannerPage(),
      ),
    );

class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key, this.cameras = availableCameras});

  /// Test seam; the camera plugin's list in the app.
  final Future<List<CameraDescription>> Function() cameras;

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  CameraController? _camera;
  String? _problem;
  String? _notice;
  bool _decoding = false;
  bool _done = false;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final cameras = await widget.cameras();
      if (cameras.isEmpty) {
        throw CameraException('NoCamera', null);
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final camera = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      _camera = camera;
      await camera.initialize();
      if (!mounted) return;
      await camera.startImageStream(_frame);
      setState(() {});
    } on CameraException catch (error) {
      _fail(switch (error.code) {
        'CameraAccessDenied' ||
        'CameraAccessDeniedWithoutPrompt' ||
        'CameraAccessRestricted' ||
        'cameraPermission' =>
          'Camera permission was declined. Type the pairing code instead.',
        'NoCamera' =>
          'This device has no camera. Type the pairing code instead.',
        _ => 'The camera could not start. Type the pairing code instead.',
      });
    } catch (_) {
      _fail('The camera could not start. Type the pairing code instead.');
    }
  }

  void _fail(String text) {
    if (mounted) setState(() => _problem = text);
  }

  void _frame(CameraImage image) {
    final now = DateTime.now();
    if (_decoding ||
        _done ||
        now.difference(_lastFrame) < const Duration(milliseconds: 250)) {
      return;
    }
    _lastFrame = now;
    _decoding = true;
    final plane = image.planes.first;
    final frame = LuminanceFrame(
      Uint8List.fromList(plane.bytes),
      image.width,
      image.height,
      plane.bytesPerRow,
    );
    unawaited(
      compute(decodeQrFrame, frame)
          .then((text) {
            if (text == null || _done || !mounted) return;
            final invitation = invitationFromQr(text);
            if (invitation == null) {
              setState(
                () => _notice = 'This QR code is not an AnJ Cloud pairing code. Scan the code from your admin.',
              );
              return;
            }
            _done = true;
            Navigator.of(context).pop(invitation);
          })
          .whenComplete(() => _decoding = false),
    );
  }

  @override
  void dispose() {
    final camera = _camera;
    _camera = null;
    if (camera != null) {
      unawaited(() async {
        try {
          if (camera.value.isStreamingImages) await camera.stopImageStream();
        } catch (_) {}
        await camera.dispose();
      }());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    final ready = camera != null && camera.value.isInitialized;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan pairing code')),
      // Clear of the system navigation bar, so Back to pairing is tappable.
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _problem ?? 'Point the camera at the QR code of your pairing code. It is read on this device only.',
                key: const ValueKey('scan-status'),
              ),
              const SizedBox(height: 12),
              if (_problem == null)
                Expanded(
                  child: ready
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Center(child: CameraPreview(camera)),
                        )
                      : const Center(child: CircularProgressIndicator()),
                ),
              if (_notice != null) ...[
                const SizedBox(height: 12),
                Text(_notice!, key: const ValueKey('scan-notice')),
              ],
              if (_problem != null) ...[
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Back to pairing'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
