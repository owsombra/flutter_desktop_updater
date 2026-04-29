import "dart:async";
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/download.dart";

/// Downloads changed files and returns a stream of [UpdateProgress].
///
/// Each file download retries up to 3 times (handled by [downloadFile]).
/// If any file still fails after retries, the incomplete `update/` directory
/// is cleaned up and an error is emitted on the stream.
Future<Stream<UpdateProgress>> updateAppFunction({
  required String remoteUpdateFolder,
  required List<FileHashModel?> changes,
}) async {
  final executablePath = Platform.resolvedExecutable;

  final directoryPath = executablePath.substring(
    0,
    executablePath.lastIndexOf(Platform.pathSeparator),
  );

  var dir = Directory(directoryPath);

  if (Platform.isMacOS) {
    dir = dir.parent;
  }

  final responseStream = StreamController<UpdateProgress>();

  try {
    if (await dir.exists()) {
      if (changes.isEmpty) {
        print("No updates required.");
        await responseStream.close();
        return responseStream.stream;
      }

      // Filter out nulls once
      final validChanges = changes.whereType<FileHashModel>().toList();

      if (validChanges.isEmpty) {
        print("No valid changes to download.");
        await responseStream.close();
        return responseStream.stream;
      }

      var receivedBytes = 0.0;
      final totalFiles = validChanges.length;
      var completedFiles = 0;
      var hasError = false;

      final totalLengthKB = validChanges.fold<double>(
        0,
        (prev, element) => prev + (element.length / 1024.0),
      );

      final changesFutureList = <Future<dynamic>>[];

      for (final file in validChanges) {
        changesFutureList.add(
          downloadFile(
            remoteUpdateFolder,
            file.filePath,
            dir.path,
            (received, total) {
              receivedBytes += received;
              if (!responseStream.isClosed) {
                responseStream.add(
                  UpdateProgress(
                    totalBytes: totalLengthKB,
                    receivedBytes: receivedBytes,
                    currentFile: file.filePath,
                    totalFiles: totalFiles,
                    completedFiles: completedFiles,
                  ),
                );
              }
            },
          ).then((_) {
            completedFiles += 1;

            if (!responseStream.isClosed) {
              responseStream.add(
                UpdateProgress(
                  totalBytes: totalLengthKB,
                  receivedBytes: receivedBytes,
                  currentFile: file.filePath,
                  totalFiles: totalFiles,
                  completedFiles: completedFiles,
                ),
              );
            }
            print("Completed: ${file.filePath}");
          }).catchError((error) {
            hasError = true;
            print("Download failed: ${file.filePath} - $error");
            if (!responseStream.isClosed) {
              responseStream.addError(error);
            }
            return null;
          }),
        );
      }

      unawaited(
        Future.wait(changesFutureList).then((_) async {
          // If any download failed, clean up the update directory
          if (hasError) {
            final updateDir = Directory("${dir.path}/update");
            if (updateDir.existsSync()) {
              try {
                updateDir.deleteSync(recursive: true);
                print("Cleaned up incomplete update directory.");
              } catch (e) {
                print("Failed to clean up update directory: $e");
              }
            }
          }
          await responseStream.close();
        }),
      );

      return responseStream.stream;
    }
  } catch (e) {
    responseStream.addError(e);
    await responseStream.close();
  }

  return responseStream.stream;
}