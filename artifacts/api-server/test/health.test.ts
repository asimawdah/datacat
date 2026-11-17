import { test } from "node:test";
import assert from "node:assert/strict";
import { dependenciesReady } from "../src/routes/health";

test("readiness succeeds when every required dependency responds", async () => {
  const checked: string[] = [];
  const ready = await dependenciesReady([
    async () => {
      checked.push("postgres");
    },
    async () => {
      checked.push("clickhouse");
    },
  ]);

  assert.equal(ready, true);
  assert.deepEqual(checked, ["postgres", "clickhouse"]);
});

test("readiness fails when a required dependency rejects", async () => {
  const ready = await dependenciesReady([
    async () => undefined,
    async () => {
      throw new Error("database unavailable");
    },
  ]);

  assert.equal(ready, false);
});

test("readiness fails when a dependency check exceeds its timeout", async () => {
  const ready = await dependenciesReady([() => new Promise(() => undefined)], 5);

  assert.equal(ready, false);
});
