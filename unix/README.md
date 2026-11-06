# CampusConnect macOS / Linux 预览版

两种系统使用同一个图形界面和 SRun 认证逻辑。第一次安装请在可上网时操作，启动脚本会下载钥匙串依赖。脚本在当前用户目录内安装，不需要以管理员身份运行。

## macOS

1. 安装 [python.org 的 macOS Python](https://www.python.org/downloads/macos/)，需要 3.10 或更新版本，建议使用 universal2 安装包。如果安装器提供 `Install Certificates.command`，运行它以配置 Python 的 HTTPS 证书。
2. 解压 ZIP，双击 `CampusConnect.command`。也可以在解压目录的终端执行 `bash start.sh`。
3. 首次保存密码或后台读取密码时，若 macOS 钥匙串弹出授权提示，请核对是本工具使用的 Python 进程再允许。后台使用当前用户的 LaunchAgent，在登录 macOS 后启动。

## Linux

需要图形桌面、Python 3.10 或更新版本、Tkinter、venv，以及可用且已解锁的 Secret Service 密码库，例如 GNOME Keyring。在 Ubuntu / Debian 桌面，缺少依赖时可安装：

```sh
sudo apt install python3 python3-tk python3-venv gnome-keyring
```

在解压目录打开终端并执行 `bash start.sh`。保存后使用桌面环境的 XDG Autostart 在用户登录时启动。此版面向桌面用户，无图形桌面的服务器不在支持范围内。

## 连接校园网

1. 先接入校园 Wi-Fi 或有线网络。
2. 填入学校实际弹出的认证链接（包含 `ac_id`）、校园网账号和密码。
3. 点击「保存并启用自启」。等窗口显示认证状态后，可以关闭设置窗口。

程序每 10 秒检查一次。连续两次明确收到未认证状态后，才通过 HTTPS 尝试登录。密码保存在系统钥匙串中。要停用时，再打开界面点击「停止并关闭自启」。

目前兼容部分深澜 SRun 账号密码认证。需要可信 HTTPS 接口。短信、扫码或统一身份认证跳转暂未支持。

本版本尚未在真实 macOS / Linux 桌面上验证启动、钥匙串弹窗、自启和实际掉线重连，欢迎反馈系统版本和桌面环境。请勿上传密码、本机配置或含个人账号的截图。
