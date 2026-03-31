# VoiceStreamInput

一个 macOS 菜单栏语音输入应用。

长按录音键开始录音，松开后把转录文本注入当前聚焦输入框。默认录音键是 `Right Command`，默认识别语言是 `简体中文`。

## 功能

- 菜单栏常驻，`LSUIElement` 模式运行，无 Dock 图标
- 长按 `Right Command` 录音，支持切换为 `Fn`
- 基于 Apple Speech 的流式转录
- 默认 `zh-CN`，支持：
  - `English`
  - `简体中文`
  - `繁體中文`
  - `日本語`
  - `한국어`
- 底部胶囊悬浮窗，实时显示波形和转录文本
- LLM Refinement，可通过 OpenAI 兼容接口做保守纠错
- 注入链路包含多级 fallback：
  - 临时切到 ASCII 输入源
  - 剪贴板 + `Cmd+V`
  - `System Events` 粘贴
  - Accessibility 文本插入兜底
- 粘贴后恢复原输入法和原剪贴板内容

## 项目结构

- [Sources/VoiceStreamInput/AppDelegate.swift](/Users/changlin/Code/voiceStreamInput/Sources/VoiceStreamInput/AppDelegate.swift)
  应用入口、菜单栏、录音状态机
- [Sources/VoiceStreamInput/HotkeyMonitor.swift](/Users/changlin/Code/voiceStreamInput/Sources/VoiceStreamInput/HotkeyMonitor.swift)
  全局录音键监听
- [Sources/VoiceStreamInput/SpeechPipeline.swift](/Users/changlin/Code/voiceStreamInput/Sources/VoiceStreamInput/SpeechPipeline.swift)
  音频采集、RMS 电平、流式识别
- [Sources/VoiceStreamInput/RecordingOverlayController.swift](/Users/changlin/Code/voiceStreamInput/Sources/VoiceStreamInput/RecordingOverlayController.swift)
  底部悬浮窗和波形动画
- [Sources/VoiceStreamInput/PasteInjector.swift](/Users/changlin/Code/voiceStreamInput/Sources/VoiceStreamInput/PasteInjector.swift)
  输入法切换、文本注入、回退策略
- [Sources/VoiceStreamInput/LLMRefiner.swift](/Users/changlin/Code/voiceStreamInput/Sources/VoiceStreamInput/LLMRefiner.swift)
  OpenAI 兼容 API 调用
- [Sources/VoiceStreamInput/SettingsWindowController.swift](/Users/changlin/Code/voiceStreamInput/Sources/VoiceStreamInput/SettingsWindowController.swift)
  设置窗口

## 环境要求

- Xcode 16+
- Swift 6
- macOS
  - `Package.swift` 当前声明最低为 `macOS 13`
  - 实际设计目标和交互风格按较新的 macOS 菜单栏应用来写

## 构建与安装

```bash
cd /Users/changlin/Code/voiceStreamInput
make build
make run
make install
```

Makefile 说明：

- `make build`
  构建并生成 `.app` bundle 到 `.build/app/VoiceStreamInput.app`
- `make run`
  构建后直接启动 `.build/app/VoiceStreamInput.app`
- `make install`
  安装到 `/Applications/VoiceStreamInput.app`
- `make clean`
  清理 `.build`

签名说明：

- `Makefile` 会优先自动寻找本机的 `Apple Development` 证书签名
- 也可以手动指定：

```bash
make install SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
```

如果没有可用证书，会回退为 `adhoc` 签名。  
但菜单栏热键、辅助功能、自动化权限在 `adhoc` 下通常不稳定，不建议长期使用。

## 首次运行需要授予的权限

- 麦克风
- 语音识别
- 辅助功能
- 输入监控
- 自动化
  - 第一次需要走 `System Events` 粘贴时，系统会弹授权框

建议安装到 `/Applications` 后再授权，避免权限因为重签名或路径变化而失效。

## 使用方式

1. 启动应用
2. 在任意输入框聚焦光标
3. 长按 `Right Command`
4. 说话
5. 松开按键
6. 应用完成转录后自动注入文本

菜单栏可配置：

- 录音键：`Right Command` / `Fn`
- 语言
- `LLM Refinement` 开关
- `Settings`

## LLM Refinement

设置窗口支持：

- API Base URL
- API Key
- Model

用途：

- 只做保守纠错
- 重点修复明显的谐音错误和技术术语误识别
- 不主动润色、不改写正确内容

## 故障排查

### 1. 能录音，但不能插入文字

优先检查：

- `辅助功能`
- `输入监控`
- `自动化 -> System Events`

如果你是重新构建后再安装，优先确认当前 app 仍然是稳定签名，而不是 `adhoc`。

### 2. 每次重装都反复弹权限框

通常是签名身份变化导致的。  
优先使用 `Apple Development` 证书签名，再重新授权一次。

### 3. `Fn` 会触发系统 emoji 面板

项目已经对 `Fn` 做了事件抑制。  
如果仍异常，优先改回 `Right Command`。

## 当前实现取舍

- 注入链路比纯 `Cmd+V` 更复杂
  因为不同应用对粘贴和 Accessibility 支持差异很大
- 目前优先保证“可用”，而不是把注入逻辑压到最短
- 调试日志代码已移除，仓库保持最小必要实现
