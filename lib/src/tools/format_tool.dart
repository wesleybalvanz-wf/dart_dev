import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:glob/glob.dart';
import 'package:io/ansi.dart';
import 'package:io/io.dart' show ExitCode;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../dart_dev_tool.dart';
import '../utils/assert_no_positional_args_nor_args_after_separator.dart';
import '../utils/logging.dart';
import '../utils/package_is_immediate_dependency.dart';
import '../utils/process_declaration.dart';
import '../utils/run_process_and_ensure_exit.dart';

final _log = Logger('Format');

/// A dart_dev tool that runs the dart formatter on the current project.
///
/// To use this tool in your project, include it in the dart_dev config in
/// `tool/dev.dart`:
///     import 'package:dart_dev/dart_dev.dart';
///
///     final config = {
///       'format': FormatTool(),
///     };
///
/// This will make it available via the `dart_dev` command-line app like so:
///     pub run dart_dev format
///
/// This tool can be configured by modifying any of its fields:
///     // tool/dev.dart
///     import 'package:dart_dev/dart_dev.dart';
///
///     final config = {
///       'format': FormatTool()
///         ..defaultMode = FormatMode.assertNoChanges
///         ..exclude = [Glob('lib/src/generated/**.dart')]
///         ..formatter = Formatter.dartStyle,
///     };
///
/// It is also possible to run this tool directly in a dart script:
///     FormatTool().run();
class FormatTool extends DevTool {
  /// The default mode in which to run the formatter.
  ///
  /// This is still overridable via the command line:
  ///     ddev format -- -n  # dry-run
  ///     ddev format -- -w  # ovewrite
  FormatMode defaultMode = FormatMode.overwrite;

  @override
  String description = 'Format dart files in this package.';

  /// The globs to exclude from the inputs to the dart formatter.
  ///
  /// By default, nothing is excluded.
  List<Glob> exclude;

  /// The formatter to run, one of:
  /// - `dartfmt` (provided by the SDK)
  /// - `pub run dart_style:format` (provided by the `dart_style` package)
  Formatter formatter = Formatter.dartfmt;

  /// The args to pass to the formatter process run by this command.
  ///
  /// Run `dartfmt -h -v` to see all available args.
  List<String> formatterArgs;

  /// The globs to include as inputs to the dart formatter.
  ///
  /// The default is `.` (e.g. `dartfmt .`) which runs the formatter on all
  /// known dart project directories (`benchmark/`, `bin/`, `example/`, `test/`,
  /// `tool/`, `web/`) as well as dart files in the root.
  List<Glob> include;

  @override
  FutureOr<int> run([DevToolExecutionContext context]) {
    context ??= DevToolExecutionContext();
    final execution = buildExecution(context,
        configuredFormatterArgs: formatterArgs,
        defaultMode: defaultMode,
        exclude: exclude,
        formatter: formatter,
        include: include);
    return execution.exitCode ?? runProcessAndEnsureExit(execution.process);
  }

  @override
  Command<int> toCommand(String name) => DevToolCommand(name, this,
      argParser: ArgParser()
        ..addSeparator('======== Formatter Mode')
        ..addFlag('overwrite',
            abbr: 'w',
            negatable: false,
            help: 'Overwrite input files with formatted output.')
        ..addFlag('dry-run',
            abbr: 'n',
            negatable: false,
            help: 'Show which files would be modified but make no changes.')
        ..addFlag('assert',
            abbr: 'a',
            negatable: false,
            help:
                'Assert that no changes need to be made by setting the exit code '
                'accordingly.\nImplies "--dry-run" and "--set-exit-if-changed".')
        ..addSeparator('======== Other Options')
        ..addOption('formatter-args',
            help: 'Args to pass to the "dartfmt" process.\n'
                'Run "dartfmt -h -v" to see all available options.'));
}

/// A declarative representation of an execution of the [FormatTool].
///
/// This class allows the [FormatTool] to break its execution up into two steps:
/// 1. Validation of confg/inputs and creation of this class.
/// 2. Execution of expensive or hard-to-test logic based on step 1.
///
/// As a result, nearly all of the logic in [FormatTool] can be tested via the
/// output of step 1 (an instance of this class) with very simple unit tests.
class FormatExecution {
  FormatExecution.exitEarly(this.exitCode) : process = null;
  FormatExecution.process(this.process) : exitCode = null;

  /// If non-null, the execution is already complete and the [FormatTool] should
  /// exit with this code.
  ///
  /// If null, there is more work to do.
  final int exitCode;

  /// A declarative representation of the formatter process that should be run.
  ///
  /// This process' result should become the final result of the [FormatTool].
  final ProcessDeclaration process;
}

/// Modes supported by the dart formatter.
enum FormatMode {
  // dartanalyzer -n --set-exit-if-changed
  assertNoChanges,
  // dartanalyzer -n
  dryRun,
  // dartanalyzer -w
  overwrite,
}

/// Available dart formatters.
enum Formatter {
  // The formatter provided via the Dart SDK.
  dartfmt,
  // The formatter provided via the `dart_style` package.
  dartStyle,
}

/// Builds and returns the full list of args for the formatter process that
/// [FormatTool] will start.
///
/// [executableArgs] will be included first and are only needed when using the
/// `dart_style:format` executable (e.g. `pub run dart_style:format`).
///
/// Next, [mode] will be mapped to the appropriate formatter arg(s), e.g. `-w`,
/// and included.
///
/// If non-null, [configuredFormatterArgs] will be included next.
///
/// If [argResults] is non-null and the `--formatter-args` option is non-null,
/// they will be included next.
///
/// Finally, if [verbose] is true and the verbose flag (`-v`) is not already
/// included, it will be added.
Iterable<String> buildArgs(
  Iterable<String> executableArgs,
  FormatMode mode, {
  ArgResults argResults,
  List<String> configuredFormatterArgs,
  bool verbose,
}) {
  final args = <String>[
    ...executableArgs,

    // Combine all args that should be passed through to the dartanalyzer in
    // this order:
    // 1. Mode flag(s), if configured
    if (mode == FormatMode.assertNoChanges) ...[
      '-n',
      '--set-exit-if-changed',
    ],
    if (mode == FormatMode.overwrite)
      '-w',
    if (mode == FormatMode.dryRun)
      '-n',

    // 2. Statically configured args from [FormatTool.formatterArgs]
    if (configuredFormatterArgs != null)
      ...configuredFormatterArgs,
    // 3. Args passed to --formatter-args
    if (argResults != null && argResults['formatter-args'] != null)
      ...argResults['formatter-args'].split(' '),
  ];
  if (verbose == true && !args.contains('-v') && !args.contains('--verbose')) {
    args.add('-v');
  }
  return args;
}

/// Returns a declarative representation of a formatter process to run based on
/// the given parameters.
///
/// These parameters will be populated from [FormatTool] when it is executed
/// (either directly or via a command-line app).
///
/// [context] is the execution context that would be provided by [AnalyzeTool]
/// when converted to a [DevToolCommand]. For tests, this can be manually
/// created to imitate the various CLI inputs.
///
/// [configuredFormatterArgs] will be populated from
/// [AnalyzeTool.formatterArgs].
///
/// [defaultMode] will be populated from [FormatTool.defaultMode].
///
/// [exclude] will be populated from [FormatTool.exclude].
///
/// [formatter] will be populated from [FormatTool.formatter].
///
/// [include] will be populated from [FormatTool.include].
///
/// If non-null, [path] will override the current working directory for any
/// operations that require it. This is intended for use by tests.
///
/// The [FormatTool] can be tested almost completely via this function by
/// enumerating all of the possible parameter variations and making assertions
/// on the declarative output.
FormatExecution buildExecution(
  DevToolExecutionContext context, {
  List<String> configuredFormatterArgs,
  FormatMode defaultMode,
  List<Glob> exclude,
  Formatter formatter,
  List<Glob> include,
  String path,
}) {
  FormatMode mode;
  if (context.argResults != null) {
    assertNoPositionalArgsNorArgsAfterSeparator(
        context.argResults, context.usageException,
        commandName: context.commandName,
        usageFooter: 'Arguments can be passed to the "dartfmt" process via the '
            '--formatter-args option.');
    mode = validateAndParseMode(context.argResults, context.usageException);
  }
  mode ??= defaultMode;

  if (formatter == Formatter.dartStyle &&
      !packageIsImmediateDependency('dart_style', path: path)) {
    _log.severe(red.wrap('Cannot run "dart_style:format".\n') +
        yellow.wrap('You must either have a dependency on "dart_style" in '
            'pubspec.yaml or configure the format tool to use "dartfmt" '
            'instead.\n'
            'Either add "dart_style" to your pubspec.yaml or configure the '
            'format tool to use "dartfmt" instead.'));
    return FormatExecution.exitEarly(ExitCode.config.code);
  }

  final inputs = buildInputs(exclude: exclude, include: include);
  if (inputs.isEmpty) {
    return FormatExecution.exitEarly(ExitCode.config.code);
  }

  final dartfmt = buildProcess(formatter);
  final args = buildArgs(dartfmt.args, mode,
      argResults: context.argResults,
      configuredFormatterArgs: configuredFormatterArgs,
      verbose: context.verbose);
  logCommand(dartfmt.executable, inputs, args, verbose: context.verbose);
  return FormatExecution.process(ProcessDeclaration(
      dartfmt.executable, [...args, ...inputs],
      mode: ProcessStartMode.inheritStdio));
}

/// Builds and returns the list of inputs on which the formatter should be run.
///
/// These inputs are determined by expanding the [include] globs and filtering
/// out any paths that match the expanded [exclude] globs.
///
/// Logs may be output in certain scenarios for debugging purposes.
///
/// By default these globs are assumed to be relative to the current working
/// directory, but that can be overridden via [root] for testing purposes.
Iterable<String> buildInputs(
    {List<Glob> exclude, List<Glob> include, String root}) {
  exclude ??= <Glob>[];
  include ??= [
    if (exclude.isNotEmpty) ...[
      Glob('*.dart'),
      Glob('benchmark/**.dart'),
      Glob('bin/**.dart'),
      Glob('example/**.dart'),
      Glob('lib/**.dart'),
      Glob('test/**.dart'),
      Glob('tool/**.dart'),
      Glob('web/**.dart'),
    ],
  ];
  final includePaths = {
    if (include.isEmpty) p.normalize(root ?? '.'),
  };
  for (final glob in include) {
    try {
      includePaths.addAll(glob
          .listSync(root: root)
          .where((entity) => entity is File || entity is Directory)
          .map((file) => file.path));
    } on FileSystemException catch (error, stack) {
      _log.fine('Could not list include glob: $glob', error, stack);
    }
  }
  _log.fine('Include paths:\n  ${includePaths.join('\n  ')}');

  final excludePaths = <String>{};
  for (final glob in exclude) {
    try {
      excludePaths.addAll(glob
          .listSync(root: root)
          .where((entity) => entity is File || entity is Directory)
          .map((file) => file.path));
    } on FileSystemException catch (error, stack) {
      _log.fine('Could not list exclude glob: $glob', error, stack);
    }
  }
  _log.fine('Exclude paths:\n  ${excludePaths.join('\n  ')}');

  final excluded = includePaths.intersection(excludePaths);
  if (excluded.isNotEmpty) {
    _log.fine('Excluding these paths from formatting:\n  '
        '${includePaths.intersection(excludePaths).join('\n  ')}');
  }
  final inputs = includePaths.difference(excludePaths);
  if (inputs.isEmpty) {
    _log.severe('The formatter cannot run because no inputs could be found '
        'with the configured includes and excludes.\n'
        'Please modify the excludes and/or includes in "tool/dev.dart".');
  }
  return inputs;
}

/// Returns a representation of the process that will be run by [FormatTool]
/// based on the given [formatter].
///
/// - [Formatter.dartfmt] -> `dartfmt`
/// - [Formatter.dartStyle] -> `pub run dart_style:format`
ProcessDeclaration buildProcess([Formatter formatter]) {
  switch (formatter) {
    case Formatter.dartStyle:
      return ProcessDeclaration('pub', ['run', 'dart_style:format']);
    case Formatter.dartfmt:
    default:
      return ProcessDeclaration('dartfmt', []);
  }
}

/// Logs the dart formatter command that will be run by [FormatTool] so that
/// consumers can run it directly for debugging purposes.
///
/// Unless [verbose] is true, the list of inputs will be abbreviated to avoid an
/// unnecessarily long log.
void logCommand(
    String executable, Iterable<String> inputs, Iterable<String> args,
    {bool verbose}) {
  final exeAndArgs = '$executable ${args.join(' ')}'.trim();
  if (inputs.length <= 5 || verbose == true) {
    logSubprocessHeader(_log, '$exeAndArgs ${inputs.join(' ')}');
  } else {
    logSubprocessHeader(_log, '$exeAndArgs <${inputs.length} paths>');
  }
}

/// Attempts to parse and return a single [FormatMode] from [argResults] by
/// checking for the supported mode flags (`--assert`, `--dry-run`, and
/// `--overwrite`).
///
/// If more than one of these mode flags are used together, [usageException]
/// will be called with a message explaining that only one mode can be used.
///
/// If none of the mode flags were enabled, this returns `null`.
FormatMode validateAndParseMode(
    ArgResults argResults, void Function(String message) usageException) {
  final assertNoChanges = argResults['assert'] == true;
  final dryRun = argResults['dry-run'] == true;
  final overwrite = argResults['overwrite'] == true;

  if (assertNoChanges && dryRun && overwrite) {
    usageException(
        'Cannot use --assert and --dry-run and --overwrite at the same time.');
  }
  if (assertNoChanges && dryRun) {
    usageException('Cannot use --assert and --dry-run at the same time.');
  }
  if (assertNoChanges && overwrite) {
    usageException('Cannot use --assert and --overwrite at the same time.');
  }
  if (dryRun && overwrite) {
    usageException('Cannot use --dry-run and --overwrite at the same time.');
  }

  if (assertNoChanges) {
    return FormatMode.assertNoChanges;
  }
  if (dryRun) {
    return FormatMode.dryRun;
  }
  if (overwrite) {
    return FormatMode.overwrite;
  }
  return null;
}