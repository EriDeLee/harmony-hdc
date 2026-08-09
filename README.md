# HDC Toolbox

在手机上直接跑 HDC 客户端。用 ArkTS 重写了 hdc 的无线调试协议，连本机 `127.0.0.1` 的 hdcd，不需要电脑。

- 包名 `com.lee.hdc` · 版本 `1.2.1`
- HarmonyOS，`targetSdkVersion 6.1.0(23)`
- 仅手机，无第三方依赖

## 截图

<table>
<tr>
<td align="center" width="50%">
<img src="screenshots/01-main.webp" width="330" alt="主页浅色主题，已连接状态，日志面板逐行显示握手、公钥上报、签名与认证成功">
<br>主页 · 握手与鉴权日志
</td>
<td align="center" width="50%">
<img src="screenshots/02-features.webp" width="330" alt="功能页深色主题，列出终端、清空应用数据、电源控制三个入口">
<br>功能页 · 深色主题
</td>
</tr>
</table>

## 为什么

`hdc` 官方只有 PC 端二进制。手机开了「无线调试」之后，hdcd 会在本机监听一个 TCP 端口 —— 那个端口对手机自己也是可达的。于是把 hdc 的握手、鉴权、shell 通道全部在 ArkTS 里实现一遍，应用就能以 shell 权限操作本机，也能连局域网里的另一台设备。

## 功能

| 入口 | 做什么 |
| --- | --- |
| 终端 | 全屏交互式 shell，支持 Ctrl+C、流式输出、UTF-8 跨帧解码 |
| 清空应用数据 | 列出全部应用，多选后用 `bm clean` 清数据 |
| 电源控制 | 熄屏、电源挡位（普通/省电/性能/超级省电）、屏幕超时 |

底层实现用的命令：

- 应用列表 `bm dump -a -l`，系统应用判定用 `xargs -P16` 在设备侧并发跑 `bm dump -n <pkg>`，判定结果缓存到 Preferences
- 清数据 `bm clean -n '<pkg>' -d`，包一层退出码 marker，非 0 直接抛错
- 电源 `power-shell suspend` / `power-shell setmode 600..603` / `power-shell timeout -o <ms>` / `power-shell timeout -r`
- 每次改电源设置后回读 `hidumper -s PowerManagerService -a "-s"` 校验是否真的生效

## 环境要求

- HarmonyOS 手机，实测 HarmonyOS 6.1.1
- 开发者选项里打开「无线调试」，记下它显示的端口号
- 首次连接需要在设备上点掉 hdc 授权弹窗

## 用法

1. 打开应用，Host 填 `127.0.0.1`（连本机）或对端设备 IP，Port 填无线调试端口
2. 点「生成密钥」生成并持久化 RSA-3072 密钥对（只需一次）
3. 点「连接」，设备弹出授权弹窗时确认
4. 切到「功能」页选终端 / 清空应用数据 / 电源控制

Host、Port 和系统应用判定缓存会存到 Preferences，下次进来自动回填。

## 目录结构

```
entry/src/main/ets/
├─ entryability/EntryAbility.ts     UIAbility，只负责 loadContent
├─ pages/Index.ets                  全部 UI（主页 + 终端/清数据/电源三个全屏浮层）
└─ hdc/
   ├─ HdcTypes.ts                   协议常量与类型
   ├─ Bytes.ts                      ByteReader/ByteWriter、base64、hex、UTF-8
   ├─ Protocol.ts                   varint、protobuf 字段、TLV、组帧与拆帧
   ├─ HdcCrypto.ts                  RSA-3072 生成/导入、PSS 签名
   ├─ HdcKeyStore.ts                密钥 PEM 持久化
   ├─ HdcSettings.ts                连接参数与系统应用判定缓存
   ├─ HdcConnection.ts              TCP、握手鉴权状态机、帧路由
   ├─ HdcShellChannel.ts            交互式 shell 通道
   ├─ HdcUnityCommandChannel.ts     一次性命令通道
   └─ BundleManager.ts              bm 封装：列表、系统应用分类、清数据
```

## 已知限制

- 设备要求 `AUTH_ENCRYPT`（TLS-PSK 加密信道）时直接失败，未实现
- 命令输入框关不掉输入法自动大写，试过多种方案均无效
- UI 文案全部硬编码中文，没做多语言
- 私钥以 PEM 明文存在应用沙箱的 Preferences 里，依赖沙箱隔离，没有额外加密

## 权限

只申请 `ohos.permission.INTERNET`，用于连 hdcd 的 TCP 端口。
