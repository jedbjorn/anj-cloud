import 'package:flutter/material.dart';

import '../core/app/controller.dart';
import '../core/app/pairing_inputs.dart';
import 'layout.dart';
import 'qr_scanner.dart';

/// Pairing (spec #35, decision #151): the household server, prefilled, and
/// the pairing code, typed or scanned live from a QR code that carries the
/// same code (#108 Q12, where [PairingOptions.liveScan]). The code pins the
/// household CA, which the app fetches and checks itself; the server
/// approves at once. A legacy invitation still shows the device fingerprint
/// for the admin (spec #35 rule 6). A dialog on wide windows, a page on
/// phones in either orientation ([compactLayout], the shared responsive
/// rule).
Future<void> showPairing(BuildContext context, ClientController controller) {
  if (compactLayout(context)) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PairingForm(controller: controller, page: true),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => PairingForm(controller: controller, page: false),
  );
}

class PairingForm extends StatefulWidget {
  const PairingForm({super.key, required this.controller, required this.page});
  final ClientController controller;
  final bool page;

  @override
  State<PairingForm> createState() => _PairingFormState();
}

class _PairingFormState extends State<PairingForm> {
  ClientController get controller => widget.controller;
  PairingOptions get options => controller.pairingOptions;
  late final _server = TextEditingController(
    text: controller.server ?? ClientController.householdOrigin,
  );
  final _code = TextEditingController();
  late var _status = controller.pairingState;
  bool _waiting = false;

  @override
  void initState() {
    super.initState();
    controller.addListener(_follow);
  }

  /// While a pinned code waits for the server's approval the controller
  /// reports 'pending' between polls.
  void _follow() {
    if (_waiting && mounted) setState(() => _status = controller.pairingState);
  }

  @override
  void dispose() {
    controller.removeListener(_follow);
    _server.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final invitation = await scanInvitation(context);
    if (invitation != null && mounted) {
      setState(() => _code.text = invitation);
    }
  }

  Future<void> _submit() async {
    setState(() => _waiting = true);
    try {
      await controller.pair(_server.text.trim(), _code.text.trim());
    } catch (_) {
      /* Controller supplies a redacted explanation. */
    }
    if (!mounted) return;
    setState(() {
      _waiting = false;
      _status = controller.pairingState;
    });
    // Paired at a first pairing: the folder screen comes next.
    if (controller.firstSyncPending && _status == 'paired') {
      Navigator.of(context).pop();
    }
  }

  List<Widget> _fields(BuildContext context) => [
    if (KeyUnavailableNotice.shown(controller))
      KeyUnavailableNotice(controller: controller),
    const Text(
      'Enter your household server and the pairing code from your admin. The app checks that the code belongs to that server, then pairs at once. Pair once: certificates do not need renewing, and a replacement from your operator is picked up automatically.',
    ),
    TextField(
      key: const ValueKey('pair-server'),
      controller: _server,
      enabled: !_waiting,
      keyboardType: TextInputType.url,
      autocorrect: false,
      decoration: const InputDecoration(labelText: 'Server'),
    ),
    TextField(
      key: const ValueKey('pair-code'),
      controller: _code,
      enabled: !_waiting,
      autocorrect: false,
      enableSuggestions: false,
      decoration: const InputDecoration(
        labelText: 'Pairing code',
        helperText: 'Dashes and spaces are fine.',
      ),
    ),
    if (options.liveScan)
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          key: const ValueKey('pair-scan'),
          onPressed: _waiting ? null : _scan,
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Scan QR code'),
        ),
      ),
    const SizedBox(height: 12),
    Text('Status: $_status', key: const ValueKey('pair-status')),
    if (controller.awaitingFingerprintApproval &&
        controller.fingerprint != null) ...[
      const Text('Device fingerprint (SHA-256)'),
      SelectableText(
        controller.fingerprint!,
        key: const ValueKey('pair-device-fingerprint'),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ),
    ],
    const SizedBox(height: 8),
    Text(
      _waiting
          ? controller.message
          : controller.pairingMessage ?? controller.message,
      key: const ValueKey('pair-message'),
    ),
    if (_waiting) const LinearProgressIndicator(),
  ];

  List<Widget> _actions(BuildContext context) => [
    if (!widget.page)
      TextButton(
        onPressed: _waiting ? null : () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    FilledButton(
      key: const ValueKey('pair-request'),
      onPressed: _waiting ? null : _submit,
      child: const Text('Pair'),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    if (!widget.page) {
      return AlertDialog(
        title: const Text('Pair this device'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _fields(context),
            ),
          ),
        ),
        actions: _actions(context),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Pair this device')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ..._fields(context),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: _actions(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown while this device's key cannot be read and the platform can wipe
/// its secret store around a failed plugin (PR #60 review F5): the one way
/// forward, in plain words, with a confirmation.
class KeyUnavailableNotice extends StatefulWidget {
  const KeyUnavailableNotice({
    super.key,
    required this.controller,
    this.compact = false,
  });
  final ClientController controller;

  /// One line and the button (the home screen); the full text is in the
  /// confirmation either way.
  final bool compact;

  static bool shown(ClientController controller) =>
      controller.keyUnavailable && controller.canResetIdentity;

  @override
  State<KeyUnavailableNotice> createState() => _KeyUnavailableNoticeState();
}

class _KeyUnavailableNoticeState extends State<KeyUnavailableNotice> {
  bool _resetting = false;

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Reset this device's pairing?"),
        content: const Text(
          "AnJ Cloud cannot read this device's key from Android's secure storage, so it cannot connect or pair. This deletes the unreadable key and creates a new one. Files on this device are kept. AnJ Cloud restarts, then you pair again with a new pairing code from your admin.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('key-reset-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset pairing'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _resetting = true);
    try {
      await widget.controller.resetDeviceIdentity();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'The reset did not complete. Try again, or clear AnJ Cloud\'s storage in Android settings.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('key-unavailable'),
      color: scheme.errorContainer,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: EdgeInsets.all(widget.compact ? 12 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "This device's key is unavailable",
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
            if (!widget.compact) ...[
              const SizedBox(height: 8),
              Text(
                "AnJ Cloud cannot read this device's key from Android's secure storage, so it cannot connect or pair. Resetting this device's pairing creates a new key. Files on this device are kept. Afterwards you pair again with a new pairing code from your admin.",
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('key-reset'),
              onPressed: _resetting ? null : _reset,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text("Reset this device's pairing"),
            ),
          ],
        ),
      ),
    );
  }
}
