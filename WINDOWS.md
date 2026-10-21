# Windows 11 迁移说明

Windows 电脑接替 Mac 运行 Twitch 服务，Roku 的功能和操作保持不变。Windows 电脑需要和 Roku 在同一家庭网络内。看电视时电脑必须保持运行，显示器可以关闭，但电脑不能休眠。

以下安装步骤用于常见的 Intel/AMD 64 位 Windows 11 电脑。ARM 机型需要另行确认 FFmpeg 和 Python 依赖的兼容性。这份包已检查文件与配置生成流程，并通过中文数据读写检查，尚未在 Windows 真机上安装或播放。

## 1. 解压程序

从 GitHub 仓库选择 **Code → Download ZIP**，在 Windows 电脑完整解压；也可使用单独提供的 Windows 运行包。将项目文件夹放到当前用户的本地目录，例如 `%LOCALAPPDATA%\RokuTwitch\roku-twitch`。可以把 `%LOCALAPPDATA%` 输入资源管理器地址栏来打开该位置。

不要直接在 ZIP 内运行脚本，也不要复制 Mac 的 `.venv`、`node_modules` 或 `data/streams` 文件夹。Windows 包不含登录凭据、观看记录、Python 或 FFmpeg。

## 2. 安装 Python 和 FFmpeg

打开 Windows 终端，依次运行以下两行，按安装器提示完成安装：

```powershell
winget install --exact --id Python.Python.3.12 --source winget
winget install --exact --id Gyan.FFmpeg --source winget
```

安装完成后关闭终端，再打开新终端，检查：

```powershell
py -3.12 --version
ffmpeg -version
```

两条都能显示版本后，双击项目文件夹内的 `1-install-windows.cmd`。它会建立 Windows 专用 Python 环境，并安装项目固定版本的依赖。出现 `Installation complete` 后可以关闭窗口。

若系统没有 `winget`，可以从 [Python Windows 下载页](https://www.python.org/downloads/windows/) 安装 Python 3.12，并从 [FFmpeg 官方下载页](https://ffmpeg.org/download.html) 链接的 Windows 构建下载 FFmpeg。手动安装时，将包含 `ffmpeg.exe` 的 `bin` 文件夹加入用户 PATH，然后重新打开终端检查。

Streamlink 通过项目的 Python 环境安装，不需要另装 Streamlink 独立版。[Streamlink Windows 安装说明](https://streamlink.github.io/install.html#windows)

## 3. 正式切换前迁移数据

以下步骤用于迁移现有安装。如果是全新安装，在项目目录运行 `.\.venv\Scripts\python.exe -m server.setup configure`，并按 [README 的首次配置说明](README.md#首次配置) 设置 Twitch Client ID、登录和播放凭据；不需要复制旧数据或运行第 4 步的迁移脚本。配置后从第 5 步继续。

这一步会短暂中断电视播放。先在 Roku 正常退出正在播放的视频，让进度保存，再停止 Mac 上的 Twitch 服务。停止服务即可，不要在 Twitch 应用里退出账号。

从原电脑项目的 `data` 文件夹复制以下文件，到 Windows 项目文件夹的 `data` 子文件夹。没有 `data` 文件夹时先创建它。

| 文件 | 内容 |
| --- | --- |
| `settings.json` | Twitch 应用设置和 Roku 配对密钥 |
| `account.json` | 账号登录和刷新凭据 |
| `playback.json` | 网页播放凭据 |
| `history.json` | 观看进度 |
| `favorites.json` | 收藏置顶 |
| `quality.json` | 清晰度偏好 |

后三个文件不存在时可以跳过。保留原文件内容，不需要打开或编辑。文件含登录信息，只在自己的设备之间复制，不要粘贴到聊天中。

不要复制 `streams`、`streamlink.conf` 或 Mac 的 `roku/config.json`。临时播放文件会重新生成，Roku 地址也会在下一步重新设置。不要同时启动两台电脑上的服务，以免同一份登录凭据被两边分别刷新。完成切换后，后续进度只会保存在 Windows 电脑上，不会自动同步回 Mac。

## 4. 生成新的 Roku 安装包

在 Windows 的“设置 → 网络和 Internet”里打开当前家庭 Wi-Fi 或以太网连接属性，找到 IPv4 地址。也可以运行 `ipconfig`，读取正在连接家庭路由器的网卡地址。不要使用 VPN、虚拟机网卡地址或 `127.0.0.1`。

双击 `2-configure-windows.cmd`：

1. 第一个问题是 Twitch Client ID，直接按 Enter，保留迁移来的值。
2. 第二个问题填写 `http://Windows电脑的IPv4地址:58787`。例如地址是 `192.168.1.100`，就填写 `http://192.168.1.100:58787`。这里的 IP 仅是示例。
3. 成功后生成 `dist\roku-twitch.zip`，稍后上传到 Roku。

这个步骤会保留配对密钥，不会修改迁移来的账号、收藏和观看进度。以后 Windows IP 改变时，可以重新运行这个脚本，再安装新生成的 Roku ZIP。

## 5. 允许家庭网络连接

确认 Windows 当前家庭网络的配置文件为“专用网络”。然后以管理员身份打开 PowerShell，执行以下规则，只允许同一子网访问本服务的 TCP 58787 端口：

```powershell
New-NetFirewallRule -Name "PersonalTwitch58787" -DisplayName "Personal Twitch LAN 58787" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 58787 -RemoteAddress LocalSubnet -Profile Private
```

规则只需添加一次。不需要关闭 Windows 防火墙，也不需要设置路由器的公网端口转发。若机器由单位管理且不能修改规则，需要使用获准的网络设置。

若以后不再使用此服务，可在管理员 PowerShell 中删除这条规则：

```powershell
Remove-NetFirewallRule -Name "PersonalTwitch58787"
```

参见 [Microsoft Windows 防火墙说明](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/configure-with-command-line)。

## 6. 启动并验证

1. 双击 `3-start-windows.cmd`。保留窗口，不要重复启动第二份服务。按 Ctrl+C 可以停止。
2. 在 Windows 浏览器打开 `http://127.0.0.1:58787/health`，应显示 `{"state":"ok"}`。
3. 用同一 Wi-Fi 的手机打开 `http://Windows电脑的IPv4地址:58787/health`，也应显示相同结果。本机可打开、手机打不开时，检查专用网络配置、防火墙规则和路由器的访客网络隔离。
4. 打开 Roku 的开发者安装页面，将第 4 步生成的 `dist\roku-twitch.zip` 直接上传，不用解压。不要上传整个 Windows 程序包，也不要使用旧的 Mac 地址安装包。
5. 在电视设置里检查服务器地址。确认账号状态、关注与收藏，再分别播放一条直播和一条 VOD，检查暂停、续播和清晰度切换。

凭据仍有效时，无需重新登录。若电视提示账号登录过期，重新走验证码登录。若只有播放凭据失效，在项目目录打开终端并运行：

```powershell
.\.venv\Scripts\python.exe -m server.setup import-playback
```

按隐藏输入提示导入本人的有效播放凭据。不要将凭据直接写进命令或发到聊天中。

本版使用可见窗口启动。先确认稳定运行，再配置登录后自动启动。将 Windows 的接通电源休眠时间设为“从不”后，关闭显示器仍可播放。笔记本合盖也可能休眠，需要检查自己的电源设置。

## 回到 Mac

先停止 Windows 服务。若 Windows 已刷新登录或产生新观看记录，把上述六个数据文件复制回 Mac，再启动 Mac 服务，并重新安装保留的 Mac 地址 Roku ZIP。不要用过期的 Mac 数据覆盖 Windows 上的新记录。
