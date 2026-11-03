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
| mjh1234/seven7 | 35.64 MB | **80 MB（用户实测）** |
| eooce/nodejs-argo 系 | 91.5 MB + 首启下载 ~92 MB | ~110-150 MB |
| **tiny-argo:direct** | **11.67 MB** | **~35-45 MB（估算，待实测）** |

比 seven7 **小 67.3%**。

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
| `GOMEMLIMIT`（sing-box，默认 20MiB） | 压流量峰值，常驻省 ~3-8 MB |
| `GOGC=50` | 更快回收，代价是 GC 更勤、CPU 略升 |

`GOMEMLIMIT` 是软限制，官方建议容器场景额外留 5-10% headroom。若流量大导致 GC 抖动，调高它。

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
| `UUID` | 自动生成 | 节点 UUID |
| `PORT` | `3000` | sing-box 监听端口（平台注入的对外端口） |
| `HOST` | 自动探测 | 公网 IP，**建议手动指定**（探测用 ip-api.com，失败会退化成占位符） |
| `NAME` | `tiny` | 节点名称 |
| `GOMEMLIMIT` | `20MiB` | sing-box Go runtime 软内存预算（非 RSS 硬上限） |
| `GOGC` | `50` | GC 触发阈值（越小越省内存、越费 CPU） |
| `LOG_LEVEL` | `info` | sing-box 日志级别 |

## 部署

```bash
docker run -d --name tiny --restart always -p 3000:3000 \
  -e UUID=<你的UUID> -e HOST=<你的公网IP> \
  ghcr.io/<你的用户名>/tiny-argo:direct
```

节点链接打印在容器日志里：`docker logs tiny`。

Pterodactyl / Koyeb 等：把 `PORT` 设成平台分配的端口。

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
