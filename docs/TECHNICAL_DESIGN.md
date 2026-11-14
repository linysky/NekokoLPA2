# FOESIM BLE 读卡器接入 NekokoLPA2 — 技术设计

- 日期：2026-11-14
- 目标：让 NekokoLPA2（Windows 桌面版）识别并管理 FOESIM / 7eSIM 蓝牙 eSIM 读卡器（`eSIM-BLE-398DD535`）
- 约束：**不本地编译**，Windows 包由 fork 仓库的 GitHub Actions（`build.yml` 的 `windows` job）产出
- 上游：`iebb/NekokoLPA2` @ `master`（MIT）；fork：`linysky/NekokoLPA2`

## 1. 现状与根因（源码级 + 实机）

### 1.1 设备实测（bleak 只读，2026-11-13 / 11-14）

| 项 | 值 |
|---|---|
| 广播名 | `eSIM-BLE-398DD535` |
| MAC | `E8:05:ED:E5:63:FC` |
| 广播 service UUID | `00004553-0000-1000-8000-00805f9b34fb` |
| GATT service | `00004553-0000-1000-8000-00805f9b34fb` |
| 写特征 | `0000494d-…`，属性 `write, write-without-response` |
| 通知特征 | `00004553-…`，属性 `notify`，CCCD `00002902-…` |
| MTU | 请求 247；分片 = mtu - 3 |
| 帧 | `0x04 | len_lo | len_hi | <payload>`；响应同构，payload 末 2 字节为 SW1SW2 |
| 帧往返实测 | 发 `04 05 00 00 70 00 00 01` → 收 `04 02 00 69 88`（合法帧） |

### 1.2 为什么现装版连不上

- `lib/adapter/ble/ble_manager.dart:197` 的扫描过滤包含 `Guid('4553')`，且设备广播带该 service UUID → **扫描能看见它**。
- `lib/adapter/ble/ble_adapter.dart:78-102` 的 `BleAdapterType.fromDeviceNames()` 是内置白名单（`estkme` / `glocal` / `9eSIM` / `beesim` / `esim_writer`），`eSIM-BLE-…` **不匹配 → null**。
- `lib/adapter/ble/ble_manager.dart:24-28` 的 `BleReaderInfo.fromScanResult` 用 `?? BleAdapterType.redBle` 兜底 → 设备被当成 ESTKme-RED。
- `CompositeAdapter._createBleAdapter` 因此构造 `RedBleAdapter`：找 `6d65`/`544b` 特征（设备没有）、发 ESTKme 的 Claim/PowerOn 帧 → 连接必然失败。

### 1.3 可复用的部分（几乎全部）

| 层 | NekokoLPA2 现有实现 | FOESIM 设备 | 一致 |
|---|---|---|---|
| 连接 | `connectBleDevice(..., preferredMtu: 247)` | `requestMtu(247)` | ✅ |
| 分片 | `calculateBleWriteChunkSize(mtu) = min(240, max(20, mtu-3))` | `mtu-3` | ✅ |
| 帧头 | `_transmit`: `cmd, len&0xFF, len>>8` | `04 len_lo len_hi` | ✅（cmd = 0x04） |
| 组帧 | `expectedLength = b[1] + (b[2]<<8) + 3` | 帧长 = payload + 3 | ✅ |
| 响应 | `sendRawApdu` 返回 `resp.sublist(3)` | payload = data + SW | ✅ |
| 特征 UUID | `6d65` / `544b` | `494d` / `4553` | ❌ 需改 |
| 建链握手 | Claim `02…ESTKme` / PowerOn `03…` | 控制帧 `00 70 00 00 01` | ❌ 需改 |

## 2. 设计

### 2.1 走插件机制，不改核心

- `BleAdapterType.register(BleReaderKind)`（`ble_adapter.dart:47`）
- `PluginManager._registerPlugins()` 对每个 plugin 的 `bleReaderKinds` 注册
- `CompositeAdapter._createBleAdapter` 的 `_ => BleAdapterType.kindOf(type)?.createAdapter() ?? RedBleAdapter()` 自动分发插件类型
- `fromDeviceNames()` **插件 kinds 优先于内置**（`ble_adapter.dart:82-84`）→ 命中后不再 fallback 到 `redBle`

因此只需新增 adapter + plugin，并同步生成式注册表；`ble_manager.dart` / `ble_adapter.dart` / `composite_adapter.dart` 一行都不改。

### 2.2 改动文件

| 文件 | 动作 |
|---|---|
| `lib/adapter/ble/foesim_ble_adapter.dart` | 新增。fork `red_ble_adapter.dart`，改 UUID、换握手、强制 write-without-response |
| `lib/plugins/foesim_ble_plugin.dart` | 新增。照 `ty_ble_plugin.dart` 声明 `BleReaderKind` |
| `lib/plugins/build_plugin_registry.dart` | 同步生成结果（等价于 `dart run scripts/generate_plugin_registry.dart` 的输出） |

### 2.3 `FoesimBleAdapter` 关键差异

- `serviceUuid = Guid('4553')`（不变）
- `txCharUuid = Guid('494d')`（写）、`rxCharUuid = Guid('4553')`（notify；与 service 同值，设备实测如此）
- 删除 ESTKme `_claim()` / `_powerOn()`；改为 **APK `q()` 的两条 `cmd=0x02` 设备码握手帧**：`02 | 08 00 | 02 05 + "eSIM-H"` 与 `02 | 06 00 | <持久 install id 后 6 字符>`，第二条期望 `02 00 00`。bleak 实测补上握手后 `AF 50 00 00 09` 从 `6988` 变 `9000`（固件 v109/109、mode=0）
- **不在连接阶段发 `00 70 00 00 01`**：那是标准 MANAGE CHANNEL APDU，由 `BaseAdapter.openLogicalChannel`（`euicc_adapter.dart:558`）负责；`BaseChannel.transmit`（:255）自动给 CLA 带通道号。第一版误在 `connect()` 里抢发，已删除
- `lastAtr => null`（设备不提供 ATR）
- 分片写入强制 `withoutResponse: true` + 15 ms 间隔（对齐 APK 的 `WRITE_TYPE_NO_RESPONSE`）。`writeBleChunks` 在特征同时支持 `write` 时会选带响应写入，故本 adapter 自己分片
- `sendRawApdu` / `_transmit` / `openChannel` 保持与 RED 一致

### 2.4 `FoesimBlePlugin` 关键字段

```dart
BleReaderKind(
  id: 'foesim_ble',
  label: 'FOESIM',
  matches: (display, advertised) =>
      _hasMarker(display) || _hasMarker(advertised),  // '-BLE-' / '-BLER-'，忽略大小写
  createAdapter: FoesimBleAdapter.new,
  icon: Icons.bluetooth,
  scanKeywords: const ['eSIM-BLE'],
  scanServiceUuids: const ['00004553-0000-1000-8000-00805f9b34fb'],
)
```

## 3. 构建与交付

- **Windows-only workflow**：`.github/workflows/windows-foesim.yml`。push 到 `master` 且改动命中 FOESIM 相关路径即自动触发，也可 `workflow_dispatch`；只跑 `windows` job，其他平台不构建（主人 2026-11-14 定：优先 Windows，其他稍后）
- 上游 `build.yml` 保留不动（全平台，`on.push.branches: [release]`）
- 构建：`runs-on: windows-latest` → `flutter build windows --release --dart-define=APP_VARIANT=std …` → `Compress-Archive` 出 portable zip（Inno Setup `setup.exe` 为 best-effort）→ `actions/upload-artifact@v4`，artifact 名 `windows-foesim`
- 产物：`NekokoLPA2-foesim-windows-x64.zip`（+ 可选 `NekokoLPA2-foesim-windows-setup.exe`）
- 首轮全平台 CI（run `43565704412`）因 `dart:math` 顶层 `log` 遮蔽 `BaseAdapter.log`，产生 8 个编译错误导致全平台失败；已改为 `import 'dart:math' as math` 修复
- 公开仓库不含私有 branding overlay，产物为 community 构建

## 4. 验证结果（2026-11-14 实机，v6 / commit `b323424`）

**通过**：GitHub Actions Windows 包静默安装 → 扫描出现 `FOESIM: eSIM-BLE-398DD535` → 连接 →
读 EID → 列出 profile。界面显示 EID `89049032…7187821357`、剩余 **833.88 KB**、profile
`ESIM_ACCES…`（Singtel，ICCID `8965012606160924300`，~18 KB，已启用）。

日志尾部（APDU 原始日志开启）：`[CH 1] >> 81e2910003bf2b00` → `<< 6105` →
`[CH 1] >> 81c0000005` → `<< bf2b02a0009000` → `Closing logical channel 1...` →
`Logical channel 1 closed.` —— 完整走完 SGP.22 读 EID + 列 profile。

### 调试中定位并修掉的 4 个根因（全部 bleak 帧级复现）

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | 所有卡 APDU 被 `6988` 挡（`E:19` / 不支持该卡） | 缺 APK `q()` 的两条 `cmd=0x02` 设备码握手帧 | adapter 加握手 |
| 2 | 补握手后仍被拒 | 设备**绑定配对 id**：实测只有 `ABC123` 拿到 `02 00 00` 并开通道，`ABC124`/`abc123`/`5e1ac5`/`123456` 全被 `6988` 拒 | `shared_preferences` 的 install id 设为设备认的值 |
| 3 | `FOESIM BLE not connected` | Windows WinRT 在订阅 CCCD 时推一次瞬时 `disconnected`，`connectionState` 监听把 `_txChar/_rxChar` 置空，随后 `_transmit` 守卫抛错 | 删掉该监听；disconnect 交给显式 `disconnect()` |
| 4 | 15 秒超时 → 回退通道 0 → `No supported AID found` | `ApduChainer` 给无 Le 命令自动补 `0x00`；TERMINAL CAPABILITY `80AA…0107` 15 字节回 `9000`，多一个 `00` 的 16 字节版**沉默并断链** | `FoesimBleAdapter.sendApdu` override，框架级 APDU 原样发送，绕过 chainer |

另：notify 改为**一次常驻订阅 + 共享缓冲**——FBP 每次 `onValueReceived.listen` 会重放上一次值，
逐请求订阅会把旧帧混进下一次响应、污染 SW。

### 支撑性排除（实机对照，非推测）

- `80 AA` TERMINAL CAPABILITY 前缀：带/不带都能开通道、SELECT 成功
- `cleanupChannels` 的 3 条 `00 70 80 00 0x`：带/不带都返回 `9000`
- MANAGE CHANNEL 的 Le=`00` / `01`：都返回 `01 90 00`
- SELECT 末尾 Le=`00` / `FF` / 不带：都返回 `61 21`，GET RESPONSE 读回 ISD-R FCI
  `6F1F 84 10 A0000005591010FFFFFFFF8900000100 … 9000`

## 5. 本机环境改动（可回滚）

`%APPDATA%/ee.nekoko/NekokoLPA 2/shared_preferences.json`：

| 键 | 值 | 说明 |
|---|---|---|
| `flutter.foesim_ble_install_id` | `ABC123` | 原值 `6603bdf5e1ac5`，备份 `.bak-foesim-20261114` |
| `flutter.enableCcidConnector` | `false` | 避免电脑自带 PC/SC 读卡器抢默认选中 |
| `flutter.lastSelectedReader` | `foesim_ble: eSIM-BLE-398DD535|E8:05:ED:E5:63:FC` | 默认选中 |
| `flutter.developerModeEnabled` / `showLogConsole` / `enableApduLogging` | `true` | 诊断用，可关 |

## 6. 不做的事

- 不改 `ble_manager.dart` / `ble_adapter.dart` / `composite_adapter.dart` 核心逻辑
- 不实现读卡器固件升级（APK 私有协议，超出本次目标）
- 不本地编译、不安装 Flutter SDK
- 不执行任何会改动 eSIM profile 的操作（启用 / 禁用 / 删除 / 下载）
