#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![cfg_attr(feature = "contract-client-gen", allow(unused_imports))]

extern crate alloc;

use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{keccak256, Address, FixedBytes, U256, U64},
    call::RawCall,
    prelude::*,
    storage::*,
};

sol! {
    event ManifestPublished(
        address indexed owner,
        bytes32 indexed schema_id,
        bytes32 indexed name_hash,
        string name,
        string manifest_cid
    );

    event ManifestUpdated(
        address indexed owner,
        bytes32 indexed schema_id,
        bytes32 indexed name_hash,
        string manifest_cid,
        uint64 version
    );

    error DataSourceNotFound();
    error SchemaNotFound();
    error SchemaRequired();
    error NameRequired();
    error ResourceSetupFailed();
}

#[derive(SolidityError)]
pub enum DataSourceRegistryError {
    DataSourceNotFound(DataSourceNotFound),
    SchemaNotFound(SchemaNotFound),
    SchemaRequired(SchemaRequired),
    NameRequired(NameRequired),
    ResourceSetupFailed(ResourceSetupFailed),
}

#[storage]
pub struct StorageDataSource {
    pub manifest_cid: StorageString,
    pub name: StorageString,
    pub version: StorageU64,
}

#[storage]
#[entrypoint]
pub struct DataSourceRegistry {
    /// owner => schema_id => name_hash => DataSource
    data_sources: StorageMap<
        Address,
        StorageMap<FixedBytes<32>, StorageMap<FixedBytes<32>, StorageDataSource>>,
    >,
    schema_registry: StorageAddress,
    settlement_registry: StorageAddress,
}

#[public]
impl DataSourceRegistry {
    #[constructor]
    pub fn initialize(&mut self, schema_registry: Address, settlement_registry: Address) {
        self.schema_registry.set(schema_registry);
        self.settlement_registry.set(settlement_registry);
    }

    /// Publish or update a named data source entry.
    ///
    /// On first publish: createResource + addSeedMember in the settlement registry.
    /// On update:        updatePrice only. The resource_id (and Semaphore group) is stable.
    pub fn publish(
        &mut self,
        manifest_cid: String,
        schema_id: FixedBytes<32>,
        name: String,
        price: U256,
    ) -> Result<(), DataSourceRegistryError> {
        let sender = self.vm().msg_sender();

        if schema_id == FixedBytes::ZERO {
            return Err(DataSourceRegistryError::SchemaRequired(SchemaRequired {}));
        }
        if name.is_empty() {
            return Err(DataSourceRegistryError::NameRequired(NameRequired {}));
        }

        // Validate schema exists
        let registry = self.schema_registry.get();
        let schema_exists =
            unsafe { RawCall::new(self.vm()).call(registry, &sel_schema_exists(schema_id)) }
                .map(|r| r.get(31).copied().unwrap_or(0) != 0) // ABI-encoded bool: byte 31 of 32
                .unwrap_or(false);

        if !schema_exists {
            return Err(DataSourceRegistryError::SchemaNotFound(SchemaNotFound {}));
        }

        let name_hash: FixedBytes<32> = keccak256(name.as_bytes());
        let resource_id = derive_resource_id(sender, schema_id, name_hash);
        let settlement = self.settlement_registry.get();

        // Read current version to determine first publish vs update
        let current_version = {
            let binding = self.data_sources.getter(sender);
            let schema_binding = binding.getter(schema_id);
            schema_binding.getter(name_hash).version.get()
        };

        if current_version == U64::ZERO {
            unsafe {
                RawCall::new(self.vm())
                    .call(settlement, &sel_create_resource(resource_id, price, sender))
            }
            .map_err(|_| DataSourceRegistryError::ResourceSetupFailed(ResourceSetupFailed {}))?;
            // notify the schema registry that this publisher has data against the schema
            unsafe {
                RawCall::new(self.vm()).call(registry, &sel_add_publisher(schema_id, sender))
            }
            .map_err(|_| DataSourceRegistryError::ResourceSetupFailed(ResourceSetupFailed {}))?;
        } else {
            // Update: price may change, group stays stable
            unsafe {
                RawCall::new(self.vm()).call(settlement, &sel_update_price(resource_id, price, sender))
            }
            .map_err(|_| DataSourceRegistryError::ResourceSetupFailed(ResourceSetupFailed {}))?;
        }

        let new_version = {
            let mut owner_binding = self.data_sources.setter(sender);
            let mut schema_binding = owner_binding.setter(schema_id);
            let mut ds = schema_binding.setter(name_hash);
            let v = ds.version.get() + U64::from(1);
            ds.version.set(v);
            ds.manifest_cid.set_str(&manifest_cid);
            if v == U64::from(1) {
                // only written once; name is immutable after first publish
                ds.name.set_str(&name);
            }
            v
        };

        if new_version == U64::from(1) {
            self.vm().log(ManifestPublished {
                owner: sender,
                schema_id,
                name_hash,
                name,
                manifest_cid,
            });
        } else {
            self.vm().log(ManifestUpdated {
                owner: sender,
                schema_id,
                name_hash,
                manifest_cid,
                version: new_version.to::<u64>(),
            });
        }

        Ok(())
    }

    pub fn get(
        &self,
        owner: Address,
        schema_id: FixedBytes<32>,
        name: String,
    ) -> Result<String, DataSourceRegistryError> {
        let name_hash: FixedBytes<32> = keccak256(name.as_bytes());
        let binding = self.data_sources.getter(owner);
        let schema_binding = binding.getter(schema_id);
        let ds = schema_binding.getter(name_hash);
        if ds.version.get() == U64::ZERO {
            return Err(DataSourceRegistryError::DataSourceNotFound(
                DataSourceNotFound {},
            ));
        }
        Ok(ds.manifest_cid.get_string())
    }

    pub fn get_by_hash(
        &self,
        owner: Address,
        schema_id: FixedBytes<32>,
        name_hash: FixedBytes<32>,
    ) -> Result<String, DataSourceRegistryError> {
        let binding = self.data_sources.getter(owner);
        let schema_binding = binding.getter(schema_id);
        let ds = schema_binding.getter(name_hash);
        if ds.version.get() == U64::ZERO {
            return Err(DataSourceRegistryError::DataSourceNotFound(
                DataSourceNotFound {},
            ));
        }
        Ok(ds.manifest_cid.get_string())
    }

    pub fn get_version(&self, owner: Address, schema_id: FixedBytes<32>, name: String) -> u64 {
        let name_hash: FixedBytes<32> = keccak256(name.as_bytes());
        self.data_sources
            .getter(owner)
            .getter(schema_id)
            .getter(name_hash)
            .version
            .get()
            .to::<u64>()
    }

    pub fn get_name(
        &self,
        owner: Address,
        schema_id: FixedBytes<32>,
        name_hash: FixedBytes<32>,
    ) -> String {
        self.data_sources
            .getter(owner)
            .getter(schema_id)
            .getter(name_hash)
            .name
            .get_string()
    }

    /// Derive the resource_id (= Semaphore group id) for a given (owner, schema, name).
    /// Exposed so the SDK can compute it client-side without a contract call.
    pub fn resource_id(
        &self,
        owner: Address,
        schema_id: FixedBytes<32>,
        name: String,
    ) -> FixedBytes<32> {
        let name_hash: FixedBytes<32> = keccak256(name.as_bytes());
        derive_resource_id(owner, schema_id, name_hash)
    }
}

fn derive_resource_id(
    owner: Address,
    schema_id: FixedBytes<32>,
    name_hash: FixedBytes<32>,
) -> FixedBytes<32> {
    let mut data = alloc::vec::Vec::with_capacity(20 + 32 + 32);
    data.extend_from_slice(owner.as_slice());
    data.extend_from_slice(schema_id.as_slice());
    data.extend_from_slice(name_hash.as_slice());
    keccak256(&data)
}

// Calldata builders

const SEL_SCHEMA_EXISTS: [u8; 4] = [0xc0, 0xef, 0x02, 0xe6]; // schemaExists(bytes32)
const SEL_ADD_PUBLISHER: [u8; 4] = [0xc6, 0xf1, 0x7a, 0xde]; // addPublisher(bytes32,address)
const SEL_CREATE_RESOURCE: [u8; 4] = [0xe8, 0x60, 0xd4, 0xc8]; // createResource(bytes32,uint256,address)
const SEL_UPDATE_PRICE: [u8; 4] = [0xc9, 0x7c, 0x8b, 0x06]; // updatePrice(bytes32,uint256,address)

fn sel_create_resource(
    resource_id: FixedBytes<32>,
    price: U256,
    owner: Address,
) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_CREATE_RESOURCE.to_vec();
    cd.extend_from_slice(resource_id.as_slice());
    cd.extend_from_slice(&price.to_be_bytes::<32>());
    cd.extend_from_slice(&[0u8; 12]);
    cd.extend_from_slice(owner.as_slice());
    cd
}

fn sel_add_publisher(schema_id: FixedBytes<32>, publisher: Address) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_ADD_PUBLISHER.to_vec();
    cd.extend_from_slice(schema_id.as_slice());
    cd.extend_from_slice(&[0u8; 12]);
    cd.extend_from_slice(publisher.as_slice());
    cd
}

fn sel_schema_exists(id: FixedBytes<32>) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_SCHEMA_EXISTS.to_vec();
    cd.extend_from_slice(id.as_slice());
    cd
}

fn sel_update_price(resource_id: FixedBytes<32>, price: U256, owner: Address) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_UPDATE_PRICE.to_vec();
    cd.extend_from_slice(resource_id.as_slice());
    cd.extend_from_slice(&price.to_be_bytes::<32>());
    cd.extend_from_slice(&[0u8; 12]);
    cd.extend_from_slice(owner.as_slice());
    cd
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod test {
    use super::*;
    use alloy_primitives::address;
    use stylus_sdk::testing::*;

    const USER: Address = address!("0xCDC41bff86a62716f050622325CC17a317f99404");
    const SCHEMA_A: FixedBytes<32> = FixedBytes::new([1u8; 32]);
    const SCHEMA_B: FixedBytes<32> = FixedBytes::new([2u8; 32]);
    const DUMMY: Address = address!("0x1111111111111111111111111111111111111111");

    fn setup() -> (TestVM, DataSourceRegistry) {
        let vm = TestVM::default();
        vm.set_sender(USER);
        let mut contract = DataSourceRegistry::from(&vm);
        contract.initialize(DUMMY, DUMMY);
        (vm, contract)
    }

    #[test]
    fn test_schema_required() {
        let (_, mut c) = setup();
        assert!(c
            .publish("cid".into(), FixedBytes::ZERO, "track-1".into(), U256::ZERO)
            .is_err());
    }

    #[test]
    fn test_name_required() {
        let (_, mut c) = setup();
        assert!(c
            .publish("cid".into(), SCHEMA_A, "".into(), U256::ZERO)
            .is_err());
    }

    #[test]
    fn test_unknown_schema_fails() {
        let (_, mut c) = setup();
        assert!(c
            .publish("cid".into(), SCHEMA_A, "track-1".into(), U256::ZERO)
            .is_err());
    }

    #[test]
    fn test_no_manifest_before_publish() {
        let (_, c) = setup();
        assert!(c.get(USER, SCHEMA_A, "track-1".into()).is_err());
    }

    #[test]
    fn test_version_starts_at_zero() {
        let (_, c) = setup();
        assert_eq!(c.get_version(USER, SCHEMA_A, "track-1".into()), 0);
    }

    #[test]
    fn test_independent_schemas() {
        let (_, c) = setup();
        assert_eq!(c.get_version(USER, SCHEMA_A, "track-1".into()), 0);
        assert_eq!(c.get_version(USER, SCHEMA_B, "track-1".into()), 0);
    }

    #[test]
    fn test_resource_id_stable_across_names() {
        let (_, c) = setup();
        let r1 = c.resource_id(USER, SCHEMA_A, "track-1".into());
        let r2 = c.resource_id(USER, SCHEMA_A, "track-1".into());
        assert_eq!(r1, r2);
    }

    #[test]
    fn test_resource_id_unique_per_name() {
        let (_, c) = setup();
        assert_ne!(
            c.resource_id(USER, SCHEMA_A, "track-1".into()),
            c.resource_id(USER, SCHEMA_A, "track-2".into()),
        );
    }

    #[test]
    fn test_resource_id_unique_per_schema() {
        let (_, c) = setup();
        assert_ne!(
            c.resource_id(USER, SCHEMA_A, "track-1".into()),
            c.resource_id(USER, SCHEMA_B, "track-1".into()),
        );
    }

    // Selector sanity checks
    #[test]
    fn test_sel_schema_exists() {
        assert_eq!(SEL_SCHEMA_EXISTS, keccak256(b"schemaExists(bytes32)")[..4]);
    }

    #[test]
    fn test_sel_create_resource() {
        assert_eq!(
            SEL_CREATE_RESOURCE,
            keccak256(b"createResource(bytes32,uint256,address)")[..4]
        );
    }

    #[test]
    fn test_sel_update_price() {
        assert_eq!(
            SEL_UPDATE_PRICE,
            keccak256(b"updatePrice(bytes32,uint256,address)")[..4]
        );
    }

    #[test]
    fn test_sel_add_publisher() {
        assert_eq!(
            SEL_ADD_PUBLISHER,
            keccak256(b"addPublisher(bytes32,address)")[..4]
        );
    }
}
