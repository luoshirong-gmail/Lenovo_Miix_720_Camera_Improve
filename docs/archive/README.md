# docs/archive — 历史排查存档

本目录存放历史排查过程中的中间产物与工具，**非项目交付物**。

| 文件 | 说明 | git 状态 |
|---|---|---|
| `ipu3-still-cam0-stream0-000299.bin` | IPU3 OV5670 原始抓帧数据 (7.3MB) — 分析画质用 | **不入库** (根 .gitignore `docs/archive/*.bin`) |
| `min_sel_test.c` / `min_sel_test2.c` / `min_sel_test3.c` | 最小选区测试程序 (min selection 排查) | 已入库 |

- `.bin` 为原始数据 (大文件)，git 忽略规则有效（从未被提交，勿 `git add -f`）。
- `.c` 分析工具已入库供查阅；二进制产物 `min_sel_test*` 在 back_camera/.gitignore 忽略。
