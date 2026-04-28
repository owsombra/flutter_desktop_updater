import "dart:io";

import "package:http/http.dart" as http;
import "package:path/path.dart" as path;

/// Maximum number of download attempts per file.
const int _maxRetries = 3;

/// Base delay between retries (multiplied by attempt number).
const Duration _retryBaseDelay = Duration(seconds: 2);

/// Downloads a file from [host]/[filePath] and saves it to [savePath]/update/[filePath].
/// [progressCallback] receives two doubles: receivedKB and totalKB.
///
/// Retries up to [_maxRetries] times on failure with exponential back-off.
/// Cleans up incomplete files on error.
Future<void> downloadFile(
  String? host,
  String filePath,
  String savePath,
  void Function(double receivedKB, double totalKB)? progressCallback,
) async {
  if (host == null) return;

  final url = "$host/$filePath";
  final fullSavePath = path.join("$savePath/update", filePath);
  final saveDirectory = Directory(path.dirname(fullSavePath));

  for (var attempt = 1; attempt <= _maxRetries; attempt++) {
    final client = http.Client();

    try {
      final request = http.Request("GET", Uri.parse(url));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        client.close();
        throw HttpException(
          "Failed to download file (HTTP ${response.statusCode}): $url",
        );
      }

      if (!saveDirectory.existsSync()) {
        await saveDirectory.create(recursive: true);
      }

      final file = File(fullSavePath);
      final sink = file.openWrite();
      final contentLength = response.contentLength ?? 0;

      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);

          if (progressCallback != null && contentLength != 0) {
            final receivedKB = chunk.length / 1024.0;
            final totalKB = contentLength / 1024.0;
            progressCallback(receivedKB, totalKB);
          }
        }

        await sink.flush();
        await sink.close();
        print("File downloaded to $fullSavePath");
        return; // Success – exit retry loop
      } catch (e) {
        await sink.close();
        if (file.existsSync()) {
          try {
            file.deleteSync();
            print("Deleted incomplete file: $fullSavePath");
          } catch (_) {}
        }
        rethrow;
      } finally {
        client.close();
      }
    } catch (e) {
      client.close();

      if (attempt < _maxRetries) {
        final delay = _retryBaseDelay * attempt;
        print(
          "Download attempt $attempt/$_maxRetries failed for $filePath: $e. "
          "Retrying in ${delay.inSeconds}s...",
        );
        await Future.delayed(delay);
      } else {
        print(
          "Download failed after $_maxRetries attempts for $filePath: $e",
        );
        rethrow;
      }
    }
  }
}