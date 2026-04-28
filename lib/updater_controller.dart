import "package:desktop_updater/desktop_updater.dart";
import "package:flutter/material.dart";

class DesktopUpdaterController extends ChangeNotifier {
  DesktopUpdaterController({
    required Uri? appArchiveUrl,
    this.localization,
  }) {
    if (appArchiveUrl != null) {
      init(appArchiveUrl);
    }
  }

  DesktopUpdateLocalization? localization;
  DesktopUpdateLocalization? get getLocalization => localization;

  String? _appName;
  String? get appName => _appName;

  String? _appVersion;
  String? get appVersion => _appVersion;

  Uri? _appArchiveUrl;
  Uri? get appArchiveUrl => _appArchiveUrl;

  bool _needUpdate = false;
  bool get needUpdate => _needUpdate;

  bool _isMandatory = false;
  bool get isMandatory => _isMandatory;

  String? _folderUrl;

  UpdateProgress? _updateProgress;
  UpdateProgress? get updateProgress => _updateProgress;

  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;

  bool _isDownloaded = false;
  bool get isDownloaded => _isDownloaded;

  /// Whether the download failed with an error.
  bool _hasDownloadError = false;
  bool get hasDownloadError => _hasDownloadError;

  double _downloadProgress = 0;
  double get downloadProgress => _downloadProgress;

  double _downloadSize = 0;
  double? get downloadSize => _downloadSize;

  double _downloadedSize = 0;
  double get downloadedSize => _downloadedSize;

  List<FileHashModel?>? _changedFiles;

  List<ChangeModel?>? _releaseNotes;
  List<ChangeModel?>? get releaseNotes => _releaseNotes;

  bool _skipUpdate = false;
  bool get skipUpdate => _skipUpdate;

  final _plugin = DesktopUpdater();

  void init(Uri url) {
    _appArchiveUrl = url;
    checkVersion();
    notifyListeners();
  }

  void makeSkipUpdate() {
    _skipUpdate = true;
    print("Skip update: $_skipUpdate");
    notifyListeners();
  }

  Future<void> checkVersion() async {
    if (_appArchiveUrl == null) {
      throw Exception("App archive URL is not set");
    }

    final versionResponse = await _plugin.versionCheck(
      appArchiveUrl: appArchiveUrl.toString(),
    );

    if (versionResponse?.url != null) {
      print("Found folder url: ${versionResponse?.url}");

      _needUpdate = true;
      _folderUrl = versionResponse?.url;
      _isMandatory = versionResponse?.mandatory ?? false;

      // Calculate total length in KB
      _downloadSize = (versionResponse?.changedFiles?.fold<double>(
            0,
            (previousValue, element) =>
                previousValue + ((element?.length ?? 0) / 1024.0),
          )) ??
          0.0;

      // Get changed files list
      _changedFiles = versionResponse?.changedFiles;
      _releaseNotes = versionResponse?.changes;
      _appName = versionResponse?.appName;
      _appVersion = versionResponse?.version;

      print("Need update: $_needUpdate");

      notifyListeners();
    }
  }

  Future<void> downloadUpdate() async {
    if (_folderUrl == null) {
      throw Exception("Folder URL is not set");
    }

    if (_changedFiles == null || _changedFiles!.isEmpty) {
      throw Exception("Changed files are not set");
    }

    // Reset state before starting
    _hasDownloadError = false;
    _isDownloading = true;
    _isDownloaded = false;
    _downloadProgress = 0;
    _downloadedSize = 0;
    notifyListeners();

    final stream = await _plugin.updateApp(
      remoteUpdateFolder: _folderUrl!,
      changedFiles: _changedFiles ?? [],
    );

    stream.listen(
      (event) {
        _updateProgress = event;
        _isDownloading = true;
        _isDownloaded = false;
        _downloadProgress = event.receivedBytes / event.totalBytes;
        _downloadedSize = _downloadSize * _downloadProgress;
        notifyListeners();
      },
      onError: (error) {
        print("Download error: $error");
        _hasDownloadError = true;
        _isDownloading = false;
        _isDownloaded = false;
        _downloadProgress = 0;
        _downloadedSize = 0;
        notifyListeners();
      },
      onDone: () {
        _isDownloading = false;

        if (_hasDownloadError) {
          // Do NOT mark as downloaded if there was an error
          _isDownloaded = false;
          _downloadProgress = 0;
          _downloadedSize = 0;
          print("Download finished with errors. Update will not proceed.");
        } else {
          _downloadProgress = 1.0;
          _downloadedSize = _downloadSize;
          _isDownloaded = true;
          print("Download completed successfully.");
        }

        notifyListeners();
      },
    );
  }

  void restartApp() {
    _plugin.restartApp();
  }
}