import { Router, type IRouter } from "express";
import { pool } from "@workspace/db";
import { chQuery } from "../lib/ch";
import { useClickHouse } from "../lib/storage";

const router: IRouter = Router();

/**
 * Check required stores with a bounded wait so a stalled dependency cannot hang health probes.
 * The checks are injected to keep the behavior independently testable.
 */
export async function dependenciesReady(
  checks: readonly (() => Promise<unknown>)[],
  timeoutMs = 2_000,
): Promise<boolean> {
  let timeout: ReturnType<typeof setTimeout> | undefined;
  const timeoutPromise = new Promise<false>((resolve) => {
    timeout = setTimeout(() => resolve(false), timeoutMs);
  });

  try {
    return await Promise.race([Promise.all(checks.map((check) => check())).then(() => true), timeoutPromise]);
  } catch {
    return false;
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

// Liveness: the process is running. This intentionally does not depend on external services.
router.get("/healthz", (_req, res) => {
  res.json({ status: "ok" });
});

// Readiness: PostgreSQL is always required; ClickHouse is also required when it stores telemetry.
router.get("/readyz", async (_req, res) => {
  const checks: Array<() => Promise<unknown>> = [() => pool.query("SELECT 1")];
  if (useClickHouse) checks.push(() => chQuery("SELECT 1"));

  const ready = await dependenciesReady(checks);
  res.status(ready ? 200 : 503).json({ status: ready ? "ok" : "unavailable" });
});

export default router;
