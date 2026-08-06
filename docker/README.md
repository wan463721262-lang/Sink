# Sink 自托管 Docker 部署

把 Sink(Cloudflare 链接缩短器)打包成 Docker 镜像,部署在任何 **Linux amd64 / arm64** 云服务器上。**数据完全保存在本地容器 volume 中,不经过 Cloudflare**(除非你主动配置了 Cloudflare 统计)。

## 工作原理

镜像在 Cloudflare 的 **workerd 运行时**上以本地(miniflare)模式运行构建好的 worker,和项目自带的本地开发/自托管方式一致(`wrangler dev` + 去掉了 `ai` 绑定的配置)。D1(链接数据库)、KV(缓存)、R2(备份/图片)、Analytics 都由本地模拟,状态落在 `/app/.wrangler`(已挂载为 volume)。

## 推荐流程:GitHub Actions 构建 → GHCR → 服务器拉取

Nuxt 构建需要 ~8GB 内存,别在云服务器上构建。仓库已带 `.github/workflows/docker.yml`:推 `master`(或打 `v*` tag)时自动在 GitHub 上构建并推到 GHCR(`ghcr.io/<你的GitHub名>/sink:latest`),服务器只负责拉取运行。

### 一次性配置

1. 把仓库推到你的 GitHub(推 `master` 即触发第一次构建)。构建约 10–20 分钟,可在 Actions 页面看进度。
2. **如果你的仓库是私有**,GHCR 镜像默认也是私有,服务器拉取需要登录:
   ```bash
   docker login ghcr.io -u <你的GitHub名> -p <GitHub Personal Access Token>
   # 或在 docker/README 之外给服务器配置 docker 凭据;更省事的是在 GHCR 页面把镜像设成 public
   ```
   公开仓库无需登录。
3. 服务器上(密码作为参数传入,不落盘):
   ```bash
   ./docker/deploy.sh <你的强密码>      # 密码就是后台登录密码(>= 8 字符)
   ```
   想改其它可选配置,再 `cp docker/.env.example .env` 编辑后重新执行 deploy 即可。
4. 打开 `http://<服务器IP>:3000/dashboard/links`,用刚才的密码登录,打开一次链接页完成一次性初始化。

### 升级

```bash
git pull                    # 拉新代码,触发 GitHub 重新构建
./docker/deploy.sh <你的强密码>   # 拉取新镜像并重启(数据在 volume 里,不受影响)
```

回滚:临时改 `docker-compose.yml` 里 `SINK_IMAGE` 的默认值(或写一个 `.env` 设 `SINK_IMAGE=ghcr.io/<GitHub名>/sink:sha-<commit>`)指向旧版本再部署。

## 备选:在服务器上本地构建(需 ~8GB 内存)

不用 CI 时,直接用仓库里的构建 override 在服务器上构建:

```bash
export NUXT_SITE_TOKEN=<你的强密码>    # 密码同样不落盘,部署时传入
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
# 国内网络慢/被墙时加镜像源:
docker compose -f docker-compose.yml -f docker-compose.build.yml build --build-arg REGISTRY=https://registry.npmmirror.com
```

## 首次使用

1. 打开 `http://<服务器IP>:3000/dashboard/links`
2. 用部署时传入的 `NUXT_SITE_TOKEN` 密码登录
3. 打开一次 **Dashboard → Links**(一次性存储初始化,KV→D1 迁移会自动完成;新实例 KV 为空,瞬间完成)

## 数据与备份

- **所有数据**都在 volume `sink-state`(`/app/.wrangler` 下的本地 SQLite D1 + KV + R2 模拟)。迁移/重建容器前先备份它:
  ```bash
  docker run --rm -v sink-state:/data -v "$PWD":/backup alpine tar czf /backup/sink-state-$(date +%F).tar.gz -C /data .
  ```
- 本地模式下**没有定时任务**,云端部署的每日自动备份(Workers cron)不会触发。请定期手动在 Dashboard 的备份页面导出,或按上面的命令备份 volume。

## 放到公网

`wrangler dev` 是开发模式而非加固的生产服务器。对外提供服务时,建议在前面加一层反向代理并启用 HTTPS(如 Caddy / Nginx / 你已有的 EdgeOne):

- Caddy 一行即可:把 `link.syyc.fun` 反代到 `127.0.0.1:3000`,自动签发证书。
- 若用 EdgeOne 等 CDN 加速,把源站指向服务器的 `3000` 端口即可。

## 运行时配置

**密码**(`NUXT_SITE_TOKEN`)通过部署命令传入(`./docker/deploy.sh <密码>`),不写在 `.env` 里。其它 `NUXT_*` 可选配置放进 `.env`(`cp docker/.env.example .env`)后由容器注入,写入 `wrangler dev` 读取的 `.dev.vars`。完整列表见项目根目录 `.env.example`。

**注意区分两类配置:**

| 类型 | 变量 | 何时生效 |
| --- | --- | --- |
| 运行时(随便改) | `NUXT_SITE_TOKEN`(部署参数)、`NUXT_HOME_URL`、`NUXT_LINK_CACHE_TTL`、`NUXT_REDIRECT_*`、`NUXT_CASE_SENSITIVE`、`NUXT_CF_ACCOUNT_ID` 等 | 改后重新 `./docker/deploy.sh <密码>` 即可 |
| 构建时(需重新构建) | `NUXT_PUBLIC_PREVIEW_MODE`、`NUXT_PUBLIC_SLUG_DEFAULT_LENGTH`、`NUXT_PUBLIC_KV_BATCH_LIMIT` | 内联进前端 bundle,须通过构建参数传(GHCR 流程下改 CI 里的 build-args 或本地 `--build-arg`) |

## 与 Cloudflare 版部署的区别 / 限制

- **数据、跳转完全在本地**,不经过 Cloudflare。适合国内服务器/自建场景。
- **用法统计(Analytics)** 默认为空。若想用 Cloudflare 的统计,在 `.env` 设置 `NUXT_CF_ACCOUNT_ID` + `NUXT_CF_API_TOKEN`(此时会有对 Cloudflare GraphQL API 的**外呼**)。
- **AI 生成短链/OG 描述** 不可用(本地没有 `ai` 绑定,相关接口返回 501)。
- 服务器重启后容器自动重启(`restart: unless-stopped`);数据在 volume 里,不受影响。

## 镜像内容与体积

多阶段构建,`runtime` 层复制了构建产物 `.output` 和完整 `node_modules`(包含 wrangler + workerd 及打包的依赖),以保证本地模拟运行时零外部下载、行为与项目自托管一致。镜像偏大(1 GB+ 量级)但可靠;后续可按需裁剪。
