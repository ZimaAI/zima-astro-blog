# Zima Astro Blog 二次开发指南

本项目基于 [Astro Theme Pure](https://github.com/cworld1/astro-theme-pure)，保留原项目提交历史和 Apache-2.0 许可证。

## 仓库与分支

- `origin`：https://github.com/ZimaAI/zima-astro-blog.git（自己的仓库，提交推送到这里）。
- `upstream`：https://github.com/cworld1/astro-theme-pure.git（主题更新来源）。
- `main`：稳定版本。
- `develop`：日常开发分支。
- `feat/功能名`：从 `develop` 创建的独立功能分支。

初始化机器的 `origin` 使用 HTTPS 拉取、SSH 推送，复用已有的 ZimaAI SSH 身份。如果在其他机器上也需要这种配置，可运行 `git remote set-url --push origin git@github.com:ZimaAI/zima-astro-blog.git`，并确保该机器已配置 GitHub SSH 登录。

新电脑克隆后，需自行添加 upstream：

```bash
git clone https://github.com/ZimaAI/zima-astro-blog.git
cd zima-astro-blog
git switch develop
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

## 从哪些文件开始改

| 需求 | 位置 |
| --- | --- |
| 标题、作者、语言、菜单、社交链接、评论 | `src/site.config.ts` |
| 首页内容和结构 | `src/pages/index.astro`、`src/components/home/` |
| 关于、项目、友链页面 | `src/pages/about/`、`src/pages/projects/`、`src/pages/links/` |
| 公共布局、文章布局 | `src/layouts/` |
| 页面组件、SEO 元信息 | `src/components/`、`src/components/BaseHead.astro` |
| 全局样式 | `src/assets/styles/global.css`、`src/assets/styles/app.css` |
| UnoCSS 配置 | `uno.config.ts` |
| 博客、文档内容 | `src/content/blog/`、`src/content/docs/` |
| 内容字段与校验规则 | `src/content.config.ts` |
| 头像、图片、图标 | `src/assets/`、`public/` |
| 域名、部署方式、Astro 集成 | `astro.config.ts` |

建议先改站点信息、首页和样式，再逐步替换示例内容。上线前将 `astro.config.ts` 的 `site` 替换为真实访问域名；导航、友链申请信息、社交链接和示例备案信息也需要逐项调整。评论默认连接主题的演示 Waline 服务，应配置自己的服务，或将 `integ.waline.enable` 设为 `false`。

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
git switch develop
git pull --ff-only origin develop
git switch -c feat/customize-home
# 修改文件并完成验证
npm run build
git add <本次修改的文件>
git commit -m "feat: customize homepage"
git push -u origin feat/customize-home
```

在 GitHub 创建 PR，将功能分支合入 `develop`。验证稳定后，再创建 `develop` → `main` 的 PR。小改动也可以直接提交并推送到 `develop`。

当前 `astro.config.ts` 配置了 Vercel adapter 和 `output: 'server'`。推送到 GitHub 仅上传代码，并不会自动发布网站；当前构建结果也不能直接当作通用静态站点上传。接入 Vercel 时可选择 `main` 为生产分支；若选择 GitHub Pages、其他静态托管或自建 Node 服务，需要先调整相应的输出模式与 adapter，再验证构建和预览方式。

## 同步原主题更新

在工作区干净时，从开发分支建立专门的同步分支：

```bash
git switch develop
git pull --ff-only origin develop
git fetch upstream
git switch -c chore/sync-theme
git merge upstream/main
# 如有冲突，处理后 git add 对应文件，再 git commit
npx --yes bun@1.3.11 install --frozen-lockfile
npm run build
git push -u origin chore/sync-theme
```

通过 PR 合入 `develop`。如果自己也修改过依赖且合并后锁文件不一致，需要先协调 `package.json`，再不带 `--frozen-lockfile` 安装以更新锁文件，并将其提交。主题模板更新与 npm `astro-pure` 版本更新是两件事，合并时都要检查。保留原许可证及必要的版权声明。
