# SOCKS5 代理管理脚本

支持 **Alpine / Debian / Ubuntu**，自动识别原生 IPv4 / 纯 IPv6 / WARP 环境。

## 一行运行

    bash <(curl -fsSL https://raw.githubusercontent.com/xxbb678/sk5-oneclick/main/sk5.sh)

> 使用 GitHub raw 直链，实时取最新版本。jsDelivr 等 CDN 有缓存，可能拉到旧脚本，不推荐。

或下载后执行：

    curl -fsSL https://raw.githubusercontent.com/xxbb678/sk5-oneclick/main/sk5.sh -o sk5.sh
    chmod +x sk5.sh && ./sk5.sh

## 菜单

    [1] 安装 SOCKS5
    [2] 查看节点链接
    [3] 更改监听端口
    [4] 重启服务
    [5] 卸载 SOCKS5
    [0] 退出脚本

## 安装参数

选 1 安装时依次询问，直接回车使用默认值：

- **端口** — 1-65535，直接回车自动生成随机端口（10000-65535，自动避开已占用）
- **用户名** — 字母数字与 `_ . @ -`，默认 `admin`
- **密码** — 自动生成 16 位随机密码

也可用环境变量 `SK5_PORT` / `SK5_USER` / `SK5_PASS` 预先指定，三项齐全时跳过交互直接安装。

## 命令行模式（不进菜单）

    sh sk5.sh install      # 安装
    sh sk5.sh show         # 查看节点信息
    sh sk5.sh uninstall    # 卸载

## 系统行为

| 系统 | 实现 |
|------|------|
| Debian / Ubuntu | 优先 dante-server；源中无 dante 时自动回退 microsocks |
| Alpine | dante-server（sockd） |

纯 IPv6 环境下同时生成 →IPv6 与 →IPv4 两条 socks pass 规则，避免 IPv4 目标不可达。

## 特性

- 按网卡逐个过滤，排除 WARP 与 docker0/br-/veth 等虚拟网卡，正确判定原生 IPv4 / 纯 IPv6
- 安装后自动认证自检，能捕获“端口通但用户不存在”这类故障
- 卸载不带参数时自动探测监听端口
- TG 链接中的用户名密码自动 URL 编码
- 管道方式（`curl ... | bash`）下自动进入安装，不进菜单

## IPv6 节点注意

服务器为 IPv6 时，TG 链接中的地址必须带方括号：

    tg://socks?server=[2001:db8::1]&port=1080&user=u&pass=p

客户端手动添加节点时，地址栏填写不带方括号的原始 IPv6。

## License

MIT