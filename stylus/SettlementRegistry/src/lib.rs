#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{keccak256, Address, FixedBytes, U256},
    call::RawCall,
    prelude::*,
    storage::*,
};

// ── Add to Cargo.toml ─────────────────────────────────────────────────────────
// [profile.release]
// codegen-units = 1
// strip        = true
// lto          = "fat"
// opt-level    = "z"
// panic        = "abort"
// ──────────────────────────────────────────────────────────────────────────────

sol! {
    event MemberRegistered(bytes32 indexed resourceId, uint256 indexed groupId, uint256 identityCommitment);
    event SettlementFinalized(bytes32 indexed resourceId, uint256 indexed nullifierHash, uint256 message);
    event ResourceUpdated(bytes32 indexed resourceId, address hook, uint256 price);
    event ResourceCreated(bytes32 indexed resourceId, uint256 groupId, address owner, uint256 price);

    error AlreadyRegistered();
    error AlreadySettled();
    error IncorrectPaymentAmount();
    error TransferFailed();
    error VerificationFailed();
    error NotResourceOwner();
    error NotAdmin();
    error NotAuthorizedRegistry();
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
    NotAdmin(NotAdmin),
    NotAuthorizedRegistry(NotAuthorizedRegistry),
    ResourceNotFound(ResourceNotFound),
    HookFailed(HookFailed),
    GroupCreationFailed(GroupCreationFailed),
}

const BN254_FIELD_MOD: U256 = U256::from_limbs([
    0x43e1f593f0000001,
    0x2833e84879b97091,
    0xb85045b68181585d,
    0x30644e72e131a029,
]);

// ── Selectors ─────────────────────────────────────────────────────────────────
// USDC (ERC-3009) — kept local, raw-called as before.
const SEL_TRANSFER_AUTH: [u8; 4] = [0xe3, 0xee, 0x16, 0x0e]; // transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)
                                                             // Hook callback
const SEL_AFTER_SETTLE: [u8; 4] = [0x71, 0xe5, 0xea, 0xc2]; // afterSettle(bytes32,uint256,uint256,bytes)
                                                            // SemaphoreAdapter (we call our own adapter, not Semaphore directly)
const SEL_ADAPTER_CREATE_GROUP: [u8; 4] = [0x7b, 0x0a, 0x47, 0xee]; // createGroup()
const SEL_ADAPTER_ADD_MEMBER: [u8; 4] = [0x17, 0x83, 0xef, 0xc3]; // addMember(uint256,uint256)
const SEL_ADAPTER_VALIDATE_PROOF: [u8; 4] = [0x32, 0x58, 0x2b, 0x7c]; // validateProof(uint256,uint256,uint256,uint256,uint256,uint256,uint256[8])

#[storage]
pub struct Resource {
    group_id: StorageU256,
    owner: StorageAddress,
    price: StorageU256,
    hook: StorageAddress,
}

#[storage]
#[entrypoint]
pub struct SettlementRegistry {
    admin: StorageAddress,
    usdc_address: StorageAddress,
    // Now points at the SemaphoreAdapter, not Semaphore itself.
    semaphore_adapter: StorageAddress,
    authorized_registry: StorageAddress,
    resources: StorageMap<FixedBytes<32>, Resource>,
    nullifiers: StorageMap<U256, StorageBool>,
    settlements: StorageMap<FixedBytes<32>, StorageBool>,
    registrations: StorageMap<FixedBytes<32>, StorageBool>,
}

#[public]
impl SettlementRegistry {
    #[constructor]
    pub fn init(&mut self, admin: Address, usdc_address: Address, semaphore_adapter: Address) {
        self.admin.set(admin);
        self.usdc_address.set(usdc_address);
        self.semaphore_adapter.set(semaphore_adapter);
    }

    pub fn set_registry(
        &mut self,
        registry: Address,
        authorized: bool,
    ) -> Result<(), SettlementError> {
        if self.vm().msg_sender() != self.admin.get() {
            return Err(SettlementError::NotAdmin(NotAdmin {}));
        }
        self.authorized_registry.set(registry);
        Ok(())
    }

    pub fn create_resource(
        &mut self,
        resource_id: FixedBytes<32>,
        price: U256,
        owner: Address,
    ) -> Result<U256, SettlementError> {
        self.only_authorized_registry()?;

        if self.resources.getter(resource_id).owner.get() != Address::ZERO {
            return Err(SettlementError::AlreadyRegistered(AlreadyRegistered {}));
        }

        // Adapter returns new group_id. Admin on the adapter side becomes
        // msg_sender, which is this contract — so we remain the group admin.
        let ret = unsafe {
            RawCall::new(self.vm()).call(self.semaphore_adapter.get(), &SEL_ADAPTER_CREATE_GROUP)
        }
        .map_err(|_| SettlementError::GroupCreationFailed(GroupCreationFailed {}))?;
        let group_id = U256::from_be_slice(&ret[..32]);

        {
            let mut r = self.resources.setter(resource_id);
            r.group_id.set(group_id);
            r.owner.set(owner);
            r.price.set(price);
        }

        let seed = U256::from_be_bytes(*keccak256(resource_id.as_slice())) % BN254_FIELD_MOD;
        unsafe {
            RawCall::new(self.vm()).call(
                self.semaphore_adapter.get(),
                &sel_adapter_add_member(group_id, seed),
            )
        }
        .map_err(|_| SettlementError::GroupCreationFailed(GroupCreationFailed {}))?;


        self.vm().log(ResourceCreated {
            resourceId: resource_id,
            groupId: group_id,
            owner,
            price,
        });
        Ok(group_id)
    }

    // Update the hook and price associated with a resource id
    // Only executable by the resource owner.
    // 
    pub fn update_resource(
        &mut self,
        resource_id: FixedBytes<32>,
        hook: Address,
        price: U256,
    ) -> Result<(), SettlementError> {
        let owner = self.resources.getter(resource_id).owner.get();
        if owner == Address::ZERO {
            return Err(SettlementError::ResourceNotFound(ResourceNotFound {}));
        }
        if self.vm().msg_sender() != owner {
            return Err(SettlementError::NotResourceOwner(NotResourceOwner {}));
        }
        {
            let mut r = self.resources.setter(resource_id);
            r.hook.set(hook);
            r.price.set(price);
        }
        self.vm().log(ResourceUpdated {
            resourceId: resource_id,
            hook,
            price,
        });
        Ok(())
    }

    #[payable]
    pub fn register(
        &mut self,
        resource_id: FixedBytes<32>,
        identity_commitment: U256,
        from: Address,
        to: Address,
        amount: U256,
        valid_after: U256,
        valid_before: U256,
        nonce: FixedBytes<32>,
        v: u8,
        r: FixedBytes<32>,
        s: FixedBytes<32>,
    ) -> Result<(), SettlementError> {
        let (owner, price, group_id) = {
            let res = self.resources.getter(resource_id);
            (res.owner.get(), res.price.get(), res.group_id.get())
        };

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

        if amount != price {
            return Err(SettlementError::IncorrectPaymentAmount(
                IncorrectPaymentAmount {},
            ));
        }

        unsafe {
            RawCall::new(self.vm()).call(
                self.usdc_address.get(),
                &sel_transfer_auth(from, to, amount, valid_after, valid_before, nonce, v, r, s),
            )
        }
        .map_err(|_| SettlementError::TransferFailed(TransferFailed {}))?;

        unsafe {
            RawCall::new(self.vm()).call(
                self.semaphore_adapter.get(),
                &sel_adapter_add_member(group_id, identity_commitment),
            )
        }
        .map_err(|_| SettlementError::GroupCreationFailed(GroupCreationFailed {}))?;

        self.registrations.setter(reg_key).set(true);
        self.vm().log(MemberRegistered {
            resourceId: resource_id,
            groupId: group_id,
            identityCommitment: identity_commitment,
        });
        Ok(())
    }

    pub fn settle(
        &mut self,
        resource_id: FixedBytes<32>,
        stealth_address: Address,
        merkle_tree_depth: U256,
        merkle_tree_root: U256,
        nullifier: U256,
        message: U256,
        points: [U256; 8],
        hook_data: Vec<u8>,
    ) -> Result<(), SettlementError> {
        let (owner, group_id, hook_addr) = {
            let res = self.resources.getter(resource_id);
            (res.owner.get(), res.group_id.get(), res.hook.get())
        };

        if owner == Address::ZERO {
            return Err(SettlementError::ResourceNotFound(ResourceNotFound {}));
        }
        if self.nullifiers.get(nullifier) {
            return Err(SettlementError::AlreadySettled(AlreadySettled {}));
        }

        unsafe {
            RawCall::new(self.vm()).call(
                self.semaphore_adapter.get(),
                &sel_adapter_validate_proof(
                    group_id,
                    merkle_tree_depth,
                    merkle_tree_root,
                    nullifier,
                    message,
                    group_id,
                    &points,
                ),
            )
        }
        .map_err(|_| SettlementError::VerificationFailed(VerificationFailed {}))?;

        self.nullifiers.setter(nullifier).set(true);
        self.settlements
            .setter(hash_concat(
                stealth_address.as_slice(),
                resource_id.as_slice(),
            ))
            .set(true);
        self.vm().log(SettlementFinalized {
            resourceId: resource_id,
            nullifierHash: nullifier,
            message,
        });

        if hook_addr != Address::ZERO {
            unsafe {
                RawCall::new(self.vm()).call(
                    hook_addr,
                    &sel_after_settle(resource_id, nullifier, message, &hook_data),
                )
            }
            .map_err(|_| SettlementError::HookFailed(HookFailed {}))?;
        }
        Ok(())
    }

    pub fn get_status(
        &self,
        stealth_address: Address,
        resource_id: FixedBytes<32>,
        identity_commitment: U256,
    ) -> (bool, bool) {
        let is_settled = self.settlements.get(hash_concat(
            stealth_address.as_slice(),
            resource_id.as_slice(),
        ));
        let is_registered = self.registrations.get(hash_concat(
            resource_id.as_slice(),
            &identity_commitment.to_be_bytes::<32>(),
        ));
        (is_settled, is_registered)
    }

    /// Returns (owner, price, group_id, hook).
    pub fn get_resource(&self, resource_id: FixedBytes<32>) -> (Address, U256, U256, Address) {
        let r = self.resources.getter(resource_id);
        (r.owner.get(), r.price.get(), r.group_id.get(), r.hook.get())
    }

    pub fn get_semaphore_adapter(&self) -> Address {
        self.semaphore_adapter.get()
    }
}

impl SettlementRegistry {
    #[inline(never)]
    fn only_authorized_registry(&self) -> Result<(), SettlementError> {
        if !self.authorized_registry.get().eq(&self.vm().msg_sender()) {
            return Err(SettlementError::NotAuthorizedRegistry(
                NotAuthorizedRegistry {},
            ));
        }
        Ok(())
    }
}

// ── Calldata encoding ─────────────────────────────────────────────────────────
// Note: the heavy validate_proof and create_group encoders are GONE from this
// contract — they live in SemaphoreAdapter now. What remains:
//   - sel_transfer_auth (USDC, 9 words)
//   - sel_after_settle  (hook, 4 words + dynamic bytes)
//   - sel_adapter_add_member (adapter, 2 words)
//   - sel_adapter_validate_proof (adapter, 14 words)
// The adapter create_group selector is a constant (no args), no helper needed.

#[inline(never)]
fn sel_adapter_add_member(group_id: U256, commitment: U256) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_ADAPTER_ADD_MEMBER.to_vec();
    cd.extend_from_slice(&group_id.to_be_bytes::<32>());
    cd.extend_from_slice(&commitment.to_be_bytes::<32>());
    cd
}

#[inline(never)]
fn sel_adapter_validate_proof(
    group_id: U256,
    depth: U256,
    root: U256,
    nullifier: U256,
    message: U256,
    scope: U256,
    points: &[U256; 8],
) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_ADAPTER_VALIDATE_PROOF.to_vec();
    cd.extend_from_slice(&group_id.to_be_bytes::<32>());
    cd.extend_from_slice(&depth.to_be_bytes::<32>());
    cd.extend_from_slice(&root.to_be_bytes::<32>());
    cd.extend_from_slice(&nullifier.to_be_bytes::<32>());
    cd.extend_from_slice(&message.to_be_bytes::<32>());
    cd.extend_from_slice(&scope.to_be_bytes::<32>());
    for p in points {
        cd.extend_from_slice(&p.to_be_bytes::<32>());
    }
    cd
}

#[inline(never)]
fn sel_transfer_auth(
    from: Address,
    to: Address,
    value: U256,
    valid_after: U256,
    valid_before: U256,
    nonce: FixedBytes<32>,
    v: u8,
    r: FixedBytes<32>,
    s: FixedBytes<32>,
) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_TRANSFER_AUTH.to_vec();
    let mut addr = [0u8; 32];
    addr[12..].copy_from_slice(from.as_slice());
    cd.extend_from_slice(&addr);
    addr[12..].copy_from_slice(to.as_slice());
    cd.extend_from_slice(&addr);
    cd.extend_from_slice(&value.to_be_bytes::<32>());
    cd.extend_from_slice(&valid_after.to_be_bytes::<32>());
    cd.extend_from_slice(&valid_before.to_be_bytes::<32>());
    cd.extend_from_slice(nonce.as_slice());
    let mut v_slot = [0u8; 32];
    v_slot[31] = v;
    cd.extend_from_slice(&v_slot);
    cd.extend_from_slice(r.as_slice());
    cd.extend_from_slice(s.as_slice());
    cd
}

#[inline(never)]
fn sel_after_settle(
    resource_id: FixedBytes<32>,
    nullifier_hash: U256,
    message: U256,
    hook_data: &[u8],
) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_AFTER_SETTLE.to_vec();
    cd.extend_from_slice(resource_id.as_slice());
    cd.extend_from_slice(&nullifier_hash.to_be_bytes::<32>());
    cd.extend_from_slice(&message.to_be_bytes::<32>());
    cd.extend_from_slice(&U256::from(0x80u64).to_be_bytes::<32>());
    let len = hook_data.len();
    cd.extend_from_slice(&U256::from(len).to_be_bytes::<32>());
    cd.extend_from_slice(hook_data);
    let rem = len % 32;
    if rem != 0 {
        cd.extend(core::iter::repeat(0u8).take(32 - rem));
    }
    cd
}

#[inline(never)]
fn hash_concat(a: &[u8], b: &[u8]) -> FixedBytes<32> {
    let mut data = alloc::vec::Vec::with_capacity(a.len() + b.len());
    data.extend_from_slice(a);
    data.extend_from_slice(b);
    keccak256(&data)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use stylus_sdk::alloy_primitives::{keccak256, FixedBytes, U256};

    fn resource_id() -> FixedBytes<32> {
        keccak256(b"test-resource-v1")
    }

    #[test]
    fn test_const_selectors() {
        assert_eq!(SEL_TRANSFER_AUTH,  keccak256(b"transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)")[..4]);
        assert_eq!(
            SEL_AFTER_SETTLE,
            keccak256(b"afterSettle(bytes32,uint256,uint256,bytes)")[..4]
        );
        // These are the adapter's public method selectors — must match SemaphoreAdapter's #[public] fn signatures.
        assert_eq!(SEL_ADAPTER_CREATE_GROUP, keccak256(b"createGroup()")[..4]);
        assert_eq!(
            SEL_ADAPTER_ADD_MEMBER,
            keccak256(b"addMember(uint256,uint256)")[..4]
        );
        assert_eq!(
            SEL_ADAPTER_VALIDATE_PROOF,
            keccak256(b"validateProof(uint256,uint256,uint256,uint256,uint256,uint256,uint256[8])")
                [..4]
        );
    }

    #[test]
    fn test_seed_in_field() {
        let seed = U256::from_be_bytes(*keccak256(resource_id().as_slice())) % BN254_FIELD_MOD;
        assert!(seed < BN254_FIELD_MOD);
        assert_ne!(seed, U256::ZERO);
    }

    #[test]
    fn test_sel_adapter_add_member_length() {
        let cd = sel_adapter_add_member(U256::ZERO, U256::ZERO);
        assert_eq!(cd.len(), 68);
    }

    #[test]
    fn test_sel_adapter_validate_proof_length() {
        let cd = sel_adapter_validate_proof(
            U256::ZERO,
            U256::ZERO,
            U256::ZERO,
            U256::ZERO,
            U256::ZERO,
            U256::ZERO,
            &[U256::ZERO; 8],
        );
        assert_eq!(cd.len(), 452);
    }

    #[test]
    fn test_after_settle_encoding() {
        let cd = sel_after_settle(resource_id(), U256::ZERO, U256::ZERO, &[]);
        assert_eq!(
            U256::from_be_slice(&cd[100..132]),
            U256::from(0x80u64),
            "offset"
        );
        assert_eq!(U256::from_be_slice(&cd[132..164]), U256::ZERO, "length");
    }

    #[test]
    fn test_reg_key_unique() {
        let rid = resource_id();
        assert_ne!(
            hash_concat(rid.as_slice(), &U256::from(1u64).to_be_bytes::<32>()),
            hash_concat(rid.as_slice(), &U256::from(2u64).to_be_bytes::<32>()),
        );
    }
}
