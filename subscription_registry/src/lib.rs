//! SubscriptionRegistry — a standalone storage-subscription contract.
//!
//! Publishers pay a USDC fee to open or renew a subscription; the off-chain upload
//! gate reads `access` to decide whether to serve. Publisher *registration* lives in
//! the separate DataRegistry contract, which this contract queries via a
//! cross-contract `isRegistered` call — so the registry and the paywall stay
//! decoupled.

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![cfg_attr(feature = "contract-client-gen", allow(unused_imports))]
extern crate alloc;

use alloc::fmt;
use alloy_sol_types::sol;
use stylus_sdk::{
    alloy_primitives::{Address, U256, U64},
    call::transfer::transfer_eth,
    prelude::*,
    storage::*,
};

sol! {
    error Unauthorized();
    error NotRegistered();
    error SubscriptionFeeRequired();
    error TransferFailed();

    /// Emitted when a publisher pays the subscription fee. `paid_at` is the block
    /// timestamp (Unix seconds); the off-chain gate enforces the active window.
    event Subscribed(
        address indexed publisher,
        uint64 paid_at
    );

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
pub enum SubscriptionError {
    Unauthorized(Unauthorized),
    NotRegistered(NotRegistered),
    SubscriptionFeeRequired(SubscriptionFeeRequired),
    TransferFailed(TransferFailed),
}

impl fmt::Debug for SubscriptionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "SubscriptionError")
    }
}

#[storage]
#[entrypoint]
pub struct SubscriptionRegistry {
    /// Protocol admin.
    admin: StorageAddress,
    /// ERC-20 token fees are paid in (USDC). Amounts are in its base units.
    usdc: StorageAddress,
    /// The DataRegistry contract queried for publisher registration.
    data_registry: StorageAddress,
    /// Subscription fee, denominated in USDC base units (6 decimals).
    subscription_fee: StorageU256,
    /// Block timestamp (Unix seconds) of each publisher's last subscription payment.
    subscribed_at: StorageMap<Address, StorageU64>,
}

#[public]
impl SubscriptionRegistry {
    #[constructor]
    pub fn init(
        &mut self,
        admin: Address,
        usdc: Address,
        data_registry: Address,
        subscription_fee: U256,
    ) {
        self.admin.set(admin);
        self.usdc.set(usdc);
        self.data_registry.set(data_registry);
        self.subscription_fee.set(subscription_fee);
    }

    /// Pay the subscription fee (USDC) to open or renew a subscription. Requires the
    /// caller to be a registered publisher in the DataRegistry. Renewable while
    /// active — it just re-stamps `now`. The caller must `approve` this contract for
    /// the fee first.
    pub fn subscribe(&mut self) -> Result<(), SubscriptionError> {
        let sender = self.vm().msg_sender();
        if !self.check_registered(sender) {
            return Err(SubscriptionError::NotRegistered(NotRegistered {}));
        }

        let fee = self.subscription_fee.get();
        self.pull_usdc(sender, fee)
            .map_err(|_| SubscriptionError::SubscriptionFeeRequired(SubscriptionFeeRequired {}))?;

        let now = self.vm().block_timestamp();
        self.subscribed_at.setter(sender).set(U64::from(now));
        self.vm().log(Subscribed { publisher: sender, paid_at: now });

        Ok(())
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    /// The single oracle the upload gate reads: `(registered, paid_at)`. `registered`
    /// is a cross-contract `isRegistered` call to the DataRegistry; `paid_at` is this
    /// publisher's last subscription timestamp (0 if never). The gate applies its own
    /// free-tier + active-window policy off-chain.
    pub fn access(&self, publisher: Address) -> (bool, u64) {
        let registered = self.check_registered(publisher);
        let paid_at = self.subscribed_at.get(publisher).to::<u64>();
        (registered, paid_at)
    }

    /// Block timestamp (Unix seconds) of the publisher's last subscription payment,
    /// or 0 if they never subscribed.
    pub fn subscribed_at(&self, publisher: Address) -> u64 {
        self.subscribed_at.get(publisher).to::<u64>()
    }

    pub fn subscription_fee(&self) -> U256 {
        self.subscription_fee.get()
    }

    /// The ERC-20 token (USDC) fees are paid in.
    pub fn usdc(&self) -> Address {
        self.usdc.get()
    }

    /// The DataRegistry contract this registry checks registration against.
    pub fn data_registry(&self) -> Address {
        self.data_registry.get()
    }

    pub fn admin(&self) -> Address {
        self.admin.get()
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    pub fn set_subscription_fee(&mut self, fee: U256) -> Result<(), SubscriptionError> {
        self.only_admin()?;
        self.subscription_fee.set(fee);
        self.vm().log(SubscriptionFeeChanged { fee });
        Ok(())
    }

    /// Update the fee token address (USDC).
    pub fn set_usdc(&mut self, token: Address) -> Result<(), SubscriptionError> {
        self.only_admin()?;
        self.usdc.set(token);
        Ok(())
    }

    /// Update the DataRegistry address used for the registration check.
    pub fn set_data_registry(&mut self, registry: Address) -> Result<(), SubscriptionError> {
        self.only_admin()?;
        self.data_registry.set(registry);
        Ok(())
    }

    /// Sweep `amount` of collected USDC to `to`.
    pub fn withdraw_usdc(&mut self, to: Address, amount: U256) -> Result<(), SubscriptionError> {
        self.only_admin()?;
        let token = self.usdc.get();
        let cfg = Call::new_mutating(self);
        match IERC20::new(token).transfer(self.vm(), cfg, to, amount) {
            Ok(true) => Ok(()),
            _ => Err(SubscriptionError::TransferFailed(TransferFailed {})),
        }
    }

    /// Rescue native ETH held by the contract.
    pub fn withdraw_eth(&mut self, to: Address, amount: U256) -> Result<(), SubscriptionError> {
        self.only_admin()?;
        transfer_eth(self.vm(), to, amount)
            .map_err(|_| SubscriptionError::TransferFailed(TransferFailed {}))
    }
}

impl SubscriptionRegistry {
    fn only_admin(&self) -> Result<(), SubscriptionError> {
        if self.vm().msg_sender() != self.admin.get() {
            return Err(SubscriptionError::Unauthorized(Unauthorized {}));
        }
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
}

// ── Tests ────────────────────────────────────────────────────────────────────

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

    const ADMIN_ADDR: Address = address!("1111111111111111111111111111111111111111");
    const PUB_ADDR: Address = address!("2222222222222222222222222222222222222222");
    const CONTRACT_ADDR: Address = address!("3333333333333333333333333333333333333333");
    const USDC_ADDR: Address = address!("4444444444444444444444444444444444444444");
    const REGISTRY_ADDR: Address = address!("6666666666666666666666666666666666666666");
    const RECIPIENT: Address = address!("5555555555555555555555555555555555555555");
    const SUB_FEE_AMT: u64 = 2_000_000; // 2 USDC (6 decimals)

    // 32-byte ABI word encoding a bool return value.
    fn bool_word(b: bool) -> Vec<u8> {
        U256::from(b as u64).to_be_bytes::<32>().to_vec()
    }

    fn new_registry(vm: &TestVM) -> SubscriptionRegistry {
        vm.set_contract_address(CONTRACT_ADDR);
        let mut registry = SubscriptionRegistry::from(vm);
        registry.init(ADMIN_ADDR, USDC_ADDR, REGISTRY_ADDR, U256::from(SUB_FEE_AMT));
        registry
    }

    // Mock the cross-contract DataRegistry.isRegistered(who) STATIC call.
    fn mock_registered(vm: &TestVM, who: Address, registered: bool) {
        let data = isRegisteredCall { publisher: who }.abi_encode();
        vm.mock_static_call(REGISTRY_ADDR, data, Ok(bool_word(registered)));
    }

    // Mock the USDC transferFrom(from → contract, amount) fee pull. Non-payable → value 0.
    fn mock_pull(vm: &TestVM, from: Address, amount: u64, ok: bool) {
        let data = transferFromCall { from, to: CONTRACT_ADDR, amount: U256::from(amount) }.abi_encode();
        vm.mock_call(USDC_ADDR, data, U256::ZERO, Ok(bool_word(ok)));
    }

    #[test]
    fn test_initialization() {
        let vm = TestVM::default();
        let registry = new_registry(&vm);

        assert_eq!(registry.admin(), ADMIN_ADDR);
        assert_eq!(registry.usdc(), USDC_ADDR);
        assert_eq!(registry.data_registry(), REGISTRY_ADDR);
        assert_eq!(registry.subscription_fee(), U256::from(SUB_FEE_AMT));
    }

    #[test]
    fn test_subscribe_requires_registration() {
        let vm = TestVM::default();
        let mut registry = new_registry(&vm);

        vm.set_sender(PUB_ADDR);
        mock_registered(&vm, PUB_ADDR, false); // not a publisher

        let res = registry.subscribe();
        assert!(matches!(res, Err(SubscriptionError::NotRegistered(_))));
        assert_eq!(registry.subscribed_at(PUB_ADDR), 0);
    }

    // ponytail: the "registered but USDC pull fails → SubscriptionFeeRequired"
    // branch isn't unit-tested here. TestVM returns one shared value for both
    // cross-calls in a single tx, so isRegistered and transferFrom can't return
    // different bools; that exact pull-failure mapping is covered by data_registry's
    // test_registration_fails_when_usdc_transfer_fails (identical copied code).

    #[test]
    fn test_subscribe_records_and_renews_timestamp() {
        let vm = TestVM::default();
        let mut registry = new_registry(&vm);

        vm.set_block_timestamp(1_700_000_000);
        vm.set_sender(PUB_ADDR);
        mock_registered(&vm, PUB_ADDR, true);
        mock_pull(&vm, PUB_ADDR, SUB_FEE_AMT, true);

        assert!(registry.subscribe().is_ok());
        assert_eq!(registry.subscribed_at(PUB_ADDR), 1_700_000_000);

        // Renewal while already active re-stamps to the new now.
        vm.set_block_timestamp(1_700_100_000);
        assert!(registry.subscribe().is_ok());
        assert_eq!(registry.subscribed_at(PUB_ADDR), 1_700_100_000);
    }

    #[test]
    fn test_access_returns_registration_and_paid_at() {
        let vm = TestVM::default();
        let mut registry = new_registry(&vm);

        // A registered publisher who has paid.
        vm.set_block_timestamp(1_700_000_000);
        vm.set_sender(PUB_ADDR);
        mock_registered(&vm, PUB_ADDR, true);
        mock_pull(&vm, PUB_ADDR, SUB_FEE_AMT, true);
        registry.subscribe().unwrap();

        let (registered, paid_at) = registry.access(PUB_ADDR);
        assert!(registered);
        assert_eq!(paid_at, 1_700_000_000);

        // An unregistered wallet that never paid.
        mock_registered(&vm, RECIPIENT, false);
        let (registered, paid_at) = registry.access(RECIPIENT);
        assert!(!registered);
        assert_eq!(paid_at, 0);
    }

    #[test]
    fn test_set_subscription_fee_admin_only() {
        let vm = TestVM::default();
        let mut registry = new_registry(&vm);

        vm.set_sender(PUB_ADDR);
        assert!(matches!(
            registry.set_subscription_fee(U256::from(1u64)),
            Err(SubscriptionError::Unauthorized(_))
        ));

        vm.set_sender(ADMIN_ADDR);
        assert!(registry.set_subscription_fee(U256::from(42u64)).is_ok());
        assert_eq!(registry.subscription_fee(), U256::from(42u64));
    }

    #[test]
    fn test_withdraw_usdc_admin_only() {
        let vm = TestVM::default();
        let mut registry = new_registry(&vm);

        vm.set_sender(PUB_ADDR);
        assert!(matches!(
            registry.withdraw_usdc(RECIPIENT, U256::from(SUB_FEE_AMT)),
            Err(SubscriptionError::Unauthorized(_))
        ));

        vm.set_sender(ADMIN_ADDR);
        let data = transferCall { to: RECIPIENT, amount: U256::from(SUB_FEE_AMT) }.abi_encode();
        vm.mock_call(USDC_ADDR, data, U256::ZERO, Ok(bool_word(true)));
        assert!(registry.withdraw_usdc(RECIPIENT, U256::from(SUB_FEE_AMT)).is_ok());
    }

    #[test]
    fn test_withdraw_eth_admin_only() {
        let vm = TestVM::default();
        let mut registry = new_registry(&vm);

        vm.set_sender(PUB_ADDR);
        assert!(matches!(
            registry.withdraw_eth(RECIPIENT, U256::from(1u64)),
            Err(SubscriptionError::Unauthorized(_))
        ));

        vm.set_sender(ADMIN_ADDR);
        vm.mock_call(RECIPIENT, Vec::new(), U256::from(1u64), Ok(Vec::new()));
        assert!(registry.withdraw_eth(RECIPIENT, U256::from(1u64)).is_ok());
    }
}
