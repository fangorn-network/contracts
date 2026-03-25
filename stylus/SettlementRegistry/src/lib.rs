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
// │    Semaphore.validateProof() handles verification + nullifier.          │
// │    Registered hook fires with the proof's signal (e.g. stealth addr).  │
// └─────────────────────────────────────────────────────────────────────────┘
//
// Semaphore V4 — same addresses on Arbitrum mainnet + Arbitrum Sepolia:
//   Semaphore : 0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D
//
// Verified from @semaphore-protocol/contracts@4.14.2:
//
//   createGroup() → uint256
//     No args. msg.sender becomes admin. groupCounter starts at 0.
//
//   addMember(uint256 groupId, uint256 identityCommitment)
//     Only callable by group admin (this contract).
//     Called in register() for real members.
//     Called in add_seed_member() once after create_resource().
//
//   validateProof(uint256 groupId, SemaphoreProof proof)
//     Reverts on: invalid proof, expired root, double-spend nullifier.
//     SemaphoreProof struct field order (verified from ISemaphore.sol):
//       uint256 merkleTreeDepth
//       uint256 merkleTreeRoot
//       uint256 nullifier
//       uint256 message
//       uint256 scope        ← must equal groupId
//       uint256[8] points
//
// NOTE ON SEED MEMBER:
//   LeanIMT depth 0 (1 member) cannot generate a valid Groth16 proof.
//   A seed member must be added after create_resource() so depth >= 1.
//   add_seed_member() is called once by the resource owner after creation.
//   Seed commitment = keccak256(resource_id)
//   The seed is emitted as MemberRegistered so fetchGroup picks it up.

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{Address, FixedBytes, U256, keccak256},
    call::RawCall,
    prelude::*,
    storage::*,
};

sol! {
    event MemberRegistered(
        bytes32 indexed resourceId,
        uint256 indexed groupId,
        uint256 identityCommitment
    );

    event SettlementFinalized(
        bytes32 indexed resourceId,
        uint256 indexed nullifierHash,
        uint256 message
    );

    event HookRegistered(bytes32 indexed resourceId, address hook);
    event ResourceCreated(bytes32 indexed resourceId, uint256 groupId, address owner, uint256 price);
    event PriceUpdated(bytes32 indexed resourceId, address owner, uint256 price);

    error AlreadyRegistered();
    error AlreadySettled();
    error IncorrectPaymentAmount();
    error TransferFailed();
    error VerificationFailed();
    error NotResourceOwner();
    error ResourceNotFound();
    error HookFailed();
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
    usdc_address:      StorageAddress,
    semaphore_address: StorageAddress,

    // resource_id => Semaphore group_id
    resource_groups:  StorageMap<FixedBytes<32>, StorageU256>,
    // resource_id => USDC price
    resource_price:   StorageMap<FixedBytes<32>, StorageU256>,
    // resource_id => owner
    resource_owners:  StorageMap<FixedBytes<32>, StorageAddress>,
    // resource_id => hook data
    resource_hooks:   StorageMap<FixedBytes<32>, StorageAddress>,

    // Local nullifier tracking for is_settled() view queries.
    // Semaphore also tracks nullifiers internally via validateProof().
    nullifiers:       StorageMap<U256, StorageBool>,

    // settlement tracking using burner addresses
    // hash(burner address|| resourceId) => true/false
    settlements: StorageMap<FixedBytes<32>, StorageBool>,

    // keccak256(resource_id ++ identity_commitment) => registered
    registrations:    StorageMap<FixedBytes<32>, StorageBool>,
}

#[public]
impl SettlementRegistry {

    #[constructor]
    pub fn init(
        &mut self,
        usdc_address:      Address,
        semaphore_address: Address,
    ) {
        self.usdc_address.set(usdc_address);
        self.semaphore_address.set(semaphore_address);
    }

    /// Create a new resource and its Semaphore group.
    /// After calling this, call add_seed_member() once to enable single-member proofs.
    pub fn create_resource(
        &mut self,
        resource_id: FixedBytes<32>,
        price: U256,
    ) -> Result<U256, SettlementError> {
        
        if self.resource_owners.get(resource_id) != Address::ZERO {
            return Err(SettlementError::AlreadyRegistered(AlreadyRegistered {}));
        }

        let this = self.vm().contract_address();
        let ret = unsafe {
            RawCall::new(self.vm())
                .call(
                    self.semaphore_address.get(), 
                    &calldata_create_group_with_admin(this)
                )
        }
        .map_err(|_| SettlementError::GroupCreationFailed(GroupCreationFailed {}))?;

        let group_id = decode_u256(&ret)
            .ok_or(SettlementError::GroupCreationFailed(GroupCreationFailed {}))?;

        let caller = self.vm().msg_sender();
        self.resource_groups.setter(resource_id).set(group_id);
        self.resource_owners.setter(resource_id).set(caller);
        self.resource_price.setter(resource_id).set(price);

        self.vm().log(ResourceCreated {
            resourceId: resource_id,
            groupId:    group_id,
            owner:      caller,
            price,
        });

        Ok(group_id)
    }

    /// Add a deterministic seed member to the group so LeanIMT depth >= 1.
    /// Must be called once by resource owner after create_resource().
    /// Seed commitment = keccak256(resource_id) — auditable but unspendable.
    /// Emits MemberRegistered so fetchGroup picks it up alongside real members.
    pub fn add_seed_member(
        &mut self,
        resource_id: FixedBytes<32>,
    ) -> Result<(), SettlementError> {
        let owner = self.resource_owners.get(resource_id);
        if owner == Address::ZERO {
            return Err(SettlementError::ResourceNotFound(ResourceNotFound {}));
        }
        if self.vm().msg_sender() != owner {
            return Err(SettlementError::NotResourceOwner(NotResourceOwner {}));
        }

        let group_id = self.resource_groups.get(resource_id);
        // let seed = U256::from_be_bytes(*keccak256(resource_id.as_slice()));
         let raw = U256::from_be_bytes(*keccak256(resource_id.as_slice()));
        // BN254 scalar field modulus
        const BN254_FIELD_MOD: U256 = U256::from_limbs([
            0x43e1f593f0000001,
            0x2833e84879b97091,
            0xb85045b68181585d,
            0x30644e72e131a029,
        ]);
        let seed = raw % BN254_FIELD_MOD;

        let add_calldata = calldata_add_member(group_id, seed);
        unsafe {
            RawCall::new(self.vm())
                .call(self.semaphore_address.get(), &add_calldata)
        }
        .map_err(|_| SettlementError::GroupCreationFailed(GroupCreationFailed {}))?;

        self.vm().log(MemberRegistered {
            resourceId:         resource_id,
            groupId:            group_id,
            identityCommitment: seed,
        });

        Ok(())
    }

    /// Update the price of the resource
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
        self.resource_price.setter(resource_id).set(price);
        self.vm().log(PriceUpdated { resourceId: resource_id, owner, price });
        Ok(())
    }

    /// Register a hook address for the resource
    pub fn register_hook(
        &mut self,
        resource_id: FixedBytes<32>,
        hook: Address,
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

    /// Phase 1. Pay => register a Semaphore identity in the group.
    #[payable]
    pub fn register(
        &mut self,
        resource_id:         FixedBytes<32>,
        identity_commitment: U256,
        from:                Address,
        to:                  Address,
        amount:              U256,
        valid_after:         U256,
        valid_before:        U256,
        nonce:               FixedBytes<32>,
        v:                   u8,
        r:                   FixedBytes<32>,
        s:                   FixedBytes<32>,
    ) -> Result<(), SettlementError> {
        let owner = self.resource_owners.get(resource_id);
        if owner == Address::ZERO {
            return Err(SettlementError::ResourceNotFound(ResourceNotFound {}));
        }

        let reg_key = hash_concat(
            resource_id.as_slice(),
            &identity_commitment.to_be_bytes::<32>(),
        );
        if self.registrations.get(reg_key) {
            return Err(SettlementError::AlreadyRegistered(AlreadyRegistered {}));
        }

        let expected_price = self.resource_price.get(resource_id);
        if amount != expected_price {
            return Err(SettlementError::IncorrectPaymentAmount(IncorrectPaymentAmount {}));
        }

        let payment_calldata = calldata_transfer_with_authorization(
            from, to, amount, valid_after, valid_before, nonce, v, r, s,
        );
        unsafe {
            RawCall::new(self.vm())
                .call(self.usdc_address.get(), &payment_calldata)
        }
        .map_err(|_| SettlementError::TransferFailed(TransferFailed {}))?;

        let group_id = self.resource_groups.get(resource_id);
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

    /// Phase 2 — Prove membership and claim access.
    ///
    /// Client generates proof via @semaphore-protocol/proof:
    ///   const proof = await generateProof(identity, group, message, groupId)
    ///   scope = groupId (4th arg to generateProof)
    pub fn settle(
        &mut self,
        resource_id:       FixedBytes<32>,
        // for anonymous settlement tracking
        stealth_address:   Address,
        merkle_tree_depth: U256,
        merkle_tree_root:  U256,
        nullifier:         U256,
        message:           U256,
        points:            [U256; 8],
        hook_data:         Vec<u8>,
    ) -> Result<(), SettlementError> {
        let owner = self.resource_owners.get(resource_id);
        if owner == Address::ZERO {
            return Err(SettlementError::ResourceNotFound(ResourceNotFound {}));
        }

        if self.nullifiers.get(nullifier) {
            return Err(SettlementError::AlreadySettled(AlreadySettled {}));
        }

        let group_id = self.resource_groups.get(resource_id);

        let validate_calldata = calldata_validate_proof(
            group_id,
            merkle_tree_depth,
            merkle_tree_root,
            nullifier,
            message,
            group_id, // scope = groupId
            &points,
        );
        unsafe {
            RawCall::new(self.vm())
                .call(
                    self.semaphore_address.get(), 
                    &validate_calldata
                )
        }
        .map_err(|_| SettlementError::VerificationFailed(VerificationFailed {}))?;

        self.nullifiers.setter(nullifier).set(true);

        // for settlement tracking, map: hash(stealth || resourceId) => true
        let settlement_key = hash_concat(
            stealth_address.as_slice(),
            resource_id.as_slice(),
        );
        self.settlements.setter(settlement_key).set(true);

        self.vm().log(SettlementFinalized {
            resourceId:    resource_id,
            nullifierHash: nullifier,
            message,
        });

        let hook_addr = self.resource_hooks.get(resource_id);
        if hook_addr != Address::ZERO {
            let hook_calldata = calldata_after_settle(
                resource_id, nullifier, message, &hook_data,
            );
            unsafe {
                RawCall::new(self.vm())
                    .call(hook_addr, &hook_calldata)
            }
            .map_err(|_| SettlementError::HookFailed(HookFailed {}))?;
        }

        Ok(())
    }

    pub fn is_settled(&self, stealth_address: Address, resource_id: FixedBytes<32>) -> bool {
        let key = hash_concat(
            stealth_address.as_slice(),
            resource_id.as_slice(),
        );
        self.settlements.get(key)
    }

    pub fn get_price(&self, resource_id: FixedBytes<32>) -> U256 {
        self.resource_price.get(resource_id)
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

// ABI Calldata Builders

/// createGroup() with the contract as the admin
fn calldata_create_group_with_admin(admin: Address) -> Vec<u8> {
    // createGroup(address) selector
    let selector = &keccak256(b"createGroup(address)")[..4];
    let mut calldata = selector.to_vec();
    // ABI encode address (padded to 32 bytes)
    calldata.extend_from_slice(&[0u8; 12]);
    calldata.extend_from_slice(admin.as_slice());
    calldata
}

/// addMember(uint256,uint256)
fn calldata_add_member(group_id: U256, identity_commitment: U256) -> Vec<u8> {
    let selector = &keccak256(b"addMember(uint256,uint256)")[..4];
    let mut cd = selector.to_vec();
    cd.extend_from_slice(&encode_u256(group_id));
    cd.extend_from_slice(&encode_u256(identity_commitment));
    cd
}

/// validateProof(uint256,(uint256,uint256,uint256,uint256,uint256,uint256[8]))
/// SemaphoreProof struct fields inline (all static, no offset pointer needed):
///   merkleTreeDepth, merkleTreeRoot, nullifier, message, scope, points[8]
fn calldata_validate_proof(
    group_id:          U256,
    merkle_tree_depth: U256,
    merkle_tree_root:  U256,
    nullifier:         U256,
    message:           U256,
    scope:             U256,
    points:            &[U256; 8],
) -> Vec<u8> {
        let selector = &keccak256(
        b"validateProof(uint256,(uint256,uint256,uint256,uint256,uint256,uint256[8]))"
    )[..4];
    let mut cd = selector.to_vec();
    cd.extend_from_slice(&encode_u256(group_id));
    // NO offset pointer — struct is fully static (uint256[8] is fixed-size)
    cd.extend_from_slice(&encode_u256(merkle_tree_depth));
    cd.extend_from_slice(&encode_u256(merkle_tree_root));
    cd.extend_from_slice(&encode_u256(nullifier));
    cd.extend_from_slice(&encode_u256(message));
    cd.extend_from_slice(&encode_u256(scope));
    for p in points {
        cd.extend_from_slice(&encode_u256(*p));
    }
    cd
}

/// transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)
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
    cd.extend_from_slice(nonce.as_slice());
    cd.extend_from_slice(&encode_u8(v));
    cd.extend_from_slice(r.as_slice());
    cd.extend_from_slice(s.as_slice());
    cd
}

/// afterSettle(bytes32,uint256,uint256,bytes)
fn calldata_after_settle(
    resource_id:    FixedBytes<32>,
    nullifier_hash: U256,
    message:        U256,
    hook_data:      &[u8],
) -> Vec<u8> {
    let selector = &keccak256(b"afterSettle(bytes32,uint256,uint256,bytes)")[..4];
    let mut cd = selector.to_vec();
    cd.extend_from_slice(resource_id.as_slice());
    cd.extend_from_slice(&encode_u256(nullifier_hash));
    cd.extend_from_slice(&encode_u256(message));
    cd.extend_from_slice(&encode_u256(U256::from(0x80u64)));
    let len = hook_data.len();
    cd.extend_from_slice(&encode_u256(U256::from(len)));
    cd.extend_from_slice(hook_data);
    let rem = len % 32;
    if rem != 0 {
        cd.extend(core::iter::repeat(0u8).take(32 - rem));
    }
    cd
}

fn encode_u256(v: U256) -> [u8; 32] { v.to_be_bytes() }

fn encode_address(addr: Address) -> [u8; 32] {
    let mut slot = [0u8; 32];
    slot[12..].copy_from_slice(addr.as_slice());
    slot
}

fn encode_u8(v: u8) -> [u8; 32] {
    let mut slot = [0u8; 32];
    slot[31] = v;
    slot
}

fn decode_u256(ret: &[u8]) -> Option<U256> {
    if ret.len() < 32 { return None; }
    Some(U256::from_be_slice(&ret[..32]))
}

fn hash_concat(a: &[u8], b: &[u8]) -> FixedBytes<32> {
    let mut data = Vec::with_capacity(a.len() + b.len());
    data.extend_from_slice(a);
    data.extend_from_slice(b);
    keccak256(&data)
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use stylus_sdk::alloy_primitives::{keccak256, FixedBytes, U256};

    fn resource_id() -> FixedBytes<32> { keccak256(b"test-resource-v1") }
    fn seed(rid: FixedBytes<32>) -> U256 { U256::from_be_bytes(*keccak256(rid.as_slice())) }

    #[test]
    fn test_seed_nonzero() {
        assert_ne!(seed(resource_id()), U256::ZERO);
    }

    #[test]
    fn test_seed_deterministic() {
        assert_eq!(seed(resource_id()), seed(resource_id()));
    }

    #[test]
    fn test_seed_unique_per_resource() {
        let r1 = keccak256(b"resource-a");
        let r2 = keccak256(b"resource-b");
        assert_ne!(seed(r1), seed(r2));
    }

    #[test]
    fn test_selector_add_member() {
        let cd = calldata_add_member(U256::ZERO, U256::ZERO);
        assert_eq!(&cd[..4], &keccak256(b"addMember(uint256,uint256)")[..4]);
        assert_eq!(cd.len(), 68);
    }

    #[test]
    fn test_selector_validate_proof() {
        let cd = calldata_validate_proof(
            U256::ZERO, U256::ZERO, U256::ZERO,
            U256::ZERO, U256::ZERO, U256::ZERO,
            &[U256::ZERO; 8],
        );
        assert_eq!(
            &cd[..4],
            &keccak256(b"validateProof(uint256,(uint256,uint256,uint256,uint256,uint256,uint256[8]))")[..4]
        );
        // selector(4) + groupId(32) + 5 struct fields(160) + points[8](256) = 452
        assert_eq!(cd.len(), 452);
    }

    #[test]
    fn test_validate_proof_field_order() {
        let group_id  = U256::from(1u64);
        let depth     = U256::from(2u64);
        let root      = U256::from(3u64);
        let nullifier = U256::from(4u64);
        let message   = U256::from(5u64);
        let scope     = U256::from(6u64);
        let points    = [U256::from(7u64); 8];

        let cd = calldata_validate_proof(
            group_id, depth, root, nullifier, message, scope, &points,
        );

        assert_eq!(U256::from_be_slice(&cd[4..36]),   group_id,  "groupId");
        assert_eq!(U256::from_be_slice(&cd[36..68]),  depth,     "merkleTreeDepth");
        assert_eq!(U256::from_be_slice(&cd[68..100]), root,      "merkleTreeRoot");
        assert_eq!(U256::from_be_slice(&cd[100..132]),nullifier, "nullifier");
        assert_eq!(U256::from_be_slice(&cd[132..164]),message,   "message");
        assert_eq!(U256::from_be_slice(&cd[164..196]),scope,     "scope");
        assert_eq!(U256::from_be_slice(&cd[196..228]),points[0], "points[0]");
    }

    #[test]
    fn test_validate_proof_scope_equals_group_id() {
        let group_id = U256::from(42u64);
        let cd = calldata_validate_proof(
            group_id, U256::ZERO, U256::ZERO,
            U256::ZERO, U256::ZERO, group_id,
            &[U256::ZERO; 8],
        );
        assert_eq!(
            U256::from_be_slice(&cd[4..36]),
            U256::from_be_slice(&cd[164..196]),
            "scope must equal group_id"
        );
    }

    #[test]
    fn test_after_settle_offset_and_length() {
        let cd = calldata_after_settle(resource_id(), U256::ZERO, U256::ZERO, &[]);
        let offset = U256::from_be_slice(&cd[100..132]);
        let length = U256::from_be_slice(&cd[132..164]);
        assert_eq!(offset, U256::from(0x80u64));
        assert_eq!(length, U256::ZERO);
    }

    #[test]
    fn test_reg_key_unique_per_identity() {
        let rid = resource_id();
        let k1 = hash_concat(rid.as_slice(), &U256::from(1u64).to_be_bytes::<32>());
        let k2 = hash_concat(rid.as_slice(), &U256::from(2u64).to_be_bytes::<32>());
        assert_ne!(k1, k2);
    }

    #[test]
    fn test_reg_key_unique_per_resource() {
        let ic = U256::from(1u64);
        let k1 = hash_concat(keccak256(b"a").as_slice(), &ic.to_be_bytes::<32>());
        let k2 = hash_concat(keccak256(b"b").as_slice(), &ic.to_be_bytes::<32>());
        assert_ne!(k1, k2);
    }
}