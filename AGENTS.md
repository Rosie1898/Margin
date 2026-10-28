# Local application updates

Keep interface explanations short and plain in every supported language. Use `mac/current` as the current design reference when updating Windows copy. Keep related explanations together, with their action below. The Windows title bar should show only window controls, without a Margin logo or wordmark.

The user wants each Margin update installed automatically over the version they use.

For Windows changes, run `node scripts/build.mjs` from `win/` after appropriate checks. Both `pnpm build` and `pnpm dist` use this workflow: build the installer, upgrade the existing installation configured in `win/.local-install-path`, then verify installed file hashes. Do not stop at updating `dist/win-unpacked` or ask the user to install manually when the normal workflow can finish it.

Use `pnpm package` only when a package without local installation is specifically wanted. `pnpm install:local` retries installation of the last successful build. Preserve the existing installation scope and user data. Close a running app normally and wait for saves; never force-terminate it to install. Windows may still require the user to approve its own UAC prompt for an all-users installation. Report an update as installed only after installed-file verification succeeds.
