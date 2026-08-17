//! AppRegistry
//!
//! An application is essentially a named domain and set of agreements for 
//! associating data with a given top-level app domain.
//! Publishers must *register* with the application in order to be able to write to the app-level namespace
//! in an associated DataRegistry where a specific instance of the AppRegistry is referenced. 
//! See [deploy.sh](../deploy.sh) for an example script of how these are configured.
//!
//!   AppRegistry  ──(no dependencies)
//!        ▲
//!        │ isRegisteredForApp(app_id, sender)
//!   DataRegistry ──▲ isRegistered(publisher)
//!                  │
//!          SubscriptionRegistry
//!

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![cfg_attr(feature = "contract-client-gen", allow(unused_imports))]
extern crate alloc;

use alloc::{fmt, string::String};
use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{keccak256, Address, FixedBytes, U256, U8},
    call::transfer::transfer_eth,
    prelude::*,
    storage::*,
};

const STATUS_UNREGISTERED: u8 = 0;
const STATUS_ACTIVE: u8 = 1;
const STATUS_SUSPENDED: u8 = 2;

sol! {
    error Unauthorized();
    error AppNotFound();
    error AppAlreadyRegistered();
    error TermsNotSet();
    error TermsMismatch();
    error AlreadyRegistered();
    error NotRegistered();
    error PublisherSuspendedErr();
    error JoinFeeRequired();
    error TransferFailed();

    /// An app was registered
    event AppRegistered(bytes32 indexed app_id, address indexed owner);

    /// The app's terms moved. Every publisher on the old hash is dropped back to
    /// "must accept again" by that fact alone — see `isRegisteredForApp`.
    event AppTermsChanged(bytes32 indexed app_id, bytes32 terms_hash, string terms_uri);

    event AppFeeChanged(bytes32 indexed app_id, uint256 fee);

    /// A publisher joined an app AND accepted `terms_hash` by doing so. This event
    /// is the durable, self-verifying record that replaces a line in a log file.
    event PublisherJoined(
        bytes32 indexed app_id,
        address indexed publisher,
        bytes32 terms_hash,
        uint256 fee
    );

    /// An app owner ejected a publisher from their market. Global standing in the
    /// DataRegistry is untouched — this is one market's door, not the network's.
    event PublisherSuspendedForApp(bytes32 indexed app_id, address indexed publisher);

    event PublisherReinstatedForApp(bytes32 indexed app_id, address indexed publisher);
}

#[derive(SolidityError)]
pub enum AppRegistryError {
    Unauthorized(Unauthorized),
    AppNotFound(AppNotFound),
    AppAlreadyRegistered(AppAlreadyRegistered),
    TermsNotSet(TermsNotSet),
    TermsMismatch(TermsMismatch),
    AlreadyRegistered(AlreadyRegistered),
    NotRegistered(NotRegistered),
    PublisherSuspendedErr(PublisherSuspendedErr),
    JoinFeeRequired(JoinFeeRequired),
    TransferFailed(TransferFailed),
}

impl fmt::Debug for AppRegistryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "AppRegistryError")
    }
}

#[storage]
#[entrypoint]
pub struct AppRegistry {
    /// Protocol admin. Can re-point the DataRegistry and rescue stuck ETH, and
    /// deliberately CANNOT set an app's terms or eject its publishers — those
    /// belong to the app owner.
    admin: StorageAddress,
    /// app_id => owner. The canonical answer to "does this app exist and whose is
    /// it", moved here from the DataRegistry so one contract holds an app's
    /// identity, its terms and its membership together.
    apps: StorageMap<FixedBytes<32>, StorageAddress>,
    /// app_id => hash of the app's current publisher terms. Zero means the app has
    /// set none, and registration is refused rather than silently meaning nothing.
    app_terms: StorageMap<FixedBytes<32>, StorageFixedBytes<32>>,
    /// app_id => where those terms can be read. Stored because a hash nobody can
    /// resolve to a document is not terms anyone agreed to.
    app_terms_uri: StorageMap<FixedBytes<32>, StorageString>,
    /// app_id => join fee in wei, paid to the app owner. Zero is normal.
    app_fees: StorageMap<FixedBytes<32>, StorageU256>,
    /// keccak256(app_id ‖ publisher) => lifecycle status.
    statuses: StorageMap<FixedBytes<32>, StorageU8>,
    /// keccak256(app_id ‖ publisher) => the terms hash they actually accepted.
    accepted: StorageMap<FixedBytes<32>, StorageFixedBytes<32>>,
}

#[public]
impl AppRegistry {
    #[constructor]
    pub fn init(&mut self, admin: Address) {
        self.admin.set(admin);
    }

    /// Claim an app id, first-come-first-served and irreversible
    ///
    /// * `app_id`: a unique 32-byte identifier for the app
    /// * `terms_hash`: the CID of the terms and conditions for using the app
    /// * `terms_uri`: A URI where the terms can be found (e.g. an IPFS gateway, an erc-8004 agent card)
    /// * `fee`: a fee for registering as a publisher
    ///
    pub fn register_app(
        &mut self,
        app_id: FixedBytes<32>,
        terms_hash: FixedBytes<32>,
        terms_uri: String,
        fee: U256,
    ) -> Result<(), AppRegistryError> {
        if self.apps.get(app_id) != Address::ZERO {
            return Err(AppRegistryError::AppAlreadyRegistered(AppAlreadyRegistered {}));
        }
        let owner = self.vm().msg_sender();
        self.apps.setter(app_id).set(owner);
        self.app_terms.setter(app_id).set(terms_hash);
        self.app_terms_uri.setter(app_id).set_str(&terms_uri);
        // TODO: introduce a proper treasury
        self.app_fees.setter(app_id).set(fee);
        self.vm().log(AppRegistered { app_id, owner });
        self.vm().log(AppTermsChanged { app_id, terms_hash, terms_uri });
        self.vm().log(AppFeeChanged { app_id, fee });
        Ok(())
    }

    pub fn get_app_owner(&self, app_id: FixedBytes<32>) -> Address {
        self.apps.get(app_id)
    }

    /// Publish (or update) an app's publisher agreement (terms and conditions). 
    /// Only callable by the app owner.
    ///
    /// Danger: Updating this has consequences real consequence: every publisher who accepted
    /// the previous terms becomes unregistered until they accept the
    /// new one.
    pub fn set_app_terms(
        &mut self,
        app_id: FixedBytes<32>,
        terms_hash: FixedBytes<32>,
        terms_uri: String,
    ) -> Result<(), AppRegistryError> {
        self.only_app_owner(app_id)?;
        self.app_terms.setter(app_id).set(terms_hash);
        self.app_terms_uri.setter(app_id).set_str(&terms_uri);
        self.vm().log(AppTermsChanged { app_id, terms_hash, terms_uri });
        Ok(())
    }

    /// Set the app's join fee in wei
    pub fn set_app_fee(&mut self, app_id: FixedBytes<32>, fee: U256) -> Result<(), AppRegistryError> {
        self.only_app_owner(app_id)?;
        self.app_fees.setter(app_id).set(fee);
        self.vm().log(AppFeeChanged { app_id, fee });
        Ok(())
    }

    /// Suspend a publisher from this app. 
    /// The global DataRegistry and their registrations with every other app are untouched.
    pub fn suspend_for_app(
        &mut self,
        app_id: FixedBytes<32>,
        publisher: Address,
    ) -> Result<(), AppRegistryError> {
        self.only_app_owner(app_id)?;
        let key = member_key(app_id, publisher);
        if self.statuses.get(key).to::<u8>() == STATUS_UNREGISTERED {
            return Err(AppRegistryError::NotRegistered(NotRegistered {}));
        }
        self.statuses.setter(key).set(U8::from(STATUS_SUSPENDED));
        self.vm().log(PublisherSuspendedForApp { app_id, publisher });
        Ok(())
    }

    /// Unsuspend a publisher from the app
    pub fn reinstate_for_app(
        &mut self,
        app_id: FixedBytes<32>,
        publisher: Address,
    ) -> Result<(), AppRegistryError> {
        self.only_app_owner(app_id)?;
        let key = member_key(app_id, publisher);
        if self.statuses.get(key).to::<u8>() != STATUS_SUSPENDED {
            return Err(AppRegistryError::NotRegistered(NotRegistered {}));
        }
        self.statuses.setter(key).set(U8::from(STATUS_ACTIVE));
        self.vm().log(PublisherReinstatedForApp { app_id, publisher });
        Ok(())
    }

    /// Register to publish to an app
    /// By registering, you are agreeing to the app terms and conditions.
    #[payable]
    pub fn register_for_app(
        &mut self,
        app_id: FixedBytes<32>,
        terms_hash: FixedBytes<32>,
    ) -> Result<(), AppRegistryError> {
        let owner = self.apps.get(app_id);
        if owner == Address::ZERO {
            return Err(AppRegistryError::AppNotFound(AppNotFound {}));
        }

        // empty terms are invalid
        let current = self.app_terms.get(app_id);
        if current == FixedBytes::<32>::ZERO {
            return Err(AppRegistryError::TermsNotSet(TermsNotSet {}));
        }
        if terms_hash != current {
            return Err(AppRegistryError::TermsMismatch(TermsMismatch {}));
        }

        let sender = self.vm().msg_sender();
        let key = member_key(app_id, sender);
        let status = self.statuses.get(key).to::<u8>();

        // must not be suspended
        if status == STATUS_SUSPENDED {
            return Err(AppRegistryError::PublisherSuspendedErr(PublisherSuspendedErr {}));
        }
        if status == STATUS_ACTIVE && self.accepted.get(key) == current {
            return Err(AppRegistryError::AlreadyRegistered(AlreadyRegistered {}));
        }

        // do not charge registration fee when accepting new publishing terms
        let fee = if status == STATUS_ACTIVE { U256::ZERO } else { self.app_fees.get(app_id) };
        let paid = self.vm().msg_value();
        if paid < fee {
            return Err(AppRegistryError::JoinFeeRequired(JoinFeeRequired {}));
        }

        self.statuses.setter(key).set(U8::from(STATUS_ACTIVE));
        self.accepted.setter(key).set(current);

        // paid directly to app owner
        // TODO: add treausury, take a percent?
        if !paid.is_zero() {
            transfer_eth(self.vm(), owner, paid)
                .map_err(|_| AppRegistryError::TransferFailed(TransferFailed {}))?;
        }

        self.vm().log(PublisherJoined { app_id, publisher: sender, terms_hash: current, fee });
        Ok(())
    }

    /// Check if a publisher is actively registered in an app
    pub fn is_registered_for_app(&self, app_id: FixedBytes<32>, publisher: Address) -> bool {
        let key = member_key(app_id, publisher);
        let current = self.app_terms.get(app_id);
        current != FixedBytes::<32>::ZERO
            && self.statuses.get(key).to::<u8>() == STATUS_ACTIVE
            && self.accepted.get(key) == current
    }

    /// Get an addresses status in an app
    pub fn status_for_app(&self, app_id: FixedBytes<32>, publisher: Address) -> u8 {
        self.statuses.get(member_key(app_id, publisher)).to::<u8>()
    }

    pub fn accepted_terms(&self, app_id: FixedBytes<32>, publisher: Address) -> FixedBytes<32> {
        self.accepted.get(member_key(app_id, publisher))
    }

    pub fn app_terms(&self, app_id: FixedBytes<32>) -> FixedBytes<32> {
        self.app_terms.get(app_id)
    }

    pub fn app_terms_uri(&self, app_id: FixedBytes<32>) -> String {
        self.app_terms_uri.get(app_id).get_string()
    }

    pub fn app_fee(&self, app_id: FixedBytes<32>) -> U256 {
        self.app_fees.get(app_id)
    }

    pub fn join_info(
        &self,
        app_id: FixedBytes<32>,
        publisher: Address,
    ) -> (FixedBytes<32>, String, U256, u8, bool) {
        (
            self.app_terms.get(app_id),
            self.app_terms_uri.get(app_id).get_string(),
            self.app_fees.get(app_id),
            self.status_for_app(app_id, publisher),
            self.is_registered_for_app(app_id, publisher),
        )
    }

    pub fn admin(&self) -> Address {
        self.admin.get()
    }

    pub fn withdraw_eth(&mut self, to: Address, amount: U256) -> Result<(), AppRegistryError> {
        self.only_admin()?;
        transfer_eth(self.vm(), to, amount)
            .map_err(|_| AppRegistryError::TransferFailed(TransferFailed {}))
    }
}

/// keccak256(app_id ‖ publisher)
fn member_key(app_id: FixedBytes<32>, publisher: Address) -> FixedBytes<32> {
    let mut bytes = [0u8; 52]; // 32 app_id + 20 address
    bytes[0..32].copy_from_slice(app_id.as_slice());
    bytes[32..52].copy_from_slice(publisher.as_slice());
    keccak256(bytes)
}

impl AppRegistry {
    fn only_admin(&self) -> Result<(), AppRegistryError> {
        if self.vm().msg_sender() != self.admin.get() {
            return Err(AppRegistryError::Unauthorized(Unauthorized {}));
        }
        Ok(())
    }

    fn only_app_owner(&self, app_id: FixedBytes<32>) -> Result<(), AppRegistryError> {
        let owner = self.apps.get(app_id);
        if owner == Address::ZERO {
            return Err(AppRegistryError::AppNotFound(AppNotFound {}));
        }
        if self.vm().msg_sender() != owner {
            return Err(AppRegistryError::Unauthorized(Unauthorized {}));
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

    const ADMIN: Address = address!("1111111111111111111111111111111111111111");
    const APP_OWNER: Address = address!("2222222222222222222222222222222222222222");
    const PUBLISHER: Address = address!("3333333333333333333333333333333333333333");
    const STRANGER: Address = address!("4444444444444444444444444444444444444444");
    const CONTRACT: Address = address!("6666666666666666666666666666666666666666");

    const APP: FixedBytes<32> = FixedBytes([0xAA; 32]);
    const OTHER_APP: FixedBytes<32> = FixedBytes([0xBB; 32]);
    const TERMS_V1: FixedBytes<32> = FixedBytes([0x11; 32]);
    const TERMS_V2: FixedBytes<32> = FixedBytes([0x22; 32]);
    const FEE: u64 = 1_000_000_000_000_000; // 0.001 ETH

    /// A bare registry with no apps claimed yet.
    fn new_registry(vm: &TestVM) -> AppRegistry {
        vm.set_contract_address(CONTRACT);
        let mut r = AppRegistry::from(vm);
        r.init(ADMIN);
        r
    }

    /// APP claimed by APP_OWNER, with terms and a join fee — ready to be joined.
    fn open_app(vm: &TestVM, r: &mut AppRegistry) {
        vm.set_sender(APP_OWNER);
        r.register_app(APP, TERMS_V1, String::from("https://tabs.example/terms"), U256::from(FEE)).unwrap();
    }

    #[test]
    fn only_the_app_owner_sets_terms_and_fee() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);

        open_app(&vm, &mut r);
        assert_eq!(r.get_app_owner(APP), APP_OWNER, "register_app must record the claimer as owner");

        vm.set_sender(STRANGER);
        assert!(r.set_app_terms(APP, TERMS_V2, String::new()).is_err(), "a stranger set an app's terms");
        assert!(r.set_app_fee(APP, U256::from(FEE)).is_err(), "a stranger set an app's fee");
        assert!(r.register_app(APP, TERMS_V2, String::new(), U256::ZERO).is_err(), "an app id was claimed twice");

        // Not even the protocol admin — the app owner's obligations are their own.
        vm.set_sender(ADMIN);
        assert!(r.set_app_terms(APP, TERMS_V2, String::new()).is_err(), "the protocol admin set an app's terms");

        vm.set_sender(APP_OWNER);
        r.set_app_terms(APP, TERMS_V2, String::from("https://tabs.example/v2")).unwrap();
        assert_eq!(r.app_terms(APP), TERMS_V2);
        assert_eq!(r.app_terms_uri(APP), "https://tabs.example/v2");
    }

    #[test]
    fn an_unclaimed_app_cannot_be_configured_or_joined() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        let ghost = FixedBytes([0xCC; 32]);

        vm.set_sender(APP_OWNER);
        assert!(r.set_app_terms(ghost, TERMS_V1, String::new()).is_err(), "terms set on an unclaimed app");
        vm.set_sender(PUBLISHER);
        assert!(r.register_for_app(ghost, TERMS_V1).is_err(), "joined an app nobody owns");
    }

    #[test]
    fn registering_agrees_to_an_exact_terms_version() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);

        // An app claimed with no terms → nothing to agree to, so joining is refused
        // rather than recording consent to a zero hash.
        vm.set_sender(APP_OWNER);
        r.register_app(OTHER_APP, FixedBytes::ZERO, String::new(), U256::ZERO).unwrap();
        vm.set_sender(PUBLISHER);
        assert!(r.register_for_app(OTHER_APP, FixedBytes::ZERO).is_err(), "joined an app with no terms");

        open_app(&vm, &mut r);

        // The wrong version reverts: an app owner must not be able to swap the terms
        // under a pending registration and have it land as consent to the new ones.
        vm.set_sender(PUBLISHER);
        vm.set_value(U256::from(FEE));
        assert!(r.register_for_app(APP, TERMS_V2).is_err(), "a stale terms hash was accepted as agreement");

        r.register_for_app(APP, TERMS_V1).unwrap();
        assert!(r.is_registered_for_app(APP, PUBLISHER));
        assert_eq!(r.accepted_terms(APP, PUBLISHER), TERMS_V1);

        // Idempotence: no paying twice for the same membership.
        assert!(r.register_for_app(APP, TERMS_V1).is_err(), "double registration charged twice");
    }

    #[test]
    fn the_fee_is_required_and_goes_to_the_app_owner() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        open_app(&vm, &mut r);

        vm.set_sender(PUBLISHER);
        vm.set_value(U256::from(FEE - 1));
        assert!(r.register_for_app(APP, TERMS_V1).is_err(), "joined without paying the fee");

        // No balance assertion: TestVM does not model native value movement —
        // `transfer_eth` returns Ok and nothing moves — so `vm.balance(APP_OWNER)`
        // would read 0 whether the contract paid out or pocketed it. The recipient
        // is pinned by the sibling test below instead, which makes the payout fail.
        vm.set_balance(CONTRACT, U256::from(FEE));
        vm.set_value(U256::from(FEE));
        r.register_for_app(APP, TERMS_V1).unwrap();
        assert!(r.is_registered_for_app(APP, PUBLISHER));
    }

    /// The other half of the payout, in its own VM because a mock is keyed on
    /// (address, calldata, value) and re-registering one does not replace it.
    #[test]
    fn an_undeliverable_join_fee_aborts_the_registration() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        open_app(&vm, &mut r);

        vm.set_sender(PUBLISHER);
        vm.set_balance(CONTRACT, U256::from(FEE));
        vm.set_value(U256::from(FEE));
        // Make calls to APP_OWNER fail. This is the only observable evidence TestVM
        // offers that the payout goes THERE: with the mock in place the registration
        // aborts, and without it (the sibling test) the same call succeeds.
        vm.mock_call(APP_OWNER, Vec::new(), U256::from(FEE), Err(Vec::new()));
        assert!(
            r.register_for_app(APP, TERMS_V1).is_err(),
            "an undeliverable join fee must abort the registration, not admit a publisher who paid nobody",
        );
        // No follow-up assertion that the membership was rolled back: TestVM keeps
        // storage writes made before an `Err` return, so it cannot observe the
        // revert that a real chain performs. The ordering in `register_for_app` is
        // checks-effects-interactions precisely so that on-chain the payout failure
        // unwinds the writes — that is a property of the EVM, not of this harness.
    }

    #[test]
    fn moving_the_terms_drops_everyone_back_to_unaccepted() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        open_app(&vm, &mut r);

        vm.set_sender(PUBLISHER);
        vm.set_balance(CONTRACT, U256::from(FEE));
        vm.set_value(U256::from(FEE));
        r.register_for_app(APP, TERMS_V1).unwrap();
        assert!(r.is_registered_for_app(APP, PUBLISHER));

        vm.set_sender(APP_OWNER);
        r.set_app_terms(APP, TERMS_V2, String::from("https://tabs.example/terms-v2")).unwrap();

        // Not registered any more — but distinguishably so: still ACTIVE, on a stale
        // hash. A UI that only had the boolean would say "you were never here".
        assert!(!r.is_registered_for_app(APP, PUBLISHER), "a terms change must re-ask every publisher");
        assert_eq!(r.status_for_app(APP, PUBLISHER), STATUS_ACTIVE);
        assert_eq!(r.accepted_terms(APP, PUBLISHER), TERMS_V1);

        // Re-accepting is free. An app must not be able to bill its whole publisher
        // base by editing a sentence.
        vm.set_sender(PUBLISHER);
        vm.set_value(U256::ZERO);
        r.register_for_app(APP, TERMS_V2).unwrap();
        assert!(r.is_registered_for_app(APP, PUBLISHER));
    }

    #[test]
    fn membership_is_per_app() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        open_app(&vm, &mut r);
        vm.set_sender(APP_OWNER);
        r.register_app(OTHER_APP, TERMS_V2, String::new(), U256::ZERO).unwrap();

        vm.set_sender(PUBLISHER);
        vm.set_balance(CONTRACT, U256::from(FEE));
        vm.set_value(U256::from(FEE));
        r.register_for_app(APP, TERMS_V1).unwrap();

        assert!(r.is_registered_for_app(APP, PUBLISHER));
        assert!(!r.is_registered_for_app(OTHER_APP, PUBLISHER), "joining one market must not join another");
        assert!(!r.is_registered_for_app(APP, STRANGER), "an address that never joined reads as a member");
    }

    #[test]
    fn an_app_owner_can_eject_a_publisher_from_their_market_only() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        open_app(&vm, &mut r);
        vm.set_sender(APP_OWNER);
        r.register_app(OTHER_APP, TERMS_V1, String::new(), U256::ZERO).unwrap();

        vm.set_sender(PUBLISHER);
        vm.set_balance(CONTRACT, U256::from(FEE * 2));
        vm.set_value(U256::from(FEE));
        r.register_for_app(APP, TERMS_V1).unwrap();
        vm.set_value(U256::ZERO);
        r.register_for_app(OTHER_APP, TERMS_V1).unwrap();

        vm.set_sender(STRANGER);
        assert!(r.suspend_for_app(APP, PUBLISHER).is_err(), "a stranger ejected someone else's publisher");

        vm.set_sender(APP_OWNER);
        r.suspend_for_app(APP, PUBLISHER).unwrap();
        assert!(!r.is_registered_for_app(APP, PUBLISHER));
        assert!(r.is_registered_for_app(OTHER_APP, PUBLISHER), "one market's ban leaked into another");

        // Paying again is not a way back in.
        vm.set_sender(PUBLISHER);
        vm.set_value(U256::from(FEE));
        assert!(r.register_for_app(APP, TERMS_V1).is_err(), "a suspended publisher bought their way back in");

        vm.set_sender(APP_OWNER);
        r.reinstate_for_app(APP, PUBLISHER).unwrap();
        assert!(r.is_registered_for_app(APP, PUBLISHER));
    }

    #[test]
    fn join_info_answers_a_join_screen_in_one_call() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        open_app(&vm, &mut r);

        let (hash, uri, fee, status, registered) = r.join_info(APP, PUBLISHER);
        assert_eq!(hash, TERMS_V1);
        assert_eq!(uri, "https://tabs.example/terms");
        assert_eq!(fee, U256::from(FEE));
        assert_eq!(status, STATUS_UNREGISTERED);
        assert!(!registered);
    }
}
