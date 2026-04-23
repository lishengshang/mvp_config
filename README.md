# MPV-Config: 个人播放器体验配置

本项目是一套高度定制化的 [mpv](https://github.com/mpv-player/mpv) 播放器配置文件，旨在为 Windows 用户提供开箱即用的、高性能且功能丰富的视频播放体验。

## 功能亮点

- **画质增强**：集成多种高级着色器（Shaders），如 FSRCNNX, SSimSuperRes 等，提升低分辨率视频观感。
- **UI/UX 优化**：使用 `uosc` 现代界面，提供流畅的操作反馈和精美的视觉设计。
- **自动化脚本**：
  - **自动加载字幕**：智能匹配本地及在线字幕。
  - **语音转字幕**：集成 Fast-Whisper，支持一键生成视频字幕。
  - **弹幕支持**：支持加载 Bilibili 等平台的弹幕。
  - **智能跳过**：自动跳过片头片尾（基于章节或配置）。
- **便携式设计**：完美适配 `portable_config` 模式，解压即用，不留系统垃圾。

## 目录结构

```text
portable_config/
├── scripts/            # 功能脚本 (.lua, .js)
├── script-opts/        # 脚本配置文件
├── shaders/            # 视频增强着色器
├── fonts/              # 必备界面字体
├── mpv.conf            # 核心配置文件
└── input.conf          # 热键配置文件
```

## 快速开始

1. **下载 mpv**：推荐使用 [shinchiro](https://github.com/shinchiro/mpv-winbuild-cmake/releases) 或 [zhongfly](https://github.com/zhongfly/mpv-winbuild) 的每日构建版。
2. **安装配置**：
   - 将本项目的所有文件放入 `mpv.exe` 所在的 `portable_config` 目录下。
3. **字体安装**：建议安装 `fonts/` 目录下的所有字体文件，以确保 UI 正常显示。
4. **运行**：直接打开 `mpv.exe` 即可享受。

## 配置说明

### API 密钥设置
为了安全起见，部分涉及在线服务的配置文件提供了示例模板。请手动配置：
- **Fast-Whisper 翻译**：重命名 `script-opts/sub_fastwhisper.conf.example` 为 `sub_fastwhisper.conf` 并填入你的 API Key。
- **射手网字幕下载**：重命名 `script-opts/sub_assrt.conf.example` 为 `sub_assrt.conf` 并填入你的 Token。

### 常用快捷键
| 按键 | 功能 |
| :--- | :--- |
| `Space` | 暂停 / 播放 |
| `Enter` | 全屏切换 |
| `Ctrl+v` | 剪贴板播放 |
| `Alt+f` | 开启 Fast-Whisper 语音转字幕 |
| `i` | 显示统计信息 |

## 参考与致谢

本项目基于 [lishengshang/mpv-config](https://github.com/lishengshang/mpv-config) 进行二次开发与深度定制，特此鸣谢。

- [lishengshang/mpv-config](https://github.com/lishengshang/mpv-config) - 本配置的原始基础项目。
- [hooke007/mpv-lazy](https://github.com/hooke007/mpv-lazy) - 优秀的中文配置参考。
- [mpv-player/mpv](https://github.com/mpv-player/mpv) - 核心引擎。
- 感谢所有开源脚本作者的贡献。

## 开源协议

本项目基于 [MIT License](LICENSE.MD) 协议开源。
