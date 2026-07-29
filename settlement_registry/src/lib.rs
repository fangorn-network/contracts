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

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::{address, b256, hex_literal::hex};

    #[test]
    fn test_hash_concat() {
        let a = [1u8; 32];
        let b = [2u8; 32];
        let result = hash_concat(&a, &b);

        let expected = keccak256([a.as_slice(), b.as_slice()].concat());
        assert_eq!(result, expected);
    }

    #[test]
    fn test_sel_add_member() {
        let group_id = U256::from(42);
        let commitment = U256::from(999);
        let calldata = sel_add_member(group_id, commitment);

        // keccak256("addMember(uint256,uint256)")[..4] == 0x1783efc3
        let expected_selector = hex!("1783efc3");
        assert_eq!(&calldata[0..4], &expected_selector);

        assert_eq!(U256::from_be_slice(&calldata[4..36]), group_id);
        assert_eq!(U256::from_be_slice(&calldata[36..68]), commitment);
    }

    #[test]
    fn test_sel_after_settle() {
        let resource_id = b256!("1111111111111111111111111111111111111111111111111111111111111111");
        let nullifier = U256::from(12345);
        let message = U256::from(67890);
        let hook_data = vec![0xaa, 0xbb, 0xcc];

        let calldata = sel_after_settle(resource_id, nullifier, message, &hook_data);

        // keccak256("afterSettle(bytes32,uint256,uint256,bytes)")[..4] == 0x71e5eac2
        assert_eq!(&calldata[0..4], &hex!("71e5eac2"));
        assert_eq!(&calldata[4..36], resource_id.as_slice());
        assert_eq!(U256::from_be_slice(&calldata[36..68]), nullifier);
        assert_eq!(U256::from_be_slice(&calldata[68..100]), message);

        // Dynamic offset and array assertions
        assert_eq!(U256::from_be_slice(&calldata[100..132]), U256::from(0x80));
        assert_eq!(U256::from_be_slice(&calldata[132..164]), U256::from(3));
        assert_eq!(&calldata[164..167], hook_data.as_slice());
    }

    #[test]
    fn test_sel_transfer_auth() {
        let from = address!("1111111111111111111111111111111111111111");
        let to = address!("2222222222222222222222222222222222222222");
        let value = U256::from(1000);
        let valid_after = U256::from(0);
        let valid_before = U256::from(9999999999_u64);
        let nonce = b256!("3333333333333333333333333333333333333333333333333333333333333333");
        let v = 27;
        let r = b256!("4444444444444444444444444444444444444444444444444444444444444444");
        let s = b256!("5555555555555555555555555555555555555555555555555555555555555555");

        let calldata = sel_transfer_auth(from, to, value, valid_after, valid_before, nonce, v, r, s);

        // keccak256("transferWithAuthorization(...)")[..4] == 0xe3ee160e
        assert_eq!(&calldata[0..4], &hex!("e3ee160e"));
        assert_eq!(&calldata[16..36], from.as_slice());
        assert_eq!(&calldata[48..68], to.as_slice());
        assert_eq!(U256::from_be_slice(&calldata[68..100]), value);
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
    const OTHER: Address = address!("4444444444444444444444444444444444444444");
    const HOOK: Address = address!("5555555555555555555555555555555555555555");
    const STEALTH: Address = address!("6666666666666666666666666666666666666666");

    const RID: FixedBytes<32> = FixedBytes([0xaa; 32]);
    const PRICE: u64 = 1_000_000; // 1 USDC
    const GROUP_ID: u64 = 7;

    // ponytail: unmocked calls return Ok(empty) in TestVM, so the happy paths need
    // no mocks — only `createGroup` (needs 32 bytes back) and revert paths do.
    fn new_registry(vm: &TestVM) -> SettlementRegistry {
        vm.mock_call(
            SEMAPHORE,
            keccak256(b"createGroup()")[..4].to_vec(),
            U256::ZERO,
            Ok(U256::from(GROUP_ID).to_be_bytes::<32>().to_vec()),
        );
        let mut r = SettlementRegistry::from(vm);
        ok(r.init(USDC, SEMAPHORE));
        r
    }

    /// Registry with RID owned by OWNER at PRICE.
    fn with_resource(vm: &TestVM) -> SettlementRegistry {
        let mut r = new_registry(vm);
        vm.set_sender(OWNER);
        ok(r.create_resource(RID, U256::from(PRICE), String::from("ipfs://x")));
        r
    }

    // ponytail: sol!-generated error structs have no Debug, so `.unwrap()` is out.
    fn ok(r: Result<(), SettlementError>) {
        assert!(r.is_ok(), "expected Ok");
    }

    fn points() -> [U256; 8] {
        core::array::from_fn(|i| U256::from(i as u64))
    }

    #[allow(clippy::too_many_arguments)]
    fn register_args(amount: U256) -> (Address, Address, U256, U256, U256, FixedBytes<32>, u8, FixedBytes<32>, FixedBytes<32>) {
        (OTHER, OWNER, amount, U256::ZERO, U256::from(u64::MAX), FixedBytes([9u8; 32]), 27, FixedBytes([1u8; 32]), FixedBytes([2u8; 32]))
    }

    fn do_register(r: &mut SettlementRegistry, commitment: U256, amount: U256) -> Result<(), SettlementError> {
        let (from, to, amt, va, vb, nonce, v, rr, s) = register_args(amount);
        r.register(RID, commitment, from, to, amt, va, vb, nonce, v, rr, s)
    }

    #[test]
    fn init_stores_group_id_from_semaphore() {
        let vm = TestVM::default();
        let r = new_registry(&vm);
        assert_eq!(r.get_global_group_id(), U256::from(GROUP_ID));
    }

    #[test]
    fn init_fails_on_short_semaphore_return() {
        let vm = TestVM::default();
        vm.mock_call(
            SEMAPHORE,
            keccak256(b"createGroup()")[..4].to_vec(),
            U256::ZERO,
            Ok(vec![0u8; 8]),
        );
        let mut r = SettlementRegistry::from(&vm);
        assert!(matches!(
            r.init(USDC, SEMAPHORE),
            Err(SettlementError::SemaphoreCallFailed(_))
        ));
    }

    #[test]
    fn create_resource_stores_owner_price_uri() {
        let vm = TestVM::default();
        let r = with_resource(&vm);
        assert_eq!(r.get_owner(RID), OWNER);
        assert_eq!(r.get_price(RID), U256::from(PRICE));
        assert_eq!(r.get_uri(RID), String::from("ipfs://x"));
    }

    #[test]
    fn create_resource_rejects_duplicate() {
        let vm = TestVM::default();
        let mut r = with_resource(&vm);
        vm.set_sender(OTHER);
        assert!(matches!(
            r.create_resource(RID, U256::from(1), String::new()),
            Err(SettlementError::AlreadyRegistered(_))
        ));
        // Ownership is unchanged by the failed second call
        assert_eq!(r.get_owner(RID), OWNER);
    }

    #[test]
    fn create_resource_propagates_semaphore_revert() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        let seed = U256::from_be_bytes(*keccak256(RID.as_slice())) % BN254_FIELD_MOD;
        vm.mock_call(
            SEMAPHORE,
            sel_add_member(U256::from(GROUP_ID), seed),
            U256::ZERO,
            Err(vec![0xff]),
        );
        vm.set_sender(OWNER);
        assert!(matches!(
            r.create_resource(RID, U256::from(PRICE), String::new()),
            Err(SettlementError::SemaphoreCallFailed(_))
        ));
    }

    #[test]
    fn update_price_owner_only() {
        let vm = TestVM::default();
        let mut r = with_resource(&vm);

        vm.set_sender(OTHER);
        assert!(matches!(
            r.update_price(RID, U256::from(5)),
            Err(SettlementError::NotResourceOwner(_))
        ));
        assert_eq!(r.get_price(RID), U256::from(PRICE));

        vm.set_sender(OWNER);
        ok(r.update_price(RID, U256::from(5)));
        assert_eq!(r.get_price(RID), U256::from(5));
    }

    #[test]
    fn update_price_fails_if_not_found() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        vm.set_sender(OWNER);
        assert!(matches!(
            r.update_price(RID, U256::from(500)),
            Err(SettlementError::ResourceNotFound(_))
        ));
    }

    #[test]
    fn register_hook_owner_only() {
        let vm = TestVM::default();
        let mut r = with_resource(&vm);

        vm.set_sender(OTHER);
        assert!(matches!(
            r.register_hook(RID, HOOK),
            Err(SettlementError::NotResourceOwner(_))
        ));

        vm.set_sender(OWNER);
        ok(r.register_hook(RID, HOOK));
    }

    #[test]
    fn register_hook_fails_if_not_found() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        vm.set_sender(OWNER);
        assert!(matches!(
            r.register_hook(RID, HOOK),
            Err(SettlementError::ResourceNotFound(_))
        ));
    }

    #[test]
    fn register_requires_existing_resource() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        assert!(matches!(
            do_register(&mut r, U256::from(1), U256::from(PRICE)),
            Err(SettlementError::ResourceNotFound(_))
        ));
    }

    #[test]
    fn register_rejects_wrong_amount() {
        let vm = TestVM::default();
        let mut r = with_resource(&vm);
        vm.set_sender(OTHER);
        assert!(matches!(
            do_register(&mut r, U256::from(1), U256::from(PRICE - 1)),
            Err(SettlementError::IncorrectPaymentAmount(_))
        ));
        assert!(!r.is_registered(RID, U256::from(1)));
    }

    #[test]
    fn register_succeeds_then_rejects_replay() {
        let vm = TestVM::default();
        let mut r = with_resource(&vm);
        vm.set_sender(OTHER);

        let commitment = U256::from(42);
        assert!(!r.is_registered(RID, commitment));
        ok(do_register(&mut r, commitment, U256::from(PRICE)));
        assert!(r.is_registered(RID, commitment));
        // A different commitment on the same resource is still open
        assert!(!r.is_registered(RID, U256::from(43)));

        assert!(matches!(
            do_register(&mut r, commitment, U256::from(PRICE)),
            Err(SettlementError::AlreadyRegistered(_))
        ));
    }

    #[test]
    fn register_propagates_transfer_revert() {
        let vm = TestVM::default();
        let mut r = with_resource(&vm);
        let (from, to, amt, va, vb, nonce, v, rr, s) = register_args(U256::from(PRICE));
        vm.mock_call(
            USDC,
            sel_transfer_auth(from, to, amt, va, vb, nonce, v, rr, s),
            U256::ZERO,
            Err(vec![0xff]),
        );
        vm.set_sender(OTHER);
        assert!(matches!(
            do_register(&mut r, U256::from(42), U256::from(PRICE)),
            Err(SettlementError::TransferFailed(_))
        ));
        // Payment failed, so no registration was recorded
        assert!(!r.is_registered(RID, U256::from(42)));
    }

    fn do_settle(r: &mut SettlementRegistry, nullifier: U256) -> Result<(), SettlementError> {
        r.settle(RID, STEALTH, U256::from(20), U256::from(123), nullifier, U256::from(7), points(), vec![])
    }

    #[test]
    fn settle_requires_existing_resource() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        assert!(matches!(
            do_settle(&mut r, U256::from(1)),
            Err(SettlementError::ResourceNotFound(_))
        ));
    }

    #[test]
    fn settle_marks_settled_then_rejects_replay() {
        let vm = TestVM::default();
        let mut r = with_resource(&vm);

        let nullifier = U256::from(99);
        assert!(!r.is_settled(STEALTH, RID));
        ok(do_settle(&mut r, nullifier));
        assert!(r.is_settled(STEALTH, RID));
        // Settlement is keyed per stealth address
        assert!(!r.is_settled(OTHER, RID));

        assert!(matches!(
            do_settle(&mut r, nullifier),
            Err(SettlementError::AlreadySettled(_))
        ));
    }

    #[test]
    fn settle_propagates_proof_failure() {
        let vm = TestVM::default();
        let mut r = with_resource(&vm);
        let nullifier = U256::from(99);
        vm.mock_call(
            SEMAPHORE,
            sel_validate_proof(
                U256::from(GROUP_ID),
                U256::from(20),
                U256::from(123),
                nullifier,
                U256::from(7),
                U256::from_be_bytes(*RID),
                &points(),
            ),
            U256::ZERO,
            Err(vec![0xff]),
        );
        assert!(matches!(
            do_settle(&mut r, nullifier),
            Err(SettlementError::VerificationFailed(_))
        ));
        assert!(!r.is_settled(STEALTH, RID));
    }

    #[test]
    fn settle_propagates_hook_failure() {
        let vm = TestVM::default();
        let mut r = with_resource(&vm);
        vm.set_sender(OWNER);
        ok(r.register_hook(RID, HOOK));

        let nullifier = U256::from(99);
        vm.mock_call(
            HOOK,
            sel_after_settle(RID, nullifier, U256::from(7), &[]),
            U256::ZERO,
            Err(vec![0xff]),
        );
        assert!(matches!(
            do_settle(&mut r, nullifier),
            Err(SettlementError::HookFailed(_))
        ));
    }

    #[test]
    fn settle_runs_registered_hook() {
        let vm = TestVM::default();
        let mut r = with_resource(&vm);
        vm.set_sender(OWNER);
        ok(r.register_hook(RID, HOOK));
        ok(do_settle(&mut r, U256::from(99)));
        assert!(r.is_settled(STEALTH, RID));
    }

    #[test]
    fn unknown_resource_reads_are_zero() {
        let vm = TestVM::default();
        let r = new_registry(&vm);
        assert_eq!(r.get_owner(RID), Address::ZERO);
        assert_eq!(r.get_price(RID), U256::ZERO);
        assert_eq!(r.get_uri(RID), String::new());
        assert!(!r.is_settled(STEALTH, RID));
        assert!(!r.is_registered(RID, U256::from(1)));
    }
}