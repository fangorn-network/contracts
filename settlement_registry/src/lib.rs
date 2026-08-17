//! SettlementRegistry — pay for a resource, then prove you paid without saying
//! who you are.
//!
//! ## What changed in v2, and why
//!
//! v1 kept ONE Semaphore group for the whole registry. `register()` paid a
//! publisher and added the buyer to that global group; `settle()` then verified
//! group membership with the resource as the proof scope — and nothing else. The
//! consequences were not subtle:
//!
//!   1. Membership meant "paid for *something*, once". A buyer who paid one
//!      publisher $0.10 could settle every resource in the registry, from every
//!      publisher, forever.
//!   2. `create_resource` was unauthenticated and took an arbitrary price, so
//!      anyone could mint a resource priced at zero, register against it for
//!      free, and land in that same global group. Total paywall bypass for the
//!      cost of gas.
//!   3. `register()` took the payment recipient as an argument and never checked
//!      it against the resource's owner. A buyer could pay themselves and still
//!      join the group.
//!
//! v2 closes all three:
//!
//!   * **One Semaphore group per resource.** Membership in resource R's group is
//!     exactly "somebody paid for R", so `settle(R)` verifying against R's own
//!     group is a payment check that stays anonymous. The anonymity set narrows
//!     from "every buyer ever" to "the buyers of this resource" — that is the
//!     real cost of correctness here, and it is the right trade: an entitlement
//!     nobody paid for is not privacy, it is a broken paywall.
//!   * **The registry derives the resourceId** as keccak(publisher ++ uid), so a
//!     resourceId cannot be squatted, front-run, or claimed by anyone but the
//!     publisher whose address is baked into it.
//!   * **`register()` pays `resource_owners[id]`**, read from storage. There is
//!     no recipient argument to get wrong.
//!
//! v2 also adds a `disabled` flag (owner or admin), because takedown had no
//! on-chain representation at all and the access gate had nothing to consult.
//!
//! ## What this contract does NOT do
//!
//! Disabling stops new registrations and new settlements. It does not and cannot
//! un-settle an existing buyer: `is_settled` stays true, because that is a
//! historical fact. Enforcement of a takedown against already-settled buyers is
//! the access gate's job (refuse to release the DEK for a disabled resource),
//! not the chain's.
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
    event ResourceCreated(bytes32 indexed resourceId, address owner, uint256 price, uint256 groupId, string uri);
    event PriceUpdated(bytes32 indexed resourceId, address owner, uint256 price);
    event ResourceDisabled(bytes32 indexed resourceId, bool disabled, address by);
    event AdminChanged(address previousAdmin, address newAdmin);

    error AlreadyRegistered();
    error AlreadySettled();
    error IncorrectPaymentAmount();
    error TransferFailed();
    error VerificationFailed();
    error NotResourceOwner();
    error ResourceNotFound();
    error HookFailed();
    error SemaphoreCallFailed();
    error ResourceIsDisabled();
    error NotAdmin();
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
    ResourceIsDisabled(ResourceIsDisabled),
    NotAdmin(NotAdmin),
}

#[storage]
#[entrypoint]
pub struct SettlementRegistry {
    usdc_address:      StorageAddress,
    semaphore_address: StorageAddress,
    /// May be zero — a registry deployed with no admin has no takedown authority
    /// beyond each resource's own owner. That is a deployment-time choice about
    /// who can pull content, and it is deliberately visible on-chain.
    admin:             StorageAddress,
    resource_price:    StorageMap<FixedBytes<32>, StorageU256>,
    resource_owners:   StorageMap<FixedBytes<32>, StorageAddress>,
    resource_uris:     StorageMap<FixedBytes<32>, StorageString>,
    resource_hooks:    StorageMap<FixedBytes<32>, StorageAddress>,
    /// resourceId → its own Semaphore group. The heart of v2.
    resource_groups:   StorageMap<FixedBytes<32>, StorageU256>,
    resource_disabled: StorageMap<FixedBytes<32>, StorageBool>,
    nullifiers:        StorageMap<U256, StorageBool>,
    settlements:       StorageMap<FixedBytes<32>, StorageBool>,
    registrations:     StorageMap<FixedBytes<32>, StorageBool>,
}

#[public]
impl SettlementRegistry {
    /// `admin` may be `Address::ZERO` for a registry nobody can administer.
    ///
    /// Note there is no group created here any more. Groups are per-resource and
    /// are created by `create_resource`, which means this registry is the admin
    /// of every group it creates — `addMember` is `onlyGroupAdmin`, and
    /// Semaphore's admin handover is two-step, which this contract cannot
    /// accept. Creating each group here keeps that property per resource.
    #[constructor]
    pub fn init(
        &mut self,
        usdc_address: Address,
        semaphore_address: Address,
        admin: Address,
    ) -> Result<(), SettlementError> {
        self.usdc_address.set(usdc_address);
        self.semaphore_address.set(semaphore_address);
        self.admin.set(admin);
        self.vm().log(AdminChanged { previousAdmin: Address::ZERO, newAdmin: admin });
        Ok(())
    }

    /// Hand over (or renounce, with `Address::ZERO`) the takedown authority.
    pub fn set_admin(&mut self, new_admin: Address) -> Result<(), SettlementError> {
        let current = self.admin.get();
        if self.vm().msg_sender() != current || current == Address::ZERO {
            return Err(SettlementError::NotAdmin(NotAdmin {}));
        }
        self.admin.set(new_admin);
        self.vm().log(AdminChanged { previousAdmin: current, newAdmin: new_admin });
        Ok(())
    }

    /// Create a resource owned by the caller, and its Semaphore group.
    ///
    /// The resourceId is DERIVED, not supplied: `keccak(publisher ++ uid)`. In v1
    /// the caller passed the id, which meant the id space was first-come — anyone
    /// watching the mempool could claim a publisher's id, set their own price and
    /// URI, and collect the payments while the real publisher's `create_resource`
    /// reverted forever. Deriving it makes that impossible: an id nobody can
    /// produce without the publisher's address is an id nobody can steal.
    ///
    /// Returns the id so the caller does not have to recompute it.
    pub fn create_resource(
        &mut self,
        uid: FixedBytes<32>,
        price: U256,
        uri: String,
    ) -> Result<FixedBytes<32>, SettlementError> {
        let owner = self.vm().msg_sender();
        let resource_id = resource_id_of(owner, uid);

        if self.resource_owners.get(resource_id) != Address::ZERO {
            return Err(SettlementError::AlreadyRegistered(AlreadyRegistered {}));
        }

        // One group per resource. Created before any state is written so a
        // Semaphore failure leaves nothing half-built.
        let ret = unsafe {
            RawCall::new(self.vm())
                .call(self.semaphore_address.get(), &keccak256(b"createGroup()")[..4])
        }
        .map_err(|_| SettlementError::SemaphoreCallFailed(SemaphoreCallFailed {}))?;
        if ret.len() < 32 {
            return Err(SettlementError::SemaphoreCallFailed(SemaphoreCallFailed {}));
        }
        let group_id = U256::from_be_slice(&ret[..32]);

        self.resource_owners.setter(resource_id).set(owner);
        self.resource_price.setter(resource_id).set(price);
        self.resource_uris.setter(resource_id).set_str(&uri);
        self.resource_groups.setter(resource_id).set(group_id);

        // v1 seeded each new resource into the global group with
        // keccak(resourceId) as a fake "member". Nothing can ever prove
        // membership with that leaf (there is no identity secret behind it), so
        // it bought nothing and inflated every member count and every client-side
        // group rebuild. A group's members are now exactly its buyers.
        self.vm().log(ResourceCreated { resourceId: resource_id, owner, price, groupId: group_id, uri });
        Ok(resource_id)
    }

    pub fn update_price(
        &mut self,
        resource_id: FixedBytes<32>,
        price: U256,
    ) -> Result<(), SettlementError> {
        let owner = self.owner_or_revert(resource_id)?;
        if self.vm().msg_sender() != owner {
            return Err(SettlementError::NotResourceOwner(NotResourceOwner {}));
        }
        self.resource_price.setter(resource_id).set(price);
        self.vm().log(PriceUpdated { resourceId: resource_id, owner, price });
        Ok(())
    }

    pub fn register_hook(
        &mut self,
        resource_id: FixedBytes<32>,
        hook: Address,
    ) -> Result<(), SettlementError> {
        let owner = self.owner_or_revert(resource_id)?;
        if self.vm().msg_sender() != owner {
            return Err(SettlementError::NotResourceOwner(NotResourceOwner {}));
        }
        self.resource_hooks.setter(resource_id).set(hook);
        self.vm().log(HookRegistered { resourceId: resource_id, hook });
        Ok(())
    }

    /// Take a resource down (or put it back). Either the owner or the registry
    /// admin may do this — the owner because it is their content, the admin
    /// because a platform served with a valid takedown notice needs a lever that
    /// does not depend on the publisher's cooperation.
    ///
    /// Existing settlements are untouched; see the module docs.
    pub fn set_disabled(
        &mut self,
        resource_id: FixedBytes<32>,
        disabled: bool,
    ) -> Result<(), SettlementError> {
        let owner = self.owner_or_revert(resource_id)?;
        let sender = self.vm().msg_sender();
        let admin = self.admin.get();
        if sender != owner && (admin == Address::ZERO || sender != admin) {
            return Err(SettlementError::NotResourceOwner(NotResourceOwner {}));
        }
        self.resource_disabled.setter(resource_id).set(disabled);
        self.vm().log(ResourceDisabled { resourceId: resource_id, disabled, by: sender });
        Ok(())
    }

    /// Pay for a resource and join its group.
    ///
    /// There is no `to` parameter. v1 accepted one and forwarded it straight to
    /// `transferWithAuthorization` while only checking the AMOUNT, so a buyer
    /// could sign an authorization paying themselves the correct price and join
    /// the group having paid the publisher nothing. The recipient now comes from
    /// storage and cannot be influenced by the caller.
    ///
    /// A zero-priced resource skips the transfer entirely rather than demanding a
    /// signature to move zero dollars. Free is free — and because groups are
    /// per-resource, joining a free resource's group entitles the joiner to that
    /// resource and nothing else.
    pub fn register(
        &mut self,
        resource_id:         FixedBytes<32>,
        identity_commitment: U256,
        from:                Address,
        amount:              U256,
        valid_after:         U256,
        valid_before:        U256,
        nonce:               FixedBytes<32>,
        v:                   u8,
        r:                   FixedBytes<32>,
        s:                   FixedBytes<32>,
    ) -> Result<(), SettlementError> {
        let owner = self.owner_or_revert(resource_id)?;
        self.not_disabled_or_revert(resource_id)?;

        let reg_key = hash_concat(resource_id.as_slice(), &identity_commitment.to_be_bytes::<32>());
        if self.registrations.get(reg_key) {
            return Err(SettlementError::AlreadyRegistered(AlreadyRegistered {}));
        }
        let price = self.resource_price.get(resource_id);
        if amount != price {
            return Err(SettlementError::IncorrectPaymentAmount(IncorrectPaymentAmount {}));
        }

        if amount > U256::ZERO {
            unsafe {
                RawCall::new(self.vm()).call(
                    self.usdc_address.get(),
                    &sel_transfer_auth(from, owner, amount, valid_after, valid_before, nonce, v, r, s),
                )
            }
            .map_err(|_| SettlementError::TransferFailed(TransferFailed {}))?;
        }

        let group_id = self.resource_groups.get(resource_id);
        unsafe {
            RawCall::new(self.vm())
                .call(self.semaphore_address.get(), &sel_add_member(group_id, identity_commitment))
        }
        .map_err(|_| SettlementError::SemaphoreCallFailed(SemaphoreCallFailed {}))?;

        self.registrations.setter(reg_key).set(true);
        self.vm().log(MemberRegistered { resourceId: resource_id, identityCommitment: identity_commitment });
        Ok(())
    }

    /// Prove — without revealing which buyer you are — that you are a member of
    /// THIS resource's group, and record access for `stealth_address`.
    ///
    /// The group id comes from the resource. In v1 it came from a single global
    /// field, which is what made one payment unlock the whole registry.
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
        self.owner_or_revert(resource_id)?;
        self.not_disabled_or_revert(resource_id)?;

        if self.nullifiers.get(nullifier) {
            return Err(SettlementError::AlreadySettled(AlreadySettled {}));
        }

        let group_id = self.resource_groups.get(resource_id);
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

    // ── views ────────────────────────────────────────────────────────────────

    /// The id a given publisher's uid maps to. Clients derive this themselves;
    /// exposing it keeps the two derivations from drifting apart.
    pub fn resource_id_for(&self, publisher: Address, uid: FixedBytes<32>) -> FixedBytes<32> {
        resource_id_of(publisher, uid)
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

    pub fn is_disabled(&self, resource_id: FixedBytes<32>) -> bool { self.resource_disabled.get(resource_id) }
    pub fn get_price(&self, resource_id: FixedBytes<32>) -> U256 { self.resource_price.get(resource_id) }
    pub fn get_group_id(&self, resource_id: FixedBytes<32>) -> U256 { self.resource_groups.get(resource_id) }
    pub fn get_owner(&self, resource_id: FixedBytes<32>) -> Address { self.resource_owners.get(resource_id) }
    pub fn get_uri(&self, resource_id: FixedBytes<32>) -> String { self.resource_uris.get(resource_id).get_string() }
    pub fn get_admin(&self) -> Address { self.admin.get() }
    pub fn get_usdc(&self) -> Address { self.usdc_address.get() }
    pub fn get_semaphore(&self) -> Address { self.semaphore_address.get() }
}

impl SettlementRegistry {
    fn owner_or_revert(&self, resource_id: FixedBytes<32>) -> Result<Address, SettlementError> {
        let owner = self.resource_owners.get(resource_id);
        if owner == Address::ZERO {
            return Err(SettlementError::ResourceNotFound(ResourceNotFound {}));
        }
        Ok(owner)
    }

    fn not_disabled_or_revert(&self, resource_id: FixedBytes<32>) -> Result<(), SettlementError> {
        if self.resource_disabled.get(resource_id) {
            return Err(SettlementError::ResourceIsDisabled(ResourceIsDisabled {}));
        }
        Ok(())
    }
}

/// keccak(publisher ++ uid) — the whole anti-squatting property in one line.
fn resource_id_of(publisher: Address, uid: FixedBytes<32>) -> FixedBytes<32> {
    hash_concat(publisher.as_slice(), uid.as_slice())
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

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::{address, b256, hex_literal::hex};

    #[test]
    fn test_hash_concat() {
        let a = [1u8; 32];
        let b = [2u8; 32];
        assert_eq!(hash_concat(&a, &b), keccak256([a.as_slice(), b.as_slice()].concat()));
    }

    #[test]
    fn resource_id_binds_publisher_and_uid() {
        let alice = address!("1111111111111111111111111111111111111111");
        let bob = address!("2222222222222222222222222222222222222222");
        let uid = b256!("00000000000000000000000000000000000000000000000000000000000000aa");

        // Exactly keccak(publisher ++ uid) — clients must be able to reproduce it.
        assert_eq!(
            resource_id_of(alice, uid),
            keccak256([alice.as_slice(), uid.as_slice()].concat())
        );
        // The same uid under two publishers is two different resources, which is
        // what makes squatting impossible.
        assert_ne!(resource_id_of(alice, uid), resource_id_of(bob, uid));
    }

    #[test]
    fn test_sel_add_member() {
        let calldata = sel_add_member(U256::from(42), U256::from(999));
        assert_eq!(&calldata[0..4], &hex!("1783efc3"));
        assert_eq!(U256::from_be_slice(&calldata[4..36]), U256::from(42));
        assert_eq!(U256::from_be_slice(&calldata[36..68]), U256::from(999));
    }

    #[test]
    fn test_sel_after_settle() {
        let resource_id = b256!("1111111111111111111111111111111111111111111111111111111111111111");
        let calldata = sel_after_settle(resource_id, U256::from(12345), U256::from(67890), &[0xaa, 0xbb, 0xcc]);

        assert_eq!(&calldata[0..4], &hex!("71e5eac2"));
        assert_eq!(&calldata[4..36], resource_id.as_slice());
        assert_eq!(U256::from_be_slice(&calldata[36..68]), U256::from(12345));
        assert_eq!(U256::from_be_slice(&calldata[68..100]), U256::from(67890));
        assert_eq!(U256::from_be_slice(&calldata[100..132]), U256::from(0x80));
        assert_eq!(U256::from_be_slice(&calldata[132..164]), U256::from(3));
        assert_eq!(&calldata[164..167], [0xaa, 0xbb, 0xcc].as_slice());
    }

    #[test]
    fn test_sel_transfer_auth() {
        let from = address!("1111111111111111111111111111111111111111");
        let to = address!("2222222222222222222222222222222222222222");
        let calldata = sel_transfer_auth(
            from, to, U256::from(1000), U256::ZERO, U256::from(9999999999_u64),
            b256!("3333333333333333333333333333333333333333333333333333333333333333"),
            27,
            b256!("4444444444444444444444444444444444444444444444444444444444444444"),
            b256!("5555555555555555555555555555555555555555555555555555555555555555"),
        );

        assert_eq!(&calldata[0..4], &hex!("e3ee160e"));
        assert_eq!(&calldata[16..36], from.as_slice());
        assert_eq!(&calldata[48..68], to.as_slice());
        assert_eq!(U256::from_be_slice(&calldata[68..100]), U256::from(1000));
    }
}

#[cfg(test)]
mod state_tests {
    use super::*;
    use stylus_sdk::alloy_primitives::address;
    use stylus_sdk::testing::TestVM;

    const USDC: Address = address!("1111111111111111111111111111111111111111");
    const SEMAPHORE: Address = address!("2222222222222222222222222222222222222222");
    const OWNER: Address = address!("3333333333333333333333333333333333333333");
    const BUYER: Address = address!("4444444444444444444444444444444444444444");
    const HOOK: Address = address!("5555555555555555555555555555555555555555");
    const STEALTH: Address = address!("6666666666666666666666666666666666666666");
    const ADMIN: Address = address!("7777777777777777777777777777777777777777");
    const ATTACKER: Address = address!("8888888888888888888888888888888888888888");
    const STRANGER: Address = address!("9999999999999999999999999999999999999999");

    const UID: FixedBytes<32> = FixedBytes([0xaa; 32]);
    const UID2: FixedBytes<32> = FixedBytes([0xbb; 32]);
    const PRICE: u64 = 1_000_000; // 1 USDC
    const GROUP_A: u64 = 7;
    const GROUP_B: u64 = 8;

    // ── harness ──────────────────────────────────────────────────────────────
    //
    // TestVM returns Ok(empty) for any call that is NOT mocked, so happy paths
    // need no mocks at all. That cuts both ways: it means a test can never prove
    // that Semaphore *rejected* something, because the stub always accepts.
    //
    // So the interesting properties are pinned a different way — mock the EXACT
    // calldata the contract is supposed to emit and make that mock revert. If the
    // contract built that calldata, the revert propagates and the test sees the
    // error. If it built anything else (wrong group, wrong recipient), the mock
    // never matches, the call silently succeeds, and the assertion fails. Every
    // `_pins_` test below works this way, in both directions.

    fn mock_group(vm: &TestVM, id: u64) {
        vm.mock_call(
            SEMAPHORE,
            keccak256(b"createGroup()")[..4].to_vec(),
            U256::ZERO,
            Ok(U256::from(id).to_be_bytes::<32>().to_vec()),
        );
    }

    fn new_registry(vm: &TestVM) -> SettlementRegistry {
        let mut r = SettlementRegistry::from(vm);
        ok(r.init(USDC, SEMAPHORE, ADMIN));
        r
    }

    /// Registry with one resource: OWNER's UID at PRICE, group GROUP_A.
    fn with_resource(vm: &TestVM) -> (SettlementRegistry, FixedBytes<32>) {
        let mut r = new_registry(vm);
        mock_group(vm, GROUP_A);
        vm.set_sender(OWNER);
        let rid = created(r.create_resource(UID, U256::from(PRICE), String::from("ipfs://x")));
        (r, rid)
    }

    // sol!-generated error structs have no Debug, so `.unwrap()`/`.expect()` are out.
    fn ok(r: Result<(), SettlementError>) {
        assert!(r.is_ok(), "expected Ok");
    }

    fn created(r: Result<FixedBytes<32>, SettlementError>) -> FixedBytes<32> {
        match r {
            Ok(id) => id,
            Err(_) => panic!("expected the resource to be created"),
        }
    }

    fn points() -> [U256; 8] {
        core::array::from_fn(|i| U256::from(i as u64))
    }

    /// (from, amount, valid_after, valid_before, nonce, v, r, s)
    fn auth(amount: U256) -> (Address, U256, U256, U256, FixedBytes<32>, u8, FixedBytes<32>, FixedBytes<32>) {
        (BUYER, amount, U256::ZERO, U256::from(u64::MAX), FixedBytes([9u8; 32]), 27, FixedBytes([1u8; 32]), FixedBytes([2u8; 32]))
    }

    fn do_register(
        r: &mut SettlementRegistry,
        rid: FixedBytes<32>,
        commitment: U256,
        amount: U256,
    ) -> Result<(), SettlementError> {
        let (from, amt, va, vb, nonce, v, rr, s) = auth(amount);
        r.register(rid, commitment, from, amt, va, vb, nonce, v, rr, s)
    }

    fn do_settle(
        r: &mut SettlementRegistry,
        rid: FixedBytes<32>,
        nullifier: U256,
    ) -> Result<(), SettlementError> {
        r.settle(rid, STEALTH, U256::from(20), U256::from(123), nullifier, U256::from(7), points(), vec![])
    }

    /// The exact validateProof calldata `settle` should emit for this resource.
    fn expected_proof_call(rid: FixedBytes<32>, group: u64, nullifier: U256) -> Vec<u8> {
        sel_validate_proof(
            U256::from(group), U256::from(20), U256::from(123),
            nullifier, U256::from(7), U256::from_be_bytes(*rid), &points(),
        )
    }

    // ── init / admin ─────────────────────────────────────────────────────────

    #[test]
    fn init_stores_addresses_and_admin() {
        let vm = TestVM::default();
        let r = new_registry(&vm);
        assert_eq!(r.get_usdc(), USDC);
        assert_eq!(r.get_semaphore(), SEMAPHORE);
        assert_eq!(r.get_admin(), ADMIN);
    }

    #[test]
    fn admin_can_hand_over_and_renounce() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);

        vm.set_sender(ADMIN);
        ok(r.set_admin(STRANGER));
        assert_eq!(r.get_admin(), STRANGER);

        // The old admin is now powerless.
        vm.set_sender(ADMIN);
        assert!(matches!(r.set_admin(ADMIN), Err(SettlementError::NotAdmin(_))));

        vm.set_sender(STRANGER);
        ok(r.set_admin(Address::ZERO));
        assert_eq!(r.get_admin(), Address::ZERO);

        // Renounced for good: nobody can claim it back.
        vm.set_sender(STRANGER);
        assert!(matches!(r.set_admin(STRANGER), Err(SettlementError::NotAdmin(_))));
    }

    #[test]
    fn stranger_cannot_take_admin() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        vm.set_sender(STRANGER);
        assert!(matches!(r.set_admin(STRANGER), Err(SettlementError::NotAdmin(_))));
        assert_eq!(r.get_admin(), ADMIN);
    }

    // ── create_resource ──────────────────────────────────────────────────────

    #[test]
    fn create_resource_derives_id_and_stores_state() {
        let vm = TestVM::default();
        let (r, rid) = with_resource(&vm);

        assert_eq!(rid, resource_id_of(OWNER, UID));
        assert_eq!(r.resource_id_for(OWNER, UID), rid);
        assert_eq!(r.get_owner(rid), OWNER);
        assert_eq!(r.get_price(rid), U256::from(PRICE));
        assert_eq!(r.get_uri(rid), String::from("ipfs://x"));
        assert_eq!(r.get_group_id(rid), U256::from(GROUP_A));
        assert!(!r.is_disabled(rid));
    }

    /// The anti-squatting property: two publishers, one uid, two resources.
    #[test]
    fn create_resource_cannot_be_squatted() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);

        mock_group(&vm, GROUP_B);
        vm.set_sender(ATTACKER);
        let stolen = created(r.create_resource(UID, U256::from(1), String::from("ipfs://evil")));

        assert_ne!(stolen, rid, "the same uid under a different sender must be a different resource");
        assert_eq!(r.get_owner(rid), OWNER, "the real publisher keeps their resource");
        assert_eq!(r.get_owner(stolen), ATTACKER);
        assert_eq!(r.get_price(rid), U256::from(PRICE), "and their price");
    }

    #[test]
    fn create_resource_rejects_duplicate_from_same_publisher() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);
        mock_group(&vm, GROUP_B);
        vm.set_sender(OWNER);
        assert!(matches!(
            r.create_resource(UID, U256::from(1), String::new()),
            Err(SettlementError::AlreadyRegistered(_))
        ));
        assert_eq!(r.get_price(rid), U256::from(PRICE));
        assert_eq!(r.get_group_id(rid), U256::from(GROUP_A), "the group must not be replaced");
    }

    /// One group per resource. This is the property the whole redesign rests on.
    #[test]
    fn create_resource_makes_a_group_per_resource() {
        let vm = TestVM::default();
        let (mut r, rid_a) = with_resource(&vm);

        mock_group(&vm, GROUP_B);
        vm.set_sender(OWNER);
        let rid_b = created(r.create_resource(UID2, U256::from(PRICE), String::new()));

        assert_ne!(rid_a, rid_b);
        assert_ne!(r.get_group_id(rid_a), r.get_group_id(rid_b), "two resources must never share a group");
    }

    #[test]
    fn create_resource_propagates_semaphore_revert() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        vm.mock_call(SEMAPHORE, keccak256(b"createGroup()")[..4].to_vec(), U256::ZERO, Err(vec![0xff]));
        vm.set_sender(OWNER);
        assert!(matches!(
            r.create_resource(UID, U256::from(PRICE), String::new()),
            Err(SettlementError::SemaphoreCallFailed(_))
        ));
        // Nothing half-built: the group call happens before any state is written.
        assert_eq!(r.get_owner(resource_id_of(OWNER, UID)), Address::ZERO);
    }

    #[test]
    fn create_resource_fails_on_short_semaphore_return() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        vm.mock_call(SEMAPHORE, keccak256(b"createGroup()")[..4].to_vec(), U256::ZERO, Ok(vec![0u8; 8]));
        vm.set_sender(OWNER);
        assert!(matches!(
            r.create_resource(UID, U256::from(PRICE), String::new()),
            Err(SettlementError::SemaphoreCallFailed(_))
        ));
    }

    /// v1 seeded keccak(resourceId) into the group as a fake member. Nothing can
    /// prove membership with it, and it polluted every client-side group rebuild.
    #[test]
    fn create_resource_adds_no_phantom_member() {
        let vm = TestVM::default();
        let seed = U256::from_be_bytes(*keccak256(resource_id_of(OWNER, UID).as_slice())) % U256::from_limbs([
            0x43e1f593f0000001, 0x2833e84879b97091, 0xb85045b68181585d, 0x30644e72e131a029,
        ]);
        // If create_resource still added the seed, this mock would fire and revert.
        vm.mock_call(SEMAPHORE, sel_add_member(U256::from(GROUP_A), seed), U256::ZERO, Err(vec![0xff]));

        let mut r = new_registry(&vm);
        mock_group(&vm, GROUP_A);
        vm.set_sender(OWNER);
        assert!(r.create_resource(UID, U256::from(PRICE), String::new()).is_ok());
    }

    // ── register ─────────────────────────────────────────────────────────────

    #[test]
    fn register_requires_existing_resource() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        assert!(matches!(
            do_register(&mut r, resource_id_of(OWNER, UID), U256::from(1), U256::from(PRICE)),
            Err(SettlementError::ResourceNotFound(_))
        ));
    }

    #[test]
    fn register_rejects_wrong_amount() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);
        vm.set_sender(BUYER);
        assert!(matches!(
            do_register(&mut r, rid, U256::from(1), U256::from(PRICE - 1)),
            Err(SettlementError::IncorrectPaymentAmount(_))
        ));
        assert!(matches!(
            do_register(&mut r, rid, U256::from(1), U256::from(PRICE + 1)),
            Err(SettlementError::IncorrectPaymentAmount(_))
        ));
        assert!(!r.is_registered(rid, U256::from(1)));
    }

    /// v1's critical bug: `to` was a caller-supplied argument, checked only for
    /// amount. Pin that the money goes to the resource owner, from storage.
    #[test]
    fn register_pins_payment_to_the_resource_owner() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);
        let (from, amt, va, vb, nonce, v, rr, s) = auth(U256::from(PRICE));

        vm.mock_call(
            USDC,
            sel_transfer_auth(from, OWNER, amt, va, vb, nonce, v, rr, s),
            U256::ZERO,
            Err(vec![0xff]),
        );
        vm.set_sender(BUYER);
        assert!(
            matches!(do_register(&mut r, rid, U256::from(42), U256::from(PRICE)), Err(SettlementError::TransferFailed(_))),
            "register must build a transfer whose recipient is the resource owner",
        );
    }

    /// The other direction: a transfer to anyone but the owner is never built, so
    /// a buyer cannot pay themselves and still join the group.
    #[test]
    fn register_never_pays_the_buyer() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);
        let (from, amt, va, vb, nonce, v, rr, s) = auth(U256::from(PRICE));

        for recipient in [BUYER, ATTACKER, STRANGER] {
            vm.mock_call(
                USDC,
                sel_transfer_auth(from, recipient, amt, va, vb, nonce, v, rr, s),
                U256::ZERO,
                Err(vec![0xff]),
            );
        }
        vm.set_sender(BUYER);
        ok(do_register(&mut r, rid, U256::from(42), U256::from(PRICE)));
        assert!(r.is_registered(rid, U256::from(42)));
    }

    #[test]
    fn register_adds_member_to_that_resources_group() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);
        vm.mock_call(
            SEMAPHORE,
            sel_add_member(U256::from(GROUP_A), U256::from(42)),
            U256::ZERO,
            Err(vec![0xff]),
        );
        vm.set_sender(BUYER);
        assert!(
            matches!(do_register(&mut r, rid, U256::from(42), U256::from(PRICE)), Err(SettlementError::SemaphoreCallFailed(_))),
            "register must add the commitment to the resource's own group",
        );
    }

    #[test]
    fn register_succeeds_then_rejects_replay() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);
        vm.set_sender(BUYER);

        let commitment = U256::from(42);
        assert!(!r.is_registered(rid, commitment));
        ok(do_register(&mut r, rid, commitment, U256::from(PRICE)));
        assert!(r.is_registered(rid, commitment));
        assert!(!r.is_registered(rid, U256::from(43)), "another buyer is still unregistered");

        assert!(matches!(
            do_register(&mut r, rid, commitment, U256::from(PRICE)),
            Err(SettlementError::AlreadyRegistered(_))
        ));
    }

    /// The same buyer identity paying for a SECOND resource must work. Under v1
    /// this was impossible: one global group plus one commitment per wallet meant
    /// the second addMember hit a duplicate leaf, which is exactly why the client
    /// skipped payment instead.
    #[test]
    fn same_buyer_can_pay_for_a_second_resource() {
        let vm = TestVM::default();
        let (mut r, rid_a) = with_resource(&vm);
        mock_group(&vm, GROUP_B);
        vm.set_sender(OWNER);
        let rid_b = created(r.create_resource(UID2, U256::from(PRICE), String::new()));

        let commitment = U256::from(42);
        vm.set_sender(BUYER);
        ok(do_register(&mut r, rid_a, commitment, U256::from(PRICE)));
        ok(do_register(&mut r, rid_b, commitment, U256::from(PRICE)));

        assert!(r.is_registered(rid_a, commitment));
        assert!(r.is_registered(rid_b, commitment));
    }

    #[test]
    fn register_propagates_transfer_revert_without_recording() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);
        let (from, amt, va, vb, nonce, v, rr, s) = auth(U256::from(PRICE));
        vm.mock_call(
            USDC,
            sel_transfer_auth(from, OWNER, amt, va, vb, nonce, v, rr, s),
            U256::ZERO,
            Err(vec![0xff]),
        );
        vm.set_sender(BUYER);
        assert!(matches!(
            do_register(&mut r, rid, U256::from(42), U256::from(PRICE)),
            Err(SettlementError::TransferFailed(_))
        ));
        assert!(!r.is_registered(rid, U256::from(42)), "a failed payment must leave no registration");
    }

    #[test]
    fn free_resource_skips_the_transfer() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        mock_group(&vm, GROUP_A);
        vm.set_sender(OWNER);
        let rid = created(r.create_resource(UID, U256::ZERO, String::new()));

        // Any transfer at all would hit this mock and revert.
        let (from, amt, va, vb, nonce, v, rr, s) = auth(U256::ZERO);
        vm.mock_call(
            USDC,
            sel_transfer_auth(from, OWNER, amt, va, vb, nonce, v, rr, s),
            U256::ZERO,
            Err(vec![0xff]),
        );
        vm.set_sender(BUYER);
        ok(do_register(&mut r, rid, U256::from(42), U256::ZERO));
        assert!(r.is_registered(rid, U256::from(42)));
    }

    // ── settle ───────────────────────────────────────────────────────────────

    #[test]
    fn settle_requires_existing_resource() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        assert!(matches!(
            do_settle(&mut r, resource_id_of(OWNER, UID), U256::from(1)),
            Err(SettlementError::ResourceNotFound(_))
        ));
    }

    /// The core v2 property: the proof is verified against THIS resource's group,
    /// with this resource as the scope.
    #[test]
    fn settle_pins_verification_to_this_resources_group() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);
        let nullifier = U256::from(99);
        vm.mock_call(SEMAPHORE, expected_proof_call(rid, GROUP_A, nullifier), U256::ZERO, Err(vec![0xff]));
        assert!(
            matches!(do_settle(&mut r, rid, nullifier), Err(SettlementError::VerificationFailed(_))),
            "settle must verify against the resource's own group and scope",
        );
        assert!(!r.is_settled(STEALTH, rid));
    }

    /// The v1 exploit, as a regression test. An attacker mints their own resource
    /// (free, or at any price they like), registers into ITS group, and then tries
    /// to settle the victim's resource. Under v1 that worked, because every
    /// resource shared one group. Here, settle(victim) is verified against the
    /// victim's group — never the attacker's — so the attacker's membership is
    /// not evidence of anything.
    ///
    /// What is pinned: settle never verifies against a group the caller can join
    /// cheaply elsewhere. Rejecting a non-member's proof is Semaphore's job, and
    /// the TestVM stub cannot model it.
    #[test]
    fn a_free_resource_does_not_unlock_someone_elses() {
        let vm = TestVM::default();
        let (mut r, victim) = with_resource(&vm);

        // Attacker mints a free resource of their own and joins its group.
        mock_group(&vm, GROUP_B);
        vm.set_sender(ATTACKER);
        let freebie = created(r.create_resource(UID, U256::ZERO, String::new()));
        assert_ne!(freebie, victim);
        ok(do_register(&mut r, freebie, U256::from(42), U256::ZERO));

        assert_ne!(
            r.get_group_id(freebie), r.get_group_id(victim),
            "a resource anyone can join for free must not share a group with a paid one",
        );

        // Settling the victim's resource must consult the VICTIM's group.
        let nullifier = U256::from(99);
        vm.mock_call(SEMAPHORE, expected_proof_call(victim, GROUP_A, nullifier), U256::ZERO, Err(vec![0xff]));
        assert!(
            matches!(do_settle(&mut r, victim, nullifier), Err(SettlementError::VerificationFailed(_))),
            "settle must not accept membership earned in another resource's group",
        );
        assert!(!r.is_settled(STEALTH, victim));
    }

    /// The same property from the other side: proving against the attacker's
    /// group is never even attempted.
    #[test]
    fn settle_never_consults_another_resources_group() {
        let vm = TestVM::default();
        let (mut r, victim) = with_resource(&vm);
        mock_group(&vm, GROUP_B);
        vm.set_sender(ATTACKER);
        let other = created(r.create_resource(UID, U256::ZERO, String::new()));

        let nullifier = U256::from(99);
        // If settle used the other group (or the other scope), one of these fires.
        vm.mock_call(SEMAPHORE, expected_proof_call(victim, GROUP_B, nullifier), U256::ZERO, Err(vec![0xff]));
        vm.mock_call(SEMAPHORE, expected_proof_call(other, GROUP_A, nullifier), U256::ZERO, Err(vec![0xff]));
        vm.mock_call(SEMAPHORE, expected_proof_call(other, GROUP_B, nullifier), U256::ZERO, Err(vec![0xff]));

        ok(do_settle(&mut r, victim, nullifier));
        assert!(r.is_settled(STEALTH, victim));
    }

    #[test]
    fn settle_marks_settled_then_rejects_nullifier_replay() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);

        let nullifier = U256::from(99);
        assert!(!r.is_settled(STEALTH, rid));
        ok(do_settle(&mut r, rid, nullifier));
        assert!(r.is_settled(STEALTH, rid));
        assert!(!r.is_settled(BUYER, rid), "settlement is per stealth address");

        assert!(matches!(
            do_settle(&mut r, rid, nullifier),
            Err(SettlementError::AlreadySettled(_))
        ));
    }

    /// A nullifier burned on one resource must not block settling another — under
    /// Semaphore the nullifier is scoped per (identity, resource), and treating
    /// the set as global would otherwise let one settle poison the rest.
    #[test]
    fn a_nullifier_is_spent_once_across_the_registry() {
        let vm = TestVM::default();
        let (mut r, rid_a) = with_resource(&vm);
        mock_group(&vm, GROUP_B);
        vm.set_sender(OWNER);
        let rid_b = created(r.create_resource(UID2, U256::from(PRICE), String::new()));

        let nullifier = U256::from(99);
        ok(do_settle(&mut r, rid_a, nullifier));
        // Same nullifier, different resource: Semaphore cannot produce this (the
        // scope differs), so seeing it means a forgery — reject it.
        assert!(matches!(
            do_settle(&mut r, rid_b, nullifier),
            Err(SettlementError::AlreadySettled(_))
        ));
        // A distinct nullifier settles normally.
        ok(do_settle(&mut r, rid_b, U256::from(100)));
        assert!(r.is_settled(STEALTH, rid_b));
    }

    #[test]
    fn settle_propagates_hook_failure() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);
        vm.set_sender(OWNER);
        ok(r.register_hook(rid, HOOK));

        let nullifier = U256::from(99);
        vm.mock_call(HOOK, sel_after_settle(rid, nullifier, U256::from(7), &[]), U256::ZERO, Err(vec![0xff]));
        assert!(matches!(do_settle(&mut r, rid, nullifier), Err(SettlementError::HookFailed(_))));
    }

    #[test]
    fn settle_runs_registered_hook() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);
        vm.set_sender(OWNER);
        ok(r.register_hook(rid, HOOK));
        ok(do_settle(&mut r, rid, U256::from(99)));
        assert!(r.is_settled(STEALTH, rid));
    }

    // ── takedown ─────────────────────────────────────────────────────────────

    #[test]
    fn owner_can_disable_and_reenable() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);

        vm.set_sender(OWNER);
        ok(r.set_disabled(rid, true));
        assert!(r.is_disabled(rid));

        vm.set_sender(BUYER);
        assert!(matches!(
            do_register(&mut r, rid, U256::from(42), U256::from(PRICE)),
            Err(SettlementError::ResourceIsDisabled(_))
        ));
        assert!(matches!(
            do_settle(&mut r, rid, U256::from(99)),
            Err(SettlementError::ResourceIsDisabled(_))
        ));

        vm.set_sender(OWNER);
        ok(r.set_disabled(rid, false));
        assert!(!r.is_disabled(rid));
        vm.set_sender(BUYER);
        ok(do_register(&mut r, rid, U256::from(42), U256::from(PRICE)));
    }

    #[test]
    fn admin_can_disable_any_resource() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);
        vm.set_sender(ADMIN);
        ok(r.set_disabled(rid, true));
        assert!(r.is_disabled(rid));
    }

    #[test]
    fn stranger_cannot_disable() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);
        for who in [STRANGER, BUYER, ATTACKER] {
            vm.set_sender(who);
            assert!(matches!(r.set_disabled(rid, true), Err(SettlementError::NotResourceOwner(_))));
        }
        assert!(!r.is_disabled(rid));
    }

    /// With no admin configured, nobody but the owner can take a resource down —
    /// and a zero-address caller must not slip through the admin check.
    #[test]
    fn a_registry_without_an_admin_has_no_takedown_authority() {
        let vm = TestVM::default();
        let mut r = SettlementRegistry::from(&vm);
        ok(r.init(USDC, SEMAPHORE, Address::ZERO));
        mock_group(&vm, GROUP_A);
        vm.set_sender(OWNER);
        let rid = created(r.create_resource(UID, U256::from(PRICE), String::new()));

        vm.set_sender(Address::ZERO);
        assert!(matches!(r.set_disabled(rid, true), Err(SettlementError::NotResourceOwner(_))));

        vm.set_sender(OWNER);
        ok(r.set_disabled(rid, true));
        assert!(r.is_disabled(rid));
    }

    #[test]
    fn disabling_does_not_revoke_an_existing_settlement() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);
        ok(do_settle(&mut r, rid, U256::from(99)));

        vm.set_sender(ADMIN);
        ok(r.set_disabled(rid, true));

        // A settlement already made is a historical fact. Stopping the buyer from
        // fetching the bytes is the access gate's job, not the chain's.
        assert!(r.is_settled(STEALTH, rid));
    }

    #[test]
    fn set_disabled_fails_if_not_found() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        vm.set_sender(ADMIN);
        assert!(matches!(
            r.set_disabled(resource_id_of(OWNER, UID), true),
            Err(SettlementError::ResourceNotFound(_))
        ));
    }

    // ── price / hooks / misc ─────────────────────────────────────────────────

    #[test]
    fn update_price_owner_only() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);

        for who in [STRANGER, ADMIN, BUYER] {
            vm.set_sender(who);
            assert!(matches!(r.update_price(rid, U256::from(5)), Err(SettlementError::NotResourceOwner(_))));
        }
        assert_eq!(r.get_price(rid), U256::from(PRICE));

        vm.set_sender(OWNER);
        ok(r.update_price(rid, U256::from(5)));
        assert_eq!(r.get_price(rid), U256::from(5));
    }

    /// A price change takes effect immediately, so an authorization signed for the
    /// old price reverts rather than under- or over-paying.
    #[test]
    fn a_reprice_invalidates_an_in_flight_authorization() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);
        vm.set_sender(OWNER);
        ok(r.update_price(rid, U256::from(PRICE * 2)));

        vm.set_sender(BUYER);
        assert!(matches!(
            do_register(&mut r, rid, U256::from(42), U256::from(PRICE)),
            Err(SettlementError::IncorrectPaymentAmount(_))
        ));
        ok(do_register(&mut r, rid, U256::from(42), U256::from(PRICE * 2)));
    }

    #[test]
    fn update_price_fails_if_not_found() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        vm.set_sender(OWNER);
        assert!(matches!(
            r.update_price(resource_id_of(OWNER, UID), U256::from(500)),
            Err(SettlementError::ResourceNotFound(_))
        ));
    }

    #[test]
    fn register_hook_owner_only() {
        let vm = TestVM::default();
        let (mut r, rid) = with_resource(&vm);
        vm.set_sender(STRANGER);
        assert!(matches!(r.register_hook(rid, HOOK), Err(SettlementError::NotResourceOwner(_))));
        vm.set_sender(OWNER);
        ok(r.register_hook(rid, HOOK));
    }

    #[test]
    fn register_hook_fails_if_not_found() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        vm.set_sender(OWNER);
        assert!(matches!(
            r.register_hook(resource_id_of(OWNER, UID), HOOK),
            Err(SettlementError::ResourceNotFound(_))
        ));
    }

    #[test]
    fn unknown_resource_reads_are_zero() {
        let vm = TestVM::default();
        let r = new_registry(&vm);
        let rid = resource_id_of(OWNER, UID);
        assert_eq!(r.get_owner(rid), Address::ZERO);
        assert_eq!(r.get_price(rid), U256::ZERO);
        assert_eq!(r.get_uri(rid), String::new());
        assert_eq!(r.get_group_id(rid), U256::ZERO);
        assert!(!r.is_disabled(rid));
        assert!(!r.is_settled(STEALTH, rid));
        assert!(!r.is_registered(rid, U256::from(1)));
    }
}
