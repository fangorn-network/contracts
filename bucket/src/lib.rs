//! Bucket 
//!
//! A bucket holds a publisher's *schemas* and *datasources* registered against those schemas.
//! Each bucket is deployed from a parent contract (the [publisher_registry](../publisher_registry))
//! Publishers never directly interact with this contract, instead only doing so through the publisher registry
//!

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![cfg_attr(feature = "contract-client-gen", allow(unused_imports))]

extern crate alloc;

use alloc::fmt;
use alloc::string::String;
use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{keccak256, Address, FixedBytes, U64},
    prelude::*,
    storage::*,
};

sol! {
    event SchemaRegistered(
        bytes32 indexed schema_id,
        string name,
        string spec_cid,
        string agent_id
    );

    event SchemaAgentUpdated(
        bytes32 indexed schema_id,
        string new_agent_id
    );

    event SchemaDeleted(
        bytes32 indexed schema_id
    );

    event ManifestPublished(
        bytes32 indexed schema_id,
        bytes32 indexed name_hash,
        string name,
        bytes32 merkle_root,
        string manifest_cid
    );

    event ManifestUpdated(
        bytes32 indexed schema_id,
        bytes32 indexed name_hash,
        bytes32 merkle_root,
        string manifest_cid,
        uint64 version
    );

    error ZeroAddress();
    error AlreadyInitialized();
    error NotRegistry();
    error SchemaNotFound();
    error SchemaAlreadyExists();
    error SchemaRequired();
    error NameRequired();
    error DataSourceNotFound();
    error SchemaInUse();
}

#[derive(SolidityError)]
pub enum BucketError {
    ZeroAddress(ZeroAddress),
    AlreadyInitialized(AlreadyInitialized),
    NotRegistry(NotRegistry),
    SchemaNotFound(SchemaNotFound),
    SchemaAlreadyExists(SchemaAlreadyExists),
    SchemaRequired(SchemaRequired),
    NameRequired(NameRequired),
    DataSourceNotFound(DataSourceNotFound),
    SchemaInUse(SchemaInUse),
}

impl fmt::Debug for BucketError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "BucketError")
    }
}

#[storage]
pub struct StorageSchema {
    pub name: StorageString,
    pub spec_cid: StorageString,
    pub agent_id: StorageString,
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
pub struct Bucket {
    /// The publisher who owns the bucket
    owner: StorageAddress,
    /// The PublisherRegistry address (only authorized caller)
    registry: StorageAddress,
    /// schema_id => schema
    schemas: StorageMap<FixedBytes<32>, StorageSchema>,
    /// number of datasources published under a schema
    schema_datasource_count: StorageMap<FixedBytes<32>, StorageU64>,
    /// schema_id => name_hash => datasource
    data_sources:
        StorageMap<FixedBytes<32>, StorageMap<FixedBytes<32>, StorageDataSource>>,
}

#[public]
impl Bucket {
    /// One-time init, called by the factory on each ERC-1167 clone (clones never
    /// run the implementation's constructor, so this is a plain guarded method).
    /// * `owner` - the authorized publisher
    /// * `registry` - the PublisherRegistry contract address
    pub fn initialize(
        &mut self,
        owner: Address,
        registry: Address,
    ) -> Result<(), BucketError> {
        if self.registry.get() != Address::ZERO {
            return Err(BucketError::AlreadyInitialized(AlreadyInitialized {}));
        }
        if owner == Address::ZERO || registry == Address::ZERO {
            return Err(BucketError::ZeroAddress(ZeroAddress {}));
        }

        self.owner.set(owner);
        self.registry.set(registry);

        Ok(())
    }


    /// Schema Registry API

    /// Register a schema. 
    /// * `name`: a unique name for the schema
    /// * `spec_cid`: the CID of the schema (e.g. JSON)
    /// * `agent_id`: an agent id (e.g. for ERC-8004 compat)
    pub fn register_schema(
        &mut self,
        name: String,
        spec_cid: String,
        agent_id: String,
    ) -> Result<FixedBytes<32>, BucketError> {
        self.only_registry()?;

        // name is required
        if name.is_empty() {
            return Err(BucketError::NameRequired(NameRequired {}));
        }

        // id = sha256(name)
        let id = keccak256(name.as_bytes());
        // name must be unique
        if self.schema_exists(id) {
            return Err(BucketError::SchemaAlreadyExists(SchemaAlreadyExists {}));
        }

        // update storage
        let mut schema = self.schemas.setter(id);
        schema.name.set_str(&name);
        schema.spec_cid.set_str(&spec_cid);
        schema.agent_id.set_str(&agent_id);

        self.vm().log(SchemaRegistered {
            schema_id: id,
            name,
            spec_cid,
            agent_id,
        });
        Ok(id)
    }

    /// Update a schema's agent
    pub fn update_schema_agent(
        &mut self,
        schema_name: String,
        new_agent_id: String,
    ) -> Result<(), BucketError> {
        self.only_registry()?;


        let schema_id = keccak256(schema_name.as_bytes());

        if !self.schema_exists(schema_id) {
            return Err(BucketError::SchemaNotFound(SchemaNotFound {}));
        }

        let mut schema = self.schemas.setter(schema_id);
        schema.agent_id.set_str(&new_agent_id);

        self.vm().log(SchemaAgentUpdated {
            schema_id,
            new_agent_id,
        });
        Ok(())
    }

    /// Try to delete a schema. 
    /// It will; refuse to delete if datasources still reference it (prevents orphaned datasources)
    pub fn delete_schema(
        &mut self,
        schema_name: String,
    ) -> Result<(), BucketError> {
        self.only_registry()?;

        let schema_id = keccak256(schema_name.as_bytes());

        if !self.schema_exists(schema_id) {
            return Err(BucketError::SchemaNotFound(SchemaNotFound {}));
        }
        if self.schema_datasource_count.get(schema_id) > U64::ZERO {
            return Err(BucketError::SchemaInUse(SchemaInUse {}));
        }

        let mut schema = self.schemas.setter(schema_id);
        schema.name.set_str("");
        schema.spec_cid.set_str("");
        schema.agent_id.set_str("");

        self.vm().log(SchemaDeleted { schema_id });
        Ok(())
    }

    /// A schema exists iff it has a published name
    pub fn schema_exists(&self, schema_id: FixedBytes<32>) -> bool {
        !self.schemas.getter(schema_id).name.get_string().is_empty()
    }

    pub fn get_schema(
        &self,
        schema_name: String,
    ) -> Result<(String, FixedBytes<32>, String, String), BucketError> {
        let schema_id = keccak256(schema_name.as_bytes());
        if !self.schema_exists(schema_id) {
            return Err(BucketError::SchemaNotFound(SchemaNotFound {}));
        }
        let schema = self.schemas.getter(schema_id);
        Ok((
            schema.name.get_string(),
            schema_id,
            schema.spec_cid.get_string(),
            schema.agent_id.get_string(),
        ))
    }

    /// Data publisher API

    /// Publish or update a datasource under a schema. Increments version on
    /// every call; first publish is version 1.
    ///
    /// * `manifest_cid`:  the CID of the manifest to publish
    /// * `merkle_root`: The Merkle root committing to entries in the manifest
    /// * `schema_id`: the schema_id we are publishing against (should this be name instead?)
    /// * `name`: a name to identify the manifest (is this needed?)
    ///
    pub fn publish(
        &mut self,
        manifest_cid: String,
        merkle_root: FixedBytes<32>,
        schema_name: String,
        name: String,
    ) -> Result<(), BucketError> {
        self.only_registry()?;

        let schema_id = keccak256(schema_name.as_bytes());
        if schema_id == FixedBytes::ZERO {
            return Err(BucketError::SchemaRequired(SchemaRequired {}));
        }
        if name.is_empty() {
            return Err(BucketError::NameRequired(NameRequired {}));
        }
        if !self.schema_exists(schema_id) {
            return Err(BucketError::SchemaNotFound(SchemaNotFound {}));
        }

        let name_hash = keccak256(name.as_bytes());

        let new_version = {
            let mut schema_ds = self.data_sources.setter(schema_id);
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

        // first publish
        if new_version == U64::from(1) {
            let count = self.schema_datasource_count.get(schema_id);
            self.schema_datasource_count
                .setter(schema_id)
                .set(count + U64::from(1));

            self.vm().log(ManifestPublished {
                schema_id,
                name_hash,
                name,
                merkle_root,
                manifest_cid,
            });
        } else {
            self.vm().log(ManifestUpdated {
                schema_id,
                name_hash,
                merkle_root,
                manifest_cid,
                version: new_version.to::<u64>(),
            });
        }

        Ok(())
    }

    // get a manifest by schema name + manifest name
    pub fn get(
        &self,
        schema_name: String,
        name: String,
    ) -> Result<(String, FixedBytes<32>), BucketError> {
        let schema_id = keccak256(schema_name.as_bytes());
        let name_hash = keccak256(name.as_bytes());
        let schema_ds = self.data_sources.getter(schema_id);
        let ds = schema_ds.getter(name_hash);
        if ds.version.get() == U64::ZERO {
            return Err(BucketError::DataSourceNotFound(DataSourceNotFound {}));
        }
        Ok((ds.manifest_cid.get_string(), ds.merkle_root.get()))
    }

    /// get a merkle root by the 
    pub fn get_merkle_root(
        &self,
        // schema_id: FixedBytes<32>,
        schema_name: String,
        name: String,
    ) -> FixedBytes<32> {
        let schema_id = keccak256(schema_name.as_bytes());
        let name_hash = keccak256(name.as_bytes());
        self.data_sources
            .getter(schema_id)
            .getter(name_hash)
            .merkle_root
            .get()
    }

    pub fn get_version(
        &self, 
        schema_name: String, 
        name: String
    ) -> u64 {
        let schema_id = keccak256(schema_name.as_bytes());
        let name_hash = keccak256(name.as_bytes());
        self.data_sources
            .getter(schema_id)
            .getter(name_hash)
            .version
            .get()
            .to::<u64>()
    }

    pub fn get_name(
        &self,
        schema_name: String,
        name_hash: FixedBytes<32>,
    ) -> String {
        let schema_id = keccak256(schema_name.as_bytes());
        self.data_sources
            .getter(schema_id)
            .getter(name_hash)
            .name
            .get_string()
    }

    // ── Identity ──────────────────────────────────────────────────────────────

    /// Deterministic global resource id for a datasource.
    ///
    /// `keccak256(bucket_address ++ schema_id ++ name_hash)`. The bucket address
    /// is this proxy's address (unique per publisher), so ids are globally
    /// unique across publishers without needing an explicit owner in the hash.
    pub fn resource_id(
        &self,
        schema_id: FixedBytes<32>,
        name: String,
    ) -> FixedBytes<32> {
        let name_hash = keccak256(name.as_bytes());
        derive_resource_id(self.vm().contract_address(), schema_id, name_hash)
    }

    pub fn owner(&self) -> Address {
        self.owner.get()
    }

    pub fn registry(&self) -> Address {
        self.registry.get()
    }
}

impl Bucket {
    /// Guard: only the registry may mutate bucket state.
    fn only_registry(&self) -> Result<(), BucketError> {
        if self.vm().msg_sender() != self.registry.get() {
            return Err(BucketError::NotRegistry(NotRegistry {}));
        }
        Ok(())
    }
}

fn derive_resource_id(
    bucket: Address,
    schema_id: FixedBytes<32>,
    name_hash: FixedBytes<32>,
) -> FixedBytes<32> {
    let mut data = alloc::vec::Vec::with_capacity(84);
    data.extend_from_slice(bucket.as_slice());
    data.extend_from_slice(schema_id.as_slice());
    data.extend_from_slice(name_hash.as_slice());
    keccak256(&data)
}

#[cfg(test)]
mod test {
    use super::*;
    use stylus_sdk::alloy_primitives::address;
    use stylus_sdk::testing::*;

    const OWNER: Address = address!("0xCDC41bff86a62716f050622325CC17a317f99404");
    const REGISTRY: Address = address!("0x1111111111111111111111111111111111111111");
    const STRANGER: Address = address!("0x2222222222222222222222222222222222222222");

    fn setup() -> (TestVM, Bucket) {
        let vm = TestVM::default();
        let mut c = Bucket::from(&vm);
        // Calls arrive from the registry.
        vm.set_sender(REGISTRY);
        c.initialize(OWNER, REGISTRY).unwrap();
        (vm, c)
    }

    // ── Initialization ────────────────────────────────────────────────────────

    #[test]
    fn initialize_sets_state() {
        let (_, c) = setup();
        assert_eq!(c.owner(), OWNER);
        assert_eq!(c.registry(), REGISTRY);
    }

    #[test]
    fn initialize_twice_fails() {
        let (_, mut c) = setup();
        assert!(matches!(
            c.initialize(OWNER, REGISTRY),
            Err(BucketError::AlreadyInitialized(_))
        ));
    }

    #[test]
    fn initialize_rejects_zero() {
        let vm = TestVM::default();
        let mut c = Bucket::from(&vm);
        assert!(matches!(
            c.initialize(Address::ZERO, REGISTRY),
            Err(BucketError::ZeroAddress(_))
        ));
        assert!(matches!(
            c.initialize(OWNER, Address::ZERO),
            Err(BucketError::ZeroAddress(_))
        ));
    }

    // ── Registry-only mutation ────────────────────────────────────────────────

    #[test]
    fn non_registry_cannot_mutate() {
        let (vm, mut c) = setup();
        vm.set_sender(STRANGER);
        assert!(matches!(
            c.register_schema("music".into(), "cid".into(), "agent".into()),
            Err(BucketError::NotRegistry(_))
        ));
    }

    // ── Schema lifecycle ──────────────────────────────────────────────────────

    #[test]
    fn schema_lifecycle() {
        let (_, mut c) = setup();
        let id = c
            .register_schema("music".into(), "cid1".into(), "agentA".into())
            .unwrap();
        assert_eq!(id, keccak256(b"music"));
        assert!(c.schema_exists(id));

        let (name, spec, agent) = c.get_schema("music".into()).unwrap();
        assert_eq!(name, "music");
        assert_eq!(spec, "cid1");
        assert_eq!(agent, "agentA");

        c.update_schema_agent("music".into(), "agentB".into())
            .unwrap();
        let (_, _, agent) = c.get_schema("music".into()).unwrap();
        assert_eq!(agent, "agentB");

        c.delete_schema("music".into()).unwrap();
        assert!(!c.schema_exists(id));
        assert!(c.get_schema("music".into()).is_err());
    }

    #[test]
    fn duplicate_schema_fails() {
        let (_, mut c) = setup();
        c.register_schema("music".into(), "cid".into(), "a".into())
            .unwrap();
        assert!(matches!(
            c.register_schema("music".into(), "cid".into(), "a".into()),
            Err(BucketError::SchemaAlreadyExists(_))
        ));
    }

    #[test]
    fn update_missing_schema_fails() {
        let (_, mut c) = setup();
        assert!(matches!(
            c.update_schema_agent("nope".into(), "y".into()),
            Err(BucketError::SchemaNotFound(_))
        ));
    }

    #[test]
    fn delete_schema_with_datasource_fails() {
        let (_, mut c) = setup();
        c.register_schema("music".into(), "cid".into(), "a".into())
            .unwrap();
        c.publish("m".into(), FixedBytes::new([9u8; 32]), "music".into(), "song".into())
            .unwrap();
        assert!(matches!(
            c.delete_schema("music".into()),
            Err(BucketError::SchemaInUse(_))
        ));
    }

    // ── Datasource lifecycle ──────────────────────────────────────────────────

    #[test]
    fn datasource_lifecycle_and_version_increments() {
        let (_, mut c) = setup();
        c.register_schema("music".into(), "cid".into(), "a".into())
            .unwrap();

        assert_eq!(c.get_version("music".into(), "song".into()), 0);

        let root1 = FixedBytes::new([1u8; 32]);
        c.publish("cidA".into(), root1, "music".into(), "song".into())
            .unwrap();
        assert_eq!(c.get_version("music".into(), "song".into()), 1);

        let (cid, root) = c.get("music".into(), "song".into()).unwrap();
        assert_eq!(cid, "cidA");
        assert_eq!(root, root1);

        let root2 = FixedBytes::new([2u8; 32]);
        c.publish("cidB".into(), root2, "music".into(), "song".into())
            .unwrap();
        assert_eq!(c.get_version("music".into(), "song".into()), 2);
        assert_eq!(c.get_merkle_root("music".into(), "song".into()), root2);

        assert_eq!(c.get_name("music".into(), keccak256(b"song")), "song");
    }

    #[test]
    fn publish_requires_existing_schema() {
        let (_, mut c) = setup();
        assert!(matches!(
            c.publish("m".into(), FixedBytes::ZERO, "ghost".into(), "n".into()),
            Err(BucketError::SchemaNotFound(_))
        ));
    }

    #[test]
    fn publish_requires_name() {
        let (_, mut c) = setup();
        c.register_schema("music".into(), "cid".into(), "a".into())
            .unwrap();
        assert!(matches!(
            c.publish("m".into(), FixedBytes::ZERO, "music".into(), "".into()),
            Err(BucketError::NameRequired(_))
        ));
    }

    #[test]
    fn get_missing_datasource_fails() {
        let (_, c) = setup();
        assert!(c.get("music".into(), "song".into()).is_err());
    }

    // ── Resource id ───────────────────────────────────────────────────────────

    #[test]
    fn resource_id_deterministic() {
        let (_, c) = setup();
        let id = keccak256(b"music");
        assert_eq!(
            c.resource_id(id, "song".into()),
            c.resource_id(id, "song".into())
        );
    }

    #[test]
    fn resource_id_unique_per_name_and_schema() {
        let (_, c) = setup();
        let a = keccak256(b"schemaA");
        let b = keccak256(b"schemaB");
        assert_ne!(
            c.resource_id(a, "song".into()),
            c.resource_id(a, "album".into())
        );
        assert_ne!(
            c.resource_id(a, "song".into()),
            c.resource_id(b, "song".into())
        );
    }

    #[test]
    fn resource_id_matches_derivation() {
        let (vm, c) = setup();
        let id = keccak256(b"music");
        let expected = derive_resource_id(
            vm.contract_address(),
            id,
            keccak256(b"song"),
        );
        assert_eq!(c.resource_id(id, "song".into()), expected);
    }
}
