import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.userDefines['build_assets'] == false) {
      stdout.writeln('Skipping the Rust build: user-define build_assets=false');
      return;
    }
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoEnvironmentVariables: _bindgenEnvironment(input),
    ).run(input: input, output: output);
  });
}

// rquickjs runs bindgen on Android, which must load libclang; Linux NDKs before
// r26 keep it under lib64, later ones and every macOS NDK under lib. Google's
// Windows NDK omits libclang.dll, so on Windows we load libclang.dll from host
// LLVM while pinning CLANG_PATH to the NDK clang.exe for header discovery.
Map<String, String> _bindgenEnvironment(BuildInput input) {
  if (!input.config.buildCodeAssets ||
      input.config.code.targetOS != OS.android) {
    return const {};
  }
  final compiler = input.config.code.cCompiler?.compiler;
  if (compiler == null) {
    return const {};
  }
  final compilerFile = File.fromUri(compiler);
  final llvmRoot = compilerFile.parent.parent;
  for (final name in const ['lib', 'lib64', 'bin']) {
    final directory = Directory(
      '${llvmRoot.path}${Platform.pathSeparator}$name',
    );
    if (_containsLibclang(directory)) {
      return {'LIBCLANG_PATH': directory.path};
    }
  }
  if (Platform.isWindows) {
    final hostLibclangDir = _findWindowsHostLibclang();
    if (hostLibclangDir != null) {
      final ndkClang = File(
        '${llvmRoot.path}${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}clang.exe',
      );
      return {
        'LIBCLANG_PATH': hostLibclangDir.path,
        if (ndkClang.existsSync())
          'CLANG_PATH': ndkClang.path
        else if (compilerFile.existsSync())
          'CLANG_PATH': compilerFile.path,
      };
    }
    throw StateError(
      'No libclang.dll found in NDK (${llvmRoot.path}) or host Windows LLVM. '
      'Install LLVM (`winget install -e --id LLVM.LLVM`) or set LIBCLANG_PATH.',
    );
  }
  throw StateError(
    'No libclang under ${llvmRoot.path} (lib or lib64); the NDK Flutter '
    'passed cannot run bindgen for rquickjs',
  );
}

Directory? _findWindowsHostLibclang() {
  final envPath = Platform.environment['LIBCLANG_PATH'];
  final candidates = <String>[
    if (envPath != null && envPath.isNotEmpty) envPath,
    r'C:\Program Files\LLVM\bin',
    r'C:\Program Files (x86)\LLVM\bin',
    ..._visualStudioLlvmDirs(),
    ...(Platform.environment['PATH'] ?? '').split(';').where((e) => e.isNotEmpty),
  ];
  for (final candidate in candidates) {
    final dir = FileSystemEntity.isFileSync(candidate)
        ? File(candidate).parent
        : Directory(candidate);
    if (_containsLibclang(dir)) {
      return dir;
    }
  }
  return null;
}

Iterable<String> _visualStudioLlvmDirs() sync* {
  for (final root in const [
    r'C:\Program Files\Microsoft Visual Studio',
    r'C:\Program Files (x86)\Microsoft Visual Studio',
  ]) {
    final rootDir = Directory(root);
    if (!rootDir.existsSync()) continue;
    for (final year in rootDir.listSync().whereType<Directory>()) {
      for (final edition in year.listSync().whereType<Directory>()) {
        yield '${edition.path}\\VC\\Tools\\Llvm\\x64\\bin';
      }
    }
  }
}

bool _containsLibclang(Directory directory) {
  if (!directory.existsSync()) return false;
  try {
    return directory.listSync().any(_isLibclang);
  } on FileSystemException {
    return false;
  }
}

bool _isLibclang(FileSystemEntity entity) {
  return entity.path
      .split(Platform.pathSeparator)
      .last
      .toLowerCase()
      .startsWith('libclang.');
}
