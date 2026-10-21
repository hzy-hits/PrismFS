// The acceptance check of the map-reduce demo: both shards' fixes are present.
import { readFileSync } from "node:fs";
const read = (name) => readFileSync(new URL(`./src/${name}`, import.meta.url), "utf8").trim();
const a = read("a.txt"), b = read("b.txt");
if (a !== "A" || b !== "B") {
  console.error(`a=${JSON.stringify(a)} b=${JSON.stringify(b)}, expected "A" and "B"`);
  process.exit(1);
}
console.log("a=A b=B");
