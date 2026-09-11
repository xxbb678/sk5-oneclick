# SOCKS5 代理一键搭建脚本

支持 **Alpine / Debian / Ubuntu**，自动识别原生 IPv4 / 纯 IPv6 / WARP 环境，安装时交互输入端口、用户名、密码。

## 一行安装

    sh <(curl -fsSL https://cdn.jsdelivr.net/gh/xxbb678/sk5-oneclick@main/sk5.sh)

或下载后执行：

    curl -fsSL https://cdn.jsdelivr.net/gh/xxbb678/sk5-oneclick@main/sk5.sh -o sk5.sh
    sh sk5.sh

## 使用

    # 安装（交互输入参数）
    sh sk5.sh

    # 卸载
    sh sk5.sh uninstall

    # 非交互（环境变量指定）
    SK5_PORT=1080 SK5_USER=user SK5_PASS='pass' sh sk5.sh

## 参数说明

安装时依次询问，直接回车使用默认值：

- **端口** — 1-65535，默认 `21461`
- **用户名** — 字母数字与 `_ . @ -`，默认 `admin`
- **密码** — 自动生成 16 位随机密码

也可用环境变量 `SK5_PORT` / `SK5_USER` / `SK5_PASS` 预先指定，三项齐全时跳过交互。

## 系统行为

| 系统 | 实现 |
|------|------|
| Debian / Ubuntu | 优先 dante-server；源中无 dante 时自动回退 microsocks |
| Alpine | dante-server（sockd） |

纯 IPv6 环境下同时生成 →IPv6 与 →IPv4 两条 socks pass 规则，避免 IPv4 目标不可达。

## 特性

- 按网卡逐个过滤，排除 WARP 与 docker0/br-/veth 等虚拟网卡，正确判定原生 IPv4 / 纯 IPv6
- 安装完成后清屏并在顶部重印节点信息与 TG 链接（用户名密码已 URL 编码）
- 卸载带端口释放验证
- 管道方式（`curl ... | sh`）下从 /dev/tty 读取输入，无终端时自动回退默认值

## 已验证

- Debian 13 x86_64，纯 IPv6 + WARP 环境：安装、代理连通、卸载全链路正常
- Alpine 分支逻辑同源，未实机验证

## License

MIT
