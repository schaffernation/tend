# Tend's website

This folder is Tend's website, served at https://tend.schaffernation.com.
It's plain static files with no build step and no framework, so any static
host can serve the folder as is. It loads no third-party scripts, fonts, or
analytics.

- `index.html`, `style.css`, and `main.js` are the page.
- `manifest.webmanifest`, `favicon.ico`, `apple-touch-icon.png`, and the
  files in `images/` are the metadata that browsers and link previews read.
- `make-images.swift` makes the icons, the link preview image
  (`images/og.png`), and copies of the README screenshots from
  `app/AppIcon.png` and `docs/screenshot-*.png`. Run it again after you
  change the icon or the screenshots:

  ```
  swift site/make-images.swift
  ```

- `appcast.xml` is the Sparkle feed that installed copies of Tend check for
  updates. It doesn't exist until the first release. `app/appcast.sh` writes
  it; don't edit it by hand.

## The download button

The page reads `appcast.xml` to find the newest version. If the feed has a
release, the button downloads
`https://github.com/schaffernation/tend/releases/latest/download/Tend.dmg`
and shows the version and the minimum macOS version. If there's no feed, the
page says that Tend isn't released yet and links to the GitHub repository.
Without JavaScript, the button links to GitHub Releases. So the page needs
no edit when Tend ships a new version.

## Preview it

Serve the folder with Python, and open http://localhost:8000:

```
python3 -m http.server 8000 --directory site
```

To preview the download button for a release, put a sample `appcast.xml` in
a copy of the folder, and serve the copy. Don't commit a sample feed:
installed copies of Tend would read it.

## Deploy it

Pushing a change in `site/` to `main` deploys the site. That includes a new
`appcast.xml`, which installed copies of Tend see right away, so publish the
GitHub release before you push its feed. See "Build a release" in the
[README](../README.md#build-a-release).
