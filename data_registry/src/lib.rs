//! DataRegistry
//!
//! This single contract handles publisher registration and enforces cryptographically
//! secure, linear timeline state updates (Compare-and-Swap) for all multi-tenant namespaces.
//! All schemas, data sources, and indices live off-chain within the Pail Merkle Trie structure.
//!
//! Namespaces are hierarchical: `app_id:publisher:subspace_id`, flattened on-chain into
//! keccak256(app_id ‖ publisher ‖ subspace_id). Callers hash human-readable path segments
//! client-side; no dynamic strings ever touch storage.

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![cfg_attr(feature = "contract-client-gen", allow(unused_imports))]
extern crate alloc;

use alloc::fmt;
use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{keccak256, Address, FixedBytes, U256, U64, U8},
    prelude::*,
    storage::*,
};

sol! {
    error AlreadyRegistered();
    error NotRegistered();
    error RegistrationFeeRequired();
    error Unauthorized();
    error StaleStateRoot();
    error PublisherSuspendedErr();
    error AppAlreadyRegistered();
    error AppNotFound();

    event AppRegistered(
        bytes32 indexed app_id,
        address indexed owner
    );

    event PublisherRegistered(
        address indexed publisher,
        bytes32 initial_root
    );

    event PublisherReactivated(
        address indexed publisher,
        bytes32 current_root
    );

    event PublisherSuspended(
        address indexed publisher
    );

    event RegistrationFeeChanged(uint256 fee);
    
    event StateCommitted(
        bytes32 indexed namespace_key,
        bytes32 indexed app_id,
        address indexed publisher,
        bytes32 subspace_id,
        bytes32 old_root,
        bytes32 new_root
    );
}

#[derive(SolidityError)]
pub enum RegistryError {
    AlreadyRegistered(AlreadyRegistered),
    NotRegistered(NotRegistered),
    RegistrationFeeRequired(RegistrationFeeRequired),
    Unauthorized(Unauthorized),
    StaleStateRoot(StaleStateRoot),
    PublisherSuspendedErr(PublisherSuspendedErr),
    AppAlreadyRegistered(AppAlreadyRegistered),
    AppNotFound(AppNotFound),
}

impl fmt::Debug for RegistryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "RegistryError")
    }
}

// Explicit status mappings for the internal state machine
const STATUS_UNREGISTERED: u8 = 0;
const STATUS_ACTIVE: u8 = 1;
const STATUS_SUSPENDED: u8 = 2;

#[storage]
#[entrypoint]
pub struct DataRegistry {
    /// Protocol admin.
    admin: StorageAddress,
    /// Registration fee (in native chain token or $FANG).
    registration_fee: StorageU256,
    /// Tracks registration state machine lifecycle: publisher => status code
    statuses: StorageMap<Address, StorageU8>,
    /// Number of active global publishers
    publisher_count: StorageU64,
    /// Registered app namespaces: app_id => app owner address
    apps: StorageMap<FixedBytes<32>, StorageAddress>,
    /// Canonical state timeline heads keyed by composite namespace hash:
    /// keccak256(app_id ‖ publisher ‖ subspace_id) => latest valid PailRootCID bytes
    namespace_heads: StorageMap<FixedBytes<32>, StorageFixedBytes<32>>,
}

#[public]
impl DataRegistry {
    #[constructor]
    pub fn init(&mut self, admin: Address, registration_fee: U256) {
        self.admin.set(admin);
        self.registration_fee.set(registration_fee);
    }

    /// Register a root application namespace (e.g. keccak256("app_name")). First come, first served.
    pub fn register_app(&mut self, app_id: FixedBytes<32>) -> Result<(), RegistryError> {
        let sender = self.vm().msg_sender();
        if self.apps.get(app_id) != Address::ZERO {
            return Err(RegistryError::AppAlreadyRegistered(AppAlreadyRegistered {}));
        }

        self.apps.setter(app_id).set(sender);
        self.vm().log(AppRegistered {
            app_id,
            owner: sender,
        });

        Ok(())
    }

    /// Register as a new data publisher or reactivate a suspended registration on the network.
    /// Allocates or unfreezes an isolated cryptographic namespace tracking slot.
    #[payable]
    pub fn register(&mut self) -> Result<(), RegistryError> {
        let sender = self.vm().msg_sender();
        let current_status = self.statuses.get(sender);

        if current_status == STATUS_ACTIVE {
            return Err(RegistryError::AlreadyRegistered(AlreadyRegistered {}));
        }
        if self.vm().msg_value() < self.registration_fee.get() {
            return Err(RegistryError::RegistrationFeeRequired(RegistrationFeeRequired {}));
        }

        // Advance lifecycle state to Active
        self.statuses.setter(sender).set(U8::from(STATUS_ACTIVE));
        self.publisher_count.set(self.publisher_count.get() + U64::from(1));

        if current_status == STATUS_SUSPENDED {
            // Suspension never clears namespace heads, so every timeline resumes where it left off.
            self.vm().log(PublisherReactivated {
                publisher: sender,
                current_root: FixedBytes::ZERO,
            });
        } else {
            self.vm().log(PublisherRegistered {
                publisher: sender,
                initial_root: FixedBytes::ZERO,
            });
        }

        Ok(())
    }

    /// Mutating State Transition Gateway
    ///
    /// The only state-modifying route needed for data ingestion, schema registration, or deletion.
    /// Enforces linear timeline execution (Compare-And-Swap) over `app_id:sender:subspace_id`.
    /// TODO: needs a merkle proof
    pub fn commit_state_root(
        &mut self,
        app_id: FixedBytes<32>,
        subspace_id: FixedBytes<32>,
        old_root: FixedBytes<32>,
        new_root: FixedBytes<32>,
    ) -> Result<(), RegistryError> {
        let sender = self.vm().msg_sender();
        let current_status = self.statuses.get(sender);
        
        // 1. Authenticate identity and lifecycle constraints
        if current_status == STATUS_UNREGISTERED {
            return Err(RegistryError::NotRegistered(NotRegistered {}));
        }
        if current_status == STATUS_SUSPENDED {
            return Err(RegistryError::PublisherSuspendedErr(PublisherSuspendedErr {}));
        }
        
        // 2. Ensure the application namespace exists
        if self.apps.get(app_id) == Address::ZERO {
            return Err(RegistryError::AppNotFound(AppNotFound {}));
        }

        // 3. Validate linear sequence progress for this subspace only
        let ns_key = namespace_key(app_id, sender, subspace_id);
        if self.namespace_heads.get(ns_key) != old_root {
            return Err(RegistryError::StaleStateRoot(StaleStateRoot {}));
        }

        // 4. Persist the state change
        self.namespace_heads.setter(ns_key).set(new_root);

        self.vm().log(StateCommitted {
            namespace_key: ns_key,
            app_id,
            publisher: sender,
            subspace_id,
            old_root,
            new_root,
        });

        Ok(())
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    /// Read-route for indexing nodes and data consumers to obtain the latest state map reference.
    pub fn get_namespace_head(
        &self,
        app_id: FixedBytes<32>,
        publisher: Address,
        subspace_id: FixedBytes<32>,
    ) -> FixedBytes<32> {
        self.namespace_heads.get(namespace_key(app_id, publisher, subspace_id))
    }

    pub fn get_app_owner(&self, app_id: FixedBytes<32>) -> Address {
        self.apps.get(app_id)
    }

    pub fn get_publisher_status(&self, publisher: Address) -> u8 {
            self.statuses.get(publisher).to::<u8>()
    }

    pub fn is_registered(&self, publisher: Address) -> bool {
        self.statuses.get(publisher) == STATUS_ACTIVE
    }

    pub fn publisher_count(&self) -> u64 {
        self.publisher_count.get().to::<u64>()
    }

    pub fn registration_fee(&self) -> U256 {
        self.registration_fee.get()
    }

    pub fn admin(&self) -> Address {
        self.admin.get()
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    /// Allows governance/admin to forcefully suspend a malicious or decommissioned publisher.
    pub fn suspend_publisher(&mut self, publisher: Address) -> Result<(), RegistryError> {
        self.only_admin()?;
        
        if self.statuses.get(publisher) != STATUS_ACTIVE {
            return Err(RegistryError::NotRegistered(NotRegistered {}));
        }

        self.statuses.setter(publisher).set(U8::from(STATUS_SUSPENDED));
        
        let count = self.publisher_count.get().to::<u64>();
        if count > 0 {
            self.publisher_count.set(U64::from(count - 1));
        }

        self.vm().log(PublisherSuspended { publisher });
        Ok(())
    }

    pub fn set_registration_fee(&mut self, fee: U256) -> Result<(), RegistryError> {
        self.only_admin()?;
        self.registration_fee.set(fee);
        self.vm().log(RegistrationFeeChanged { fee });
        Ok(())
    }
}

/// keccak256(app_id ‖ publisher ‖ subspace_id) — the flattened hierarchical namespace slot.
fn namespace_key(
    app_id: FixedBytes<32>,
    publisher: Address,
    subspace_id: FixedBytes<32>,
) -> FixedBytes<32> {
    let mut bytes = [0u8; 84]; // 32 app_id + 20 address + 32 subspace_id
    bytes[0..32].copy_from_slice(app_id.as_slice());
    bytes[32..52].copy_from_slice(publisher.as_slice());
    bytes[52..84].copy_from_slice(subspace_id.as_slice());
    keccak256(bytes)
}

impl DataRegistry {
    fn only_admin(&self) -> Result<(), RegistryError> {
        if self.vm().msg_sender() != self.admin.get() {
            return Err(RegistryError::Unauthorized(Unauthorized {}));
        }
        Ok(())
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use stylus_sdk::alloy_primitives::{address, hex};
    use stylus_sdk::testing::TestVM;

    const ADMIN_ADDR: Address = address!("1111111111111111111111111111111111111111");
    const PUB_ADDR: Address = address!("2222222222222222222222222222222222222222");
    const FEE_AMT: u64 = 1_000_000_000_000_000_000; // 1 native token
    const APP_ID: FixedBytes<32> = FixedBytes([1u8; 32]);
    const SUB_A: FixedBytes<32> = FixedBytes([2u8; 32]);
    const SUB_B: FixedBytes<32> = FixedBytes([3u8; 32]);

    /// Registered app + registered, active publisher.
    fn setup(vm: &TestVM) -> DataRegistry {
        let mut registry = DataRegistry::from(vm);
        registry.init(ADMIN_ADDR, U256::from(FEE_AMT));

        vm.set_sender(ADMIN_ADDR);
        registry.register_app(APP_ID).unwrap();

        vm.set_sender(PUB_ADDR);
        vm.set_value(U256::from(FEE_AMT));
        registry.register().unwrap();
        registry
    }

    #[test]
    fn test_initialization() {
        let vm = TestVM::default();
        let mut registry = DataRegistry::from(&vm);
        registry.init(ADMIN_ADDR, U256::from(FEE_AMT));

        assert_eq!(registry.admin(), ADMIN_ADDR);
        assert_eq!(registry.registration_fee(), U256::from(FEE_AMT));
        assert_eq!(registry.publisher_count(), 0);
    }

    #[test]
    fn test_failed_registration_insufficient_fee() {
        let vm = TestVM::default();
        let mut registry = DataRegistry::from(&vm);
        registry.init(ADMIN_ADDR, U256::from(FEE_AMT));

        // Use TestVM setters to modify the context state dynamically
        vm.set_sender(PUB_ADDR);
        vm.set_value(U256::ZERO);

        let result = registry.register();
        assert!(matches!(result, Err(RegistryError::RegistrationFeeRequired(_))));
    }

    #[test]
    fn test_successful_registration_and_duplicate_prevention() {
        let vm = TestVM::default();
        let mut registry = DataRegistry::from(&vm);
        registry.init(ADMIN_ADDR, U256::from(FEE_AMT));

        vm.set_sender(PUB_ADDR);
        vm.set_value(U256::from(FEE_AMT));

        assert!(registry.register().is_ok());
        assert!(registry.is_registered(PUB_ADDR));
        assert_eq!(registry.get_publisher_status(PUB_ADDR), STATUS_ACTIVE);
        assert_eq!(registry.publisher_count(), 1);

        // Disallow immediate duplicate registration updates
        let duplicate_result = registry.register();
        assert!(matches!(duplicate_result, Err(RegistryError::AlreadyRegistered(_))));
    }

    #[test]
    fn test_admin_suspension_flow() {
        let vm = TestVM::default();
        let mut registry = DataRegistry::from(&vm);
        registry.init(ADMIN_ADDR, U256::from(FEE_AMT));

        // Register publisher
        vm.set_sender(PUB_ADDR);
        vm.set_value(U256::from(FEE_AMT));
        registry.register().unwrap();
        assert_eq!(registry.publisher_count(), 1);

        // Admin execution of suspension policy
        vm.set_sender(ADMIN_ADDR);
        assert!(registry.suspend_publisher(PUB_ADDR).is_ok());
        assert_eq!(registry.get_publisher_status(PUB_ADDR), STATUS_SUSPENDED);
        assert_eq!(registry.publisher_count(), 0);
        assert!(!registry.is_registered(PUB_ADDR));
    }

    #[test]
    fn test_suspended_publisher_cannot_commit() {
        let vm = TestVM::default();
        let mut registry = setup(&vm);

        vm.set_sender(ADMIN_ADDR);
        registry.suspend_publisher(PUB_ADDR).unwrap();

        // Ensure state commits fail under suspended state status bounds
        vm.set_sender(PUB_ADDR);
        let commit_res =
            registry.commit_state_root(APP_ID, SUB_A, FixedBytes::ZERO, FixedBytes([7u8; 32]));
        assert!(matches!(commit_res, Err(RegistryError::PublisherSuspendedErr(_))));
    }

    /// Golden fixture shared with the SDK (`namespace-key.test.ts`). The client
    /// derives this key to filter events and to address heads; if the two
    /// derivations ever diverge, every read silently returns a zero root instead
    /// of failing, so both sides pin the same constant.
    #[test]
    fn test_namespace_key_matches_sdk_fixture() {
        // keccak256("fangorn"), keccak256("docs")
        let app_id = FixedBytes(hex!(
            "e9cb5c7e3e8fb962393e314a9387731152c9b2e3cfb1fcbfe79c0c3038b2ed37"
        ));
        let subspace_id = FixedBytes(hex!(
            "6bf9054545420e9e9f4aa4f353a32c7d0d52c11dbcdda56c53be8375cafeebb1"
        ));

        assert_eq!(
            namespace_key(app_id, PUB_ADDR, subspace_id),
            FixedBytes(hex!(
                "cfde128f9c8e22771b4caeabe644f7abd0c1d1c50e27562b263934f9279ad3ca"
            ))
        );
    }

    #[test]
    fn test_unknown_app_rejected() {
        let vm = TestVM::default();
        let mut registry = setup(&vm);

        let res = registry.commit_state_root(
            FixedBytes([0xAAu8; 32]),
            SUB_A,
            FixedBytes::ZERO,
            FixedBytes([7u8; 32]),
        );
        assert!(matches!(res, Err(RegistryError::AppNotFound(_))));
    }

    #[test]
    fn test_app_registration_is_exclusive() {
        let vm = TestVM::default();
        let mut registry = setup(&vm);

        assert_eq!(registry.get_app_owner(APP_ID), ADMIN_ADDR);
        // PUB_ADDR is still the sender after setup
        assert!(matches!(
            registry.register_app(APP_ID),
            Err(RegistryError::AppAlreadyRegistered(_))
        ));
    }

    #[test]
    fn test_subspaces_have_isolated_timelines() {
        let vm = TestVM::default();
        let mut registry = setup(&vm);

        let root_a = FixedBytes([5u8; 32]);
        registry
            .commit_state_root(APP_ID, SUB_A, FixedBytes::ZERO, root_a)
            .unwrap();

        // SUB_B is untouched and still starts from zero
        assert_eq!(registry.get_namespace_head(APP_ID, PUB_ADDR, SUB_B), FixedBytes::ZERO);
        let root_b = FixedBytes([6u8; 32]);
        registry
            .commit_state_root(APP_ID, SUB_B, FixedBytes::ZERO, root_b)
            .unwrap();

        assert_eq!(registry.get_namespace_head(APP_ID, PUB_ADDR, SUB_A), root_a);
        assert_eq!(registry.get_namespace_head(APP_ID, PUB_ADDR, SUB_B), root_b);
    }

    #[test]
    fn test_reactivation_retains_timeline_history() {
        let vm = TestVM::default();
        let mut registry = setup(&vm);

        let root_a = FixedBytes([5u8; 32]);
        registry
            .commit_state_root(APP_ID, SUB_A, FixedBytes::ZERO, root_a)
            .unwrap();

        // 2. Suspension event triggering execution sequence bounds 
        vm.set_sender(ADMIN_ADDR);
        registry.suspend_publisher(PUB_ADDR).unwrap();

        // 3. Re-registration processing loop verification triggers
        vm.set_sender(PUB_ADDR);
        vm.set_value(U256::from(FEE_AMT));
        assert!(registry.register().is_ok());
        
        assert_eq!(registry.get_publisher_status(PUB_ADDR), STATUS_ACTIVE);
        assert_eq!(registry.publisher_count(), 1);
        // Assert historical root state remains perfectly unaffected across suspensions
        assert_eq!(registry.get_namespace_head(APP_ID, PUB_ADDR, SUB_A), root_a);

        // 4. Ensure CAS logic continues perfectly from historical state anchors
        let root_b = FixedBytes([9u8; 32]);
        assert!(registry.commit_state_root(APP_ID, SUB_A, root_a, root_b).is_ok());
        assert_eq!(registry.get_namespace_head(APP_ID, PUB_ADDR, SUB_A), root_b);
    }

    #[test]
    fn test_stale_state_root_rejection() {
        let vm = TestVM::default();
        let mut registry = setup(&vm);

        let root_a = FixedBytes([1u8; 32]);
        let root_b = FixedBytes([2u8; 32]);

        let bad_commit = registry.commit_state_root(APP_ID, SUB_A, root_a, root_b);
        assert!(matches!(bad_commit, Err(RegistryError::StaleStateRoot(_))));
    }
}