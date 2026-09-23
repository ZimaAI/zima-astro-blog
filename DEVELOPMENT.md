# Zima Astro Blog 二次开发指南

本项目基于 [Astro Theme Pure](https://github.com/cworld1/astro-theme-pure)，保留原项目提交历史和 Apache-2.0 许可证。

## 仓库与分支

- `origin`：https://github.com/ZimaAI/zima-astro-blog.git（自己的仓库，提交推送到这里）。
- `upstream`：https://github.com/cworld1/astro-theme-pure.git（主题更新来源）。
- `main`：唯一开发与发布分支，日常修改、主题同步和提交推送都直接在此分支完成。

本项目为个人项目，采用单分支工作流。

初始化机器的 `origin` 使用 HTTPS 拉取、SSH 推送，复用已有的 ZimaAI SSH 身份。如果在其他机器上也需要这种配置，可运行 `git remote set-url --push origin git@github.com:ZimaAI/zima-astro-blog.git`，并确保该机器已配置 GitHub SSH 登录。

新电脑克隆后，需自行添加 upstream：

```bash
git clone https://github.com/ZimaAI/zima-astro-blog.git
cd zima-astro-blog
git switch main
git remote add upstream https://github.com/cworld1/astro-theme-pure.git
```

## 本地启动

使用 Node.js 22.12+ 的受支持偶数版本（本次初始化环境为 Node.js 24）。项目已有 `bun.lock`，建议保持使用 Bun，避免混用包管理器生成多个锁文件。

如果已安装 Bun：

```bash
bun install --frozen-lockfile
bun run dev
```

没有全局 Bun 时，可通过 npm 临时运行 Bun：

```bash
npx --yes bun@1.3.11 install --frozen-lockfile
npm run dev
```

打开 http://localhost:4321。修改页面和样式后开发服务器会自动更新。

```bash
npm run check   # Astro / TypeScript 检查
npm run build   # 主题环境检查、类型检查和生产构建
```

`npm run lint` 和 `npm run format` 会修改文件，运行后检查差异再提交。

### 在 VS Code 中启动

1. 安装上述版本的 Node.js（包含 npm），然后在 VS Code 中打开项目根目录 `zima-astro-blog`。
2. 按提示安装工作区推荐的 Astro 和 MDX 扩展。
3. 在“运行和调试”中选择 `Astro: 本地开发`，按 `F5` 启动，或按 `Ctrl+F5` 启动而不调试。

启动前会自动执行 `Astro: 安装依赖`，通过 `npx --yes bun@1.3.11 install --frozen-lockfile` 安装或检查依赖，无需全局安装 Bun。首次运行需要联网下载依赖。开发服务器启动后自动打开浏览器，默认地址为 http://localhost:4321；若端口被占用，以终端显示和浏览器打开的实际地址为准。修改源码后页面会自动更新，按 `Shift+F5` 停止调试启动的服务器。

也可以通过“终端 → 运行任务”选择 `Astro: 开发服务器`、`Astro: 检查` 或 `Astro: 构建`；开发服务器任务可在终端中按 `Ctrl+C` 停止。`Ctrl+Shift+B` 执行默认构建任务。

配置位于 `.vscode/launch.json` 和 `.vscode/tasks.json`，使用 VS Code [内置 Node.js 调试器](https://code.visualstudio.com/docs/nodejs/nodejs-debugging)。

## 从哪些文件开始改

| 需求                                          | 位置                                                        |
| --------------------------------------------- | ----------------------------------------------------------- |
| 个人资料、教育经历、技术栈、GitHub 和项目链接 | `src/data/profile.ts`                                       |
| 站点描述、语言、菜单、评论等集成配置          | `src/site.config.ts`                                        |
| 首页内容和结构                                | `src/pages/index.astro`、`src/components/home/`             |
| 关于、项目页面                                | `src/pages/about/`、`src/pages/projects/`                   |
| 公共布局、文章布局                            | `src/layouts/`                                              |
| 页面组件、SEO 元信息                          | `src/components/`、`src/components/BaseHead.astro`          |
| 全局样式                                      | `src/assets/styles/global.css`、`src/assets/styles/app.css` |
| UnoCSS 配置                                   | `uno.config.ts`                                             |
| 博客文章                                      | `src/content/blog/`                                         |
| 原主题示例和文档（不发布）                    | `docs/theme-examples/`                                      |
| 内容字段与校验规则                            | `src/content.config.ts`                                     |
| 头像、图片、图标                              | `src/assets/`、`public/`                                    |
| 博客域名                                      | `.env` 或部署环境中的 `SITE_URL`，参见 `.env.example`       |
| 部署方式、Astro 集成                          | `astro.config.ts`                                           |

站点已按 `docs/aboutme/aboutme.md` 改造成奇码的个人博客；后续修改共享资料时编辑 `src/data/profile.ts`。原主题的示例文章和文档已移至 `docs/theme-examples/`，不会发布为博客内容或 `/docs` 页面。

上线前在部署环境中设置 `SITE_URL` 为博客的真实访问地址；本地可复制 `.env.example` 为 `.env` 后填写。`astro.config.ts` 从中读取站点地址，未配置时使用 `http://localhost:4321`。规范链接、RSS、站点地图和分享元信息依赖此设置。示例备案信息已移除，Waline 评论已关闭；如需评论，请配置自己的服务后再开启 `integ.waline.enable`。

`astro-pure` 当前是 npm 依赖。虽然仓库包含 `packages/pure/`，直接修改该目录不会自动改变站点使用的依赖。普通定制优先在 `src/` 完成；若需要修改主题底层，可把根 `package.json` 中的 `astro-pure` 改为 `file:./packages/pure`，重新运行 `bun install`（或 `npx --yes bun@1.3.11 install`），同时提交依赖声明和锁文件，再验证构建。不要直接编辑 `node_modules/`。

## 写文章

可以运行 `npm run pure -- new` 使用交互式命令，也可以创建 `src/content/blog/hello-world.md`：

```markdown
---
title: '我的第一篇文章'
description: '记录博客二次开发的开始'
publishDate: 2026-09-21
tags: ['Astro', '博客']
draft: false
---

这里是正文。
```

标题、描述、发布日期为必填字段；可使用 `.mdx` 在文章中加入组件。

## 日常开发与发布

```bash
git switch main
git pull --ff-only origin main
# 修改文件并完成验证
npm run build
git add <本次修改的文件>
git commit -m "feat: customize homepage"
git push origin main
```

日常修改在 `main` 上完成，验证后直接提交并推送到 `origin/main`。

当前 `astro.config.ts` 使用 `output: 'static'`。完成 [本机部署说明](./deploy/README.md) 中的一次性初始化和 GitHub Secrets 设置后，推送 `main` 会触发 `.github/workflows/deploy.yml`，在 GitHub 构建静态站点，通过专用 SSH 账号发布到本机独立目录，由已有 Nginx 提供 **https://aboutme.zimagent.top** 服务。

## 同步原主题更新

在工作区干净时，直接在 `main` 上合并原主题更新：

```bash
git switch main
git pull --ff-only origin main
git fetch upstream
git merge upstream/main
# 如有冲突，处理后 git add 对应文件，再 git commit
npx --yes bun@1.3.11 install --frozen-lockfile
npm run build
git push origin main
```

如果自己也修改过依赖且合并后锁文件不一致，需要先协调 `package.json`，再不带 `--frozen-lockfile` 安装以更新锁文件，并将其提交。验证通过后推送到 `origin/main`。主题模板更新与 npm `astro-pure` 版本更新是两件事，合并时都要检查。保留原许可证及必要的版权声明。
