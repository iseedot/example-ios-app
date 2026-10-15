# MyCallRec

一个自己实现的通话录音 App，用作**第一阶段真机验证台**：验证"用私有 audio tap 抓取通话音频"这条路线在
TrollStore 环境下是否成立。代码全部自写，只依赖公开 SDK（私有类通过 Objective-C 运行时访问）。

## 它能做什么

- 选择录音源：**麦克风 / 系统音频 / 扬声器 / 指定进程 PID**
- 通话接听后**自动开始**录制，挂断自动停止（CoreTelephony 私有通知中心）
- 录音列表、播放、删除（文件在 App 沙盒 `Documents/Recordings/`，可通过"文件"App 取出）
- 实时显示已录时长与音频包数（0 包 = 抓取失败，直接暴露问题）
- 内置进程列表，可挑选 PID 做实验（用于确定通话音频归属哪个进程）
- 屏幕内日志，出问题能直接看到原因

## 安装（TrollStore）

1. 打开 [Releases](../../releases/latest)，下载 `MyCallRec.tipa`
2. 用 TrollStore 打开该文件安装
3. 首次启动后点一次"开始录制"，确认权限生效（tap 状态应显示"可用"）

> 仓库为 private 时，手机上需要先在 Safari 登录 GitHub 才能下载。
> 想省事可以把它改成 public（本仓库只含自写代码）。

## 构建

GitHub Actions 在 `macos-14` 上执行 `build.sh`：

1. `swiftc` 直接用 iPhoneOS SDK 编译（无 Xcode 工程）
2. `ldid -S entitlements.plist` 注入私有 entitlements
3. 打成 `Payload/MyCallRec.app` → `MyCallRec.tipa`
4. 上传 artifact，并创建带该 tipa 的 Release

本地构建：`./build.sh`（需要 macOS + Xcode 命令行工具 + `brew install ldid`）。

## entitlement 说明

`entitlements.plist` 里的权限来自对目标软件的分析（见 REA 工作区 `analysis/entitlements.json`）：

| entitlement | 用途 |
|---|---|
| `com.apple.coreaudio.CanTapTelephony` / `app-tap` / `private.SystemWideTap` | 允许抓取通话与系统音频 |
| `com.apple.coreaudio.CanRecordWithoutSessionActivation` | 后台录音不激活会话 |
| `com.apple.private.mediaexperience.startrecordinginthebackground.allow` | 允许后台起录 |
| `com.apple.CommCenter.fine-grained` / `telephonyutilities.callservicesd` | 读取通话状态 |
| `com.apple.private.security.no-sandbox` / `platform-application` | 关闭沙箱（TrollStore 环境） |
| `com.apple.private.tcc.allow` (Microphone) | 免弹窗使用麦克风 |
| `com.apple.security.exception.files.absolute-path.read-write: ["/"]` | 访问沙盒外路径 |

这些权限用普通 Apple 开发者证书拿不到，必须经 TrollStore 安装。

## 关键技术点

```swift
// 1. 私有类：运行时取，不需要私有头
let descClass = NSClassFromString("ATAudioTapDescription")
let tapClass  = NSClassFromString("ATAudioTap")

// 2. 通过 IMP 调用私有初始化器（兼容新旧 iOS 的两种选择子）
let imp = method_getImplementation(class_getInstanceMethod(descClass, sel))
let initialize = unsafeBitCast(imp, to: InitTwoArgFn.self)

// 3. 让 AudioQueue 的数据源从麦克风改绑到 tap
AudioQueueSetProperty(queue, 0x71746F62 /* 'qtob' */, &tap, 8)
```

## 已知限制

- 只有单路录音；通话双方分轨（uplink/downlink 混音）是下一步
- 还没有守护进程，App 被系统回收后不会继续录
- `0x71746F62` 这个属性值来自上游 GPL 头文件的注释（作者自己标注为猜测），若录到静音需要怀疑它
- 未在本仓库验证：所有代码尚未在真机跑过
