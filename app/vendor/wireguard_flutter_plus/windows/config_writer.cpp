#include <windows.h>

#include <codecvt>
#include <stdexcept>
#include <string>

#include "utils.h"

namespace wireguard_flutter
{

  std::wstring WriteConfigToTempFile(std::string config, std::string service_name)
  {
    WCHAR temp_path[MAX_PATH];
    DWORD temp_path_len = GetTempPath(MAX_PATH, temp_path);
    if (temp_path_len > MAX_PATH || temp_path_len == 0)
    {
      throw std::runtime_error("could not get temporary dir: " + std::to_string(GetLastError()));
    }

    std::wstring temp_filename_str;

    if (service_name.empty()) {
        WCHAR temp_filename[MAX_PATH];
        UINT temp_filename_result = GetTempFileName(temp_path, L"wg_conf", 0, temp_filename);
        if (temp_filename_result == 0)
        {
          throw std::runtime_error("could not get temporary file name: " + std::to_string(GetLastError()));
        }
        temp_filename_str = temp_filename;
    } else {
        std::wstring service_name_wide = Utf8ToWide(service_name);
        temp_filename_str = std::wstring(temp_path) + service_name_wide;
    }

    // Ensure it ends with .conf
    // GetTempFileName might create a file with .tmp extension. We want .conf
    // If we used service_name, we append .conf
    // If we used GetTempFileName, it appends .tmp. We need to rename or just append .conf

    // For safety and simplicity, let's just append .conf. 
    // If it was .tmp, it becomes .tmp.conf, which is fine as long as we use that name.
    // BUT wireguard.exe might expect [InterfaceName].conf

    // If service_name is provided, we want [temp_path]\[service_name].conf
    if (!service_name.empty()) {
        temp_filename_str += L".conf";
    } else {
        // existing logic appended .conf to the temp filename
        temp_filename_str += L".conf";
    }
    
    HANDLE temp_file = CreateFile(temp_filename_str.c_str(), GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (temp_file == INVALID_HANDLE_VALUE)
    {
      throw std::runtime_error("unable to create temporary file: " + std::to_string(GetLastError()));
    }

    DWORD bytes_written;
    if (!WriteFile(temp_file, config.c_str(), static_cast<DWORD>(config.length()), &bytes_written, NULL))
    {
      CloseHandle(temp_file);
      throw std::runtime_error("could not write temporary config file:" + std::to_string(GetLastError()));
    }

    if (!CloseHandle(temp_file))
    {
      throw std::runtime_error("unable to close temporary file:" + std::to_string(GetLastError()));
    }
    return temp_filename_str;
  }

}
