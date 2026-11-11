import worker from "../../apps/server/src/index.ts";
import assets from "seekhunt:assets";

export { GameRoom } from "../../apps/server/src/index.ts";

const types = {
  css: "text/css; charset=utf-8",
  html: "text/html; charset=utf-8",
  ico: "image/x-icon",
  jpeg: "image/jpeg",
  jpg: "image/jpeg",
  js: "text/javascript; charset=utf-8",
  json: "application/json; charset=utf-8",
  mjs: "text/javascript; charset=utf-8",
  png: "image/png",
  svg: "image/svg+xml",
  txt: "text/plain; charset=utf-8",
  wasm: "application/wasm",
  webmanifest: "application/manifest+json; charset=utf-8",
  webp: "image/webp",
  woff: "font/woff",
  woff2: "font/woff2",
};

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/_health" && request.method === "GET") {
      // Exercise the real storage binding without creating a game or exposing room data.
      const room = env.ROOMS.get(env.ROOMS.idFromName("__seekhunt_health__"));
      const [state, index] = await Promise.all([
        room.fetch("https://room/info"),
        env.ASSETS.fetch(new Request("https://assets/index.html", { method: "HEAD" })),
      ]);
      return Response.json({ status: state.ok && index.ok ? "ok" : "unavailable", commit: __SEEKHUNT_COMMIT__ }, {
        status: state.ok && index.ok ? 200 : 503,
        headers: { "cache-control": "no-store" },
      });
    }
    if (url.pathname.startsWith("/api/") || url.pathname.startsWith("/ws/")) {
      return worker.fetch(request, env, ctx);
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    let path;
    try {
      path = decodeURIComponent(url.pathname);
    } catch {
      return new Response("Invalid path", { status: 400 });
    }
    if (!Object.hasOwn(assets, path)) {
      if (!request.headers.get("accept")?.includes("text/html") || path.startsWith("/assets/")) {
        return new Response("Not found", { status: 404 });
      }
      path = "/index.html";
    }
    // Only files recorded at build time are reachable; disk directory listings are never public.
    const encodedPath = path.split("/").map(encodeURIComponent).join("/");
    const response = await env.ASSETS.fetch(new Request(`https://assets${encodedPath}`, { method: request.method }));
    const headers = new Headers(response.headers);
    headers.set("content-type", types[path.split(".").pop()] ?? "application/octet-stream");
    headers.set("cache-control", "no-cache");
    headers.set("x-content-type-options", "nosniff");
    return new Response(response.body, { status: response.status, headers });
  },
};
