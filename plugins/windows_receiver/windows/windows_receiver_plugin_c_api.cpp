#include "include/windows_receiver/windows_receiver_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "windows_receiver_plugin.h"

void WindowsReceiverPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  windows_receiver::WindowsReceiverPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
