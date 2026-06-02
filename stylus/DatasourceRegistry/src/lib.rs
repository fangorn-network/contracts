#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![cfg_attr(feature = "contract-client-gen", allow(unused_imports))]

extern crate alloc;

use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{keccak256, Address, FixedBytes, U64},
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
        bytes32 merkle_root,
        string manifest_cid
    );

    event ManifestUpdated(
        address indexed owner,
        bytes32 indexed schema_id,
        bytes32 indexed name_hash,
        bytes32 merkle_root,
        string manifest_cid,
        uint64 version
    );

    error DataSourceNotFound();
    error SchemaNotFound();
    error SchemaRequired();
    error NameRequired();
    error SchemaRegistrationFailed();
}

#[derive(SolidityError)]
pub enum DataSourceRegistryError {
    DataSourceNotFound(DataSourceNotFound),
    SchemaNotFound(SchemaNotFound),
    SchemaRequired(SchemaRequired),
    NameRequired(NameRequired),
    SchemaRegistrationFailed(SchemaRegistrationFailed),
}

#[storage]
pub struct StorageDataSource {
    pub manifest_cid: StorageString,
    pub merkle_root: StorageFixedBytes<32>,
    pub name: StorageString,
    pub version: StorageU64,
}

#[storage]
#[entrypoint]
pub struct DataSourceRegistry {
    /// owner => schema_id => name_hash => datasource
    data_sources: StorageMap<
        Address,
        StorageMap<FixedBytes<32>, StorageMap<FixedBytes<32>, StorageDataSource>>,
    >,

    schema_registry: StorageAddress,
}

#[public]
impl DataSourceRegistry {
    #[constructor]
    pub fn initialize(&mut self, schema_registry: Address) {
        self.schema_registry.set(schema_registry);
    }

    pub fn publish(
        &mut self,
        manifest_cid: String,
        merkle_root: FixedBytes<32>,
        schema_id: FixedBytes<32>,
        name: String,
    ) -> Result<(), DataSourceRegistryError> {
        let sender = self.vm().msg_sender();

        if schema_id == FixedBytes::ZERO {
            return Err(DataSourceRegistryError::SchemaRequired(SchemaRequired {}));
        }

        if name.is_empty() {
            return Err(DataSourceRegistryError::NameRequired(NameRequired {}));
        }

        let registry = self.schema_registry.get();

        let schema_exists =
            unsafe { RawCall::new(self.vm()).call(registry, &sel_schema_exists(schema_id)) }
                .map(|r| r.get(31).copied().unwrap_or(0) != 0)
                .unwrap_or(false);

        if !schema_exists {
            return Err(DataSourceRegistryError::SchemaNotFound(SchemaNotFound {}));
        }

        let name_hash = keccak256(name.as_bytes());

        let current_version = {
            self.data_sources
                .getter(sender)
                .getter(schema_id)
                .getter(name_hash)
                .version
                .get()
        };

        if current_version == U64::ZERO {
            unsafe {
                RawCall::new(self.vm()).call(registry, &sel_add_publisher(schema_id, sender))
            }
            .map_err(|_| DataSourceRegistryError::SchemaRegistrationFailed(SchemaRegistrationFailed {}))?;
        }

        let new_version = {
            let mut sender_ds = self.data_sources.setter(sender);
            let mut schema_ds = sender_ds.setter(schema_id);
            let mut ds = schema_ds.setter(name_hash);

            let version = ds.version.get() + U64::from(1);

            ds.version.set(version);
            ds.manifest_cid.set_str(&manifest_cid);
            ds.merkle_root.set(merkle_root);

            if version == U64::from(1) {
                ds.name.set_str(&name);
            }

            version
        };

        if new_version == U64::from(1) {
            self.vm().log(ManifestPublished {
                owner: sender,
                schema_id,
                name_hash,
                name,
                merkle_root,
                manifest_cid,
            });
        } else {
            self.vm().log(ManifestUpdated {
                owner: sender,
                schema_id,
                name_hash,
                merkle_root,
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
    ) -> Result<(String, FixedBytes<32>), DataSourceRegistryError> {
        let name_hash = keccak256(name.as_bytes());
        self.get_by_hash(owner, schema_id, name_hash)
    }

    pub fn get_by_hash(
        &self,
        owner: Address,
        schema_id: FixedBytes<32>,
        name_hash: FixedBytes<32>,
    ) -> Result<(String, FixedBytes<32>), DataSourceRegistryError> {
        let mut owner_ds = self.data_sources.getter(owner);
        let mut schema_ds = owner_ds.getter(schema_id);
        let mut ds = schema_ds.getter(name_hash);

        if ds.version.get() == U64::ZERO {
            return Err(DataSourceRegistryError::DataSourceNotFound(
                DataSourceNotFound {},
            ));
        }

        Ok((ds.manifest_cid.get_string(), ds.merkle_root.get()))
    }

    pub fn get_merkle_root(
        &self,
        owner: Address,
        schema_id: FixedBytes<32>,
        name_hash: FixedBytes<32>,
    ) -> FixedBytes<32> {
        self.data_sources
            .getter(owner)
            .getter(schema_id)
            .getter(name_hash)
            .merkle_root
            .get()
    }

    pub fn get_version(&self, owner: Address, schema_id: FixedBytes<32>, name: String) -> u64 {
        let name_hash = keccak256(name.as_bytes());
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

    pub fn resource_id(
        &self,
        owner: Address,
        schema_id: FixedBytes<32>,
        name: String,
    ) -> FixedBytes<32> {
        let name_hash = keccak256(name.as_bytes());
        derive_resource_id(owner, schema_id, name_hash)
    }

    pub fn get_schema_registry(&self) -> Address {
        self.schema_registry.get()
    }
}

fn derive_resource_id(
    owner: Address,
    schema_id: FixedBytes<32>,
    name_hash: FixedBytes<32>,
) -> FixedBytes<32> {
    let mut data = alloc::vec::Vec::with_capacity(84);
    data.extend_from_slice(owner.as_slice());
    data.extend_from_slice(schema_id.as_slice());
    data.extend_from_slice(name_hash.as_slice());
    keccak256(&data)
}

const SEL_SCHEMA_EXISTS: [u8; 4] = [0xc0, 0xef, 0x02, 0xe6];
const SEL_ADD_PUBLISHER: [u8; 4] = [0xc6, 0xf1, 0x7a, 0xde];

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

#[cfg(test)]
mod tests {
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
        contract.initialize(DUMMY);
        (vm, contract)
    }

    #[test]
    fn resource_id_stable() {
        let (_, c) = setup();
        assert_eq!(
            c.resource_id(USER, SCHEMA_A, "music".into()),
            c.resource_id(USER, SCHEMA_A, "music".into()),
        );
    }

    #[test]
    fn resource_id_unique_per_name() {
        let (_, c) = setup();
        assert_ne!(
            c.resource_id(USER, SCHEMA_A, "music".into()),
            c.resource_id(USER, SCHEMA_A, "movies".into()),
        );
    }

    #[test]
    fn resource_id_unique_per_schema() {
        let (_, c) = setup();
        assert_ne!(
            c.resource_id(USER, SCHEMA_A, "music".into()),
            c.resource_id(USER, SCHEMA_B, "music".into()),
        );
    }

    #[test]
    fn empty_before_publish() {
        let (_, c) = setup();
        assert!(c.get(USER, SCHEMA_A, "music".into()).is_err());
    }

    #[test]
    fn version_zero_before_publish() {
        let (_, c) = setup();
        assert_eq!(c.get_version(USER, SCHEMA_A, "music".into()), 0);
    }

    #[test]
    fn merkle_root_zero_before_publish() {
        let (_, c) = setup();
        let name_hash = keccak256(b"music");
        assert_eq!(
            c.get_merkle_root(USER, SCHEMA_A, name_hash),
            FixedBytes::<32>::ZERO
        );
    }

    #[test]
    fn selectors_match() {
        assert_eq!(SEL_SCHEMA_EXISTS, keccak256(b"schemaExists(bytes32)")[..4]);
        assert_eq!(SEL_ADD_PUBLISHER, keccak256(b"addPublisher(bytes32,address)")[..4]);
    }

    #[test]
    fn get_schema_registry_returns_initialized_value() {
        let (_, c) = setup();
        assert_eq!(c.get_schema_registry(), DUMMY);
    }
}