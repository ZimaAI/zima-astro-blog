# Zima's Blog

English | [简体中文](./README-zh-CN.md)

奇码's personal blog, covering AI application development, Java backend development and software engineering. Built with Astro and [Astro Theme Pure](https://github.com/cworld1/astro-theme-pure).

The site includes a personal homepage, articles, archives, projects, an about page, search and RSS. Personal information comes from [docs/aboutme/aboutme.md](./docs/aboutme/aboutme.md); shared site data lives in [src/data/profile.ts](./src/data/profile.ts).

## Local development

Use a supported even-numbered Node.js version, 22.12 or later. Keep the existing Bun lockfile when installing dependencies.

```sh
bun install --frozen-lockfile
bun run dev
```

Without a global Bun installation:

```sh
npx --yes bun@1.3.11 install --frozen-lockfile
npm run dev
```

Open [localhost:4321](http://localhost:4321).

```sh
npm run check
npm run build
```

## Customize and write

| Content                                                 | Location                                                           |
| ------------------------------------------------------- | ------------------------------------------------------------------ |
| Name, education, skills, GitHub and project link        | `src/data/profile.ts`                                              |
| Site metadata, navigation and integrations              | `src/site.config.ts`                                               |
| Homepage, about page and projects                       | `src/pages/index.astro`, `src/pages/about/`, `src/pages/projects/` |
| Blog posts                                              | `src/content/blog/`                                                |
| Original theme examples, kept out of the published site | `docs/theme-examples/`                                             |
| Icons and social sharing image                          | `public/favicon/`, `public/images/social-card.svg`                 |

Create a `.md` or `.mdx` file in `src/content/blog/` with this frontmatter:

```markdown
---
title: 'My first post'
description: 'A short introduction to this post'
publishDate: 2026-09-21
tags: ['Astro']
draft: false
---

Write your post here.
```

## Deployment

Copy `.env.example` to `.env` for local configuration, or set `SITE_URL` in the deployment environment to the blog's real public URL. This controls canonical URLs, RSS, the sitemap and social sharing metadata. Without it, the site uses `http://localhost:4321`.

The project uses `output: 'static'` and is served by the existing Nginx instance at **https://aboutme.zimagent.top**. After the one-time server and GitHub Secrets setup, pushes to `main` build and deploy through GitHub Actions. A dedicated user, release directory and virtual host isolate the blog from other projects; failed local health checks restore the previous release. See the [deployment guide](./deploy/README.md). Waline comments are disabled until a personal comment service is configured.

See [DEVELOPMENT.md](./DEVELOPMENT.md) for VS Code setup, the existing Git workflow and theme updates.

## Credits and license

Based on [Astro Theme Pure](https://github.com/cworld1/astro-theme-pure). The original theme attribution and [Apache-2.0 license](./LICENSE) are retained.
