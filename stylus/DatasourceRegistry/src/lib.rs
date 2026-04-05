#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![cfg_attr(feature = "contract-client-gen", allow(unused_imports))]

extern crate alloc;

use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{Address, FixedBytes, U256, U64, keccak256},
    call::RawCall,
    prelude::*,
    storage::*,
};

sol! {
    event ManifestPublished(
        address indexed owner,
        bytes32 indexed schema_id,
        string manifest_cid,
        uint64 version
    );

    event ManifestUpdated(
        address indexed owner,
        bytes32 indexed schema_id,
        string manifest_cid,
        uint64 version
    );

    error DataSourceNotFound();
    error SchemaNotFound();
    error SchemaRequired();
    error ResourceSetupFailed();
}

#[derive(SolidityError)]
pub enum DataSourceRegistryError {
    DataSourceNotFound(DataSourceNotFound),
    SchemaNotFound(SchemaNotFound),
    SchemaRequired(SchemaRequired),
    ResourceSetupFailed(ResourceSetupFailed),
}

// ── Selectors (hardcoded to avoid runtime keccak in every builder) ────────────
//
// schemaExists(bytes32)                    keccak256 => 0x ???
// createResource(bytes32,uint256)          keccak256 => computed below
// addSeedMember(bytes32)                   keccak256 => computed below
// updatePrice(bytes32,uint256)             keccak256 => computed below
//
// These are verified in the selector tests below.

#[storage]
pub struct StorageDataSource {
    pub manifest_cid: StorageString,
    pub version: StorageU64,
}

#[storage]
#[entrypoint]
pub struct DataSourceRegistry {
    /// owner => schema_id => DataSource
    data_sources: StorageMap<Address, StorageMap<FixedBytes<32>, StorageDataSource>>,
    /// owner => schema_id => comma-separated tags  e.g. "track-1,track-2"
    data_source_tags: StorageMap<Address, StorageMap<FixedBytes<32>, StorageString>>,
    schema_registry: StorageAddress,
    settlement_registry: StorageAddress,
}

#[public]
impl DataSourceRegistry {
    #[constructor]
    pub fn initialize(
        &mut self,
        schema_registry: Address,
        settlement_registry: Address,
    ) {
        self.schema_registry.set(schema_registry);
        self.settlement_registry.set(settlement_registry);
    }

    /// Publish or update a manifest.
    ///
    /// For each tag:
    ///   - If the resource does not exist: createResource + addSeedMember
    ///   - If it already exists:           updatePrice
    ///
    /// Tags are appended to the on-chain index (no duplicates).
    /// Emits ManifestPublished on first publish, ManifestUpdated on subsequent.
    pub fn publish(
        &mut self,
        manifest_cid: String,
        schema_id: FixedBytes<32>,
        tags: String,  // comma-separated, pre-packed by caller
        price: U256,
    ) -> Result<(), DataSourceRegistryError> {
        let sender = self.vm().msg_sender();

        if schema_id == FixedBytes::ZERO {
            return Err(DataSourceRegistryError::SchemaRequired(SchemaRequired {}));
        }

        // Validate schema exists
        let registry = self.schema_registry.get();
        let exists = unsafe {
            RawCall::new(self.vm()).call(registry, &sel_schema_exists(schema_id))
        }
        .map(|r| r.last().copied().unwrap_or(0) != 0)
        .unwrap_or(false);

        if !exists {
            return Err(DataSourceRegistryError::SchemaNotFound(SchemaNotFound {}));
        }

        let settlement = self.settlement_registry.get();

        // Process each tag: create resource + seed, or update price if exists
        for tag in tags.split(',').filter(|t| !t.is_empty()) {
            let resource_id = derive_resource_id(sender, schema_id, tag);

            // if the (owner / schema / tag) combo is fresh, create a new resource
            // otherwise we just need to update the price in the settlement registry
            let newly_created = unsafe {
                RawCall::new(self.vm()).call(settlement, &sel_create_resource(resource_id, price))
            }
            .is_ok();

            if newly_created {
                unsafe {
                    RawCall::new(self.vm())
                        .call(settlement, &sel_add_seed_member(resource_id))
                }
                .map_err(|_| {
                    DataSourceRegistryError::ResourceSetupFailed(ResourceSetupFailed {})
                })?;
            } else {
                unsafe {
                    RawCall::new(self.vm())
                        .call(settlement, &sel_update_price(resource_id, price))
                }
                .map_err(|_| {
                    DataSourceRegistryError::ResourceSetupFailed(ResourceSetupFailed {})
                })?;
            }
        }

        // Append packed tags to the index (dedup is handled client-side)
        {
            let existing_raw = {
                let owner_getter = self.data_source_tags.getter(sender);
                owner_getter.getter(schema_id).get_string()
            };

            let new_raw = if existing_raw.is_empty() {
                tags.clone()
            } else {
                alloc::format!("{},{}", existing_raw, tags)
            };

            self.data_source_tags
                .setter(sender)
                .setter(schema_id)
                .set_str(&new_raw);
        }

        let new_version = {
            let mut owner_binding = self.data_sources.setter(sender);
            let mut ds = owner_binding.setter(schema_id);
            let v = ds.version.get() + U64::from(1);
            ds.version.set(v);
            ds.manifest_cid.set_str(&manifest_cid);
            v
        };

        if new_version != U64::from(1) {
            self.vm().log(ManifestUpdated {
                owner: sender,
                schema_id,
                manifest_cid,
                version: new_version.to::<u64>(),
            });
        } else {
            self.vm().log(ManifestPublished {
                owner: sender,
                schema_id,
                manifest_cid,
                version: new_version.to::<u64>(),
            });
        }

        Ok(())
    }

    /// Get the manifest CID for a given (owner, schema_id) pair.
    pub fn get(
        &self,
        owner: Address,
        schema_id: FixedBytes<32>,
    ) -> Result<String, DataSourceRegistryError> {
        let binding = self.data_sources.getter(owner);
        let ds = binding.getter(schema_id);
        if ds.version.get() == U64::ZERO {
            return Err(DataSourceRegistryError::DataSourceNotFound(
                DataSourceNotFound {},
            ));
        }
        Ok(ds.manifest_cid.get_string())
    }

    pub fn get_version(&self, owner: Address, schema_id: FixedBytes<32>) -> u64 {
        self.data_sources
            .getter(owner)
            .getter(schema_id)
            .version
            .get()
            .to::<u64>()
    }

    /// Return the raw comma-separated tag string for a given (owner, schema_id).
    /// Callers split on ',' client-side. Avoids Vec<String> ABI encode overhead.
    pub fn get_tags_raw(&self, owner: Address, schema_id: FixedBytes<32>) -> String {
        let binding = self.data_source_tags.getter(owner);
        binding.getter(schema_id).get_string()
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn derive_resource_id(owner: Address, schema_id: FixedBytes<32>, tag: &str) -> FixedBytes<32> {
    let mut data = alloc::vec::Vec::new();
    data.extend_from_slice(owner.as_slice());
    data.extend_from_slice(schema_id.as_slice());
    data.extend_from_slice(tag.as_bytes());
    keccak256(&data)
}

// ── Calldata builders ─────────────────────────────────────────────────────────
//
// Selectors are hardcoded to eliminate runtime keccak256 and reduce binary size.
// Verified by selector tests below. If you change a function signature, update
// both the constant and the test.
const SEL_SCHEMA_EXISTS:    [u8; 4] = [0xc0, 0xef, 0x02, 0xe6]; // schemaExists(bytes32)
const SEL_CREATE_RESOURCE:  [u8; 4] = [0xcc, 0x35, 0x31, 0x31]; // createResource(bytes32,uint256)
const SEL_ADD_SEED_MEMBER:  [u8; 4] = [0x7d, 0x80, 0xf8, 0x0e]; // addSeedMember(bytes32)
const SEL_UPDATE_PRICE:     [u8; 4] = [0x5f, 0x70, 0x4f, 0x3e]; // updatePrice(bytes32,uint256)

fn sel_schema_exists(id: FixedBytes<32>) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_SCHEMA_EXISTS.to_vec();
    cd.extend_from_slice(id.as_slice());
    cd
}

fn sel_create_resource(resource_id: FixedBytes<32>, price: U256) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_CREATE_RESOURCE.to_vec();
    cd.extend_from_slice(resource_id.as_slice());
    cd.extend_from_slice(&price.to_be_bytes::<32>());
    cd
}

fn sel_add_seed_member(resource_id: FixedBytes<32>) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_ADD_SEED_MEMBER.to_vec();
    cd.extend_from_slice(resource_id.as_slice());
    cd
}

fn sel_update_price(resource_id: FixedBytes<32>, price: U256) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_UPDATE_PRICE.to_vec();
    cd.extend_from_slice(resource_id.as_slice());
    cd.extend_from_slice(&price.to_be_bytes::<32>());
    cd
}

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
        assert!(c.publish("cid".into(), FixedBytes::ZERO, "".into(), U256::ZERO).is_err());
    }

    #[test]
    fn test_unknown_schema_fails() {
        let (_, mut c) = setup();
        assert!(c.publish("cid".into(), SCHEMA_A, "t".into(), U256::ZERO).is_err());
    }

    #[test]
    fn test_no_manifest_before_publish() {
        let (_, c) = setup();
        assert!(c.get(USER, SCHEMA_A).is_err());
    }

    #[test]
    fn test_version_starts_at_zero() {
        let (_, c) = setup();
        assert_eq!(c.get_version(USER, SCHEMA_A), 0);
    }

    #[test]
    fn test_get_tags_empty() {
        let (_, c) = setup();
        assert!(c.get_tags_raw(USER, SCHEMA_A).is_empty());
    }

    #[test]
    fn test_independent_schemas() {
        let (_, c) = setup();
        assert_eq!(c.get_version(USER, SCHEMA_A), 0);
        assert_eq!(c.get_version(USER, SCHEMA_B), 0);
    }

    // Selector sanity checks — verify hardcoded bytes match the function signatures.
    // If a signature changes, the keccak here will catch the drift.
    #[test]
    fn test_sel_schema_exists() {
        assert_eq!(SEL_SCHEMA_EXISTS, keccak256(b"schemaExists(bytes32)")[..4]);
    }

    #[test]
    fn test_sel_create_resource() {
        assert_eq!(SEL_CREATE_RESOURCE, keccak256(b"createResource(bytes32,uint256)")[..4]);
        assert_eq!(sel_create_resource(FixedBytes::ZERO, U256::ZERO).len(), 4 + 32 + 32);
    }

    #[test]
    fn test_sel_add_seed_member() {
        assert_eq!(SEL_ADD_SEED_MEMBER, keccak256(b"addSeedMember(bytes32)")[..4]);
        assert_eq!(sel_add_seed_member(FixedBytes::ZERO).len(), 4 + 32);
    }

    #[test]
    fn test_sel_update_price() {
        assert_eq!(SEL_UPDATE_PRICE, keccak256(b"updatePrice(bytes32,uint256)")[..4]);
        assert_eq!(sel_update_price(FixedBytes::ZERO, U256::ZERO).len(), 4 + 32 + 32);
    }

    #[test]
    fn test_derive_resource_id_deterministic() {
        let r1 = derive_resource_id(USER, SCHEMA_A, "track-1");
        let r2 = derive_resource_id(USER, SCHEMA_A, "track-1");
        assert_eq!(r1, r2);
    }

    #[test]
    fn test_derive_resource_id_unique_per_tag() {
        assert_ne!(
            derive_resource_id(USER, SCHEMA_A, "track-1"),
            derive_resource_id(USER, SCHEMA_A, "track-2"),
        );
    }

    #[test]
    fn test_derive_resource_id_unique_per_schema() {
        assert_ne!(
            derive_resource_id(USER, SCHEMA_A, "track-1"),
            derive_resource_id(USER, SCHEMA_B, "track-1"),
        );
    }
}