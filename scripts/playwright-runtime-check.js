"use strict";

const args = process.argv.slice(2);
const getArg = (name, fallback) => {
  const index = args.indexOf(name);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
};

const url = getArg("--url", "http://127.0.0.1:4200");
const runtimeDir = getArg("--runtime-dir", process.cwd());
const waitMs = Number(getArg("--wait-ms", "1500"));

function loadPlaywright() {
  for (const packageName of ["playwright", "@playwright/test"]) {
    try {
      return require(require.resolve(packageName, { paths: [runtimeDir] }));
    } catch (_) {}
  }
  return null;
}

function message(text, location) {
  return {
    text,
    file: location && location.url ? location.url : null,
    line: location && location.lineNumber ? location.lineNumber : null,
    column: location && location.columnNumber ? location.columnNumber : null,
  };
}

(async () => {
  const playwright = loadPlaywright();
  if (!playwright) {
    console.log(
      JSON.stringify({
        status: "unverified",
        verified: false,
        reason: "playwright_missing",
        error: "No se encontro Playwright en el runtime aislado.",
      }),
    );
    process.exitCode = 2;
    return;
  }

  const result = {
    status: "ok",
    verified: true,
    url,
    console_errors: [],
    console_warnings: [],
    page_errors: [],
    failed_requests: [],
    http_errors: [],
    page_title: null,
  };
  let browser;

  try {
    browser = await playwright.chromium.launch({ headless: true });
    const page = await browser.newPage();
    page.on("console", (entry) => {
      const item = message(entry.text(), entry.location());
      if (entry.type() === "error") {
        result.console_errors.push(item);
      } else if (entry.type() === "warning") {
        result.console_warnings.push(item);
      }
    });
    page.on("pageerror", (error) => {
      result.page_errors.push({
        text: error.message,
        stack: error.stack || null,
      });
    });
    page.on("requestfailed", (request) => {
      result.failed_requests.push({
        url: request.url(),
        method: request.method(),
        error: request.failure() ? request.failure().errorText : null,
      });
    });
    page.on("response", (response) => {
      if (response.status() >= 400) {
        result.http_errors.push({
          url: response.url(),
          status: response.status(),
        });
      }
    });

    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 45000 });
    await new Promise((resolve) => setTimeout(resolve, waitMs));
    result.page_title = await page.title();
    const hasProblems =
      result.console_errors.length > 0 ||
      result.console_warnings.length > 0 ||
      result.page_errors.length > 0 ||
      result.failed_requests.length > 0 ||
      result.http_errors.length > 0;
    result.status = hasProblems ? "failed" : "ok";
    result.verified = !hasProblems;
    console.log(JSON.stringify(result));
    process.exitCode = hasProblems ? 1 : 0;
  } catch (error) {
    result.status = "failed";
    result.verified = false;
    result.error = error.message;
    console.log(JSON.stringify(result));
    process.exitCode = 1;
  } finally {
    if (browser) {
      await browser.close();
    }
  }
})();
