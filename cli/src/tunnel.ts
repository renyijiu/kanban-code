/**
 * Spawn a cloudflared quick-tunnel for a local port, parse the public URL
 * from its stdout/stderr, and expose a kill handle. Kept thin + injectable
 * so tests can substitute a fake binary that prints the URL and exits.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { delimiter, join } from "node:path";

export interface TunnelHandle {
  /** The public URL cloudflared allocated (e.g. "https://xxx.trycloudflare.com"). */
  url: string;
  /** The underlying child — kill to tear the tunnel down. */
  child: ChildProcess;
  /** Graceful teardown: SIGTERM, then SIGKILL after `timeoutMs` if still alive. */
  stop: (timeoutMs?: number) => Promise<void>;
}

export interface StartTunnelOptions {
  /** Localhost port that cloudflared should forward to. */
  port: number;
  /** Override the cloudflared binary (default: "npx cloudflared"). */
  command?: string;
  args?: string[];
  /** How long to wait for the URL line before giving up. */
  timeoutMs?: number;
  /** Spawner — pluggable for tests. */
  spawnImpl?: typeof spawn;
}

// Quick tunnels always allocate something under trycloudflare.com. Match
// both `https://<sub>.trycloudflare.com` and `https://<sub>.cfargotunnel.com`
// just in case the CDN changes the surface.
const URL_REGEX = /https:\/\/[a-z0-9][a-z0-9-]*\.(?:trycloudflare\.com|cfargotunnel\.com)/i;

function findExecutable(name: string): string | null {
  const path = process.env.PATH ?? "";
  for (const dir of path.split(delimiter)) {
    if (!dir) continue;
    const candidate = join(dir, name);
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // Keep searching.
    }
  }
  return null;
}

/** Start cloudflared and resolve once the public URL is seen on stdout/stderr.
 *
 *  Resolution order for the cloudflared binary:
 *    1. Caller-provided `command` / `args` (used by tests).
 *    2. `KANBAN_CLOUDFLARED` env var — absolute path to a specific binary.
 *    3. Fallback to `npx -y cloudflared` so standalone CLI use still works.
 *
 *  We pass `--config /dev/null` to disable auto-loading of `~/.cloudflared/
 *  config.yml`. Users who previously set up a named tunnel have an ingress
 *  stanza there, and cloudflared's default behavior is to apply those
 *  ingress rules to ANY tunnel it runs — silently ignoring `--url` and
 *  returning 404 for every request to our quick tunnel. Nailed to /dev/null
 *  so our share tunnels always route to the intended origin.
 */
export function startCloudflaredTunnel(opts: StartTunnelOptions): Promise<TunnelHandle> {
  const bundled = process.env.KANBAN_CLOUDFLARED;
  const urlArgs = ["--config", "/dev/null", "tunnel", "--url", `http://localhost:${opts.port}`];
  const installedCloudflared = bundled ? null : findExecutable("cloudflared");
  const defaultCommand = bundled || installedCloudflared || "npx";
  const defaultArgs = bundled || installedCloudflared ? urlArgs : ["-y", "cloudflared", ...urlArgs];
  const {
    port,
    command = defaultCommand,
    args = defaultArgs,
    timeoutMs = 30_000,
    spawnImpl = spawn,
  } = opts;
  void port;

  return new Promise<TunnelHandle>((resolve, reject) => {
    const child = spawnImpl(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      env: process.env,
    });

    let resolved = false;
    const timer = setTimeout(() => {
      if (resolved) return;
      resolved = true;
      try { child.kill("SIGTERM"); } catch { /* */ }
      reject(new Error(`cloudflared did not publish a URL within ${timeoutMs}ms`));
    }, timeoutMs);

    const stop = async (killTimeoutMs = 2000): Promise<void> => {
      if (child.exitCode !== null || child.signalCode !== null) return;
      return new Promise<void>((res) => {
        const done = (): void => { clearTimeout(hard); res(); };
        child.once("exit", done);
        try { child.kill("SIGTERM"); } catch { done(); return; }
        const hard = setTimeout(() => {
          try { child.kill("SIGKILL"); } catch { /* */ }
        }, killTimeoutMs);
      });
    };

    const scan = (data: Buffer | string): void => {
      if (resolved) return;
      const chunk = typeof data === "string" ? data : data.toString("utf-8");
      const m = chunk.match(URL_REGEX);
      if (m) {
        resolved = true;
        clearTimeout(timer);
        resolve({ url: m[0], child, stop });
      }
    };

    child.stdout?.on("data", scan);
    child.stderr?.on("data", scan);

    child.once("exit", (code, signal) => {
      if (resolved) return;
      resolved = true;
      clearTimeout(timer);
      reject(new Error(`cloudflared exited before publishing a URL (code=${code}, signal=${signal})`));
    });

    child.once("error", (err) => {
      if (resolved) return;
      resolved = true;
      clearTimeout(timer);
      reject(err);
    });
  });
}
