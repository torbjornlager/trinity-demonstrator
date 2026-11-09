"use strict";

const fs = require("node:fs");
const path = require("node:path");
const loadEngine = require(path.join(__dirname, "../../web/swipl-bundle.js"));

async function main() {
  const goal = JSON.parse(fs.readFileSync(0, "utf8"));
  const engine = await loadEngine({ arguments: ["-q", "--nosignals"] });
  const answer = engine.prolog.query(
    `(${goal}), with_output_to(atom(Text), writeq(Outcome))`
  ).once();
  if (!answer || typeof answer.Text !== "string") {
    throw new Error("SWI-WASM returned no observation");
  }
  console.log("portable_core_result=" + answer.Text);
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
