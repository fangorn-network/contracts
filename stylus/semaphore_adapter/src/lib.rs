#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{Address, U256, keccak256},
    call::RawCall,
    prelude::*,
    storage::*,
};

// ── Add to Cargo.toml ─────────────────────────────────────────────────────────
// [profile.release]
// codegen-units = 1
// strip        = true
// lto          = "fat"
// opt-level    = "z"
// panic        = "abort"
// ──────────────────────────────────────────────────────────────────────────────

sol! {
    error GroupCreationFailed();
    error AddMemberFailed();
    error VerificationFailed();
    error InvalidReturn();
}

#[derive(SolidityError)]
pub enum AdapterError {
    GroupCreationFailed(GroupCreationFailed),
    AddMemberFailed(AddMemberFailed),
    VerificationFailed(VerificationFailed),
    InvalidReturn(InvalidReturn),
}

// Selectors against Semaphore V4 (verified in tests)
const SEL_CREATE_GROUP:   [u8; 4] = [0x5c, 0x3f, 0x3b, 0x60]; // createGroup(address)
const SEL_ADD_MEMBER:     [u8; 4] = [0x17, 0x83, 0xef, 0xc3]; // addMember(uint256,uint256)
const SEL_VALIDATE_PROOF: [u8; 4] = [0xd0, 0xd8, 0x98, 0xdd]; // validateProof(uint256,(uint256,uint256,uint256,uint256,uint256,uint256[8]))

#[storage]
#[entrypoint]
pub struct SemaphoreAdapter {
    semaphore_address: StorageAddress,
}

#[public]
impl SemaphoreAdapter {
    #[constructor]
    pub fn init(&mut self, semaphore_address: Address) {
        self.semaphore_address.set(semaphore_address);
    }

    /// Create a new Semaphore group administered by the caller.
    /// Returns the new group id.
    pub fn create_group(&mut self) -> Result<U256, AdapterError> {
        // The Semaphore V4 createGroup expects the admin as an argument —
        // we pass through msg_sender so the caller controls the group.
        let admin = self.vm().msg_sender();
        let ret = unsafe {
            RawCall::new(self.vm())
                .call(self.semaphore_address.get(), &sel_create_group(admin))
        }
        .map_err(|_| AdapterError::GroupCreationFailed(GroupCreationFailed {}))?;

        if ret.len() < 32 {
            return Err(AdapterError::InvalidReturn(InvalidReturn {}));
        }
        Ok(U256::from_be_slice(&ret[..32]))
    }

    /// Add a member (identity commitment) to a group.
    /// The caller must be the group admin on Semaphore.
    pub fn add_member(&mut self, group_id: U256, commitment: U256) -> Result<(), AdapterError> {
        unsafe {
            RawCall::new(self.vm())
                .call(self.semaphore_address.get(), &sel_add_member(group_id, commitment))
        }
        .map_err(|_| AdapterError::AddMemberFailed(AddMemberFailed {}))?;
        Ok(())
    }

    /// Validate a Semaphore proof. Caller is responsible for nullifier
    /// tracking; this just verifies the proof against the tree root.
    pub fn validate_proof(
        &mut self,
        group_id: U256,
        merkle_tree_depth: U256,
        merkle_tree_root: U256,
        nullifier: U256,
        message: U256,
        scope: U256,
        points: [U256; 8],
    ) -> Result<(), AdapterError> {
        unsafe {
            RawCall::new(self.vm()).call(
                self.semaphore_address.get(),
                &sel_validate_proof(
                    group_id, merkle_tree_depth, merkle_tree_root,
                    nullifier, message, scope, &points,
                ),
            )
        }
        .map_err(|_| AdapterError::VerificationFailed(VerificationFailed {}))?;
        Ok(())
    }

    pub fn get_semaphore_address(&self) -> Address {
        self.semaphore_address.get()
    }
}

// ── Calldata encoding ─────────────────────────────────────────────────────────

#[inline(never)]
fn sel_create_group(admin: Address) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_CREATE_GROUP.to_vec();
    cd.extend_from_slice(&[0u8; 12]);
    cd.extend_from_slice(admin.as_slice());
    cd
}

#[inline(never)]
fn sel_add_member(group_id: U256, commitment: U256) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_ADD_MEMBER.to_vec();
    cd.extend_from_slice(&group_id.to_be_bytes::<32>());
    cd.extend_from_slice(&commitment.to_be_bytes::<32>());
    cd
}

#[inline(never)]
fn sel_validate_proof(
    group_id: U256, depth: U256, root: U256,
    nullifier: U256, message: U256, scope: U256,
    points: &[U256; 8],
) -> alloc::vec::Vec<u8> {
    let mut cd = SEL_VALIDATE_PROOF.to_vec();
    cd.extend_from_slice(&group_id.to_be_bytes::<32>());
    cd.extend_from_slice(&depth.to_be_bytes::<32>());
    cd.extend_from_slice(&root.to_be_bytes::<32>());
    cd.extend_from_slice(&nullifier.to_be_bytes::<32>());
    cd.extend_from_slice(&message.to_be_bytes::<32>());
    cd.extend_from_slice(&scope.to_be_bytes::<32>());
    for p in points {
        cd.extend_from_slice(&p.to_be_bytes::<32>());
    }
    cd
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use stylus_sdk::alloy_primitives::keccak256;

    #[test]
    fn test_const_selectors() {
        assert_eq!(SEL_CREATE_GROUP,   keccak256(b"createGroup(address)")[..4]);
        assert_eq!(SEL_ADD_MEMBER,     keccak256(b"addMember(uint256,uint256)")[..4]);
        assert_eq!(
            SEL_VALIDATE_PROOF,
            keccak256(b"validateProof(uint256,(uint256,uint256,uint256,uint256,uint256,uint256[8]))")[..4]
        );
    }

    #[test]
    fn test_sel_add_member_length() {
        let cd = sel_add_member(U256::ZERO, U256::ZERO);
        assert_eq!(cd.len(), 68);
        assert_eq!(&cd[..4], &SEL_ADD_MEMBER);
    }

    #[test]
    fn test_sel_validate_proof_length() {
        let cd = sel_validate_proof(
            U256::ZERO, U256::ZERO, U256::ZERO,
            U256::ZERO, U256::ZERO, U256::ZERO,
            &[U256::ZERO; 8],
        );
        assert_eq!(cd.len(), 452);
        assert_eq!(&cd[..4], &SEL_VALIDATE_PROOF);
    }

    #[test]
    fn test_validate_proof_field_order() {
        let cd = sel_validate_proof(
            U256::from(1u64), U256::from(2u64), U256::from(3u64),
            U256::from(4u64), U256::from(5u64), U256::from(6u64),
            &[U256::from(7u64); 8],
        );
        assert_eq!(U256::from_be_slice(&cd[4..36]),   U256::from(1u64));
        assert_eq!(U256::from_be_slice(&cd[36..68]),  U256::from(2u64));
        assert_eq!(U256::from_be_slice(&cd[164..196]),U256::from(6u64), "scope");
    }
}