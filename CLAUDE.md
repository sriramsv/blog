# blog — Claude Code Instructions

Personal blog at [blog.sriramsv.com](https://blog.sriramsv.com), built with Hugo and the
PaperMod theme, deployed via GitHub Pages.

## Stack

- **Generator**: Hugo (extended), config in `hugo.toml`
- **Theme**: [PaperMod](https://github.com/adityatelange/hugo-PaperMod), vendored as a git
  submodule at `themes/PaperMod` — don't edit files under this path directly, they'll be lost on
  submodule update. Override via `layouts/` at the repo root instead.
- **Hosting**: GitHub Pages, custom domain `blog.sriramsv.com` (see `static/CNAME`)
- **Deploy**: `.github/workflows/deploy.yml` — builds and publishes on every push to `master`

## Writing posts

```
hugo new content posts/<slug>.md
```

Set `draft = false` in the front matter before it'll appear in the build (drafts are excluded
from production builds).

## Local preview

```
hugo server -D
```

## DNS

The `blog.sriramsv.com` CNAME record lives in the `IAC` repo
(`terraform/cloudflare/main.tf`, `cloudflare_dns_record.blog`), managed via OpenTofu — not in
this repo. It's currently unproxied (DNS-only, grey cloud) so GitHub can issue and renew the
Let's Encrypt cert for the custom domain; don't flip it to proxied without first confirming
GitHub's HTTPS enforcement is stable.

## Notes

- This repo previously deployed via Netlify (`netlify.toml`, since removed) — GitHub Pages is
  the current and only deploy target.
