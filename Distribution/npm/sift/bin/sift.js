#!/usr/bin/env node
// The npm face of sift: find the binary for this platform and hand the process straight to it.
//
// NOTHING HERE MAY WRITE TO STDOUT. `sift mcp` speaks JSON-RPC on stdout, and one stray line from a
// launcher corrupts the protocol for the entire session — the same rule the server itself is held to.
// Every diagnostic goes to stderr, and the child's streams are inherited rather than piped so the
// launcher never sits between the server and its client.
"use strict";

const { spawnSync } = require("node:child_process");

// The binary ships in its own package per platform, declared as an optional dependency, so npm
// installs exactly the one that can run here and refuses none of the install on the others.
const PLATFORM_PACKAGES = {
    "darwin-arm64": "@agulhas-labs/sift-darwin-arm64",
};

function resolveBinary() {
    const platform = `${process.platform}-${process.arch}`;
    const packageName = PLATFORM_PACKAGES[platform];
    if (!packageName) {
        const supported = Object.keys(PLATFORM_PACKAGES).join(", ");
        throw new Error(`sift ships for ${supported} only, and this is ${platform}.`);
    }
    try {
        return require.resolve(`${packageName}/bin/sift`);
    } catch {
        throw new Error(
            `${packageName} is not installed. It is an optional dependency, so an install run with ` +
            `--no-optional or --omit=optional skips it. Reinstall without that flag.`
        );
    }
}

let binary;
try {
    binary = resolveBinary();
} catch (error) {
    process.stderr.write(`sift: ${error.message}\n`);
    process.exit(1);
}

const result = spawnSync(binary, process.argv.slice(2), { stdio: "inherit" });
if (result.error) {
    process.stderr.write(`sift: ${result.error.message}\n`);
    process.exit(1);
}
// A child killed by a signal reports a null status. Exiting 0 there would tell whatever started this
// that a killed server finished cleanly.
process.exit(result.status === null ? 1 : result.status);
