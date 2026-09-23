# 本机部署：aboutme.zimagent.top

Astro 输出静态文件，由本机已有 Nginx 按域名提供服务。GitHub Actions 在 GitHub 托管的 runner 上构建，通过 SSH 上传，每次推送 `main` 自动发布，也可在 Actions 页面手动运行。无需 Docker、自托管 runner 或常驻 Node 服务。

## 隔离范围

| 资源       | 本项目专用值                                        |
| ---------- | --------------------------------------------------- |
| 域名       | `aboutme.zimagent.top`                              |
| 发布账号   | `aboutme-deploy`（不授予 sudo 权限）                |
| 发布目录   | `/var/www/zima-astro-blog`                          |
| Nginx 站点 | `/etc/nginx/sites-available/zima-astro-blog`        |
| Nginx 片段 | `/etc/nginx/snippets/zima-astro-blog.conf`          |
| 证书       | `/etc/letsencrypt/live/aboutme.zimagent.top/`       |
| 日志       | `/var/log/nginx/zima-astro-blog.{access,error}.log` |

复用 Nginx 的 80/443 端口，只增加域名虚拟主机，不设置 `default_server`。不修改其他项目、数据库、容器或证书。初始化前检查域名冲突，Nginx 配置通过 `nginx -t` 后才 reload。日常发布只切换软链接，无需 reload Nginx。

## 首次初始化（本机终端）

域名 A 记录应指向本机公网 IP（检查时为 `36.151.151.229`）；如果配置了 AAAA，必须指向同一台可通过 IPv6 访问的服务器。公网需要能访问 80/443 和 SSH 22。本机已经安装 Nginx、Certbot、rsync，并有可复用的 ACME 账号。

本次配置已在 `/home/zima/.ssh/` 生成独立密钥 `aboutme-actions`、公钥 `aboutme-actions.pub` 和从本机 SSH 公钥生成的 `aboutme-known-hosts`。它们不在 Git 仓库内，不要提交私钥。

```bash
cd /home/zima/Develop/Projects/zima-astro-blog
# 本次已完成构建；更新源代码后需重新执行。
npx --yes bun@1.3.11 install --frozen-lockfile
SITE_URL=https://aboutme.zimagent.top npm run build

sudo bash deploy/setup-server.sh /home/zima/.ssh/aboutme-actions.pub
```

脚本创建专用账号与目录、安装首个构建、启用 HTTP、通过 Certbot webroot 申请独立证书，最后启用 HTTPS。使用既有 Certbot 账号；证书续期的 deploy hook 会先验证再 reload Nginx。如果申请证书失败，HTTP 站点保留以便排查，修复 DNS/防火墙后可重跑。重跑不会替换当前已发布版本。

Nginx 平滑重载需要短暂切换工作进程，初始化脚本会重试 HTTPS 验证并核对版本号，全程校验证书。如果旧版脚本在最后一步出现 `curl: (60)`，先执行 `curl -fsS https://aboutme.zimagent.top/deploy-version.txt`；若正常返回版本号，说明站点已经就绪，无需重新申请证书。Certbot 输出的 `Hook 'deploy-hook' ran with error output` 若仅包含 Nginx 的 `syntax is ok` 和 `test is successful`，只是成功检查信息写入了标准错误流；新版 hook 使用 `nginx -t -q` 避免这类提示。

新机器上需要自行生成密钥：`ssh-keygen -t ed25519 -N '' -f ~/.ssh/aboutme-actions`，并根据该服务器真实 SSH 主机公钥重新制作 known_hosts，不能直接信任网络扫描得到的陌生公钥。

## GitHub Secrets（手动一次）

打开 [仓库 Actions Secrets 设置](https://github.com/ZimaAI/zima-astro-blog/settings/secrets/actions)，添加以下两个 **Repository secrets**：

| 名称                 | 值                                                              |
| -------------------- | --------------------------------------------------------------- |
| `DEPLOY_SSH_KEY`     | `/home/zima/.ssh/aboutme-actions` 的完整内容，包含 BEGIN/END 行 |
| `DEPLOY_KNOWN_HOSTS` | `/home/zima/.ssh/aboutme-known-hosts` 的完整内容                |

在自己的终端读取并粘贴到 GitHub；不要把私钥发到聊天或写入仓库。workflow 固定连接 `aboutme.zimagent.top:22`，账号为 `aboutme-deploy`，严格验证主机公钥。

可先在本机验证专用账号：

```bash
ssh -i ~/.ssh/aboutme-actions -o IdentitiesOnly=yes \
  -o UserKnownHostsFile=~/.ssh/aboutme-known-hosts -o StrictHostKeyChecking=yes \
  aboutme-deploy@aboutme.zimagent.top 'test -w /var/www/zima-astro-blog && echo ready'
```

将本次配置提交、推送到 `main` 后，在 [Actions 页面](https://github.com/ZimaAI/zima-astro-blog/actions/workflows/deploy.yml) 查看 `Deploy blog`。后续每次 push 自动构建部署。工作流使用 `production` environment；若你自行为它设置了审批规则，需要按规则批准发布。

## 验证与回退

```bash
curl -I https://aboutme.zimagent.top
curl -fsS https://aboutme.zimagent.top/deploy-version.txt
systemctl list-timers --all | grep certbot
# 仅测试本项目证书的自动续期
sudo certbot renew --cert-name aboutme.zimagent.top --dry-run
```

发布先检查首页、404、RSS、站点地图、robots、Pagefind 和静态资源，再将 `current` 原子切换到 `releases/<运行编号>-<重试次数>-<commit>`。本机通过 HTTPS 校验版本号，失败会恢复原软链接；Actions 随后从公网再校验一次。公网校验失败会标记工作流失败，本机版本保持此前通过本机检查的状态。

手动回退：

```bash
ls /var/www/zima-astro-blog/releases
sudo -u aboutme-deploy bash deploy/release.sh <已有版本目录名>
```

`assets/` 保留历史带哈希资源，避免旧页面在发布后丢失资源。发布目录也保留供回退；定期查看磁盘空间，确认无需回退后删除不用的历史 release，切勿删除 `current` 指向的目录。首次初始化前的工作区 `dist/` 不参与后续线上服务。

参考：[Astro 静态输出](https://docs.astro.build/en/reference/configuration-reference/#output)、[GitHub 部署工作流](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/control-deployments)。
