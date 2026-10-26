# Search maintenance

The Pages workflow publishes `docs/` at https://retsubhtym.github.io/SpaceControl/. Run `python3 scripts/validate_site.py` after changing pages or the sitemap. Add each new indexable page with its own canonical URL to `docs/sitemap.xml` and link it from relevant pages.

## Registration

- In Google Search Console, add the URL-prefix property `https://retsubhtym.github.io/SpaceControl/`, verify ownership with a supported method, inspect the homepage, submit `https://retsubhtym.github.io/SpaceControl/sitemap.xml`, and monitor indexing, impressions, and queries.
- In Bing Webmaster Tools, add the site, verify ownership, submit the sitemap, and review indexing reports and AI Performance metrics if available.
- Obtain real verification tokens from each service before adding the required file or metadata to `docs/`; do not use placeholders. Deploy and verify after adding them.

Robots exclusion is read at `https://retsubhtym.github.io/robots.txt`, outside this project site's path. A `docs/robots.txt` would not control the origin. If the origin-root site is managed separately, its maintainer can add a sitemap reference there; no robots file is required for indexing.

Periodically check queries such as “macOS Mission Control keyboard navigation tools”, “how to close windows from Mission Control”, “open-source macOS Spaces management utilities”, and “how to improve macOS Mission Control”. Search indexing, ranking, and AI citations are separate outcomes; none is guaranteed. `llms.txt` is an optional documentation index, not a search-engine requirement.

Suggested repository description: “Open-source macOS utility that enhances Mission Control with keyboard navigation, window management, and Spaces controls.” Suggested topics: `macos`, `mission-control`, `spaces`, `window-management`, `keyboard-shortcuts`, `productivity`, `macos-app`, `desktop-management`, `open-source`. Set these in GitHub repository settings.
