// SettlementRegistry — Fangorn Network
//
// Privacy-preserving settlement with Semaphore ZK nullifiers and pluggable hooks.
//
// ┌─────────────────────────────────────────────────────────────────────────┐
// │  TWO-PHASE FLOW                                                         │
// │                                                                         │
// │  Phase 1 — register()                                                   │
// │    Burner wallet pays via ERC-3009 transferWithAuthorization.           │
// │    Identity commitment is added to the resource's Semaphore group.      │
// │    The paying address and the identity are never linked on-chain.       │
// │                                                                         │
// │  Phase 2 — settle()                                                     │
// │    User presents a Groth16 ZK proof of group membership.               │
// │    Nullifier recorded (prevents double-claim).                          │
// │    Registered hook fires with the proof's signal (e.g. stealth addr).  │
// └─────────────────────────────────────────────────────────────────────────┘
//
// Semaphore V4 — same addresses on Arbitrum mainnet + Arbitrum Sepolia:
//   SemaphoreVerifier : 0x4DeC9E3784EcC1eE002001BfE91deEf4A48931f8
//   Semaphore         : 0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D
//
// External calls use RawCall + manual ABI encoding throughout (no sol_interface!).
// This matches the pattern established in DataSourceRegistry and avoids the
// Call::new(self) + self.vm() dual-arg issue in Stylus SDK 0.6.x.

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{Address, FixedBytes, U256, keccak256},
    call::RawCall,
    prelude::*,
    storage::*,
};

// ─── Events & Errors ──────────────────────────────────────────────────────────

sol! {
    // Phase 1 completion. identity_commitment is public but not wallet-linked.
    event MemberRegistered(
        bytes32 indexed resourceId,
        uint256 indexed groupId,
        uint256 identityCommitment
    );

    // Phase 2 completion. nullifier_hash is the sole on-chain record
    event SettlementFinalized(
        bytes32 indexed resourceId,
        uint256 indexed nullifierHash,
        uint256 message
    );

    event HookRegistered(bytes32 indexed resourceId, address hook);
    event ResourceCreated(bytes32 indexed resourceId, uint256 groupId, address owner, uint256 price);
    event PriceUpdated(bytes32 indexed resourceId, address owner, uint256 price);

    // identity already registered for this resource
    error AlreadyRegistered();   
    // this nullifier has already been used
    error AlreadySettled();
    // The payment amount is incorrect
    error IncorrectPaymentAmount();
    // ERC-3009 call reverted
    error TransferFailed();      
    // ZK proof rejected by Semaphore verifier
    error VerificationFailed(); 
    // caller != resource owner 
    error NotResourceOwner();
    // resource_id has no associated group   
    error ResourceNotFound();
    // afterSettle() reverted
    error HookFailed();          
    // Semaphore createGroup() failed
    error GroupCreationFailed(); 
}

#[derive(SolidityError)]
pub enum SettlementError {
    AlreadyRegistered(AlreadyRegistered),
    AlreadySettled(AlreadySettled),
    IncorrectPaymentAmount(IncorrectPaymentAmount),
    TransferFailed(TransferFailed),
    VerificationFailed(VerificationFailed),
    NotResourceOwner(NotResourceOwner),
    ResourceNotFound(ResourceNotFound),
    HookFailed(HookFailed),
    GroupCreationFailed(GroupCreationFailed),
}

#[storage]
#[entrypoint]
pub struct SettlementRegistry {
    // Protocol addresses (immutable after init)
    usdc_address:      StorageAddress,
    semaphore_address: StorageAddress,
    verifier_address:  StorageAddress,

    // resource_id => Semaphore group_id (0 = resource not created)
    resource_groups: StorageMap<FixedBytes<32>, StorageU256>,

    // resource_id => price (in USDC)
    resource_price: StorageMap<FixedBytes<32>, StorageU256>,

    // resource_id => owner (only owner can set hooks)
    resource_owners: StorageMap<FixedBytes<32>, StorageAddress>,

    // resource_id => hook contract (Address::ZERO = no hook)
    resource_hooks: StorageMap<FixedBytes<32>, StorageAddress>,

    // Semaphore nullifier_hash => claimed
    // Prevents double-claim regardless of which wallet submits the proof.
    nullifiers: StorageMap<U256, StorageBool>,

    // keccak256(resource_id ++ identity_commitment) => registered
    // Prevents the same Semaphore identity from paying twice per resource.
    registrations: StorageMap<FixedBytes<32>, StorageBool>,
}

#[public]
impl SettlementRegistry {

    #[constructor]
    pub fn init(
        &mut self,
        usdc_address:      Address, // arb sep 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d
        semaphore_address: Address, // arb sep 0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D
        verifier_address:  Address, // arb sep 0x4DeC9E3784EcC1eE002001BfE91deEf4A48931f8
    ) {
        self.usdc_address.set(usdc_address);
        self.semaphore_address.set(semaphore_address);
        self.verifier_address.set(verifier_address);
    }

    /// Create a new resource and its Semaphore group.
    /// Caller becomes the resource owner.
    ///
    /// In Fangorn: resource_id = keccak256(owner_addr ++ schema_id ++ tag)
    /// Schema owners call this once when publishing a content asset or data stream.
    pub fn create_resource(
        &mut self,
        resource_id: FixedBytes<32>,
        price: U256,
    ) -> Result<U256, SettlementError> {
        if self.resource_groups.get(resource_id) != U256::ZERO {
            return Err(SettlementError::AlreadyRegistered(AlreadyRegistered {}));
        }

        // createGroup() (no args) returns uint256 group_id.
        // This contract becomes the Semaphore group admin, so only this contract
        // can call addMember() for this group going forward.
        let ret = unsafe {
            RawCall::new(self.vm())
                .call(self.semaphore_address.get(), &calldata_create_group())
        }
        .map_err(|_| SettlementError::GroupCreationFailed(GroupCreationFailed {}))?;

        let group_id = decode_u256(&ret)
            .ok_or(SettlementError::GroupCreationFailed(GroupCreationFailed {}))?;

        self.resource_groups.setter(resource_id).set(group_id);
        let caller = self.vm().msg_sender();
        self.resource_owners.setter(resource_id).set(caller);
        self.resource_price.setter(resource_id).set(price);

        self.vm().log(ResourceCreated {
            resourceId: resource_id,
            groupId: group_id,
            owner: caller,
            price: price
        });

        Ok(group_id)
    }

    /// Update the registered price for accessing the resource
    pub fn update_price(
         &mut self,
        resource_id: FixedBytes<32>,
        price: U256,
    ) -> Result<(), SettlementError> {
        let owner = self.resource_owners.get(resource_id);
        if owner == Address::ZERO {
            return Err(SettlementError::ResourceNotFound(ResourceNotFound {}));
        }
        if self.vm().msg_sender() != owner {
            return Err(SettlementError::NotResourceOwner(NotResourceOwner {}));
        }

        // update price
        self.resource_price.setter(resource_id).set(price);

        self.vm().log(PriceUpdated {
            resourceId: resource_id,
            owner: owner,
            price: price
        });

        Ok(())
    }

    /// Register or replace the settlement hook for a resource.
    /// Only callable by the resource owner.
    /// Pass Address::ZERO to remove the hook (settlements still record nullifiers).
    pub fn register_hook(
        &mut self,
        resource_id: FixedBytes<32>,
        hook:        Address,
    ) -> Result<(), SettlementError> {
        let owner = self.resource_owners.get(resource_id);
        if owner == Address::ZERO {
            return Err(SettlementError::ResourceNotFound(ResourceNotFound {}));
        }
        if self.vm().msg_sender() != owner {
            return Err(SettlementError::NotResourceOwner(NotResourceOwner {}));
        }

        self.resource_hooks.setter(resource_id).set(hook);
        self.vm().log(HookRegistered { resourceId: resource_id, hook });
        Ok(())
    }

    /// Pay for access and register a Semaphore identity in the resource's group.
    ///
    /// Privacy model:
    ///   - `from` is a burner/stealth wallet that holds USDC and has signed the
    ///     ERC-3009 authorization off-chain. It never calls any contract directly.
    ///   - `identity_commitment` is derived from the user's Semaphore secret, which
    ///     never leaves the client. It appears on-chain but is unlinkable to `from`.
    ///   - The transaction sender (msg.sender) can be a relayer — also unlinkable.
    ///
    /// Off-chain setup (@semaphore-protocol/identity):
    ///   const identity = new Identity()
    ///   const commitment = identity.commitment   // pass as identity_commitment
    ///   // Persist identity.export() encrypted client-side — NEVER transmit secret
    ///
    #[payable]
    pub fn register(
        &mut self,
        resource_id:         FixedBytes<32>,
        identity_commitment: U256,
        from:        Address,
        to:          Address,         // recipient of USDC (e.g. schema owner treasury)
        amount:      U256,
        valid_after: U256,
        valid_before:U256,
        nonce:       FixedBytes<32>,
        v: u8,
        r: FixedBytes<32>,
        s: FixedBytes<32>,
    ) -> Result<(), SettlementError> {
        // check if the group exists
        let group_id = self.resource_groups.get(resource_id);
        if group_id == U256::ZERO {
            return Err(SettlementError::ResourceNotFound(ResourceNotFound {}));
        }

        // Prevent double-registration for this (resource, identity) pair
        let reg_key = hash_concat(
            resource_id.as_slice(),
            &identity_commitment.to_be_bytes::<32>(),
        );
        if self.registrations.get(reg_key) {
            return Err(SettlementError::AlreadyRegistered(AlreadyRegistered {}));
        }

        // Ensure payment amount is exact
        let expected_price = self.resource_price.get(resource_id);
        if amount != expected_price {
            return Err(SettlementError::IncorrectPaymentAmount(IncorrectPaymentAmount {}));
        }

        // transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)
        // All static params — straightforward ABI encoding, no dynamic slots needed.
        let payment_calldata = calldata_transfer_with_authorization(
            from, to, amount, valid_after, valid_before, nonce, v, r, s,
        );
        unsafe {
            RawCall::new(self.vm())
                .call(self.usdc_address.get(), &payment_calldata)
        }
        .map_err(|_| SettlementError::TransferFailed(TransferFailed {}))?;

        // addMember(uint256 groupId, uint256 identityCommitment)
        // This is the only on-chain entitlement record — no wallet, no amount.
        let add_calldata = calldata_add_member(group_id, identity_commitment);
        unsafe {
            RawCall::new(self.vm())
                .call(self.semaphore_address.get(), &add_calldata)
        }
        .map_err(|_| SettlementError::GroupCreationFailed(GroupCreationFailed {}))?;

        self.registrations.setter(reg_key).set(true);

        self.vm().log(MemberRegistered {
            resourceId:         resource_id,
            groupId:            group_id,
            identityCommitment: identity_commitment,
        });

        Ok(())
    }

    /// Claim access by presenting a valid Semaphore ZK proof.
    ///
    /// The caller can be ANY address — the proof cryptographically ties the claim
    /// to the identity commitment without revealing which commitment, which wallet
    /// paid, or which wallet is claiming. A relayer can submit on the user's behalf.
    ///
    /// Proof generation (@semaphore-protocol/proof):
    ///   const proof = await generateProof(
    ///     identity,      // kept client-side
    ///     group,         // fetched from Semaphore subgraph or MemberRegistered events
    ///     message,       // your signal: encode stealth address, token id, etc. as U256
    ///     scope,         // MUST equal the group_id for this resource_id
    ///   )
    ///   // Submit: proof.nullifier, proof.merkleTreeRoot, proof.message, proof.proof[8]
    ///
    /// hook_data interpretation by hook type:
    ///   AccessNFTHook  — abi.encode(stealthAddress, metadataUri)
    ///   TimelockHook   — abi.encode(durationSeconds)
    ///   (no hook)      — only nullifier recorded; off-chain check via is_settled()
    ///
    pub fn settle(
        &mut self,
        resource_id:    FixedBytes<32>,
        nullifier_hash: U256,
        message:        U256,       // Semaphore signal — passed to hook
        merkle_root:    U256,       // Must match current group root
        proof:          [U256; 8],  // Groth16 proof
        hook_data:      Vec<u8>,    // Forwarded verbatim to afterSettle()
    ) -> Result<(), SettlementError> {
        let group_id = self.resource_groups.get(resource_id);
        if group_id == U256::ZERO {
            return Err(SettlementError::ResourceNotFound(ResourceNotFound {}));
        }

        // Nullifier check before any external calls (checks-effects-interactions)
        if self.nullifiers.get(nullifier_hash) {
            return Err(SettlementError::AlreadySettled(AlreadySettled {}));
        }

        // getMerkleTreeDepth(uint256) — static call, returns uint256
        let depth_calldata = calldata_get_merkle_tree_depth(group_id);
        let depth_ret = unsafe {
            RawCall::new_static(self.vm())
                .call(self.semaphore_address.get(), &depth_calldata)
        }
        .map_err(|_| SettlementError::VerificationFailed(VerificationFailed {}))?;

        let depth = decode_u256(&depth_ret)
            .ok_or(SettlementError::VerificationFailed(VerificationFailed {}))?;

        // verifyProof(...) — static call, reverts on invalid proof (no bool return).
        // scope = group_id: binds this proof to exactly this resource.
        // A valid proof for resource A cannot be replayed against resource B.
        let verify_calldata = calldata_verify_proof(
            depth, merkle_root, nullifier_hash, message, group_id, &proof,
        );
        unsafe {
            RawCall::new_static(self.vm())
                .call(self.verifier_address.get(), &verify_calldata)
        }
        .map_err(|_| SettlementError::VerificationFailed(VerificationFailed {}))?;

        // Commit nullifier BEFORE hook call (reentrancy protection)
        self.nullifiers.setter(nullifier_hash).set(true);

        self.vm().log(SettlementFinalized {
            resourceId:    resource_id,
            nullifierHash: nullifier_hash,
            message,
        });

        // Dispatch hook atomically (hook revert = settle revert)
        let hook_addr = self.resource_hooks.get(resource_id);
        if hook_addr != Address::ZERO {
            // afterSettle(bytes32,uint256,uint256,bytes) — `bytes` is dynamic,
            // so we use the full ABI dynamic encoding helper.
            let hook_calldata = calldata_after_settle(
                resource_id, nullifier_hash, message, &hook_data,
            );
            unsafe {
                RawCall::new(self.vm())
                    .call(hook_addr, &hook_calldata)
            }
            .map_err(|_| SettlementError::HookFailed(HookFailed {}))?;
        }

        Ok(())
    }

    // ── View ──────────────────────────────────────────────────────────────────

    pub fn is_settled(&self, nullifier_hash: U256) -> bool {
        self.nullifiers.get(nullifier_hash)
    }

    pub fn get_group_id(&self, resource_id: FixedBytes<32>) -> U256 {
        self.resource_groups.get(resource_id)
    }

    pub fn get_hook(&self, resource_id: FixedBytes<32>) -> Address {
        self.resource_hooks.get(resource_id)
    }

    pub fn get_owner(&self, resource_id: FixedBytes<32>) -> Address {
        self.resource_owners.get(resource_id)
    }

    pub fn is_registered(&self, resource_id: FixedBytes<32>, identity_commitment: U256) -> bool {
        let key = hash_concat(
            resource_id.as_slice(),
            &identity_commitment.to_be_bytes::<32>(),
        );
        self.registrations.get(key)
    }
}

// ─── ABI Calldata Builders ────────────────────────────────────────────────────
//
// Manual ABI encoding following the Ethereum ABI spec.
// Static types (uint256, address, bytes32, uint8, fixed arrays) are encoded
// inline as 32-byte slots. Dynamic types (bytes) use a head/tail layout with
// an offset pointer in the head followed by length + padded data in the tail.
//
// All selectors are the first 4 bytes of keccak256("functionName(argTypes,...)").

/// createGroup() → uint256
fn calldata_create_group() -> Vec<u8> {
    // keccak256("createGroup()")
    let selector = &keccak256(b"createGroup()")[..4];
    selector.to_vec()
}

/// addMember(uint256 groupId, uint256 identityCommitment)
fn calldata_add_member(group_id: U256, identity_commitment: U256) -> Vec<u8> {
    let selector = &keccak256(b"addMember(uint256,uint256)")[..4];
    let mut cd = selector.to_vec();
    cd.extend_from_slice(&encode_u256(group_id));
    cd.extend_from_slice(&encode_u256(identity_commitment));
    cd
}

/// getMerkleTreeDepth(uint256 groupId) → uint256
fn calldata_get_merkle_tree_depth(group_id: U256) -> Vec<u8> {
    let selector = &keccak256(b"getMerkleTreeDepth(uint256)")[..4];
    let mut cd = selector.to_vec();
    cd.extend_from_slice(&encode_u256(group_id));
    cd
}

/// verifyProof(uint256,uint256,uint256,uint256,uint256,uint256[8])
///
/// uint256[8] is a fixed-size array — it is a static type under the ABI spec,
/// so all 8 elements are encoded inline (no offset pointer).
fn calldata_verify_proof(
    depth:          U256,
    merkle_root:    U256,
    nullifier_hash: U256,
    message:        U256,
    scope:          U256,
    proof:          &[U256; 8],
) -> Vec<u8> {
    let selector = &keccak256(
        b"verifyProof(uint256,uint256,uint256,uint256,uint256,uint256[8])"
    )[..4];
    let mut cd = selector.to_vec();
    cd.extend_from_slice(&encode_u256(depth));
    cd.extend_from_slice(&encode_u256(merkle_root));
    cd.extend_from_slice(&encode_u256(nullifier_hash));
    cd.extend_from_slice(&encode_u256(message));
    cd.extend_from_slice(&encode_u256(scope));
    // Inline the 8 proof elements — no offset needed for fixed arrays
    for p in proof {
        cd.extend_from_slice(&encode_u256(*p));
    }
    cd
}

/// transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)
///
/// All params are static — address and uint8 are both ABI-encoded as 32-byte
/// slots (left-padded with zeros for address, right-padded for none).
fn calldata_transfer_with_authorization(
    from:         Address,
    to:           Address,
    value:        U256,
    valid_after:  U256,
    valid_before: U256,
    nonce:        FixedBytes<32>,
    v:            u8,
    r:            FixedBytes<32>,
    s:            FixedBytes<32>,
) -> Vec<u8> {
    let selector = &keccak256(
        b"transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
    )[..4];
    let mut cd = selector.to_vec();
    cd.extend_from_slice(&encode_address(from));
    cd.extend_from_slice(&encode_address(to));
    cd.extend_from_slice(&encode_u256(value));
    cd.extend_from_slice(&encode_u256(valid_after));
    cd.extend_from_slice(&encode_u256(valid_before));
    cd.extend_from_slice(nonce.as_slice());         // bytes32: already 32 bytes
    cd.extend_from_slice(&encode_u8(v));
    cd.extend_from_slice(r.as_slice());             // bytes32: already 32 bytes
    cd.extend_from_slice(s.as_slice());             // bytes32: already 32 bytes
    cd
}

/// afterSettle(bytes32,uint256,uint256,bytes)
///
/// `bytes` is a dynamic type. ABI encoding for (bytes32, uint256, uint256, bytes):
///
///   slot 0 : resourceId           [bytes32, 32 bytes]
///   slot 1 : nullifierHash        [uint256, 32 bytes]
///   slot 2 : message              [uint256, 32 bytes]
///   slot 3 : offset to bytes data [uint256 = 0x80 = 4 * 32]
///   slot 4 : bytes length         [uint256]
///   slot 5+: bytes data           [padded to 32-byte boundary]
///
fn calldata_after_settle(
    resource_id:    FixedBytes<32>,
    nullifier_hash: U256,
    message:        U256,
    hook_data:      &[u8],
) -> Vec<u8> {
    let selector = &keccak256(b"afterSettle(bytes32,uint256,uint256,bytes)")[..4];
    let mut cd = selector.to_vec();

    // Head: 3 static slots + 1 offset slot = 4 slots = 128 bytes
    cd.extend_from_slice(resource_id.as_slice());
    cd.extend_from_slice(&encode_u256(nullifier_hash));
    cd.extend_from_slice(&encode_u256(message));
    // Offset to the bytes value: starts after the 4 head slots (4 * 32 = 128 = 0x80)
    cd.extend_from_slice(&encode_u256(U256::from(0x80u64)));

    // Tail: length then data padded to 32-byte multiple
    let len = hook_data.len();
    cd.extend_from_slice(&encode_u256(U256::from(len)));
    cd.extend_from_slice(hook_data);
    // Pad to 32-byte boundary
    let rem = len % 32;
    if rem != 0 {
        cd.extend(core::iter::repeat(0u8).take(32 - rem));
    }

    cd
}

// ─── ABI Encoding Primitives ──────────────────────────────────────────────────

/// Encode a U256 as a 32-byte big-endian slot.
fn encode_u256(v: U256) -> [u8; 32] {
    v.to_be_bytes()
}

/// Encode an address as a 32-byte ABI slot (12 zero bytes + 20 address bytes).
fn encode_address(addr: Address) -> [u8; 32] {
    let mut slot = [0u8; 32];
    slot[12..].copy_from_slice(addr.as_slice());
    slot
}

/// Encode a uint8 as a 32-byte ABI slot (left-padded with zeros).
fn encode_u8(v: u8) -> [u8; 32] {
    let mut slot = [0u8; 32];
    slot[31] = v;
    slot
}

// ─── Return Value Decoder ─────────────────────────────────────────────────────

/// Decode the first 32 bytes of a raw return buffer as a U256.
/// Returns None if the buffer is shorter than 32 bytes.
fn decode_u256(ret: &[u8]) -> Option<U256> {
    if ret.len() < 32 {
        return None;
    }
    Some(U256::from_be_slice(&ret[..32]))
}

// ─── Internal Helpers ─────────────────────────────────────────────────────────

fn hash_concat(a: &[u8], b: &[u8]) -> FixedBytes<32> {
    let mut data = Vec::with_capacity(a.len() + b.len());
    data.extend_from_slice(a);
    data.extend_from_slice(b);
    keccak256(&data)
}