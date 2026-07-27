//! DataRegistry — The unified, zero-proxy data network engine.
//!
//! This single contract handles publisher registration and enforces cryptographically 
//! secure, linear timeline state updates (Compare-and-Swap) for all multi-tenant namespaces.
//! All schemas, data sources, and indices live off-chain within the Pail Merkle Trie structure.

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![cfg_attr(feature = "contract-client-gen", allow(unused_imports))]
extern crate alloc;

use alloc::fmt;
use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{Address, FixedBytes, U256, U64, U8},
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
        address indexed publisher,
        bytes32 indexed old_root,
        bytes32 indexed new_root
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
    /// The canonical state timeline anchor tracking: publisher => latest valid PailRootCID bytes
    namespace_heads: StorageMap<Address, StorageFixedBytes<32>>,
}

#[public]
impl DataRegistry {
    #[constructor]
    pub fn init(&mut self, admin: Address, registration_fee: U256) {
        self.admin.set(admin);
        self.registration_fee.set(registration_fee);
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
            // Reactivation preserves the historic timeline root reference
            let current_root = self.namespace_heads.get(sender);
            self.vm().log(PublisherReactivated {
                publisher: sender,
                current_root,
            });
        } else {
            // Fresh registrations initialize a clean root tracking state
            self.namespace_heads.setter(sender).set(FixedBytes::ZERO);
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
    /// Enforces linear timeline execution (Compare-And-Swap) over an active publisher's namespace.
    /// TODO: needs a merkle proof
    pub fn commit_state_root(
        &mut self,
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
        
        // 2. Validate linear sequence progress
        let current_head = self.namespace_heads.get(sender);
        if current_head != old_root {
            return Err(RegistryError::StaleStateRoot(StaleStateRoot {}));
        }

        // 3. Persist the state change
        self.namespace_heads.setter(sender).set(new_root);

        self.vm().log(StateCommitted {
            publisher: sender,
            old_root,
            new_root,
        });

        Ok(())
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    /// Read-route for indexing nodes and data consumers to obtain the latest state map reference.
    pub fn get_namespace_head(&self, publisher: Address) -> FixedBytes<32> {
        self.namespace_heads.get(publisher)
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
    use stylus_sdk::alloy_primitives::address;
    use stylus_sdk::testing::TestVM;

    const ADMIN_ADDR: Address = address!("1111111111111111111111111111111111111111");
    const PUB_ADDR: Address = address!("2222222222222222222222222222222222222222");
    const FEE_AMT: u64 = 1_000_000_000_000_000_000; // 1 native token

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
        let mut registry = DataRegistry::from(&vm);
        registry.init(ADMIN_ADDR, U256::from(FEE_AMT));

        vm.set_sender(PUB_ADDR);
        vm.set_value(U256::from(FEE_AMT));
        registry.register().unwrap();

        vm.set_sender(ADMIN_ADDR);
        registry.suspend_publisher(PUB_ADDR).unwrap();

        // Ensure state commits fail under suspended state status bounds
        vm.set_sender(PUB_ADDR);
        let commit_res = registry.commit_state_root(FixedBytes::ZERO, FixedBytes([7u8; 32]));
        assert!(matches!(commit_res, Err(RegistryError::PublisherSuspendedErr(_))));
    }

    #[test]
    fn test_reactivation_retains_timeline_history() {
        let vm = TestVM::default();
        let mut registry = DataRegistry::from(&vm);
        registry.init(ADMIN_ADDR, U256::from(FEE_AMT));

        // 1. Initial signup and real commit mapping tracking setup
        vm.set_sender(PUB_ADDR);
        vm.set_value(U256::from(FEE_AMT));
        registry.register().unwrap();

        let root_a = FixedBytes([5u8; 32]);
        registry.commit_state_root(FixedBytes::ZERO, root_a).unwrap();

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
        assert_eq!(registry.get_namespace_head(PUB_ADDR), root_a);

        // 4. Ensure CAS logic continues perfectly from historical state anchors
        let root_b = FixedBytes([9u8; 32]);
        assert!(registry.commit_state_root(root_a, root_b).is_ok());
        assert_eq!(registry.get_namespace_head(PUB_ADDR), root_b);
    }

    #[test]
    fn test_stale_state_root_rejection() {
        let vm = TestVM::default();
        let mut registry = DataRegistry::from(&vm);
        registry.init(ADMIN_ADDR, U256::from(FEE_AMT));

        vm.set_sender(PUB_ADDR);
        vm.set_value(U256::from(FEE_AMT));
        registry.register().unwrap();

        let root_a = FixedBytes([1u8; 32]);
        let root_b = FixedBytes([2u8; 32]);

        let bad_commit = registry.commit_state_root(root_a, root_b);
        assert!(matches!(bad_commit, Err(RegistryError::StaleStateRoot(_))));
    }
}