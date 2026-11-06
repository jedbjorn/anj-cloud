#ifndef RUNNER_DESKTOP_INTEGRATION_H_
#define RUNNER_DESKTOP_INTEGRATION_H_

// The Windows desktop session in the runner (spec #32 W3): the window,
// tray and activation channels the Dart WindowsDesktopSession uses, and
// session end. Channels:
//
//   cloud.anj/window  Dart -> runner: show, hide, allowForeground,
//                     activateExisting {profile}, claimActivation {profile}
//                     runner -> Dart: activate, endSession
//   cloud.anj/tray    Dart -> runner: start {tooltip}, setState {status,
//                     paused}, close
//                     runner -> Dart: open, togglePause, quit, hostChanged
#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <optional>
#include <string>
#include <vector>

class DesktopIntegration {
 public:
  DesktopIntegration(flutter::FlutterEngine* engine, HWND window);
  ~DesktopIntegration();

  // Window messages the runner handles before Flutter does; a value means
  // the message was handled.
  std::optional<LRESULT> HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam);

  // Tray menu command ids (also accepted as WM_COMMAND, the seat's test
  // hook for the menu).
  static constexpr UINT kCommandOpen = 1001;
  static constexpr UINT kCommandTogglePause = 1002;
  static constexpr UINT kCommandQuit = 1003;

 private:
  using Channel = flutter::MethodChannel<flutter::EncodableValue>;
  void HandleWindowCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleTrayCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  bool AddTrayIcon();
  void RemoveTrayIcon();
  void ShowTrayMenu();
  void SendTrayEvent(const char* method, bool value = false, bool has_value = false);
  void ShowWindowForeground();
  void EndSession();

  HWND window_;
  std::unique_ptr<Channel> window_channel_;
  std::unique_ptr<Channel> tray_channel_;
  UINT taskbar_created_ = 0;
  bool tray_wanted_ = false;
  bool tray_added_ = false;
  bool paused_ = false;
  std::wstring tooltip_ = L"AnJ Cloud";
  std::wstring status_ = L"AnJ Cloud";
  HICON icon_ = nullptr;
  HANDLE pipe_ = nullptr;
};

// Startup checks used by wWinMain.
bool ProcessIsElevated();
// Elevated with no linked filtered token (TokenElevationTypeDefault): UAC is
// off or this is the built-in Administrator, so every start is elevated.
bool ElevationIsPermanent();
bool HasArgument(const std::vector<std::string>& arguments, const char* name);

#endif  // RUNNER_DESKTOP_INTEGRATION_H_
