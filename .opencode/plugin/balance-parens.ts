import type { Plugin } from "@opencode-ai/plugin";
import Debug from "debug";

const debug = Debug("balance-parens");

export const BalanceParens: Plugin = async ({ $ }) => {
  try {
    await $`command -v parinfer-rust`.quiet();
  } catch {
    console.warn("parinfer-rust not found in PATH. BalanceParens plugin disabled.");
    return {};
  }

  return {
    event: async ({ event }) => {
      if (event.type !== "file.edited") return;
      const filename = event.properties.file;
      if (!filename.endsWith(".el")) return;

      const tmpFile = `${filename}.parinfer.tmp`;

      const { exitCode, stderr } = await $`cat ${filename} | parinfer-rust -l lisp -m smart > ${tmpFile}`.nothrow().quiet();

      if (exitCode !== 0) {
        debug(`parinfer-rust exited with non-zero exit code (${exitCode}).\n ${stderr}`);
        // Cleanup temp file on failure
        await $`rm -f ${tmpFile}`.nothrow().quiet();
        return;
      }

      // Compare file sizes to detect changes
      const originalSize = (await $`stat -c %s ${filename}`.quiet()).stdout.trim();
      const newSize = (await $`stat -c %s ${tmpFile}`.quiet()).stdout.trim();

      if (originalSize !== newSize) {
        // Only write if sizes differ
        await $`mv ${tmpFile} ${filename}`.quiet();
        debug(`Balanced parens for ${filename}`);
      } else {
        // No changes, cleanup temp file
        await $`rm -f ${tmpFile}`.nothrow().quiet();
        debug(`No changes needed for ${filename}`);
      }

      if (exitCode !== 0) {
        debug(
          `parinfer-rust exited with non-zero exit code (${exitCode}).\n ${stderr}`,
        );
        // Cleanup temp file on failure
        await $`rm -f ${tmpFile}`.nothrow().quiet();
      } else {
        debug(`Balanced parens for ${filename}`);
      }
    },
  };
};
