// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC5643} from "./IERC5643.sol";

/// AppRegistry
///
/// An application is sponsored storage for the publishers it accepts. A wallet claims
/// an app (`registerApp`) and owns it; the owner accepts publishers (`acceptPublisher`).
/// An accepted publisher uploads with storage the app provides, and the app includes its
/// data: the latest head of each of its repos, less what the owner excludes (`exclude`).
/// A repo lives in the DataRegistry and belongs to no app; nothing here reads or records
/// a head. One rule, `canPublish`, says whether both hold for a publisher now.
///
/// An app IS a storage subscription: claiming one pulls the subscription fee (USDC)
/// for one period, and the off-chain upload gate reads `access` to decide whether to
/// serve its publishers.
///
/// The subscription fee is the one payment, in USDC: set by the admin, paid by the app's
/// owner, and taken out by the admin (`withdrawToken`). Join fees, which earlier versions
/// collected from publishers, are no longer charged; what an owner is still owed stays
/// theirs to take out (`withdrawJoinFees`), out of the admin's reach
/// (`totalJoinFeesOwed`). The contract holds no ETH.
///
/// Each app is also an ERC-721 token, minted to its owner at claim, and its
/// subscription follows ERC-5643: `expiresAt`, `isRenewable`, `renewSubscription` and
/// `cancelSubscription`. The token id and the app id are the same 32 bytes,
/// `uint256(app_id)`: the ERC-721 and ERC-5643 functions take the token id, the rest of
/// the contract the app id. The token cannot be transferred.
///
/// The expiry is enforced here. Once an app's subscription has lapsed or been
/// cancelled, it provides no storage and includes nothing. Renewing lifts it at once,
/// and nothing is lost meanwhile. Managing publishers stays open.
/// Deployed behind an ERC-1967 proxy (UUPS): the proxy holds the state and the address,
/// and the admin can point it at a new implementation. Storage is therefore
/// append-only: add state variables after the last one and fields at the end of
/// `App`, and never reorder, retype or remove what is there. A new version is an edit
/// to this file; the upgrade tooling checks its storage against the build of the live
/// version, committed under `deployed/`.
contract AppRegistry is Initializable, UUPSUpgradeable, ERC721Upgradeable, ReentrancyGuardTransient, IERC5643 {
    using SafeERC20 for IERC20;

    /// A publisher's standing in one app. In the ABI it is a uint8, in this order.
    enum Status {
        /// Never accepted by the app.
        None,
        /// Accepted by the app's owner (`acceptPublisher`).
        Active,
        /// Accepted, then suspended from the app by its owner.
        Suspended,
        /// Retired: invited under the old join flow, and never joined. Not a member;
        /// `acceptPublisher` accepts it like `None`.
        Invited
    }

    // Errors, grouped by topic.

    // Shared
    /// The caller may not do this: not the admin, for an admin function; not the
    /// app's owner, for an owner function or `cancelSubscription`
    error Unauthorized();
    /// Sending USDC (`withdrawJoinFees`) or an ERC-20 (`withdrawToken`) failed
    error TransferFailed();
    /// `withdrawToken`: more USDC than the protocol's share, which is the contract's
    /// balance minus the join fees owed to app owners
    error ExceedsProtocolBalance();

    // Apps
    /// No app has been registered with this id
    error AppNotFound();
    /// `registerApp`: an app with this id already exists
    error AppAlreadyRegistered();
    /// `withdrawJoinFees`: the caller is owed nothing
    error NothingToWithdraw();

    // Membership
    /// `setPublisherSuspended`: the app never accepted this wallet
    error NotAccepted();
    /// `acceptPublisher`: the app has already accepted this wallet (suspended or not)
    error AlreadyAccepted();
    /// `setPublisherSuspended(…, false)`: the publisher is not suspended from this app
    error PublisherNotSuspended();
    /// `setPublisherSuspended`: an app's owner cannot suspend themselves from it
    error CannotSuspendOwner();
    /// The protocol admin has suspended this wallet network-wide (`setGlobalSuspension`):
    /// the caller, the publisher named, or (for accepting a publisher and moving the
    /// agent card) the app's owner
    error PublisherSuspendedGlobal();

    // Presenting
    /// `exclude`: already excluded
    error AlreadyExcluded();
    /// `restore`: not excluded
    error NotExcluded();

    // Subscription
    /// The subscription fee could not be collected: the token refused the transfer,
    /// usually because the payer's allowance or balance is too low
    error SubscriptionFeeRequired();
    /// `registerApp`: the subscription fee is above the most the caller agreed to pay
    error SubscriptionFeeTooHigh();
    /// The subscription has a period or more left; renew it once less than that remains
    error SubscriptionNotRenewable();
    /// `renewSubscription`: `duration` is not the subscription period
    error DurationMismatch();
    /// The subscription is paid in USDC; renewing or cancelling takes no ETH
    error EthNotAccepted();
    /// An app's token cannot be transferred or burned
    error NotTransferable();
    /// The subscription period cannot be zero
    error ZeroPeriod();

    // Events, grouped the same way. The subscription's own event, `SubscriptionUpdate`,
    // is ERC-5643's, declared in `IERC5643`.

    // Apps
    /// A wallet claimed an app
    event AppRegistered(bytes32 indexed app_id, address indexed owner);
    /// An app owner took out the join fees they were owed
    event JoinFeesWithdrawn(address indexed owner, address to, uint256 amount);
    /// The app's agent card moved
    event AppAgentChanged(bytes32 indexed app_id, string agent_uri);
    /// The protocol admin suspended (or reinstated) an entire app
    event AppSuspensionChanged(bytes32 indexed app_id, bool suspended);

    // Membership
    /// An app's owner accepted a publisher: it may upload with the app's storage, and the
    /// app includes its data
    event PublisherAccepted(bytes32 indexed app_id, address indexed publisher);
    /// An app owner suspended a publisher from their app, or lifted the suspension
    event PublisherSuspensionChanged(bytes32 indexed app_id, address indexed publisher, bool suspended);
    /// The protocol admin banned a wallet network-wide, or lifted the ban
    event GlobalSuspensionChanged(address indexed publisher, bool suspended);

    // Presenting
    /// An exclusion changed: odd `count` means in force. `repo_id` and `key_id` are zero
    /// for the levels it does not name.
    event ExclusionChanged(
        bytes32 indexed app_id,
        address indexed publisher,
        bytes32 indexed exclusion_id,
        bytes32 repo_id,
        bytes32 key_id,
        uint64 count
    );

    // Protocol admin
    /// The admin changed the subscription fee, in USDC base units: it applies from the
    /// next claim or renewal
    event SubscriptionFeeChanged(uint256 fee);
    /// The admin changed the period: it applies from each app's next payment
    event SubscriptionPeriodChanged(uint64 period);
    /// The admin pointed the DataRegistry address at another one
    event DataRegistryChanged(address previous_registry, address new_registry);
    /// The admin sent an ERC-20 the contract held: subscription fees, or a token sent
    /// here by mistake
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);
    /// The admin role moved to `new_admin`. Zero renounces it, and upgrades, for good.
    event AdminChanged(address previous_admin, address new_admin);

    /// The app registry admin
    address public admin;
    /// How long one subscription payment lasts, in seconds. Shares a slot with `admin`.
    uint64 public subscriptionPeriod;
    /// ERC-20 token the subscription fee is paid in (USDC). Amounts are in its base units.
    address public usdc;
    /// Subscription fee, denominated in USDC base units (6 decimals).
    uint256 public subscriptionFee;
    /// The DataRegistry this app registry names. Nothing here calls it.
    address public dataRegistry;

    struct App {
        // The first three fields share one storage slot (20 + 1 + 8 bytes): keep them
        // adjacent.
        /// Zero means the app is unclaimed. Always the same as the token's owner
        /// (`ownerOf`): the token cannot move. Kept here as well so that `canPublish`
        /// reads the owner, the takedown flag and the expiry from one storage slot.
        address owner;
        /// Admin takedown flag. A suspended app is dead for every publisher at once.
        bool isAppSuspended;
        /// When the subscription expires (Unix seconds). Zero once cancelled.
        uint64 expiry;
        /// Retired: the publisher terms hash of the old join flow. Kept for the layout.
        bytes32 appTerms;
        /// Retired: where the terms were read. Kept for the layout.
        string appTermsUri;
        /// Retired: the old join fee. Kept for the layout.
        uint256 joinFee;
        /// URI of the app's ERC-8004 agent card. Empty means the app has none.
        string appAgentUri;
    }

    /// app_id => app. Internal: the getters below are the ABI the SDK reads.
    mapping(bytes32 => App) internal apps;
    /// app_id => publisher => standing in the app
    mapping(bytes32 => mapping(address => Status)) public statusForApp;
    /// Retired: app_id => publisher => the terms hash they joined on. Kept for the layout.
    mapping(bytes32 => mapping(address => bytes32)) internal acceptedTerms;
    /// wallet => banned network-wide by the protocol admin
    mapping(address => bool) public globalSuspensions;
    /// app owner => join fees paid to their apps under the old join flow and not yet
    /// withdrawn, in USDC base units. Nothing adds to it any more.
    mapping(address => uint256) public joinFeesOwed;
    /// The sum of `joinFeesOwed`: the part of the contract's USDC that belongs to app
    /// owners, which `withdrawToken` cannot touch
    uint256 public totalJoinFeesOwed;

    /// app_id => exclusionId => changes so far; odd means excluded
    mapping(bytes32 => mapping(bytes32 => uint64)) public exclusionCount;

    /// The implementation is only ever used through a proxy. Lock it, so nobody can
    /// initialize it directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// Takes the place of a constructor: runs once, in the proxy's storage, as part of
    /// the proxy's deployment.
    function initialize(address admin_, address usdc_, uint256 subscriptionFee_, uint64 subscriptionPeriod_)
        external
        initializer
    {
        __ERC721_init("FANGAPP", "FANGAPP");
        admin = admin_;
        usdc = usdc_;
        subscriptionFee = subscriptionFee_;
        _setSubscriptionPeriod(subscriptionPeriod_);
    }

    // ── Apps ──────────────────────────────────────────────────────────────────

    /// Register a unique app id.
    ///
    /// * `max_subscription_fee`: the most the caller will pay for the first period. The
    ///   fee charged is `subscriptionFee()` when the registration lands; if the admin has raised
    ///   it above this in the meantime, the registration reverts instead.
    ///
    /// The caller becomes the app's first publisher, already accepted.
    ///
    /// Registration pays the subscription fee (USDC) for one period, so an app cannot exist
    /// unpaid. The caller must `approve` this contract for `subscriptionFee()` first.
    /// It mints the app's token to the caller.
    ///
    /// The caller must not be banned network-wide (`globalSuspensions`), so a wallet the
    /// protocol admin has banned cannot come back as an app owner.
    function registerApp(bytes32 app_id, uint256 max_subscription_fee) external nonReentrant {
        App storage app = apps[app_id];
        address owner = msg.sender;
        if (globalSuspensions[owner]) revert PublisherSuspendedGlobal();
        if (app.owner != address(0)) revert AppAlreadyRegistered();
        if (subscriptionFee > max_subscription_fee) revert SubscriptionFeeTooHigh();
        _paySubscription(app_id, owner);

        app.owner = owner;
        statusForApp[app_id][owner] = Status.Active;
        _mint(owner, uint256(app_id));

        emit AppRegistered(app_id, owner);
        emit PublisherAccepted(app_id, owner);
    }

    function getAppOwner(bytes32 app_id) external view returns (address) {
        return apps[app_id].owner;
    }

    /// Take out every join fee owed to the caller, as the owner of one or more apps,
    /// and send it, in USDC, to `to`. Only fees collected under the old join flow are
    /// owed. If the transfer fails, the balance stays owed.
    function withdrawJoinFees(address to) external nonReentrant {
        uint256 amount = joinFeesOwed[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        joinFeesOwed[msg.sender] = 0;
        totalJoinFeesOwed -= amount;
        if (!IERC20(usdc).trySafeTransfer(to, amount)) revert TransferFailed();
        emit JoinFeesWithdrawn(msg.sender, to, amount);
    }

    /// Point at the app's ERC-8004 agent card. Only callable by the app owner, and not
    /// by one banned network-wide (`PublisherSuspendedGlobal`).
    function setAppAgentUri(bytes32 app_id, string calldata agent_uri) external onlyAppOwner(app_id) {
        if (globalSuspensions[msg.sender]) revert PublisherSuspendedGlobal();
        apps[app_id].appAgentUri = agent_uri;
        emit AppAgentChanged(app_id, agent_uri);
    }

    // ── Membership ────────────────────────────────────────────────────────────

    /// Accept a publisher into this app. Only callable by the app owner. From here the
    /// publisher may upload with storage the app provides, and the app includes its data,
    /// for as long as `canPublish` holds.
    ///
    /// Neither side may be banned network-wide (`PublisherSuspendedGlobal`): an owner
    /// cannot bring in a wallet the protocol admin has banned, and a banned owner cannot
    /// bring in anyone, which would let them keep publishing through new wallets.
    /// A publisher the app already accepted reverts `AlreadyAccepted`; one it suspended
    /// comes back with `setPublisherSuspended(…, false)`.
    function acceptPublisher(bytes32 app_id, address publisher) external onlyAppOwner(app_id) {
        if (globalSuspensions[msg.sender]) revert PublisherSuspendedGlobal();
        if (globalSuspensions[publisher]) revert PublisherSuspendedGlobal();
        Status status = statusForApp[app_id][publisher];
        if (status == Status.Active || status == Status.Suspended) revert AlreadyAccepted();
        statusForApp[app_id][publisher] = Status.Active;
        emit PublisherAccepted(app_id, publisher);
    }

    /// Suspend a member from this app (`true`), or lift the suspension (`false`). Only
    /// callable by the app owner, and only for this app: a network-wide ban is the
    /// protocol admin's (`setGlobalSuspension`).
    ///
    /// Only a publisher the app accepted can be suspended (`NotAccepted` otherwise), so
    /// lifting a suspension always makes them a member again. Unlike the other suspension setters,
    /// lifting one that is not there reverts (`PublisherNotSuspended`), since it would
    /// otherwise change the publisher's status. The owner cannot suspend themselves
    /// (`CannotSuspendOwner`): an owner's membership of their own app is not theirs to
    /// take away.
    function setPublisherSuspended(bytes32 app_id, address publisher, bool is_suspended) external onlyAppOwner(app_id) {
        Status status = statusForApp[app_id][publisher];
        if (is_suspended) {
            if (publisher == msg.sender) revert CannotSuspendOwner();
            if (status != Status.Active) revert NotAccepted();
            statusForApp[app_id][publisher] = Status.Suspended;
        } else {
            if (status != Status.Suspended) revert PublisherNotSuspended();
            statusForApp[app_id][publisher] = Status.Active;
        }
        emit PublisherSuspensionChanged(app_id, publisher, is_suspended);
    }

    // ── Presenting ────────────────────────────────────────────────────────────

    /// Withdraw a publisher (`repo_id` and `key_id` zero), one of its repos (`key_id`
    /// zero), or one record key of a repo from the app, for all of its past. Owner only.
    function exclude(bytes32 app_id, address publisher, bytes32 repo_id, bytes32 key_id) external onlyAppOwner(app_id) {
        _flipExclusion(app_id, publisher, repo_id, key_id, 0);
    }

    /// Lift an exclusion. Owner only.
    function restore(bytes32 app_id, address publisher, bytes32 repo_id, bytes32 key_id) external onlyAppOwner(app_id) {
        _flipExclusion(app_id, publisher, repo_id, key_id, 1);
    }

    /// The slot an exclusion is counted in. Names stay hashed.
    function exclusionId(address publisher, bytes32 repo_id, bytes32 key_id) public pure returns (bytes32) {
        return keccak256(abi.encode(publisher, repo_id, key_id));
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    function appAgentUri(bytes32 app_id) external view returns (string memory) {
        return apps[app_id].appAgentUri;
    }

    function isAppSuspended(bytes32 app_id) external view returns (bool) {
        return apps[app_id].isAppSuspended;
    }

    /// May `publisher` publish to the app now? True while the app has accepted it and not
    /// suspended it, it is not banned network-wide, and the app is neither taken down nor
    /// past its subscription. The one rule an app has
    /// for a publisher: while it holds, the upload gate bills the publisher's bytes to the
    /// app, and the app presents the publisher's repos.
    function canPublish(bytes32 app_id, address publisher) public view returns (bool) {
        App storage app = apps[app_id];
        return !app.isAppSuspended && app.expiry > block.timestamp && !globalSuspensions[publisher]
            && statusForApp[app_id][publisher] == Status.Active;
    }

    /// The single oracle the upload gate reads: `(can_publish, owner, expires_at)`.
    /// `can_publish` is `canPublish`; `owner` is zero for an unclaimed app;
    /// `expires_at` is when the app's subscription expires; once it has passed,
    /// `can_publish` is false.
    function access(bytes32 app_id, address publisher) external view returns (bool, address, uint64) {
        App storage app = apps[app_id];
        return (canPublish(app_id, publisher), app.owner, app.expiry);
    }

    // ── Subscription (ERC-5643) ───────────────────────────────────────────────

    /// Pay for one more period. Callable by the app's owner, or an address they have
    /// approved for its token, who pays the subscription fee (USDC; `approve` this
    /// contract first).
    ///
    /// The fee charged is `subscriptionFee()` when the renewal lands. The standard
    /// fixes this function's arguments, so there is no maximum-fee argument here: the
    /// payer's allowance is the cap. Approve exactly the fee, and a fee raised in the
    /// meantime makes the renewal revert instead of charging more.
    ///
    /// `duration` must be the subscription period, and the app must be renewable: a
    /// subscription with a period or more left cannot be paid further ahead. The
    /// period is added to the current expiry, or to now if it has passed.
    ///
    /// `payable` only because ERC-5643 declares it so: the fee is USDC, and ETH sent
    /// with it reverts.
    function renewSubscription(uint256 tokenId, uint64 duration) external payable nonReentrant {
        _checkAuthorized(_ownerOf(tokenId), msg.sender, tokenId);
        if (msg.value != 0) revert EthNotAccepted();
        if (duration != subscriptionPeriod) revert DurationMismatch();
        if (!isRenewable(tokenId)) revert SubscriptionNotRenewable();
        _paySubscription(bytes32(tokenId), msg.sender);
    }

    /// End the subscription now, as the standard does: the expiry becomes zero. Nothing
    /// is refunded. The app stays claimed, and renewing starts a new period from now.
    /// Only the app's owner may cancel: an address they approved for the token can
    /// renew it, but not end it. `payable` only because ERC-5643 declares it so; ETH
    /// sent with it reverts.
    function cancelSubscription(uint256 tokenId) external payable {
        if (_requireOwned(tokenId) != msg.sender) revert Unauthorized();
        if (msg.value != 0) revert EthNotAccepted();
        apps[bytes32(tokenId)].expiry = 0;
        emit SubscriptionUpdate(tokenId, 0);
    }

    function expiresAt(uint256 tokenId) external view returns (uint64) {
        _requireOwned(tokenId);
        return apps[bytes32(tokenId)].expiry;
    }

    /// True while less than one period is left, or the subscription has expired.
    function isRenewable(uint256 tokenId) public view returns (bool) {
        _requireOwned(tokenId);
        return apps[bytes32(tokenId)].expiry < block.timestamp + subscriptionPeriod;
    }

    function supportsInterface(bytes4 interface_id) public view override returns (bool) {
        return interface_id == type(IERC5643).interfaceId || super.supportsInterface(interface_id);
    }

    /// Mint only: an app's token is never transferred or burned, so its owner is
    /// always `App.owner`.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0)) revert NotTransferable();
        return super._update(to, tokenId, auth);
    }

    // ── Protocol admin ────────────────────────────────────────────────────────

    /// Hand the admin role to another address. The admin is also who may upgrade this
    /// contract, so setting zero renounces both for good.
    function setAdmin(address new_admin) external onlyAdmin {
        emit AdminChanged(admin, new_admin);
        admin = new_admin;
    }

    /// Only the admin may point the proxy at a new implementation.
    function _authorizeUpgrade(address) internal override onlyAdmin {}

    /// Change the subscription fee, in USDC base units. It applies from the next claim
    /// or renewal, within what the payer has capped (see `registerApp`, `renewSubscription`).
    function setSubscriptionFee(uint256 fee) external onlyAdmin {
        subscriptionFee = fee;
        emit SubscriptionFeeChanged(fee);
    }

    /// Change how long one payment lasts. Expiries already set stay as they are; the
    /// new period applies from each app's next payment.
    ///
    /// It does move when apps may next renew: `isRenewable` compares an app's expiry
    /// with now plus the current period, so a longer period lets every app renew
    /// sooner, and a shorter one later.
    function setSubscriptionPeriod(uint64 period) external onlyAdmin {
        _setSubscriptionPeriod(period);
    }

    /// Point the DataRegistry address at another one.
    function setDataRegistry(address registry) external onlyAdmin {
        emit DataRegistryChanged(dataRegistry, registry);
        dataRegistry = registry;
    }

    /// Take an app down for every publisher at once (`true`), or put it back (`false`).
    /// Admin-only. Memberships are left intact, so putting it back restores them
    /// exactly.
    function setAppSuspended(bytes32 app_id, bool is_suspended) external onlyAdmin {
        App storage app = apps[app_id];
        if (app.owner == address(0)) revert AppNotFound();
        app.isAppSuspended = is_suspended;
        emit AppSuspensionChanged(app_id, is_suspended);
    }

    /// Ban a wallet network-wide (`true`), or lift the ban (`false`). A banned wallet
    /// can no longer claim an app, be accepted into one, or publish in any
    /// (`canPublish` turns false). Any address can be banned, including one that
    /// has never published. Nothing else is touched, so lifting the ban restores
    /// everything, and the wallet's timelines in the DataRegistry resume where they
    /// stopped.
    function setGlobalSuspension(address publisher, bool is_suspended) external onlyAdmin {
        globalSuspensions[publisher] = is_suspended;
        emit GlobalSuspensionChanged(publisher, is_suspended);
    }

    /// Send `amount` of an ERC-20 the contract holds to `to`: the collected subscription
    /// fees (USDC), or any token sent here by mistake, including one that returns no
    /// value from `transfer`. Of USDC, only the protocol's share can be taken: the
    /// contract's balance less the join fees owed to app owners (`ExceedsProtocolBalance`).
    function withdrawToken(address token, address to, uint256 amount) external nonReentrant onlyAdmin {
        if (token == usdc && IERC20(usdc).balanceOf(address(this)) < totalJoinFeesOwed + amount) {
            revert ExceedsProtocolBalance();
        }
        if (!IERC20(token).trySafeTransfer(to, amount)) revert TransferFailed();
        emit TokenWithdrawn(token, to, amount);
    }

    // ── Internals ─────────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    modifier onlyAppOwner(bytes32 app_id) {
        address owner = apps[app_id].owner;
        if (owner == address(0)) revert AppNotFound();
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// Pull the subscription fee from `payer` and add one period to the app's expiry,
    /// counted from now if it has passed.
    function _paySubscription(bytes32 app_id, address payer) private {
        uint256 fee = subscriptionFee;
        if (fee != 0 && !IERC20(usdc).trySafeTransferFrom(payer, address(this), fee)) {
            revert SubscriptionFeeRequired();
        }
        App storage app = apps[app_id];
        uint64 from = app.expiry > block.timestamp ? app.expiry : uint64(block.timestamp);
        uint64 expiry = from + subscriptionPeriod;
        app.expiry = expiry;
        emit SubscriptionUpdate(uint256(app_id), expiry);
    }

    /// exclude needs an even count, restore an odd one; both add one.
    function _flipExclusion(bytes32 app_id, address publisher, bytes32 repo_id, bytes32 key_id, uint64 parity) private {
        bytes32 xid = exclusionId(publisher, repo_id, key_id);
        uint64 n = exclusionCount[app_id][xid];
        if (n % 2 != parity) {
            if (parity == 0) revert AlreadyExcluded();
            revert NotExcluded();
        }
        exclusionCount[app_id][xid] = n + 1;
        emit ExclusionChanged(app_id, publisher, xid, repo_id, key_id, n + 1);
    }

    function _setSubscriptionPeriod(uint64 period) private {
        if (period == 0) revert ZeroPeriod();
        subscriptionPeriod = period;
        emit SubscriptionPeriodChanged(period);
    }
}
