# Public website

The project website is a buildless static page in `site/`, published at
<https://jedbjorn.github.io/anj-cloud/> through GitHub Pages. It has no JavaScript,
external fonts, analytics, package installation, server secrets, or deployment
profile. Relative asset links work under the `/anj-cloud/` project path.

## Publishing

In the public `jedbjorn/anj-cloud` repository, set **Settings → Pages → Source** to
**GitHub Actions**. The `Public website` workflow validates relevant pull requests;
on `main` it uploads only `site/` and deploys with the `github-pages` environment.
`workflow_dispatch` also publishes the current `main` branch. Deployment jobs are
guarded to this repository and `main`; forks and pull requests only validate.
There are no personal tokens or custom secrets to configure.

The package job has read-only repository permissions. Only the deploy job gets
`pages: write` and `id-token: write`. Actions use the official
[upload-pages-artifact](https://github.com/actions/upload-pages-artifact) and
[deploy-pages](https://github.com/actions/deploy-pages) actions.

## Editing and checking

Edit `site/index.html` and `site/styles.css`. Run:

```sh
python3 tool/check_site.py
git diff --check
```

The check verifies local asset paths, project-path compatibility, section anchors,
linked source documents and headings, image descriptions/dimensions, and the
absence of active HTML/SVG content or external assets. It does not replace browser
layout, assistive technology, or public-link availability checks.

For local preview, serve the repository root and open `/site/` (or mount `site/`
under `/anj-cloud/` to exercise the production URL prefix). Follow the seat's
preview policy and stop any preview process you start.

## Content and assets

- `assets/anj-cloud.svg` is the existing Harbor app icon, copied from
  `apps/client/assets/branding/harbor/icon.svg`.
- `assets/household-cloud.svg` is an original explanatory illustration, not a
  screenshot. Its tiny library is illustrative.
- The three PNGs are unchanged copies of public, synthetic demo images in
  `docs/images/`: Android library, desktop sharing, and macOS admin users. Their
  example accounts and files do not depict a real household.
- Screenshots and graphics are served locally and use the repository's license.

Keep platform availability, installer limits, and the trust model aligned with
`README.md`, `docs/clients.md`, and `docs/self-hosting/quickstart.md`. In particular,
do not imply end-to-end encrypted storage, an official Windows binary, implemented
inference access, or backup setup on the generic quick-start path.
