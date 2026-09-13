import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// A running Windows process as seen by the (unprivileged) UI process.
///
/// [path] is null when the image path cannot be queried, which is the case for
/// elevated, protected or other users' processes; such entries can still be
/// added by [name].
class WindowsProcess {
  final int pid;
  final String name;
  final String? path;

  const WindowsProcess({required this.pid, required this.name, this.path});

  /// The list entry to store: the full path when known, else the name.
  String get entry => path ?? name;
}

final class _ProcessEntry32W extends Struct {
  @Uint32()
  external int dwSize;
  @Uint32()
  external int cntUsage;
  @Uint32()
  external int th32ProcessID;
  @IntPtr()
  external int th32DefaultHeapID;
  @Uint32()
  external int th32ModuleID;
  @Uint32()
  external int cntThreads;
  @Uint32()
  external int th32ParentProcessID;
  @Int32()
  external int pcPriClassBase;
  @Uint32()
  external int dwFlags;
  @Array(260)
  external Array<Uint16> szExeFile;
}

typedef _CreateSnapshotC = IntPtr Function(Uint32 flags, Uint32 processId);
typedef _CreateSnapshotDart = int Function(int flags, int processId);
typedef _Process32C = Int32 Function(IntPtr snapshot, Pointer<_ProcessEntry32W>);
typedef _Process32Dart = int Function(int snapshot, Pointer<_ProcessEntry32W>);
typedef _OpenProcessC = IntPtr Function(Uint32 access, Int32 inherit, Uint32 pid);
typedef _OpenProcessDart = int Function(int access, int inherit, int pid);
typedef _QueryImageNameC =
    Int32 Function(IntPtr process, Uint32 flags, Pointer<Utf16>, Pointer<Uint32>);
typedef _QueryImageNameDart =
    int Function(int process, int flags, Pointer<Utf16>, Pointer<Uint32>);
typedef _CloseHandleC = Int32 Function(IntPtr handle);
typedef _CloseHandleDart = int Function(int handle);

/// Enumerates running processes through the ToolHelp snapshot API.
///
/// Works without administrator rights; paths of processes the caller may not
/// open come back as null. Windows only.
abstract final class WindowsProcesses {
  static const _snapshotProcesses = 0x00000002; // TH32CS_SNAPPROCESS
  static const _queryLimitedInformation = 0x1000; // PROCESS_QUERY_LIMITED_INFORMATION
  static const _invalidHandle = -1;
  static const _pathCapacity = 32768;

  static DynamicLibrary? _kernel32Cache;

  static DynamicLibrary get _kernel32 =>
      _kernel32Cache ??= DynamicLibrary.open('kernel32.dll');

  /// One entry per distinct executable, sorted by name; paths are preferred
  /// over names when two processes share a name.
  static List<WindowsProcess> list() {
    final kernel32 = _kernel32;
    final createSnapshot = kernel32
        .lookupFunction<_CreateSnapshotC, _CreateSnapshotDart>(
          'CreateToolhelp32Snapshot',
        );
    final first = kernel32.lookupFunction<_Process32C, _Process32Dart>(
      'Process32FirstW',
    );
    final next = kernel32.lookupFunction<_Process32C, _Process32Dart>(
      'Process32NextW',
    );
    final closeHandle = kernel32.lookupFunction<_CloseHandleC, _CloseHandleDart>(
      'CloseHandle',
    );

    final snapshot = createSnapshot(_snapshotProcesses, 0);
    if (snapshot == _invalidHandle || snapshot == 0) {
      return const [];
    }
    final entry = calloc<_ProcessEntry32W>();
    entry.ref.dwSize = sizeOf<_ProcessEntry32W>();
    final byKey = <String, WindowsProcess>{};
    try {
      if (first(snapshot, entry) == 0) {
        return const [];
      }
      do {
        final pid = entry.ref.th32ProcessID;
        final name = _exeName(entry.ref);
        if (pid == 0 || name.isEmpty) {
          continue;
        }
        final path = _imagePath(pid);
        final key = (path ?? name).toLowerCase();
        byKey.putIfAbsent(
          key,
          () => WindowsProcess(pid: pid, name: name, path: path),
        );
      } while (next(snapshot, entry) != 0);
    } finally {
      calloc.free(entry);
      closeHandle(snapshot);
    }
    final processes = byKey.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return processes;
  }

  static String _exeName(_ProcessEntry32W entry) {
    final units = <int>[];
    for (var i = 0; i < 260; i++) {
      final unit = entry.szExeFile[i];
      if (unit == 0) break;
      units.add(unit);
    }
    return String.fromCharCodes(units);
  }

  static String? _imagePath(int pid) {
    final kernel32 = _kernel32;
    final openProcess = kernel32.lookupFunction<_OpenProcessC, _OpenProcessDart>(
      'OpenProcess',
    );
    final queryImageName = kernel32
        .lookupFunction<_QueryImageNameC, _QueryImageNameDart>(
          'QueryFullProcessImageNameW',
        );
    final closeHandle = kernel32.lookupFunction<_CloseHandleC, _CloseHandleDart>(
      'CloseHandle',
    );
    final process = openProcess(_queryLimitedInformation, 0, pid);
    if (process == 0) {
      return null;
    }
    final buffer = calloc<Uint16>(_pathCapacity);
    final size = calloc<Uint32>()..value = _pathCapacity;
    try {
      final ok = queryImageName(process, 0, buffer.cast<Utf16>(), size);
      if (ok == 0 || size.value == 0) {
        return null;
      }
      return buffer.cast<Utf16>().toDartString(length: size.value);
    } finally {
      calloc.free(buffer);
      calloc.free(size);
      closeHandle(process);
    }
  }
}
