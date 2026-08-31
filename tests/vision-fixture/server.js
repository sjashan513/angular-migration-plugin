"use strict";

const fs = require("fs");
const http = require("http");
const path = require("path");

const port = Number(process.argv[2]);
const root = path.resolve(__dirname);

http
  .createServer((request, response) => {
    const pathname = decodeURIComponent(
      new URL(request.url, "http://localhost").pathname,
    );
    const file = path.resolve(root, `.${pathname}`, "index.html");
    if (!file.startsWith(`${root}${path.sep}`) || !fs.existsSync(file)) {
      response.writeHead(404);
      response.end("Not found");
      return;
    }
    response.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    fs.createReadStream(file).pipe(response);
  })
  .listen(port, "127.0.0.1", () => process.stdout.write("ready\n"));
