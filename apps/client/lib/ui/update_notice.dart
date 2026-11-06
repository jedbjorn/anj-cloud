import 'package:flutter/material.dart';

import '../core/update/desktop_updater.dart';

/// The desktop updater's one notice and status line (spec #37 rule 4):
/// **Update available (version X) — Update now / Later**, the wait for
/// syncing or Finish editing, and "Update could not be verified" /
/// "Update required" / "Updated to version X" in the status area.
class UpdateNotice extends StatelessWidget {
  const UpdateNotice({super.key, required this.updater});
  final DesktopUpdater updater;

  @override
  Widget build(BuildContext context) {
    final notice = updater.notice;
    final status = updater.status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (notice != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              key: const ValueKey('update-notice'),
              children: [
                const Icon(Icons.system_update_alt, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(notice)),
                if (updater.phase == DesktopUpdatePhase.ready) ...[
                  TextButton(
                    key: const ValueKey('update-later'),
                    onPressed: updater.later,
                    child: const Text('Later'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    key: const ValueKey('update-now'),
                    onPressed: () => updater.updateNow(),
                    child: const Text('Update now'),
                  ),
                ],
                if (updater.phase == DesktopUpdatePhase.waiting)
                  TextButton(
                    key: const ValueKey('update-cancel'),
                    onPressed: updater.cancelWaiting,
                    child: const Text('Cancel'),
                  ),
              ],
            ),
          ),
        if (status != null)
          Row(
            key: const ValueKey('update-status'),
            children: [
              Expanded(
                child: Tooltip(
                  message: updater.detail ?? '',
                  child: Text(status),
                ),
              ),
              TextButton(
                onPressed: updater.dismissStatus,
                child: const Text('Dismiss'),
              ),
            ],
          ),
      ],
    );
  }
}
