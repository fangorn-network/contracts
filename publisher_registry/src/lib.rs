//! PublisherRegistry — the only user-facing contract.
//!
//! Users never touch Bucket directly. They:
//!   1. `join()` — pay the registration fee; the registry asks the
//!      `BucketFactory` to deploy a per-publisher `BeaconProxy` (which
//!      `delegatecall`s the shared Stylus Bucket implementation) and records
//!      `publisher => bucket`.
//!   2. call schema / datasource methods here; the registry forwards each call
//!      to *that publisher's* bucket. Because the forward is a normal call into
//!      the proxy, and the proxy delegatecalls Bucket, `msg.sender` seen by
//!      Bucket is this registry — which is exactly what Bucket's `only_registry`
//!      guard requires.
//!
//! The registry never accepts an arbitrary bucket address from a user; it only
//! ever forwards to the bucket it deployed for `msg.sender`.

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![cfg_attr(feature = "contract-client-gen", allow(unused_imports))]
extern crate alloc;

use alloc::fmt;
use alloc::string::String;
use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{Address, FixedBytes, U256, U64},
    prelude::*,
    storage::*,
};

sol! {
    error AlreadyRegistered();
    error NotRegistered();
    error RegistrationFeeRequired();
    error BucketCreationFailed();
    error ForwardFailed();
    error Unauthorized();

    event PublisherRegistered(
        address indexed publisher,
        address indexed bucket
    );

    event RegistrationFeeChanged(uint256 fee);
}

#[derive(SolidityError)]
pub enum RegistryError {
    AlreadyRegistered(AlreadyRegistered),
    NotRegistered(NotRegistered),
    RegistrationFeeRequired(RegistrationFeeRequired),
    BucketCreationFailed(BucketCreationFailed),
    ForwardFailed(ForwardFailed),
    Unauthorized(Unauthorized),
}

impl fmt::Debug for RegistryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "RegistryError")
    }
}

// Typed clients for the contracts the registry talks to.
sol_interface! {
    interface IBucketFactory {
        function createBucket(address owner) external returns (address);
    }

    interface IBucket {
        // Mutating methods
        function registerSchema(string name, string spec_cid, string agent_id) external returns (bytes32);
        function updateSchemaAgent(string schema_name, string new_agent_id) external;
        function deleteSchema(string schema_name) external;
        function publish(string manifest_cid, bytes32 merkle_root, string schema_name, string name) external;

        // View/Getter methods
        function schemaExists(bytes32 schema_id) external view returns (bool);
        function getSchema(string schema_name) external view returns (string, bytes32, string, string);
        function get(string schema_name, string name) external view returns (string, bytes32);
        function getMerkleRoot(string schema_name, string name) external view returns (bytes32);
        function getVersion(string schema_name, string name) external view returns (uint64);
        function getName(string schema_name, bytes32 name_hash) external view returns (string);
        function resourceId(bytes32 schema_id, string name) external view returns (bytes32);
    }
}

#[storage]
#[entrypoint]
pub struct PublisherRegistry {
    /// Protocol admin.
    admin: StorageAddress,
    /// BucketFactory that deploys per-publisher beacon proxies.
    factory: StorageAddress,
    /// Registration fee (eventually in $FANG).
    registration_fee: StorageU256,
    /// publisher => bucket proxy
    publisher_to_bucket: StorageMap<Address, StorageAddress>,
    /// bucket proxy => publisher
    owners: StorageMap<Address, StorageAddress>,
    /// registered?
    registered: StorageMap<Address, StorageBool>,
    /// number of publishers
    publisher_count: StorageU64,
}

#[public]
impl PublisherRegistry {
    #[constructor]
    pub fn init(
        &mut self,
        admin: Address,
        factory: Address,
        registration_fee: U256,
    ) {
        self.admin.set(admin);
        self.factory.set(factory);
        self.registration_fee.set(registration_fee);
    }

    /// Register as a publisher
    // pays the registration fee, then deploys a bucket and records ownership
    ///
    #[payable]
    pub fn register(&mut self) -> Result<Address, RegistryError> {
        let sender = self.vm().msg_sender();

        if self.registered.get(sender) {
            return Err(RegistryError::AlreadyRegistered(AlreadyRegistered {}));
        }
        if self.vm().msg_value() < self.registration_fee.get() {
            return Err(RegistryError::RegistrationFeeRequired(
                RegistrationFeeRequired {},
            ));
        }

        // deploy a new bucket for the publisher
        let factory = IBucketFactory::new(self.factory.get());
        let ctx = Call::new_mutating(self);
        let bucket = factory
            .create_bucket(self.vm(), ctx, sender)
            .map_err(|_| RegistryError::BucketCreationFailed(BucketCreationFailed {}))?;

        self.registered.setter(sender).set(true);
        self.publisher_to_bucket.setter(sender).set(bucket);
        self.owners.setter(bucket).set(sender);
        self.publisher_count
            .set(self.publisher_count.get() + U64::from(1));

        self.vm().log(PublisherRegistered {
            publisher: sender,
            bucket,
        });
        Ok(bucket)
    }

    // ── Schema forwarders ─────────────────────────────────────────────────────

    pub fn register_schema(
        &mut self,
        name: String,
        spec_cid: String,
        agent_id: String,
    ) -> Result<FixedBytes<32>, RegistryError> {
        let bucket = self.require_bucket()?;
        let ctx = Call::new_mutating(self);
        IBucket::new(bucket)
            .register_schema(self.vm(), ctx, name, spec_cid, agent_id)
            .map_err(|_| RegistryError::ForwardFailed(ForwardFailed {}))
    }

    pub fn update_schema_agent(
        &mut self,
        schema_name: String,
        new_agent_id: String,
    ) -> Result<(), RegistryError> {
        let bucket = self.require_bucket()?;
        let ctx = Call::new_mutating(self);
        IBucket::new(bucket)
            .update_schema_agent(self.vm(), ctx, schema_name, new_agent_id)
            .map_err(|_| RegistryError::ForwardFailed(ForwardFailed {}))
    }

    pub fn delete_schema(
        &mut self,
        schema_name: String,
    ) -> Result<(), RegistryError> {
        let bucket = self.require_bucket()?;
        let ctx = Call::new_mutating(self);
        IBucket::new(bucket)
            .delete_schema(self.vm(), ctx, schema_name)
            .map_err(|_| RegistryError::ForwardFailed(ForwardFailed {}))
    }

    // ── Datasource forwarder ──────────────────────────────────────────────────

    pub fn publish(
        &mut self,
        manifest_cid: String,
        merkle_root: FixedBytes<32>,
        schema_name: String,
        name: String,
    ) -> Result<(), RegistryError> {
        let bucket = self.require_bucket()?;
        let ctx = Call::new_mutating(self);
        IBucket::new(bucket)
            .publish(self.vm(), ctx, manifest_cid, merkle_root, schema_name, name)
            .map_err(|_| RegistryError::ForwardFailed(ForwardFailed {}))
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    /// Publisher's bucket proxy address (also lets clients read the bucket
    /// directly, skipping the forwarding hop for reads).
    pub fn bucket_of(&self, publisher: Address) -> Address {
        self.publisher_to_bucket.get(publisher)
    }

    pub fn owner_of(&self, bucket: Address) -> Address {
        self.owners.get(bucket)
    }

    pub fn is_registered(&self, publisher: Address) -> bool {
        self.registered.get(publisher)
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

    pub fn factory(&self) -> Address {
        self.factory.get()
    }

    // ── Forwarded Bucket Data Getters ─────────────────────────────────────────

    pub fn get_bucket_schema_exists(
        &self,
        publisher: Address,
        schema_id: FixedBytes<32>,
    ) -> Result<bool, RegistryError> {
        let bucket = self.get_bucket_of(publisher)?;
        let ctx = Call::new();
        IBucket::new(bucket)
            .schema_exists(self.vm(), ctx, schema_id)
            .map_err(|_| RegistryError::ForwardFailed(ForwardFailed {}))
    }

    pub fn get_bucket_schema(
        &self,
        publisher: Address,
        schema_name: String,
    ) -> Result<(String, FixedBytes<32>, String, String), RegistryError> {
        let bucket = self.get_bucket_of(publisher)?;
        let ctx = Call::new();
        IBucket::new(bucket)
            .get_schema(self.vm(), ctx, schema_name)
            .map_err(|_| RegistryError::ForwardFailed(ForwardFailed {}))
    }

    pub fn get_bucket_manifest(
        &self,
        publisher: Address,
        schema_name: String,
        name: String,
    ) -> Result<(String, FixedBytes<32>), RegistryError> {
        let bucket = self.get_bucket_of(publisher)?;
        let ctx = Call::new();
        IBucket::new(bucket)
            .get(self.vm(), ctx, schema_name, name)
            .map_err(|_| RegistryError::ForwardFailed(ForwardFailed {}))
    }

    pub fn get_bucket_merkle_root(
        &self,
        publisher: Address,
        schema_name: String,
        name: String,
    ) -> Result<FixedBytes<32>, RegistryError> {
        let bucket = self.get_bucket_of(publisher)?;
        let ctx = Call::new();
        IBucket::new(bucket)
            .get_merkle_root(self.vm(), ctx, schema_name, name)
            .map_err(|_| RegistryError::ForwardFailed(ForwardFailed {}))
    }

    pub fn get_bucket_version(
        &self,
        publisher: Address,
        schema_name: String,
        name: String,
    ) -> Result<u64, RegistryError> {
        let bucket = self.get_bucket_of(publisher)?;
        let ctx = Call::new();
        IBucket::new(bucket)
            .get_version(self.vm(), ctx, schema_name, name)
            .map_err(|_| RegistryError::ForwardFailed(ForwardFailed {}))
    }

    pub fn get_bucket_name_by_hash(
        &self,
        publisher: Address,
        schema_name: String,
        name_hash: FixedBytes<32>,
    ) -> Result<String, RegistryError> {
        let bucket = self.get_bucket_of(publisher)?;
        let ctx = Call::new();
        IBucket::new(bucket)
            .get_name(self.vm(), ctx, schema_name, name_hash)
            .map_err(|_| RegistryError::ForwardFailed(ForwardFailed {}))
    }

    pub fn get_bucket_resource_id(
        &self,
        publisher: Address,
        schema_id: FixedBytes<32>,
        name: String,
    ) -> Result<FixedBytes<32>, RegistryError> {
        let bucket = self.get_bucket_of(publisher)?;
        let ctx = Call::new();
        IBucket::new(bucket)
            .resource_id(self.vm(), ctx, schema_id, name)
            .map_err(|_| RegistryError::ForwardFailed(ForwardFailed {}))
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    pub fn set_registration_fee(&mut self, fee: U256) -> Result<(), RegistryError> {
        self.only_admin()?;
        self.registration_fee.set(fee);
        self.vm().log(RegistrationFeeChanged { fee });
        Ok(())
    }

    pub fn set_factory(&mut self, factory: Address) -> Result<(), RegistryError> {
        self.only_admin()?;
        self.factory.set(factory);
        Ok(())
    }
}

impl PublisherRegistry {
    /// The caller's bucket, or `NotRegistered` if they never joined.
    fn require_bucket(&self) -> Result<Address, RegistryError> {
        let sender = self.vm().msg_sender();
        self.get_bucket_of(sender)
    }

    /// Internal look up for a specified publisher's bucket, ensuring registration.
    fn get_bucket_of(&self, publisher: Address) -> Result<Address, RegistryError> {
        if !self.registered.get(publisher) {
            return Err(RegistryError::NotRegistered(NotRegistered {}));
        }
        Ok(self.publisher_to_bucket.get(publisher))
    }

    fn only_admin(&self) -> Result<(), RegistryError> {
        if self.vm().msg_sender() != self.admin.get() {
            return Err(RegistryError::Unauthorized(Unauthorized {}));
        }
        Ok(())
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use stylus_sdk::alloy_primitives::address;
    use stylus_sdk::testing::*;

    const ADMIN: Address = address!("0xCDC41bff86a62716f050622325CC17a317f99404");
    const FACTORY: Address = address!("0x1111111111111111111111111111111111111111");
    const ALICE: Address = address!("0x3333333333333333333333333333333333333333");

    fn setup() -> (TestVM, PublisherRegistry) {
        let vm = TestVM::default();
        let mut c = PublisherRegistry::from(&vm);
        c.init(ADMIN, FACTORY, U256::from(1000));
        (vm, c)
    }

    #[test]
    fn init_sets_state() {
        let (_, c) = setup();
        assert_eq!(c.admin(), ADMIN);
        assert_eq!(c.factory(), FACTORY);
        assert_eq!(c.registration_fee(), U256::from(1000));
        assert_eq!(c.publisher_count(), 0);
    }

    #[test]
    fn register_requires_fee() {
        let (vm, mut c) = setup();
        vm.set_sender(ALICE);
        vm.set_value(U256::from(999));
        assert!(matches!(
            c.register(),
            Err(RegistryError::RegistrationFeeRequired(_))
        ));
    }

    #[test]
    fn forward_before_join_fails() {
        let (vm, mut c) = setup();
        vm.set_sender(ALICE);
        assert!(matches!(
            c.register_schema("music".into(), "cid".into(), "a".into()),
            Err(RegistryError::NotRegistered(_))
        ));
    }

    #[test]
    fn set_fee_admin_only() {
        let (vm, mut c) = setup();
        vm.set_sender(ALICE);
        assert!(matches!(
            c.set_registration_fee(U256::from(5)),
            Err(RegistryError::Unauthorized(_))
        ));
        vm.set_sender(ADMIN);
        assert!(c.set_registration_fee(U256::from(5)).is_ok());
        assert_eq!(c.registration_fee(), U256::from(5));
    }

    #[test]
    fn bucket_lookup_empty_by_default() {
        let (_, c) = setup();
        assert_eq!(c.bucket_of(ALICE), Address::ZERO);
        assert!(!c.is_registered(ALICE));
    }

    // NOTE: `join()` success, forwarding into a real bucket, duplicate
    // registration, and beacon upgrades all exercise a live factory + proxy +
    // cross-VM delegatecall. Those cannot be reproduced in the Stylus TestVM
    // (no contract deployment / delegatecall). They are covered by the Foundry
    // suite and the on-chain integration flow on nitro-testnode.
}
