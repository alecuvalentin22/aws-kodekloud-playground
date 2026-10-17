# __REPO__

The platform team's reusable workflows. Created by the platform-lab GitHub playground
(safe to delete: `playground/setup/up-github.sh --destroy`).

Call one from a service repo:

```yaml
jobs:
  lint:
    uses: __OWNER__/__REPO__/.github/workflows/python-lint.yml@v1.0.0
    with:
      path: service
```

Releases are tags (`v1.0.0`). Pin a tag or a commit SHA, never `@main`.
