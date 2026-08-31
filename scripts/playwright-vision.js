"use strict";

const fs = require("fs");
const path = require("path");

const args = process.argv.slice(2);
const arg = (name, fallback) => {
  const index = args.indexOf(name);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
};

const mode = arg("--mode");
const manifestPath = arg("--manifest");
const targetUrl = arg("--url");
const outputDir = path.resolve(
  arg("--output-dir", ".angular-migration/vision/current"),
);
const publishDir = arg("--publish-dir")
  ? path.resolve(arg("--publish-dir"))
  : null;
const runtimeDir = path.resolve(arg("--runtime-dir", process.cwd()));
const threshold = Number(arg("--threshold", "0.001"));

function loadPackage(name) {
  return require(require.resolve(name, { paths: [runtimeDir] }));
}

function safeName(value) {
  const name = value.replace(/^\/+|\/+$/g, "").replace(/[^a-z0-9._-]+/gi, "-");
  return name || "root";
}

function ensureDir(directory) {
  fs.mkdirSync(directory, { recursive: true });
}

function writeJson(file, value) {
  ensureDir(path.dirname(file));
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
}

function routeUrl(base, routePath) {
  const baseUrl = new URL(base);
  const url = new URL(
    routePath.replace(/^\//, ""),
    `${baseUrl.origin}${baseUrl.pathname.replace(/\/?$/, "/")}`,
  );
  if (url.origin !== baseUrl.origin)
    throw new Error("La ruta sale del origin de la URL indicada");
  return url.href;
}

function publicUrl(value) {
  const url = new URL(value);
  url.username = "";
  url.password = "";
  url.search = "";
  url.hash = "";
  return url.href;
}

async function capture(page, url, file, masks) {
  const events = {
    console_errors: [],
    page_errors: [],
    failed_requests: [],
    http_errors: [],
  };
  const onConsole = (entry) => {
    if (entry.type() === "error") events.console_errors.push(entry.text());
  };
  const onPageError = (error) => events.page_errors.push(error.message);
  const onRequestFailed = (request) => {
    const failure = request.failure();
    events.failed_requests.push({
      url: publicUrl(request.url()),
      error: failure ? failure.errorText : null,
    });
  };
  const onResponse = (response) => {
    if (response.status() >= 400)
      events.http_errors.push({
        url: publicUrl(response.url()),
        status: response.status(),
      });
  };
  page.on("console", onConsole);
  page.on("pageerror", onPageError);
  page.on("requestfailed", onRequestFailed);
  page.on("response", onResponse);

  try {
    const response = await page.goto(url, {
      waitUntil: "domcontentloaded",
      timeout: 45000,
    });
    await page
      .waitForLoadState("networkidle", { timeout: 3000 })
      .catch(() => {});
    await page
      .evaluate(() => (document.fonts ? document.fonts.ready : null))
      .catch(() => {});
    await page.addStyleTag({
      content:
        "*,*::before,*::after{animation:none!important;transition:none!important;caret-color:transparent!important}",
    });
    const locators = masks.map((selector) => page.locator(selector));
    ensureDir(path.dirname(file));
    await page.screenshot({
      path: file,
      fullPage: true,
      animations: "disabled",
      caret: "hide",
      mask: locators,
    });
    return {
      status: "captured",
      final_url: publicUrl(page.url()),
      title: await page.title(),
      http_status: response ? response.status() : null,
      ...events,
    };
  } catch (error) {
    return { status: "failed", error: error.message, ...events };
  } finally {
    page.off("console", onConsole);
    page.off("pageerror", onPageError);
    page.off("requestfailed", onRequestFailed);
    page.off("response", onResponse);
  }
}

function comparePng(PNG, pixelmatch, baselineFile, candidateFile, diffFile) {
  const baseline = PNG.sync.read(fs.readFileSync(baselineFile));
  const candidate = PNG.sync.read(fs.readFileSync(candidateFile));
  if (
    baseline.width !== candidate.width ||
    baseline.height !== candidate.height
  ) {
    const diff = new PNG({
      width: Math.max(baseline.width, candidate.width),
      height: Math.max(baseline.height, candidate.height),
    });
    for (let index = 0; index < diff.data.length; index += 4) {
      diff.data[index] = 255;
      diff.data[index + 3] = 255;
    }
    ensureDir(path.dirname(diffFile));
    fs.writeFileSync(diffFile, PNG.sync.write(diff));
    return { different: true, ratio: 1, dimensions_changed: true };
  }
  const diff = new PNG({ width: baseline.width, height: baseline.height });
  const pixels = pixelmatch(
    baseline.data,
    candidate.data,
    diff.data,
    baseline.width,
    baseline.height,
    { threshold: 0.1 },
  );
  const ratio = pixels / (baseline.width * baseline.height);
  if (ratio > threshold) {
    ensureDir(path.dirname(diffFile));
    fs.writeFileSync(diffFile, PNG.sync.write(diff));
  }
  return { different: ratio > threshold, ratio, dimensions_changed: false };
}

(async () => {
  if (!["baseline", "compare"].includes(mode) || !manifestPath || !targetUrl) {
    throw new Error(
      "Uso: --mode baseline|compare --manifest <json> --url <http(s)> --output-dir <dir>",
    );
  }
  const parsedUrl = new URL(targetUrl);
  if (!["http:", "https:"].includes(parsedUrl.protocol))
    throw new Error("Solo se aceptan URLs http o https");

  const manifest = readJson(manifestPath);
  const playwright = loadPackage("playwright");
  const pixelmatch = mode === "compare" ? loadPackage("pixelmatch") : null;
  const PNG = mode === "compare" ? loadPackage("pngjs").PNG : null;
  const viewports =
    manifest.viewports && manifest.viewports.length
      ? manifest.viewports
      : [
          { name: "desktop", width: 1440, height: 900 },
          { name: "mobile", width: 390, height: 844 },
        ];
  const masks = manifest.masks || [];
  const tempDir = path.join(outputDir, "temp");
  const baselineDir = path.join(tempDir, "baseline");
  const candidateDir = path.join(tempDir, "candidate");
  ensureDir(outputDir);

  const browser = await playwright.chromium.launch({ headless: true });
  const results = [];
  try {
    for (const [routeIndex, route] of (manifest.routes || []).entries()) {
      if (route.status === "blocked") {
        results.push({
          path: route.path,
          status: "blocked",
          reason: route.reason || "Ruta no visitable",
        });
        continue;
      }
      for (const viewport of viewports) {
        const context = await browser.newContext({
          viewport: { width: viewport.width, height: viewport.height },
          locale: "es-ES",
          timezoneId: "UTC",
          colorScheme: "light",
          deviceScaleFactor: 1,
          reducedMotion: "reduce",
        });
        const page = await context.newPage();
        const prefix = `${String(routeIndex + 1).padStart(3, "0")}-${safeName(route.path)}`;
        const relative = path.join(prefix, safeName(viewport.name), "page.png");
        const targetFile = path.join(
          mode === "baseline" ? baselineDir : candidateDir,
          relative,
        );
        const captureResult = await capture(
          page,
          routeUrl(targetUrl, route.path),
          targetFile,
          masks,
        );
        await context.close();
        const item = {
          path: route.path,
          viewport: viewport.name,
          ...captureResult,
        };

        if (mode === "compare" && captureResult.status === "captured") {
          const baselineFile = path.join(baselineDir, relative);
          if (!fs.existsSync(baselineFile)) {
            item.status = "failed";
            item.error = "Baseline ausente";
          } else {
            const publishRoute = path.join(
              publishDir || path.join(outputDir, "differences"),
              prefix,
              safeName(viewport.name),
            );
            const comparison = comparePng(
              PNG,
              pixelmatch,
              baselineFile,
              targetFile,
              path.join(publishRoute, "diff.png"),
            );
            item.status = comparison.different ? "different" : "unchanged";
            item.difference_ratio = comparison.ratio;
            item.dimensions_changed = comparison.dimensions_changed;
            if (comparison.different) {
              ensureDir(publishRoute);
              fs.copyFileSync(
                baselineFile,
                path.join(publishRoute, "baseline.png"),
              );
              fs.copyFileSync(
                targetFile,
                path.join(publishRoute, "candidate.png"),
              );
            }
          }
        }
        results.push(item);
      }
    }
  } finally {
    await browser.close();
  }

  const result = {
    status: results.some((item) => item.status === "failed") ? "failed" : "ok",
    mode,
    url: publicUrl(targetUrl),
    threshold,
    results,
    summary: {
      captured: results.filter((item) => item.status === "captured").length,
      different: results.filter((item) => item.status === "different").length,
      unchanged: results.filter((item) => item.status === "unchanged").length,
      blocked: results.filter((item) => item.status === "blocked").length,
      failed: results.filter((item) => item.status === "failed").length,
    },
  };
  writeJson(
    path.join(
      outputDir,
      mode === "baseline" ? "baseline.json" : "comparison.json",
    ),
    result,
  );
  if (mode === "compare") fs.rmSync(tempDir, { recursive: true, force: true });
  process.stdout.write(`${JSON.stringify(result)}\n`);
  process.exitCode = result.status === "ok" ? 0 : 1;
})().catch((error) => {
  process.stdout.write(
    `${JSON.stringify({ status: "failed", error: error.message })}\n`,
  );
  process.exitCode = 1;
});
