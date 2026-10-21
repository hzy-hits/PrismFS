// The portfolio fixture: several *different* accepted results, not one.
// Each candidate writes its own value; all three pass.
import { readFileSync } from "node:fs";
const raw = readFileSync(new URL("./src/value.txt", import.meta.url), "utf8").trim();
const value = Number(raw);
if (![42, 43, 44].includes(value)) {
  console.error(`value ${JSON.stringify(raw)} is not one of 42, 43, 44`);
  process.exit(1);
}
console.log(`accepted ${value}`);
