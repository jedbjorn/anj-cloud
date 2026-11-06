#include "desktop_integration.h"

#include <bcrypt.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <sddl.h>
#include <shellapi.h>

#include <cstdio>
#include <thread>

#include "resource.h"

namespace {

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kActivateMessage = WM_APP + 2;
constexpr UINT kExitMessage = WM_APP + 3;
constexpr UINT kTrayId = 1;
constexpr UINT kCommandStatus = 1000;

std::wstring Wide(const std::string& text) {
  if (text.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring out(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), &out[0], n);
  return out;
}

const std::string* StringArgument(const flutter::EncodableValue* arguments, const char* key) {
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (!map) return nullptr;
  auto found = map->find(flutter::EncodableValue(std::string(key)));
  return found == map->end() ? nullptr : std::get_if<std::string>(&found->second);
}

bool BoolArgument(const flutter::EncodableValue* arguments, const char* key) {
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (!map) return false;
  auto found = map->find(flutter::EncodableValue(std::string(key)));
  const bool* value = found == map->end() ? nullptr : std::get_if<bool>(&found->second);
  return value && *value;
}

// The process user's SID as a string (S-1-5-21-...).
std::wstring UserSid() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return std::wstring();
  DWORD length = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &length);
  std::vector<unsigned char> buffer(length);
  std::wstring out;
  if (length && GetTokenInformation(token, TokenUser, buffer.data(), length, &length)) {
    wchar_t* text = nullptr;
    if (ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &text)) {
      out = text;
      LocalFree(text);
    }
  }
  CloseHandle(token);
  return out;
}

// Named pipes are machine-wide: the name carries the user SID and a hash of
// the profile path (case-folded, as Windows compares paths), and the pipe's
// DACL admits only this user.
std::wstring ActivationPipeName(const std::string& profile) {
  std::wstring path = Wide(profile);
  if (!path.empty()) CharLowerBuffW(&path[0], static_cast<DWORD>(path.size()));
  unsigned char digest[32] = {};
  if (BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0,
                 reinterpret_cast<PUCHAR>(&path[0]),
                 static_cast<ULONG>(path.size() * sizeof(wchar_t)), digest,
                 sizeof(digest)) != 0) {
    return std::wstring();
  }
  wchar_t hex[33] = {};
  for (int i = 0; i < 16; i++) swprintf(hex + i * 2, 3, L"%02x", digest[i]);
  std::wstring sid = UserSid();
  if (sid.empty()) return std::wstring();
  return L"\\\\.\\pipe\\anj-cloud-activate-" + sid + L"-" + hex;
}

// The process at the other end of [pipe] runs as this user.
bool SameUser(HANDLE pipe) {
  ULONG pid = 0;
  if (!GetNamedPipeServerProcessId(pipe, &pid)) return false;
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return false;
  HANDLE token = nullptr;
  bool same = false;
  if (OpenProcessToken(process, TOKEN_QUERY, &token)) {
    DWORD length = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &length);
    std::vector<unsigned char> buffer(length);
    if (length && GetTokenInformation(token, TokenUser, buffer.data(), length, &length)) {
      wchar_t* text = nullptr;
      if (ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &text)) {
        same = UserSid() == text;
        LocalFree(text);
      }
    }
    CloseHandle(token);
  }
  CloseHandle(process);
  if (same) AllowSetForegroundWindow(pid);
  return same;
}

// A second launch: asks the running instance to show its window.
bool ActivateExisting(const std::string& profile) {
  std::wstring name = ActivationPipeName(profile);
  if (name.empty() || !WaitNamedPipeW(name.c_str(), 3000)) return false;
  HANDLE pipe = CreateFileW(name.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                            SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
  if (pipe == INVALID_HANDLE_VALUE) return false;
  bool ok = false;
  if (SameUser(pipe)) {
    DWORD written = 0;
    ok = WriteFile(pipe, "activate", 8, &written, nullptr) && written == 8;
    FlushFileBuffers(pipe);
  }
  CloseHandle(pipe);
  return ok;
}

// The running instance: one pipe instance, created first (a squatter makes
// this fail rather than receive our launches), serving one client at a time.
HANDLE ClaimActivation(const std::string& profile, HWND window) {
  std::wstring name = ActivationPipeName(profile);
  std::wstring sid = UserSid();
  if (name.empty() || sid.empty()) return nullptr;
  std::wstring sddl = L"D:P(A;;GA;;;" + sid + L")";
  PSECURITY_DESCRIPTOR sd = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1,
                                                            &sd, nullptr)) {
    return nullptr;
  }
  SECURITY_ATTRIBUTES attributes = {sizeof(attributes), sd, FALSE};
  HANDLE pipe = CreateNamedPipeW(
      name.c_str(), PIPE_ACCESS_INBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 0, 64, 0,
      &attributes);
  LocalFree(sd);
  if (pipe == INVALID_HANDLE_VALUE) return nullptr;
  std::thread([pipe, window]() {
    while (true) {
      BOOL connected = ConnectNamedPipe(pipe, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED;
      if (!connected) {
        if (GetLastError() == ERROR_INVALID_HANDLE) return;
        // ERROR_NO_DATA and similar: a client came and went; the instance
        // must be disconnected before it can accept again.
        DisconnectNamedPipe(pipe);
        Sleep(50);
        continue;
      }
      char buffer[16] = {};
      DWORD read = 0;
      if (ReadFile(pipe, buffer, sizeof(buffer), &read, nullptr) && read == 8 &&
          memcmp(buffer, "activate", 8) == 0) {
        PostMessageW(window, kActivateMessage, 0, 0);
      }
      DisconnectNamedPipe(pipe);
    }
  }).detach();
  return pipe;
}

}  // namespace

bool ProcessIsElevated() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  TOKEN_ELEVATION elevation = {};
  DWORD length = 0;
  bool elevated = GetTokenInformation(token, TokenElevation, &elevation, sizeof(elevation),
                                      &length) &&
                  elevation.TokenIsElevated;
  CloseHandle(token);
  return elevated;
}

bool ElevationIsPermanent() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  TOKEN_ELEVATION_TYPE type = TokenElevationTypeDefault;
  DWORD length = 0;
  bool permanent = GetTokenInformation(token, TokenElevationType, &type, sizeof(type), &length) &&
                   type == TokenElevationTypeDefault;
  CloseHandle(token);
  return permanent;
}

bool HasArgument(const std::vector<std::string>& arguments, const char* name) {
  for (const auto& argument : arguments) {
    if (argument == name) return true;
  }
  return false;
}

DesktopIntegration::DesktopIntegration(flutter::FlutterEngine* engine, HWND window)
    : window_(window) {
  const auto& codec = flutter::StandardMethodCodec::GetInstance();
  window_channel_ = std::make_unique<Channel>(engine->messenger(), "cloud.anj/window", &codec);
  tray_channel_ = std::make_unique<Channel>(engine->messenger(), "cloud.anj/tray", &codec);
  window_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleWindowCall(call, std::move(result));
  });
  tray_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleTrayCall(call, std::move(result));
  });
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  icon_ = static_cast<HICON>(LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON),
                                        IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                                        GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR));
}

DesktopIntegration::~DesktopIntegration() {
  RemoveTrayIcon();
  if (icon_) DestroyIcon(icon_);
  window_channel_->SetMethodCallHandler(nullptr);
  tray_channel_->SetMethodCallHandler(nullptr);
}

void DesktopIntegration::ShowWindowForeground() {
  ShowWindow(window_, IsIconic(window_) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window_);
}

void DesktopIntegration::HandleWindowCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "show") {
    ShowWindowForeground();
    result->Success();
  } else if (method == "hide") {
    ShowWindow(window_, SW_HIDE);
    result->Success();
  } else if (method == "activateExisting") {
    const std::string* profile = StringArgument(call.arguments(), "profile");
    result->Success(flutter::EncodableValue(profile && ActivateExisting(*profile)));
  } else if (method == "claimActivation") {
    const std::string* profile = StringArgument(call.arguments(), "profile");
    if (!pipe_ && profile) pipe_ = ClaimActivation(*profile, window_);
    result->Success(flutter::EncodableValue(pipe_ != nullptr));
  } else {
    result->NotImplemented();
  }
}

bool DesktopIntegration::AddTrayIcon() {
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kTrayId;
  data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = icon_;
  wcsncpy_s(data.szTip, tooltip_.c_str(), _TRUNCATE);
  // An icon left by a crashed earlier run of this window is replaced.
  Shell_NotifyIconW(NIM_DELETE, &data);
  if (!Shell_NotifyIconW(NIM_ADD, &data)) return false;
  data.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &data);
  return true;
}

void DesktopIntegration::RemoveTrayIcon() {
  if (!tray_added_) return;
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kTrayId;
  Shell_NotifyIconW(NIM_DELETE, &data);
  tray_added_ = false;
}

void DesktopIntegration::HandleTrayCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "start") {
    if (const std::string* tip = StringArgument(call.arguments(), "tooltip")) tooltip_ = Wide(*tip);
    tray_wanted_ = true;
    tray_added_ = AddTrayIcon();
    fwprintf(stderr, L"anj-cloud: tray icon %s\n", tray_added_ ? L"added" : L"not added yet");
    fflush(stderr);
    result->Success(flutter::EncodableValue(tray_added_));
  } else if (method == "setState") {
    if (const std::string* status = StringArgument(call.arguments(), "status")) {
      status_ = Wide(*status);
      tooltip_ = status_;
    }
    paused_ = BoolArgument(call.arguments(), "paused");
    if (tray_added_) {
      NOTIFYICONDATAW data = {};
      data.cbSize = sizeof(data);
      data.hWnd = window_;
      data.uID = kTrayId;
      data.uFlags = NIF_TIP | NIF_SHOWTIP;
      wcsncpy_s(data.szTip, tooltip_.c_str(), _TRUNCATE);
      Shell_NotifyIconW(NIM_MODIFY, &data);
    }
    result->Success();
  } else if (method == "close") {
    tray_wanted_ = false;
    RemoveTrayIcon();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void DesktopIntegration::SendTrayEvent(const char* method, bool value, bool has_value) {
  tray_channel_->InvokeMethod(
      method, has_value ? std::make_unique<flutter::EncodableValue>(value) : nullptr);
}

// The same menu as Linux: status, Open, Pause/Resume, Quit.
void DesktopIntegration::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING | MF_GRAYED, kCommandStatus, status_.c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kCommandOpen, L"Open AnJ Cloud");
  AppendMenuW(menu, MF_STRING, kCommandTogglePause, paused_ ? L"Resume sync" : L"Pause sync");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kCommandQuit, L"Quit AnJ Cloud");
  POINT point = {};
  GetCursorPos(&point);
  // Documented requirement for a notification-area menu to close properly.
  SetForegroundWindow(window_);
  UINT command = TrackPopupMenuEx(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY, point.x,
                                  point.y, window_, nullptr);
  PostMessageW(window_, WM_NULL, 0, 0);
  DestroyMenu(menu);
  if (command) PostMessageW(window_, WM_COMMAND, command, 0);
}

// Logoff or shutdown: Dart stops sync and closes the tray before this
// returns, because Windows ends the process right after WM_ENDSESSION. The
// lock file handle is closed by the kernel with the process. Windows shows
// the block reason while this waits (at most 15 s).
void DesktopIntegration::EndSession() {
  ShutdownBlockReasonCreate(window_, L"AnJ Cloud is stopping sync");
  auto done = std::make_shared<bool>(false);
  window_channel_->InvokeMethod(
      "endSession", nullptr,
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [done](const flutter::EncodableValue*) { *done = true; },
          [done](const std::string&, const std::string&, const flutter::EncodableValue*) {
            *done = true;
          },
          [done]() { *done = true; }));
  ULONGLONG deadline = GetTickCount64() + 15000;
  while (!*done && GetTickCount64() < deadline) {
    MsgWaitForMultipleObjects(0, nullptr, FALSE, 50, QS_ALLINPUT);
    MSG message;
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      if (message.message == WM_QUIT) {
        PostQuitMessage(static_cast<int>(message.wParam));
        *done = true;
        break;
      }
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
  }
  fwprintf(stderr, L"anj-cloud: session end: sync %s\n", *done ? L"stopped" : L"stop timed out");
  fflush(stderr);
  RemoveTrayIcon();
  ShutdownBlockReasonDestroy(window_);
}

std::optional<LRESULT> DesktopIntegration::HandleMessage(HWND, UINT message, WPARAM wparam,
                                                         LPARAM lparam) {
  if (taskbar_created_ && message == taskbar_created_) {
    // Explorer restarted: the notification area is new and empty.
    tray_added_ = false;
    if (tray_wanted_) {
      tray_added_ = AddTrayIcon();
      fwprintf(stderr, L"anj-cloud: tray %s after Explorer restart\n",
               tray_added_ ? L"re-added" : L"unavailable");
      fflush(stderr);
      SendTrayEvent("hostChanged", tray_added_, true);
    }
    return 0;
  }
  switch (message) {
    case kTrayMessage:
      switch (LOWORD(lparam)) {
        case WM_CONTEXTMENU:
        case WM_RBUTTONUP:
          ShowTrayMenu();
          break;
        case NIN_SELECT:
        case NIN_KEYSELECT:
        case WM_LBUTTONDBLCLK:
          SendTrayEvent("open");
          break;
      }
      return 0;
    case kActivateMessage:
      window_channel_->InvokeMethod("activate", nullptr);
      return 0;
    case WM_COMMAND:
      switch (LOWORD(wparam)) {
        case kCommandOpen:
          SendTrayEvent("open");
          return 0;
        case kCommandTogglePause:
          SendTrayEvent("togglePause");
          return 0;
        case kCommandQuit:
          SendTrayEvent("quit");
          return 0;
      }
      break;
    case WM_QUERYENDSESSION:
      // Nothing stops here: another application may still veto the end.
      return TRUE;
    case WM_ENDSESSION:
      // FALSE: the shutdown or logoff was cancelled after the query; the
      // client simply carries on (nothing was stopped).
      if (wparam) {
        EndSession();
        // Logoff and shutdown end the process after this returns, but
        // Restart Manager (ENDSESSION_CLOSEAPP) and a shutdown cancelled at
        // the blocking screen do not: the client, with sync stopped, ends
        // itself, and the kernel releases the profile lock.
        PostMessageW(window_, kExitMessage, 0, 0);
      }
      return 0;
    case kExitMessage:
      DestroyWindow(window_);
      return 0;
  }
  return std::nullopt;
}
