# Releasing

This package is prepared for Hex publishing and includes a local release gate
that checks formatting, tests, docs, and Hex publishability before packaging.

## Release Checklist

1. Bump `@version` in [mix.exs](mix.exs).
2. Move the relevant notes from `Unreleased` into a versioned section in
   [CHANGELOG.md](CHANGELOG.md).
3. Refresh dependencies with `mix deps.get`.
4. Run `mix release.check`.
5. If the audit passes, run `mix release.package`.
6. Create and push a matching git tag: `git tag vX.Y.Z && git push origin vX.Y.Z`.

The release flow expects a tag that matches `@version` because ExDoc source
links are configured to use `v#{@version}`.

## Local Publish

Register a Hex user and create an API key if you do not already have one:

```bash
mix hex.user register
mix hex.user key generate --key-name publish-ci --permission api:write
```

Then publish manually:

```bash
mix release.check
mix release.package
HEX_API_KEY=... mix hex.publish --yes
```

Hex will build docs automatically through `mix docs` during publish. The repo
also runs that step explicitly in `mix release.check` to catch doc failures
earlier.

## GitHub Actions Release Flow

The repository includes
[.github/workflows/release.yml](.github/workflows/release.yml).

- pushing a `v*` tag runs the verification pipeline and, if the dependency
  graph is publishable, publishes to Hex
- the publish job runs in the GitHub `ci` environment and reads `HEX_API_KEY`
  from that environment
- the same workflow can be started manually with `workflow_dispatch` to run the
  verification steps without publishing from a branch
- successful tagged publishes also create a GitHub Release for the same tag

The workflow runs:

1. `mix deps.get`
2. `mix release.check`
3. `mix release.package`
4. `mix hex.publish --yes`
5. create the matching GitHub Release

## After Publish

Hex allows republishing fixes for a short window after the initial publish and
also supports reverting a version if necessary. See the official Hex publishing
guide for the current rules and commands:

- [Publishing packages to Hex](https://hex.pm/docs/publish)
