import 'package:dart_dev/dart_dev.dart';
import 'package:glob/glob.dart';

final config = {
  ...coreConfig,
  'analyze': AnalyzeTool()..useDartAnalyze = true,
  'format': FormatTool()
    ..exclude = [Glob('test/**/fixtures/**.dart')]
    ..formatter = Formatter.dartFormat,
};
