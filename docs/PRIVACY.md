# 隐私与本机数据

[简体中文](PRIVACY.md) · [English](PRIVACY.en.md)

## 功能如何处理数据

- 截图和 GIF 使用本机屏幕捕获；文字识别使用系统 Vision 框架。
- 截图历史、缩略图、GIF 与用户导出文件保存在本机。
- 系统监控读取 CPU、内存、网络接口计数、磁盘信息和进程信息；统计网络吞吐不需要读取网页或抓取网络内容。
- 当前 Meridian 宿主未接入账户、截图上传、云端识字或遥测上传服务。
- 网络详情中的“出口公网 IP”由用户打开网络详情时按需请求 `api.ipify.org`；该服务会收到请求方出口 IP。查询结果只缓存在本机内存中，不会上传到项目服务器。
- 管理员助手用于本机显示覆盖和风扇寄存器写入。

监控库内还保留可选的公网 IP 归属地查询实现；嵌入的 Meridian 宿主不使用该归属地功能。

## 默认存储位置

| 数据 | 位置 |
| --- | --- |
| 截图历史、索引和缩略图 | `~/Library/Application Support/ScreenshotLab/History/` |
| 快速保存目录 | 默认 `~/Pictures/ScreenshotLab/`，可在截图页更改 |
| 主应用偏好 | UserDefaults 域 `app.meridian.control`（为兼容旧版本继续保留） |
| 模块偏好 | `app.meridian.control.capture`、`.pointer`、`.display`、`.thermal` |
| 风扇控制状态文件 | `~/Library/Application Support/FanControlLab/desired.json` |
| 显示覆盖助手的请求与结果 | `~/Library/Application Support/DisplayLab/` |

开发时可以通过环境变量覆盖部分数据目录；已有本地版本也可能保留自定义路径。以应用设置与实际文件为准。

## 清理和反馈

截图历史和导出文件可能包含密码、聊天内容或个人资料。删除应用不会自动删除这些数据，用户导出的副本也不受历史数量限制控制。

卸载前先恢复系统风扇和原生显示，移除管理员服务并退出应用，再决定是否删除上述本机文件。不要在服务运行时随意删除它的状态文件。

反馈时请先检查日志、截图和诊断报告中的用户名、路径、进程名称及屏幕内容。
