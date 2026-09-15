import 'package:file_picker/file_picker.dart' as fp;
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// Per-application split for desktop: which executables use the tunnel.
///
/// The lists live in [VpnProps.accessControlProps] (tunneled = acceptList,
/// non-tunneled = rejectList) and are rendered into mihomo rules by
/// [DesktopAccessRules]. The rules only bite when the Core runs in TUN mode,
/// so enabling the feature first walks through the TUN authorization (Helper
/// service install behind a UAC prompt on Windows); a declined prompt leaves
/// the feature off.
class AccessDesktopView extends ConsumerStatefulWidget {
  const AccessDesktopView({super.key});

  @override
  ConsumerState<AccessDesktopView> createState() => _AccessDesktopViewState();
}

enum _ListKind { tunneled, nonTunneled }

class _AccessDesktopViewState extends ConsumerState<AccessDesktopView> {
  bool _authorizing = false;
  bool _saving = false;
  bool _dirty = false;

  AccessDesktopStrings get _strings => AccessDesktopStrings.of(context);

  void _update(AccessControlProps Function(AccessControlProps props) builder) {
    ref
        .read(vpnSettingProvider.notifier)
        .update(
          (state) => state.copyWith(
            accessControlProps: builder(state.accessControlProps),
          ),
        );
  }

  Future<void> _handleEnable(bool value) async {
    if (!value) {
      _update((props) => props.copyWith(enable: false));
      await _save();
      return;
    }
    if (_authorizing) {
      return;
    }
    setState(() {
      _authorizing = true;
    });
    try {
      final authorized = await ref
          .read(setupActionProvider.notifier)
          .authorizeTun();
      if (!mounted) {
        return;
      }
      if (!authorized) {
        dialogs.showNotifier(_strings.tunDeclined, level: MessageLevel.warning);
        return;
      }
      if (!ref.read(patchClashConfigProvider).tun.enable) {
        ref
            .read(patchClashConfigProvider.notifier)
            .update((state) => state.copyWith.tun(enable: true));
      }
      _update((props) => props.copyWith(enable: true));
      await _save();
    } finally {
      if (mounted) {
        setState(() {
          _authorizing = false;
        });
      }
    }
  }

  void _markDirty() {
    if (!_dirty) {
      setState(() {
        _dirty = true;
      });
    }
  }

  /// Applies the current lists by restarting the Core process, not by
  /// hot-reloading the config.
  ///
  /// A hot reload (`applyProfile`) builds a fresh set of outbounds and only
  /// swaps the proxy map; the previous WireGuard outbound keeps its UDP socket
  /// and timers alive until the garbage collector reaches it. Two or more
  /// devices with the same key then take turns handshaking with the node and
  /// steal the session from each other every few seconds (A31-BUG-4,
  /// docs/canary/node-20.md CAN-47/CAN-50): the tunnel goes dark in 30-40 s
  /// windows for every application behind the TUN. Restarting the Core kills
  /// the process, so every socket is closed for certain; the restart worker
  /// re-applies the profile with the new lists and brings the TUN back up.
  /// Applications reconnect and land under the new rules.
  Future<void> _save() async {
    if (_saving) {
      return;
    }
    setState(() {
      _saving = true;
    });
    try {
      final applied = await ref
          .read(coreActionProvider.notifier)
          .restartCore();
      if (!mounted) {
        return;
      }
      if (applied) {
        setState(() {
          _dirty = false;
        });
        dialogs.showNotifier(_strings.applied, level: MessageLevel.success);
      } else {
        dialogs.showNotifier(_strings.applyFailed, level: MessageLevel.error);
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _handleBack() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final res = await dialogs.showMessage(
      title: _strings.title,
      message: TextSpan(text: _strings.saveChangesPrompt),
      confirmText: _strings.save,
    );
    if (res == true) {
      await _save();
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  List<String> _listOf(AccessControlProps props, _ListKind kind) =>
      switch (kind) {
        _ListKind.tunneled => props.acceptList,
        _ListKind.nonTunneled => props.rejectList,
      };

  AccessControlProps _withList(
    AccessControlProps props,
    _ListKind kind,
    List<String> list,
  ) => switch (kind) {
    _ListKind.tunneled => props.copyWith(acceptList: list),
    _ListKind.nonTunneled => props.copyWith(rejectList: list),
  };

  void _add(_ListKind kind, String? entry) {
    if (entry == null) {
      return;
    }
    _addAll(kind, [entry]);
  }

  /// Adds entries, skipping blanks and case-insensitive duplicates.
  void _addAll(_ListKind kind, Iterable<String> entries) {
    final values = entries
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList();
    if (values.isEmpty) {
      return;
    }
    var changed = false;
    _update((props) {
      final list = List<String>.from(_listOf(props, kind));
      for (final value in values) {
        final exists = list.any(
          (item) => item.toLowerCase() == value.toLowerCase(),
        );
        if (!exists) {
          list.add(value);
          changed = true;
        }
      }
      return changed ? _withList(props, kind, list) : props;
    });
    if (changed) {
      _markDirty();
    }
  }

  void _remove(_ListKind kind, String entry) {
    _update((props) {
      final list = _listOf(props, kind).where((item) => item != entry).toList();
      return _withList(props, kind, list);
    });
    _markDirty();
  }

  Future<void> _pickProcess(_ListKind kind) async {
    final processes = await Future(WindowsProcesses.list);
    if (!mounted) {
      return;
    }
    final entry = await dialogs.showCommonDialog<String>(
      child: _ProcessPickerDialog(processes: processes, strings: _strings),
    );
    _add(kind, entry);
  }

  Future<void> _pickExecutable(_ListKind kind) async {
    final files = await fp.FilePicker.pickFiles(
      dialogTitle: _strings.addExecutable,
      type: fp.FileType.custom,
      allowedExtensions: const ['exe'],
    );
    _add(kind, files.isEmpty ? null : files.first.path);
  }

  Future<void> _pickFolder(_ListKind kind) async {
    final path = await fp.FilePicker.getDirectoryPath(
      dialogTitle: _strings.addFolder,
    );
    _add(kind, path);
  }

  Future<void> _typeName(_ListKind kind) async {
    final value = await dialogs.showCommonDialog<String>(
      child: _TextInputDialog(
        title: _strings.addName,
        hint: _strings.nameHint,
        strings: _strings,
      ),
    );
    if (value == null) {
      return;
    }
    // Several names at once: "a.exe, b.exe" or one per line.
    _addAll(kind, value.split(RegExp(r'[,;\r\n]+')));
  }

  Widget _buildStatus({
    required AccessControlProps props,
    required bool tunEnabled,
  }) {
    final strings = _strings;
    final (IconData icon, String text) = switch (props) {
      _ when _dirty => (Icons.save_outlined, strings.unsaved),
      AccessControlProps(enable: false) => (
        Icons.info_outline,
        strings.disabledHint,
      ),
      _ when !tunEnabled => (Icons.warning_amber_outlined, strings.tunOff),
      AccessControlProps(acceptList: final tunneled) when tunneled.isNotEmpty =>
        (
          Icons.vpn_lock,
          props.rejectList.isEmpty
              ? strings.effectiveAllow
              : '${strings.effectiveAllow} ${strings.nonTunneledIgnored}',
        ),
      AccessControlProps(rejectList: final excluded) when excluded.isNotEmpty =>
        (Icons.vpn_lock, strings.effectiveDeny),
      _ => (Icons.info_outline, strings.effectiveNone),
    };
    return ListItem(
      leading: Icon(icon, color: context.colorScheme.primary),
      title: Text(text, style: context.textTheme.bodyMedium),
    );
  }

  IconData _entryIcon(String entry) {
    final isPath = entry.contains('\\') || entry.contains('/');
    if (!isPath) {
      return Icons.apps;
    }
    return entry.toLowerCase().endsWith('.exe')
        ? Icons.terminal
        : Icons.folder_outlined;
  }

  Widget _buildSection({
    required _ListKind kind,
    required String title,
    required String description,
    required List<String> entries,
  }) {
    final strings = _strings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListHeader(title: title, subTitle: description),
        if (entries.isEmpty)
          ListItem(
            title: Text(
              strings.empty,
              style: TextStyle(color: context.colorScheme.outline),
            ),
          ),
        for (final entry in entries)
          ListItem(
            leading: Icon(_entryIcon(entry)),
            title: Text(
              entry,
              maxLines: 1,
              style: const TextStyle(overflow: TextOverflow.ellipsis),
            ),
            trailing: IconButton(
              tooltip: strings.remove,
              icon: const Icon(Icons.close),
              onPressed: () => _remove(kind, entry),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => _pickProcess(kind),
                icon: const Icon(Icons.memory),
                label: Text(strings.addProcess),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _pickExecutable(kind),
                icon: const Icon(Icons.file_open_outlined),
                label: Text(strings.addExecutable),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _pickFolder(kind),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: Text(strings.addFolder),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _typeName(kind),
                icon: const Icon(Icons.keyboard_outlined),
                label: Text(strings.addName),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final props = ref.watch(
      vpnSettingProvider.select((state) => state.accessControlProps),
    );
    final tunEnabled = ref.watch(
      patchClashConfigProvider.select((state) => state.tun.enable),
    );
    final strings = _strings;
    return CommonScaffold(
      title: strings.title,
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton.icon(
            onPressed: _dirty && !_saving ? _save : null,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(strings.save),
          ),
        ),
      ],
      body: CommonPopScope(
        onPop: (_) {
          _handleBack();
          return false;
        },
        child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          ListItem.toggle(
            leading: const Icon(Icons.alt_route),
            title: Text(strings.enable),
            subtitle: Text(strings.enableDesc),
            value: props.enable,
            onChanged: _authorizing ? null : _handleEnable,
          ),
          _buildStatus(props: props, tunEnabled: tunEnabled),
          _buildSection(
            kind: _ListKind.tunneled,
            title: strings.tunneled,
            description: strings.tunneledDesc,
            entries: props.acceptList,
          ),
          _buildSection(
            kind: _ListKind.nonTunneled,
            title: strings.nonTunneled,
            description: strings.nonTunneledDesc,
            entries: props.rejectList,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              strings.entryHelp,
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colorScheme.outline,
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }
}

class _ProcessPickerDialog extends StatefulWidget {
  final List<WindowsProcess> processes;
  final AccessDesktopStrings strings;

  const _ProcessPickerDialog({required this.processes, required this.strings});

  @override
  State<_ProcessPickerDialog> createState() => _ProcessPickerDialogState();
}

class _ProcessPickerDialogState extends State<_ProcessPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final filtered = widget.processes.where((process) {
      if (_query.isEmpty) {
        return true;
      }
      return process.name.toLowerCase().contains(_query) ||
          (process.path?.toLowerCase().contains(_query) ?? false);
    }).toList();
    return CommonDialog(
      title: strings.addProcess,
      overrideScroll: true,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
      ],
      child: SizedBox(
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                hintText: strings.search,
                prefixIcon: const Icon(Icons.search),
              ),
              onChanged: (value) {
                setState(() {
                  _query = value.trim().toLowerCase();
                });
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filtered.isEmpty
                  ? Center(child: Text(strings.empty))
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, index) {
                        final process = filtered[index];
                        return ListItem(
                          dense: true,
                          padding: EdgeInsets.zero,
                          title: Text(process.name),
                          subtitle: Text(
                            process.path ?? strings.pathUnavailable,
                            maxLines: 1,
                            style: const TextStyle(
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          onTap: () => Navigator.of(context).pop(process.entry),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextInputDialog extends StatefulWidget {
  final String title;
  final String hint;
  final AccessDesktopStrings strings;

  const _TextInputDialog({
    required this.title,
    required this.hint,
    required this.strings,
  });

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return CommonDialog(
      title: widget.title,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        TextButton(onPressed: _submit, child: Text(strings.confirm)),
      ],
      child: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (_) => _submit(),
      ),
    );
  }
}

/// UI strings for the desktop per-app split. Kept out of the arb pipeline
/// for the proof of concept; English with a Russian variant.
class AccessDesktopStrings {
  final bool _ru;

  const AccessDesktopStrings._(this._ru);

  static AccessDesktopStrings of(BuildContext context) {
    final code = Localizations.maybeLocaleOf(context)?.languageCode;
    return AccessDesktopStrings._(code == 'ru');
  }

  String _t(String en, String ru) => _ru ? ru : en;

  String get title => _t('Per-app tunneling', 'Приложения через VPN');
  String get menuDesc => _t(
    'Choose which programs use the tunnel',
    'Выбор программ, которые идут через туннель',
  );
  String get enable => _t('Enable per-app tunneling', 'Включить сплит по приложениям');
  String get enableDesc => _t(
    'Requires TUN mode; administrator rights are requested once',
    'Нужен режим TUN; права администратора запрашиваются один раз',
  );
  String get tunDeclined => _t(
    'TUN was not authorized, per-app tunneling stays off',
    'TUN не разрешён, сплит по приложениям остаётся выключенным',
  );
  String get disabledHint => _t(
    'Off: all traffic follows the profile rules',
    'Выключено: весь трафик идёт по правилам профиля',
  );
  String get tunOff => _t(
    'TUN is off, the lists are not applied until it is on',
    'TUN выключен, списки не применяются, пока он не включён',
  );
  String get effectiveAllow => _t(
    'Only the tunneled applications use the tunnel, everything else goes direct.',
    'Через туннель идут только приложения из списка, всё остальное напрямую.',
  );
  String get nonTunneledIgnored => _t(
    'The non-tunneled list is ignored while the tunneled list is not empty.',
    'Список «мимо туннеля» не учитывается, пока список «через туннель» не пуст.',
  );
  String get effectiveDeny => _t(
    'The non-tunneled applications go direct, everything else uses the tunnel.',
    'Приложения из списка идут напрямую, всё остальное через туннель.',
  );
  String get effectiveNone => _t(
    'No applications listed yet, all traffic follows the profile rules',
    'Списки пусты, весь трафик идёт по правилам профиля',
  );
  String get tunneled => _t('Tunneled applications', 'Через туннель');
  String get tunneledDesc => _t(
    'Only these use the VPN. Leave empty to tunnel everything.',
    'Только они идут через VPN. Пусто — через VPN идёт всё.',
  );
  String get nonTunneled => _t('Non-tunneled applications', 'Мимо туннеля');
  String get nonTunneledDesc => _t(
    'These bypass the VPN. Tunneled applications take priority.',
    'Они идут мимо VPN. Список «через туннель» имеет приоритет.',
  );
  String get empty => _t('Nothing here yet', 'Пока пусто');
  String get remove => _t('Remove', 'Удалить');
  String get addProcess => _t('Running process', 'Запущенный процесс');
  String get addExecutable => _t('Executable', 'Файл .exe');
  String get addFolder => _t('Folder', 'Папка');
  String get addName => _t('By name', 'По имени');
  String get nameHint => _t(
    'e.g. discord, msedge or C:\\Games\\ (several: comma-separated)',
    'например discord, msedge или C:\\Games\\ (несколько — через запятую)',
  );
  String get save => _t('Save', 'Сохранить');
  String get unsaved => _t(
    'Changes are not applied yet: press Save. The rules are reloaded with '
    'the tunnel up (nothing leaks) and open connections are reset so that '
    'applications reconnect under the new rules.',
    'Изменения ещё не применены: нажми «Сохранить». Правила перезагрузятся '
    'при поднятом туннеле (утечки нет), открытые соединения сбросятся, '
    'чтобы приложения переподключились уже по новым правилам.',
  );
  String get applied => _t(
    'Per-app rules applied, open connections reset',
    'Правила применены, открытые соединения сброшены',
  );
  String get applyFailed => _t(
    'Could not apply the profile, see the logs',
    'Не удалось применить профиль, смотри логи',
  );
  String get saveChangesPrompt => _t(
    'Apply the changed lists before leaving?',
    'Применить изменённые списки перед выходом?',
  );
  String get entryHelp => _t(
    'A name matches the process name, .exe is optional. A path with slashes '
    'matches that executable, or every executable under the folder. '
    'Processes of other users or elevated ones can be added by name.',
    'Имя сравнивается с именем процесса, .exe можно не писать. Путь со '
    'слэшами — этот exe или все exe внутри папки. Процессы других '
    'пользователей и запущенные от администратора добавляются по имени.',
  );
  String get search => _t('Search', 'Поиск');
  String get pathUnavailable => _t('path unavailable', 'путь недоступен');
  String get cancel => _t('Cancel', 'Отмена');
  String get confirm => _t('Add', 'Добавить');
}
