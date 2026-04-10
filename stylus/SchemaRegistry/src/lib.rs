#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![cfg_attr(feature = "contract-client-gen", allow(unused_imports))]

extern crate alloc;

use alloc::fmt;
use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{keccak256, Address, FixedBytes, U256},
    prelude::*,
    storage::*,
};

sol! {
    event SchemaRegistered(
        bytes32 indexed id,
        address indexed owner,
        string name,
        string spec_cid,
        string agent_id
    );

    event SchemaUpdated(
        bytes32 indexed id,
        string new_spec_cid,
        string new_agent_id
    );

    event PublisherAdded(
        bytes32 indexed schema_id,
        address indexed publisher
    );

    error NotOwner();
    error SchemaNotFound();
    error SchemaAlreadyExists();
    error SchemaInUse();
    error NotDataSourceRegistry();
}

#[derive(SolidityError)]
pub enum RegistryError {
    NotOwner(NotOwner),
    SchemaNotFound(SchemaNotFound),
    SchemaAlreadyExists(SchemaAlreadyExists),
    SchemaInUse(SchemaInUse),
    NotDataSourceRegistry(NotDataSourceRegistry),
}

impl fmt::Debug for RegistryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "RegistryError")
    }
}

#[storage]
pub struct StorageSchema {
    pub name: StorageString,
    pub spec_cid: StorageString,
    pub agent_id: StorageString,
    pub owner: StorageAddress,
}

#[storage]
#[entrypoint]
pub struct SchemaRegistry {
    admin: StorageAddress,
    schemas: StorageMap<FixedBytes<32>, StorageSchema>,
    publisher_count: StorageMap<FixedBytes<32>, StorageU256>,
    publisher_set: StorageMap<FixedBytes<32>, StorageMap<Address, StorageBool>>,
    data_source_registry: StorageAddress,
}

#[public]
impl SchemaRegistry {
    #[constructor]
    pub fn initialize(&mut self, admin: Address) {
        self.admin.set(admin);
    }

    pub fn set_data_source_registry(&mut self, registry: Address) -> Result<(), RegistryError> {
        if self.vm().msg_sender() != self.admin.get() {
            return Err(RegistryError::NotOwner(NotOwner {}));
        }
        // only allow setting once
        if self.data_source_registry.get() != Address::ZERO {
            return Err(RegistryError::SchemaAlreadyExists(SchemaAlreadyExists {}));
            // reuse or add a new error
        }
        self.data_source_registry.set(registry);
        Ok(())
    }

    pub fn schema_id(&self, name: String) -> FixedBytes<32> {
        schema_id_from_name(name)
    }

    pub fn register_schema(
        &mut self,
        name: String,
        spec_cid: String,
        agent_id: String,
    ) -> Result<FixedBytes<32>, RegistryError> {
        let sender = self.vm().msg_sender();
        let id = schema_id_from_name(name.clone());

        if self.schemas.getter(id).owner.get() != Address::ZERO {
            return Err(RegistryError::SchemaAlreadyExists(SchemaAlreadyExists {}));
        }

        let mut schema = self.schemas.setter(id);
        schema.name.set_str(&name);
        schema.spec_cid.set_str(&spec_cid);
        schema.agent_id.set_str(&agent_id);
        schema.owner.set(sender);

        self.vm().log(SchemaRegistered {
            id,
            owner: sender,
            name,
            spec_cid,
            agent_id,
        });
        Ok(id)
    }

    pub fn update_schema(
        &mut self,
        id: FixedBytes<32>,
        new_spec_cid: String,
        new_agent_id: String,
    ) -> Result<(), RegistryError> {
        let sender = self.vm().msg_sender();
        let owner = self.schemas.getter(id).owner.get();

        if owner == Address::ZERO {
            return Err(RegistryError::SchemaNotFound(SchemaNotFound {}));
        }
        if owner != sender {
            return Err(RegistryError::NotOwner(NotOwner {}));
        }

        let mut schema = self.schemas.setter(id);
        schema.spec_cid.set_str(&new_spec_cid);
        schema.agent_id.set_str(&new_agent_id);

        self.vm().log(SchemaUpdated {
            id,
            new_spec_cid,
            new_agent_id,
        });
        Ok(())
    }

    pub fn delete_schema(&mut self, id: FixedBytes<32>) -> Result<(), RegistryError> {
        let sender = self.vm().msg_sender();
        let owner = self.schemas.getter(id).owner.get();

        if owner == Address::ZERO {
            return Err(RegistryError::SchemaNotFound(SchemaNotFound {}));
        }
        if owner != sender {
            return Err(RegistryError::NotOwner(NotOwner {}));
        }
        if self.publisher_count.get(id) > U256::ZERO {
            return Err(RegistryError::SchemaInUse(SchemaInUse {}));
        }

        let mut schema = self.schemas.setter(id);
        schema.name.set_str("");
        schema.spec_cid.set_str("");
        schema.agent_id.set_str("");
        schema.owner.set(Address::ZERO);

        Ok(())
    }

    /// Called by the authorized DataSourceRegistry on first publish.
    /// Idempotent — duplicate calls for the same publisher are no-ops.
    pub fn add_publisher(
        &mut self,
        schema_id: FixedBytes<32>,
        publisher: Address,
    ) -> Result<(), RegistryError> {
        if self.vm().msg_sender() != self.data_source_registry.get() {
            return Err(RegistryError::NotDataSourceRegistry(
                NotDataSourceRegistry {},
            ));
        }
        if self.schemas.getter(schema_id).owner.get() == Address::ZERO {
            return Err(RegistryError::SchemaNotFound(SchemaNotFound {}));
        }
        if !self.publisher_set.getter(schema_id).get(publisher) {
            self.publisher_set
                .setter(schema_id)
                .setter(publisher)
                .set(true);
            let count = self.publisher_count.get(schema_id);
            self.publisher_count
                .setter(schema_id)
                .set(count + U256::from(1u8));
            self.vm().log(PublisherAdded {
                schema_id,
                publisher,
            });
        }
        Ok(())
    }

    pub fn get_admin(&self) -> Address {
        self.admin.get()
    }

    pub fn get_data_source_registry(&self) -> Address {
        self.data_source_registry.get()
    }

    pub fn schema_exists(&self, id: FixedBytes<32>) -> bool {
        self.schemas.getter(id).owner.get() != Address::ZERO
    }

    pub fn has_publishers(&self, schema_id: FixedBytes<32>) -> bool {
        self.publisher_count.get(schema_id) > U256::ZERO
    }

    pub fn is_publisher(&self, schema_id: FixedBytes<32>, publisher: Address) -> bool {
        self.publisher_set.getter(schema_id).get(publisher)
    }

    pub fn get_publisher_count(&self, schema_id: FixedBytes<32>) -> U256 {
        self.publisher_count.get(schema_id)
    }

    pub fn get_schema_spec(&self, id: FixedBytes<32>) -> Result<String, RegistryError> {
        if self.schemas.getter(id).owner.get() == Address::ZERO {
            return Err(RegistryError::SchemaNotFound(SchemaNotFound {}));
        }
        Ok(self.schemas.getter(id).spec_cid.get_string())
    }

    pub fn get_schema_agent(&self, id: FixedBytes<32>) -> Result<String, RegistryError> {
        if self.schemas.getter(id).owner.get() == Address::ZERO {
            return Err(RegistryError::SchemaNotFound(SchemaNotFound {}));
        }
        Ok(self.schemas.getter(id).agent_id.get_string())
    }

    pub fn get_schema_name(&self, id: FixedBytes<32>) -> Result<String, RegistryError> {
        if self.schemas.getter(id).owner.get() == Address::ZERO {
            return Err(RegistryError::SchemaNotFound(SchemaNotFound {}));
        }
        Ok(self.schemas.getter(id).name.get_string())
    }

    pub fn get_schema_owner(&self, id: FixedBytes<32>) -> Result<Address, RegistryError> {
        let owner = self.schemas.getter(id).owner.get();
        if owner == Address::ZERO {
            return Err(RegistryError::SchemaNotFound(SchemaNotFound {}));
        }
        Ok(owner)
    }
}

pub fn schema_id_from_name(name: String) -> FixedBytes<32> {
    use alloy_sol_types::SolValue;
    keccak256(name.abi_encode())
}

#[cfg(test)]
mod test {
    use super::*;
    use alloy_primitives::address;
    use stylus_sdk::testing::*;

    const USER: Address = address!("0xCDC41bff86a62716f050622325CC17a317f99404");
    const OTHER: Address = address!("0xDEADbeefdEAdbeefdEadbEEFdeadbeEFdEADbeeF");
    const DS_REGISTRY: Address = address!("0x1111111111111111111111111111111111111111");

    fn setup() -> (TestVM, SchemaRegistry) {
        let vm = TestVM::default();
        vm.set_sender(USER);
        let mut contract = SchemaRegistry::from(&vm);
        contract.initialize(DS_REGISTRY);
        (vm, contract)
    }

    fn register(contract: &mut SchemaRegistry) -> FixedBytes<32> {
        contract
            .register_schema(
                "fangorn.music.v1".into(),
                "bafy...schema".into(),
                "agent_id".into(),
            )
            .unwrap()
    }

    #[test]
    fn test_schema_registration_works() {
        let (_, mut c) = setup();
        let id = register(&mut c);
        assert!(c.schema_exists(id));
        assert_eq!(c.get_schema_spec(id).unwrap(), "bafy...schema");
        assert_eq!(c.get_schema_agent(id).unwrap(), "agent_id");
        assert_eq!(c.get_schema_name(id).unwrap(), "fangorn.music.v1");
    }

    #[test]
    fn test_duplicate_schema_fails() {
        let (_, mut c) = setup();
        register(&mut c);
        assert!(c
            .register_schema("fangorn.music.v1".into(), "x".into(), "y".into())
            .is_err());
    }

    #[test]
    fn test_update_not_owner_fails() {
        let (vm, mut c) = setup();
        let id = register(&mut c);
        vm.set_sender(OTHER);
        assert!(matches!(
            c.update_schema(id, "new".into(), "new".into()),
            Err(RegistryError::NotOwner(_))
        ));
    }

    #[test]
    fn test_update_owner_succeeds() {
        let (_, mut c) = setup();
        let id = register(&mut c);
        c.update_schema(id, "bafy...new".into(), "agent-new".into())
            .unwrap();
        assert_eq!(c.get_schema_spec(id).unwrap(), "bafy...new");
        assert_eq!(c.get_schema_agent(id).unwrap(), "agent-new");
    }

    #[test]
    fn test_delete_no_publishers() {
        let (_, mut c) = setup();
        let id = register(&mut c);
        c.delete_schema(id).unwrap();
        assert!(!c.schema_exists(id));
    }

    #[test]
    fn test_delete_blocked_when_in_use() {
        let (vm, mut c) = setup();
        let id = register(&mut c);
        vm.set_sender(DS_REGISTRY);
        // set datasource registry
        c.set_data_source_registry(DS_REGISTRY);
        c.add_publisher(id, USER).unwrap();
        vm.set_sender(USER);
        assert!(matches!(
            c.delete_schema(id),
            Err(RegistryError::SchemaInUse(_))
        ));
    }

    #[test]
    fn test_delete_not_owner_fails() {
        let (vm, mut c) = setup();
        let id = register(&mut c);
        vm.set_sender(OTHER);
        assert!(matches!(
            c.delete_schema(id),
            Err(RegistryError::NotOwner(_))
        ));
    }

    #[test]
    fn test_add_publisher_requires_ds_registry() {
        let (_, mut c) = setup();
        let id = register(&mut c);
        assert!(matches!(
            c.add_publisher(id, OTHER),
            Err(RegistryError::NotDataSourceRegistry(_))
        ));
    }

    #[test]
    fn test_add_publisher_succeeds() {
        let (vm, mut c) = setup();
        let id = register(&mut c);
        vm.set_sender(DS_REGISTRY);
        c.set_data_source_registry(DS_REGISTRY);
        c.add_publisher(id, USER).unwrap();
        assert!(c.is_publisher(id, USER));
        assert_eq!(c.get_publisher_count(id), U256::from(1u8));
    }

    #[test]
    fn test_add_publisher_idempotent() {
        let (vm, mut c) = setup();
        let id = register(&mut c);
        vm.set_sender(DS_REGISTRY);
        c.set_data_source_registry(DS_REGISTRY);
        c.add_publisher(id, USER).unwrap();
        c.add_publisher(id, USER).unwrap();
        assert_eq!(c.get_publisher_count(id), U256::from(1u8));
    }

    #[test]
    fn test_add_multiple_publishers() {
        let (vm, mut c) = setup();
        let id = register(&mut c);
        vm.set_sender(DS_REGISTRY);
        c.set_data_source_registry(DS_REGISTRY);
        c.add_publisher(id, USER).unwrap();
        c.add_publisher(id, OTHER).unwrap();
        assert_eq!(c.get_publisher_count(id), U256::from(2u8));
        assert!(c.is_publisher(id, USER));
        assert!(c.is_publisher(id, OTHER));
    }

    #[test]
    fn test_has_publishers() {
        let (vm, mut c) = setup();
        let id = register(&mut c);
        assert!(!c.has_publishers(id));
        vm.set_sender(DS_REGISTRY);
        c.set_data_source_registry(DS_REGISTRY);
        c.add_publisher(id, USER).unwrap();
        assert!(c.has_publishers(id));
    }

    #[test]
    fn test_schema_id_deterministic() {
        let (_, c) = setup();
        assert_eq!(c.schema_id("foo".into()), c.schema_id("foo".into()));
        assert_ne!(c.schema_id("foo".into()), c.schema_id("bar".into()));
    }
}
