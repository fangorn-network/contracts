#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{keccak256, Address, FixedBytes, U256},
    call::RawCall,
    prelude::*,
    storage::*,
};

sol! {
    event MemberRegistered(bytes32 indexed resourceId, uint256 indexed groupId, uint256 identityCommitment);
    event SettlementFinalized(bytes32 indexed resourceId, uint256 indexed nullifierHash, uint256 message);
    event ResourceUpdated(bytes32 indexed resourceId, address hook, uint256 price);
    event ResourceCreated(bytes32 indexed resourceId, uint256 groupId, address owner, uint256 price);

    // Error codes:
    //  1 = AlreadyRegistered
    //  2 = AlreadySettled
    //  3 = IncorrectPaymentAmount
    //  4 = TransferFailed
    //  5 = VerificationFailed
    //  6 = NotResourceOwner
    //  7 = NotAdmin
    //  8 = NotAuthorizedRegistry
    //  9 = ResourceNotFound
    // 10 = HookFailed
    // 11 = GroupCreationFailed
    error ErrCode(uint8 code);
}

#[derive(SolidityError)]
pub enum SettlementError {
    ErrCode(ErrCode),
}

// Error code constants
const E_ALREADY_REGISTERED: u8 = 1;
const E_ALREADY_SETTLED: u8 = 2;
const E_INCORRECT_PAYMENT: u8 = 3;
const E_TRANSFER_FAILED: u8 = 4;
const E_VERIFICATION_FAILED: u8 = 5;
const E_NOT_RESOURCE_OWNER: u8 = 6;
const E_NOT_ADMIN: u8 = 7;
const E_NOT_AUTHORIZED_REGISTRY: u8 = 8;
const E_RESOURCE_NOT_FOUND: u8 = 9;
const E_HOOK_FAILED: u8 = 10;
const E_GROUP_CREATION_FAILED: u8 = 11;

#[inline(never)]
fn err(code: u8) -> SettlementError {
    SettlementError::ErrCode(ErrCode { code })
}

const BN254_FIELD_MOD: U256 = U256::from_limbs([
    0x43e1f593f0000001,
    0x2833e84879b97091,
    0xb85045b68181585d,
    0x30644e72e131a029,
]);

const SEL_CREATE_GROUP: [u8; 4] = [0x5c, 0x3f, 0x3b, 0x60];
const SEL_ADD_MEMBER: [u8; 4] = [0x17, 0x83, 0xef, 0xc3];
const SEL_VALIDATE_PROOF: [u8; 4] = [0xd0, 0xd8, 0x98, 0xdd];
const SEL_TRANSFER_AUTH: [u8; 4] = [0xe3, 0xee, 0x16, 0x0e];
const SEL_AFTER_SETTLE: [u8; 4] = [0x71, 0xe5, 0xea, 0xc2];

#[storage]
pub struct Resource {
    group_id: StorageU256,
    price: StorageU256,
    owner: StorageAddress,
    hook: StorageAddress,
}

#[storage]
#[entrypoint]
pub struct SettlementRegistry {
    admin: StorageAddress,
    usdc_address: StorageAddress,
    semaphore_address: StorageAddress,
    authorized_registries: StorageMap<Address, StorageBool>,
    resources: StorageMap<FixedBytes<32>, Resource>,
    nullifiers: StorageMap<U256, StorageBool>,
    settlements: StorageMap<Address, StorageMap<FixedBytes<32>, StorageBool>>,
    registrations: StorageMap<FixedBytes<32>, StorageMap<U256, StorageBool>>,
}

#[public]
impl SettlementRegistry {
    #[constructor]
    pub fn init(
        &mut self,
        admin: Address, 
        usdc_address: Address, 
        semaphore_address: Address
    ) {
        self.admin.set(admin);
        self.usdc_address.set(usdc_address);
        self.semaphore_address.set(semaphore_address);
    }

    pub fn set_registry(
        &mut self,
        registry: Address,
        authorized: bool,
    ) -> Result<(), SettlementError> {
        if self.vm().msg_sender() != self.admin.get() {
            return Err(err(E_NOT_ADMIN));
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
        if self.resources.getter(resource_id).owner.get() != Address::ZERO {
            return Err(err(E_ALREADY_REGISTERED));
        }

        let this = self.vm().contract_address();
        let ret = unsafe {
            RawCall::new(self.vm()).call(self.semaphore_address.get(), &sel_create_group(this))
        }
        .map_err(|_| err(E_GROUP_CREATION_FAILED))?;
        let group_id = decode_u256(&ret).ok_or(err(E_GROUP_CREATION_FAILED))?;

        {
            let mut r = self.resources.setter(resource_id);
            r.group_id.set(group_id);
            r.owner.set(owner);
            r.price.set(price);
        }

        let seed = U256::from_be_bytes(*keccak256(resource_id.as_slice())) % BN254_FIELD_MOD;
        unsafe {
            RawCall::new(self.vm()).call(
                self.semaphore_address.get(),
                &sel_add_member(group_id, seed),
            )
        }
        .map_err(|_| err(E_GROUP_CREATION_FAILED))?;

        // self.vm().log(MemberRegistered {
        //     resourceId: resource_id,
        //     groupId: group_id,
        //     identityCommitment: seed,
        // });
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
            return Err(err(E_RESOURCE_NOT_FOUND));
        }
        if self.vm().msg_sender() != owner {
            return Err(err(E_NOT_RESOURCE_OWNER));
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
            return Err(err(E_RESOURCE_NOT_FOUND));
        }
        if self
            .registrations
            .getter(resource_id)
            .get(identity_commitment)
        {
            return Err(err(E_ALREADY_REGISTERED));
        }
        if amount != price {
            return Err(err(E_INCORRECT_PAYMENT));
        }

        unsafe {
            RawCall::new(self.vm()).call(
                self.usdc_address.get(),
                &sel_transfer_auth(from, to, amount, valid_after, valid_before, nonce, v, r, s),
            )
        }
        .map_err(|_| err(E_TRANSFER_FAILED))?;

        unsafe {
            RawCall::new(self.vm()).call(
                self.semaphore_address.get(),
                &sel_add_member(group_id, identity_commitment),
            )
        }
        .map_err(|_| err(E_GROUP_CREATION_FAILED))?;

        self.registrations
            .setter(resource_id)
            .setter(identity_commitment)
            .set(true);
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
            let r = self.resources.getter(resource_id);
            (r.owner.get(), r.group_id.get(), r.hook.get())
        };
        if owner == Address::ZERO {
            return Err(err(E_RESOURCE_NOT_FOUND));
        }
        if self.nullifiers.get(nullifier) {
            return Err(err(E_ALREADY_SETTLED));
        }

        unsafe {
            RawCall::new(self.vm()).call(
                self.semaphore_address.get(),
                &sel_validate_proof(
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
        .map_err(|_| err(E_VERIFICATION_FAILED))?;

        self.nullifiers.setter(nullifier).set(true);
        self.settlements
            .setter(stealth_address)
            .setter(resource_id)
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
            .map_err(|_| err(E_HOOK_FAILED))?;
        }
        Ok(())
    }

    pub fn is_settled(&self, stealth_address: Address, resource_id: FixedBytes<32>) -> bool {
        self.settlements.getter(stealth_address).get(resource_id)
    }

    pub fn is_registered(&self, resource_id: FixedBytes<32>, identity_commitment: U256) -> bool {
        self.registrations
            .getter(resource_id)
            .get(identity_commitment)
    }

    /// Returns the Semaphore group id for a resource, or 0 if the resource doesn't exist.
    /// Group ids start at 1 (groupCounter is post-incremented in Semaphore V4's createGroup,
    /// but adjust interpretation on caller side if treating 0 as sentinel).
    pub fn get_group_id(&self, resource_id: FixedBytes<32>) -> U256 {
        self.resources.getter(resource_id).group_id.get()
    }

    pub fn get_price(&self, resource_id: FixedBytes<32>) -> U256 {
        self.resources.getter(resource_id).price.get()
    }
}

impl SettlementRegistry {
    #[inline(never)]
    fn only_authorized_registry(&self) -> Result<(), SettlementError> {
        if !self.authorized_registries.get(self.vm().msg_sender()) {
            return Err(err(E_NOT_AUTHORIZED_REGISTRY));
        }
        Ok(())
    }
}

#[inline(never)]
fn sel_create_group(admin: Address) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_CREATE_GROUP.to_vec();
    cd.extend_from_slice(&[0u8; 12]);
    cd.extend_from_slice(admin.as_slice());
    cd
}

#[inline(never)]
fn sel_add_member(group_id: U256, commitment: U256) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_ADD_MEMBER.to_vec();
    cd.extend_from_slice(&group_id.to_be_bytes::<32>());
    cd.extend_from_slice(&commitment.to_be_bytes::<32>());
    cd
}

#[inline(never)]
fn sel_validate_proof(
    group_id: U256,
    depth: U256,
    root: U256,
    nullifier: U256,
    message: U256,
    scope: U256,
    points: &[U256; 8],
) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_VALIDATE_PROOF.to_vec();
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
fn decode_u256(ret: &[u8]) -> Option<U256> {
    if ret.len() < 32 {
        return None;
    }
    Some(U256::from_be_slice(&ret[..32]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use stylus_sdk::alloy_primitives::{keccak256, FixedBytes, U256};

    fn resource_id() -> FixedBytes<32> {
        keccak256(b"test-resource-v1")
    }

    #[test]
    fn test_seed_in_field() {
        let seed = U256::from_be_bytes(*keccak256(resource_id().as_slice())) % BN254_FIELD_MOD;
        assert!(seed < BN254_FIELD_MOD);
        assert_ne!(seed, U256::ZERO);
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
            U256::ZERO,
            U256::ZERO,
            U256::ZERO,
            U256::ZERO,
            U256::ZERO,
            U256::ZERO,
            &[U256::ZERO; 8],
        );
        assert_eq!(
            &cd[..4],
            &keccak256(
                b"validateProof(uint256,(uint256,uint256,uint256,uint256,uint256,uint256[8]))"
            )[..4]
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
}