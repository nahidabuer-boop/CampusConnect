# CampusConnect 校园网自动连接

连接校园网后，填写学校的认证链接和账号密码，CampusConnect 会在后台检查认证状态，并在掉线后尝试重新登录。

## 按系统下载

| 系统 | 下载 | 启动方式 |
| --- | --- | --- |
| Windows | [Windows ZIP](https://github.com/nahidabuer-boop/CampusConnect/releases/download/v0.2.1/CampusConnect-v0.2.1-Windows.zip) | 解压后双击 `CampusConnect.cmd` |
| macOS | [macOS ZIP](https://github.com/nahidabuer-boop/CampusConnect/releases/download/v0.2.1/CampusConnect-v0.2.1-macOS.zip) | 安装 Python 后双击 `CampusConnect.command` |
| Linux 桌面 | [Linux ZIP](https://github.com/nahidabuer-boop/CampusConnect/releases/download/v0.2.1/CampusConnect-v0.2.1-Linux.zip) | 安装依赖后在解压目录执行 `bash start.sh` |

macOS 和 Linux 版需要 Python 3.10 或更新版本、Tkinter 和系统钥匙串，首次安装需要联网。见 [macOS / Linux 安装说明](unix/README.md)。Windows 版使用系统自带的 Windows PowerShell。各版本可在 [Releases](https://github.com/nahidabuer-boop/CampusConnect/releases) 找到。

## 使用方法

1. 下载并解压对应系统的压缩包，按上表启动。
2. 填写学校实际弹出的认证链接、校园网账号和密码。链接需要保留 `ac_id` 参数。
3. 点击「保存并启用自启」。关闭窗口后，程序继续在后台运行。

认证链接格式示例：`https://portal.example.edu/srun_portal_pc?ac_id=20&theme=basic`。请使用学校实际给出的链接。

后台每 10 秒检查一次认证状态，连续两次收到明确的未认证状态后才尝试登录。自启发生在当前用户登录系统之后。需要暂停时，点击「停止并关闭自启」。

普通登录失败在请求结束后约 15 秒重试；学校返回疑似账号密码错误时，等待 15 分钟重试。界面显示剩余等待时间。修改凭据后请点击「保存并启用自启」，后台会使用新凭据重新检查并清除原来的等待时间。

更新已有安装时，请先用旧版点击「停止并关闭自启」，退出旧设置窗口，再从新版包打开设置并保存。后台目录中的 `monitor.log` 记录状态变化和过滤后的结果码，不记录账号密码。配置密码保持不变时，单独关闭窗口不会停止后台。

## 兼容范围

- 支持使用兼容的深澜 SRun 网页账号密码认证，并提供可验证 HTTPS 接口的学校。短信、扫码、统一身份认证跳转和仅支持 HTTP 的登录暂不支持。
- 需要先连上学校的 Wi-Fi 或有线网络。学校的登录入口和认证配置可能不同。

## 凭据与运行状态

Windows 使用当前用户加密保存密码。macOS 使用钥匙串，Linux 使用 Secret Service 密码库。账号名和认证地址保存在本机配置中。登录凭据只提交到配置地址对应的 HTTPS 认证接口。提交问题时请勿上传本机配置、账号或密码。

## 验证情况

Windows 分享版已在北京化工大学校园网上实测自动重连。macOS 和 Linux 为预览版，已验证协议和模拟掉线流程，仍需在对应系统上实测界面、系统钥匙串、自启及真实掉线重连。其他学校的兼容性待实测。
