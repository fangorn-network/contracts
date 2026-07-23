#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloc::string::String;
use alloc::vec::Vec;
use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{Address, FixedBytes, U256, keccak256},
    call::RawCall,
    prelude::*,
    storage::*,
};

sol! {
    event MemberRegistered(bytes32 indexed resourceId, uint256 identityCommitment);
    event SettlementFinalized(bytes32 indexed resourceId, uint256 indexed nullifierHash, uint256 message);
    event HookRegistered(bytes32 indexed resourceId, address hook);
    event ResourceCreated(bytes32 indexed resourceId, address owner, uint256 price, string uri);
    event PriceUpdated(bytes32 indexed resourceId, address owner, uint256 price);

    error AlreadyRegistered();
    error AlreadySettled();
    error IncorrectPaymentAmount();
    error TransferFailed();
    error VerificationFailed();
    error NotResourceOwner();
    error ResourceNotFound();
    error HookFailed();
    error SemaphoreCallFailed();
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
    SemaphoreCallFailed(SemaphoreCallFailed),
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
    usdc_address:          StorageAddress,
    semaphore_address:     StorageAddress,
    global_group_id:       StorageU256,
    resource_price:        StorageMap<FixedBytes<32>, StorageU256>,
    resource_owners:       StorageMap<FixedBytes<32>, StorageAddress>,
    resource_uris:         StorageMap<FixedBytes<32>, StorageString>,
    resource_hooks:        StorageMap<FixedBytes<32>, StorageAddress>,
    nullifiers:            StorageMap<U256, StorageBool>,
    settlements:           StorageMap<FixedBytes<32>, StorageBool>,
    registrations:         StorageMap<FixedBytes<32>, StorageBool>,
}

#[public]
impl SettlementRegistry {
    /// The registry creates its own Semaphore group so that *it* is the group
    /// admin — `addMember` is `onlyGroupAdmin`, and Semaphore's admin handover
    /// is two-step (`updateGroupAdmin` + `acceptGroupAdmin`), which this
    /// contract has no way to accept. Taking a group id as a constructor arg
    /// is a footgun: any id not created by this address bricks create_resource.
    #[constructor]
    pub fn init(
        &mut self,
        usdc_address: Address,
        semaphore_address: Address,
    ) -> Result<(), SettlementError> {
        self.usdc_address.set(usdc_address);
        self.semaphore_address.set(semaphore_address);

        let ret = unsafe {
            RawCall::new(self.vm())
                .call(semaphore_address, &keccak256(b"createGroup()")[..4])
        }
        .map_err(|_| SettlementError::SemaphoreCallFailed(SemaphoreCallFailed {}))?;

        if ret.len() < 32 {
            return Err(SettlementError::SemaphoreCallFailed(SemaphoreCallFailed {}));
        }
        self.global_group_id.set(U256::from_be_slice(&ret[..32]));
        Ok(())
    }

    /// Callable directly by any publisher
   pub fn create_resource(
        &mut self,
        resource_id: FixedBytes<32>,
        price: U256,
        uri: String, 
    ) -> Result<(), SettlementError> {
        if self.resource_owners.get(resource_id) != Address::ZERO {
            return Err(SettlementError::AlreadyRegistered(AlreadyRegistered {}));
        }

        // Bind ownership directly to the transaction caller
        let owner = self.vm().msg_sender();

        self.resource_owners.setter(resource_id).set(owner);
        self.resource_price.setter(resource_id).set(price);
        self.resource_uris.setter(resource_id).set_str(&uri);

        // Add publisher commitment seed to global Semaphore group
        let seed = U256::from_be_bytes(*keccak256(resource_id.as_slice())) % BN254_FIELD_MOD;
        let group_id = self.global_group_id.get();
        
        unsafe {
            RawCall::new(self.vm())
                .call(self.semaphore_address.get(), &sel_add_member(group_id, seed))
        }
        .map_err(|_| SettlementError::SemaphoreCallFailed(SemaphoreCallFailed {}))?;

        self.vm().log(MemberRegistered { resourceId: resource_id, identityCommitment: seed });
        self.vm().log(ResourceCreated { resourceId: resource_id, owner, price, uri });
        Ok(())
    }

    pub fn update_price(
        &mut self,
        resource_id: FixedBytes<32>,
        price: U256,
    ) -> Result<(), SettlementError> {
        let stored_owner = self.resource_owners.get(resource_id);
        if stored_owner == Address::ZERO {
            return Err(SettlementError::ResourceNotFound(ResourceNotFound {}));
        }
        // Ensure the caller is the registered owner
        if self.vm().msg_sender() != stored_owner {
            return Err(SettlementError::NotResourceOwner(NotResourceOwner {}));
        }
        
        self.resource_price.setter(resource_id).set(price);
        self.vm().log(PriceUpdated { resourceId: resource_id, owner: stored_owner, price });
        Ok(())
    }

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

        let group_id = self.global_group_id.get();
        unsafe {
            RawCall::new(self.vm())
                .call(self.semaphore_address.get(), &sel_add_member(group_id, identity_commitment))
        }
        .map_err(|_| SettlementError::SemaphoreCallFailed(SemaphoreCallFailed {}))?;

        self.registrations.setter(reg_key).set(true);
        self.vm().log(MemberRegistered {
            resourceId: resource_id,
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

        let group_id = self.global_group_id.get();
        let scope = U256::from_be_bytes(*resource_id); 
        
        unsafe {
            RawCall::new(self.vm()).call(
                self.semaphore_address.get(),
                &sel_validate_proof(group_id, merkle_tree_depth, merkle_tree_root, nullifier, message, scope, &points),
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
    pub fn get_global_group_id(&self) -> U256 { self.global_group_id.get() }
    pub fn get_owner(&self, resource_id: FixedBytes<32>) -> Address { self.resource_owners.get(resource_id) }
    pub fn get_uri(&self, resource_id: FixedBytes<32>) -> String { self.resource_uris.get(resource_id).get_string() }
}

// ── ABI Encoders ─────────────────────────────────────────────────────────────

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
fn hash_concat(a: &[u8], b: &[u8]) -> FixedBytes<32> {
    let mut data = alloc::vec::Vec::with_capacity(a.len() + b.len());
    data.extend_from_slice(a);
    data.extend_from_slice(b);
    keccak256(&data)
}