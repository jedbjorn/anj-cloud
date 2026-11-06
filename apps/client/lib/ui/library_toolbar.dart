import 'package:flutter/material.dart';

import 'layout.dart';
import 'library_view.dart';
import 'shortcuts.dart';

class LibraryToolbar extends StatelessWidget {
  const LibraryToolbar({
    super.key,
    required this.policy,
    required this.onPolicyChanged,
    required this.search,
    required this.searchFocus,
    required this.onSearchChanged,
    required this.onCreateFolder,
    this.selecting = false,
    this.onSelect,
    this.onEscape,
  });

  final LibraryPolicy policy;
  final ValueChanged<LibraryPolicy> onPolicyChanged;
  final TextEditingController search;
  final FocusNode searchFocus;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback? onCreateFolder;
  final bool selecting;
  final VoidCallback? onSelect;
  final VoidCallback? onEscape;

  void clearSearch() {
    search.clear();
    onSearchChanged('');
    searchFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    // Tighter chip labels on a phone: all five fit one 360 dp row at the
    // default font size, and they wrap rather than hide at larger ones.
    final labelPadding = compactLayout(context)
        ? const EdgeInsets.symmetric(horizontal: 4)
        : null;
    final choices = Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final choice in LibraryPolicy.values)
          ChoiceChip(
            key: ValueKey('policy:${choice.name}'),
            label: Text(choice.label),
            tooltip: choice.tooltip,
            labelPadding: labelPadding,
            selected: policy == choice,
            showCheckmark: false,
            onSelected: (_) => onPolicyChanged(choice),
          ),
      ],
    );
    final field = CallbackShortcuts(
      bindings: {AppShortcuts.cancel: onEscape ?? clearSearch},
      child: TextField(
        key: const ValueKey('library-search'),
        controller: search,
        focusNode: searchFocus,
        onChanged: onSearchChanged,
        decoration: InputDecoration(
          isDense: true,
          labelText: 'Search name or path',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: search.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  onPressed: clearSearch,
                  icon: const Icon(Icons.close),
                ),
          border: const OutlineInputBorder(),
        ),
      ),
    );
    final select = OutlinedButton.icon(
      key: const ValueKey('select-button'),
      onPressed: onSelect,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      icon: Icon(selecting ? Icons.close : Icons.checklist),
      label: Text(selecting ? 'Cancel' : 'Select'),
    );
    final create = FilledButton.icon(
      key: const ValueKey('create-folder-button'),
      onPressed: onCreateFolder,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      icon: const Icon(Icons.add),
      label: const Text('Folder'),
    );
    // Phone (spec #28 Phone Layout): the desktop order, chips then search,
    // Select and Folder. Select and Folder are icon buttons with their words
    // as tooltip and screen-reader label; portrait uses two rows, landscape
    // one, so the list keeps the height.
    if (compactLayout(context)) {
      final tools = [
        IconButton(
          key: const ValueKey('select-button'),
          onPressed: onSelect,
          tooltip: selecting ? 'Cancel' : 'Select',
          isSelected: selecting,
          icon: const Icon(Icons.checklist),
          selectedIcon: const Icon(Icons.close),
        ),
        IconButton.filled(
          key: const ValueKey('create-folder-button'),
          onPressed: onCreateFolder,
          tooltip: 'Create folder',
          icon: const Icon(Icons.create_new_folder_outlined),
        ),
      ];
      if (!compactWidth(context)) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * 0.55,
                  ),
                  child: choices,
                ),
                const SizedBox(width: 12),
                Expanded(child: field),
                const SizedBox(width: 4),
                ...tools,
              ],
            ),
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(right: 8), child: choices),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: field),
                const SizedBox(width: 4),
                ...tools,
              ],
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: LayoutBuilder(
        // Five chips, search, Select and Folder fit on one line from 1000;
        // from 680 the chips share a line with Select and Folder.
        builder: (context, constraints) => constraints.maxWidth >= 1000
            ? Row(
                children: [
                  choices,
                  const SizedBox(width: 16),
                  Expanded(child: field),
                  const SizedBox(width: 16),
                  select,
                  const SizedBox(width: 8),
                  create,
                ],
              )
            : constraints.maxWidth >= 680
            ? Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: choices),
                      const SizedBox(width: 16),
                      select,
                      const SizedBox(width: 8),
                      create,
                    ],
                  ),
                  const SizedBox(height: 8),
                  field,
                ],
              )
            : Column(
                children: [
                  Align(alignment: Alignment.centerLeft, child: choices),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Flexible(child: select),
                      const SizedBox(width: 8),
                      Flexible(child: create),
                    ],
                  ),
                  const SizedBox(height: 8),
                  field,
                ],
              ),
      ),
    );
  }
}
