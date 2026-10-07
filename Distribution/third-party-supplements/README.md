# Third-party notice supplements

License texts that `third-party-notices.sh` cannot discover, because they are not in the checkout to
be found. The generator copies each license out of the checkout named by `Package.resolved`, so the
list cannot fall behind the resolution. This directory is the one exception: every claim here is a
person's and nothing checks it against upstream, so add a file only when the terms exist nowhere in the
dependency's own tree.

## Layout

One directory per SwiftPM identity (the lower-cased name `Package.resolved` uses), one `.txt` file per
component. The generator emits each file inside the section of the package it travels in, under a
heading naming the file:

```
Distribution/third-party-supplements/<identity>/<component>.txt
  → "--- supplement: <component> ---" in that package's section
```

Each file opens with a sentence saying what the component is, where it is vendored, why the terms are
not discoverable, and where the text was taken from — then the license verbatim. `ThirdPartyNoticesTests`
asserts every file reaches the notices and its identity is still one the resolution names.

## What is here, and why

- **`yams/libyaml.txt`** — Yams is a Swift wrapper around libyaml and vendors its C sources at
  `Sources/CYaml/`, with the per-file copyright headers stripped and no license file kept. Yams' own `LICENSE` covers Yams, not libyaml,
  so without this the binary shipped libyaml's compiled code carrying none of libyaml's terms — which
  its MIT license requires a redistribution to reproduce. The text is libyaml's `License` at tag
  `0.2.5`, the release the vendored sources match (Yams 5.4.0).
