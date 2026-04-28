import "dart:async";
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/download.dart";
import "package:desktop_updater/src/file_hash.dart";

/// Maximum number of verification + re-download rounds after the initial download.
const int _maxVerifyRounds = 2;

/// Downloads changed files and returns a stream of [UpdateProgress].
///
/// After all files are downloaded, each file's hash is verified against the
/// expected hash from [changes]. Any files that fail verification are
/// re-downloaded (up to [_maxVerifyRounds] rounds). If files still fail after
/// all rounds, the incomplete `update/` directory is cleaned up and an error
/// is emitted on the stream.
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

      final totalLengthKB = validChanges.fold<double>(
        0,
        (prev, element) => prev + (element.length / 1024.0),
      );

      unawaited(_runDownloadAndVerify(
        responseStream: responseStream,
        remoteUpdateFolder: remoteUpdateFolder,
        validChanges: validChanges,
        dir: dir,
        totalLengthKB: totalLengthKB,
      ));

      return responseStream.stream;
    }
  } catch (e) {
    responseStream.addError(e);
    await responseStream.close();
  }

  return responseStream.stream;
}

/// Orchestrates the download, verification, and retry loop, then closes the stream.
Future<void> _runDownloadAndVerify({
  required StreamController<UpdateProgress> responseStream,
  required String remoteUpdateFolder,
  required List<FileHashModel> validChanges,
  required Directory dir,
  required double totalLengthKB,
}) async {
  try {
    // -- Initial download of all files --
    final downloadError = await _downloadFiles(
      responseStream: responseStream,
      remoteUpdateFolder: remoteUpdateFolder,
      files: validChanges,
      dir: dir,
      totalLengthKB: totalLengthKB,
      totalFiles: validChanges.length,
      completedFilesBefore: 0,
      receivedBytesBefore: 0,
    );

    if (downloadError) {
      await _cleanupAndError(
        responseStream,
        dir,
        "One or more files failed to download after retries.",
      );
      return;
    }

    // -- Verification + re-download rounds --
    for (var round = 1; round <= _maxVerifyRounds; round++) {
      final failedFiles = await _verifyDownloadedFiles(
        dir: dir,
        expectedFiles: validChanges,
      );

      if (failedFiles.isEmpty) {
        print("All files verified successfully"
            "${round > 1 ? " (round $round)" : ""}.");
        await responseStream.close();
        return;
      }

      print("Verification round $round: "
          "${failedFiles.length} file(s) failed hash check. "
          "Re-downloading...");

      // Delete the bad files before re-downloading
      for (final file in failedFiles) {
        final filePath = "${dir.path}/update/${file.filePath}";
        final f = File(filePath);
        if (f.existsSync()) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }

      final retryError = await _downloadFiles(
        responseStream: responseStream,
        remoteUpdateFolder: remoteUpdateFolder,
        files: failedFiles,
        dir: dir,
        totalLengthKB: totalLengthKB,
        totalFiles: validChanges.length,
        completedFilesBefore: validChanges.length - failedFiles.length,
        receivedBytesBefore: totalLengthKB -
            failedFiles.fold<double>(
              0,
              (prev, e) => prev + (e.length / 1024.0),
            ),
      );

      if (retryError) {
        await _cleanupAndError(
          responseStream,
          dir,
          "Re-download failed in verification round $round.",
        );
        return;
      }
    }

    // Final verification after all retry rounds
    final stillFailed = await _verifyDownloadedFiles(
      dir: dir,
      expectedFiles: validChanges,
    );

    if (stillFailed.isNotEmpty) {
      final fileNames = stillFailed.map((f) => f.filePath).join(", ");
      await _cleanupAndError(
        responseStream,
        dir,
        "Files still invalid after $_maxVerifyRounds verification rounds: "
            "$fileNames",
      );
      return;
    }

    print("All files verified successfully after retry rounds.");
    await responseStream.close();
  } catch (e) {
    await _cleanupAndError(responseStream, dir, e.toString());
  }
}

/// Downloads a list of files in parallel. Returns `true` if any file failed.
Future<bool> _downloadFiles({
  required StreamController<UpdateProgress> responseStream,
  required String remoteUpdateFolder,
  required List<FileHashModel> files,
  required Directory dir,
  required double totalLengthKB,
  required int totalFiles,
  required int completedFilesBefore,
  required double receivedBytesBefore,
}) async {
  var receivedBytes = receivedBytesBefore;
  var completedFiles = completedFilesBefore;
  var hasError = false;

  final futures = <Future<dynamic>>[];

  for (final file in files) {
    futures.add(
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

  await Future.wait(futures);
  return hasError;
}

/// Verifies each downloaded file's hash against the expected hash.
/// Returns a list of [FileHashModel] entries whose hashes do not match.
Future<List<FileHashModel>> _verifyDownloadedFiles({
  required Directory dir,
  required List<FileHashModel> expectedFiles,
}) async {
  final failed = <FileHashModel>[];

  for (final expected in expectedFiles) {
    final filePath = "${dir.path}/update/${expected.filePath}";
    final file = File(filePath);

    if (!file.existsSync()) {
      print("Verification failed: file missing - ${expected.filePath}");
      failed.add(expected);
      continue;
    }

    // Check file size first as a quick sanity check
    final actualLength = file.lengthSync();
    if (actualLength != expected.length) {
      print("Verification failed: size mismatch for ${expected.filePath} "
          "(expected ${expected.length}, got $actualLength)");
      failed.add(expected);
      continue;
    }

    // Verify hash
    final actualHash = await getFileHash(file);
    if (actualHash != expected.calculatedHash) {
      print("Verification failed: hash mismatch for ${expected.filePath}");
      failed.add(expected);
    }
  }

  return failed;
}

/// Cleans up the update directory and sends an error before closing the stream.
Future<void> _cleanupAndError(
  StreamController<UpdateProgress> responseStream,
  Directory dir,
  String errorMessage,
) async {
  print("Update failed: $errorMessage");

  final updateDir = Directory("${dir.path}/update");
  if (updateDir.existsSync()) {
    try {
      updateDir.deleteSync(recursive: true);
      print("Cleaned up incomplete update directory.");
    } catch (e) {
      print("Failed to clean up update directory: $e");
    }
  }

  if (!responseStream.isClosed) {
    responseStream.addError(Exception(errorMessage));
  }
  await responseStream.close();
}