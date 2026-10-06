//! AppRegistry
//!
//! An application is essentially a named domain and set of agreements for 
//! associating data with a given top-level app domain.
//! 
//! Each app is a tuple A = (R, W, V) where:
//! - R  is the set of allowed relations in published graphs
//! - W represents a (trusted or untrusted) agent that gates ingress into the application.
//!         It is responsible for validating all data that becomes committed to the app.
//! - V represents the validation logic 
//! 
//! Publishers must *register* with the application in order to be able to write to the app-level namespace
//! in an associated DataRegistry where a specific instance of the AppRegistry is referenced. 
//! See [deploy.sh](../deploy.sh) for an example script of how these are configured.
//!
//! An app IS a storage subscription: claiming one pulls the subscription fee (USDC), and
//! the off-chain upload gate reads `access` to decide whether to serve its publishers.
//! Membership is by invitation — the owner adds a publisher, who then accepts the terms.
//!
//! The DataRegistry is where the protocol admin bans a publisher network-wide, so this
//! contract asks it before letting a wallet claim an app or be added to one. The two
//! contracts therefore point at each other:
//!
//!   AppRegistry ── isRegistered(wallet) ──────────────▶ DataRegistry
//!   AppRegistry ◀── isRegisteredForApp(app_id, sender) ── DataRegistry
//!

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![cfg_attr(feature = "contract-client-gen", allow(unused_imports))]
extern crate alloc;

use alloc::{fmt, string::String};
use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{keccak256, Address, FixedBytes, U256, U64, U8},
    call::transfer::transfer_eth,
    prelude::*,
    storage::*,
};

const STATUS_UNREGISTERED: u8 = 0;
const STATUS_ACTIVE: u8 = 1;
const STATUS_SUSPENDED: u8 = 2;
/// Added by the app owner, terms not yet accepted. Per-app only: the DataRegistry
/// shares codes 0-2 and has no such state.
const STATUS_INVITED: u8 = 3;

sol! {
    error Unauthorized();
    error AppNotFound();
    error AppAlreadyRegistered();
    error TermsNotSet();
    error TermsMismatch();
    error AlreadyRegistered();
    error NotRegistered();
    error PublisherSuspendedErr();
    error AppSuspendedErr();
    error JoinFeeRequired();
    error TransferFailed();
    error NotInvited();
    error SubscriptionFeeRequired();
    /// The wallet is not an active publisher in the DataRegistry: it never registered,
    /// or the protocol admin suspended it. Distinct from `NotRegistered`, which is
    /// about one app.
    error NotRegisteredGlobally();

    /// A new app was registered
    event AppRegistered(bytes32 indexed app_id, address indexed owner);

    /// The app's terms changed and every publisher on the old hash must accept the new terms 
    /// before they can publish again
    event AppTermsChanged(bytes32 indexed app_id, bytes32 terms_hash, string terms_uri);

    event AppFeeChanged(bytes32 indexed app_id, uint256 fee);

    /// The app's agent card moved
    event AppAgentChanged(bytes32 indexed app_id, string agent_uri);

    /// A publisher joined an app AND accepted `terms_hash`
    event PublisherJoined(
        bytes32 indexed app_id,
        address indexed publisher,
        bytes32 terms_hash,
        uint256 fee
    );

    /// An app owner suspended a publisher from their app
    event PublisherSuspendedForApp(bytes32 indexed app_id, address indexed publisher);

    event PublisherReinstatedForApp(bytes32 indexed app_id, address indexed publisher);

    /// The protocol admin suspended (or reinstated) an entire app
    event AppSuspensionChanged(bytes32 indexed app_id, bool suspended);

    /// An app owner added a publisher, who may now accept the terms and join
    event PublisherInvited(bytes32 indexed app_id, address indexed publisher);

    /// The app's subscription was paid (at claim, or a renewal). `paid_at` is the block
    /// timestamp (Unix seconds); the off-chain gate enforces the active window.
    event AppSubscribed(bytes32 indexed app_id, address indexed payer, uint64 paid_at);

    event SubscriptionFeeChanged(uint256 fee);
}

sol_interface! {
    /// Minimal ERC-20 surface for pulling fees and sweeping the treasury.
    interface IERC20 {
        function transferFrom(address from, address to, uint256 amount) external returns (bool);
        function transfer(address to, uint256 amount) external returns (bool);
    }

    /// The DataRegistry publisher-registration check.
    interface IDataRegistry {
        function isRegistered(address publisher) external view returns (bool);
    }
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
    AppSuspendedErr(AppSuspendedErr),
    JoinFeeRequired(JoinFeeRequired),
    TransferFailed(TransferFailed),
    NotInvited(NotInvited),
    SubscriptionFeeRequired(SubscriptionFeeRequired),
    NotRegisteredGlobally(NotRegisteredGlobally),
}

impl fmt::Debug for AppRegistryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "AppRegistryError")
    }
}

#[storage]
#[entrypoint]
pub struct AppRegistry {
    /// The app registry admin
    admin: StorageAddress,
    /// app_id => owner
    apps: StorageMap<FixedBytes<32>, StorageAddress>,
    /// app_id => hash of the app's current publisher terms (e.g. an IPFS cid)
    // Zero means there are no terms set
    app_terms: StorageMap<FixedBytes<32>, StorageFixedBytes<32>>,
    /// app_id => URI to read the terms (e.g. an IPFS gateway)
    app_terms_uri: StorageMap<FixedBytes<32>, StorageString>,
    /// app_id => join fee (in wei) - can be zerof
    app_fees: StorageMap<FixedBytes<32>, StorageU256>,
    /// keccak256(app_id ‖ publisher) => lifecycle status.
    statuses: StorageMap<FixedBytes<32>, StorageU8>,
    /// keccak256(app_id ‖ publisher) => the terms hash they actually accepted
    /// used to determine if they must accept new terms
    accepted: StorageMap<FixedBytes<32>, StorageFixedBytes<32>>,
    /// app_id => admin takedown flag. A suspended app is dead for every publisher at once
    app_suspended: StorageMap<FixedBytes<32>, StorageBool>,
    /// app_id => URI of the app's ERC-8004 agent card. Empty means the app has none.
    // Appended last on purpose: inserting a field above shifts every slot below it.
    app_agent_uri: StorageMap<FixedBytes<32>, StorageString>,
    /// ERC-20 token the subscription fee is paid in (USDC). Amounts are in its base units.
    usdc: StorageAddress,
    /// Subscription fee, denominated in USDC base units (6 decimals).
    subscription_fee: StorageU256,
    /// app_id => block timestamp (Unix seconds) of the app's last subscription payment.
    subscribed_at: StorageMap<FixedBytes<32>, StorageU64>,
    /// The DataRegistry queried for network-wide publisher registration.
    data_registry: StorageAddress,
}

#[public]
impl AppRegistry {
    #[constructor]
    pub fn init(
        &mut self,
        admin: Address,
        usdc: Address,
        subscription_fee: U256,
        data_registry: Address,
    ) {
        self.admin.set(admin);
        self.usdc.set(usdc);
        self.subscription_fee.set(subscription_fee);
        self.data_registry.set(data_registry);
    }

    /// Claim a unique app id
    ///
    /// * `app_id`: a unique 32-byte identifier for the app
    /// * `terms_hash`: the CID of the terms and conditions for using the app
    /// * `terms_uri`: A URI where the terms can be found (e.g. an IPFS gateway).
    ///   NOT the app's agent card — that goes in `set_app_agent_uri`, which carries no
    ///   hash precisely so that moving it does not unregister every publisher.
    /// * `fee`: a fee for registering as a publisher
    ///
    /// The claimer becomes the app's first registered publisher, so they can write to
    /// their own namespace without a second transaction against their own terms.
    ///
    /// Claiming pays the subscription fee (USDC), so an app cannot exist unpaid. The
    /// caller must `approve` this contract for `subscription_fee()` first.
    ///
    /// The caller must be a registered publisher in the DataRegistry, so a wallet the
    /// protocol admin has banned cannot come back as an app owner.
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
        if !self.check_registered(owner) {
            return Err(AppRegistryError::NotRegisteredGlobally(NotRegisteredGlobally {}));
        }
        self.pay_subscription(app_id, owner)?;
        self.apps.setter(app_id).set(owner);
        self.app_terms.setter(app_id).set(terms_hash);
        self.app_terms_uri.setter(app_id).set_str(&terms_uri);
        // TODO: introduce a proper treasury
        self.app_fees.setter(app_id).set(fee);
        self.join_owner(app_id, owner, terms_hash);
        self.vm().log(AppRegistered { app_id, owner });
        self.vm().log(AppTermsChanged { app_id, terms_hash, terms_uri });
        self.vm().log(AppFeeChanged { app_id, fee });
        Ok(())
    }

    pub fn get_app_owner(&self, app_id: FixedBytes<32>) -> Address {
        self.apps.get(app_id)
    }

    /// Renew an app's subscription: pays the fee again and re-stamps `now`.
    /// Only callable by the app owner. Renewing while still active is allowed.
    pub fn renew_app(&mut self, app_id: FixedBytes<32>) -> Result<(), AppRegistryError> {
        self.only_app_owner(app_id)?;
        let owner = self.apps.get(app_id);
        self.pay_subscription(app_id, owner)
    }

    /// Add a publisher to this app. Only callable by the app owner.
    ///
    /// This is an invitation, not a membership: the publisher still has to accept the
    /// terms (and pay the join fee) with `register_for_app`. Nobody can join uninvited.
    /// Take an invitation back with `suspend_for_app`.
    ///
    /// The publisher must be registered in the DataRegistry: an owner cannot bring in
    /// a wallet that never registered, or one the protocol admin has banned.
    pub fn add_publisher(
        &mut self,
        app_id: FixedBytes<32>,
        publisher: Address,
    ) -> Result<(), AppRegistryError> {
        self.only_app_owner(app_id)?;
        if !self.check_registered(publisher) {
            return Err(AppRegistryError::NotRegisteredGlobally(NotRegisteredGlobally {}));
        }
        let key = member_key(app_id, publisher);
        if self.statuses.get(key).to::<u8>() != STATUS_UNREGISTERED {
            return Err(AppRegistryError::AlreadyRegistered(AlreadyRegistered {}));
        }
        self.statuses.setter(key).set(U8::from(STATUS_INVITED));
        self.vm().log(PublisherInvited { app_id, publisher });
        Ok(())
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
        // The owner accepts their own terms by publishing them. Without this they are
        // locked out of their own app by every edit, needing a round trip to agree to
        // a document they wrote.
        self.join_owner(app_id, self.apps.get(app_id), terms_hash);
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

    /// Point at the app's ERC-8004 agent card. 
    /// Only callable by the app owner.
    pub fn set_app_agent_uri(
        &mut self,
        app_id: FixedBytes<32>,
        agent_uri: String,
    ) -> Result<(), AppRegistryError> {
        self.only_app_owner(app_id)?;
        self.app_agent_uri.setter(app_id).set_str(&agent_uri);
        self.vm().log(AppAgentChanged { app_id, agent_uri });
        Ok(())
    }

    /// Suspend a publisher from only this app.
    /// Does not suspend globally.
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

    /// Suspend an app's entire set of publisher. 
    /// Admin-only global takedown
    pub fn suspend_app(&mut self, app_id: FixedBytes<32>) -> Result<(), AppRegistryError> {
        self.set_app_suspended(app_id, true)
    }

    /// Reinstate a suspended app
    pub fn reinstate_app(&mut self, app_id: FixedBytes<32>) -> Result<(), AppRegistryError> {
        self.set_app_suspended(app_id, false)
    }

    pub fn is_app_suspended(&self, app_id: FixedBytes<32>) -> bool {
        self.app_suspended.get(app_id)
    }

    /// Register to publish to an app
    /// By registering, you are agreeing to the app terms and conditions.
    /// The app owner must have added you first (`add_publisher`).
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
        // block on a suspended app
        if self.app_suspended.get(app_id) {
            return Err(AppRegistryError::AppSuspendedErr(AppSuspendedErr {}));
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

        // must have been added by the app owner
        if status == STATUS_UNREGISTERED {
            return Err(AppRegistryError::NotInvited(NotInvited {}));
        }
        // must not be suspended as a publisher
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
    /// returns false if the publisher is suspended or if the app is suspended
    pub fn is_registered_for_app(&self, app_id: FixedBytes<32>, publisher: Address) -> bool {
        let key = member_key(app_id, publisher);
        let current = self.app_terms.get(app_id);
        !self.app_suspended.get(app_id)
            && current != FixedBytes::<32>::ZERO
            && self.statuses.get(key).to::<u8>() == STATUS_ACTIVE
            && self.accepted.get(key) == current
    }

    /// The single oracle the upload gate reads: `(registered, owner, paid_at)`.
    /// `registered` is `is_registered_for_app`; `owner` is `Address::ZERO` for an
    /// unclaimed app; `paid_at` is the app's last subscription timestamp. The gate
    /// applies its own active-window policy off-chain.
    pub fn access(&self, app_id: FixedBytes<32>, publisher: Address) -> (bool, Address, u64) {
        (
            self.is_registered_for_app(app_id, publisher),
            self.apps.get(app_id),
            self.subscribed_at.get(app_id).to::<u64>(),
        )
    }

    /// Block timestamp (Unix seconds) of the app's last subscription payment,
    /// or 0 for an unclaimed app.
    pub fn subscribed_at(&self, app_id: FixedBytes<32>) -> u64 {
        self.subscribed_at.get(app_id).to::<u64>()
    }

    pub fn subscription_fee(&self) -> U256 {
        self.subscription_fee.get()
    }

    /// The ERC-20 token (USDC) the subscription fee is paid in.
    pub fn usdc(&self) -> Address {
        self.usdc.get()
    }

    /// The DataRegistry this registry checks network-wide registration against.
    pub fn data_registry(&self) -> Address {
        self.data_registry.get()
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

    /// The app's agent card URI, or an empty string if it has never set one.
    pub fn app_agent_uri(&self, app_id: FixedBytes<32>) -> String {
        self.app_agent_uri.get(app_id).get_string()
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

    pub fn set_subscription_fee(&mut self, fee: U256) -> Result<(), AppRegistryError> {
        self.only_admin()?;
        self.subscription_fee.set(fee);
        self.vm().log(SubscriptionFeeChanged { fee });
        Ok(())
    }

    /// Update the fee token address (USDC).
    pub fn set_usdc(&mut self, token: Address) -> Result<(), AppRegistryError> {
        self.only_admin()?;
        self.usdc.set(token);
        Ok(())
    }

    /// Update the DataRegistry used for the registration check. Until one is set,
    /// nobody reads as registered, so no app can be claimed and nobody added.
    pub fn set_data_registry(&mut self, registry: Address) -> Result<(), AppRegistryError> {
        self.only_admin()?;
        self.data_registry.set(registry);
        Ok(())
    }

    /// Sweep `amount` of collected USDC to `to`.
    pub fn withdraw_usdc(&mut self, to: Address, amount: U256) -> Result<(), AppRegistryError> {
        self.only_admin()?;
        let token = self.usdc.get();
        let cfg = Call::new_mutating(self);
        match IERC20::new(token).transfer(self.vm(), cfg, to, amount) {
            Ok(true) => Ok(()),
            _ => Err(AppRegistryError::TransferFailed(TransferFailed {})),
        }
    }

    pub fn withdraw_eth(&mut self, to: Address, amount: U256) -> Result<(), AppRegistryError> {
        self.only_admin()?;
        transfer_eth(self.vm(), to, amount)
            .map_err(|_| AppRegistryError::TransferFailed(TransferFailed {}))
    }
}

impl AppRegistry {
    fn set_app_suspended(
        &mut self,
        app_id: FixedBytes<32>,
        suspended: bool,
    ) -> Result<(), AppRegistryError> {
        self.only_admin()?;
        if self.apps.get(app_id) == Address::ZERO {
            return Err(AppRegistryError::AppNotFound(AppNotFound {}));
        }
        self.app_suspended.setter(app_id).set(suspended);
        self.vm().log(AppSuspensionChanged { app_id, suspended });
        Ok(())
    }

    /// Cross-contract check: is `who` an active registered publisher in the
    /// DataRegistry? A reverted/failed call is treated as "not registered".
    fn check_registered(&self, who: Address) -> bool {
        let registry = self.data_registry.get();
        matches!(
            IDataRegistry::new(registry).is_registered(self.vm(), Call::new(), who),
            Ok(true)
        )
    }

    /// Pull the subscription fee from `payer` and stamp the app as paid now.
    /// The pull comes first, so a refused payment leaves nothing behind.
    fn pay_subscription(
        &mut self,
        app_id: FixedBytes<32>,
        payer: Address,
    ) -> Result<(), AppRegistryError> {
        let fee = self.subscription_fee.get();
        self.pull_usdc(payer, fee)
            .map_err(|_| AppRegistryError::SubscriptionFeeRequired(SubscriptionFeeRequired {}))?;
        let now = self.vm().block_timestamp();
        self.subscribed_at.setter(app_id).set(U64::from(now));
        self.vm().log(AppSubscribed { app_id, payer, paid_at: now });
        Ok(())
    }

    /// Pull `amount` of USDC from `from` into this contract. `from` must have
    /// approved this contract. Returns `Err(())` on revert or a `false` return.
    fn pull_usdc(&mut self, from: Address, amount: U256) -> Result<(), ()> {
        if amount.is_zero() {
            return Ok(());
        }
        let token = self.usdc.get();
        let this = self.vm().contract_address();
        let cfg = Call::new_mutating(self);
        match IERC20::new(token).transfer_from(self.vm(), cfg, from, this, amount) {
            Ok(true) => Ok(()),
            _ => Err(()),
        }
    }

    /// Mark an app owner as an active publisher of their own app
    fn join_owner(&mut self, app_id: FixedBytes<32>, owner: Address, terms_hash: FixedBytes<32>) {
        let key = member_key(app_id, owner);
        self.statuses.setter(key).set(U8::from(STATUS_ACTIVE));
        self.accepted.setter(key).set(terms_hash);
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

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_sol_types::{sol, SolCall};
    use stylus_sdk::alloy_primitives::address;
    use stylus_sdk::testing::TestVM;

    // Local ABI defs used only to build the exact calldata TestVM matches on.
    sol! {
        function transferFrom(address from, address to, uint256 amount) external returns (bool);
        function transfer(address to, uint256 amount) external returns (bool);
        function isRegistered(address publisher) external view returns (bool);
    }

    const ADMIN: Address = address!("1111111111111111111111111111111111111111");
    const APP_OWNER: Address = address!("2222222222222222222222222222222222222222");
    const PUBLISHER: Address = address!("3333333333333333333333333333333333333333");
    const STRANGER: Address = address!("4444444444444444444444444444444444444444");
    const CONTRACT: Address = address!("6666666666666666666666666666666666666666");
    const USDC: Address = address!("5555555555555555555555555555555555555555");
    const DATA_REGISTRY: Address = address!("7777777777777777777777777777777777777777");
    /// A wallet the DataRegistry does not know: never registered, or banned.
    const OUTSIDER: Address = address!("8888888888888888888888888888888888888888");

    const APP: FixedBytes<32> = FixedBytes([0xAA; 32]);
    const OTHER_APP: FixedBytes<32> = FixedBytes([0xBB; 32]);
    const TERMS_V1: FixedBytes<32> = FixedBytes([0x11; 32]);
    const TERMS_V2: FixedBytes<32> = FixedBytes([0x22; 32]);
    const FEE: u64 = 1_000_000_000_000_000; // 0.001 ETH
    const SUB_FEE: u64 = 2_000_000; // 2 USDC (6 decimals)

    /// A bare registry with no apps claimed yet. The subscription fee starts at zero,
    /// so claiming makes no USDC call unless a test raises it. Every wallet reads as
    /// registered in the DataRegistry except OUTSIDER.
    fn new_registry(vm: &TestVM) -> AppRegistry {
        vm.set_contract_address(CONTRACT);
        let mut r = AppRegistry::from(vm);
        r.init(ADMIN, USDC, U256::ZERO, DATA_REGISTRY);
        // OUTSIDER's lookup reverts, which the contract treats as "not registered".
        let data = isRegisteredCall { publisher: OUTSIDER }.abi_encode();
        vm.mock_static_call(DATA_REGISTRY, data, Err(Vec::new()));
        everyone_else_is_registered(vm);
        r
    }

    fn bool_word(b: bool) -> Vec<u8> {
        U256::from(b as u64).to_be_bytes::<32>().to_vec()
    }

    /// TestVM keys a mock's Ok/Err outcome by (address, calldata), but keeps ONE
    /// shared return-data buffer: the bytes of whichever mock was registered last.
    /// An unmocked call succeeds and reads that same buffer. So "is this wallet
    /// registered" is whatever was mocked last, for every wallet — only a reverting
    /// mock (OUTSIDER's) can make one caller differ. This leaves `true` in the buffer;
    /// call it again after any mock that should not change the answer.
    fn everyone_else_is_registered(vm: &TestVM) {
        let data = isRegisteredCall { publisher: APP_OWNER }.abi_encode();
        vm.mock_static_call(DATA_REGISTRY, data, Ok(bool_word(true)));
    }

    /// APP claimed by APP_OWNER, with terms and a join fee, and PUBLISHER invited —
    /// ready for PUBLISHER to join.
    fn open_app(vm: &TestVM, r: &mut AppRegistry) {
        vm.set_sender(APP_OWNER);
        r.register_app(APP, TERMS_V1, String::from("https://tabs.example/terms"), U256::from(FEE)).unwrap();
        r.add_publisher(APP, PUBLISHER).unwrap();
    }

    // Mock the USDC transferFrom(from → contract, SUB_FEE) fee pull. Non-payable → value 0.
    // A refused pull is a revert rather than a `false` return: `false` would land in
    // the shared buffer and make the payer read as unregistered too.
    fn mock_pull(vm: &TestVM, from: Address, ok: bool) {
        let data = transferFromCall { from, to: CONTRACT, amount: U256::from(SUB_FEE) }.abi_encode();
        let outcome = if ok { Ok(bool_word(true)) } else { Err(Vec::new()) };
        vm.mock_call(USDC, data, U256::ZERO, outcome);
        everyone_else_is_registered(vm);
    }

    #[test]
    fn claiming_an_app_pays_its_subscription() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);

        vm.set_sender(STRANGER);
        assert!(r.set_subscription_fee(U256::from(1u64)).is_err(), "a stranger set the subscription fee");
        vm.set_sender(ADMIN);
        r.set_subscription_fee(U256::from(SUB_FEE)).unwrap();
        assert_eq!(r.subscription_fee(), U256::from(SUB_FEE));
        assert_eq!(r.usdc(), USDC);

        // No payment, no app: a refused pull must not leave a claimed id behind.
        vm.set_sender(STRANGER);
        mock_pull(&vm, STRANGER, false);
        assert!(
            matches!(
                r.register_app(OTHER_APP, TERMS_V1, String::new(), U256::ZERO),
                Err(AppRegistryError::SubscriptionFeeRequired(_))
            ),
            "an app was claimed without paying the subscription",
        );
        assert_eq!(r.get_app_owner(OTHER_APP), Address::ZERO, "an unpaid claim left an app behind");
        assert_eq!(r.subscribed_at(OTHER_APP), 0);

        vm.set_block_timestamp(1_700_000_000);
        vm.set_sender(APP_OWNER);
        mock_pull(&vm, APP_OWNER, true);
        r.register_app(APP, TERMS_V1, String::new(), U256::ZERO).unwrap();
        assert_eq!(r.subscribed_at(APP), 1_700_000_000);

        // The gate's one read: membership, who owns the app, and when it last paid.
        assert_eq!(r.access(APP, APP_OWNER), (true, APP_OWNER, 1_700_000_000));
        assert_eq!(r.access(APP, STRANGER), (false, APP_OWNER, 1_700_000_000));
        assert_eq!(r.access(OTHER_APP, STRANGER), (false, Address::ZERO, 0));

        // Renewing is the owner's to do, and re-stamps to the new now.
        vm.set_block_timestamp(1_700_100_000);
        vm.set_sender(STRANGER);
        assert!(r.renew_app(APP).is_err(), "a stranger renewed someone else's app");
        vm.set_sender(APP_OWNER);
        r.renew_app(APP).unwrap();
        assert_eq!(r.subscribed_at(APP), 1_700_100_000);
    }

    #[test]
    fn only_an_invited_publisher_can_join() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        open_app(&vm, &mut r);

        // An invitation is not a membership.
        assert_eq!(r.status_for_app(APP, PUBLISHER), STATUS_INVITED);
        assert!(!r.is_registered_for_app(APP, PUBLISHER), "an invitation alone let a publisher publish");

        vm.set_sender(STRANGER);
        vm.set_value(U256::from(FEE));
        assert!(
            matches!(r.register_for_app(APP, TERMS_V1), Err(AppRegistryError::NotInvited(_))),
            "an uninvited wallet joined an app",
        );
        assert!(r.add_publisher(APP, STRANGER).is_err(), "a stranger invited themselves");

        vm.set_sender(APP_OWNER);
        assert!(r.add_publisher(APP, PUBLISHER).is_err(), "a publisher was invited twice");

        // The owner can take an invitation back before it is used.
        r.add_publisher(APP, STRANGER).unwrap();
        r.suspend_for_app(APP, STRANGER).unwrap();
        vm.set_sender(STRANGER);
        assert!(r.register_for_app(APP, TERMS_V1).is_err(), "a revoked invitation was still redeemable");
    }

    #[test]
    fn claiming_and_adding_need_data_registry_registration() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        assert_eq!(r.data_registry(), DATA_REGISTRY);

        // Never registered, or banned by the protocol admin: no app for them.
        vm.set_sender(OUTSIDER);
        assert!(
            matches!(
                r.register_app(APP, TERMS_V1, String::new(), U256::ZERO),
                Err(AppRegistryError::NotRegisteredGlobally(_))
            ),
            "a wallet the DataRegistry does not know claimed an app",
        );
        assert_eq!(r.get_app_owner(APP), Address::ZERO, "a refused claim left an app behind");

        // ...and an owner cannot bring one in either.
        vm.set_sender(APP_OWNER);
        r.register_app(APP, TERMS_V1, String::new(), U256::ZERO).unwrap();
        assert!(
            matches!(r.add_publisher(APP, OUTSIDER), Err(AppRegistryError::NotRegisteredGlobally(_))),
            "an owner added a wallet the DataRegistry does not know",
        );
        assert_eq!(r.status_for_app(APP, OUTSIDER), STATUS_UNREGISTERED);
        r.add_publisher(APP, PUBLISHER).unwrap();

        // Only the protocol admin chooses which DataRegistry vouches for wallets.
        vm.set_sender(STRANGER);
        assert!(r.set_data_registry(STRANGER).is_err(), "a stranger repointed the DataRegistry");
        vm.set_sender(ADMIN);
        r.set_data_registry(STRANGER).unwrap();
        assert_eq!(r.data_registry(), STRANGER);
        // Not asserted: that an unset DataRegistry fails closed. On-chain a call to an
        // address with no code returns empty data, which does not decode as `true`.
        // TestVM answers an unmocked call from the shared buffer instead, so it would
        // read as registered here.
    }

    #[test]
    fn only_the_admin_sweeps_the_subscription_fees() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);

        vm.set_sender(APP_OWNER);
        assert!(matches!(
            r.withdraw_usdc(STRANGER, U256::from(SUB_FEE)),
            Err(AppRegistryError::Unauthorized(_))
        ));

        vm.set_sender(ADMIN);
        let data = transferCall { to: STRANGER, amount: U256::from(SUB_FEE) }.abi_encode();
        vm.mock_call(USDC, data, U256::ZERO, Ok(bool_word(true)));
        assert!(r.withdraw_usdc(STRANGER, U256::from(SUB_FEE)).is_ok());
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
    fn moving_the_agent_card_leaves_registrations_alone() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        open_app(&vm, &mut r);

        vm.set_sender(PUBLISHER);
        vm.set_value(U256::from(FEE));
        r.register_for_app(APP, TERMS_V1).unwrap();
        assert!(r.is_registered_for_app(APP, PUBLISHER));

        vm.set_sender(STRANGER);
        assert!(
            r.set_app_agent_uri(APP, String::from("https://evil.example/card.json")).is_err(),
            "a stranger repointed an app's agent card",
        );

        // The point of the separate field: an endpoint can rotate as often as it likes
        // without touching terms_hash, so nobody gets unregistered by a redeploy.
        vm.set_sender(APP_OWNER);
        r.set_app_agent_uri(APP, String::from("https://a.example/card.json")).unwrap();
        r.set_app_agent_uri(APP, String::from("https://b.example/card.json")).unwrap();
        assert_eq!(r.app_agent_uri(APP), "https://b.example/card.json");
        assert_eq!(r.app_terms(APP), TERMS_V1, "the agent card disturbed the terms hash");
        assert_eq!(r.accepted_terms(APP, PUBLISHER), TERMS_V1);
        assert!(
            r.is_registered_for_app(APP, PUBLISHER),
            "moving the agent card unregistered a publisher — the exact trap this field exists to avoid",
        );

        // An app that never set one reads as empty, not as a revert.
        vm.set_sender(APP_OWNER);
        r.register_app(OTHER_APP, TERMS_V1, String::new(), U256::ZERO).unwrap();
        assert_eq!(r.app_agent_uri(OTHER_APP), "");
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

        r.add_publisher(OTHER_APP, PUBLISHER).unwrap();

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
    fn the_admin_can_take_down_a_whole_app() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        open_app(&vm, &mut r);
        vm.set_sender(APP_OWNER);
        r.register_app(OTHER_APP, TERMS_V1, String::new(), U256::ZERO).unwrap();

        vm.set_sender(PUBLISHER);
        vm.set_balance(CONTRACT, U256::from(FEE));
        vm.set_value(U256::from(FEE));
        r.register_for_app(APP, TERMS_V1).unwrap();

        // The app owner has no say over their own takedown, and a stranger even less.
        vm.set_sender(APP_OWNER);
        assert!(r.suspend_app(APP).is_err(), "an app owner suspended their own app");
        vm.set_sender(STRANGER);
        assert!(r.suspend_app(APP).is_err(), "a stranger suspended an app");

        vm.set_sender(ADMIN);
        assert!(r.suspend_app(FixedBytes([0xCC; 32])).is_err(), "suspended an app nobody owns");
        r.suspend_app(APP).unwrap();

        // Everyone is out, owner included, and nothing about the other app moved.
        assert!(!r.is_registered_for_app(APP, PUBLISHER));
        assert!(!r.is_registered_for_app(APP, APP_OWNER), "a takedown left the owner publishing");
        assert!(r.is_registered_for_app(OTHER_APP, APP_OWNER), "a takedown leaked into another app");

        // No buying back in, and per-publisher status is untouched underneath.
        vm.set_sender(PUBLISHER);
        vm.set_value(U256::from(FEE));
        assert!(r.register_for_app(APP, TERMS_V1).is_err(), "joined a suspended app");
        assert_eq!(r.status_for_app(APP, PUBLISHER), STATUS_ACTIVE);

        // Reinstating restores the memberships exactly as they were.
        vm.set_sender(ADMIN);
        r.reinstate_app(APP).unwrap();
        assert!(r.is_registered_for_app(APP, PUBLISHER), "reinstating an app lost its publishers");
        assert!(r.is_registered_for_app(APP, APP_OWNER));
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
        assert_eq!(status, STATUS_INVITED);
        assert!(!registered);
        assert_eq!(r.join_info(APP, STRANGER).3, STATUS_UNREGISTERED);
    }

    #[test]
    fn an_app_owner_is_their_own_first_publisher() {
        let vm = TestVM::default();
        let mut r = new_registry(&vm);
        open_app(&vm, &mut r);

        assert!(r.is_registered_for_app(APP, APP_OWNER), "register_app left the owner unable to publish");

        // ...and editing the terms must not lock them out of their own app either.
        vm.set_sender(APP_OWNER);
        r.set_app_terms(APP, TERMS_V2, String::new()).unwrap();
        assert!(r.is_registered_for_app(APP, APP_OWNER), "set_app_terms locked the owner out");
        assert_eq!(r.accepted_terms(APP, APP_OWNER), TERMS_V2);

        // Claiming an app must not enrol you anywhere else.
        assert!(!r.is_registered_for_app(OTHER_APP, APP_OWNER));
    }
}