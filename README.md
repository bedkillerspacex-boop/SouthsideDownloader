# SouthSideDownloader

南侧下载器是一个 Windows 上的一键安装工具，用来自动下载并整理 Minecraft `1.21.4`、Fabric、依赖库、资源文件和内置模组。

## 功能

- 自动下载 Minecraft 客户端、依赖库、资源文件和 Fabric 依赖。
- 默认安装版本名为 `SouthsideNextgen`。
- 优先使用国内镜像源，必要时自动与官方源竞速下载。
- 支持断点续传、失败重试、无进度自动重连。
- 支持多线程下载，默认 `16` 线程，最高限制 `64`。
- 自动写入启动器配置，并释放内置 PCL2 启动器与桌面快捷方式。
- 重复运行会尽量复用缓存，减少校验、解压和重复写入。

## 使用

双击运行：

```bat
SouthSideDownloader.bat
```

命令行运行：

```bat
SouthSideDownloader.bat -MinecraftDir D:\Games\.minecraft
SouthSideDownloader.bat -MaxThreads 32
SouthSideDownloader.bat -RetryCount 3
SouthSideDownloader.bat -NoProgressTimeoutSeconds 15
SouthSideDownloader.bat -HedgeAfterSeconds 5
SouthSideDownloader.bat -FabricLoaderVersion 0.16.14
```

## 参数

- `-MinecraftDir`：指定 `.minecraft` 目录，传入后不再弹窗选择路径。
- `-FabricLoaderVersion`：指定 Fabric Loader 版本，默认使用可用的最新稳定版本。
- `-InstallVersionName`：指定安装后的版本名，默认 `SouthsideNextgen`。
- `-ProfileName`：指定启动器配置名称，默认 `SouthsideNextgen`。
- `-MaxThreads`：下载线程数，默认 `16`。
- `-RetryCount`：单文件失败后的重试次数，默认 `3`。
- `-NoProgressTimeoutSeconds`：连接无进度多少秒后自动重连，默认 `15`。
- `-HedgeAfterSeconds`：下载超过多少秒后启用备用源竞速，默认 `5`。
- `-NoLauncherProfile`：不写入启动器配置。
- `-SkipAssets`：跳过资源文件下载。
- `-Help`：显示帮助。

## 说明

- 本工具只负责下载和整理游戏文件，不负责账号登录。
- Minecraft `1.21.4` 需要 Java 21。
- 大文件使用 Git LFS 管理，克隆后请确保已安装并启用 Git LFS。
