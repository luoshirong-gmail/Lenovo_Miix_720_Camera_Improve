# 合并过程记录 (P0–P7) — 2026-08-08

## 合并决策（用户审批）

1. **范围**: 仅两个会话的功能产出 — 前置 RGB 增强 (20260805_230625_26d388) +
   后置 OV5670 虚拟摄像头 (20260806_154617_97ac43)
2. **排除**: IR 摄像头项目、ov5670_autofocus 对焦项目（已回滚）、
   Final_Patches 内核补丁包（归另一主板硬件驱动项目）、MOK 密钥资产
3. **服务架构**: 两个摄像头功能保持**两个独立 systemd 服务**分别开发维护
4. **配置**: 系统级共享配置统一一套 (modprobe.d/modules-load.d/refresh),
   项目内专属配置各归各
5. **旧目录**: `USB_Camera_Enhancement` 与 `Lenovo_Miix_720_Camera` 保留只读,
   不删除任何内容, 作为历史备份存档
6. **GitHub**: 不配置 remote、不推送, git 仅本地版本管理
7. **前提**: 本项目只做功能提升, 硬件驱动由另一项目保证

## 执行明细

### P0 备份
- 基线快照 → `docs/pre-merge-baseline.md` (2026-08-08 01:18)
- USB 项目 git 工作区干净 (最新 183fbff), ov5670_universalization 非 git 仓库

### P1 骨架
- 目录结构 + `git init -b main` (本地)
- 注: 首次 git init 不完整 (缺 HEAD), 已重建

### P2 迁移
- `front_camera/` ← USB_Camera_Enhancement, **git subtree add 保留完整历史**
  (usb-source/main, 3 提交 + v1.0.0 tag)
- `back_camera/` ← ov5670_universalization (非 git, 直接复制 + 本文件溯源)
- 补丁脚本归集到 `common/v4l2loopback-patches/`
- ec-fix service/sh 归集到 `common/config/`

### P3 统一补丁链 — 关键发现
- 4 处补丁脚本合并 → `common/v4l2loopback-patches/apply_all.py`
  (幂等, 顺序固化: D-1 → HERMES → MIN-3 → IMAGE-ON-DEMAND)
- **坑 1**: 旧 D-1 脚本 old 文本含 `announce_all_caps` (针对 0.15.3/更早版本),
  官方 0.15.4 的 fixed 行是 `keep_format || has_other_owners` 单行 — 已修正
- **坑 2**: 旧 HERMES 脚本 anchor 写单 tab, 官方 0.15.4 release_token 是
  **双 tab** (对齐缩进) — 已修正 (用 `cat -A` 实测确认)
- **坑 3**: `/usr/src/v4l2loopback-0.15.4/v4l2loopback.c.orig-official` 命名误导
  (实为 D-1 v3 中间态), 权威测试用官方 GitHub tag tar 包
- 验证: 官方干净源码 → 4 补丁全部应用 ✅; 幂等复测 ✅; 与系统源码关键区域 diff 一致 ✅

### P4 统一系统配置
- `common/config/v4l2loopback-modprobe.conf` — 单 conf 合并两项目参数
  (exclusive_caps=0 + max 尺寸 + max_buffers=16 + card_label + video_nr=99)
- `common/config/v4l2loopback-modules-load.conf` — 单文件 (仅模块名)
- `common/wireplumber-refresh.sh` — 参数化 ($1=videoN), 取 ov5670 版
  "仅病态时重启"逻辑 (正常零副作用不打断音频)
- ⚠️ 未实际替换系统 /etc/ 配置 (P4 产出模板, 部署策略见下)

### P5 服务路径迁移
- 两 service 文件改写 → 新项目路径, ExecStartPost 统一用参数化 refresh
- 系统服务文件备份 → `docs/backup-20260808/`
- 部署到 ~/.config/systemd/user/ + daemon-reload + 重启
- **坑 4**: 首次重启 203/EXEC — 二进制不存在 (编译时 `cd` + gcc 管道 head
  吞掉真实退出码, `$?` 取到的是 head 的 0)。教训: 编译必须看 gcc 直接退出码,
  不能经管道取 $?; 重编译后二进制就位
- 编译产物: front `pipeline/camera-router` (27256B), back `scripts/ov5670-router` (26576B)
  (仅原有 -Wrestrict/-Wformat-truncation 警告, 无新增)

### P6 验证 (与 P0 基线对照, 全部通过 ✅)
| 项 | 基线 (P0) | 现状 (P6) |
|---|---|---|
| camera-enhancement.service | active | active (PID 15387, 新路径) |
| ov5670-virtual-camera.service | active | active (PID 15390, 新路径) |
| video99 出流 | NV12 1080p | 5/5 帧 ✅ |
| video16 格式 | NV12 2560×1920 | 一致 ✅ |
| Video/Source 节点 | video99+video16+前摄 | 一致 ✅ (无 CAM6) |
| 51-CAM6 屏蔽 | 在位 | 在位 ✅ |
| wireplumber | 音频不受影响 | refresh 脚本实测"无需处理"零副作用 ✅ |

## 遗留事项 / 后续建议

1. **系统 /etc 配置统一** (P4 模板已就绪未部署): 当前系统仍是两个 modprobe.d conf
   (字母序覆盖机制, 功能正常)。是否替换为单 conf 需单独审批 — 涉及 /etc 写入,
   且当前工作状态无冲突, 非合并必需
2. **ec-fix 服务** (common/config/): 系统已装 /usr/local/sbin/ov5670-ec-fix.sh +
   /etc/systemd/system/ov5670-ec-fix.service, 路径不依赖项目目录, 未改动
3. **front_camera README** 仍指向旧 GitHub (usb-camera-enhancement), 子 README
   未改写 — 不影响功能, 待后续统一
4. **编译产物未入 git** (front 的 camera-router 二进制被 .gitignore 忽略,
   back 的 ov5670-router 二进制建议加入 .gitignore) — 保持源码为准的工程习惯

## 补充: video99 第二次打开失败修复 (2026-08-08)

### 症状
重启后 Snapshot 首次打开 video99 正常, 关闭后再打开报错 (not-negotiated),
pipewire 日志: `can't allocate enough buffers 2 < 3` / `negotiate buffers: -12`。

### 根因 (与 ov5670 Phase 20/22 同款机制)
1. 增强链 gldownload 输出带 jpegdec 残留的 `multiview-flags` 字段,
   idle 链 (videotestsrc) 无此字段 → selector 切换 active-pad 时 caps 变化
2. v4l2sink 重建 buffer pool, 受 enhance queue `max-size-buffers=2` 限制缩到 2
3. 增强链激活时 reader 在场 → MIN-3 补丁条件 `!has_other_owners` 不满足 → 不触发
   → `used_buffer_count=2` 残留 (实测 REQBUFS(3)→2)
4. 第二次打开 PipeWire 请求 3 → 被压到 2 → "2 < 3" → -12 → not-negotiated

### 修复 (commit: fix(video99): 第二次打开失败)
1. **兜底**: enhance queue `max-size-buffers` 2→4 (重建后仍 ≥3)
2. **根治**: 新增 `make_full_caps()` 统一构造 caps (multiview-mode=mono,
   multiview-flags=0, pixel-aspect-ratio=1/1, interlace-mode=progressive 全字段),
   三处 capsfilter 同用: idle 链 / 增强链 (新增 capsfilter 元素, enhance_chain[8],
   enhance_count 8→9) / selector→sink → 两条链 caps 完全一致 → 切换零重建
   (前置验证: gst-launch 实测两条链都能强制 multiview-flags=0, 协商成功)

### 验证 (全部通过)
- 连续 3 轮打开/关闭 (v4l2-ctl 5帧×3) 全部成功
- 每轮关闭后 REQBUFS(3) → **实际分配 3** (修复前=2)
- 真实画面非黑屏 (Y 方差 3136)
- 增强链 9 元素激活/释放循环正常
- 待用户实测: Snapshot 连续开关 3 次

### 回退
回退包: `docs/rollback-20260808-video99-buffers/` (源码 .c.bak + 二进制 .bin.bak
+ service 备份 + git HEAD)。git 也有提交点可 `git revert`/`git checkout`。
