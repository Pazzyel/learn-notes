npm init -y
npm i -D vitepress
npm pkg set scripts.docs:dev="vitepress dev notes" scripts.docs:build="vitepress build notes" scripts.docs:preview="vitepress preview notes"

New-Item -ItemType Directory -Force notes\.vitepress | Out-Null

@'
import { defineConfig } from "vitepress";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const NOTES_ROOT = path.resolve(__dirname, "..");

// 旧路径 -> 新路径（按需维护）
const redirects: Record<string, string> = {
  "/spring-cloud-notes/bootstrap..html": "/spring-cloud-notes/bootstrap.html"
};

function buildSidebar(rootDir: string) {
  return fs
    .readdirSync(rootDir, { withFileTypes: true })
    .filter((d) => d.isDirectory() && !d.name.startsWith("."))
    .map((dir) => {
      const items = fs
        .readdirSync(path.join(rootDir, dir.name), { withFileTypes: true })
        .filter((f) => f.isFile() && f.name.endsWith(".md") && f.name.toLowerCase() !== "index.md")
        .map((f) => {
          const base = f.name.replace(/\.md$/i, "");
          return { text: base, link: `/${dir.name}/${base}` };
        })
        .sort((a, b) => a.text.localeCompare(b.text, "zh-Hans-CN"));

      return { text: dir.name, collapsed: true, items };
    })
    .filter((g) => g.items.length > 0)
    .sort((a, b) => a.text.localeCompare(b.text, "zh-Hans-CN"));
}

function buildRedirectScript(map: Record<string, string>) {
  const json = JSON.stringify(map);
  return `
(() => {
  const redirects = ${json};
  const p = window.location.pathname;
  const variants = [p];
  if (!p.endsWith("/")) variants.push(p + "/");
  if (!p.endsWith(".html")) variants.push(p.replace(/\\/$/, "") + ".html");

  for (const key of variants) {
    const target = redirects[key];
    if (target && target !== p) {
      window.location.replace(target + window.location.search + window.location.hash);
      return;
    }
  }
})();
`.trim();
}

export default defineConfig({
  lang: "zh-CN",
  title: "My Notes",
  description: "个人学习笔记",
  cleanUrls: true,
  lastUpdated: true,
  head: [["script", {}, buildRedirectScript(redirects)]],
  themeConfig: {
    nav: [{ text: "总览", link: "/index" }],
    sidebar: buildSidebar(NOTES_ROOT),
    search: { provider: "local" }
  }
});
'@ | Set-Content notes\.vitepress\config.mts -Encoding UTF8

@'
# 笔记总览

欢迎来到我的笔记站点。
'@ | Set-Content notes\index.md -Encoding UTF8

npm run docs:dev
