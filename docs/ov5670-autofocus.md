# OV5670 自动对焦修复记录 (2026-08-08)

Lenovo MIIX 720 (80VV) 后置 OV5670 (IPU3 管线) 自动对焦功能增强与修复。
基于 libcamera 0.7.0 (Ubuntu) 源码修改，改动以补丁形式归档于
`back_camera/ipa-patches/`。

## 架构

```
应用 → /dev/video16 (v4l2loopback) → ov5670-router (GStreamer)
     → libcamerasrc (af-mode/af-trigger 属性) → controls → IPU3 IPA
     → Af 算法 (af.cpp) → 镜头 (dw9719 VCM)
```

- **router** (`back_camera/scripts/ov5670-router.c`)：检测 v4l2 控件
  `af_trigger`/`focus_auto`/`focus_absolute` 变化 → 经 GStreamer 属性
  (`g_object_set`) 写入 libcamerasrc → IPA。
- **IPA** (`af.cpp`)：三模式状态机 (manual/auto/continuous)。

## 修复清单

### A. 触发可靠性 (router + gst 层)

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| A1 | AfMode 偶发到不了 IPA | 主线程 `g_object_set`→`controls_[AfMode]` 与流线程每帧 `merge→clear` 竞争，写入落在 merge 后 clear 前被丢弃 | **跨帧重发**：触发后立即异步重发 + 500/1000/1500ms 三次重发 (间隔 >> 帧周期 34.5ms) |
| A2 | auto 心跳形同虚设 | `af_apply_mode` 去重 (`mode==af_cur_mode` 直接 return) 挡住心跳重发 | auto 心跳改**直发** `af_set_src_int("af-mode",1)` 绕过去重 |
| A3 | AfTrigger 偶发丢失 | 同 A1 (瞬时控件同样存 controls_) | AfTrigger 同样 3 次跨帧重发 |
| A4 | 30s 回退 continuous 失效 | 回退的 AfMode=2 单次发送撞 clear 竞争 | 回退也跨帧重发 + **continuous 心跳** (非 auto/manual 时每 2s 直发 af-mode=2) |
| A5 | cam PAUSED 时属性无法到达 | applyControls 依赖帧流 (queueRequest 每帧) | 无帧时属性滞留 controls_，激活后自动补发 (用户应用常开不受影响) |

### B. 失焦判定 (af.cpp continuous 模式)

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| B1 | 对焦准确时反复重扫 | AE 增益漂移 → 绝对方差暴涨 (实测 cur=70万 vs max=11万, ratio 5.2) | **方差归一化** `var/mean²` (增益 g: mean→g·mean, var→g²·var, 归一化不变) |
| B2 | 归一化后检测失效 | `diff_var` 是 uint32_t，归一化后小数被截断为 0 | 改 `double` |
| B3 | EMA 滞后致扫描峰值低估 | 扫描中方差快变，EMA (0.5/0.5) 滞后 → 峰值偏低 → 收敛后 cur 显著 > max | **扫描后基准收敛期** (10 帧 maxVariance 跟随 EMA, 不判定失焦) |
| B4 | 场景亮度慢漂移 | maxVariance 固定为扫描峰值 | **自适应基准** (未失焦时 max 缓慢跟随 0.95/0.05, 时间常数 ~0.7s) |
| B5 | 阈值过敏感 | kMaxChange=0.3 把 20-40% 正常波动判为失焦 | 回调 **0.4** (官方 0.5 与用户原要求 0.4 之间取 0.4) |
| B6 | 单帧瞬时误判 | 单帧方差比较即触发 | **连续 5 帧确认** (~170ms) 才 afReset |

### C. auto 扫描精度 (af.cpp auto 模式)

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| C1 | rescan limit 后锁粗扫 best (无细扫) | confirm 失败 3 次 → 直接锁定 (±5 精度) | rescan limit → **围绕历史最佳细扫** (不跳环节, ±1 精度) |
| C2 | rescan 锁最后那次 best | rescan 重置 forceBestFocus_ | **历史全局最佳** bestFocusAll_ (跨 rescan 保留) |
| C3 | 细扫锁定到范围外 (实测 154 vs 预期 360±51) | 细扫轨迹用**动态** fineBestFocus_ 做基准, 扫描中更新致轨迹漂移 | **固定起点** fineScanStart_ 做轨迹基准 |
| C4 | 尖锐峰被 confirm 误判假峰值 | confirm 回退整 1 个粗扫步长 (10 步), 尖锐峰回退后方差掉 >10% | 回退**半步** (5 步) |
| C5 | 最长扫描路径超 30s 锁定窗口 | 3 次 rescan (21s) + 细扫 (10.6s) = 31.6s > 30s → 回退打断细扫 | 锁定窗口 **30→40s** |
| C6 | AfTrigger 丢失 (统计性) | gst 层 clear 竞争概率残留 (~6%) | **auto idle 超时兜底** (20 帧无触发自动扫描) |

### D. 稳定性 (router)

| # | 问题 | 修复 |
|---|---|---|
| D1 | OBS 等 O_RDWR 占用 video16 → S_FMT EBUSY → 服务 13s 抖动重启循环 | **busy 等待**: 检测 "is busy" → 等 video16 释放 (IN_CLOSE) 后退出重启, 60s 超时兜底 |

## 画质调校 (2026-08-08)

- 根因: `ov5670.yaml` 调校缺失 → fallback `uncalibrated.yaml` (零参数) →
  AGC 目标亮度仅 0.16 (画面暗) + 无传感器特性。
- 修复: `back_camera/tuning/ov5670.yaml` 设置 `Agc.relativeLuminanceTarget: 0.35`
  → 实测亮度 43.5 → 132.6 (提亮 3 倍)。
- 资产: Intel 官方 ov5670 调校 (`01ov5670.aiqb` Apache 2.0) 已归档 (见
  `back_camera/tuning/README.md`)，供后续完整 3A 调校使用。

## 对焦接口更新 (2026-08-09)

用户实测反馈后的迭代:

| 改动 | 内容 |
|---|---|
| **v3 扫描加速** | 粗扫步进 10→20 (全范围 ~4s→~2s), 细扫步进 1→2 (~10.6s→~5.3s), 细扫范围 ±51 保持 (覆盖粗扫偏差 ±20) |
| **focus_auto=0 → manual** | 标准语义入口 (原只有 focus_absolute 拖动触发); 切 manual 保持当前位置, 不启动心跳 (等拖动接管) |
| **af_trigger 自动回 0** | int 控件不自动复位 → 触发后 router 立即写回 0, 保持待触发状态 (可重复 0→1 触发) |
| **manual 心跳直发 af-mode=0** | 修复: 首次 af-mode=0 单次发送被 clear 竞争丢弃 → IPA 停留 continuous 忽略 LensPosition → 手动对焦无效; 心跳 200ms 同时重发 af-mode=0 + lens-position |

**使用说明** (V4L2 标准 2 态):
- `focus_auto=1` → auto (触发扫描, 40s 后回退 continuous); 默认 continuous
- `focus_auto=0` → manual; 拖 `focus_absolute` (0-1023) 移动镜头
- `af_trigger=1` → 触发一次 auto 扫描 (触发后自动回 0)
- 3 态模式开关 (af_mode 自定义控件) 用户决定**不实施** (自定义不通用)

## 2026-08-09 排查记录 (重启控件丢失根治 + 手动切回触发修复)

### 1. 重启后对焦控件丢失 — 六次复发根治 (initramfs 预加载)

用户六次重启报告 video16 对焦控件 (af_trigger/focus_auto/focus_absolute) 缺失 (0/3)。逐轮定位:

| 轮 | 方案 | 结果 | 结论 |
|---|---|---|---|
| 1 | 手动重载恢复 | 每次重启必丢 | 开机路径与手动路径行为不同 |
| 2 | selfheal 自愈 (9cb836e) | 偶发恢复 | 双保险, 非根治 (**2026-08-09 晚移除**) |
| 3 | 模块参数 video_nr=99,16 (方案 A) | 引号/转义解析问题 | conf 回滚, 视频16 走 add |
| 4 | 无条件注册 AF 控件 (3bdc402) | 手动验证过, 重启仍丢 | 开机加载的模块≠磁盘模块 |
| 5 | v4l2loopback-load.service (fb0edfc) | 重启仍丢 | initramfs 阶段已预加载 |
| 6 | **update-initramfs -u** (9c5dd11) | **重启即有控件** | initrd 预加载消除, 根治 |

**根因链**: initramfs-tools `MODULES=most` + modules-load.d 含 v4l2loopback
→ initramfs 打包 v4l2loopback.ko.zst + 未注释的 modules-load.d → **initrd
阶段 (root 挂载前) systemd-modules-load 预加载 v4l2loopback** (kmod 库方式)
→ root 阶段所有改动 (modules-load.d 注释 / v4l2loopback-load.service) 均
无效 (模块已加载, modprobe 不重载) → 登录后 ensure-device add video16 →
控件不注册 (0/3)。

**关键证据**:
- journal 开机早期 `Inserted module v4l2loopback` (systemd-modules-load PID 133, initrd 阶段)
- `sudo lsinitramfs` 确认 initramfs 含 `v4l2loopback.ko.zst` + `modules-load.d/ov5670-virtual-camera.conf`
- **决定性对照**: 同一模块 (35373B) modprobe 加载 → add 3/3; modules-load (kmod 库) 加载 → add 0/3
- 反汇编: 模块无条件注册编译正确但行为不一致 (模块≠当前源码, 旧模块数据段 "OV5670.%s erro")

**最终方案 (已部署+跨重启验证)**:
1. `update-initramfs -u` — 新 initramfs 的 modules-load.d 为注释版, initrd 不再加载
2. `v4l2loopback-load.service` (root, WantedBy=sysinit.target) — `ExecStart=/sbin/modprobe
   v4l2loopback` (modprobe 命令加载, modprobe.d 参数完整解析, 与手动重载一致)
3. modules-load.d 注释 v4l2loopback (root 与 initramfs 同步)
4. ec-fix `After=systemd-modules-load.service v4l2loopback-load.service`
5. ~2026-08-09 晚: selfheal (user 服务) 曾保留为双保险 (检测控件缺失 → delete+add
   重建, 不碰前摄) — **现已移除** (版本统一后控件注册确定性, 双保险无必要,
   且其检测"控件缺失"无法防"版本回退"; `systemctl --user disable ov5670-af-selfheal`)

### 2. 手动切回 focus_auto 不触发 — 写回竞态修复 (0720ab2)

- 现象: 拖 focus_absolute 进手动 (写回 focus_auto=0) 后, 勾选 focus_auto 不触发 auto 扫描。
- 根因: 写回 0 后 router G_EXT_CTRLS 读控件缓存**偶发延迟** (仍读 1) → af_last_focus_auto
  无边沿 → ② auto_on_event (`focus_auto==1 && last_auto==0`) 不满足 → 不触发。
- 修复: ② 条件加 `af_manual_active` (manual 心跳状态勾选必定触发, 不依赖读边沿);
  同时 `manual_event` (① 拖动轮) 跳过 ② (防拖动轮误触发 auto, 12:24:52 实测复现)。
- 验证: 拖动轮不误触发 + 勾选触发 + 场景 B (focus_auto=0→1) 触发 + auto 持续无重复
  (`docs/scripts/verification/hermes-verify-af-manual-switch.sh`, PASS=9)。

## 2026-08-10 修复链 (gst→IPA 控件传递断点 + 扫描中断 + AfState 官方完成检测)

### 1. ENOBUFS 丢控件根因 (9ad5814) — 最关键的修复

- **根因**: gst buffer 池不足 (min_buffers=3) 时, `acquire_buffer` 失败 →
  带控件的 request 整体丢弃 (`return -ENOBUFS`) → 控件随 request 消失。
  之前的竞态锁/逐个 set 修错了地方 — 断点不在"写-清竞争"。
- **修复**: `GstCameraControls::retainControls()` — ENOBUFS 丢弃时把控件
  放回 controls_, 下次 request 自动带上。事件驱动控件不再丢失。
- **同时**: 回归官方 `request->controls().merge(controls_)` (merge≡逐个
  set 完全等价, controls.cpp 1012-1033 行证实), 补丁面最小化。
- **验证**: 修复前 IPA queueRequest 探针 303 次全 controls=0; 修复后
  连续 3 次触发 IPA 每次收到 AfMode + 扫描。

### 2. router 状态残留修复 (2773eeb)

- **af_trigger 运行中残留**: continuous 下设 af_trigger 被官方语义忽略
  但残留 1 → 切回 manual 后设 1 无边沿 → 永远失效。修复: continuous
  下检测到触发边沿立即复位控件 + af_last_trigger 保持 0。
- **流状态不收敛**: deactivate 依赖 inotify 事件, 事件丢失 (pipewire
  间歇 fd 干扰) 则 PLAYING 卡住无帧。修复: poll 线程每 1s 定期兜底
  复查 reader, 状态收敛到真实 reader 状态。

### 3. 单次对焦扫描中被手动移镜打断 (577be69)

- **根因**: 触发单次对焦后 (临时 auto 扫描中) focus_auto 控件仍是 0,
  abs_event 条件仍成立 — 扫描中拖动 focus_absolute 会发 af-mode=0 +
  lens-position → IPA 扫描被强制打断 → 镜头停半路。
- **修复**: `af_scanning` 标志 — 触发时置 true (扫描中忽略 abs), 扫描
  完成回 manual 时置 false。官方语义: auto 扫描中 LensPosition 无效。

### 4. 粗扫次数 3→2 (5f3eb3c)

- `kMaxRescan` 2→1: 初始粗扫 1 + rescan 1 = 2 次粗扫。
- 精扫范围固定 ±51 (kFineRange 0.05 × 1023), 不随粗扫次数变化; 粗扫
  步长 ±20 偏差被 ±51 覆盖。正常场景无感知差异。

### 5. 移除 Start 兜底重发 (93d3721) — 二次触发扫描重启

- **根因**: 触发后 500ms 的 Start 兜底重发发出第二个 Start → IPA 每次
  收到 Start 都 startAutoScan → 扫描被自己重发重启 (刚扫一点又从头扫)。
- ENOBUFS retainControls 修复后 Start 可靠到达, 重发已无必要且有害。

### 6. 单次对焦超时 6s→12s (4253448) — 后撤销 (见下)

- 6s 固定超时 < IPA 完整扫描时长 (~12s) → 扫描中途强制回 manual →
  精扫从未执行。临时改为 12s, 最终被 AfState 官方检测替代 (见 7)。

### 7. AfState 官方完成检测替代固定定时回退 (d7d72d0) — 最终方案

- **用户要求**: 不要用定时回退 manual (时长不确定, 定时要么中断扫描
  要么用户等待)。定时回退是自创机制, 非官方语义。
- **官方机制**: libcamera 标准 AfState 控件 — IPA 扫描状态机实时输出
  (0=Idle 1=Scanning 2=Focused 3=Failed):
  ① IPA af.cpp: 状态机各分支 `metadata.set(AfState)` — manual→Idle,
     扫描中→Scanning, 锁定/稳定→Focused
  ② IPA ipu3.cpp: 声明 AfState 控件 (ControlInfo)
  ③ gst gen-gst-controls.py: AfState 加入 exposed_controls 白名单
     (上游未暴露此只读状态控件) → 生成 af-state 属性
  ④ router: 触发后 200ms 轮询 af-state 属性, 非 Scanning (完成) 即
     回 manual + 恢复 abs; 30s 超长兜底仅防 AfState 缺失死锁
- **验证**: 触发→完整扫描链 (粗扫×2+精扫, ~13s)→AfState=2 (Focused)
  → 立即回 manual。扫描完成瞬间回退, 无中断无等待。

### 8. AfState 完成时取消 30s 兜底计时器 (2333da7)

- **用户指出**: AfState 完成回 manual 后, 30s 兜底 timer 未取消 →
  仍在跑, 30s 后重复回 manual; 连续触发时旧 timer 干扰新扫描。
- **修复**: timer 句柄管理 — 触发时先取消旧 timer 再新建; AfState
  完成时 g_source_remove 取消兜底; 兜底执行时对称取消检测器。

### 9. 备份与归档 (d174640 + build-sources/)

- 最终版 IPA/gst 插件产物备份: `back_camera/backups/*.final-20260810`
  (dpkg 升级覆盖防护)。
- 最新构建树归档: `back_camera/build-sources/libcamera-orig.tar.gz`
  (含 AfState 全链源码 + build-new 生成代码, 重启不丢失)。
- 回滚用原版备份: `back_camera/backups/*.bak-*`。
- **dpkg 覆盖恢复**: 若 libcamera/gstreamer 包升级覆盖了补丁版插件:
  ```
  sudo cp back_camera/backups/ipa_ipu3.so.final-20260810 \
      /usr/lib/x86_64-linux-gnu/libcamera/ipa/ipa_ipu3.so
  sudo cp back_camera/backups/libgstlibcamera.so.final-20260810 \
      /usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstlibcamera.so
  systemctl --user restart ov5670-virtual-camera.service
  ```
- **源码重构建**: 归档 `build-sources/libcamera-orig.tar.gz` 解压 →
  `patched-sources/` 覆盖 5 个修改文件 (af.cpp/ipu3.cpp/
  gstlibcamerasrc.cpp/gstlibcamera-controls.cpp.in/gen-gst-controls.py)
  → `ninja -C build-new` 重编 → 安装。

### 10. 无应用时 continuous 对焦一直跑 (61121e6) — 停流根治

**用户实测**: 未运行任何相机应用时, OV5670 仍在 continuous 自动对焦
(镜头持续动作)。**按设计**: 无消费者应停流, 无帧 → IPA 不处理 → 不对焦。

**根因链 (三处)**:
1. `has_real_reader()` 把 **wireplumber 枚举 fd 算 reader** —
   wireplumber 是设备管理器, 打开 V4L2 设备只为枚举/探测, 从不消费流。
   其枚举周期与复查窗口碰撞 → 流被误激活 → continuous 对焦跑。
2. 复查 (inotify 600ms + 定期 1s) 是**单次快照即动作** — wireplumber
   短暂 fd 命中即激活; 频繁枚举则永不释放。
3. `deactivate` 设 cam_src **PAUSED 不停流** — libcamerasrc
   `PLAYING_TO_PAUSED` 转换不停 task (gstlibcamerasrc.cpp:993, 上游
   实现与 READY_TO_PAUSED 的 task_pause 不一致) + libcamera request
   循环继续 → **IPA 持续有帧** → 无应用也扫描。

**修复 (三处)**:
1. `has_real_reader()` 排除 wireplumber (`probe(WP)` 不算 reader)。
2. **reader_streak 连续判定**: ±3 (≈3s 一致) 才 activate/deactivate —
   inotify 复查 + 定期复查统一走 streak; 枚举探测 (短暂 fd) 达不到
   连续 → 不误激活。
3. deactivate/启动停流改 **READY** (camera 保持 open — NULL_TO_READY
   才 open — 但未 start → IPA 无帧); activate 用
   `gst_element_sync_state_with_parent` 恢复 (READY→PAUSED→PLAYING)。

**验证** (ad-hoc PASS=11 FAIL=0): 无应用 IPA 0 活动 + 0 激活; 起流
streak +3 激活 + IPA 对焦 (rescan/fine); 关闭 streak -3 释放 (READY)
+ IPA 停流。

**注意**: 释放延迟 ≈3s (streak 连续判定), 启动激活延迟 ≈3s — 设计
取舍, 换取枚举探测免疫。

## 验证

- 全链路: 触发 → AfMode/AfTrigger 到达 (ENOBUFS retainControls 保证)
  → auto 全范围粗扫 → confirm → rescan 上限 (粗扫 2 次) → 细扫 →
  锁定 → **AfState=Focused 官方检测完成回 manual** (无固定定时器)。
- 单次对焦完整性: 扫描链全程不被中断 — ①无 Start 重发重启 ②扫描中
  忽略手动移镜 (af_scanning) ③无定时器中途切走。
- continuous 静止稳定性: 0 误判重扫, rate 稳定 0.3-3% (阈值 40%);
  手动→continuous 切换先失焦判断 (连续 5 帧超阈值) 再决定重扫。
- **无应用停流**: 无消费者时 IPA 0 活动 + 0 激活 (wireplumber 枚举
  免疫 + streak 连续判定 + READY 停流); 起流 ~3s 激活, 关闭 ~3s 释放。
- 验证脚本归档: `docs/scripts/verification/` (ad-hoc, PASS=N FAIL=0 模式)。

## 相关文件

| 文件 | 说明 |
|---|---|
| `back_camera/ipa-patches/0001-af-ipu3.patch` | af.cpp 全部改动 (655 行) |
| `back_camera/ipa-patches/0002-af-ipu3-h.patch` | af.h 改动 (99 行) |
| `back_camera/scripts/ov5670-router.c` | router (触发/心跳/重发/busy 等待/写回/竞态修复) |
| `back_camera/scripts/ov5670-af-selfheal.sh` | 自愈脚本 (2026-08-09 晚已禁用: 版本统一后双保险无必要, 文件保留供参考) |
| `back_camera/scripts/ov5670-ensure-device.sh` | systemd ExecStartPre: 确保 /dev/video16 存在 |
| `back_camera/systemd/v4l2loopback-load.service` | **root 服务**: modprobe 命令加载 v4l2loopback (替代 modules-load.d, initramfs 根治核心) |
| `back_camera/systemd/ov5670-ec-fix.service` | exclusive_caps 自愈 (After v4l2loopback-load) |
| `back_camera/systemd/usb-camera-enhancement.conf.archived` | modprobe.d 配置归档 (含方案 A/引号版/清理版演进) |
| `back_camera/systemd/ov5670-virtual-camera-modules-load.conf.archived` | modules-load.d 归档 (v4l2loopback 已注释) |
| `/usr/src/v4l2loopback-0.15.4/v4l2loopback.c` | 模块源码 (AF 三控件无条件注册, 3091 行) |
| `back_camera/tuning/` | 画质调校资产 |
