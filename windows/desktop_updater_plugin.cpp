#include "desktop_updater_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>
#include <VersionHelpers.h>
#include <Shlwapi.h>
#include <ShlObj.h>

#pragma comment(lib, "Version.lib")
#pragma comment(lib, "Shlwapi.lib")

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>
#include <filesystem>
#include <iostream>
#include <fstream>
#include <cstdlib>
#include <vector>

namespace fs = std::filesystem;
namespace desktop_updater
{

  // static
  void DesktopUpdaterPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarWindows *registrar)
  {
    auto channel =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "desktop_updater",
            &flutter::StandardMethodCodec::GetInstance());

    auto plugin = std::make_unique<DesktopUpdaterPlugin>();

    channel->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto &call, auto result)
        {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });

    registrar->AddPlugin(std::move(plugin));
  }

  DesktopUpdaterPlugin::DesktopUpdaterPlugin() {}

  DesktopUpdaterPlugin::~DesktopUpdaterPlugin() {}

  // -- Helpers -----------------------------------------------

  static std::string wideToUtf8(const std::wstring &wide)
  {
    if (wide.empty())
      return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, NULL, 0, NULL, NULL);
    std::string out(n - 1, 0);
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, &out[0], n - 1, NULL, NULL);
    return out;
  }

  static std::wstring utf8ToWide(const std::string &utf8)
  {
    if (utf8.empty())
      return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, NULL, 0);
    std::wstring out(n - 1, 0);
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, &out[0], n - 1);
    return out;
  }

  static std::string getExeDirectoryUtf8()
  {
    wchar_t buf[MAX_PATH];
    GetModuleFileNameW(NULL, buf, MAX_PATH);
    std::wstring dir(buf);
    size_t pos = dir.find_last_of(L"\\");
    if (pos != std::wstring::npos)
      dir = dir.substr(0, pos);
    return wideToUtf8(dir);
  }

  static std::string getExePathUtf8()
  {
    wchar_t buf[MAX_PATH];
    GetModuleFileNameW(NULL, buf, MAX_PATH);
    return wideToUtf8(std::wstring(buf));
  }

  // Returns %APPDATA%\com.draftify\log  (creates if needed)
  static std::string getLogDirectorySafe()
  {
    wchar_t *appdata = nullptr;
    HRESULT hr = SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, NULL, &appdata);
    if (FAILED(hr) || appdata == nullptr)
    {
      // Fallback to exe directory
      return getExeDirectoryUtf8();
    }
    std::wstring base(appdata);
    CoTaskMemFree(appdata);

    std::wstring comDraftify = base + L"\\com.draftify";
    CreateDirectoryW(comDraftify.c_str(), NULL);

    std::wstring logDir = comDraftify + L"\\log";
    CreateDirectoryW(logDir.c_str(), NULL);

    return wideToUtf8(logDir);
  }

  // -- Bat file creation -------------------------------------

  static void createBatFile(const std::string &exeDirStr, const std::string &exePathStr)
  {
    const std::string updateDir = exeDirStr + "\\update";
    const std::string destDir = exeDirStr;
    const std::string logDir = getLogDirectorySafe();
    const std::string logFile = logDir + "\\update_log.txt";
    const std::string batFilePath = exeDirStr + "\\update_script.bat";

    const std::string batScript =
        "@echo off\n"
        "chcp 65001 > NUL\n"
        "echo [%date% %time%] Update script started > \"" + logFile + "\"\n"
        "echo [%date% %time%] CWD: %cd% >> \"" + logFile + "\"\n"
        "echo [%date% %time%] Update dir: " + updateDir + " >> \"" + logFile + "\"\n"
        "echo [%date% %time%] Dest dir: " + destDir + " >> \"" + logFile + "\"\n"
        "echo [%date% %time%] Exe path: " + exePathStr + " >> \"" + logFile + "\"\n"
        "echo [%date% %time%] Waiting for app (PID " + std::to_string(GetCurrentProcessId()) + ") to exit... >> \"" + logFile + "\"\n"
        "set RETRY=0\n"
        ":waitloop\n"
        "tasklist /FI \"PID eq " + std::to_string(GetCurrentProcessId()) + "\" 2>NUL | find \"" + std::to_string(GetCurrentProcessId()) + "\" >NUL\n"
        "if errorlevel 1 goto :waitdone\n"
        "set /a RETRY+=1\n"
        "if %RETRY% GEQ 4 (\n"
        "  echo [%date% %time%] App still running after 4s, force killing PID " + std::to_string(GetCurrentProcessId()) + "... >> \"" + logFile + "\"\n"
        "  taskkill /F /PID " + std::to_string(GetCurrentProcessId()) + " >> \"" + logFile + "\" 2>&1\n"
        "  timeout /t 1 /nobreak > NUL\n"
        "  goto :waitdone\n"
        ")\n"
        "timeout /t 1 /nobreak > NUL\n"
        "goto :waitloop\n"
        ":waitdone\n"
        "echo [%date% %time%] App exited (retries: %RETRY%) >> \"" + logFile + "\"\n"
        "if not exist \"" + updateDir + "\" (\n"
        "  echo [%date% %time%] ERROR: Update directory does not exist! >> \"" + logFile + "\"\n"
        "  goto :restart\n"
        ")\n"
        "echo [%date% %time%] Files in update directory: >> \"" + logFile + "\"\n"
        "dir /S /B \"" + updateDir + "\" >> \"" + logFile + "\" 2>&1\n"
        "echo [%date% %time%] Starting xcopy... >> \"" + logFile + "\"\n"
        "xcopy /E /I /Y \"" + updateDir + "\\*\" \"" + destDir + "\\\" >> \"" + logFile + "\" 2>&1\n"
        "echo [%date% %time%] xcopy exit code: %errorlevel% >> \"" + logFile + "\"\n"
        "echo [%date% %time%] Removing update directory... >> \"" + logFile + "\"\n"
        "rmdir /S /Q \"" + updateDir + "\" >> \"" + logFile + "\" 2>&1\n"
        "echo [%date% %time%] rmdir exit code: %errorlevel% >> \"" + logFile + "\"\n"
        ":restart\n"
        "echo [%date% %time%] Starting application... >> \"" + logFile + "\"\n"
        "start \"\" \"" + exePathStr + "\"\n"
        "echo [%date% %time%] Update script finished >> \"" + logFile + "\"\n"
        "timeout /t 2 /nobreak > NUL\n"
        "del \"" + batFilePath + "\"\n"
        "exit\n";

    std::ofstream batFile(batFilePath);
    batFile << batScript;
    batFile.close();
    std::cout << "Temporary .bat created at: " << batFilePath << std::endl;
  }

  // -- Run bat -----------------------------------------------

  static void runBatFile(const std::string &exeDirStr)
  {
    std::string batPath = exeDirStr + "\\update_script.bat";
    std::wstring cmd = L"cmd.exe /c \"" + utf8ToWide(batPath) + L"\"";

    std::vector<wchar_t> cmdBuf(cmd.begin(), cmd.end());
    cmdBuf.push_back(L'\0');

    STARTUPINFOW si = {sizeof(si)};
    PROCESS_INFORMATION pi;

    if (CreateProcessW(NULL, cmdBuf.data(), NULL, NULL, FALSE,
                       CREATE_NO_WINDOW, NULL, NULL, &si, &pi))
    {
      CloseHandle(pi.hProcess);
      CloseHandle(pi.hThread);
    }
    else
    {
      std::cout << "Failed to run the .bat file. Error: " << GetLastError() << std::endl;
    }
  }

  // -- RestartApp --------------------------------------------

  void RestartApp()
  {
    printf("Restarting the application...\n");

    std::string exeDirStr = getExeDirectoryUtf8();
    std::string exePathStr = getExePathUtf8();

    printf("Executable path: %s\n", exePathStr.c_str());
    printf("Executable dir:  %s\n", exeDirStr.c_str());

    createBatFile(exeDirStr, exePathStr);
    runBatFile(exeDirStr);

    ExitProcess(0);
  }

  // -- Method call handler -----------------------------------

  void DesktopUpdaterPlugin::HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    if (method_call.method_name().compare("getPlatformVersion") == 0)
    {
      std::ostringstream version_stream;
      version_stream << "Windows ";
      if (IsWindows10OrGreater())
      {
        version_stream << "10+";
      }
      else if (IsWindows8OrGreater())
      {
        version_stream << "8";
      }
      else if (IsWindows7OrGreater())
      {
        version_stream << "7";
      }
      result->Success(flutter::EncodableValue(version_stream.str()));
    }
    else if (method_call.method_name().compare("restartApp") == 0)
    {
      RestartApp();
      result->Success();
    }
    else if (method_call.method_name().compare("getExecutablePath") == 0)
    {
      result->Success(flutter::EncodableValue(getExePathUtf8()));
    }
    else if (method_call.method_name().compare("getCurrentVersion") == 0)
    {
      wchar_t exePath[MAX_PATH];
      GetModuleFileNameW(NULL, exePath, MAX_PATH);

      DWORD verHandle = 0;
      UINT size = 0;
      LPBYTE lpBuffer = NULL;
      DWORD verSize = GetFileVersionInfoSizeW(exePath, &verHandle);
      if (verSize == NULL)
      {
        result->Error("VersionError", "Unable to get version size.");
        return;
      }

      std::vector<BYTE> verData(verSize);
      if (!GetFileVersionInfoW(exePath, verHandle, verSize, verData.data()))
      {
        result->Error("VersionError", "Unable to get version info.");
        return;
      }

      struct LANGANDCODEPAGE
      {
        WORD wLanguage;
        WORD wCodePage;
      } *lpTranslate;

      UINT cbTranslate = 0;
      if (!VerQueryValueW(verData.data(), L"\\VarFileInfo\\Translation",
                          (LPVOID *)&lpTranslate, &cbTranslate) ||
          cbTranslate < sizeof(LANGANDCODEPAGE))
      {
        result->Error("VersionError", "Unable to get translation info.");
        return;
      }

      wchar_t subBlock[50];
      swprintf(subBlock, 50, L"\\StringFileInfo\\%04x%04x\\ProductVersion",
               lpTranslate[0].wLanguage, lpTranslate[0].wCodePage);

      if (!VerQueryValueW(verData.data(), subBlock, (LPVOID *)&lpBuffer, &size))
      {
        result->Error("VersionError", "Unable to query version value.");
        return;
      }

      std::wstring productVersion((wchar_t *)lpBuffer);
      size_t plusPos = productVersion.find(L'+');
      if (plusPos != std::wstring::npos && plusPos + 1 < productVersion.length())
      {
        std::wstring buildNumber = productVersion.substr(plusPos + 1);
        buildNumber.erase(buildNumber.find_last_not_of(L' ') + 1);
        result->Success(flutter::EncodableValue(wideToUtf8(buildNumber)));
      }
      else
      {
        result->Error("VersionError", "Invalid version format.");
      }
    }
    else
    {
      result->NotImplemented();
    }
  }

} // namespace desktop_updater
