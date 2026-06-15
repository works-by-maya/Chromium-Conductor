# Local Custom Patch Notes

`patches.local` is the cozyCore/plushcore patch layer for this build workspace.

`conductor.sh` refreshes `ungoogled-chromium-macos` every run, so local patches live
beside the script instead of inside that refreshed checkout. This directory is
the steady little home for patches suggested by Sai, authored locally, or
otherwise specific to this workspace's build style.

How to add a patch:

1. Put the patch file somewhere under this directory.
2. Add its relative path to `series`.
3. Add a tab-separated explanation to `manifest.tsv`.

The `series` file controls apply order. The manifest controls what `conductor.sh`
prints while it runs, so someone watching the build can understand what each
local patch is for without having to decode it from scratch.

Format for `manifest.tsv`:

```text
patch-relative-path<TAB>short summary<TAB>why this patch exists
```

Keep the explanations plain-English, warm, and honest. A future reader should be
able to understand the local choice without opening the patch first.
