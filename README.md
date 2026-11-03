# tiny-argo

极小的 sing-box VLESS-WS 节点镜像。基于 `scratch`，零解释器、零运行时下载，内存占用用 `GOMEMLIMIT` 强制压制。

专为按内存计费的平台设计。

## 两个 tag

| tag | 内容 | 镜像体积 | 常驻内存（估） | 用途 |
|---|---|---|---|---|
| `latest` / `direct` | sing-box + busybox | **~12 MB** | **~20-25 MB** | 有公网端口，直连 |
| `argo` | 上面 + cloudflared | **~30 MB** | **~50-60 MB** | 无公网端口，走 Cloudflare 隧道 |

对比参照：

| 镜像 | 体积 | 常驻内存（实测/估） |
|---|---|---|
| mjh1234/seven7 | 35.64 MB | ~80 MB（实测） |
| eooce/nodejs-argo 系 | 91.5 MB + 首启下载 ~92 MB | ~110-150 MB |
| **tiny-argo:direct** | **~12 MB** | **~20-25 MB** |
| **tiny-argo:argo** | **~30 MB** | **~50-60 MB** |

内存数字为估算：`GOMEMLIMIT` 让 Go 运行时把堆压在限额附近（sing-box 20 MiB、cloudflared 32 MiB），
代价是高流量时 GC 更频繁、CPU 略升。对单用户节点完全可接受。流量大时可在环境变量里调高。

## 内存原理

1. **进程最少**：direct 模式只有一个进程（entrypoint exec 成 sing-box，shell 不常驻）。
2. **GOMEMLIMIT**：Go 1.19+ 的软内存上限。sing-box 默认 idle RSS 25-40 MB，压到 ~20 MB；cloudflared 默认 35-45 MB，压到 ~30 MB。
3. **不用 argo 就关掉它**：`argo` tag 加 `DISABLE_ARGO=true` 等于 direct 模式（但镜像里仍带 cloudflared 文件，不占内存只占磁盘）。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `UUID` | 自动生成 | 节点 UUID |
| `PORT` | `3000` | sing-box 监听端口（平台注入的对外端口） |
| `HOST` | 自动探测 | direct 模式的公网 IP（探测失败时手动指定） |
| `NAME` | `tiny` | 节点名称 |
| `ARGO_DOMAIN` | 空 | 固定隧道域名（与 ARGO_AUTH 同填启用固定隧道） |
| `ARGO_AUTH` | 空 | 固定隧道 token |
| `CFIP` / `CFPORT` | 空 / `443` | 优选 IP/域名，argo 模式下替换链接中的连接地址 |
| `DISABLE_ARGO` | `false` | `true` = 完全不启动 cloudflared |
| `GOMEMLIMIT` | `20MiB` | sing-box 内存上限 |
| `CF_GOMEMLIMIT` | `32MiB` | cloudflared 内存上限 |
| `GOGC` | `50` | GC 触发阈值（越小越省内存、越费 CPU） |
| `LOG_LEVEL` | `info` | sing-box 日志级别 |

## 部署

```bash
# direct：有公网端口
docker run -d --name tiny --restart always -p 3000:3000 \
  ghcr.io/<你的用户名>/tiny-argo:direct

# argo：临时隧道（trycloudflare）
docker run -d --name tiny --restart always \
  ghcr.io/<你的用户名>/tiny-argo:argo

# argo：固定隧道
docker run -d --name tiny --restart always \
  -e ARGO_DOMAIN=xxx.example.com -e ARGO_AUTH=<tunnel-token> \
  ghcr.io/<你的用户名>/tiny-argo:argo
```

节点链接打印在容器日志里：`docker logs tiny`。

Pterodactyl / Koyeb 等：设置 `PORT` 为平台分配的端口，镜像按上述 tag 选择即可。

## 关于 sing-box 版本

默认锁定 **1.9.5**（与 seven7 相同）。原因：sing-box 从 1.12 起改为 CGO 构建，
musl 静态变体压缩后从 11 MB 膨胀到 31 MB，镜像会直接超 40 MB。
1.9.5 是最后一个纯 Go 静态发布线，对 VLESS-WS + argo 场景功能完整。

如需升级：Actions 手动触发（workflow_dispatch）填 `sing_box_version`，
或改 Dockerfile 的 `SING_BOX_VERSION`，注意体积会变大。

## 首次发布 / 自动构建

1. 把本目录推到 GitHub 仓库（例如 `tiny-argo`）
2. push 到 `main` 后 Actions 自动构建两个 tag 并推到 GHCR
3. **首次构建后**：仓库右侧 Packages → 该镜像 → Package settings → Change visibility → **Public**（否则部署平台拉不到）
4. 每周二自动重建，跟进 cloudflared 最新版（sing-box 版本固定不动）

```bash
cd tiny-argo
git init -b main
git add .
git commit -m "tiny-argo: minimal sing-box + cloudflared image"
git remote add origin https://github.com/<你的用户名>/tiny-argo.git
git push -u origin main
```

## 许可

sing-box (GPL-3.0) 与 cloudflared (Apache-2.0) 的二进制再分发请遵守各自协议。
