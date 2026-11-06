#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdio>

#include "desktop_integration.h"
#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  // Runs unelevated (spec #32): an elevated client would create files owned
  // by Administrators (breaking the "owned" checks) and could write where
  // the user cannot. It refuses and says why; ANJ_ELEVATION_NO_DIALOG skips
  // the dialog (seat checks), leaving the message and exit code 77.
  if (ProcessIsElevated()) {
    // An account without a filtered token (User Account Control off, or the
    // built-in Administrator) is always elevated: say so, since starting it
    // differently cannot help.
    const wchar_t* reason =
        ElevationIsPermanent()
            ? L"AnJ Cloud must run as a normal Windows user, but this account always runs "
              L"programs as administrator (User Account Control is off, or it is the "
              L"built-in Administrator account). Sign in with a standard account to use "
              L"AnJ Cloud."
            : L"AnJ Cloud must run as your normal Windows user, not as administrator. "
              L"Start it again without \"Run as administrator\".";
    fwprintf(stderr, L"anj-cloud: %s\n", reason);
    fflush(stderr);
    wchar_t skip[8] = {};
    if (!GetEnvironmentVariableW(L"ANJ_ELEVATION_NO_DIALOG", skip, 8)) {
      MessageBoxW(nullptr, reason, L"AnJ Cloud", MB_OK | MB_ICONWARNING);
    }
    return 77;
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  bool background = HasArgument(command_line_arguments, "--background");
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, background);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"AnJ Cloud", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
