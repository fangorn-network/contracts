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

// ─── Contract Address ─────────────────────────────────────────────────────────

export const SETTLEMENT_REGISTRY = "0x4536881306ee355c2f18ae81658771c4488139a3" as Address;

// ─── ABI ─────────────────────────────────────────────────────────────────────

export const REGISTRY_ABI = [
  {
    name: "createResource",
    type: "function",
    inputs: [{ name: "resourceId", type: "bytes32" }],
    outputs: [{ name: "groupId", type: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    name: "register",
    type: "function",
    inputs: [
      { name: "resourceId",         type: "bytes32" },
      { name: "identityCommitment", type: "uint256" },
      { name: "from",               type: "address" },
      { name: "to",                 type: "address" },
      { name: "amount",             type: "uint256" },
      { name: "validAfter",         type: "uint256" },
      { name: "validBefore",        type: "uint256" },
      { name: "nonce",              type: "bytes32" },
      { name: "v",                  type: "uint8"   },
      { name: "r",                  type: "bytes32" },
      { name: "s",                  type: "bytes32" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
  {
    name: "settle",
    type: "function",
    inputs: [
      { name: "resourceId",    type: "bytes32"    },
      { name: "nullifierHash", type: "uint256"    },
      { name: "message",       type: "uint256"    },
      { name: "merkleRoot",    type: "uint256"    },
      { name: "proof",         type: "uint256[8]" },
      { name: "hookData",      type: "bytes"      },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    name: "getGroupId",
    type: "function",
    inputs: [{ name: "resourceId", type: "bytes32" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    name: "isSettled",
    type: "function",
    inputs: [{ name: "nullifierHash", type: "uint256" }],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
] as const;

// ─── Identity ─────────────────────────────────────────────────────────────────

export function createIdentity(): Identity { return new Identity(); }
export function restoreIdentity(exported: string): Identity { return new Identity(exported); }

// ─── createResource ───────────────────────────────────────────────────────────

export interface CreateResourceParams {
  resourceId:      Hex;
  ownerPrivateKey: Hex;
  chain:           Chain;
  rpcUrl:          string;
}

export async function createResource(params: CreateResourceParams): Promise<Hex> {
  const { resourceId, ownerPrivateKey, chain, rpcUrl } = params;
  const walletClient = createWalletClient({
    account:   privateKeyToAccount(ownerPrivateKey),
    chain,
    transport: http(rpcUrl),
  });
  const txHash = await walletClient.writeContract({
    address: SETTLEMENT_REGISTRY, abi: REGISTRY_ABI,
    functionName: "createResource", args: [resourceId],
    gas: 5_000_000n,
  });
  console.log(`[createResource] tx: ${txHash}`);
  return txHash;
}

// ─── Phase 1: Pay & Register ──────────────────────────────────────────────────

export interface RegisterParams {
  resourceId:         Hex;
  identity:           Identity;
  burnerPrivateKey:   Hex;
  paymentRecipient:   Address;
  amount:             bigint;
  relayerPrivateKey?: Hex;
  chain:              Chain;
  rpcUrl:             string;
  usdcAddress:        Address;
  usdcDomainName:     string;   // e.g. "USD Coin"
  usdcDomainVersion:  string;   // e.g. "2"
}

export async function register(params: RegisterParams): Promise<Hex> {
  const {
    resourceId, identity, burnerPrivateKey, paymentRecipient,
    amount, chain, rpcUrl, usdcAddress, usdcDomainName, usdcDomainVersion,
  } = params;

  const burner       = privateKeyToAccount(burnerPrivateKey);
  const burnerWallet = createWalletClient({ account: burner, chain, transport: http(rpcUrl) });

  const validAfter  = 0n;
  const validBefore = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const nonceBytes  = crypto.getRandomValues(new Uint8Array(32));
  const nonce       = `0x${Array.from(nonceBytes).map(b => b.toString(16).padStart(2, '0')).join('')}` as Hex;

  const sig = await burnerWallet.signTypedData({
    domain: { name: usdcDomainName, version: usdcDomainVersion, chainId: chain.id, verifyingContract: usdcAddress },
    types: {
      TransferWithAuthorization: [
        { name: "from",        type: "address" },
        { name: "to",          type: "address" },
        { name: "value",       type: "uint256" },
        { name: "validAfter",  type: "uint256" },
        { name: "validBefore", type: "uint256" },
        { name: "nonce",       type: "bytes32" },
      ],
    },
    primaryType: "TransferWithAuthorization",
    message: { from: burner.address, to: paymentRecipient, value: amount, validAfter, validBefore, nonce },
  });

  // parseSignature handles both compact (64-byte) and standard (65-byte) sigs
  const { v, r, s } = parseSignature(sig);

  const submitter = createWalletClient({
    account:   privateKeyToAccount(params.relayerPrivateKey ?? burnerPrivateKey),
    chain,
    transport: http(rpcUrl),
  });

  const txHash = await submitter.writeContract({
    address: SETTLEMENT_REGISTRY, abi: REGISTRY_ABI,
    functionName: "register",
    gas: 5_000_000n,
    args: [
      resourceId, identity.commitment,
      burner.address, paymentRecipient,
      amount, validAfter, validBefore, nonce,
      Number(v), r, s,
    ],
  });

  console.log(`[register] tx: ${txHash}`);
  return txHash;
}

// ─── Phase 2: Prove & Settle ──────────────────────────────────────────────────

export interface SettleParams {
  resourceId:     Hex;
  identity:       Identity;
  stealthAddress: Address;
  hookData?:      Hex;
  callerKey:      Hex;
  chain:          Chain;
  rpcUrl:         string;
}

export async function settle(params: SettleParams): Promise<Hex> {
  const { resourceId, identity, stealthAddress, callerKey, chain, rpcUrl } = params;

  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });

  const groupId = await publicClient.readContract({
    address: SETTLEMENT_REGISTRY, abi: REGISTRY_ABI,
    functionName: "getGroupId", args: [resourceId],
  });
  if (groupId === 0n) throw new Error(`No group for ${resourceId} — was createResource() called?`);

  const group = await fetchGroup(resourceId, rpcUrl, chain);

  // proof.points is PackedGroth16Proof (string[8]) — map to bigint[8] for the contract
  const proof: SemaphoreProof = await generateProof(identity, group, BigInt(stealthAddress), groupId);

  const hookData = params.hookData ?? encodeAbiParameters(
    parseAbiParameters("address, string"),
    [stealthAddress, ""],
  );

  const txHash = await createWalletClient({
    account: privateKeyToAccount(callerKey), chain, transport: http(rpcUrl),
  }).writeContract({
    address: SETTLEMENT_REGISTRY, abi: REGISTRY_ABI,
    functionName: "settle",
    gas: 8_000_000n,
    args: [
      resourceId,
      BigInt(proof.nullifier),
      BigInt(proof.message),
      BigInt(proof.merkleTreeRoot),
      proof.points.map(BigInt) as [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint],
      hookData,
    ],
  });

  console.log(`[settle] tx: ${txHash}`);
  return txHash;
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
        { name: "resourceId",         type: "bytes32", indexed: true  },
        { name: "groupId",            type: "uint256", indexed: true  },
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