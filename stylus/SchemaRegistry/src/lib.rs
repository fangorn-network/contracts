#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![cfg_attr(feature = "contract-client-gen", allow(unused_imports))]

extern crate alloc;

use alloy_sol_types::sol;
use alloc::fmt;
use stylus_sdk::{
    alloy_primitives::{Address, FixedBytes, keccak256},
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
    error NotDataSourceRegistry();
}

#[derive(SolidityError)]
pub enum RegistryError {
    NotOwner(NotOwner),
    SchemaNotFound(SchemaNotFound),
    SchemaAlreadyExists(SchemaAlreadyExists),
    NotDataSourceRegistry(NotDataSourceRegistry),
}

// for testing
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
    schemas: StorageMap<FixedBytes<32>, StorageSchema>,
    /// schema_id => comma-separated lowercase hex publisher addresses
    /// e.g. "0xabc...,0xdef..."
    publishers: StorageMap<FixedBytes<32>, StorageString>,
}

#[public]
impl SchemaRegistry {

    #[constructor]
    pub fn initialize(&mut self) { }

    /// Expose id derivation as a pure view so callers can cache it.
    pub fn schema_id(&self, name: String) -> FixedBytes<32> {
        schema_id_from_name(name)
    }

    /// Register a new schema. ID is derived from name so it's deterministic.
    /// Note: all schemas must have unique names!
    ///
    /// * `name`:     The human-readable schema name
    /// * `spec_cid`: The CID of the schema json
    /// * `agent_id`: The option agent Id
    ///
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

        self.vm().log(SchemaRegistered { id, owner: sender, name, spec_cid, agent_id });

        Ok(id)
    }

    /// Update the spec CID and agent ID of an existing schema (owner only).
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

        self.vm().log(SchemaUpdated { id, new_spec_cid, new_agent_id });

        Ok(())
    }

    /// Return all publisher addresses for a schema.
    pub fn get_publishers(&self, schema_id: FixedBytes<32>) -> Vec<Address> {
        let binding = self.publishers.getter(schema_id);
        let raw = binding.get_string();
        if raw.is_empty() {
            return alloc::vec::Vec::new();
        }
        raw.split(',')
            .filter_map(|s| hex_to_address(s))
            .collect()
    }

    /// Get the spec CID for a schema by id.
    pub fn get_schema_spec(&self, id: FixedBytes<32>) -> Result<String, RegistryError> {
        if self.schemas.getter(id).owner.get() == Address::ZERO {
            return Err(RegistryError::SchemaNotFound(SchemaNotFound {}));
        }
        Ok(self.schemas.getter(id).spec_cid.get_string())
    }

    /// Get the agent ID for a schema by id.
    pub fn get_schema_agent(&self, id: FixedBytes<32>) -> Result<String, RegistryError> {
        if self.schemas.getter(id).owner.get() == Address::ZERO {
            return Err(RegistryError::SchemaNotFound(SchemaNotFound {}));
        }
        Ok(self.schemas.getter(id).agent_id.get_string())
    }

    /// Check whether a schema exists by its bytes32 id (used by DataSourceRegistry).
    pub fn schema_exists(&self, id: FixedBytes<32>) -> bool {
        self.schemas.getter(id).owner.get() != Address::ZERO
    }
}

// helper functions

pub fn schema_id_from_name(name: String) -> FixedBytes<32> {
    use alloy_sol_types::SolValue;
    keccak256(name.abi_encode())
}

/// Encode an Address as a lowercase hex string with 0x prefix.
/// Used as the storage representation in the publishers packed string.
fn address_to_hex(addr: Address) -> alloc::string::String {
    let bytes = addr.as_slice();
    let mut s = alloc::string::String::with_capacity(42);
    s.push_str("0x");
    for b in bytes {
        let hi = (b >> 4) as usize;
        let lo = (b & 0xf) as usize;
        s.push(HEX_CHARS[hi]);
        s.push(HEX_CHARS[lo]);
    }
    s
}

const HEX_CHARS: [char; 16] = [
    '0', '1', '2', '3', '4', '5', '6', '7',
    '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
];

/// Parse a 0x-prefixed hex string back into an Address. Returns None on malformed input.
fn hex_to_address(s: &str) -> Option<Address> {
    let hex = s.strip_prefix("0x")?;
    if hex.len() != 40 {
        return None;
    }
    let mut bytes = [0u8; 20];
    for (i, chunk) in hex.as_bytes().chunks(2).enumerate() {
        let hi = hex_nibble(chunk[0])?;
        let lo = hex_nibble(chunk[1])?;
        bytes[i] = (hi << 4) | lo;
    }
    Some(Address::from(bytes))
}

fn hex_nibble(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod test {
    use super::*;
    use alloy_primitives::address;
    use stylus_sdk::testing::*;

    const USER: Address  = address!("0xCDC41bff86a62716f050622325CC17a317f99404");
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
        contract.register_schema(
            "fangorn.music.v1".to_string(),
            "bafy...schema".to_string(),
            "agent_id".to_string(),
        ).unwrap()
    }

    #[test]
    fn test_schema_registration_works() {
        let (_, mut contract) = setup();
        let id = register(&mut contract);
        assert!(contract.schema_exists(id));
        assert_eq!(contract.get_schema_spec(id).unwrap(), "bafy...schema");
        assert_eq!(contract.get_schema_agent(id).unwrap(), "agent_id");
    }

    #[test]
    fn test_duplicate_schema_fails() {
        let (_, mut contract) = setup();
        register(&mut contract);
        assert!(contract.register_schema(
            "fangorn.music.v1".to_string(),
            "bafy...schema2".to_string(),
            "agent_id2".to_string(),
        ).is_err());
    }

    #[test]
    fn test_schema_update_not_owner_fails() {
        let (vm, mut contract) = setup();
        let id = register(&mut contract);
        vm.set_sender(OTHER);
        assert!(contract.update_schema(id, "bafy...new".to_string(), "agent-new".to_string()).is_err());
    }

    #[test]
    fn test_schema_update_owner_succeeds() {
        let (_, mut contract) = setup();
        let id = register(&mut contract);
        contract.update_schema(id, "bafy...new".to_string(), "agent-new".to_string()).unwrap();
        assert_eq!(contract.get_schema_spec(id).unwrap(), "bafy...new");
        assert_eq!(contract.get_schema_agent(id).unwrap(), "agent-new");
    }

    #[test]
    fn test_add_publisher_requires_ds_registry() {
        let (_, mut contract) = setup();
        let id = register(&mut contract);
        // USER is not the DS registry — must fail
        assert!(contract.add_publisher(id, OTHER).is_err());
    }

    #[test]
    fn test_add_publisher_succeeds_from_ds_registry() {
        let (vm, mut contract) = setup();
        let id = register(&mut contract);
        vm.set_sender(DS_REGISTRY);
        contract.add_publisher(id, USER).unwrap();
        let publishers = contract.get_publishers(id);
        assert_eq!(publishers.len(), 1);
        assert_eq!(publishers[0], USER);
    }

    #[test]
    fn test_add_publisher_deduplicates() {
        let (vm, mut contract) = setup();
        let id = register(&mut contract);
        vm.set_sender(DS_REGISTRY);
        contract.add_publisher(id, USER).unwrap();
        contract.add_publisher(id, USER).unwrap();
        assert_eq!(contract.get_publishers(id).len(), 1);
    }

    #[test]
    fn test_add_multiple_publishers() {
        let (vm, mut contract) = setup();
        let id = register(&mut contract);
        vm.set_sender(DS_REGISTRY);
        contract.add_publisher(id, USER).unwrap();
        contract.add_publisher(id, OTHER).unwrap();
        let publishers = contract.get_publishers(id);
        assert_eq!(publishers.len(), 2);
        assert!(publishers.contains(&USER));
        assert!(publishers.contains(&OTHER));
    }

    #[test]
    fn test_get_publishers_empty() {
        let (_, mut contract) = setup();
        let id = register(&mut contract);
        assert!(contract.get_publishers(id).is_empty());
    }

    #[test]
    fn test_address_roundtrip() {
        let hex = address_to_hex(USER);
        assert!(hex.starts_with("0x"));
        assert_eq!(hex.len(), 42);
        assert_eq!(hex_to_address(&hex).unwrap(), USER);
    }
}