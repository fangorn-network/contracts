import { Identity } from "@semaphore-protocol/identity";
import { Group } from "@semaphore-protocol/group";
import { generateProof, type SemaphoreProof } from "@semaphore-protocol/proof";
import {
  createWalletClient,
  createPublicClient,
  http,
  encodePacked,
  keccak256,
  encodeAbiParameters,
  parseAbiParameters,
  parseSignature,
  type Chain,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { SETTLEMENT_REGISTRY_ABI } from "./abi";

// ─── Contract Address ─────────────────────────────────────────────────────────

export const SETTLEMENT_REGISTRY = "0xc3bddddcf640eedbb6386b625ab15366cdebaba9" as Address;

// ─── Identity ─────────────────────────────────────────────────────────────────

export function createIdentity(): Identity { return new Identity(); }
export function restoreIdentity(exported: string): Identity { return new Identity(exported); }

// ─── createResource ───────────────────────────────────────────────────────────

export interface CreateResourceParams {
  resourceId: Hex;
  ownerPrivateKey: Hex;
  chain: Chain;
  rpcUrl: string;
}

export async function createResource(params: CreateResourceParams): Promise<Hex> {
  const { resourceId, ownerPrivateKey, chain, rpcUrl } = params;
  const walletClient = createWalletClient({
    account: privateKeyToAccount(ownerPrivateKey),
    chain,
    transport: http(rpcUrl),
  });
  const txHash = await walletClient.writeContract({
    address: SETTLEMENT_REGISTRY, abi: SETTLEMENT_REGISTRY_ABI,
    functionName: "createResource", args: [resourceId, BigInt(1n)],
    gas: 5_000_000n,
  });
  console.log(`[createResource] tx: ${txHash}`);
  return txHash;
}

export async function checkResourceExists(owner: Address, resourceId: Hex, chain: Chain, rpcUrl: string) {
  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });

  const groupId = await publicClient.readContract({
    address: SETTLEMENT_REGISTRY,
    abi: SETTLEMENT_REGISTRY_ABI,
    functionName: "getGroupId",
    args: [resourceId],
  });

  if (!groupId) {
    process.exit(1)
  } else {
    console.log('resource existence confirmed')
  }

  const actualOwner = await publicClient.readContract({
    address: SETTLEMENT_REGISTRY,
    abi: SETTLEMENT_REGISTRY_ABI,
    functionName: "getOwner",
    args: [resourceId],
  });

  if (!actualOwner) {
    process.exit(1)
  } else {
    // if ("0x147c24c5Ea2f1EE1ac42AD16820De23bBba45Ef6" != actualOwner) {
    //   process.exit(1)
    // } else {
      console.log('owned by ' + actualOwner)
    // }
  }
}

export async function addSeedMember(params: CreateResourceParams): Promise<Hex> {
  const { resourceId, ownerPrivateKey, chain, rpcUrl } = params;
  const walletClient = createWalletClient({
    account: privateKeyToAccount(ownerPrivateKey),
    chain,
    transport: http(rpcUrl),
  });
  const txHash = await walletClient.writeContract({
    address: SETTLEMENT_REGISTRY,
    abi: SETTLEMENT_REGISTRY_ABI,
    functionName: "addSeedMember",
    args: [resourceId],
    gas: 5_000_000n,
  });
  console.log(`[addSeedMember] tx: ${txHash}`);
  return txHash;
}


// ─── Phase 1: Pay & Register ──────────────────────────────────────────────────

export interface RegisterParams {
  resourceId: Hex;
  identity: Identity;
  burnerPrivateKey: Hex;
  paymentRecipient: Address;
  amount: bigint;
  relayerPrivateKey?: Hex;
  chain: Chain;
  rpcUrl: string;
  usdcAddress: Address;
  usdcDomainName: string;   // e.g. "USD Coin"
  usdcDomainVersion: string;   // e.g. "2"
}

export async function register(params: RegisterParams): Promise<Hex> {
  const {
    resourceId, identity, burnerPrivateKey, paymentRecipient,
    amount, chain, rpcUrl, usdcAddress, usdcDomainName, usdcDomainVersion,
  } = params;

  const burner = privateKeyToAccount(burnerPrivateKey);
  const burnerWallet = createWalletClient({ account: burner, chain, transport: http(rpcUrl) });

  const validAfter = 0n;
  const validBefore = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const nonceBytes = crypto.getRandomValues(new Uint8Array(32));
  const nonce = `0x${Array.from(nonceBytes).map(b => b.toString(16).padStart(2, '0')).join('')}` as Hex;

  const sig = await burnerWallet.signTypedData({
    domain: { name: usdcDomainName, version: usdcDomainVersion, chainId: chain.id, verifyingContract: usdcAddress },
    types: {
      TransferWithAuthorization: [
        { name: "from", type: "address" },
        { name: "to", type: "address" },
        { name: "value", type: "uint256" },
        { name: "validAfter", type: "uint256" },
        { name: "validBefore", type: "uint256" },
        { name: "nonce", type: "bytes32" },
      ],
    },
    primaryType: "TransferWithAuthorization",
    message: { from: burner.address, to: paymentRecipient, value: amount, validAfter, validBefore, nonce },
  });

  // parseSignature handles both compact (64-byte) and standard (65-byte) sigs
  const { v, r, s } = parseSignature(sig);

  const submitter = createWalletClient({
    account: privateKeyToAccount(params.relayerPrivateKey ?? burnerPrivateKey),
    chain,
    transport: http(rpcUrl),
  });

  const txHash = await submitter.writeContract({
    address: SETTLEMENT_REGISTRY,
    abi: SETTLEMENT_REGISTRY_ABI,
    functionName: "register",
    gas: 5_000_000n,
    args: [
      resourceId,
      identity.commitment,
      burner.address,
      paymentRecipient,
      amount,
      validAfter,
      validBefore,
      nonce,
      Number(v), r, s,
    ],
  });

  console.log(`[register] tx: ${txHash}`);
  return txHash;
}

export async function checkRegistration(resourceId: Hex, identity: Identity, chain: Chain, rpcUrl: string) {
  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });

  const isRegistered = await publicClient.readContract({
    address: SETTLEMENT_REGISTRY,
    abi: SETTLEMENT_REGISTRY_ABI,
    functionName: "isRegistered",
    args: [resourceId, identity.commitment],
  });

  if (!isRegistered) {
    console.log('the id is NOT registered properly')
    process.exit(1)
  } else {
    console.log('id registered for the resource? ' + isRegistered)
  }
}

// ─── Phase 2: Prove & Settle ──────────────────────────────────────────────────

export interface SettleParams {
  resourceId: Hex;
  identity: Identity;
  stealthAddress: Address;
  hookData?: Hex;
  callerKey: Hex;
  chain: Chain;
  rpcUrl: string;
}

export async function settle(params: SettleParams): Promise<Hex> {
  const { resourceId, identity, stealthAddress, callerKey, chain, rpcUrl } = params;

  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });

  const groupId = await publicClient.readContract({
    address: SETTLEMENT_REGISTRY,
    abi: SETTLEMENT_REGISTRY_ABI,
    functionName: "getGroupId",
    args: [resourceId],
  });
  if (groupId === 0n) throw new Error(`No group for ${resourceId} — was createResource() called?`);

  const group = await fetchGroup(resourceId, rpcUrl, chain);

  // proof.points is PackedGroth16Proof (string[8]) — map to bigint[8] for the contract
  const proof: SemaphoreProof = await generateProof(identity, group, BigInt(stealthAddress), groupId);

  // const hookData = params.hookData ?? encodeAbiParameters(
  //   parseAbiParameters("address, string"),
  //   [stealthAddress, ""],
  // );

  const semaphoreAddress = "0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D";
  const onChainRoot = await publicClient.readContract({
    address: semaphoreAddress,
    abi: [{
      name: "getMerkleTreeRoot",
      type: "function",
      inputs: [{ name: "groupId", type: "uint256" }],
      outputs: [{ type: "uint256" }],
      stateMutability: "view",
    }],
    functionName: "getMerkleTreeRoot",
    args: [groupId],
  });
  console.log("on-chain root :", onChainRoot.toString());
  console.log("proof root    :", proof.merkleTreeRoot);

  const txHash = await createWalletClient({
    account: privateKeyToAccount(callerKey), chain, transport: http(rpcUrl),
  }).writeContract({
    address: SETTLEMENT_REGISTRY,
    abi: SETTLEMENT_REGISTRY_ABI,
    functionName: "settle",
    gas: 8_000_000n,
    args: [
      resourceId,
      params.stealthAddress,
      BigInt(proof.merkleTreeDepth),
      BigInt(proof.merkleTreeRoot),
      BigInt(proof.nullifier),
      BigInt(proof.message),
      proof.points.map(BigInt) as [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint],
      [],
    ],
  });

  console.log(`[settle] tx: ${txHash}`);
  return txHash;
}

export async function checkSettlement(stealthAddress: Address, resourceId: Hex, chain: Chain, rpcUrl: string) {
  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });

  const isSettled = await publicClient.readContract({
    address: SETTLEMENT_REGISTRY,
    abi: SETTLEMENT_REGISTRY_ABI,
    functionName: "isSettled",
    args: [stealthAddress, resourceId],
  });

  if (!isSettled) {
    console.log('no settlement recorded :(((')
    process.exit(1)
  } else {
    console.log('id settled for the resource? ' + isSettled)
  }
}

// ─── Group Reconstruction ─────────────────────────────────────────────────────

async function fetchGroup(resourceId: Hex, rpcUrl: string, chain: Chain): Promise<Group> {
  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });

  // Fetch all MemberRegistered logs for this contract without topic filters,
  // then filter in JS. Avoids viem topic-encoding edge cases for indexed params.
  const logs = await publicClient.getLogs({
    address: SETTLEMENT_REGISTRY,
    event: {
      name: "MemberRegistered", type: "event",
      inputs: [
        { name: "resourceId", type: "bytes32", indexed: true },
        { name: "groupId", type: "uint256", indexed: true },
        { name: "identityCommitment", type: "uint256", indexed: false },
      ],
    },
    fromBlock: 0n,
  });

  console.log(`[fetchGroup] total MemberRegistered logs: ${logs.length}`);

  // Filter in JS — compare hex strings case-insensitively
  const filtered = logs.filter(
    (log) => log.args.resourceId?.toLowerCase() === resourceId.toLowerCase()
  );

  console.log(`[fetchGroup] logs matching resourceId ${resourceId}: ${filtered.length}`);
  for (const log of filtered) console.log(`  commitment: ${log.args.identityCommitment}`);

  const group = new Group();
  for (const log of filtered) group.addMember(log.args.identityCommitment!.toString());

  console.log(`[fetchGroup] group size: ${group.size}`);
  return group;
}

// ─── Utilities ────────────────────────────────────────────────────────────────

export function deriveResourceId(owner: Address, schemaId: Hex, tag: string): Hex {
  return keccak256(
    encodePacked(
      ["address", "bytes32", "bytes"],
      [owner, schemaId, `0x${Buffer.from(tag).toString("hex")}`],
    ),
  );
}