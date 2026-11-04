# tiny-argo

极小的 sing-box VLESS-WS 节点镜像（**direct 直连版，无隧道**）。基于 `scratch`，
零解释器、零运行时下载、单进程常驻。

专为按内存计费的平台设计：能省的内存全靠**砍进程**——本镜像只跑一个 sing-box，
不跑 cloudflared、不跑 shell、不跑任何解释器。

## 体积（GHCR 实测，非估算）

| tag | amd64 | arm64 | 层数 |
|---|---|---|---|
| `latest` / `direct` | **11.666 MB**（压缩拉取） / 30.03 MB（落盘） | 10.871 MB | 4 |

逐层（amd64，pull / disk）：

| 层 | pull | disk |
|---|---|---|
| sing-box 1.9.5 | 10.938 MB | 28.875 MB |
| busybox.static | 0.626 MB | 0.980 MB |
| ca-certificates | 0.100 MB | 0.174 MB |
| entrypoint.sh | 0.002 MB | 0.005 MB |

对比参照：

| 镜像 | 体积 | 常驻内存 |
|---|---|---|
| mjh1234/seven7 | 35.64 MB | **80 MB（实测）** |
| eooce/nodejs-argo 系 | 91.5 MB + 首启下载 ~92 MB | ~110-150 MB |
| **tiny-argo:direct** | **11.67 MB** | **20 MB 空闲 / 40 MB 满载（实测）** |

比 seven7 **小 67.3%**，内存降 **50%~75%**。

实测数据来自 Railway 平台（2026-11），配置 `GOMEMLIMIT=64MiB` + `GOGC=100`：
平时约 20 MB，跑满带宽时峰值约 40 MB。早期用 `20MiB`+`GOGC=50` 时空闲能压到 **9 MB**，
但大流量下 GC 连续触发、吞吐明显下降——**省内存和要速度在这条线上是互相冲突的，按需取舍**。

## 内存：要说实话

**常驻内存的大头是二进制本身被 mmap 进物理内存的页，不是 Go 堆。**

- 反推 seven7 的 80 MB：sing-box ~40 MB + cloudflared ~31 MB（有生产环境实测 RSS 记录） + bash ~3 MB + 零头
- sing-box 1.9.5 ELF 段：RX 13.66 MB、rodata 14.53 MB、RW 0.91 MB，合计 29.10 MB 虚拟映像

`GOMEMLIMIT` 按 Go 官方定义是 **Go runtime 记账内存的软预算**（`Sys - HeapReleased`），
**不覆盖** mmap 的二进制代码/rodata、cgo/off-heap、OS 页表等；空闲且堆很小时 GC 可能根本不活动，
堆还有 4 MiB 下限。所以它对**流量峰值**有效（防止堆膨胀），对**空闲常驻**帮助有限，大概省 3-8 MB。

结论很清楚：**真正省内存的是砍进程**。本镜像相比 seven7 省掉的是 cloudflared（~31 MB）
和常驻 bash（~3 MB），这是全部收益来源。

## 内存调优

| 手段 | 效果 |
|---|---|
| 不跑 cloudflared（本镜像已如此） | **省 ~31 MB（最有效）** |
| `GOMEMLIMIT`（默认 64MiB） | 控制流量峰值时的堆膨胀 |
| `GOGC`（默认 100） | 调低更省内存，代价是 GC 更频繁、吞吐下降 |

**两组实测配置的取舍**（Railway，上午空闲 / 满载时各测一次）：

| 配置 | 空闲 | 满载 | 体感 |
|---|---|---|---|
| `GOMEMLIMIT=20MiB` + `GOGC=50` | **9 MB** | — | 网速拉不起来，GC 抖动严重 |
| `GOMEMLIMIT=64MiB` + `GOGC=100` | **20 MB** | **40 MB** | **正常，推荐** |

结论：`20MiB` 对 sing-box 转发行情太紧——堆一到上限就连续 GC，CPU 全耗在回收上。
如果平台按内存计费、且能接受 20 MB 起步，用默认值即可；只有极度在意空闲内存时才降到
`GOMEMLIMIT=20MiB GOGC=50`，并接受速度损失。

`GOMEMLIMIT` 是软限制（不覆盖二进制 mmap 页），容器内存上限建议设为它的 1.5~2 倍。

## 部署后自己实测

```bash
# 容器总占用（含页缓存，数值偏大）
docker stats --no-stream tiny

# 真实 RSS（scratch 里 PID 1 就是 sing-box）
docker exec tiny /bin/busybox cat /proc/1/status | grep VmRSS
docker exec tiny /bin/busybox ps
```

以 `VmRSS` 为准，别看 `docker stats` 的 MEM USAGE。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `UUID` | 自动生成 | 节点 UUID。**PaaS 上务必手动固定**，否则每次重新部署都会变，客户端链接失效 |
| `PORT` | `3000` | sing-box 监听端口 |
| `HOST` | 自动探测 | 对外地址，**必须手动指定**（探测走 ip-api.com，在 PaaS 上拿到的是出口 IP，一定错） |
| `PUBLIC_PORT` | 同 `PORT` | 对外端口。转发型平台（Railway TCP Proxy）外部端口 ≠ 容器端口时用它 |
| `TLS_DOMAIN` | 空 | 平台的 HTTPS 域名。填了会额外打印一条 `NODE-TLS:` 链接（443 + TLS + WS） |
| `NAME` | `tiny` | 节点名称 |
| `GOMEMLIMIT` | `64MiB` | Go runtime 软内存预算（非 RSS 硬上限） |
| `GOGC` | `100` | GC 触发阈值（越小越省内存、越费速度） |
| `LOG_LEVEL` | `warn` | sing-box 日志级别。**别用 `info`**——每个连接都写 stdout，高并发时日志 I/O 会拖慢吞吐 |

## 部署

```bash
docker run -d --name tiny --restart always -p 3000:3000 \
  -e UUID=<你的UUID> -e HOST=<你的公网IP> \
  ghcr.io/<你的用户名>/tiny-argo:direct
```

节点链接打印在容器日志里：`docker logs tiny`。

Pterodactyl 等有公网端口的平台：把 `PORT` 设成平台分配的端口即可。

### Railway（无公网 IP）

Railway 有**两种入口**，可以同时开、互为备用：

| 入口 | 地址形态 | 特点 |
|---|---|---|
| **HTTP 域名 + TLS**（推荐） | `xxx.up.railway.app:443` | 走 CF 类边缘、**实测明显更快**，流量是标准 HTTPS，伪装好 |
| **TCP Proxy** | `xxx.proxy.rlwy.net:NNNNN` | 裸 TCP 转发，延迟稳定但吞吐一般；免费版只给 1 个 |

**部署步骤**

1. New Service → **Docker Image** → `ghcr.io/<用户名>/tiny-argo:direct`
2. **Variables 填 5 个**（缺一个链接就是错的）：

   | 变量 | 值 |
   |---|---|
   | `PORT` | `3000`（**必须手设**，否则平台注入的端口会和你的网络配置打架） |
   | `UUID` | 自己固定一个，别留空 |
   | `LOG_LEVEL` | `warn` |
   | `HOST` / `PUBLIC_PORT` | TCP Proxy 的域名与**对外**端口 |
   | `TLS_DOMAIN` | HTTP 域名的 host（不含 `https://` 和端口） |

3. Healthcheck Path **留空**（纯 TCP/WS 服务，HTTP 探活会一直失败）
4. Settings → Networking：
   - **TCP Proxy** → 目标端口填 `3000` → 拿到 `域名:端口` → 回填 `HOST`/`PUBLIC_PORT`
   - **HTTP 域名** → 端口填 `3000`（**不是 8080**）→ 域名回填 `TLS_DOMAIN`
5. 重新部署，日志里会出现两条链接，`NODE-TLS:` 那条通常更快

**踩坑清单**

| 现象 | 原因 | 修法 |
|---|---|---|
| 日志里链接的主机是 `xxx.up.railway.app:3000`，连不上 | HTTP 域名**只在 443 提供 TLS**，不开 3000；且明文 `security=none` 进不去 | 用 `NODE-TLS:` 那条（443 + `security=tls` + `alpn=http/1.1`） |
| 日志出现 `bad path: /xxx` | 客户端 UUID 与 `UUID` 变量不一致（变量没生效 → 服务端自生成） | 以日志打印的 UUID 为准固定下来 |
| WS 握手返回 **400 Bad Request** | 链接带 `?ed=2048`（early data），部分客户端与 sing-box 的 `Sec-WebSocket-Protocol` 解析冲突 | 去掉 `ed=2048`，本镜像生成的链接已默认不带 |
| 域名访问超时 / 502 | 域名目标端口填的是 `8080`、`20241` 之类的旧值 | 改成 `3000` |
| 偶尔第一次连接失败或卡几秒 | Railway **Serverless** 闲置 5~10 分钟后休眠，唤醒有冷启动，首次请求可能 502 | 见下方保活；或升级 Hobby 计划关闭 Serverless |

**关于 Serverless 休眠**

Railway 官方口径：**按「出站流量」判定活跃**，停止发包 5 分钟后标记 inactive，实际 5~10 分钟入睡；
收到任何流量即唤醒。所以**正常用节点时不会睡**，只有闲置才睡，睡了反而省钱（不收内存费）。

免费/试用计划**无法关闭**该功能。要保活就用外部定时器打自己的 HTTPS 域名
（如 cron-job.org，间隔 **4 分钟**；返回 404 也算活跃，因为容器有出站响应包）。
UptimeRobot 免费版最短 5 分钟，正好卡在阈值边缘，可能仍会睡。

> Cloudflare 优选 IP 串在这条链路前面意义有限：它只优化「你→CF」这一跳，
> 而真正的瓶颈是「CF→Railway（境外）」；且 CF 免费版对 WebSocket 有 **100 秒空闲超时**（不可调）。

## 关于 sing-box 版本

默认锁定 **1.9.5**（与 seven7 相同）。原因：sing-box 从 1.12 起改为 CGO 构建，
musl 静态变体压缩后从 11 MB 膨胀到 31 MB，镜像会直接超 40 MB。
1.9.5 是最后一个纯 Go 静态发布线，对 VLESS-WS 场景功能完整。

如需升级：Actions 手动触发（workflow_dispatch）填 `sing_box_version`，
或改 Dockerfile 的 `SING_BOX_VERSION`，注意体积会变大。

## 自动构建

1. push 到 `main` 后 Actions 自动构建 `direct` + `latest` 并推到 GHCR（amd64 / arm64）
2. **首次构建后**：仓库右侧 Packages → 该镜像 → Package settings → Change visibility → **Public**（否则部署平台拉不到）

```bash
cd tiny-argo
git init -b main
git add .
git commit -m "tiny-argo: minimal sing-box node image (direct)"
git remote add origin https://github.com/<你的用户名>/tiny-argo.git
git push -u origin main
```

## 许可

sing-box (GPL-3.0) 二进制再分发请遵守其协议。
