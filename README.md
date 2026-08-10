# nugraph-action

This repository provides a reusable GitHub Action and workflow example for generating a NuGet dependency graph from a .NET solution or project by using [0xced/nugraph](https://github.com/0xced/nugraph).

For local/command-line usage, install and run nugraph directly per its own docs — see [0xced/nugraph](https://github.com/0xced/nugraph).

## What is included

- A composite GitHub Action in [action.yml](action.yml)
- A manual workflow example in [examples/basic.yml](examples/basic.yml)
- A private-feed variant in [examples/private-feed.yml](examples/private-feed.yml)

## Usage as a GitHub Action

```yaml
jobs:
  graph:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: Tsabo/nugraph-action@main
        with:
          project-path: ./src/MyApp.sln
          output-path: artifacts/nugraph/graph.svg
```

See [examples/basic.yml](examples/basic.yml) for a full manual (`workflow_dispatch`) workflow you can copy into a consuming repo's `.github/workflows/` directory.

## Output formats

nugraph's `--output` option always writes raw graph source text — a Mermaid diagram if `output-path` ends in `.mmd`/`.mermaid`, otherwise Graphviz DOT text — it never renders an image itself. For image extensions (`.svg`, `.png`, `.pdf`, `.jpg`/`.jpeg`), this action renders the Graphviz DOT source into that image locally using Graphviz's `dot` (installed via `apt-get` on the runner if not already present, no external service involved). Mermaid output (`.mmd`/`.mermaid`) is left as raw source text, viewable at [mermaid.live](https://mermaid.live) — this action doesn't render Mermaid diagrams to images. See [0xced/nugraph](https://github.com/0xced/nugraph) for everything nugraph itself supports.

## Ignoring packages

Use `ignore` to exclude packages, one pattern per line — each line becomes its own `-i` flag, so you don't need to remember to repeat `-i` yourself:

```yaml
      - uses: Tsabo/nugraph-action@main
        with:
          project-path: ./src/MyApp.sln
          output-path: artifacts/nugraph/graph.svg
          ignore: |
            System.*
            Humanizer.Core.*
```

Any other nugraph flag (e.g. `-f`/`--framework`, `--no-links`) can be passed through `extra-args`:

```yaml
      - uses: Tsabo/nugraph-action@main
        with:
          project-path: ./src/MyApp.sln
          output-path: artifacts/nugraph/graph.png
          extra-args: '--no-links'
```

## Private NuGet feeds

nugraph calls `dotnet restore` internally, so it honors whatever NuGet sources are already configured on the runner — either a `NuGet.config` committed to the consuming repo, or a source registered by an earlier step in the same job (e.g. `dotnet nuget add source ...`). This action doesn't need to know about your feeds or credentials; just add a source-registration step before the `uses: Tsabo/nugraph-action@main` step, the same way you would before any other `dotnet restore`/`build` step. See [examples/private-feed.yml](examples/private-feed.yml) for an example using GitHub Packages.

## Notes

Rendering image output requires passwordless `sudo` and `apt-get` to install Graphviz if it isn't already on the runner — this works out of the box on GitHub-hosted runners, but self-hosted runners without those may need Graphviz preinstalled instead.

The exact CLI syntax for nugraph can vary slightly between versions. If your installed version expects different flags, pass them through the `extra-args` input. Values in `extra-args` are space-separated and cannot contain embedded spaces (e.g. quoted multi-word values are not supported).
