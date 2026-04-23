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
    event MemberRegistered(bytes32 indexed resourceId, uint256 indexed groupId, uint256 identityCommitment);
    event SettlementFinalized(bytes32 indexed resourceId, uint256 indexed nullifierHash, uint256 message);
    event HookRegistered(bytes32 indexed resourceId, address hook);
    event ResourceCreated(bytes32 indexed resourceId, uint256 groupId, address owner, uint256 price);
    event PriceUpdated(bytes32 indexed resourceId, address owner, uint256 price);

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

#[storage]
#[entrypoint]
pub struct SettlementRegistry {
    admin:                 StorageAddress,
    usdc_address:          StorageAddress,
    semaphore_address:     StorageAddress,
    authorized_registries: StorageMap<Address, StorageBool>,
    resource_groups:       StorageMap<FixedBytes<32>, StorageU256>,
    resource_price:        StorageMap<FixedBytes<32>, StorageU256>,
    resource_owners:       StorageMap<FixedBytes<32>, StorageAddress>,
    resource_hooks:        StorageMap<FixedBytes<32>, StorageAddress>,
    nullifiers:            StorageMap<U256, StorageBool>,
    settlements:           StorageMap<FixedBytes<32>, StorageBool>,
    registrations:         StorageMap<FixedBytes<32>, StorageBool>,
}

#[public]
impl SettlementRegistry {
    #[constructor]
    pub fn init(&mut self, admin: Address, usdc_address: Address, semaphore_address: Address) {
        self.admin.set(admin);
        self.usdc_address.set(usdc_address);
        self.semaphore_address.set(semaphore_address);
    }

    pub fn set_registry(&mut self, registry: Address, authorized: bool) -> Result<(), SettlementError> {
        if self.vm().msg_sender() != self.admin.get() {
            return Err(SettlementError::NotAdmin(NotAdmin {}));
        }
        self.authorized_registries.setter(registry).set(authorized);
        Ok(())
    }

    pub fn create_resource(
        &mut self,
        resource_id: FixedBytes<32>,
        price: U256,
        owner: Address,
    ) -> Result<U256, SettlementError> {
        self.only_authorized_registry()?;
        if self.resource_owners.get(resource_id) != Address::ZERO {
            return Err(SettlementError::AlreadyRegistered(AlreadyRegistered {}));
        }

        let this = self.vm().contract_address();
        let ret = unsafe {
            RawCall::new(self.vm())
                .call(self.semaphore_address.get(), &sel_create_group(this))
        }
        .map_err(|_| SettlementError::GroupCreationFailed(GroupCreationFailed {}))?;

        let group_id = decode_u256(&ret)
            .ok_or(SettlementError::GroupCreationFailed(GroupCreationFailed {}))?;

        self.resource_groups.setter(resource_id).set(group_id);
        self.resource_owners.setter(resource_id).set(owner);
        self.resource_price.setter(resource_id).set(price);

        let seed = U256::from_be_bytes(*keccak256(resource_id.as_slice())) % BN254_FIELD_MOD;
        unsafe {
            RawCall::new(self.vm())
                .call(self.semaphore_address.get(), &sel_add_member(group_id, seed))
        }
        .map_err(|_| SettlementError::GroupCreationFailed(GroupCreationFailed {}))?;

        self.vm().log(MemberRegistered { resourceId: resource_id, groupId: group_id, identityCommitment: seed });
        self.vm().log(ResourceCreated { resourceId: resource_id, groupId: group_id, owner, price });
        Ok(group_id)
    }

    // pub fn update_price(
    //     &mut self,
    //     resource_id: FixedBytes<32>,
    //     price: U256,
    //     owner: Address,
    // ) -> Result<(), SettlementError> {
    //     self.only_authorized_registry()?;
    //     let stored = self.resource_owners.get(resource_id);
    //     if stored == Address::ZERO {
    //         return Err(SettlementError::ResourceNotFound(ResourceNotFound {}));
    //     }
    //     if owner != stored {
    //         return Err(SettlementError::NotResourceOwner(NotResourceOwner {}));
    //     }
    //     self.resource_price.setter(resource_id).set(price);
    //     self.vm().log(PriceUpdated { resourceId: resource_id, owner, price });
    //     Ok(())
    // }

    // // ── Direct wallet calls ───────────────────────────────────────────────────

    // /// Called directly by the publisher wallet to register a hook.
    // pub fn register_hook(
    //     &mut self,
    //     resource_id: FixedBytes<32>,
    //     hook: Address,
    // ) -> Result<(), SettlementError> {
    //     let owner = self.resource_owners.get(resource_id);
    //     if owner == Address::ZERO {
    //         return Err(SettlementError::ResourceNotFound(ResourceNotFound {}));
    //     }
    //     if self.vm().msg_sender() != owner {
    //         return Err(SettlementError::NotResourceOwner(NotResourceOwner {}));
    //     }
    //     self.resource_hooks.setter(resource_id).set(hook);
    //     self.vm().log(HookRegistered { resourceId: resource_id, hook });
    //     Ok(())
    // }

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
        if self.resource_owners.get(resource_id) == Address::ZERO {
            return Err(SettlementError::ResourceNotFound(ResourceNotFound {}));
        }
        let reg_key = hash_concat(resource_id.as_slice(), &identity_commitment.to_be_bytes::<32>());
        if self.registrations.get(reg_key) {
            return Err(SettlementError::AlreadyRegistered(AlreadyRegistered {}));
        }
        if amount != self.resource_price.get(resource_id) {
            return Err(SettlementError::IncorrectPaymentAmount(IncorrectPaymentAmount {}));
        }

        unsafe {
            RawCall::new(self.vm()).call(
                self.usdc_address.get(),
                &sel_transfer_auth(from, to, amount, valid_after, valid_before, nonce, v, r, s),
            )
        }
        .map_err(|_| SettlementError::TransferFailed(TransferFailed {}))?;

        let group_id = self.resource_groups.get(resource_id);
        unsafe {
            RawCall::new(self.vm())
                .call(self.semaphore_address.get(), &sel_add_member(group_id, identity_commitment))
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
        resource_id:       FixedBytes<32>,
        stealth_address:   Address,
        merkle_tree_depth: U256,
        merkle_tree_root:  U256,
        nullifier:         U256,
        message:           U256,
        points:            [U256; 8],
        hook_data:         Vec<u8>,
    ) -> Result<(), SettlementError> {
        if self.resource_owners.get(resource_id) == Address::ZERO {
            return Err(SettlementError::ResourceNotFound(ResourceNotFound {}));
        }
        if self.nullifiers.get(nullifier) {
            return Err(SettlementError::AlreadySettled(AlreadySettled {}));
        }

        let group_id = self.resource_groups.get(resource_id);
        unsafe {
            RawCall::new(self.vm()).call(
                self.semaphore_address.get(),
                &sel_validate_proof(group_id, merkle_tree_depth, merkle_tree_root, nullifier, message, group_id, &points),
            )
        }
        .map_err(|_| SettlementError::VerificationFailed(VerificationFailed {}))?;

        self.nullifiers.setter(nullifier).set(true);
        self.settlements
            .setter(hash_concat(stealth_address.as_slice(), resource_id.as_slice()))
            .set(true);
        self.vm().log(SettlementFinalized { resourceId: resource_id, nullifierHash: nullifier, message });

        let hook_addr = self.resource_hooks.get(resource_id);
        if hook_addr != Address::ZERO {
            unsafe {
                RawCall::new(self.vm())
                    .call(hook_addr, &sel_after_settle(resource_id, nullifier, message, &hook_data))
            }
            .map_err(|_| SettlementError::HookFailed(HookFailed {}))?;
        }
        Ok(())
    }

    pub fn is_settled(&self, stealth_address: Address, resource_id: FixedBytes<32>) -> bool {
        self.settlements.get(hash_concat(stealth_address.as_slice(), resource_id.as_slice()))
    }

    pub fn is_registered(&self, resource_id: FixedBytes<32>, identity_commitment: U256) -> bool {
        self.registrations.get(hash_concat(
            resource_id.as_slice(),
            &identity_commitment.to_be_bytes::<32>(),
        ))
    }

    pub fn get_price(&self, resource_id: FixedBytes<32>) -> U256 { self.resource_price.get(resource_id) }
    pub fn get_group_id(&self, resource_id: FixedBytes<32>) -> U256 { self.resource_groups.get(resource_id) }
    // pub fn get_owner(&self, resource_id: FixedBytes<32>) -> Address { self.resource_owners.get(resource_id) }
}

impl SettlementRegistry {
    #[inline(never)]
    fn only_authorized_registry(&self) -> Result<(), SettlementError> {
        if !self.authorized_registries.get(self.vm().msg_sender()) {
            return Err(SettlementError::NotAuthorizedRegistry(NotAuthorizedRegistry {}));
        }
        Ok(())
    }
}

#[inline(never)]
fn sel_create_group(admin: Address) -> alloc::vec::Vec<u8> {
    let mut cd = keccak256(b"createGroup(address)")[..4].to_vec();
    cd.extend_from_slice(&[0u8; 12]);
    cd.extend_from_slice(admin.as_slice());
    cd
}

#[inline(never)]
fn sel_add_member(group_id: U256, commitment: U256) -> alloc::vec::Vec<u8> {
    let mut cd = keccak256(b"addMember(uint256,uint256)")[..4].to_vec();
    cd.extend_from_slice(&group_id.to_be_bytes::<32>());
    cd.extend_from_slice(&commitment.to_be_bytes::<32>());
    cd
}

#[inline(never)]
fn sel_validate_proof(
    group_id: U256, depth: U256, root: U256,
    nullifier: U256, message: U256, scope: U256,
    points: &[U256; 8],
) -> alloc::vec::Vec<u8> {
    let mut cd = keccak256(
        b"validateProof(uint256,(uint256,uint256,uint256,uint256,uint256,uint256[8]))"
    )[..4].to_vec();
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
    from: Address, to: Address, value: U256,
    valid_after: U256, valid_before: U256,
    nonce: FixedBytes<32>, v: u8, r: FixedBytes<32>, s: FixedBytes<32>,
) -> alloc::vec::Vec<u8> {
    let mut cd = keccak256(
        b"transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
    )[..4].to_vec();
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
    resource_id: FixedBytes<32>, nullifier_hash: U256, message: U256, hook_data: &[u8],
) -> alloc::vec::Vec<u8> {
    let mut cd = keccak256(b"afterSettle(bytes32,uint256,uint256,bytes)")[..4].to_vec();
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
fn decode_u256(ret: &[u8]) -> Option<U256> {
    if ret.len() < 32 { return None; }
    Some(U256::from_be_slice(&ret[..32]))
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

    fn resource_id() -> FixedBytes<32> { keccak256(b"test-resource-v1") }

    #[test]
    fn test_seed_in_field() {
        let seed = U256::from_be_bytes(*keccak256(resource_id().as_slice())) % BN254_FIELD_MOD;
        assert!(seed < BN254_FIELD_MOD);
        assert_ne!(seed, U256::ZERO);
    }

    #[test]
    fn test_seed_deterministic() {
        let rid = resource_id();
        assert_eq!(
            U256::from_be_bytes(*keccak256(rid.as_slice())),
            U256::from_be_bytes(*keccak256(rid.as_slice())),
        );
    }

    #[test]
    fn test_sel_add_member() {
        let cd = sel_add_member(U256::ZERO, U256::ZERO);
        assert_eq!(&cd[..4], &keccak256(b"addMember(uint256,uint256)")[..4]);
        assert_eq!(cd.len(), 68);
    }

    #[test]
    fn test_sel_validate_proof() {
        let cd = sel_validate_proof(
            U256::ZERO, U256::ZERO, U256::ZERO,
            U256::ZERO, U256::ZERO, U256::ZERO,
            &[U256::ZERO; 8],
        );
        assert_eq!(
            &cd[..4],
            &keccak256(b"validateProof(uint256,(uint256,uint256,uint256,uint256,uint256,uint256[8]))")[..4]
        );
        assert_eq!(cd.len(), 452);
    }

    #[test]
    fn test_validate_proof_field_order() {
        let cd = sel_validate_proof(
            U256::from(1u64), U256::from(2u64), U256::from(3u64),
            U256::from(4u64), U256::from(5u64), U256::from(6u64),
            &[U256::from(7u64); 8],
        );
        assert_eq!(U256::from_be_slice(&cd[4..36]),   U256::from(1u64), "groupId");
        assert_eq!(U256::from_be_slice(&cd[36..68]),  U256::from(2u64), "depth");
        assert_eq!(U256::from_be_slice(&cd[68..100]), U256::from(3u64), "root");
        assert_eq!(U256::from_be_slice(&cd[100..132]),U256::from(4u64), "nullifier");
        assert_eq!(U256::from_be_slice(&cd[132..164]),U256::from(5u64), "message");
        assert_eq!(U256::from_be_slice(&cd[164..196]),U256::from(6u64), "scope");
        assert_eq!(U256::from_be_slice(&cd[196..228]),U256::from(7u64), "points[0]");
    }

    #[test]
    fn test_scope_equals_group_id() {
        let group_id = U256::from(42u64);
        let cd = sel_validate_proof(group_id, U256::ZERO, U256::ZERO, U256::ZERO, U256::ZERO, group_id, &[U256::ZERO; 8]);
        assert_eq!(U256::from_be_slice(&cd[4..36]), U256::from_be_slice(&cd[164..196]));
    }

    #[test]
    fn test_after_settle_encoding() {
        let cd = sel_after_settle(resource_id(), U256::ZERO, U256::ZERO, &[]);
        assert_eq!(U256::from_be_slice(&cd[100..132]), U256::from(0x80u64), "offset");
        assert_eq!(U256::from_be_slice(&cd[132..164]), U256::ZERO, "length");
    }

    #[test]
    fn test_reg_key_unique_per_identity() {
        let rid = resource_id();
        assert_ne!(
            hash_concat(rid.as_slice(), &U256::from(1u64).to_be_bytes::<32>()),
            hash_concat(rid.as_slice(), &U256::from(2u64).to_be_bytes::<32>()),
        );
    }

    #[test]
    fn test_reg_key_unique_per_resource() {
        let ic = U256::from(1u64).to_be_bytes::<32>();
        assert_ne!(
            hash_concat(keccak256(b"a").as_slice(), &ic),
            hash_concat(keccak256(b"b").as_slice(), &ic),
        );
    }
}