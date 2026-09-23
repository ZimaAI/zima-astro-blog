# Zima's Blog

[English](./README.md) | 简体中文

奇码的个人博客，记录 AI 应用开发、Java 后端与软件工程的学习和实践。基于 Astro 和 [Astro Theme Pure](https://github.com/cworld1/astro-theme-pure) 构建。

站点包含个人首页、文章、归档、项目、关于页面，以及搜索和 RSS。个人资料来源为 [docs/aboutme/aboutme.md](./docs/aboutme/aboutme.md)，共享信息集中在 [src/data/profile.ts](./src/data/profile.ts)。

## 本地运行

使用 Node.js 22.12 或以上的受支持偶数版本。安装依赖时沿用仓库已有的 Bun 锁文件。

```sh
bun install --frozen-lockfile
bun run dev
```

没有全局 Bun 时：

```sh
npx --yes bun@1.3.11 install --frozen-lockfile
npm run dev
```

打开 [localhost:4321](http://localhost:4321)。检查和构建命令：

```sh
npm run check
npm run build
```

## 修改资料与写文章

| 内容                                      | 位置                                                               |
| ----------------------------------------- | ------------------------------------------------------------------ |
| 姓名、教育经历、技术栈、GitHub 和项目链接 | `src/data/profile.ts`                                              |
| 站点元信息、导航与集成配置                | `src/site.config.ts`                                               |
| 首页、关于和项目页面                      | `src/pages/index.astro`、`src/pages/about/`、`src/pages/projects/` |
| 博客文章                                  | `src/content/blog/`                                                |
| 保留供开发参考、不发布到站点的主题示例    | `docs/theme-examples/`                                             |
| 图标和社交分享图原稿                      | `public/favicon/`、`public/images/social-card.svg`                 |

在 `src/content/blog/` 中创建 `.md` 或 `.mdx` 文件，填写以下文章信息：

```markdown
---
title: '我的第一篇文章'
description: '这篇文章的简短介绍'
publishDate: 2026-09-21
tags: ['Astro', '学习记录']
draft: false
---

这里是正文。
```

## 部署配置

本地可将 `.env.example` 复制为 `.env`，部署时在托管平台设置 `SITE_URL` 为博客的真实访问地址。规范链接、RSS、站点地图和社交分享元信息都使用该值；未配置时默认使用 `http://localhost:4321`。

项目使用 `output: 'static'`，由本机 Nginx 提供服务，公网地址为 **https://aboutme.zimagent.top**。完成一次性服务器初始化和 GitHub Secrets 设置后，推送 `main` 即通过 GitHub Actions 自动构建、上传和发布。独立目录、专用账号和域名虚拟主机避免与本机其他项目冲突；健康检查失败自动回退。详细步骤见 [本机部署说明](./deploy/README.md)。Waline 评论已关闭，配置自己的评论服务后再开启。

VS Code 启动方式、现有 Git 工作流和主题更新方法见 [DEVELOPMENT.md](./DEVELOPMENT.md)。

## 来源与许可

基于 [Astro Theme Pure](https://github.com/cworld1/astro-theme-pure) 改造，保留原主题署名和 [Apache-2.0 许可证](./LICENSE)。
