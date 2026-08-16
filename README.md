# Newifi D2 OpenWrt Build

这是一个用于自动化编译 Newifi D2 固件的 OpenWrt 仓库。

## 构建目标

- 设备：Newifi D2
- 源码：OpenWrt `master`
- 配置文件：`newifi3.config`
- GitHub Actions 工作流：`.github/workflows/newifi3.yml`

## 自动化构建

GitHub Actions 会在相关文件变更后触发固件编译，包括：

- `newifi3.config`
- `feeds.conf.default`
- `DIY/` 下的自定义脚本
- `Scripts/` 下的本地构建脚本
- `.github/workflows/newifi3.yml`

也可以在 GitHub Actions 页面手动运行 `NEWIFI 3` 工作流。

## 本地构建

在支持 OpenWrt 编译依赖的 Linux 环境中，可以使用 `Scripts/` 目录下的本地构建脚本进行编译。

脚本会拉取 OpenWrt `master`，应用仓库中的 feeds、配置和 DIY 脚本，然后开始编译。

## 默认设置

- 默认 LAN IP：`192.168.2.1`
- 默认 Hostname：`Newifi-D2`
- 固件产物路径：`openwrt/bin/targets/ramips/mt7621`

## Geo 数据与空间保护

- 固件内置经过校验的完整 GeoIP/Geosite 只读兜底，开机后复制到 `/tmp` 使用。
- 在线更新只写入 RAM；下载或校验失败时继续使用兜底数据，不占用 overlay。
- 更新会避开 PassWall2 订阅、规则更新和线路切换，并在连接异常时自动回滚和熔断重启。
- Newifi D2 镜像构建上限设为 30100 KiB，为配置和 overlay 元数据保留空间。

## 致谢

本仓库的自动化构建流程参考了 [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)。
