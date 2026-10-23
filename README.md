# nuwa-mainline

Xiaomi 13 Pro（nuwa / SM8550）主线 Linux 移植。

- 双系统：保留原厂 HyperOS
- 发行版：Ubuntu 26.04 + GNOME
- 首版范围：启动 + 显示 + 触控 + USB 网络 + Wi-Fi/蓝牙 + 音频

## 结构

| 目录 | 内容 |
|---|---|
| kernel/ | 内核构建入口（上游主线 + 板级补丁） |
| rootfs/ | Ubuntu 26.04 GNOME 根文件系统构建脚本 |
| tools/ | 打包、安装、切换、测试脚本 |
| docs/ | 构建、安装、开发文档 |

> 私有数据（序列号、MAC、备份、校准）不入库。
