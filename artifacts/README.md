# Artifact sources

The HTML behind the two published write-ups, kept in the repo so they can be
edited and re-published rather than rebuilt from memory.

| file | published at |
|---|---|
| `platform-lab-architecture.html` | <https://claude.ai/code/artifact/33a25fb7-fda8-46b5-a4ce-b1cb09a33130> |
| `gitops-delivery-styles.html` | <https://claude.ai/code/artifact/3bbe06ac-2659-4c85-8f3d-b80bc518dda4> |

**Pass the URL when re-publishing from a new conversation.** Without it a fresh
URL is minted and every link already shared goes stale.

These are page *bodies* — no `<!doctype>`, `<html>`, `<head>` or `<body>`; the
publisher wraps them. A strict CSP blocks every external host, so there are no
CDN scripts, webfonts or remote images: all CSS is inline and the diagrams are
hand-authored inline SVG.

Both are theme-aware in three states — explicit light, explicit dark, and the
default "system" setting, which stamps nothing on the root element and is what
most viewers actually see. Colours are defined as tokens on bare `:root` and
only redefined inside the media query and `[data-theme]` blocks; a colour whose
only definition sits behind `[data-theme]` renders one theme's text on the other
theme's background.
