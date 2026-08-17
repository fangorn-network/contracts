//! DataRegistry
//!
//! The DataRegistry handles: 
//! - per-app publisher registration
//! -  enforces cryptographically secure, linear timeline state updates (Compare-and-Swap) for all multi-tenant namespaces.
//!
//! Namespaces are hierarchical: `app_id:publisher:subspace_id`
//! flattened on-chain using keccak256(app_id ‖ publisher ‖ subspace_id)

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
    error NotRegisteredForApp();

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
    NotRegisteredForApp(NotRegisteredForApp),
}

impl fmt::Debug for RegistryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "RegistryError")
    }
}

// Explicit status mappings
const STATUS_UNREGISTERED: u8 = 0;
const STATUS_ACTIVE: u8 = 1;
const STATUS_SUSPENDED: u8 = 2;

sol_interface! {
    interface IAppRegistry {
        function isRegisteredForApp(bytes32 app_id, address publisher) external view returns (bool);
    }
}

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
    /// The AppRegistry consulted for app existence and per-app publisher membership.
    app_registry: StorageAddress,
    /// Canonical state timeline heads keyed by composite namespace hash:
    /// keccak256(app_id ‖ publisher ‖ subspace_id) => latest valid PailRootCID bytes
    namespace_heads: StorageMap<FixedBytes<32>, StorageFixedBytes<32>>,
}

#[public]
impl DataRegistry {
    #[constructor]
    pub fn init(&mut self, admin: Address, registration_fee: U256, app_registry: Address) {
        self.admin.set(admin);
        self.registration_fee.set(registration_fee);
        self.app_registry.set(app_registry);
    }

    /// Register as a new data publisher or reactivate a suspended registration on the network.
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
    /// Enforces linear timeline execution (Compare-And-Swap) over `app_id:sender:subspace_id`.
    /// TODO: needs a merkle proof?
    pub fn commit_state_root(
        &mut self,
        app_id: FixedBytes<32>,
        subspace_id: FixedBytes<32>,
        old_root: FixedBytes<32>,
        new_root: FixedBytes<32>,
    ) -> Result<(), RegistryError> {
        let sender = self.vm().msg_sender();
        let current_status = self.statuses.get(sender);
        
        // must be an active publisher
        if current_status == STATUS_UNREGISTERED {
            return Err(RegistryError::NotRegistered(NotRegistered {}));
        }
        if current_status == STATUS_SUSPENDED {
            return Err(RegistryError::PublisherSuspendedErr(PublisherSuspendedErr {}));
        }

        // fail if not an active publisher
        let registry = IAppRegistry::new(self.app_registry.get());
        if !registry.is_registered_for_app(self.vm(), Call::new(), app_id, sender).unwrap_or(false) {
            return Err(RegistryError::NotRegisteredForApp(NotRegisteredForApp {}));
        }

        // validate linear sequence progress for this subspace only
        let ns_key = namespace_key(app_id, sender, subspace_id);
        if self.namespace_heads.get(ns_key) != old_root {
            return Err(RegistryError::StaleStateRoot(StaleStateRoot {}));
        }

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

    /// Get the latest head for a specific publisher's subspace within an application
    pub fn get_namespace_head(
        &self,
        app_id: FixedBytes<32>,
        publisher: Address,
        subspace_id: FixedBytes<32>,
    ) -> FixedBytes<32> {
        self.namespace_heads.get(namespace_key(app_id, publisher, subspace_id))
    }

    pub fn app_registry(&self) -> Address {
        self.app_registry.get()
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

    pub fn set_app_registry(&mut self, registry: Address) -> Result<(), RegistryError> {
        self.only_admin()?;
        self.app_registry.set(registry);
        Ok(())
    }

    /// Restore one namespace head after a redeploy.
    /// This is for assisting in migration to a new version of the data registry contract
    pub fn seed_namespace_head(
        &mut self,
        app_id: FixedBytes<32>,
        publisher: Address,
        subspace_id: FixedBytes<32>,
        root: FixedBytes<32>,
    ) -> Result<(), RegistryError> {
        self.only_admin()?;
        let ns_key = namespace_key(app_id, publisher, subspace_id);
        if self.namespace_heads.get(ns_key) != FixedBytes::ZERO {
            return Err(RegistryError::StaleStateRoot(StaleStateRoot {}));
        }
        self.namespace_heads.setter(ns_key).set(root);
        self.vm().log(StateCommitted {
            namespace_key: ns_key,
            app_id,
            publisher,
            subspace_id,
            old_root: FixedBytes::ZERO,
            new_root: root,
        });
        Ok(())
    }

    pub fn set_registration_fee(&mut self, fee: U256) -> Result<(), RegistryError> {
        self.only_admin()?;
        self.registration_fee.set(fee);
        self.vm().log(RegistrationFeeChanged { fee });
        Ok(())
    }
}

/// keccak256(app_id ‖ publisher ‖ subspace_id)
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

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_sol_types::{sol, SolCall};
    use stylus_sdk::alloy_primitives::{address, hex};
    use stylus_sdk::testing::TestVM;

    // Local ABI defs used only to build the exact calldata TestVM matches on.
    sol! {
        function isRegisteredForApp(bytes32 app_id, address publisher) external view returns (bool);
    }

    const ADMIN_ADDR: Address = address!("1111111111111111111111111111111111111111");
    const PUB_ADDR: Address = address!("2222222222222222222222222222222222222222");
    const FEE_AMT: u64 = 1_000_000_000_000_000_000; // 1 native token
    const APP_ID: FixedBytes<32> = FixedBytes([1u8; 32]);
    const SUB_A: FixedBytes<32> = FixedBytes([2u8; 32]);
    const SUB_B: FixedBytes<32> = FixedBytes([3u8; 32]);
    const APP_REGISTRY_ADDR: Address = address!("7777777777777777777777777777777777777777");

    fn bool_word(b: bool) -> Vec<u8> {
        U256::from(b as u64).to_be_bytes::<32>().to_vec()
    }

    /// Mock the AppRegistry's membership view — the only cross-call commit makes.
    fn mock_member(vm: &TestVM, app_id: FixedBytes<32>, publisher: Address, joined: bool) {
        let data = isRegisteredForAppCall { app_id, publisher }.abi_encode();
        vm.mock_static_call(APP_REGISTRY_ADDR, data, Ok(bool_word(joined)));
    }

    /// An app that exists with PUB_ADDR joined, plus a globally registered publisher.
    fn setup(vm: &TestVM) -> DataRegistry {
        let mut registry = DataRegistry::from(vm);
        registry.init(ADMIN_ADDR, U256::from(FEE_AMT), APP_REGISTRY_ADDR);

        mock_member(vm, APP_ID, PUB_ADDR, true);

        vm.set_sender(PUB_ADDR);
        vm.set_value(U256::from(FEE_AMT));
        registry.register().unwrap();
        registry
    }

    #[test]
    fn test_initialization() {
        let vm = TestVM::default();
        let mut registry = DataRegistry::from(&vm);
        registry.init(ADMIN_ADDR, U256::from(FEE_AMT), APP_REGISTRY_ADDR);

        assert_eq!(registry.admin(), ADMIN_ADDR);
        assert_eq!(registry.registration_fee(), U256::from(FEE_AMT));
        assert_eq!(registry.publisher_count(), 0);
    }

    #[test]
    fn test_failed_registration_insufficient_fee() {
        let vm = TestVM::default();
        let mut registry = DataRegistry::from(&vm);
        registry.init(ADMIN_ADDR, U256::from(FEE_AMT), APP_REGISTRY_ADDR);

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
        registry.init(ADMIN_ADDR, U256::from(FEE_AMT), APP_REGISTRY_ADDR);

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
        registry.init(ADMIN_ADDR, U256::from(FEE_AMT), APP_REGISTRY_ADDR);

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


    /// The check this contract did not used to make. A globally registered
    /// publisher who never joined the app must not be able to write under it —
    /// previously the app merely had to EXIST, so every app was open to everyone.
    ///
    /// This also covers the old `test_unknown_app_rejected` case: an app nobody
    /// claimed is an app nobody joined, and both now take the same branch.
    #[test]
    fn test_publisher_not_registered_for_app_rejected() {
        // Built from scratch rather than on `setup`: TestVM resolves mocks in
        // registration order per address, so a second mock added later for the same
        // contract does not reliably win. Every mock this test needs is registered
        // before the first call.
        let vm = TestVM::default();
        let mut registry = DataRegistry::from(&vm);
        registry.init(ADMIN_ADDR, U256::from(FEE_AMT), APP_REGISTRY_ADDR);

        // The app exists and is owned, but PUB_ADDR never joined it.
        mock_member(&vm, APP_ID, PUB_ADDR, false);

        vm.set_sender(PUB_ADDR);
        vm.set_value(U256::from(FEE_AMT));
        registry.register().unwrap(); // globally registered — and still not enough

        let res = registry.commit_state_root(APP_ID, SUB_A, FixedBytes::ZERO, FixedBytes([7u8; 32]));
        assert!(
            matches!(res, Err(RegistryError::NotRegisteredForApp(_))),
            "an app this publisher never joined accepted their commit",
        );
    }

    /// A missing head can be restored once; a live one can never be rewritten.

    #[test]
    fn test_seed_namespace_head_is_fill_only() {
        let vm = TestVM::default();
        let mut registry = setup(&vm);
        let root = FixedBytes([9u8; 32]);

        vm.set_sender(PUB_ADDR);
        assert!(registry.seed_namespace_head(APP_ID, PUB_ADDR, SUB_A, root).is_err(), "a non-admin seeded a head");

        vm.set_sender(ADMIN_ADDR);
        registry.seed_namespace_head(APP_ID, PUB_ADDR, SUB_A, root).unwrap();
        assert_eq!(registry.get_namespace_head(APP_ID, PUB_ADDR, SUB_A), root);

        assert!(
            registry.seed_namespace_head(APP_ID, PUB_ADDR, SUB_A, FixedBytes([8u8; 32])).is_err(),
            "the migration lever overwrote a live timeline — that is a backdoor, not a migration",
        );
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
