// The acceptance check of the demo project: src/value.txt must hold 42.
import { readFileSync } from "node:fs";
const value = readFileSync(new URL("./src/value.txt", import.meta.url), "utf8").trim();
if (value !== "42") {
  console.error(`value is ${JSON.stringify(value)}, expected "42"`);
  process.exit(1);
}
console.log("value is 42");
