#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <filesystem>
#include <string>
#include <vector>

// GUI-subsystem host. CREATE_NO_WINDOW prevents the PowerShell child from
// owning a terminal; waiting preserves Task Scheduler lifetime supervision.
int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    std::vector<wchar_t> path(32768);
    DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (!length || length >= path.size()) return 1;
    auto directory = std::filesystem::path(std::wstring(path.data(), length)).parent_path();
    int count = 0;
    auto arguments = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!arguments) return 1;
    bool monitor = count == 2 && std::wstring(arguments[1]) == L"--monitor";
    bool checkUi = count == 2 && std::wstring(arguments[1]) == L"--check-ui";
    bool hidden = count == 2 && std::wstring(arguments[1]) == L"--tray";
    bool valid = count == 1 || monitor || checkUi || hidden;
    LocalFree(arguments);
    if (!valid) return 2;
    auto script = directory / (monitor ? L"Monitor.ps1" : L"Setup.ps1");
    if (!std::filesystem::is_regular_file(script)) {
        if (!monitor) MessageBoxW(nullptr, L"请先解压完整文件夹，再打开 CampusConnect.exe。", L"校园网自动连接", MB_OK | MB_ICONERROR);
        return 1;
    }
    wchar_t system[32768];
    UINT systemLength = GetSystemDirectoryW(system, 32768);
    if (!systemLength || systemLength >= 32768) return 1;
    auto powershell = std::filesystem::path(system) / L"WindowsPowerShell" / L"v1.0" / L"powershell.exe";
    std::wstring command = L"\"" + powershell.wstring() + L"\" -NoLogo -NoProfile -STA -NonInteractive -ExecutionPolicy Bypass -File \"" + script.wstring() + L"\"";
    if (checkUi) command += L" -CheckUi";
    if (hidden) command += L" -StartHidden";
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    HANDLE job = CreateJobObjectW(nullptr, nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
        if (job) CloseHandle(job);
        return 1;
    }
    if (!CreateProcessW(powershell.c_str(), command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW | CREATE_SUSPENDED,
                        nullptr, directory.c_str(), &startup, &process)) {
        CloseHandle(job);
        if (!monitor) MessageBoxW(nullptr, L"无法启动设置界面，请确认 Windows PowerShell 可用。", L"校园网自动连接", MB_OK | MB_ICONERROR);
        return 1;
    }
    if (!AssignProcessToJobObject(job, process.hProcess) || ResumeThread(process.hThread) == static_cast<DWORD>(-1)) {
        TerminateProcess(process.hProcess, 1);
        CloseHandle(process.hThread); CloseHandle(process.hProcess); CloseHandle(job);
        return 1;
    }
    CloseHandle(process.hThread);
    DWORD wait = WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exitCode = 1;
    if (wait == WAIT_OBJECT_0) GetExitCodeProcess(process.hProcess, &exitCode);
    CloseHandle(process.hProcess);
    CloseHandle(job);
    if (exitCode && !monitor) MessageBoxW(nullptr, L"设置界面启动失败，请检查文件是否完整。", L"校园网自动连接", MB_OK | MB_ICONERROR);
    return static_cast<int>(exitCode);
}
