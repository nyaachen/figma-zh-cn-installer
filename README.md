# Figma 中文版 · Windows 安装脚本

给 Figma 桌面客户端配置「本地代理 + 中文语言包」，让界面变成中文。
单个 `.ps1` 文件，可放在任意静态站点，用 `irm ... | iex` 直接跑。

界面所使用的中文语言包来自开源项目
[kailous/figma-zh-CN-localized](https://github.com/kailous/figma-zh-CN-localized)，
本仓库只负责安装与本地代理配置，不内置、不转发语言包（详见 [语言包来源与致谢](#语言包来源与致谢)）。

## 直接安装（本仓库）

```powershell
irm https://raw.githubusercontent.com/nyaachen/figma-zh-cn-installer/main/install.ps1 | iex
```

仓库：<https://github.com/nyaachen/figma-zh-cn-installer>

## 部署

把 `install.ps1` 放到任意能返回纯文本的地址即可，例如：

- GitHub Gist（raw 地址）
- 自建静态站 / 对象存储
- 内网文件服务

要求：`Content-Type` 不要是 `text/html`（否则 `irm` 拿到的是 HTML）。
`raw.githubusercontent.com`、Gist raw、OSS/COS 直链都没问题。

脚本自身带编码自愈：即使服务端没声明 `charset=utf-8`（例如普通
`python -m http.server` 返回 `application/octet-stream`），PowerShell 5.1 按
Latin-1 解码导致中文变乱码，脚本会在运行时检测并还原，快捷方式名与提示文字都正常。
仍然建议服务端声明 `charset=utf-8`。

## 运行

```powershell
irm https://你的地址/install.ps1 | iex
```

脚本会先说明它要做什么，按回车才开始；输入其它内容回车则取消。

> Windows PowerShell 5.1 下推荐用 `irm | iex`。如果先 `-OutFile` 再 `-File` 执行，
> 5.1 会按 ANSI 读取无 BOM 的 UTF-8 文件，中文提示可能变乱码；这种用法请改用
> PowerShell 7（`pwsh -File install.ps1`）。

### 参数（可选）

| 参数 | 作用 |
| --- | --- |
| `-InstallDir <路径>` | 安装目录，默认 `%USERPROFILE%\.figma-zh-cn` |
| `-Yes` | 跳过开头的回车确认（自动化用） |
| `-NoShortcut` | 不创建快捷方式，只准备文件 |
| `-SkipFigma` | 即使没装 Figma 也不去下载 |
| `-Port <端口>` | 指定 mitm 端口；默认自动探测未使用的非常用端口 |

`irm | iex` 传不了参数。需要参数时改用下载后执行：

```powershell
irm https://你的地址/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Yes
```

## 干净机器上会发生什么

| 情况 | 脚本行为 |
| --- | --- |
| 没有 Python | 下载 Python 3.13.9 便携版到安装目录，pip 安装 mitmproxy，**不碰系统 Python** |
| 没有 Figma 客户端 | 询问后下载官方 `FigmaSetup.exe`（约 160 MB）并安装，装完自动继续 |
| 已装过本工具、快捷方式丢了 | 识别为「修复安装」：保留语言包与端口，补回桌面/开始菜单快捷方式 |
| 已装过、但 Python 环境坏了 | 检测 `mitmdump --version` 失败后重建环境 |

安装完成后会做两项自检：语言包 JSON 与插件规则校验；以及真起一次 mitm，
请求 Figma 语言包 URL 验证返回的正是中文包（字节数一致）。

## 它改什么、不改什么

改：

- `%USERPROFILE%\.figma-zh-cn\` 下的文件（自带的 Python、mitmproxy 插件、语言包、启动器）
- 桌面和开始菜单各一个「Figma 中文版」快捷方式

不改：

- 系统代理（WinINET）、Clash 配置、浏览器
- Windows 证书库（不导入自签 CA；Figma 启动时用 `--ignore-certificate-errors` 仅对该进程生效）
- 不需要管理员权限，不写服务项、不改注册表

## 启动时的行为

双击「Figma 中文版」后：

1. 若发现 Figma 已经在运行但**没有走本地代理**（例如你点的是原来的 Figma 图标），
   弹窗询问是否立即重启；确认后会顺带清理 Figma 的界面缓存（见下节）
2. 探测上游代理：**系统真实代理**（`HKCU\...\Internet Settings`）→ 不可达则回退 **Clash `127.0.0.1:7897`**
3. 需要时拉起本地 mitm（端口来自 `port.txt`）
4. **健康检查**：通过本地代理请求一次语言包，确认返回的确实是中文包；
   不通过就重启 mitm 重试，仍不通过则弹窗报错并不启动 Figma（不会静默变成英文）
5. 带 `--proxy-server` 参数启动 Figma，语言包请求被替换为中文包

系统代理与 Clash 都不可达时，弹窗二选一：**直连启动**（mitm 不挂上游，界面仍中文）或 **停止启动**。

## 为什么"装完还是英文"（已修复）

Figma 会把真实英文语言包按 build hash 缓存在自己的 HTTP 缓存里。只要 Figma 在
本地代理之外跑过一次（最常见的：安装前先打开过 Figma，或事后点了原来的 Figma 图标），
这份英文包就会留在缓存里；之后再通过代理启动，即使语言包请求已被替换成中文，
前端仍可能沿用缓存里的英文——表现为"代理明明生效了，界面还是英文"。

现在两处都处理了：

- 安装时（Figma 未运行）自动清理一次 Figma 的界面缓存，并输出清理了几个目录
- 启动器发现未走代理的实例、按用户确认重启时，也会清理缓存后再启动

缓存目录不是靠猜目录名，规则取自 Figma 自己的 `resources/app.asar` → `main.js`：

```js
lI = parseInt(process.versions.electron.split(".")[0]);            // 版本号 = Electron 主版本号
cx = join(channel === "stable" ? base : profileDir,
          channel === "stable" ? "DesktopProfile" : "Profile");
_a = join(cx, `v${lI}`);                                            // 即 --user-data-dir
```

Chromium 的 HTTP 缓存就在 `<user-data-dir>\Cache\Cache_Data`。本机实测：
Figma 126.11.8 / Electron 44.10.0 → 目录 `DesktopProfile\v44`，与公式一致。

脚本的取法（两级）：

1. **Figma 正在运行**：直接读进程命令行里的 `--user-data-dir=...`，拼 `Cache` 子目录——
   精确，且能覆盖自定义 profile 目录的用法
2. **Figma 未运行**：在 `%APPDATA%\Figma` 下按上述结构找 `<渠道>\v*\Cache`，
   只取内含 `Cache_Data` 的目录（按 main.js 的迁移逻辑，只有当前版本 profile 才有 Cache）

因此下面这些变化**不需要改脚本**：

- Electron 升级导致 `v44` → `v45`（`v*` 通配，且运行时走 `--user-data-dir`）
- 渠道目录名不同：`DesktopProfile` / `Profile` / `DesktopGov` / `DesktopBeta`（扫码时通配）
- 用户用参数把 profile 放到别处（运行中读命令行，精确命中）

需要更新脚本的只有一种情况：Figma 更换缓存实现，不再使用 `<user-data-dir>\Cache`。
这时安装日志会显示"未发现需要清理的 Figma 缓存目录"，症状会退回"装完是英文"，
看到这条日志就说明该按新版 main.js 更新路径规则了。

注意：清理缓存会让 Figma 下次启动重新下载界面资源（几十 MB），属一次性开销。
请统一用「Figma 中文版」启动，不要再用原来的 Figma 图标。


## 卸载

1. 退出 Figma
2. 删除桌面和开始菜单里的「Figma 中文版」
3. 删除 `%USERPROFILE%\.figma-zh-cn`
4. 如果 mitm 还在跑：`Get-Process mitmdump | Stop-Process`

## 语言包来源与致谢

中文语言包**不是本仓库翻译的**，来自开源项目：

- 项目主页：[kailous/figma-zh-CN-localized](https://github.com/kailous/figma-zh-CN-localized)
- 语言包直链（本工具默认从这里下载）：<https://kailous.github.io/figma-zh-CN-localized/lang/zh.json>

上游项目把 Figma 官方英文语言包翻译成中文，并每 30 分钟跟随 Figma 英文包更新，
同时维护术语表（MCP、组件、实例、令牌等产品/技术名的统一译法）。
本仓库只负责"让 Figma 加载这份语言包"所需的安装与本地代理配置，
**不转发、也不内置 `zh.json`**——安装时才从上面这个直链下载。
翻译质量、缺词、术语问题请提到[上游仓库](https://github.com/kailous/figma-zh-CN-localized/issues)。

## 已知限制

- 只处理 Figma 桌面客户端；网页版（浏览器）不生效。
- 登录页/授权页走另一份 `auth_iframe-*` 语言包，仍是英文。
- 语言包由上游 [kailous/figma-zh-CN-localized](https://github.com/kailous/figma-zh-CN-localized)
  每 30 分钟跟随 Figma 英文包更新，本机启动器在包超过 7 天时自动刷新；
  Figma 新增文案若上游尚未翻译，按缺键回退。
- 首次安装需要能访问 python.org、pypi.org 以及
  [kailous.github.io](https://kailous.github.io/figma-zh-CN-localized/lang/zh.json)；下载 Figma 时需要 figma.com。
- Figma 自动升级后语言包文件名 hash 会变，插件按模式匹配，无需重新安装。

## 本机实测覆盖（2026-11-12，Figma 126.11.8 / Windows 11）

| 场景 | 结果 |
| --- | --- |
| 全新安装（无 Python 依赖，走自带 embeddable 3.13.9 + pip 装 mitmproxy 12.3.1） | 通过 |
| `irm http://… | iex` 投递（服务端 `application/octet-stream`，无 charset） | 通过，中文与快捷方式名正常 |
| 按回车同意 / 输入其它内容取消 | 两条分支均符合预期 |
| 重复运行（修复安装） | 3.2 秒完成，复用端口、跳过下载 |
| 删除快捷方式 + 删除 `figma_zh.py` 后重跑 | 两者都被补回，端口不变 |
| 安装后自检（起 mitm → 请求语言包 → 与 zh.json 逐字节比对） | 通过 |
| 通过新快捷方式启动 Figma | 上游识别系统代理，界面中文，语言包替换生效 |

**未实测**：本机已装 Figma，所以「未检测到 Figma → 下载 `FigmaSetup.exe`（约 160 MB）→
等待安装完成」这条分支只验证了下载地址可达（HTTP 200），没有真正跑过安装流程。
