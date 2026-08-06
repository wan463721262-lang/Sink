# Sink 部署指南(Docker)

在任意 **Linux amd64** 云服务器上自托管 Sink 链接缩短器的完整操作手册。数据完全保存在服务器本地,不经过 Cloudflare。

## 架构

```
GitHub Actions(构建镜像)──► GHCR(ghcr.io/sangyu6666/sink:latest)──► 服务器 docker compose 拉取运行
```

- 镜像在 GitHub 上构建(需要 ~8GB 内存的 Nuxt 编译),**服务器不构建**,只拉取现成镜像。
- 运行方式是 Cloudflare workerd 的本地模式:D1(链接库)、KV(缓存)、R2(备份)都在本地模拟,数据落在 volume `sink-state`。
- 推送 `master` 会自动触发 CI 构建并更新 `latest` 标签;同时自动清理旧版本(保留最近 2 次构建)。

---

## 一、新机器部署

### 1. 安装 Docker

```bash
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
docker --version   # 确认已装
```

### 2. 拉代码并部署

```bash
git clone https://github.com/SangYu6666/Sink.git && cd Sink
./docker/deploy.sh password
```

示例里的 `password` 请换成你自己的强密码(≥ 8 字符),它就是后台登录密码。密码作为参数传入,不写入任何文件。

> 如果提示 `Permission denied`:先执行 `git pull`(会拉取 deploy.sh 的执行权限),再重跑上面的 deploy 命令;或临时用 `sh docker/deploy.sh password`。

### 3. 验证启动

```bash
docker compose ps           # 状态应为 running
docker compose logs -f sink # 看到 wrangler 监听 0.0.0.0:3000 即正常,按 Ctrl+C 退出
```

### 4. 首次使用

1. 浏览器打开 `https://your-domain.com/dashboard/links`
2. 用第 2 步传入的密码登录
3. 打开一次 **Dashboard → Links**(一次性初始化,KV→D1 迁移自动完成)

之后就能正常创建短链了。

> **⚠️ 必须用 HTTPS 访问(通过域名),不要用裸 IP + HTTP。** 直接用裸 IP 或 HTTP 访问时:
> - **复制链接功能不可用**(浏览器剪贴板 API 要求"安全上下文",HTTP 下不生效)
> - **刷新页面会 404**(SPA 前端路由需要正确的服务层回退)
> - 加上 CDN(如 EdgeOne)并申请证书、走 HTTPS 后即恢复正常。
> 这是预期行为,不是 bug。对外正式使用前请先配好 HTTPS(见下方"放到公网")。

---

## 二、日常维护

### 升级

```bash
cd ~/Sink
git pull                    # 拉新代码,触发 GitHub 自动重新构建镜像
./docker/deploy.sh password # 拉取新镜像并重启(数据在 volume 里,不受影响)
```

> 提示:CI 构建需要几分钟。如果 `git pull` 完立刻 deploy,拉到的是上一版镜像(无副作用);想立刻拿到最新版,等 GitHub Actions 构建完成后再次执行 deploy,或隔几分钟重跑一次。

### 回滚

把镜像指到某个历史版本标签(`sha-<提交号>` 保留最近 2 次构建):

```bash
echo 'SINK_IMAGE=ghcr.io/sangyu6666/sink:sha-<提交号>' > .env
./docker/deploy.sh password
```

### 换密码

```bash
./docker/deploy.sh <新密码>
```

---

## 三、备份

本地模式**没有定时任务**,云端部署的每日自动备份不会触发,必须自己做。

### 手动备份(整份数据快照)

```bash
docker run --rm -v sink-state:/data -v "$PWD":/backup \
  alpine tar czf /backup/sink-state-$(date +%F).tar.gz -C /data .
```

### 每天自动备份(cron)

```bash
crontab -e
# 加入一行(每天凌晨 3:05 备份,保留到 /root/backups):
5 3 * * * cd /root/Sink && docker run --rm -v sink-state:/data -v /root/backups:/backup alpine tar czf /backup/sink-state-$(date +\%F).tar.gz -C /data . 2>/dev/null
```

> 注意 cron 里 `%` 要写成 `\%`。恢复时:`docker run --rm -v sink-state:/data -v "$PWD":/backup alpine tar xzf /backup/sink-state-<日期>.tar.gz -C /data`,然后 `docker compose restart sink`。

---

## 四、数据迁移(旧机器 → 新机器)

两种方式:

**方式 A:只搬短链列表(推荐日常用)**
1. 旧机器 Dashboard → **Links → 导出**(JSON)
2. 新机器 Dashboard → **导入**这个文件

**方式 B:整机搬移(含缓存、统计、备份档案)**
1. 旧机器执行上面的 volume 备份命令,得到 `sink-state-<日期>.tar.gz`
2. 拷到新机器,执行恢复命令(见上),然后 `docker compose restart sink`
3. 新机器的 `NUXT_SITE_TOKEN` 建议设成和旧机器一致(否则原链接的密码保护会不同)

---

## 五、配置

| 项 | 方式 |
| --- | --- |
| 登录密码 `NUXT_SITE_TOKEN` | 部署时作参数传入,不落盘 |
| 可选运行配置(统计、首页跳转、跳转码等) | 复制 `docker/.env.example` 为 `.env` 后编辑,再重新 deploy |
| 镜像地址 | compose 默认已是 `ghcr.io/sangyu6666/sink:latest`;要换可在 `.env` 设 `SINK_IMAGE` |
| 构建期配置(`NUXT_PUBLIC_*`) | 需要在 CI 的 build-args 里改,一般不用动 |

常用可选配置见 `docker/.env.example`。

---

## 六、常见问题

| 现象 | 处理 |
| --- | --- |
| `Permission denied` | `git pull` 拉取执行权限,或临时用 `sh docker/deploy.sh password` |
| `docker compose pull` 拉取失败 | 检查 `.env` 里 `SINK_IMAGE` 是否正确(镜像在 `ghcr.io/sangyu6666/sink`,必须全小写) |
| 端口访问不了 | 云控制台安全组/防火墙放行 3000 端口 |
| 复制链接不可用 / 刷新页面 404(HTTP 裸 IP 访问时) | 预期行为:必须走 HTTPS。加 CDN(如 EdgeOne)+ 证书,或 Caddy/Nginx 反代 + TLS 后正常 |
| 想对外提供 HTTPS | Caddy/Nginx 反代到 `127.0.0.1:3000` + 自动证书;或把 EdgeOne 源站指向服务器 3000 端口 |
| 登录报错 | 确认密码与部署时传入的一致;改密码直接重新 deploy |
| CI 里"Prune old GHCR versions"步骤失败 | 需要在 GHCR 包设置页把包关联到仓库(一次性),不影响部署 |

---

## 七、相关

- 镜像封装细节:`docker/README.md`
- 反向代理、EdgeOne 加速配置:见本仓库根 `README.md`
