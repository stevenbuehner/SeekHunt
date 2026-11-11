import { createRequire } from "node:module";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../", import.meta.url));
const require = createRequire(import.meta.url);
// Use the exact build tools and runtime already pinned by Wrangler in package-lock.json.
const wranglerRequire = createRequire(require.resolve("wrangler"));
const { build } = wranglerRequire("esbuild");
const runtimeVersion = wranglerRequire("workerd/package.json").version;
const commit = process.env.SEEKHUNT_COMMIT;
if (!/^[a-f0-9]{40}$/.test(commit ?? "")) throw new Error("SEEKHUNT_COMMIT must be a full commit SHA.");
const config = await readFile(resolve(root, "apps/server/wrangler.jsonc"), "utf8");
const compatibilityDate = config.match(/"compatibility_date"\s*:\s*"(\d{4}-\d{2}-\d{2})"/)?.[1];
if (!compatibilityDate) throw new Error("No compatibility_date found in wrangler.jsonc.");

const assets = Object.create(null);
async function collect(directory, prefix = "") {
  for (const item of await readdir(directory, { withFileTypes: true })) {
    const path = `${prefix}/${item.name}`;
    if (item.name.startsWith(".") || item.name === "_headers" || item.name === "_redirects") continue;
    if (item.isDirectory()) await collect(resolve(directory, item.name), path);
    else if (item.isFile()) assets[path] = true;
    else throw new Error(`Unsupported asset: ${path}`);
  }
}
await collect(resolve(root, "apps/web/dist"));
if (!assets["/index.html"]) throw new Error("Build the web app with npm run build first.");
const output = resolve(root, "build/proxmox");
await mkdir(output, { recursive: true });
await build({
  absWorkingDir: root,
  entryPoints: ["scripts/proxmox/entry.mjs"],
  outfile: resolve(output, "worker.mjs"),
  bundle: true,
  format: "esm",
  platform: "neutral",
  mainFields: ["module", "main"],
  target: "es2022",
  conditions: ["workerd", "worker", "browser"],
  external: ["cloudflare:*"],
  define: { __SEEKHUNT_COMMIT__: JSON.stringify(commit) },
  plugins: [{
    name: "seekhunt-assets",
    setup(plugin) {
      plugin.onResolve({ filter: /^seekhunt:assets$/ }, () => ({ path: "assets", namespace: "seekhunt" }));
      plugin.onLoad({ filter: /.*/, namespace: "seekhunt" }, () => ({ contents: JSON.stringify(assets), loader: "json" }));
    },
  }],
});
const template = await readFile(resolve(root, "scripts/proxmox/config.capnp"), "utf8");
await writeFile(resolve(output, "config.capnp"), template.replace("@COMPATIBILITY_DATE@", compatibilityDate));
await writeFile(resolve(output, "version.json"), `${JSON.stringify({ commit, workerd: runtimeVersion }, null, 2)}\n`);
console.log(`Built SeekHunt ${commit} with workerd ${runtimeVersion}.`);
