// Reference DAG-CBOR encoding of a DataRegistry commit, for the differential test in
// test/DataRegistry.invariant.t.sol. Same shape as the SDK's `commitHead`
// (fangorn/src/engine/index.ts): @ipld/dag-cbor encode, sha256 digest.
//
//   node commitHead.mjs <node_modules dir> <repo hex> <epoch> <parent> <diff> <root> <car hex>
//
// Prints the digest as 0x-hex, or 0x (empty) when the inputs have no DAG-CBOR form
// (repo not UTF-8, car not a CID): the test discards those runs.
import { createRequire } from "node:module";
import { createHash } from "node:crypto";

const [nm, repoHex, epochStr, parent, diff, root, carHex] = process.argv.slice(2);
const require = createRequire(nm.replace(/\/?$/, "/"));
const dagCbor = require("@ipld/dag-cbor");
const { CID } = require("multiformats/cid");
const Digest = require("multiformats/hashes/digest");

const hex = (h) => Buffer.from(h.replace(/^0x/, ""), "hex");
const link = (d) => CID.createV1(0x71, Digest.create(0x12, hex(d)));
const ZERO = "0x" + "00".repeat(32);

let repo, car;
try {
  repo = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(hex(repoHex));
  car = CID.decode(hex(carHex));
} catch {
  process.stdout.write("0x");
  process.exit(0);
}
const e = BigInt(epochStr);
const block = dagCbor.encode({
  epoch: e > BigInt(Number.MAX_SAFE_INTEGER) ? e : Number(e),
  parent: parent.toLowerCase() === ZERO ? null : link(parent),
  diff: link(diff),
  root: link(root),
  repo,
  car,
});
process.stdout.write("0x" + createHash("sha256").update(block).digest("hex"));
