/**
 * demo.ts — Fangorn SettlementRegistry two-phase flow
 *
 * Run:
 *   npx tsx demo.ts
 *
 * Dependencies:
 *   npm i viem @semaphore-protocol/identity @semaphore-protocol/group @semaphore-protocol/proof tsx
 *
 * Three wallets are involved:
 *   OWNER_KEY   — schema owner, calls createResource(), receives USDC payment
 *   BURNER_KEY  — holds USDC, signs ERC-3009 auth; never linked to identity
 *   CALLER_KEY  — submits settle(); any wallet works, we reuse owner here for simplicity
 *
 * On Arbitrum Sepolia there is no official USDC with ERC-3009 (Circle only deploys
 * that on mainnet). For the demo we use amount=0 and point to a mock USDC address,
 * which means register() will still exercise the Semaphore group logic but skip
 * the actual token transfer. Swap in real USDC + amount for a production test.
 */

import { createPublicClient, encodePacked, Hex, http, keccak256, parseEventLogs } from "viem";
import { arbitrumSepolia } from "viem/chains";
import {
  createIdentity,
  createResource,
  register,
  settle,
  deriveResourceId,
  type CreateResourceParams,
  type RegisterParams,
  type SettleParams,
  checkResourceExists,
  checkRegistration,
  addSeedMember,
  checkSettlement,
} from "./utils";

// Config
const RPC_URL = "https://sepolia-rollup.arbitrum.io/rpc";
const CHAIN = arbitrumSepolia;
const OWNER_KEY = (process.env.OWNER_KEY ?? "0xde0e6c1c331fcd8692463d6ffcf20f9f2e1847264f7a3f578cf54f62f05196cb") as `0x${string}`;
const BURNER_KEY = (process.env.BURNER_KEY ?? "0xde0e6c1c331fcd8692463d6ffcf20f9f2e1847264f7a3f578cf54f62f05196cb") as `0x${string}`;
const CALLER_KEY = (process.env.CALLER_KEY ?? OWNER_KEY) as `0x${string}`;
// Stealth address: in production derive this via EIP-5564 from the user's spend key.
// For the demo it's just any address that will receive the soulbound NFT (or timelock entry).
const STEALTH_ADDRESS = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" as `0x${string}`;
// setup payment params (smallest USDC amt > 0 we can send)
const USDC_ADDRESS = "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d" as `0x${string}`;
const AMOUNT = 1n;

// Derive a deterministic resource_id
//
// In Fangorn this is keccak256(ownerAddress || schemaId || tag).
// Using a fixed schemaId and tag here so the resource_id is stable across runs
// (re-running the demo with the same OWNER_KEY will hit AlreadyRegistered on
// createResource).

import { privateKeyToAccount, privateKeyToAddress } from "viem/accounts";
import { SETTLEMENT_REGISTRY_ABI } from "./abi";

// mock fangorn data
const ownerAddress = privateKeyToAccount(OWNER_KEY).address;
const SCHEMA_ID = "0x0000000000000000000000000000000000000000000000000000000000000001" as `0x${string}`;
const TAG = "demo-track-002";
const RESOURCE_ID = keccak256(
  encodePacked(
    ["address", "uint256"],
    [ownerAddress, BigInt(Date.now())]
  )
) as Hex;
console.log("resourceId:", RESOURCE_ID);
const publicClient = createPublicClient({ chain: CHAIN, transport: http(RPC_URL) });

async function main() {
  console.log("\n=== Fangorn SettlementRegistry Demo ===\n");
  console.log(`owner    : ${ownerAddress}`);
  console.log(`resourceId: ${RESOURCE_ID}\n`);

  // Step 0: Create a fresh Semaphore identity
  const identity = createIdentity();
  console.log(`identity commitment: ${identity.commitment}\n`);

  {
    // Step 1: createResource
    const params: CreateResourceParams = {
      resourceId: RESOURCE_ID,
      ownerPrivateKey: OWNER_KEY,
      chain: CHAIN,
      rpcUrl: RPC_URL,
    };

    let hash = await createResource(params);
    console.log("waiting for createResource...");
    let receipt = await publicClient.waitForTransactionReceipt({ hash });
    // the call should not revert
    if (receipt.status === "reverted") {
      console.error("the call reverted :(")
      process.exit(1)
    } else {
      console.log('resource created')
    }

    console.log("createResource confirmed ✓\n");
    // confirm group id exists
    await checkResourceExists(privateKeyToAddress(OWNER_KEY), RESOURCE_ID, arbitrumSepolia, RPC_URL);
    // add seed member
    hash = await addSeedMember(params)
    receipt = await publicClient.waitForTransactionReceipt({ hash });
    // the call should not revert
    if (receipt.status === "reverted") {
      console.error("the call reverted :(")
      process.exit(1)
    } else {
      console.log('Seed member added')
    }
  }
  // Step 2: register (Phase 1 — pay + join group)
  //
  // The burner signs the ERC-3009 auth off-chain. The identity commitment goes
  // on-chain — it's unlinkable to the burner address or any other wallet.
  {
    const params: RegisterParams = {
      resourceId: RESOURCE_ID,
      identity,
      burnerPrivateKey: BURNER_KEY,
      paymentRecipient: ownerAddress,       // USDC recipient
      amount: AMOUNT,
      relayerPrivateKey: CALLER_KEY,          // who submits the tx (irrelevant to privacy)
      chain: CHAIN,
      rpcUrl: RPC_URL,
      usdcAddress: USDC_ADDRESS,
      usdcDomainName: "USD Coin",          // must match USDC contract's EIP-712 domain
      usdcDomainVersion: "2",
    };
    const hash = await register(params);
    console.log("waiting for register...");

    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status === "reverted") {
      console.error("registration failed")
      process.exit(1)
    }
    console.log("register confirmed ✓\n");

    // verify that the identity is registered
    await checkRegistration(RESOURCE_ID, identity, arbitrumSepolia, RPC_URL)
  }

  // ── Step 3: settle (Phase 2 — ZK proof + hook) ────────────────────────────
  //
  // Any wallet can submit this. The Semaphore proof is what authorizes it.
  // The hook fires atomically — AccessNFTHook mints a soulbound NFT to STEALTH_ADDRESS.
  {
    const params: SettleParams = {
      resourceId: RESOURCE_ID,
      identity,
      stealthAddress: STEALTH_ADDRESS,
      callerKey: CALLER_KEY,
      chain: CHAIN,
      rpcUrl: RPC_URL,
      hookData: "0x0",
      // hookData defaults to abi.encode(stealthAddress, "") if omitted
    };

    const hash = await settle(params);
    console.log("waiting for settle...");
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status === "reverted") {
      console.error("settle failed: reverted!")
      process.exit(1)
    }

    await checkSettlement(params.stealthAddress, RESOURCE_ID, CHAIN, RPC_URL);
  }

  // await debugSettle(RESOURCE_ID, RPC_URL, CHAIN)
  console.log("=== demo complete ===");
  console.log(`→ stealth address ${STEALTH_ADDRESS} should now hold an access token`);
  console.log(`→ check AccessNFTHook.hasAccess(${STEALTH_ADDRESS}, ${RESOURCE_ID}) on-chain`);
}


main().catch(console.error);